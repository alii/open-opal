import CoreVideo
import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "com.openopal", category: "device")

/// Owns the Opal C1: discovery, the XLink connection, the frame pump, and the
/// control queue.
///
/// Connecting **takes the camera over**. The C1 normally runs Opal's flashed
/// firmware, which presents an ordinary UVC webcam to macOS. Booting our own
/// pipeline replaces that firmware in RAM, so the system "Opal C1" camera
/// disappears for as long as we hold the device. Releasing it reboots back into
/// UVC within about five seconds. Nothing is written to flash — this is fully
/// reversible, and the camera is never at risk of being bricked.
@Observable
@MainActor
final class OpalDevice {

    enum State: Equatable {
        case searching
        case notFound
        case connecting
        case streaming
        case failed(String)

        var isLive: Bool { self == .streaming }
    }

    private(set) var state: State = .searching
    private(set) var sensorName = ""
    private(set) var resolution = (w: 0, h: 0)
    private(set) var usbSpeed = ""

    /// Live numbers straight from the device, so the UI never has to guess.
    private(set) var telemetry = Telemetry()

    struct Telemetry {
        var latencyMs: Double = 0
        var fps: Double = 0
        var exposureUs: Int = 0
        var iso: Int = 0
        var lensPosition: Int = 0
        var colorTempK: Int = 0
    }

    /// Handed a fresh NV12 frame, already wrapped in an IOSurface-backed
    /// CVPixelBuffer ready for Metal. **Called on the capture thread**, not the
    /// main actor — hop yourself if you need to.
    var onFrame: ((CVPixelBuffer, Double) -> Void)? {
        get { sink.callback }
        set { sink.callback = newValue }
    }

    /// The frame path lives entirely off the main actor: depthai delivers frames
    /// on its own thread, and bouncing every one through the main actor just to
    /// copy bytes would put a 30Hz memcpy of 3MB behind whatever the UI is doing.
    private let sink = FrameSink()

    /// The takeover, narrated with real numbers — firmware size, USB
    /// re-enumeration states, pipeline graph, handshake, first frame. Shown in
    /// the connecting overlay, because a 4-second spinner that could instead say
    /// "uploading 15MB of firmware to a VPU" is a wasted 4 seconds.
    private(set) var bootLog: [String] = []

    private let bootSink = BootLogSink()
    private var handle: OpaquePointer?
    private var telemetryTimer: Timer?

    init() {
        opal_set_boot_logger(opalBootLogTrampoline,
                             Unmanaged.passUnretained(bootSink).toOpaque())
        bootSink.onLine = { [weak self] line in
            Task { @MainActor in self?.bootLog.append(line) }
        }
    }

    // MARK: - Discovery

    struct Discovered: Identifiable, Hashable {
        let mxid: String
        let name: String
        let usable: Bool
        var id: String { mxid }
    }

    func discover() -> [Discovered] {
        var infos = [OpalDeviceInfo](repeating: OpalDeviceInfo(), count: 8)
        let n = infos.withUnsafeMutableBufferPointer { opal_list_devices($0.baseAddress, 8) }
        return (0..<Int(n)).map { i in
            var info = infos[i]
            let mxid = withUnsafeBytes(of: &info.mxid) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
            let name = withUnsafeBytes(of: &info.name) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
            return Discovered(mxid: mxid, name: name, usable: info.usable)
        }
    }

    // MARK: - Lifecycle

