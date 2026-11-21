import Accelerate
import CoreML
import CoreVideo
import Foundation
import Metal
import OSLog

private let log = Logger(subsystem: "com.openopal", category: "depth")

/// Where the optional Depth Pro 2 model lives, and whether this Mac can run it.
enum DepthPro2 {
    /// The small model with a four-frame window, from
    /// https://huggingface.co/apple/DepthPro2-coreml. Fetched only on request,
    /// by `scripts/fetch-models.sh --depth-pro-2`: its weights are under Apple's
    /// research-only model licence, so normal builds do not carry them.
    static let resourceName = "depthpro2-s_w4"

    static var bundledModelURL: URL? {
        Bundle.main.url(forResource: resourceName, withExtension: "mlmodelc")
    }

    /// The model keeps its memory of past frames in Core ML state, which needs
    /// macOS 15.
    static var isAvailable: Bool {
        if #available(macOS 15.0, *) { return bundledModelURL != nil }
        return false
    }
}

/// Monocular depth from Apple's Depth Pro 2, as an alternative to Depth Anything
/// V2 that we can compare side by side.
///
/// Two things make it worth trying:
///
///  1. It looks at the last few frames as well as this one, so its depth is
///     steady from frame to frame.
///  2. Its output has a real scale. A wall three metres away gets the same value
///     in every frame, whatever else is in the shot. Depth Anything rescales
///     every frame to 0...1, which is the "depth swim" `DepthProvider.align`
///     exists to hide. Nothing here needs aligning.
@available(macOS 15.0, *)
final class DepthPro2Provider: DepthSource, @unchecked Sendable {

    /// The model ships one function per input size. Measured on an M4 Max with
    /// the small model: 640x360 takes 14ms on the GPU and 854x480 takes 27ms.
    /// The Neural Engine takes 47ms and 182ms, so it is not an option. 640x360
    /// costs about what Depth Anything does, and the depth map is blurred and
    /// upsampled downstream anyway.
    private static let function = "res_640x360"

    /// The inverse depth that maps to "nearest". The model's output is
    /// `focal length in frame widths / metres`, and the C1's lens is about 0.7
    /// frame widths, so 1.5 is roughly 0.5m. Anything closer reads as nearest.
    ///
    /// This is fixed on purpose. Scaling by what is in the frame would bring the
    /// swim straight back.
    private static let nearestInverseDepth: Float = 1.5

    /// A gap this long means the camera stopped or depth was turned off, so the
    /// frames the model remembers no longer describe the scene.
    private static let staleAfter: TimeInterval = 1

    private let device: MTLDevice
    private let model: MLModel
    private let width: Int
    private let height: Int

    private let input: MLMultiArray
    private let features: MLDictionaryFeatureProvider

    /// One prediction at a time. The state holds the frames before this one, and
    /// Core ML does not allow two predictions to share it at once.
    private let lock = NSLock()
    private var state: MLState
    private var lastRun = Date.distantPast

    private var texture: MTLTexture?
    private var scratch: [Float] = []

    // Scratch planes for turning NV12 into the planar RGB the model wants.
    private var lumaSmall: vImage_Buffer
    private var chromaSmall: vImage_Buffer
    private var argb: vImage_Buffer
    private var planes: [vImage_Buffer]
    private var videoRange = vImage_YpCbCrToARGB()
    private var fullRange = vImage_YpCbCrToARGB()

