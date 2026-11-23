import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import OSLog

private let log = Logger(subsystem: "com.openopal", category: "vcam")

/// Pushes finished frames into the virtual camera's sink stream.
///
/// This speaks the old C CoreMediaIO hardware API — the same interface Zoom
/// uses to *read* cameras, driven in reverse: find our virtual device, find its
/// sink stream, start it, and enqueue sample buffers. It's the one sanctioned
/// way for an app to feed its own CMIO extension without inventing custom IPC.
final class VirtualCameraFeeder: @unchecked Sendable {

    private let lock = NSLock()
    private var deviceID: CMIOObjectID = 0
    private var sinkStreamID: CMIOStreamID = 0
    private var queue: CMSimpleQueue?
    private var formatDesc: CMFormatDescription?
    private var isConnected = false
    var connected: Bool { lock.withLock { isConnected } }

    /// The stream video apps read from, which carries the extension's "is
    /// anyone watching" property.
    private var sourceStreamID: CMIOStreamID?
    private var watched = true
    private var watchedCheckedAt = 0.0

    /// True when a frame sent now would reach a video app.
    ///
    /// Frames used to be sent whether or not anything had the camera open. Each
    /// one cost a GPU blit and wait, a colour conversion and a trip through
    /// CoreMediaIO's service and the extension, which together measured more
    /// CPU than the rest of the app, to be thrown away at the far end. The
    /// extension already publishes whether a capture client is streaming (for
    /// the login helper), so ask it, ten times a second.
    ///
    /// Anything but a clear "nobody" counts as watched: a missed frame in a
    /// call is worse than a wasted one.
    var wantsFrames: Bool {
        lock.lock(); defer { lock.unlock() }
        guard isConnected else { return false }
        guard let sourceStreamID else { return true }

        let now = CFAbsoluteTimeGetCurrent()
        if now - watchedCheckedAt >= 0.1 {
            watchedCheckedAt = now
            watched = demand(on: sourceStreamID) ?? true
        }
        return watched
    }

    private func demand(on stream: CMIOStreamID) -> Bool? {
        var address = CameraDemand.address
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard CMIOObjectGetPropertyData(stream, &address, 0, nil, size, &used, &value) == noErr,
              used == size, let value else { return nil }
        return CameraDemand.isActive(value.takeRetainedValue() as String)
    }
    private let converter = VirtualCameraFrameConverter()

    /// Frames delivered / dropped, for the UI.
    private(set) var sent: Int = 0
    private(set) var dropped: Int = 0

    // MARK: Discovery

    /// Finds the virtual device and opens its sink. Safe to call repeatedly —
    /// it's a no-op once connected, and cheap when the device doesn't exist yet
    /// (extension not installed / still activating).
    func connectIfNeeded() {
        lock.lock(); defer { lock.unlock() }
        guard !isConnected else { return }

        guard let device = findDevice(uid: kVirtualDeviceUID) else { return }
        guard let sink = findStream(device: device, scope: kCMIODevicePropertyScopeOutput,
                                    direction: 0) else {
            log.warning("virtual device found but no sink stream")
            return
        }

        var q: Unmanaged<CMSimpleQueue>?
        let status = CMIOStreamCopyBufferQueue(sink, { _, _, _ in }, nil, &q)
        guard status == noErr, let q else {
            log.error("CMIOStreamCopyBufferQueue failed: \(status)")
            return
        }

        let ownedQueue = q.takeRetainedValue()
        guard CMIODeviceStartStream(device, sink) == noErr else {
            log.error("CMIODeviceStartStream failed")
            return
        }

        deviceID = device
        sinkStreamID = sink
        sourceStreamID = findStream(device: device, scope: kCMIODevicePropertyScopeInput,
                                    direction: 1)
        watched = true
        watchedCheckedAt = 0
        queue = ownedQueue
        isConnected = true
        log.info("feeding virtual camera (device \(device), sink \(sink))")
    }

    func disconnect() {
        lock.lock(); defer { lock.unlock() }
        if isConnected {
            CMIODeviceStopStream(deviceID, sinkStreamID)
        }
        isConnected = false
        queue = nil
        formatDesc = nil
    }

    // MARK: Frames

    /// Enqueue one BGRA frame. Called from the render worker, off the main actor.
    func send(_ pixelBuffer: CVPixelBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard isConnected, let queue else { return }

        // The sink's queue is shallow by design; if the extension isn't
        // draining (no app watching the camera), drop rather than block.
        guard CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue) else {
            dropped += 1
            return
        }
        guard let pixelBuffer = converter.convert(pixelBuffer) else {
            dropped += 1
            return
        }

        if formatDesc == nil ||
            !CMVideoFormatDescriptionMatchesImageBuffer(formatDesc!, imageBuffer: pixelBuffer) {
            var desc: CMFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                formatDescriptionOut: &desc)
            formatDesc = desc
        }
        guard let formatDesc else { return }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid)

        var sbuf: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDesc,
            sampleTiming: &timing,
            sampleBufferOut: &sbuf)
        guard status == noErr, let sbuf else { return }

        // Transfer ownership only if the queue actually accepts the buffer.
        let retained = Unmanaged.passRetained(sbuf)
        if CMSimpleQueueEnqueue(queue, element: retained.toOpaque()) == noErr {
            sent += 1
        } else {
            retained.release()
            dropped += 1
        }
    }

    // MARK: - CMIO plumbing

    // CMIOExtension devices surface their deviceID UUID as the C-API UID.
    private var kVirtualDeviceUID: String { CameraDemand.deviceUID }

    private func findDevice(uid: String) -> CMIOObjectID? {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))

        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject),
                                            &address, 0, nil, &dataSize) == noErr else { return nil }
        let count = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
        guard count > 0 else { return nil }

        var devices = [CMIOObjectID](repeating: 0, count: count)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject),
                                        &address, 0, nil, dataSize, &used, &devices) == noErr
        else { return nil }

        for device in devices {
            if deviceUID(device) == uid { return device }
        }
        return nil
    }

    private func deviceUID(_ device: CMIOObjectID) -> String? {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var uid: CFString = "" as CFString
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &uid) { ptr in
            CMIOObjectGetPropertyData(device, &address, 0, nil, size, &used, ptr)
        }
        return status == noErr ? uid as String : nil
    }

    /// The legacy CMIO direction is 0 for output/playback (our sink) and 1 for
    /// input/capture (what video apps read). This differs from
    /// CMIOExtensionStream.Direction.
    private func findStream(device: CMIOObjectID, scope: Int, direction wanted: UInt32) -> CMIOStreamID? {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams),
            mScope: CMIOObjectPropertyScope(scope),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))

        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(device, &address, 0, nil, &dataSize) == noErr
        else { return nil }
        let count = Int(dataSize) / MemoryLayout<CMIOStreamID>.size
        var streams = [CMIOStreamID](repeating: 0, count: count)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(device, &address, 0, nil, dataSize, &used, &streams) == noErr
        else { return nil }

        for stream in streams {
            var dirAddress = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIOStreamPropertyDirection),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
            var direction: UInt32 = 0
            var dirUsed: UInt32 = 0
            if CMIOObjectGetPropertyData(stream, &dirAddress, 0, nil,
                                         UInt32(MemoryLayout<UInt32>.size),
                                         &dirUsed, &direction) == noErr,
               direction == wanted {
                return stream
            }
        }
        return nil
    }
}
