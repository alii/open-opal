// The virtual camera, as dumb as possible — deliberately.
//
// This extension knows nothing about the Opal C1, depthai, or Metal. It is a
// pipe with a splash screen: one device exposing a SOURCE stream (what Zoom,
// FaceTime, and friends capture from) and a SINK stream (what the Open Opal app
// pushes finished frames into). Frames entering the sink are forwarded to the
// source untouched. When nothing is feeding the sink, a pre-rendered splash
// card plays so the camera never shows garbage in a picker.
//
// All the intelligence — device control, bokeh, exposure — stays in the app,
// which can be updated without reinstalling a system extension.

import CoreGraphics
import CoreMedia
import CoreMediaIO
import CoreText
import CoreVideo
import Foundation
import IOKit.audio
import os.log

private let log = OSLog(subsystem: "com.openopal.camera", category: "extension")

// Fixed identity: apps remember cameras by unique ID, so these must never change.
let kSourceStreamUUID = UUID(uuidString: "7E671FBA-4A0A-4B0A-8F5D-3A1A1B4DE6F3")!
let kSinkStreamUUID = UUID(uuidString: "7E671FBA-4A0A-4B0A-8F5D-3A1A1B4DE6F4")!

let kWidth = 1920
let kHeight = 1080
let kFrameRate = 30

// MARK: - Provider

final class CameraProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: CameraDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        let queue = DispatchQueue(label: "com.openopal.camera.clients", target: clientQueue)
        provider = CMIOExtensionProvider(source: self, clientQueue: queue)
        deviceSource = CameraDeviceSource(clientQueue: queue)
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            os_log(.error, log: log, "addDevice failed: %{public}@", "\(error)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {
        deviceSource.sinkStreamSource.disconnect(client)
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.providerManufacturer, .providerName]
    }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionProviderProperties {
        let p = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerName) { p.name = "Open Opal" }
        if properties.contains(.providerManufacturer) { p.manufacturer = "Open Opal" }
        return p
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}

// MARK: - Device

final class CameraDeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!

    private var sourceStream: CMIOExtensionStream!
    private var sinkStream: CMIOExtensionStream!
    fileprivate var sourceStreamSource: SourceStreamSource!
    fileprivate var sinkStreamSource: SinkStreamSource!
    fileprivate let clientQueue: DispatchQueue

    private let format: CMIOExtensionStreamFormat
    private let videoDescription: CMFormatDescription

    // Splash machinery
    private let splashQueue = DispatchQueue(label: "com.openopal.camera.splash")
    private var splashTimer: DispatchSourceTimer?
    private var splashBuffer: CVPixelBuffer?

    /// Host time of the last frame the app pushed into the sink. If this goes
    /// stale, the splash takes over — so a Zoom call shows a tidy card, not a
    /// frozen last frame, when the app quits mid-call.
    private let stateLock = NSLock()
    private var lastSinkFrameAt: CFAbsoluteTime = 0
    private var streamingCounter = 0

    init(clientQueue: DispatchQueue) {
        self.clientQueue = clientQueue
        var desc: CMFormatDescription!
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32BGRA,
            width: Int32(kWidth), height: Int32(kHeight),
            extensions: nil, formatDescriptionOut: &desc)
        videoDescription = desc
        format = CMIOExtensionStreamFormat(
            formatDescription: desc,
            maxFrameDuration: CMTime(value: 1, timescale: Int32(kFrameRate)),
            minFrameDuration: CMTime(value: 1, timescale: Int32(kFrameRate)),
            validFrameDurations: nil)

        super.init()

        device = CMIOExtensionDevice(localizedName: "Open Opal Camera",
                                     deviceID: CameraDemand.deviceUUID,
                                     legacyDeviceID: nil,
                                     source: self)

        sourceStreamSource = SourceStreamSource(format: format, device: self)
        sinkStreamSource = SinkStreamSource(format: format, device: self)
        sourceStream = CMIOExtensionStream(localizedName: "Open Opal Camera",
                                           streamID: kSourceStreamUUID,
                                           direction: .source,
                                           clockType: .hostTime,
                                           source: sourceStreamSource)
        sinkStream = CMIOExtensionStream(localizedName: "Open Opal Sink",
                                         streamID: kSinkStreamUUID,
                                         direction: .sink,
                                         clockType: .hostTime,
                                         source: sinkStreamSource)
        do {
            try device.addStream(sourceStream)
            try device.addStream(sinkStream)
        } catch {
            os_log(.error, log: log, "addStream failed: %{public}@", "\(error)")
        }

        splashBuffer = SplashCard.render(width: kWidth, height: kHeight)
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionDeviceProperties {
        let p = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            p.transportType = kIOAudioDeviceTransportTypeVirtual
        }
        if properties.contains(.deviceModel) {
            p.model = "Open Opal Virtual Camera"
        }
        return p
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    // MARK: Frame flow

    /// Called by the sink when the app delivers a frame: forward it verbatim.
    func forwardToSource(_ sbuf: CMSampleBuffer) {
        stateLock.lock()
        lastSinkFrameAt = CFAbsoluteTimeGetCurrent()
        let streaming = streamingCounter > 0
        stateLock.unlock()
        guard streaming else { return }

        sourceStream.send(sbuf,
                          discontinuity: [],
                          hostTimeInNanoseconds: UInt64(sbuf.presentationTimeStamp.seconds * 1e9))
    }

    func startedStreaming() {
        stateLock.lock()
        streamingCounter += 1
        let first = streamingCounter == 1
        stateLock.unlock()
        if first {
            startSplashTimer()
            sourceStream.notifyPropertiesChanged([
                CameraDemand.property: CameraDemand.propertyState(isActive: true)
            ])
        }
    }

    func stoppedStreaming() {
        stateLock.lock()
        let wasStreaming = streamingCounter > 0
        streamingCounter = max(0, streamingCounter - 1)
        let last = wasStreaming && streamingCounter == 0
        stateLock.unlock()
        if last {
            stopSplashTimer()
            sourceStream.notifyPropertiesChanged([
                CameraDemand.property: CameraDemand.propertyState(isActive: false)
            ])
        }
    }

    fileprivate var hasCaptureClients: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return streamingCounter > 0
    }

    /// 30Hz heartbeat: if the app hasn't fed the sink recently, serve the splash
    /// card so client apps always have something sane to show.
    private func startSplashTimer() {
        let timer = DispatchSource.makeTimerSource(queue: splashQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / Double(kFrameRate))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let appFeeding = CFAbsoluteTimeGetCurrent() - self.lastSinkFrameAt < 1.0
            self.stateLock.unlock()
            guard !appFeeding, let pb = self.splashBuffer else { return }

            var timing = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: Int32(kFrameRate)),
                presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                decodeTimeStamp: .invalid)
            var sbuf: CMSampleBuffer?
            CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pb,
                formatDescription: self.videoDescription,
                sampleTiming: &timing,
                sampleBufferOut: &sbuf)
            if let sbuf {
                self.sourceStream.send(
                    sbuf, discontinuity: [],
                    hostTimeInNanoseconds: UInt64(timing.presentationTimeStamp.seconds * 1e9))
            }
        }
        timer.resume()
        splashTimer = timer
    }

    private func stopSplashTimer() {
        splashTimer?.cancel()
        splashTimer = nil
    }
}

