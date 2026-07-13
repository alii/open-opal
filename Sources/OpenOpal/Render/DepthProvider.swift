import Accelerate
import CoreML
import CoreVideo
import Metal
import OSLog
import Vision

private let log = Logger(subsystem: "com.openopal", category: "depth")

/// Monocular depth via Apple's Core ML build of Depth Anything V2 (Small, F16),
/// running on the Neural Engine.
///
/// This is the piece Opal didn't have. Their bokeh came from a small
/// segmentation network on the camera's Myriad VPU, which can only answer
/// "person or not person" — so a chair one metre behind you and a wall six
/// metres behind you were blurred by exactly the same amount. That flatness is
/// what reads as fake. A continuous depth map lets blur fall off with real
/// distance, which is what a lens actually does.
///
/// Two details matter when consuming this model:
///
///  1. It outputs **inverse** depth (disparity): larger = *closer*. The renderer
///     wants 0 = near, 1 = far, so we invert.
///  2. The output carries no metric scale, and the model min-max normalizes it
///     *internally, per frame* — every frame spans exactly 0...1 regardless of
///     what's in it. So when you lift a hand toward the lens, the far wall's
///     value changes even though the wall didn't move. That's "depth swim", and
///     it cannot be fixed here: rescaling a range that's already [0,1] is a
///     no-op. It's dealt with downstream, by temporal smoothing in the shader.
final class DepthProvider: @unchecked Sendable {

    private let device: MTLDevice
    private let model: VNCoreMLModel
    private let request: VNCoreMLRequest

    private var texture: MTLTexture?
    private var scratch: [Float] = []

