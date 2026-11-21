import OSLog
import Metal
import Observation
import SwiftUI

/// Ties the device, the settings, and the renderer together, and owns the one
/// rule that keeps the UI honest: hot settings stream to the camera instantly,
/// cold ones (resolution/fps) need the Myriad rebooted, so we make the user ask.
@Observable
@MainActor
final class CameraModel {

    let device = OpalDevice()
    let settings = CameraSettings()
    private(set) var renderer: BokehRenderer?

    /// Virtual camera: system-extension installer and the sink feeder. The
    /// feeder polls for the device — the extension may activate minutes after
    /// install, or already be running from a previous launch.
    let installer = ExtensionInstaller()
    let autoLaunch = AutoLaunchController()
    let feeder = VirtualCameraFeeder()
    private var feederPollStarted = false
    private var isStarting = false

    /// The freshest rendered texture, handed to the preview each vsync.
    private(set) var latestTexture: MTLTexture?

    /// What the mask costs, in milliseconds. Shown in the status pill — in sync
    /// mode this is latency you actually feel, so it shouldn't be a mystery.
    var maskMs: Double { renderer?.matteProvider?.lastMs ?? 0 }

    var isRebooting = false

    /// Freeze the preview's draw loop. Manual (⌘⇧F), or automatically for the
    /// half-second a panel animation runs.
    ///
    /// Why: the glass panels are composited by the system, and glass re-blurs
    /// whatever sits behind it. Behind ours is video changing every 33ms — so
    /// during a panel animation the compositor is re-rendering moving backdrops
    /// over moving content at animation rate, off in WindowServer where our
    /// process profiles as idle. Freezing the video for the duration of the
    /// spring makes the backdrop static and that whole cost collapses.
    var previewFrozen = false
    private(set) var animationHold = false
    var previewPaused: Bool { previewFrozen || animationHold }