    /// Connects, retrying while the device settles.
    ///
    /// When we release the C1 it reboots back into its stock UVC firmware, and
    /// for a few seconds it sits in BOOTLOADER state — present on the bus, but
    /// not ready to be booted again. Quitting and relaunching (or hitting ⌘R)
    /// lands squarely in that window, and grabbing the device mid-reboot kills
    /// the XLink stream outright ("Couldn't read data from stream: __bootloader").
    /// So: wait for it, don't fail on it.
    func connect(settings: CameraSettings) async {
        guard handle == nil else { return }

        state = .searching
        bootLog.removeAll()

        let deadline = Date().addingTimeInterval(20)
        var target: Discovered?

        while Date() < deadline {
            let devices = discover()
            // A device still in BOOTLOADER is mid-reboot: it'll be ready shortly.
            if let ready = devices.first(where: { $0.usable }) {
                target = ready
                break
            }
            try? await Task.sleep(for: .milliseconds(700))
        }

        guard let target else {
            state = .notFound
            return
        }

        state = .connecting
        log.info("booting pipeline onto \(target.mxid, privacy: .public)")

        var cfg = OpalPipelineConfig()
        if let scale = settings.outputMode.ispScale {
            cfg.ispNum = Int32(scale.num)
            cfg.ispDen = Int32(scale.den)
            cfg.keep4K = false
        } else {
            cfg.keep4K = true
        }
        cfg.fps = Int32(settings.fps)
        cfg.orientation = settings.rotate180 ? OPAL_ORIENT_ROTATE_180 : OPAL_ORIENT_NORMAL

        // opal_open boots the Myriad and blocks for a couple of seconds, so keep
        // it off the main actor or the whole UI stalls mid-connect.
        //
        // The callback context is the FrameSink, not self: frames arrive on the
        // capture thread, and handing a main-actor object to C would be a lie.
        let ctx = Unmanaged.passUnretained(sink).toOpaque()
        let mxid = target.mxid

        // The device can still slip into a reboot between discovery and open, so
        // a single attempt isn't enough — retry a few times before giving up.
        let args = OpenArgs(cfg: cfg, ctx: ctx)

        var opened: OpaquePointer?
        var lastError = ""
        for attempt in 1...4 {
            opened = await Task.detached(priority: .userInitiated) {
                HandleBox(mxid.withCString {
                    opal_open($0, args.cfg, opalFrameTrampoline, args.ctx)
                })
            }.value.handle
            if opened != nil { break }

            lastError = String(cString: opal_last_error())
            log.warning("open attempt \(attempt) failed: \(lastError, privacy: .public)")
            try? await Task.sleep(for: .seconds(2))
        }

        guard let opened else {
            log.error("open failed: \(lastError, privacy: .public)")
            state = .failed(lastError.isEmpty ? "Could not open the camera." : lastError)
            return
        }

        handle = opened
        readInfo()
        state = .streaming
        apply(settings)
        startTelemetry()
        log.info("streaming \(self.resolution.w)x\(self.resolution.h) from \(self.sensorName, privacy: .public)")
    }

    func disconnect() {
        telemetryTimer?.invalidate()
        telemetryTimer = nil
        if let handle {
            // Blocking: joins the capture thread and resets the Myriad.
            opal_close(handle)
            self.handle = nil
        }
        state = .searching
    }

    /// Cold settings (resolution/fps) live in the device pipeline, so changing
    /// them means rebooting the Myriad rather than sending a control message.
    func rebuildPipeline(settings: CameraSettings) async {
        guard handle != nil else { return }
        disconnect()
        await connect(settings: settings)
        settings.coldDirty = false
    }

    // MARK: - Controls