    init?(device: MTLDevice, modelURL: URL? = DepthPro2.bundledModelURL) {
        self.device = device

        guard let modelURL else {
            log.error("Depth Pro 2 not found in bundle — run scripts/fetch-models.sh --depth-pro-2")
            return nil
        }

        let config = MLModelConfiguration()
        // Unlike Depth Anything, this one is far slower anywhere but the GPU
        // (.all measured 36ms against 14ms), so it shares the GPU with the
        // render passes.
        config.computeUnits = .cpuAndGPU
        config.functionName = Self.function

        do {
            model = try MLModel(contentsOf: modelURL, configuration: config)
        } catch {
            log.error("Depth Pro 2 load failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        // (1, 3, H, W): planar RGB, half floats, 0...1.
        guard let shape = model.modelDescription.inputDescriptionsByName["frame"]?
                .multiArrayConstraint?.shape.map(\.intValue),
              shape.count == 4, shape[1] == 3,
              shape[2] % 2 == 0, shape[3] % 2 == 0,
              model.modelDescription.outputDescriptionsByName["inverse_depth"] != nil else {
            log.error("Depth Pro 2 model does not have the inputs we expect")
            return nil
        }
        let (h, w) = (shape[2], shape[3])
        height = h
        width = w

        do {
            input = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float16)
            features = try MLDictionaryFeatureProvider(dictionary: ["frame": input])
            lumaSmall = try vImage_Buffer(width: w, height: h, bitsPerPixel: 8)
            chromaSmall = try vImage_Buffer(width: w / 2, height: h / 2, bitsPerPixel: 16)
            argb = try vImage_Buffer(width: w, height: h, bitsPerPixel: 32)
            planes = try (0..<4).map { _ in
                try vImage_Buffer(width: w, height: h, bitsPerPixel: 8)
            }
        } catch {
            log.error("Depth Pro 2 buffers failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard input.strides.map(\.intValue) == [3 * h * w, h * w, w, 1] else {
            log.error("Depth Pro 2 input array is not contiguous")
            return nil
        }

        // BT.709, matching nv12_to_linear in Bokeh.metal. The ISP emits video
        // range; full range is handled so a different source cannot look washed
        // out to the model.
        var bt709 = vImage_YpCbCrToARGBMatrix(Yp: 1, Cr_R: 1.5748, Cr_G: -0.4681,
                                              Cb_G: -0.1873, Cb_B: 1.8556)
        var video = vImage_YpCbCrPixelRange(Yp_bias: 16, CbCr_bias: 128,
                                            YpRangeMax: 235, CbCrRangeMax: 240,
                                            YpMax: 235, YpMin: 16, CbCrMax: 240, CbCrMin: 16)
        var full = vImage_YpCbCrPixelRange(Yp_bias: 0, CbCr_bias: 128,
                                           YpRangeMax: 255, CbCrRangeMax: 255,
                                           YpMax: 255, YpMin: 1, CbCrMax: 255, CbCrMin: 0)
        let flags = vImage_Flags(kvImageNoFlags)
        guard vImageConvert_YpCbCrToARGB_GenerateConversion(
                  &bt709, &video, &videoRange,
                  kvImage420Yp8_CbCr8, kvImageARGB8888, flags) == kvImageNoError,
              vImageConvert_YpCbCrToARGB_GenerateConversion(
                  &bt709, &full, &fullRange,
                  kvImage420Yp8_CbCr8, kvImageARGB8888, flags) == kvImageNoError else {
            return nil
        }

        state = model.makeState()
    }

    deinit {
        lumaSmall.free()
        chromaSmall.free()
        argb.free()
        planes.forEach { $0.free() }
    }

    func depth(from pixelBuffer: CVPixelBuffer) async -> DepthProvider.Result? {
        lock.withLock { predict(pixelBuffer) }
    }

    private func predict(_ pixelBuffer: CVPixelBuffer) -> DepthProvider.Result? {
        guard fillInput(from: pixelBuffer) else { return nil }

        let now = Date()
        if now.timeIntervalSince(lastRun) > Self.staleAfter { state = model.makeState() }
        lastRun = now

        do {
            let output = try model.prediction(from: features, using: state)
            guard let inverse = output.featureValue(for: "inverse_depth")?.multiArrayValue else {
                return nil
            }
            return normalizeAndUpload(inverse)
        } catch {
            log.error("Depth Pro 2 inference failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// NV12 at camera size -> planar RGB half floats at model size.
    ///
    /// The frame is stretched to the model's shape, not cropped, because the
    /// depth map has to cover the whole frame. Every output mode is 16:9 and so
    /// is the model input, so in practice nothing is distorted.
    private func fillInput(from pixelBuffer: CVPixelBuffer) -> Bool {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let isFullRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        guard isFullRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else {
            log.error("Depth Pro 2 needs NV12 input")
            return false
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else { return false }

        var luma = vImage_Buffer(
            data: lumaBase,
            height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)),
            width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)),
            rowBytes: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0))
        var chroma = vImage_Buffer(
            data: chromaBase,
            height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)),
            width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)),
            rowBytes: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1))

        // Shrink first, convert second: the colour maths then runs on a ninth of
        // the pixels of a 1080p frame.
        let flags = vImage_Flags(kvImageNoFlags)
        guard vImageScale_Planar8(&luma, &lumaSmall, nil, flags) == kvImageNoError,
              vImageScale_CbCr8(&chroma, &chromaSmall, nil, flags) == kvImageNoError else { return false }

        var conversion = isFullRange ? fullRange : videoRange
        guard vImageConvert_420Yp8_CbCr8ToARGB8888(&lumaSmall, &chromaSmall, &argb, &conversion,
                                                   nil, 255, flags) == kvImageNoError,
              vImageConvert_ARGB8888toPlanar8(&argb, &planes[0], &planes[1], &planes[2], &planes[3],
                                              flags) == kvImageNoError else { return false }

        // planes[0] is alpha. Red, green and blue go straight into the model's
        // input, one after another, as 0...1 half floats.
        let planeBytes = width * height * MemoryLayout<Float16>.size
        var ok = true
        input.withUnsafeMutableBytes { raw, _ in
            guard let base = raw.baseAddress else { ok = false; return }
            for channel in 0..<3 {
                var destination = vImage_Buffer(data: base + channel * planeBytes,
                                                height: vImagePixelCount(height),
                                                width: vImagePixelCount(width),
                                                rowBytes: width * MemoryLayout<Float16>.size)
                if vImageConvert_Planar8toPlanar16F(&planes[channel + 1], &destination,
                                                    flags) != kvImageNoError { ok = false }
            }
        }
        return ok
    }

    /// Half-float inverse depth -> the renderer's 0 = near, 1 = far.
    private func normalizeAndUpload(_ inverse: MLMultiArray) -> DepthProvider.Result? {
        // (1, H, W)
        let shape = inverse.shape.map(\.intValue)
        let strides = inverse.strides.map(\.intValue)
        guard inverse.dataType == .float16, shape.count == 3, strides.count == 3 else { return nil }
        let h = shape[1], w = shape[2]
        let count = w * h

        if scratch.count != count { scratch = [Float](repeating: 0, count: count) }

        var ok = true
        inverse.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { ok = false; return }
            var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: base),
                                       height: vImagePixelCount(h), width: vImagePixelCount(w),
                                       rowBytes: strides[1] * MemoryLayout<Float16>.size)
            scratch.withUnsafeMutableBufferPointer { destination in
                var out = vImage_Buffer(data: destination.baseAddress, height: vImagePixelCount(h),
                                        width: vImagePixelCount(w), rowBytes: w * MemoryLayout<Float>.size)
                if vImageConvert_Planar16FtoPlanarF(&source, &out, 0) != kvImageNoError { ok = false }
            }
        }
        guard ok else { return nil }

        // Larger = closer, and zero = infinitely far, so this is the same flip
        // Depth Anything needs, just with a fixed scale in place of a per-frame
        // one:  out = 1 - inverse / nearest
        var scale = -1 / Self.nearestInverseDepth
        var bias: Float = 1
        vDSP_vsmsa(scratch, 1, &scale, &bias, &scratch, 1, vDSP_Length(count))
        var lo: Float = 0, hi: Float = 1
        vDSP_vclip(scratch, 1, &lo, &hi, &scratch, 1, vDSP_Length(count))

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
        return DepthProvider.Result(texture: texture, values: scratch, width: w, height: h)
    }
}