// MARK: - Source stream (what Zoom sees)

fileprivate final class SourceStreamSource: NSObject, CMIOExtensionStreamSource {
    private let format: CMIOExtensionStreamFormat
    private unowned let deviceSource: CameraDeviceSource

    init(format: CMIOExtensionStreamFormat, device: CameraDeviceSource) {
        self.format = format
        self.deviceSource = device
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }
    var activeFormatIndex = 0

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration, CameraDemand.property]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionStreamProperties {
        let p = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { p.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) {
            p.frameDuration = CMTime(value: 1, timescale: Int32(kFrameRate))
        }
        if properties.contains(CameraDemand.property) {
            p.setPropertyState(CameraDemand.propertyState(isActive: deviceSource.hasCaptureClients),
                               forProperty: CameraDemand.property)
        }
        return p
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws { deviceSource.startedStreaming() }
    func stopStream() throws { deviceSource.stoppedStreaming() }
}

// MARK: - Sink stream (what the app feeds)

fileprivate final class SinkStreamSource: NSObject, CMIOExtensionStreamSource, @unchecked Sendable {
    private let format: CMIOExtensionStreamFormat
    private unowned let deviceSource: CameraDeviceSource
    private var client: CMIOExtensionClient?
    private let authorizer = SinkClientAuthorizer()
    private var isStreaming = false

    private struct ReceivedSample: @unchecked Sendable {
        let buffer: CMSampleBuffer?
    }

    init(format: CMIOExtensionStreamFormat, device: CameraDeviceSource) {
        self.format = format
        self.deviceSource = device
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }
    var activeFormatIndex = 0

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration, .streamSinkBufferQueueSize,
         .streamSinkBuffersRequiredForStartup, .streamSinkBufferUnderrunCount,
         .streamSinkEndOfData]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionStreamProperties {
        let p = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { p.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) {
            p.frameDuration = CMTime(value: 1, timescale: Int32(kFrameRate))
        }
        if properties.contains(.streamSinkBufferQueueSize) { p.sinkBufferQueueSize = 4 }
        if properties.contains(.streamSinkBuffersRequiredForStartup) {
            p.sinkBuffersRequiredForStartup = 1
        }
        return p
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        guard authorizer?.isAuthorized(signingID: client.signingID, pid: client.pid) == true,
              self.client == nil || self.client?.clientID == client.clientID else { return false }
        self.client = client
        return true
    }

    func startStream() throws {
        guard let client, !isStreaming else { return }
        isStreaming = true
        consumeNext(from: client)
    }

    func stopStream() throws {
        isStreaming = false
        client = nil
    }

    func disconnect(_ disconnectedClient: CMIOExtensionClient) {
        guard client?.clientID == disconnectedClient.clientID else { return }
        isStreaming = false
        client = nil
    }

    private func consumeNext(from client: CMIOExtensionClient) {
        guard let stream = deviceSource.sinkStreamValue else { return }
        let clientID = client.clientID
        let queue = deviceSource.clientQueue
        stream.consumeSampleBuffer(from: client) { [weak self] sample, sequence, _, _, error in
            let received = ReceivedSample(buffer: sample)
            let succeeded = error == nil
            queue.async { [weak self] in
                guard let self, self.isStreaming,
                      let currentClient = self.client, currentClient.clientID == clientID else { return }
                guard succeeded else {
                    self.isStreaming = false
                    self.client = nil
                    return
                }
                if let sample = received.buffer,
                   let hostTime = self.deviceSource.forwardToSource(sample) {
                    self.deviceSource.sinkStreamValue?.notifyScheduledOutputChanged(
                        CMIOExtensionScheduledOutput(sequenceNumber: sequence,
                                                     hostTimeInNanoseconds: hostTime))
                }
                self.consumeNext(from: currentClient)
            }
        }
    }
}

extension CameraDeviceSource {

    fileprivate var sinkStreamValue: CMIOExtensionStream? {
        device.streams.first { $0.streamID == kSinkStreamUUID }
    }
}