    private var holdGeneration = 0
    func holdPreviewDuringAnimation(_ duration: Double = 0.6) {
        animationHold = true
        holdGeneration += 1
        let gen = holdGeneration
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            if gen == holdGeneration { animationHold = false }
        }
    }

    /// Caps concurrent frames at the mask provider's lane count — more would
    /// just block on a lane anyway. Lock-based because the frame callback runs
    /// on the capture thread, not the main actor.
    private let gate = FrameGate(max: 3)

    /// Where each frame's time goes, written to the log every few seconds.
    private let stats = PipelineStats()

    /// Frames finish out of order when several are in flight, so we track arrival
    /// order and refuse to present a frame older than one already on screen.
    private var nextSequence = 0
    private var presentedSequence = -1

    /// Last AE region we sent, so we only re-meter when the subject genuinely
    /// moves. Re-sending on every analysis pass would flood the control queue and
    /// make auto-exposure visibly pump.
    private var lastMeteredRect: CGRect?

    func start() async {
        // A launch request can reopen the window while a previous window task
        // is still booting the camera. There must only be one USB open in flight.
        guard !isStarting, !isRebooting, !device.state.isLive else { return }
        isStarting = true
        defer { isStarting = false }

        if renderer == nil, let r = BokehRenderer() {
            if let mtl = MTLCreateSystemDefaultDevice() {
                // The depth model is loaded lazily — it's 50MB and, in the default
                // uniform-blur mode, never runs at all.
                r.matteProvider = MatteProvider(device: mtl)
            }
            r.onSubject = { [weak self] subject in
                Task { @MainActor in
                    self?.meter(on: subject)
                }
            }
            renderer = r
        }

        device.onFrame = { [weak self] pixelBuffer, _ in
            // Called on the capture thread — and the work STAYS off the main
            // actor. This whole pipeline (analysis + five Metal pass encodes)
            // used to hop onto the main actor for every frame, 30 times a
            // second, which meant every SwiftUI animation had to fight the
            // camera for main-thread time — panel springs ran like a slideshow
            // while the video played smoothly. The main actor now does exactly
            // two tiny things per frame: hand out a settings snapshot, and
            // receive the finished texture.
            //
            // Concurrency is bounded (frames beyond the cap are DROPPED, not
            // queued — a queue turns latency into lag), and in-flight frames can
            // finish out of order, so each is stamped on arrival and an older
            // frame never replaces a newer one on screen.
            guard let self else { return }
            let arrived = CFAbsoluteTimeGetCurrent()
            guard self.gate.tryEnter() else {
                self.stats.dropped()
                return
            }
            let frame = FrameBox(buffer: pixelBuffer)

            Task.detached(priority: .userInitiated) {
                defer { self.gate.exit() }

                guard let work = await MainActor.run(body: { () -> (BokehRenderer, RenderSettings, Int)? in
                    guard let renderer = self.renderer else { return nil }
                    self.syncRenderer()
                    let seq = self.nextSequence
                    self.nextSequence += 1
                    return (renderer, RenderSettings(self.settings), seq)
                }) else { return }
                let (renderer, snapshot, seq) = work

                if snapshot.bokehEnabled && snapshot.syncBokeh {
                    // Analyse THIS frame and wait. Costs latency, buys a mask
                    // that lines up with the pixels we're about to blur.
                    await renderer.analyzeNow(pixelBuffer: frame.buffer,
                                              needsDepth: !snapshot.uniformBlur)
                }
                let analysed = CFAbsoluteTimeGetCurrent()

                let texture = TexBox(t: renderer.render(pixelBuffer: frame.buffer,
                                                        settings: snapshot))

                // Feed the virtual camera the exact frame the preview shows —
                // processed, un-mirrored. Off-main, like everything else here.
                if let t = texture.t, self.feeder.connected,
                   let pb = renderer.exportFrame(t) {
                    self.feeder.send(pb)
                }

                let rendered = CFAbsoluteTimeGetCurrent()
                await MainActor.run {
                    if seq >= self.presentedSequence {
                        self.presentedSequence = seq
                        self.latestTexture = texture.t
                    }
                }
                self.stats.shown(waitMs: (analysed - arrived) * 1000,
                                 renderMs: (rendered - analysed) * 1000,
                                 totalMs: (CFAbsoluteTimeGetCurrent() - arrived) * 1000,
                                 maskMs: renderer.matteProvider?.lastMs ?? 0,
                                 depthMs: renderer.depthMs)
            }
        }

        if !feederPollStarted {
            feederPollStarted = true
            Task { [feeder] in
                while true {
                    feeder.connectIfNeeded()
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }

        await device.connect(settings: settings)
    }

    func stop() { device.shutdown() }

    func reconnect() async {
        guard !isStarting, !isRebooting else { return }
        // A fresh pipeline starts in the chosen focus mode, so no click is held.
        focusHeld = false
        isRebooting = true
        defer { isRebooting = false }
        device.disconnect()
        await device.connect(settings: settings)
    }

    /// Send hot settings to the camera. Cheap — safe to call on every slider tick.
    /// The bridge coalesces and diffs, so nothing here blocks on USB.
    func push() {
        device.apply(settings, holdingFocus: focusHeld)
    }

    /// True after a click on the picture: the lens focused there and is holding.
    /// It is not saved. A click used to rewrite the saved focus mode to
    /// one-shot, so one click turned continuous autofocus off for good.
    private(set) var focusHeld = false

    /// Give the lens back to whichever focus mode is chosen.
    func resumeAutofocus() {
        focusHeld = false
        push()
    }

    /// Bring the renderer in line with the settings: mask quality, and whether the
    /// depth model needs to exist at all.
    func syncRenderer() {
        guard let renderer else { return }
        renderer.matteProvider?.setQuality(settings.matteQuality)

        let needsDepth = settings.bokehEnabled && !settings.uniformBlur
        // A saved choice of Depth Pro 2 only counts while the model is on disk.
        let wanted: CameraSettings.DepthModel =
            settings.depthModel == .depthPro2 && depthPro2.isInstalled ? .depthPro2 : .depthAnythingV2
        if needsDepth, renderer.depthProvider == nil || loadedDepthModel != wanted,
           let mtl = MTLCreateSystemDefaultDevice() {
            renderer.depthProvider = Self.makeDepthSource(wanted, device: mtl)
            loadedDepthModel = wanted
        }
    }

    /// The optional Depth Pro 2 model: downloading it, and whether it is here.
    let depthPro2 = DepthPro2Installer()

    /// The model the current depth provider was built for, so that changing the
    /// picker, or installing or deleting Depth Pro 2, swaps it.
    private var loadedDepthModel: CameraSettings.DepthModel?

    /// Depth Pro 2 needs macOS 15, and a downloaded model can still fail to load.
    /// Either way, fall back to Depth Anything so the blur still works.
    private static func makeDepthSource(_ model: CameraSettings.DepthModel,
                                        device: MTLDevice) -> (any DepthSource)? {
        if model == .depthPro2, #available(macOS 15.0, *),
           let provider = DepthPro2Provider(device: device) {
            return provider
        }
        return DepthProvider(device: device)
    }

    /// Click-to-focus. Also aims exposure at that spot, and stands the automatic
    /// subject metering down for a few seconds — otherwise the next analysis pass
    /// would immediately yank the exposure region back onto the person and the
    /// click would appear to do nothing.
    func focus(at sensorPoint: CGPoint) {
        device.focus(at: sensorPoint)
        // The device drops into one-shot AF so the focus holds. Remember that
        // here, so later pushes keep the hold and the panel can offer to end it.
        focusHeld = true
        meteringSuspendedUntil = Date().addingTimeInterval(5)
        lastMeteredRect = nil
    }

    private var meteringSuspendedUntil: Date?

    /// Point auto-exposure at the person. Only fires when they've actually moved,
    /// and only while AE is doing the deciding.
    private func meter(on subject: SubjectInfo) {
        guard settings.meterOnSubject, settings.autoExposure, device.state.isLive else { return }
        if let until = meteringSuspendedUntil, Date() < until { return }

        // Meter on the upper-middle of the subject's box — that's where a face
        // lives. Metering the full body drags in a lot of torso and desk.
        let b = subject.bounds
        let rect = CGRect(x: b.minX + b.width * 0.2,
                          y: b.minY,
                          width: b.width * 0.6,
                          height: max(b.height * 0.45, 0.05))

        if let last = lastMeteredRect {
            // Dead-band: ignore small shifts, or AE hunts every time you breathe.
            let moved = abs(rect.midX - last.midX) + abs(rect.midY - last.midY)
                      + abs(rect.width - last.width) + abs(rect.height - last.height)
            guard moved > 0.06 else { return }
        }
        lastMeteredRect = rect
        device.meterExposure(on: rect)
    }

    /// Cold settings changed; reboot the pipeline to pick them up.
    func applyColdChanges() async {
        guard !isStarting, !isRebooting else { return }
        isRebooting = true
        defer { isRebooting = false }
        await device.rebuildPipeline(settings: settings)
    }
}

/// Lock-based in-flight counter, usable from the capture thread.
private final class FrameGate: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let max: Int

    init(max: Int) { self.max = max }

    func tryEnter() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard count < max else { return false }
        count += 1
        return true
    }
    func exit() { lock.lock(); count -= 1; lock.unlock() }
}