    func apply(_ s: CameraSettings) {
        guard let handle else { return }
        var c = OpalControls()

        c.autoExposure   = s.autoExposure
        c.exposureUs     = Int32(s.exposureUs)
        c.iso            = Int32(s.iso)
        c.evCompensation = Int32(s.evCompensation)
        c.aeLock         = s.aeLock

        c.manualFocus  = s.manualFocus
        c.lensPosition = Int32(s.lensPosition)
        c.afMode = switch s.afMode {
        case .auto:            OPAL_AF_AUTO
        case .continuousVideo: OPAL_AF_CONTINUOUS_VIDEO
        case .macro:           OPAL_AF_MACRO
        case .edof:            OPAL_AF_EDOF
        }

        c.manualWhiteBalance = s.manualWhiteBalance
        c.whiteBalanceK      = Int32(s.whiteBalanceK)
        c.awbLock            = s.awbLock
        c.awbMode = switch s.awbMode {
        case .auto:            OPAL_AWB_AUTO
        case .incandescent:    OPAL_AWB_INCANDESCENT
        case .fluorescent:     OPAL_AWB_FLUORESCENT
        case .warmFluorescent: OPAL_AWB_WARM_FLUORESCENT
        case .daylight:        OPAL_AWB_DAYLIGHT
        case .cloudy:          OPAL_AWB_CLOUDY
        case .twilight:        OPAL_AWB_TWILIGHT
        case .shade:           OPAL_AWB_SHADE
        }

        c.antiBanding = switch s.antiBanding {
        case .off:  OPAL_AB_OFF
        case .hz50: OPAL_AB_50HZ
        case .hz60: OPAL_AB_60HZ
        case .auto: OPAL_AB_AUTO
        }

        c.sharpness     = Int32(s.sharpness)
        c.lumaDenoise   = Int32(s.lumaDenoise)
        c.chromaDenoise = Int32(s.chromaDenoise)
        c.brightness    = Int32(s.brightness)
        c.contrast      = Int32(s.contrast)
        c.saturation    = Int32(s.saturation)

        opal_set_controls(handle, c)
    }

    func triggerAutofocus() {
        guard let handle else { return }
        opal_trigger_autofocus(handle)
    }

    /// Meter auto-exposure on a region (leaves focus alone). Throttled and
    /// dead-banded by the caller — spamming this would just flood the control
    /// queue and make AE oscillate.
    func meterExposure(on rect: CGRect) {
        guard let handle else { return }
        opal_set_exposure_region(handle,
                                 Float(rect.minX), Float(rect.minY),
                                 Float(rect.width), Float(rect.height))
    }

    /// Tap-to-focus: point the AF and AE metering at a spot in the frame.
    func focus(at point: CGPoint, boxSize: CGFloat = 0.18) {
        guard let handle else { return }
        let half = boxSize / 2
        opal_set_focus_region(handle,
                              Float(max(0, min(1 - boxSize, point.x - half))),
                              Float(max(0, min(1 - boxSize, point.y - half))),
                              Float(boxSize), Float(boxSize))
    }

    // MARK: - Telemetry

    private func readInfo() {
        guard let handle else { return }
        var name = [CChar](repeating: 0, count: 64)
        var speed: Int32 = 0, w: Int32 = 0, h: Int32 = 0
        if opal_get_info(handle, &name, 64, &speed, &w, &h) {
            sensorName = String(cString: name)
            resolution = (Int(w), Int(h))
            usbSpeed = switch speed {
            case 4: "SuperSpeed+"
            case 3: "SuperSpeed"
            case 2: "High Speed"
            default: "USB"
            }
        }
        // The sensor reports itself as "LCM48", which is Luxonis's name for the
        // 48MP Sony IMX582 module. Show the part people recognize.
        if sensorName == "LCM48" { sensorName = "Sony IMX582 (48MP)" }
    }

    private func startTelemetry() {
        telemetryTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollTelemetry() }
        }
    }

    private func pollTelemetry() {
        guard let handle else { return }
        var t = OpalTelemetry()
        guard opal_get_telemetry(handle, &t) else { return }
        telemetry = Telemetry(latencyMs: t.latencyMsP50,
                              fps: t.fps,
                              exposureUs: Int(t.reportedExposureUs),
                              iso: Int(t.reportedIso),
                              lensPosition: Int(t.reportedLensPosition),
                              colorTempK: Int(t.reportedColorTempK))
        if resolution.w == 0 { readInfo() }
    }
}

/// Receives frames on depthai's capture thread and turns them into Metal-ready
/// pixel buffers. Deliberately not actor-isolated — this is the hot path.
private final class FrameSink: @unchecked Sendable {
    private let lock = NSLock()
    private var pool: CVPixelBufferPool?
    private var poolSize = (w: 0, h: 0)

