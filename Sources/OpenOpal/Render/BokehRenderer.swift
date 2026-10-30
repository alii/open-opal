import CoreVideo
import Metal
import MetalKit
import OSLog
import simd

private let log = Logger(subsystem: "com.openopal", category: "render")

/// The GPU side of the frame path.
///
/// A frame arrives as NV12 in an IOSurface-backed CVPixelBuffer and is turned
/// into Metal textures via CVMetalTextureCache — no copy, no CPU colour
/// conversion. From there:
///
///     NV12 ──► linear RGB ──► [depth + matte] ──► CoC ──► gather ──► composite
///
/// Asynchronous analysis supplies the latest current result without stalling.
/// Synchronous callers wait for analysis paired with the exact input frame.
///
/// A value snapshot of everything the render path needs from CameraSettings.
///
/// The renderer must not read the live @Observable settings object: rendering
/// runs OFF the main actor (encoding Metal on the main thread 30x/sec was
/// starving SwiftUI animations into a slideshow), and the settings object is
/// main-actor state. Main takes this snapshot in microseconds; the render
/// worker gets an immutable copy it can read from any thread.
struct RenderSettings: Sendable {
    var bokehEnabled: Bool
    var syncBokeh: Bool
    var uniformBlur: Bool
    var meterOnSubject: Bool
    var autoFocusSubject: Bool
    var focusOnSubject: Bool
    var focusDistance: Double
    var aperture: Double
    var hexIris: Bool
    var highlightBloom: Double

    @MainActor
    init(_ s: CameraSettings) {
        bokehEnabled = s.bokehEnabled
        syncBokeh = s.syncBokeh
        uniformBlur = s.uniformBlur
        meterOnSubject = s.meterOnSubject
        autoFocusSubject = s.autoFocusSubject
        // Focus tracking consumes the same subject analysis, so it has to be in
        // the snapshot too — otherwise "Follow face" silently does nothing
        // whenever bokeh and subject metering are both off.
        focusOnSubject = s.focusOnSubject
        focusDistance = s.focusDistance
        aperture = s.aperture
        hexIris = s.apertureShape == .hexagonal
        highlightBloom = s.highlightBloom
    }
}

/// Published pixels stay owned by preview and virtual-camera consumers.
struct RenderedFrame: @unchecked Sendable {
    let texture: MTLTexture
    let pixelBuffer: CVPixelBuffer
    fileprivate let backing: CVMetalTexture
}

/// `@unchecked Sendable`: render() serializes itself with a lock, the analysis
/// path is lock-guarded (AnalysisStore), and the providers are Sendable.
final class BokehRenderer: @unchecked Sendable {

    /// Serializes render() — with several frames in flight, two could otherwise
    /// race on the shared intermediate textures.
    private let renderLock = NSLock()

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var textureCache: CVMetalTextureCache!

    private let nv12Pipeline: MTLComputePipelineState
    private let cocPipeline: MTLComputePipelineState
    private let gatherPipeline: MTLComputePipelineState
    private let compositePipeline: MTLComputePipelineState
    private let smoothPipeline: MTLComputePipelineState
    private let depthSmoothPipeline: MTLComputePipelineState
    private let matteRefinePipeline: MTLComputePipelineState
    private let matteStabilizePipeline: MTLComputePipelineState

    // Intermediates, reallocated only when the frame size changes.
    private var linearTex: MTLTexture?
    private var cocTex: MTLTexture?
    private var blurTex: MTLTexture?
    private var depthTex: MTLTexture?
    private var matteTex: MTLTexture?
    // Ping-pong: depth_smooth reads one and writes the other, because it now
    // samples neighbours (and reading + writing the same texture in one dispatch
    // is undefined).
    private var depthHistory: MTLTexture?
    private var depthHistoryPrev: MTLTexture?
    private var matteHistory: MTLTexture?
    private var matteHistoryPrev: MTLTexture?
    /// Last frame's luma, at mask resolution. Lets us ask "did the picture change
    /// here?" — which is how we tell a genuinely moving subject apart from a
    /// static object whose mask is merely flickering.
    private var prevLuma: MTLTexture?
    private var prevLumaNext: MTLTexture?
    /// The matte after the guided upsample — full resolution, edges snapped to
    /// the image. This is the one everything downstream actually uses.
    private var matteRefined: MTLTexture?
    private var size = (w: 0, h: 0)
    private var historyReady = false
    private var historyGeneration: UInt64?
    private var historyUsesDepth = false

