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

    /// Handed a fresh NV12 frame on the capture thread's behalf, already wrapped
    /// in an IOSurface-backed CVPixelBuffer ready for Metal.
    var onFrame: (@Sendable (CVPixelBuffer, Double) -> Void)?

    private var handle: OpaquePointer?
    private var pool: CVPixelBufferPool?
    private var poolSize = (w: 0, h: 0)
    private var telemetryTimer: Timer?

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

    func connect(settings: CameraSettings) async {
        guard handle == nil else { return }

        state = .searching
        let devices = discover()
        guard let target = devices.first(where: { $0.usable }) else {
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

        // opal_open boots the Myriad and blocks for a couple of seconds, so keep
        // it off the main actor or the whole UI stalls mid-connect.
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let mxid = target.mxid
        let opened: OpaquePointer? = await Task.detached(priority: .userInitiated) {
            mxid.withCString { opal_open($0, cfg, opalFrameTrampoline, ctx) }
        }.value

        guard let opened else {
            let msg = String(cString: opal_last_error())
            log.error("open failed: \(msg, privacy: .public)")
            state = .failed(msg.isEmpty ? "Could not open the camera." : msg)
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
        pool = nil
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

    /// Tap-to-focus: point the AF and AE metering at a spot in the frame.
    func focus(at point: CGPoint, boxSize: CGFloat = 0.18) {
        guard let handle else { return }
        let half = boxSize / 2
        opal_set_focus_region(handle,
                              Float(max(0, min(1 - boxSize, point.x - half))),
                              Float(max(0, min(1 - boxSize, point.y - half))),
                              Float(boxSize), Float(boxSize))
    }

    // MARK: - Frames

    /// Called on the bridge's capture thread. Copies the NV12 planes into an
    /// IOSurface-backed CVPixelBuffer — the one copy in the whole path. From
    /// here the data goes to Metal as two textures with no color conversion,
    /// and on to the virtual camera without ever touching the CPU again.
    nonisolated func ingest(y: UnsafePointer<UInt8>, yStride: Int,
                            uv: UnsafePointer<UInt8>, uvStride: Int,
                            width: Int, height: Int, latencyMs: Double) {
        guard let pb = MainActor.assumeIsolated({ pixelBuffer(width: width, height: height) })
        else { return }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        if let dstY = CVPixelBufferGetBaseAddressOfPlane(pb, 0) {
            let dstStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            for row in 0..<height {
                memcpy(dstY.advanced(by: row * dstStride), y.advanced(by: row * yStride), width)
            }
        }
        if let dstUV = CVPixelBufferGetBaseAddressOfPlane(pb, 1) {
            let dstStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
            for row in 0..<(height / 2) {
                memcpy(dstUV.advanced(by: row * dstStride), uv.advanced(by: row * uvStride), width)
            }
        }

        onFrame?(pb, latencyMs)
    }

    private func pixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if pool == nil || poolSize != (width, height) {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                // IOSurface-backed so Metal (and later the camera extension) can
                // read the same memory without another copy.
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary,
                                    attrs as CFDictionary, &p)
            pool = p
            poolSize = (width, height)
        }
        guard let pool else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        return pb
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

/// C callback -> Swift. `ctx` is the unretained OpalDevice; it outlives every
/// frame because opal_close() joins the capture thread before the device is
/// torn down.
private func opalFrameTrampoline(y: UnsafePointer<UInt8>?, yStride: Int,
                                 uv: UnsafePointer<UInt8>?, uvStride: Int,
                                 width: Int32, height: Int32,
                                 hostTimeNs: Int64, latencyMs: Double,
                                 ctx: UnsafeMutableRawPointer?) {
    guard let y, let uv, let ctx else { return }
    let device = Unmanaged<OpalDevice>.fromOpaque(ctx).takeUnretainedValue()
    device.ingest(y: y, yStride: yStride, uv: uv, uvStride: uvStride,
                  width: Int(width), height: Int(height), latencyMs: latencyMs)
}
