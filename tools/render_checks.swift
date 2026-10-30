import CoreVideo
import Foundation
import Metal

// No camera, device bridge, app model, or virtual-camera connection.
@main
struct RenderChecks {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }

    static func nv12(width: Int = 320, height: Int = 180, luma: UInt8 = 120,
                     cb: UInt8 = 128, cr: UInt8 = 128) -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        require(CVPixelBufferCreate(nil, width, height,
                                   kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                   attributes as CFDictionary, &result) == kCVReturnSuccess,
                "Cannot allocate synthetic NV12 input")
        let buffer = result!
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for plane in 0..<2 {
            let rows = CVPixelBufferGetHeightOfPlane(buffer, plane)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let bytes = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!.assumingMemoryBound(to: UInt8.self)
            for y in 0..<rows {
                for x in 0..<stride {
                    bytes[y * stride + x] = plane == 0 ? luma : (x % 2 == 0 ? cb : cr)
                }
            }
        }
        return buffer
    }

    static func pixels(_ buffer: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let rowBytes = CVPixelBufferGetWidth(buffer) * 4
        return (0..<CVPixelBufferGetHeight(buffer)).flatMap { row in
            Array(UnsafeBufferPointer(start: bytes + row * stride, count: rowBytes))
        }
    }

    static func texturePixels(_ texture: MTLTexture) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        result.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 4,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return result
    }

    @MainActor
    static func checkOwnedOutput(settings: CameraSettings) {
        let renderer = BokehRenderer()!
        let snapshot = RenderSettings(settings)
        let input = nv12(cb: 100, cr: 155)
        let first = renderer.render(pixelBuffer: input, settings: snapshot,
                                    captureGeneration: renderer.captureGeneration)!
        let original = pixels(first.pixelBuffer)
        require(original[3] == 255 && original[2] > original[0],
                "GPU output must preserve opaque BGRA channel order")
        require(texturePixels(first.texture) == original, "Preview and sink must share completed GPU pixels")
        autoreleasepool {
            let second = renderer.render(pixelBuffer: nv12(luma: 200), settings: snapshot,
                                         captureGeneration: renderer.captureGeneration)!
            require(pixels(second.pixelBuffer) != original, "A new input must produce new pixels")
            let resized = renderer.render(pixelBuffer: nv12(width: 160, height: 90, luma: 235),
                                          settings: snapshot, captureGeneration: renderer.captureGeneration)!
            require(pixels(resized.pixelBuffer).allSatisfy { $0 == 255 }, "White input must render opaque white")
        }
        require(pixels(first.pixelBuffer) == original && texturePixels(first.texture) == original,
                "Subsequent renders or resizing overwrote retained output")

        let bounded = BokehRenderer()!
        autoreleasepool {
            var retained: [RenderedFrame] = []
            for _ in 0..<6 {
                retained.append(bounded.render(pixelBuffer: input, settings: snapshot,
                                               captureGeneration: bounded.captureGeneration)!)
            }
            require(bounded.render(pixelBuffer: input, settings: snapshot,
                                   captureGeneration: bounded.captureGeneration) == nil,
                    "Retained output must be bounded rather than overwritten")
            retained.removeAll()
        }
        autoreleasepool {
            require(bounded.render(pixelBuffer: input, settings: snapshot,
                                   captureGeneration: bounded.captureGeneration) != nil,
                    "Released output storage must recover")
        }
        print("PASS: production GPU pixels, shared preview/sink pixels, retained output, bounded output recovery")
    }

    static func analysisMatte(_ pool: AnalysisTexturePool, value: UInt8,
                              width: Int = 16, height: Int = 16) -> MatteResult {
        let backing = pool.acquire(width: width, height: height)!
        let mask = [UInt8](repeating: value, count: width * height)
        mask.withUnsafeBytes {
            backing.texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                                    withBytes: $0.baseAddress!, bytesPerRow: width)
        }
        return MatteResult(backing: backing, mask: mask, width: width, height: height)
    }

    static func firstMaskByte(_ texture: MTLTexture) -> UInt8 {
        var value: UInt8 = 0
        texture.getBytes(&value, bytesPerRow: 1, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        return value
    }

    static func floatTexture(_ device: MTLDevice, values: [Float], width: Int, height: Int) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite]
        let texture = device.makeTexture(descriptor: descriptor)!
        values.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: width * MemoryLayout<Float>.size)
        }
        return texture
    }

    static func floats(_ texture: MTLTexture) -> [Float] {
        var values = [Float](repeating: 0, count: texture.width * texture.height)
        values.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * MemoryLayout<Float>.size,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return values
    }

    static func encodeSmooth(_ command: MTLCommandBuffer, pipeline: MTLComputePipelineState,
                             current: MTLTexture, history: MTLTexture, output: MTLTexture,
                             alpha: Float) {
        let encoder = command.makeComputeCommandEncoder()!
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(current, index: 0)
        encoder.setTexture(history, index: 1)
        encoder.setTexture(output, index: 2)
        var alpha = alpha
        encoder.setBytes(&alpha, length: MemoryLayout<Float>.size, index: 0)
        encoder.dispatchThreads(MTLSize(width: output.width, height: output.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        encoder.endEncoding()
    }

    static func checkAnalysisStorage() {
        let device = MTLCreateSystemDefaultDevice()!
        let pool = AnalysisTexturePool(device: device, format: .r8Unorm, capacity: 2)
        let store = BokehRenderer.AnalysisStore()
        let token = store.tryBeginMatte()!
        var first: MatteResult? = analysisMatte(pool, value: 37)
        let originalStorage = ObjectIdentifier(first!.texture)
        _ = store.publishMatte(first!, subject: nil, generation: token)
        store.endMatte()
        first = nil
        var snapshot = store.latest()
        var second: MatteResult? = analysisMatte(pool, value: 211)
        require(firstMaskByte(snapshot.1!.texture) == 37, "Later analysis overwrote retained matte pixels")
        require(pool.acquire(width: 16, height: 16) == nil, "Analysis storage must stay bounded")
        _ = store.reset()
        require(pool.acquire(width: 16, height: 16) == nil, "Reset recycled a retained matte")
        snapshot = (nil, nil, nil)
        autoreleasepool {
            let reused = pool.acquire(width: 16, height: 16)!
            require(ObjectIdentifier(reused.texture) == originalStorage, "Released storage must be reused")
            require(firstMaskByte(second!.texture) == 211, "Reusing another slot corrupted a result")
        }
        second = nil

        let depthPool = AnalysisTexturePool(device: device, format: .r32Float, capacity: 1)
        autoreleasepool {
            let depthToken = store.tryBeginDepth()!
            let backing = depthPool.acquire(width: 1, height: 1)!
            var value: Float = 0.25
            backing.texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                                    withBytes: &value, bytesPerRow: MemoryLayout<Float>.size)
            store.publishDepth(DepthProvider.Result(backing: backing, values: [value], width: 1, height: 1),
                               generation: depthToken)
            store.endDepth()
        }
        var depthSnapshot = store.latest()
        _ = store.reset()
        require(depthPool.acquire(width: 1, height: 1) == nil, "Reset recycled a retained depth result")
        require(floats(depthSnapshot.0!.texture) == [0.25] && depthSnapshot.0!.values == [0.25],
                "Retained depth pixels and CPU values changed")
        depthSnapshot = (nil, nil, nil)
        require(depthPool.acquire(width: 1, height: 1) != nil, "Released depth storage did not recover")

        let gpuPool = AnalysisTexturePool(device: device, format: .r8Unorm, capacity: 1)
        let queue = device.makeCommandQueue()!
        let pipeline = try! device.makeComputePipelineState(
            function: device.makeDefaultLibrary()!.makeFunction(name: "temporal_smooth")!)
        autoreleasepool {
            var result: MatteResult? = analysisMatte(gpuPool, value: 37)
            let output = floatTexture(device, values: [Float](repeating: 0, count: 256), width: 16, height: 16)
            let event = device.makeSharedEvent()!
            let command = queue.makeCommandBuffer()!
            command.encodeWaitForEvent(event, value: 1)
            encodeSmooth(command, pipeline: pipeline, current: result!.texture,
                         history: result!.texture, output: output, alpha: 1)
            let reader = BokehRenderer.AnalysisStore()
            _ = reader.publishMatte(result!, subject: nil, generation: reader.tryBeginMatte()!)
            reader.endMatte()
            let completed = DispatchSemaphore(value: 0)
            command.addCompletedHandler { [reader] _ in
                _ = reader.reset()
                completed.signal()
            }
            result = nil
            command.commit()
            require(gpuPool.acquire(width: 16, height: 16) == nil, "GPU reader lost its analysis lease")
            event.signaledValue = 1
            command.waitUntilCompleted()
            completed.wait()
            require(command.status == .completed, "GPU analysis read failed")
            require(floats(output).allSatisfy { abs($0 - 37.0 / 255.0) < 0.00001 },
                    "GPU read recycled analysis pixels")
        }
        require(gpuPool.acquire(width: 16, height: 16) != nil, "Completed GPU read did not release its lease")
        print("PASS: bounded matte/depth leases, retained CPU/GPU results, GPU lifetime and storage recovery")
    }

    @MainActor
    static func checkAnalysisTransitions(settings: CameraSettings) async {
        let device = MTLCreateSystemDefaultDevice()!
        let pool = AnalysisTexturePool(device: device, format: .r8Unorm, capacity: 1)
        let matte = analysisMatte(pool, value: 255)
        let store = BokehRenderer.AnalysisStore()
        let matteToken = store.tryBeginMatte()!
        let depthToken = store.tryBeginDepth()!
        let subject = SubjectInfo(depth: 0.8, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), coverage: 1)
        let capture = store.currentCaptureGeneration
        let syncToken = store.setSynchronous(true, captureGeneration: capture)!
        require(store.publishMatte(matte, subject: subject, generation: matteToken) == nil,
                "Mode transition admitted an old asynchronous matte")
        let depthPool = AnalysisTexturePool(device: device, format: .r32Float, capacity: 1)
        let depth = DepthProvider.Result(backing: depthPool.acquire(width: 1, height: 1)!,
                                         values: [0.8], width: 1, height: 1)
        store.publishDepth(depth, generation: depthToken)
        require(store.latest().0 == nil && store.latest().1 == nil && store.latest().2 == nil,
                "Mode transition repopulated stale analysis")
        require(store.publishSynchronousSubject(subject, generation: syncToken)?.depth == 0.8,
                "Current synchronous subject was lost")
        _ = store.reset()
        require(!store.isCurrent(syncToken), "Queued callback survived capture reset")
        require(store.publishSynchronousSubject(subject, generation: syncToken) == nil,
                "Old subject repopulated a new capture session")
        require(store.setSynchronous(false, captureGeneration: capture) == nil,
                "Old capture work changed the new session's mode")
        _ = store.setSynchronous(false, captureGeneration: store.currentCaptureGeneration)
        require(store.tryBeginMatte() == nil && store.tryBeginDepth() == nil,
                "Reset reopened lanes while their old work was running")
        store.endMatte()
        store.endDepth()
        require(store.tryBeginMatte() != nil && store.tryBeginDepth() != nil,
                "Analysis lanes did not recover after old work finished")

        let renderer = BokehRenderer()!
        let input = nv12()
        let generation = renderer.captureGeneration
        settings.bokehEnabled = true
        settings.syncBokeh = true
        let prepared = await renderer.analyzeNow(pixelBuffer: input, needsDepth: false,
                                                 captureGeneration: generation)!
        let snapshot = RenderSettings(settings)
        require(renderer.render(pixelBuffer: input, settings: snapshot,
                                captureGeneration: generation) == nil,
                "Synchronous render must require this frame's analysis")
        autoreleasepool {
            require(renderer.render(pixelBuffer: input, settings: snapshot,
                                    captureGeneration: generation, analysisForFrame: prepared) != nil,
                    "Exact input analysis was rejected")
        }
        require(renderer.render(pixelBuffer: nv12(), settings: snapshot,
                                captureGeneration: generation, analysisForFrame: prepared) == nil,
                "Analysis from a different buffer of the same dimensions was accepted")
        settings.bokehEnabled = false
        autoreleasepool {
            _ = renderer.render(pixelBuffer: input, settings: RenderSettings(settings),
                                captureGeneration: generation)
        }
        require(!renderer.isCurrentAnalysisGeneration(prepared.generation),
                "Leaving synchronous mode did not fence old callbacks")
        settings.bokehEnabled = true
        require(renderer.render(pixelBuffer: input, settings: snapshot,
                                captureGeneration: generation, analysisForFrame: prepared) == nil,
                "Old synchronous analysis survived a mode round-trip")
        renderer.resetCaptureState()
        require(renderer.render(pixelBuffer: input, settings: snapshot,
                                captureGeneration: generation, analysisForFrame: prepared) == nil,
                "Capture reset admitted old rendering")
        let stale = await renderer.analyzeNow(pixelBuffer: input, needsDepth: false,
                                              captureGeneration: generation)
        require(stale == nil, "Old capture work started inference after reset")
        print("PASS: exact-frame pairing, async/sync fencing, stale capture rejection and callback generations")
    }

    static func checkIndependentHistory() {
        let device = MTLCreateSystemDefaultDevice()!
        let queue = device.makeCommandQueue()!
        let pipeline = try! device.makeComputePipelineState(
            function: device.makeDefaultLibrary()!.makeFunction(name: "temporal_smooth")!)
        let width = 16, height = 16
        let prior = (0..<(width * height)).map { Float($0 % width) / Float(width - 1) }
        let currentValues = prior.map { 1 - $0 }
        let current = floatTexture(device, values: currentValues, width: width, height: height)
        var history = floatTexture(device, values: prior, width: width, height: height)
        var next = floatTexture(device, values: [Float](repeating: 0, count: prior.count),
                                width: width, height: height)
        var expected = prior
        for _ in 0..<3 {
            let before = floats(history)
            let command = queue.makeCommandBuffer()!
            encodeSmooth(command, pipeline: pipeline, current: current, history: history, output: next, alpha: 0.6)
            command.commit()
            command.waitUntilCompleted()
            require(command.status == .completed, "Temporal GPU pass failed")
            expected = zip(expected, currentValues).map { old, new in
                let t = min(max((abs(new - old) - 0.15) / 0.35, 0), 1)
                let alpha: Float = 0.6 + 0.4 * t * t * (3 - 2 * t)
                return old + (new - old) * alpha
            }
            require(floats(history) == before, "Smoothing changed its prior history")
            require(zip(floats(next), expected).allSatisfy { abs($0 - $1) < 0.00001 },
                    "Temporal pixels differ from independent prior/output smoothing")
            swap(&history, &next)
        }
    }

    static func checkerInput(width: Int = 320, height: Int = 180) -> CVPixelBuffer {
        let input = nv12(width: width, height: height)
        CVPixelBufferLockBaseAddress(input, [])
        defer { CVPixelBufferUnlockBaseAddress(input, []) }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(input, 0)
        let bytes = CVPixelBufferGetBaseAddressOfPlane(input, 0)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width { bytes[y * stride + x] = (x / 3 + y / 3) % 2 == 0 ? 40 : 200 }
        }
        return input
    }

    // Synthetic pixels are immutable after construction, like captured frames.
    private struct InputFrame: @unchecked Sendable {
        let buffer: CVPixelBuffer
    }

    @MainActor
    static func pairedPixels(_ renderer: BokehRenderer, input: CVPixelBuffer,
                             matte: MatteResult, settings: CameraSettings) async -> [UInt8] {
        let capture = renderer.captureGeneration
        let frame = InputFrame(buffer: input)
        let prepared = await renderer.analyzeNow(pixelBuffer: frame.buffer, needsDepth: false,
                                                 captureGeneration: capture)!
        let paired = BokehRenderer.FrameAnalysis(pixelBuffer: input, generation: prepared.generation,
                                                 depth: nil, matte: matte, subject: nil)
        return autoreleasepool {
            let frame = renderer.render(pixelBuffer: input, settings: RenderSettings(settings),
                                        captureGeneration: capture, analysisForFrame: paired)!
            return pixels(frame.pixelBuffer)
        }
    }

    @MainActor
    static func checkProductionHistory(settings: CameraSettings) async {
        checkIndependentHistory()
        let device = MTLCreateSystemDefaultDevice()!
        let pool = AnalysisTexturePool(device: device, format: .r8Unorm, capacity: 4)
        let sharp = analysisMatte(pool, value: 255)
        let background = analysisMatte(pool, value: 0)
        let prior = analysisMatte(pool, value: 128)
        let current = analysisMatte(pool, value: 153)
        let input = checkerInput()
        settings.bokehEnabled = false
        let renderer = BokehRenderer()!
        let baseline = autoreleasepool {
            pixels(renderer.render(pixelBuffer: input, settings: RenderSettings(settings),
                                   captureGeneration: renderer.captureGeneration)!.pixelBuffer)
        }
        settings.bokehEnabled = true
        settings.syncBokeh = true
        settings.uniformBlur = true
        settings.aperture = 1.4
        let sharpPixels = await pairedPixels(renderer, input: input, matte: sharp, settings: settings)
        require(sharpPixels == baseline, "This frame's full subject matte must preserve sharp pixels")
        let blurred = await pairedPixels(renderer, input: input, matte: background, settings: settings)
        require(blurred != baseline, "This frame's background matte must blur actual GPU pixels")
        renderer.resetCaptureState()
        _ = await pairedPixels(renderer, input: input, matte: prior, settings: settings)
        let warm = await pairedPixels(renderer, input: input, matte: current, settings: settings)
        let fresh = BokehRenderer()!
        let cold = await pairedPixels(fresh, input: input, matte: current, settings: settings)
        require(warm != cold, "Temporal rendering must retain an independent previous matte")
        renderer.resetCaptureState()
        let reset = await pairedPixels(renderer, input: input, matte: current, settings: settings)
        require(reset == cold, "Capture reset must seed history from the current matte")
        _ = await pairedPixels(renderer, input: input, matte: prior, settings: settings)
        settings.bokehEnabled = false
        autoreleasepool {
            _ = renderer.render(pixelBuffer: input, settings: RenderSettings(settings),
                                captureGeneration: renderer.captureGeneration)
        }
        settings.bokehEnabled = true
        let restarted = await pairedPixels(renderer, input: input, matte: current, settings: settings)
        require(restarted == cold, "Mode restart must not mix in old temporal history")
        _ = await pairedPixels(renderer, input: input, matte: prior, settings: settings)
        let resized = checkerInput(width: 160, height: 90)
        let resizedPixels = await pairedPixels(renderer, input: resized, matte: current, settings: settings)
        let resizedFresh = await pairedPixels(BokehRenderer()!, input: resized, matte: current, settings: settings)
        require(resizedPixels == resizedFresh, "Resolution change must seed fresh temporal history")
        require(firstMaskByte(current.texture) == 153, "Rendering changed leased inference output")
        print("PASS: frame-paired sharp/blur pixels, independent temporal history, capture/mode/resize history reset")
    }

    @MainActor
    static func main() async {
        let domain = "com.openopal.render-checks.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: domain)!
        defer { preferences.removePersistentDomain(forName: domain) }
        let settings = CameraSettings(preferences: preferences)
        settings.bokehEnabled = false
        settings.meterOnSubject = false
        settings.focusOnSubject = false
        checkOwnedOutput(settings: settings)
        checkAnalysisStorage()
        await checkAnalysisTransitions(settings: settings)
        await checkProductionHistory(settings: settings)
    }
}