    init?(device: MTLDevice) {
        self.device = device

        guard let url = Bundle.main.url(forResource: "DepthAnythingV2SmallF16",
                                        withExtension: "mlmodelc") else {
            log.error("depth model not found in bundle — run scripts/fetch-models.sh")
            return nil
        }

        let config = MLModelConfiguration()
        // Measured on an M4 Max: GPU 14ms, ANE 24ms, .all 17ms. The GPU is the
        // fastest single accelerator, but it's also the one running our Metal
        // passes, and we'd rather not have depth inference contend with the
        // render loop for it. .all lets Core ML spread the graph across both and
        // still clears the 33ms frame budget comfortably.
        config.computeUnits = .all

        do {
            let mlModel = try MLModel(contentsOf: url, configuration: config)
            model = try VNCoreMLModel(for: mlModel)
        } catch {
            log.error("depth model load failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        request = VNCoreMLRequest(model: model)
        // The model wants 518x392. Fill (rather than fit) so we don't hand it
        // letterboxed bars, which it would happily assign a depth to.
        request.imageCropAndScaleOption = .scaleFill
    }

    /// Depth map, plus the values on the CPU so we can find where the subject
    /// actually is (see SubjectAnalysis).
    struct Result {
        let texture: MTLTexture
        let values: [Float]     // 0 = near, 1 = far
        let width: Int
        let height: Int
    }

    /// Kept alive across frames — see MatteProvider for why this matters.
    private let sequence = VNSequenceRequestHandler()

    /// The previous *aligned* depth frame, which the next one is fitted to.
    private var previous: [Float] = []

    func depth(from pixelBuffer: CVPixelBuffer) async -> Result? {
        do {
            try sequence.perform([request], on: pixelBuffer)
        } catch {
            log.error("depth inference failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let obs = request.results?.first as? VNPixelBufferObservation else { return nil }
        return normalizeAndUpload(obs.pixelBuffer)
    }

    /// Fit this frame onto the previous one with a single scale and shift.
    ///
    /// This is the actual cure for "depth swim". Depth Anything V2 is a
    /// single-image model that min-max normalizes its output *internally, per
    /// frame*: every frame spans exactly 0...1 no matter what's in it. So lift a
    /// hand toward the lens and it becomes the new "nearest thing" — which
    /// silently rescales the ENTIRE scene, and the far wall's depth value changes
    /// even though the wall didn't move. The whole room appears to breathe in and
    /// out of focus.
    ///
    /// Smoothing can only blunt that; it can't fix it, because the signal itself
    /// is wrong. Instead, solve for the (a, b) that best maps this frame onto the
    /// previous one — least squares, closed form — and apply it. Depths then live
    /// in a consistent, continuous space across frames, which is exactly the
    /// property the model doesn't give us.
    private func align(_ current: inout [Float]) {
        guard previous.count == current.count, !current.isEmpty else { return }

        var meanCur: Float = 0, meanPrev: Float = 0
        vDSP_meanv(current, 1, &meanCur, vDSP_Length(current.count))
        vDSP_meanv(previous, 1, &meanPrev, vDSP_Length(previous.count))

        // a = cov(cur, prev) / var(cur)
        var dotCP: Float = 0, dotCC: Float = 0
        vDSP_dotpr(current, 1, previous, 1, &dotCP, vDSP_Length(current.count))
        vDSP_dotpr(current, 1, current, 1, &dotCC, vDSP_Length(current.count))
        let n = Float(current.count)
        let cov = dotCP / n - meanCur * meanPrev
        let varCur = dotCC / n - meanCur * meanCur
        guard varCur > 1e-6 else { return }

        // Clamp hard. A wild fit (someone walks in, the scene genuinely changes)
        // should nudge the mapping, not throw the scene into a different universe.
        var a = min(max(cov / varCur, 0.6), 1.6)
        var b = meanPrev - a * meanCur

        // Ease into the new fit so a sudden scene change doesn't snap everything.
        a = smoothedScale + 0.25 * (a - smoothedScale)
        b = smoothedShift + 0.25 * (b - smoothedShift)
        smoothedScale = a
        smoothedShift = b

        vDSP_vsmsa(current, 1, &a, &b, &current, 1, vDSP_Length(current.count))
        // Keep it in range; the fit can push a few pixels outside 0...1.
        var lo: Float = 0, hi: Float = 1
        vDSP_vclip(current, 1, &lo, &hi, &current, 1, vDSP_Length(current.count))
    }

    private var smoothedScale: Float = 1
    private var smoothedShift: Float = 0

    /// Half-float disparity -> normalized, inverted, GPU-resident depth.
    private func normalizeAndUpload(_ buffer: CVPixelBuffer) -> Result? {
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        let count = w * h

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }

        if scratch.count != count { scratch = [Float](repeating: 0, count: count) }

        // The model emits 16-bit half floats; Accelerate converts the whole
        // plane in one pass. This runs on the analysis task, never the render
        // loop, so a fraction of a millisecond here is free.
        var src = vImage_Buffer(data: base, height: vImagePixelCount(h),
                                width: vImagePixelCount(w),
                                rowBytes: CVPixelBufferGetBytesPerRow(buffer))
        var ok = true
        scratch.withUnsafeMutableBufferPointer { dst in
            var out = vImage_Buffer(data: dst.baseAddress, height: vImagePixelCount(h),
                                    width: vImagePixelCount(w), rowBytes: w * MemoryLayout<Float>.size)
            if vImageConvert_Planar16FtoPlanarF(&src, &out, 0) != kvImageNoError { ok = false }
        }
        guard ok else { return nil }

        // The model already delivers 0...1 with larger = closer, so all that's
        // left is the flip to 0 = near, 1 = far:  out = -v + 1
        var scale: Float = -1
        var bias: Float = 1
        vDSP_vsmsa(scratch, 1, &scale, &bias, &scratch, 1, vDSP_Length(count))

        // Put this frame into the same depth space as the last one.
        align(&scratch)
        previous = scratch

        if texture == nil || texture!.width != w || texture!.height != h {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r32Float, width: w, height: h, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            texture = device.makeTexture(descriptor: d)
        }
        guard let texture else { return nil }

        scratch.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, w, h),
                            mipmapLevel: 0,
                            withBytes: raw.baseAddress!,
                            bytesPerRow: w * MemoryLayout<Float>.size)
        }
        return Result(texture: texture, values: scratch, width: w, height: h)
    }
}