/// Counts frames and times the stages each one passes through, and writes a
/// line to the log every few seconds:
///
///     log stream --predicate 'subsystem == "com.openopal" && category == "perf"'
///
/// The status line's fps and latency come from the camera, so they say nothing
/// about frames this app dropped or how long it held them. This does.
private final class PipelineStats: @unchecked Sendable {
    private let log = Logger(subsystem: "com.openopal", category: "perf")
    private let lock = NSLock()
    private var since = CFAbsoluteTimeGetCurrent()
    private var shownCount = 0, droppedCount = 0
    private var wait = 0.0, render = 0.0, total = 0.0, worst = 0.0

    func dropped() {
        lock.withLock { droppedCount += 1 }
    }

    func shown(waitMs: Double, renderMs: Double, totalMs: Double, maskMs: Double, depthMs: Double) {
        lock.lock(); defer { lock.unlock() }
        shownCount += 1
        wait += waitMs; render += renderMs; total += totalMs
        worst = max(worst, totalMs)

        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - since
        guard elapsed >= 3 else { return }
        let n = Double(shownCount)
        log.notice("""
            shown \(n / elapsed, format: .fixed(precision: 1)) fps, \
            dropped \(Double(self.droppedCount) / elapsed, format: .fixed(precision: 1)) fps, \
            in app \(self.total / n, format: .fixed(precision: 0)) ms \
            (worst \(self.worst, format: .fixed(precision: 0)), \
            waiting for mask \(self.wait / n, format: .fixed(precision: 0)), \
            render and present \(self.render / n, format: .fixed(precision: 0))), \
            one mask \(maskMs, format: .fixed(precision: 0)) ms, \
            one depth map \(depthMs, format: .fixed(precision: 0)) ms
            """)
        since = now
        shownCount = 0; droppedCount = 0
        wait = 0; render = 0; total = 0; worst = 0
    }
}

/// CVPixelBuffer / MTLTexture aren't Sendable, but these specific instances are
/// safe to move: the pixel buffer is pool-owned with no other writer, and the
/// texture is only read after the render that produced it completes.
private struct FrameBox: @unchecked Sendable { let buffer: CVPixelBuffer }
private struct TexBox: @unchecked Sendable { let t: MTLTexture? }