    /// Latest neural results, written by the analysis task and read by the
    /// render loop. Never blocks the render loop.
    private let analysis = AnalysisStore()

    struct Uniforms {
        var texelSize: SIMD2<Float>
        var focusDepth: Float
        var aperture: Float
        var maxCoCPixels: Float
        var highlightBloom: Float
        var highlightThresh: Float
        var apertureBlades: Int32
        var matteStrength: Float
        var useDepth: Int32
    }

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue

        guard let library = device.makeDefaultLibrary() else {
            log.error("no default Metal library")
            return nil
        }

        func pipeline(_ name: String) -> MTLComputePipelineState? {
            guard let fn = library.makeFunction(name: name) else {
                log.error("missing kernel \(name, privacy: .public)")
                return nil
            }
            return try? device.makeComputePipelineState(function: fn)
        }

        guard let a = pipeline("nv12_to_linear"),
              let b = pipeline("compute_coc"),
              let c = pipeline("bokeh_gather"),
              let d = pipeline("composite"),
              let e = pipeline("temporal_smooth"),
              let f = pipeline("depth_smooth"),
              let g = pipeline("matte_refine"),
              let i = pipeline("matte_stabilize") else { return nil }

        nv12Pipeline = a; cocPipeline = b; gatherPipeline = c
        compositePipeline = d; smoothPipeline = e; depthSmoothPipeline = f
        matteRefinePipeline = g; matteStabilizePipeline = i

        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
    }

    // MARK: - Analysis handoff

    /// Frame-paired results never pass through the asynchronous latest-value box.
    struct FrameAnalysis: @unchecked Sendable {
        let pixelBuffer: CVPixelBuffer
        let generation: UInt64
        let depth: DepthProvider.Result?
        let matte: MatteResult?
        let subject: SubjectInfo?
    }

    /// Latest results retain their leases. Generations fence earlier modes and
    /// capture sessions without canceling running Vision requests.
    final class AnalysisStore: @unchecked Sendable {
        private let lock = NSLock()
        private var _depth: DepthProvider.Result?
        private var _matte: MatteResult?
        private var _matteBusy = false
        private var _depthBusy = false
        private var _subject: SubjectInfo?
        private var generation: UInt64 = 0
        private var captureGeneration: UInt64 = 0
        private var synchronous = false

        func setSynchronous(_ enabled: Bool, captureGeneration expected: UInt64) -> UInt64? {
            lock.withLock {
                guard expected == captureGeneration else { return nil }
                if synchronous != enabled {
                    synchronous = enabled
                    invalidate()
                }
                return generation
            }
        }

        var currentCaptureGeneration: UInt64 {
            lock.withLock { captureGeneration }
        }

        func reset() -> UInt64 {
            lock.withLock {
                captureGeneration &+= 1
                invalidate()
                return generation
            }
        }

        private func invalidate() {
            generation &+= 1
            _depth = nil
            _matte = nil
            _subject = nil
        }

        func isCurrent(_ token: UInt64) -> Bool {
            lock.withLock { token == generation }
        }

        // Reset must not free a lane while its old pass is still running.
        func tryBeginMatte() -> UInt64? {
            lock.withLock {
                guard !synchronous, !_matteBusy else { return nil }
                _matteBusy = true
                return generation
            }
        }
        func endMatte() { lock.withLock { _matteBusy = false } }

        func tryBeginDepth() -> UInt64? {
            lock.withLock {
                guard !synchronous, !_depthBusy else { return nil }
                _depthBusy = true
                return generation
            }
        }
        func endDepth() { lock.withLock { _depthBusy = false } }

        func publishDepth(_ depth: DepthProvider.Result, generation token: UInt64) {
            lock.withLock {
                guard token == generation, !synchronous else { return }
                _depth = depth
            }
        }

        func depthValues() -> ([Float], Int, Int) {
            lock.withLock { (_depth?.values ?? [], _depth?.width ?? 0, _depth?.height ?? 0) }
        }

        func publishMatte(_ matte: MatteResult, subject: SubjectInfo?,
                          generation token: UInt64) -> SubjectInfo? {
            lock.withLock {
                guard token == generation, !synchronous else { return nil }
                _matte = matte
                return updateSubject(subject)
            }
        }

        func publishSynchronousSubject(_ subject: SubjectInfo?,
                                       generation token: UInt64) -> SubjectInfo? {
            lock.withLock {
                guard token == generation, synchronous else { return nil }
                return updateSubject(subject)
            }
        }

        private func updateSubject(_ subject: SubjectInfo?) -> SubjectInfo? {
            guard let subject else { return nil }
            if var previous = _subject {
                previous.depth += 0.15 * (subject.depth - previous.depth)
                previous.bounds = subject.bounds
                previous.coverage = subject.coverage
                _subject = previous
            } else {
                _subject = subject
            }
            return _subject
        }

        func latest() -> (DepthProvider.Result?, MatteResult?, SubjectInfo?) {
            lock.withLock { (_depth, _matte, _subject) }
        }
    }

    /// CVPixelBuffer isn't Sendable, but this one is safe to hand to the analysis
    /// task: it came from a pool, nothing else holds it, and the neural providers
    /// only read it.
    private struct BufferBox: @unchecked Sendable {
        let buffer: CVPixelBuffer
    }

    var depthProvider: DepthProvider?
    var matteProvider: MatteProvider?

    // MARK: - Frame

    /// Completion is awaited on the render worker, never on the main actor.
    /// Nil drops a frame rather than publishing incomplete or recycled pixels.
    func render(pixelBuffer: CVPixelBuffer, settings: RenderSettings,
                captureGeneration: UInt64, analysisForFrame: FrameAnalysis? = nil) -> RenderedFrame? {
        renderLock.lock()
        defer { renderLock.unlock() }
        let syncing = settings.bokehEnabled && settings.syncBokeh
        guard let generation = analysis.setSynchronous(syncing, captureGeneration: captureGeneration)
        else { return nil }
        if syncing {
            guard let analysisForFrame,
                  analysisForFrame.pixelBuffer === pixelBuffer,
                  analysisForFrame.generation == generation else { return nil }
        }
        if historyGeneration != generation || historyUsesDepth != !settings.uniformBlur {
            historyReady = false
            historyGeneration = generation
            historyUsesDepth = !settings.uniformBlur
        }

        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        guard let luma = makeTexture(pixelBuffer, plane: 0, format: .r8Unorm),
              let chroma = makeTexture(pixelBuffer, plane: 1, format: .rg8Unorm) else { return nil }
        if size != (w, h) { allocate(w: w, h: h) }
        guard let linearTex, let output = makeOutputFrame(w: w, h: h),
              let cmd = queue.makeCommandBuffer() else { return nil }

        guard encode(cmd, nv12Pipeline, textures: [luma.texture, chroma.texture, linearTex],
                     size: (w, h)) else { return nil }
        if !syncing && (settings.bokehEnabled || settings.meterOnSubject || settings.focusOnSubject) {
            kickOffAnalysisIfIdle(pixelBuffer: pixelBuffer,
                                  needsDepth: settings.bokehEnabled && !settings.uniformBlur)
        }

        var compositeBlur = linearTex
        var compositeCoC = blackTexture()
        var updatedHistory = false
        let latest = syncing
            ? (analysisForFrame?.depth, analysisForFrame?.matte, analysisForFrame?.subject)
            : analysis.latest()
        let depth = latest.0?.texture
        let matte = latest.1?.texture
        let u = uniforms(settings, subject: latest.2, w: w, h: h)
        if settings.bokehEnabled, let matte, let cocTex, let blurTex,
           let depthHistory, let depthHistoryPrev, let matteHistory,
           let matteHistoryPrev, let matteRefined,
           let depth = depth ?? (settings.uniformBlur ? blackTexture() : nil) {
            var matteAlpha: Float = historyReady ? 0.6 : 1
            guard encode(cmd, smoothPipeline,
                         textures: [matte, historyReady ? matteHistory : blackTexture(), matteHistoryPrev],
                         buffer: &matteAlpha, size: (matteHistoryPrev.width, matteHistoryPrev.height)),
                  encode(cmd, matteRefinePipeline,
                         textures: [matteHistoryPrev, linearTex, matteRefined], size: (w, h)) else { return nil }
            var depthAlpha: Float = historyReady ? 0.35 : 1
            guard encode(cmd, depthSmoothPipeline,
                         textures: [depth, matteRefined, historyReady ? depthHistory : blackTexture(), depthHistoryPrev],
                         buffer: &depthAlpha, size: (depthHistory.width, depthHistory.height)),
                  encode(cmd, cocPipeline, textures: [depthHistoryPrev, matteRefined, cocTex],
                         uniforms: u, size: (w, h)),
                  encode(cmd, gatherPipeline, textures: [linearTex, cocTex, blurTex],
                         uniforms: u, size: (w, h)) else { return nil }
            updatedHistory = true
            compositeBlur = blurTex
            compositeCoC = cocTex
        }
        guard encode(cmd, compositePipeline,
                     textures: [linearTex, compositeBlur, compositeCoC, output.texture],
                     uniforms: u, size: (w, h)) else { return nil }

        // Retain source wrappers, owned output, and analysis leases until GPU completion.
        withExtendedLifetime((pixelBuffer, luma, chroma, output, latest, analysisForFrame)) {
            cmd.commit()
            cmd.waitUntilCompleted()
        }
        guard cmd.status == .completed else {
            log.error("frame render failed: \(cmd.error?.localizedDescription ?? "unknown GPU error", privacy: .public)")
            return nil
        }
        if updatedHistory {
            swap(&self.depthHistory, &self.depthHistoryPrev)
            swap(&self.matteHistory, &self.matteHistoryPrev)
            historyReady = true
        } else {
            historyReady = false
        }
        return output
    }

    /// Reject work from the previous capture and reset stateful inference.
    func resetCaptureState() {
        renderLock.withLock {
            let generation = analysis.reset()
            depthProvider?.reset(generation: generation)
            matteProvider?.reset(generation: generation)
            historyReady = false
            historyGeneration = nil
            frameIndex = 0
        }
    }

    func isCurrentAnalysisGeneration(_ generation: UInt64) -> Bool {
        analysis.isCurrent(generation)
    }

    var captureGeneration: UInt64 { analysis.currentCaptureGeneration }

    /// Runs depth + segmentation off the render path. If a previous pass is
    /// still in flight we simply skip this frame — the render loop keeps using
    /// the last good result, so frame rate never depends on inference speed.
    /// How often to re-run depth, in frames.
    ///
    /// Was 6 (~5Hz) on the theory that "the background doesn't move". That's only
    /// half true — the *subject* is in the depth map too, and running depth this
    /// slowly meant the geometry revealed behind a moving person took a third of
    /// a second to appear. Now ~15Hz, with the background-masked history
    /// (depth_smooth) doing the real work of killing the trail.
    private static let depthInterval = 2
    private var frameIndex = 0

    private func kickOffAnalysisIfIdle(pixelBuffer: CVPixelBuffer, needsDepth: Bool) {
        let box = BufferBox(buffer: pixelBuffer)
        let store = analysis
        let onSubject = self.onSubject

        frameIndex &+= 1

        // --- segmentation: every frame. It's what tracks you. ---
        if let matteProvider, let generation = store.tryBeginMatte() {
            Task.detached(priority: .userInitiated) {
                defer { store.endMatte() }
                if let m = await matteProvider.matte(from: box.buffer, generation: generation) {
                    let (values, dw, dh) = store.depthValues()
                    let subject: SubjectInfo? = values.isEmpty
                        ? SubjectAnalysis.locate(matte: m)
                        : SubjectAnalysis.analyze(matte: m, depth: values,
                                                  depthWidth: dw, depthHeight: dh)
                    if let subject = store.publishMatte(m, subject: subject, generation: generation),
                       store.isCurrent(generation) {
                        onSubject?(subject, generation)
                    }
                }
            }
        }

        // --- depth: occasionally, and only when bokeh actually needs it. ---
        guard needsDepth, let depthProvider else { return }
        guard frameIndex % Self.depthInterval == 0,
              let generation = store.tryBeginDepth() else { return }

        Task.detached(priority: .userInitiated) {
            defer { store.endDepth() }
            if let d = await depthProvider.depth(from: box.buffer, generation: generation) {
                store.publishDepth(d, generation: generation)
            }
        }
    }

    /// Fired whenever we get a fresh read on the subject. CameraModel uses it to
    /// meter exposure on the person rather than the whole frame.
    private let callbackLock = NSLock()
    private var _onSubject: (@Sendable (SubjectInfo, UInt64) -> Void)?
    var onSubject: (@Sendable (SubjectInfo, UInt64) -> Void)? {
        get { callbackLock.withLock { _onSubject } }
        set { callbackLock.withLock { _onSubject = newValue } }
    }

    /// Compute the mask (and optionally depth) for THIS frame, and wait for it.
    ///
    /// Costs latency, buys exact alignment: the mask describes the frame we're
    /// about to composite, not one from 60ms ago. This is the whole point of
    /// "sync" mode — the trailing edge is a synchronisation problem, not a
    /// filtering one.
    func analyzeNow(pixelBuffer: CVPixelBuffer, needsDepth: Bool,
                    captureGeneration: UInt64) async -> FrameAnalysis? {
        guard let generation = analysis.setSynchronous(true, captureGeneration: captureGeneration)
        else { return nil }
        let box = BufferBox(buffer: pixelBuffer)
        let onSubject = self.onSubject
        async let matteTask = matteProvider?.matte(from: box.buffer, generation: generation)
        async let depthTask = needsDepth ? depthProvider?.depth(from: box.buffer, generation: generation) : nil
        let (matte, depth) = await (matteTask, depthTask)
        guard analysis.isCurrent(generation) else { return nil }

        let subject = matte.flatMap { matte in
            if let depth {
                return SubjectAnalysis.analyze(matte: matte, depth: depth.values,
                                               depthWidth: depth.width, depthHeight: depth.height)
            }
            return SubjectAnalysis.locate(matte: matte)
        }
        let smoothed = analysis.publishSynchronousSubject(subject, generation: generation)
        if let smoothed, analysis.isCurrent(generation) {
            onSubject?(smoothed, generation)
        }
        return FrameAnalysis(pixelBuffer: pixelBuffer, generation: generation,
                             depth: depth, matte: matte, subject: smoothed)
    }

    // MARK: - Owned frame output

    private var outputPool: CVPixelBufferPool?
    private var outputSize = (w: 0, h: 0)
    private let outputAllocationOptions = [
        kCVPixelBufferPoolAllocationThresholdKey as String: 6
    ] as CFDictionary
    private let outputTextureAttributes = [
        kCVMetalTextureUsage as String: MTLTextureUsage.shaderRead.union(.shaderWrite).rawValue
    ] as CFDictionary

    private func makeOutputFrame(w: Int, h: Int) -> RenderedFrame? {
        if outputPool == nil || outputSize != (w, h) {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            var pool: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool) == kCVReturnSuccess
            else { return nil }
            outputPool = pool
            outputSize = (w, h)
        }
        guard let outputPool else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            nil, outputPool, outputAllocationOptions, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        var backing: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, buffer, outputTextureAttributes, .bgra8Unorm,
            w, h, 0, &backing) == kCVReturnSuccess,
              let backing, let texture = CVMetalTextureGetTexture(backing) else { return nil }
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        return RenderedFrame(texture: texture, pixelBuffer: buffer, backing: backing)
    }

    // MARK: - Plumbing

    private func uniforms(_ s: RenderSettings, subject: SubjectInfo?, w: Int, h: Int) -> Uniforms {
        // Scale the blur with resolution so f/2.8 looks the same at 720p as at
        // 4K, instead of getting weaker as pixels get smaller.
        let maxCoC = Float(h) * 0.025

        // THE focal plane. With "track subject" on, this is the subject's own
        // median depth — so blur is measured as distance from *you*. It used to
        // be the UI's fixed 0.35 no matter where you actually were, which meant
        // "track subject" tracked precisely nothing and the blur was measuring
        // distance from an arbitrary plane in space.
        let focus: Float = s.autoFocusSubject
            ? (subject?.depth ?? Float(s.focusDistance))
            : Float(s.focusDistance)

        return Uniforms(
            texelSize: SIMD2(1.0 / Float(w), 1.0 / Float(h)),
            focusDepth: focus,
            aperture: Float(s.aperture),
            maxCoCPixels: maxCoC,
            highlightBloom: Float(s.highlightBloom),
            highlightThresh: 0.75,
            apertureBlades: s.hexIris ? 6 : 0,
            matteStrength: s.autoFocusSubject ? 0.9 : 0.0,
            useDepth: s.uniformBlur ? 0 : 1
        )
    }

    private struct PlaneTexture {
        let backing: CVMetalTexture
        let texture: MTLTexture
    }

    private func makeTexture(_ pb: CVPixelBuffer, plane: Int,
                             format: MTLPixelFormat) -> PlaneTexture? {
        let w = CVPixelBufferGetWidthOfPlane(pb, plane)
        let h = CVPixelBufferGetHeightOfPlane(pb, plane)
        guard w > 0, h > 0 else { return nil }
        var cvTex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pb, nil, format, w, h, plane, &cvTex)
        guard status == kCVReturnSuccess, let cvTex,
              let texture = CVMetalTextureGetTexture(cvTex) else { return nil }
        return PlaneTexture(backing: cvTex, texture: texture)
    }

    private func allocate(w: Int, h: Int) {
        size = (w, h)
        historyReady = false
        func make(_ fmt: MTLPixelFormat, _ tw: Int, _ th: Int) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: fmt, width: tw, height: th, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        // Half-float: we're working in linear light, where 8 bits banding is
        // very visible in smooth out-of-focus gradients.
        linearTex = make(.rgba16Float, w, h)
        blurTex   = make(.rgba16Float, w, h)
        cocTex    = make(.r16Float, w, h)

        // Depth Anything V2 has a FIXED 518x392 output — not square, and not
        // resizable. Match it exactly or the history won't line up.
        depthHistory = make(.r16Float, 518, 392)
        depthHistoryPrev = make(.r16Float, 518, 392)

        // The matte gets a higher-resolution history than the depth map. It's
        // what defines the visible edge around you — hair, shoulders, the gap
        // under your chin — and squeezing it down to the depth model's grid threw
        // away exactly the detail that makes the cutout look convincing.
        let mw = min(w, 960), mh = min(h, 540)
        matteHistory     = make(.r16Float, mw, mh)
        matteHistoryPrev = make(.r16Float, mw, mh)
        prevLuma         = make(.r16Float, mw, mh)
        prevLumaNext     = make(.r16Float, mw, mh)
        matteRefined     = make(.r16Float, w, h)
        log.info("allocated \(w)x\(h)")
    }

    private var _black: MTLTexture?
    private func blackTexture() -> MTLTexture {
        if let _black { return _black }
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Float, width: 1, height: 1, mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = .shared
        let t = device.makeTexture(descriptor: d)!
        var zero: UInt16 = 0
        t.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                  withBytes: &zero, bytesPerRow: MemoryLayout<UInt16>.stride)
        _black = t
        return t
    }

    private func encode(_ cmd: MTLCommandBuffer, _ pipeline: MTLComputePipelineState,
                        textures: [MTLTexture], uniforms: Uniforms? = nil,
                        buffer: UnsafeMutableRawPointer? = nil,
                        bufferLength: Int = MemoryLayout<Float>.stride,
                        size: (w: Int, h: Int)) -> Bool {
        guard let enc = cmd.makeComputeCommandEncoder() else { return false }
        enc.setComputePipelineState(pipeline)
        for (i, t) in textures.enumerated() { enc.setTexture(t, index: i) }
        if var u = uniforms {
            enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        } else if let buffer {
            enc.setBytes(buffer, length: bufferLength, index: 0)
        }
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(width: (size.w + 15) / 16,
                             height: (size.h + 15) / 16, depth: 1)
        enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
        enc.endEncoding()
        return true
    }
}
