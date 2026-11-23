import OSLog
import Metal
import Observation
import SwiftUI

private let assistLog = Logger(subsystem: "com.openopal", category: "device")

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

    init() {
        device.onDisconnect = { [weak self] in
            self?.resetCaptureTracking()
        }
    }

    /// Retain the backing pixel buffer while the preview reads its texture.
    private(set) var latestFrame: RenderedFrame?

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

    /// Caps frames in flight at the mask provider's lane count. More would just
    /// wait for a lane, and a frame past the cap is dropped, not queued. The
    /// gate also turns away frames from a camera session that has ended.
    private let gate = FrameGate(max: 3)

    /// Where each frame's time goes, written to the log every few seconds.
    private let stats = PipelineStats()

    /// Frames finish out of order when several are in flight, so we track arrival
    /// order and refuse to present a frame older than one already on screen.
    private var nextSequence = 0
    private var presentedSequence = -1

    /// Exposure history and tap holds are scoped to the capture pipeline.
    private var meteringSession = SubjectMeteringSession()
    private var captureGeneration: UInt64 = 0

    private func resetCaptureTracking() {
        captureGeneration = gate.invalidate()
        latestFrame = nil
        meteringSession.reset()
        assist = LowLightAssist()
        renderer?.resetCaptureState()
        configureSubjectTracking()
        configureFrameDelivery()
    }

    private func configureSubjectTracking() {
        guard let renderer else { return }
        let generation = captureGeneration
        renderer.onSubject = { [weak self, weak renderer] subject, analysisGeneration in
            Task { @MainActor [weak self, weak renderer] in
                guard let self, let renderer,
                      self.captureGeneration == generation,
                      renderer.isCurrentAnalysisGeneration(analysisGeneration) else { return }
                self.meter(on: subject)
            }
        }
    }

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
            renderer = r
            configureSubjectTracking()
        }

        configureFrameDelivery()

        if !feederPollStarted {
            feederPollStarted = true
            // The feeder's poll below reconnects within a few seconds.
            installer.onActivated = { [feeder] in feeder.disconnect() }
            installer.onWillReplace = { [feeder] in feeder.disconnect() }
            installer.updateIfOutdated()
            Task { [feeder, installer] in
                while true {
                    // Leave the old extension alone while it is being replaced.
                    if installer.status != .installing { feeder.connectIfNeeded() }
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }

        await device.connect(settings: settings)
    }

    private func configureFrameDelivery() {
        let generation = captureGeneration
        let rendererGeneration = renderer?.captureGeneration
        device.onFrame = { [weak self] pixelBuffer, _ in
            // Called on the capture thread, and the work stays off the main
            // actor. The main actor does two small things per frame: hand out a
            // settings snapshot, and receive the finished frame.
            //
            // Each device pipeline retains this immutable generation.
            guard let self, let rendererGeneration else { return }
            let arrived = CFAbsoluteTimeGetCurrent()
            if self.assistClock.due(every: 0.5), let stats = SceneSampler.sample(pixelBuffer) {
                Task { @MainActor in
                    guard self.captureGeneration == generation, self.device.state.isLive else { return }
                    self.help(with: stats)
                }
            }
            guard self.gate.tryEnter(generation: generation) else {
                self.stats.dropped()
                return
            }
            let input = FrameBox(buffer: pixelBuffer)

            Task.detached(priority: .userInitiated) {
                defer { self.gate.exit() }
                guard let work = await MainActor.run(body: { () -> (BokehRenderer, RenderSettings, Int)? in
                    guard self.captureGeneration == generation, self.device.state.isLive,
                          let renderer = self.renderer else { return nil }
                    self.syncRenderer()
                    let seq = self.nextSequence
                    self.nextSequence += 1
                    var snapshot = RenderSettings(self.settings)
                    snapshot.exposureGain = Float(self.assist.gain)
                    snapshot.tint = SIMD3<Float>(self.assist.tint)
                    return (renderer, snapshot, seq)
                }) else { return }
                let (renderer, snapshot, seq) = work
                var analysisForFrame: BokehRenderer.FrameAnalysis?

                if snapshot.bokehEnabled && snapshot.syncBokeh {
                    guard self.gate.isCurrent(generation) else { return }
                    // Analyse THIS frame and wait, up to a deadline. Costs
                    // latency, buys a mask that lines up with the pixels we're
                    // about to blur.
                    analysisForFrame = await renderer.analyzeNow(pixelBuffer: input.buffer,
                                                                needsDepth: !snapshot.uniformBlur,
                                                                captureGeneration: rendererGeneration)
                }
                let analysed = CFAbsoluteTimeGetCurrent()

                guard self.gate.isCurrent(generation),
                      let frame = renderer.render(pixelBuffer: input.buffer,
                                                  settings: snapshot,
                                                  captureGeneration: rendererGeneration,
                                                  analysisForFrame: analysisForFrame) else { return }
                guard self.gate.isCurrent(generation) else { return }
                // Feed the virtual camera the exact frame the preview shows:
                // processed, un-mirrored. Only while a video app has the camera
                // open: see wantsFrames.
                if self.feeder.wantsFrames {
                    self.feeder.send(frame.pixelBuffer)
                }
                let rendered = CFAbsoluteTimeGetCurrent()

                await MainActor.run {
                    guard self.captureGeneration == generation, self.device.state.isLive else { return }
                    if seq >= self.presentedSequence {
                        self.presentedSequence = seq
                        self.latestFrame = frame
                    }
                }
                self.stats.shown(waitMs: (analysed - arrived) * 1000,
                                 renderMs: (rendered - analysed) * 1000,
                                 totalMs: (CFAbsoluteTimeGetCurrent() - arrived) * 1000,
                                 maskMs: renderer.matteProvider?.lastMs ?? 0,
                                 depthMs: renderer.depthMs)
            }
        }
    }

    func stop() { device.shutdown() }

    func reconnect() async {
        guard !isStarting, !isRebooting, !device.isConnecting else { return }
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
        device.apply(settings, holdingFocus: focusHeld, whiteBalanceK: assist.whiteBalanceK)
    }

    /// Steps in when the camera's auto exposure or white balance is stuck.
    /// Readable so the status area can list everything it is doing.
    private(set) var assist = LowLightAssist()
    private let assistClock = SampleClock()
    private var assistLoggedAt = Date.distantPast

    private func help(with stats: SceneStats) {
        let before = assist.whiteBalanceK
        defer { if assist.whiteBalanceK != before { push() } }
        guard settings.lowLightHelp else {
            assist = LowLightAssist()
            return
        }
        assist.update(stats,
                      iso: device.telemetry.iso,
                      reportedK: device.telemetry.colorTempK,
                      autoExposure: settings.autoExposure && !settings.aeLock,
                      autoWhiteBalance: !settings.manualWhiteBalance && settings.awbMode == .auto
                          && !settings.awbLock)
        let now = Date()
        if now.timeIntervalSince(assistLoggedAt) >= 5 {
            assistLoggedAt = now
            let tint = assist.tint
            assistLog.info("picture brightness \(stats.luma, format: .fixed(precision: 2)), red over blue \(stats.redOverBlue ?? 0, format: .fixed(precision: 2)). low light help: brightness x\(self.assist.gain, format: .fixed(precision: 1)), red x\(tint.x, format: .fixed(precision: 2)), green x\(tint.y, format: .fixed(precision: 2)), blue x\(tint.z, format: .fixed(precision: 2)), camera white balance \(self.assist.whiteBalanceK.map { "set to \($0) K" } ?? "left on auto", privacy: .public)")
        }
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
        meteringSession.suspend(until: Date().addingTimeInterval(5))
    }

    /// Point auto-exposure at the person. Only fires when they've actually moved,
    /// and only while AE is doing the deciding.
    private func meter(on subject: SubjectInfo) {
        guard settings.meterOnSubject, settings.autoExposure, device.state.isLive else { return }
        guard let rect = meteringSession.region(for: subject.bounds, at: Date()) else { return }
        device.meterExposure(on: rect)
    }

    /// Cold settings changed; reboot the pipeline to pick them up.
    func applyColdChanges() async {
        guard !isStarting, !isRebooting, !device.isConnecting else { return }
        isRebooting = true
        defer { isRebooting = false }
        await device.rebuildPipeline(settings: settings)
    }
}

/// Lock-based in-flight counter, usable from the capture thread.
private final class FrameGate: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var generation: UInt64 = 0
    private let max: Int

    init(max: Int) { self.max = max }

    func tryEnter(generation token: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard token == generation, count < max else { return false }
        count += 1
        return true
    }
    func invalidate() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        generation += 1
        return generation
    }
    func isCurrent(_ token: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return token == generation
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

/// The input buffer is pool-owned and has no other writer.
private struct FrameBox: @unchecked Sendable { let buffer: CVPixelBuffer }
