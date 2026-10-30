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

    /// Drop rather than queue while analysis, render, and publication are in flight.
    private let gate = FrameGate(max: 1)

    /// Sequence numbers keep publication monotonic across asynchronous handoffs.
    private var nextSequence = 0
    private var presentedSequence = -1

    /// Exposure history and tap holds are scoped to the capture pipeline.
    private var meteringSession = SubjectMeteringSession()
    private var lastFocusArea: CGFloat?
    private var focusCooldownUntil: Date?
    private var captureGeneration: UInt64 = 0

    private func resetCaptureTracking() {
        captureGeneration = gate.invalidate()
        latestFrame = nil
        resetFocusTracking()
        meteringSession.reset()
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
                self.focusOnSubject(subject)
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
            Task { [feeder] in
                while true {
                    feeder.connectIfNeeded()
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
            // Each device pipeline retains this immutable generation.
            guard let self, let rendererGeneration,
                  self.gate.tryEnter(generation: generation) else { return }
            let input = FrameBox(buffer: pixelBuffer)

            Task.detached(priority: .userInitiated) {
                defer { self.gate.exit() }
                guard let work = await MainActor.run(body: { () -> (BokehRenderer, RenderSettings, Int)? in
                    guard self.captureGeneration == generation, self.device.state.isLive,
                          let renderer = self.renderer else { return nil }
                    self.syncRenderer()
                    let seq = self.nextSequence
                    self.nextSequence += 1
                    return (renderer, RenderSettings(self.settings), seq)
                }) else { return }
                let (renderer, snapshot, seq) = work
                var analysisForFrame: BokehRenderer.FrameAnalysis?

                if snapshot.bokehEnabled && snapshot.syncBokeh {
                    guard self.gate.isCurrent(generation) else { return }
                    analysisForFrame = await renderer.analyzeNow(pixelBuffer: input.buffer,
                                                                needsDepth: !snapshot.uniformBlur,
                                                                captureGeneration: rendererGeneration)
                }

                guard self.gate.isCurrent(generation),
                      let frame = renderer.render(pixelBuffer: input.buffer,
                                                  settings: snapshot,
                                                  captureGeneration: rendererGeneration,
                                                  analysisForFrame: analysisForFrame) else { return }
                guard self.gate.isCurrent(generation) else { return }
                if self.feeder.connected {
                    self.feeder.send(frame.pixelBuffer)
                }

                await MainActor.run {
                    guard self.captureGeneration == generation, self.device.state.isLive else { return }
                    if seq >= self.presentedSequence {
                        self.presentedSequence = seq
                        self.latestFrame = frame
                    }
                }
            }
        }
    }

    func stop() { device.shutdown() }

    func reconnect() async {
        guard !isStarting, !isRebooting, !device.isConnecting else { return }
        isRebooting = true
        defer { isRebooting = false }
        device.disconnect()
        await device.connect(settings: settings)
    }

    /// Send hot settings to the camera. Cheap — safe to call on every slider tick.
    /// The bridge coalesces and diffs, so nothing here blocks on USB.
    func push() {
        // Clear immediately, even if manual focus is turned off again before
        // the next subject analysis arrives.
        if settings.manualFocus { resetFocusTracking() }
        device.apply(settings)
    }

    /// Bring the renderer in line with the settings: mask quality, and whether the
    /// depth model needs to exist at all.
    func syncRenderer() {
        guard let renderer else { return }
        renderer.matteProvider?.setQuality(settings.matteQuality)

        let needsDepth = settings.bokehEnabled && !settings.uniformBlur
        if needsDepth, renderer.depthProvider == nil,
           let mtl = MTLCreateSystemDefaultDevice() {
            renderer.depthProvider = DepthProvider(device: mtl)
        }
    }

    /// Click-to-focus. Also aims exposure at that spot, and stands the automatic
    /// subject metering down for a few seconds — otherwise the next analysis pass
    /// would immediately yank the exposure region back onto the person and the
    /// click would appear to do nothing.
    func focus(at sensorPoint: CGPoint) {
        device.focus(at: sensorPoint)
        // The device drops into one-shot AF so the focus holds; reflect that in
        // the UI rather than leaving the picker lying about the mode.
        settings.afMode = .auto
        meteringSession.suspend(until: Date().addingTimeInterval(5))
    }

    /// Point auto-exposure at the person. Only fires when they've actually moved,
    /// and only while AE is doing the deciding.
    private func meter(on subject: SubjectInfo) {
        guard settings.meterOnSubject, settings.autoExposure, device.state.isLive else { return }
        guard let rect = meteringSession.region(for: subject.bounds, at: Date()) else { return }
        device.meterExposure(on: rect)
    }

    /// Refocus on the subject, following the strategy the camera's own vendor
    /// firmware uses.
    ///
    /// The interesting part is what it does *not* do. Continuous AF re-decides
    /// constantly and visibly hunts, so this is one-shot AUTO aimed at the face
    /// box — and it only re-triggers when the face's *area* changes by more
    /// than 40%, which is to say when you actually moved toward or away from
    /// the lens. Someone walking past behind you does not shift your face box
    /// enough to qualify, so the lens stays put. That hysteresis is why vendor
    /// autofocus feels settled where continuous AF does not.
    ///
    /// The one-second cooldown mirrors the sleep the firmware takes after each
    /// trigger, so refocuses cannot chain.
    private func focusOnSubject(_ subject: SubjectInfo) {
        guard settings.focusOnSubject, device.state.isLive else { return }

        // While the lens is being driven by hand, drop the history: otherwise
        // handing it back to autofocus with the subject unchanged compares
        // against a stale area and skips the first trigger.
        guard !settings.manualFocus else {
            resetFocusTracking()
            return
        }
        if let until = focusCooldownUntil, Date() < until { return }

        // Caveat worth stating plainly: `bounds` is the segmentation's person
        // box, not a face box. The upper-middle crop below is a stand-in for
        // where a face sits within a person, which holds for one person facing
        // the camera and degrades otherwise — a raised arm can grow the box,
        // and with two people the crop can land between them.
        //
        // The vendor firmware runs a real face detector and applies the
        // hysteresis to an actual face. Doing the same here needs Vision face
        // detection wired into the analysis pass; until then, coverage is
        // checked so a tiny or fragmented mask cannot drive the lens.
        guard subject.coverage > 0.05 else { return }

        let b = subject.bounds
        let face = CGRect(x: b.minX + b.width * 0.2,
                          y: b.minY,
                          width: b.width * 0.6,
                          height: max(b.height * 0.45, 0.05))

        let area = face.width * face.height
        guard area > 0 else { return }

        if let last = lastFocusArea, last > 0 {
            guard abs(area / last - 1.0) > 0.4 else { return }
        }

        lastFocusArea = area
        focusCooldownUntil = Date().addingTimeInterval(1)
        device.focus(on: face)

        // The bridge just switched the lens to one-shot AUTO. Unless the
        // setting follows, the next push of any unrelated control — sharpness,
        // say — sees afMode still reading Continuous, treats it as a change and
        // restores continuous hunting, undoing the hold. Tap-to-focus already
        // does this; automatic tracking has to as well.
        settings.afMode = .auto
    }

    /// Forget where focus last landed.
    ///
    /// The hysteresis compares against the last focused area, so a stale value
    /// suppresses the first trigger after the situation has changed: reconnect
    /// with the subject the same size and nothing fires, and the same happens
    /// after driving the lens by hand and handing it back to autofocus.
    func resetFocusTracking() {
        lastFocusArea = nil
        focusCooldownUntil = nil
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

/// The input buffer is pool-owned and has no other writer.
private struct FrameBox: @unchecked Sendable { let buffer: CVPixelBuffer }