    /// Read on the capture thread, written from the main actor at setup. Guarded
    /// by the same lock as the pool.
    var callback: ((CVPixelBuffer, Double) -> Void)? {
        get { lock.withLock { _callback } }
        set { lock.withLock { _callback = newValue } }
    }
    private var _callback: ((CVPixelBuffer, Double) -> Void)?

    /// Copies the NV12 planes into an IOSurface-backed CVPixelBuffer. This is
    /// the *only* copy in the whole path: from here the data reaches Metal as
    /// two textures with no colour conversion, and can go on to the virtual
    /// camera without the CPU touching it again.
    func ingest(y: UnsafePointer<UInt8>, yStride: Int,
                uv: UnsafePointer<UInt8>, uvStride: Int,
                width: Int, height: Int, latencyMs: Double) {
        guard let pb = buffer(width: width, height: height) else { return }

        CVPixelBufferLockBaseAddress(pb, [])
        if let dstY = CVPixelBufferGetBaseAddressOfPlane(pb, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            for row in 0..<height {
                memcpy(dstY.advanced(by: row * stride), y.advanced(by: row * yStride), width)
            }
        }
        if let dstUV = CVPixelBufferGetBaseAddressOfPlane(pb, 1) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
            for row in 0..<(height / 2) {
                memcpy(dstUV.advanced(by: row * stride), uv.advanced(by: row * uvStride), width)
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])

        callback?(pb, latencyMs)
    }

    private func buffer(width: Int, height: Int) -> CVPixelBuffer? {
        lock.lock()
        if pool == nil || poolSize != (width, height) {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                // IOSurface-backed so Metal — and later the virtual camera —
                // can read the same memory without another copy.
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil,
                                    [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary,
                                    attrs as CFDictionary, &p)
            pool = p
            poolSize = (width, height)
        }
        let p = pool
        lock.unlock()

        guard let p else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, p, &pb)
        return pb
    }
}

/// Receives boot-log lines from the bridge's internal threads and forwards them
/// to whoever's listening. Unretained by C, but it lives as long as OpalDevice,
/// which lives as long as the app.
private final class BootLogSink: @unchecked Sendable {
    var onLine: (@Sendable (String) -> Void)?
}

private func opalBootLogTrampoline(line: UnsafePointer<CChar>?,
                                   ctx: UnsafeMutableRawPointer?) {
    guard let line, let ctx else { return }
    let sink = Unmanaged<BootLogSink>.fromOpaque(ctx).takeUnretainedValue()
    sink.onLine?(String(cString: line))
}

/// OpaquePointer isn't Sendable, but the depthai handle genuinely is safe to
/// move: the bridge guards it internally, and we only ever hand it back to C.
private struct HandleBox: @unchecked Sendable {
    let handle: OpaquePointer?
    init(_ h: OpaquePointer?) { handle = h }
}

/// Everything opal_open needs, in one sendable parcel. The config is a C struct
/// of scalars and the context is the FrameSink (which outlives the device), so
/// both are genuinely safe to hand to another thread — Swift just can't prove it
/// for imported C types.
private struct OpenArgs: @unchecked Sendable {
    let cfg: OpalPipelineConfig
    let ctx: UnsafeMutableRawPointer
}

/// C callback -> Swift, on depthai's capture thread. `ctx` is the unretained
/// FrameSink; it outlives every frame because opal_close() joins the capture
/// thread before anything is torn down.
private func opalFrameTrampoline(y: UnsafePointer<UInt8>?, yStride: Int,
                                 uv: UnsafePointer<UInt8>?, uvStride: Int,
                                 width: Int32, height: Int32,
                                 hostTimeNs: Int64, latencyMs: Double,
                                 ctx: UnsafeMutableRawPointer?) {
    guard let y, let uv, let ctx else { return }
    let sink = Unmanaged<FrameSink>.fromOpaque(ctx).takeUnretainedValue()
    sink.ingest(y: y, yStride: yStride, uv: uv, uvStride: uvStride,
                width: Int(width), height: Int(height), latencyMs: latencyMs)
}
