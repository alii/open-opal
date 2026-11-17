import CoreImage
import CoreVideo
import Metal
import OSLog
import Vision

private let log = Logger(subsystem: "com.openopal", category: "matte")

/// A subject matte, plus the CPU-side mask so we can ask questions about it —
/// where the subject is, and how far away.
struct MatteResult: @unchecked Sendable {
    let backing: AnalysisTexturePool.Lease
    var texture: MTLTexture { backing.texture }
    let mask: [UInt8]     // 0..255, row-major
    let width: Int
    let height: Int
}

/// Produces a soft subject matte using Vision's person segmentation, on the ANE.
///
/// The matte is **not** what does the blurring — depth does that. The matte pins
/// the subject to the focal plane (a monocular depth model will happily put half
/// a cheek at the wrong distance, and a blurry patch on someone's face is the
/// most damning artifact you can ship), and it tells us where to *meter*.
final class MatteProvider: @unchecked Sendable {

    /// One independent inference lane.
    ///
    /// Vision's sequence handler is stateful, so it can't run two frames at once.
    /// To get more than one frame in flight we need genuinely separate handlers —
    /// which is the whole point: in synchronous mode the frame rate is capped at
    /// 1/inference_time, so a 40ms mask means 25fps no matter how fast the camera
    /// is. Running several frames concurrently raises THROUGHPUT without touching
    /// latency or breaking the frame↔mask pairing that keeps the blur aligned.
    ///
    /// Each lane owns its request. Consumers keep output storage leased after
    /// the lane is released.
    private final class Lane {
        let request = VNGeneratePersonSegmentationRequest()
        var sequence = VNSequenceRequestHandler()
        var inUse = false
        var needsReset = false

        init() {
            request.qualityLevel = .balanced
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        }
    }

    private let textures: AnalysisTexturePool
    private let lock = NSLock()
    private var lanes: [Lane]
    private var quality: CameraSettings.MatteQuality = .balanced
    private var generation: UInt64 = 0

    /// Rolling inference time, so the UI can show what the mask actually costs
    /// instead of us guessing.
    private(set) var lastMs: Double = 0

    init(device: MTLDevice, laneCount: Int = 3) {
        let count = max(laneCount, 1)
        self.lanes = (0..<count).map { _ in Lane() }
        textures = AnalysisTexturePool(device: device, format: .r8Unorm, capacity: count + 2)
    }

    func setQuality(_ q: CameraSettings.MatteQuality) {
        lock.lock(); defer { lock.unlock() }
        guard q != quality else { return }
        quality = q
    }

    func reset(generation token: UInt64) {
        lock.withLock {
            guard token > generation else { return }
            generation = token
            for lane in lanes { lane.needsReset = true }
        }
    }

    private func qualityLevel() -> VNGeneratePersonSegmentationRequest.QualityLevel {
        switch quality {
        case .fast:     .fast
        case .balanced: .balanced
        case .accurate: .accurate
        }
    }

    /// Nil if every lane is busy — the caller should drop this frame rather than
    /// queue it. Queueing just builds a backlog and turns latency into lag.
    private func claimLane(generation token: UInt64) -> Lane? {
        lock.lock(); defer { lock.unlock() }
        guard token >= generation else { return nil }
        if token != generation {
            generation = token
            for lane in lanes { lane.needsReset = true }
        }
        guard let lane = lanes.first(where: { !$0.inUse }) else { return nil }
        lane.inUse = true
        // Vision may still be using the other lanes' requests.
        lane.request.qualityLevel = qualityLevel()
        if lane.needsReset {
            lane.sequence = VNSequenceRequestHandler()
            lane.needsReset = false
        }
        return lane
    }

    private func release(_ lane: Lane) {
        lock.lock(); lane.inUse = false; lock.unlock()
    }

    func matte(from pixelBuffer: CVPixelBuffer, generation token: UInt64) async -> MatteResult? {
        guard let lane = claimLane(generation: token) else { return nil }
        defer { release(lane) }

        let start = CFAbsoluteTimeGetCurrent()
        do {
            try lane.sequence.perform([lane.request], on: pixelBuffer)
        } catch {
            log.error("segmentation failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let result = lane.request.results?.first as? VNPixelBufferObservation else { return nil }
        let out = upload(result.pixelBuffer)

        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        lock.withLock { lastMs += 0.2 * (ms - lastMs) }
        return out
    }

    private func upload(_ mask: CVPixelBuffer) -> MatteResult? {
        let w = CVPixelBufferGetWidth(mask)
        let h = CVPixelBufferGetHeight(mask)

        guard let backing = textures.acquire(width: w, height: h) else { return nil }
        let texture = backing.texture

        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(mask)

        texture.replace(region: MTLRegionMake2D(0, 0, w, h),
                        mipmapLevel: 0, withBytes: base, bytesPerRow: stride)

        var flat = [UInt8](repeating: 0, count: w * h)
        let src = base.assumingMemoryBound(to: UInt8.self)
        flat.withUnsafeMutableBufferPointer { dst in
            for row in 0..<h {
                memcpy(dst.baseAddress! + row * w, src + row * stride, w)
            }
        }
        return MatteResult(backing: backing, mask: flat, width: w, height: h)
    }
}

/// What we learn about the subject each analysis pass.
struct SubjectInfo {
    /// Median scene depth over the subject — this is the focal plane. Previously
    /// this was a hardcoded constant, which meant "track subject" tracked
    /// nothing: the blur measured distance from an arbitrary plane rather than
    /// from the person.
    var depth: Float
    /// Normalized bounding box of the subject, used to meter exposure on the
    /// person instead of on the whole frame. Backlighting (a bright window
    /// behind you) otherwise drags the average up and leaves your face dark.
    var bounds: CGRect
    var coverage: Float   // fraction of frame; if tiny, don't trust any of this
}

enum SubjectAnalysis {

    /// Where the subject is, without needing a depth map. Enough to meter
    /// exposure on them, which is all we need when bokeh is off.
    static func locate(matte: MatteResult) -> SubjectInfo? {
        var minX = 1.0, minY = 1.0, maxX = 0.0, maxY = 0.0
        var hits = 0

        // Every 4th pixel: the bounding box of a person doesn't need more, and
        // this runs on every analysis pass.
        let step = 4
        for y in stride(from: 0, to: matte.height, by: step) {
            for x in stride(from: 0, to: matte.width, by: step) {
                guard matte.mask[y * matte.width + x] > 128 else { continue }
                hits += 1
                let nx = Double(x) / Double(matte.width)
                let ny = Double(y) / Double(matte.height)
                minX = min(minX, nx); maxX = max(maxX, nx)
                minY = min(minY, ny); maxY = max(maxY, ny)
            }
        }

        let total = (matte.width / step) * (matte.height / step)
        let coverage = Float(hits) / Float(max(total, 1))
        guard coverage > 0.02 else { return nil }

        return SubjectInfo(depth: 0.35,   // unknown; unused when bokeh is off
                           bounds: CGRect(x: minX, y: minY,
                                          width: maxX - minX, height: maxY - minY),
                           coverage: coverage)
    }

    /// Combines the matte and the depth map, which are different sizes but both
    /// cover the full frame — so normalized coordinates line them up.
    static func analyze(matte: MatteResult, depth: [Float],
                        depthWidth dw: Int, depthHeight dh: Int) -> SubjectInfo? {
        guard dw > 0, dh > 0, depth.count >= dw * dh else { return nil }

        var subjectDepths: [Float] = []
        subjectDepths.reserveCapacity(dw * dh / 4)

        var minX = 1.0, minY = 1.0, maxX = 0.0, maxY = 0.0
        var hits = 0

        for y in 0..<dh {
            let my = y * matte.height / dh
            for x in 0..<dw {
                let mx = x * matte.width / dw
                guard matte.mask[my * matte.width + mx] > 128 else { continue }

                hits += 1
                subjectDepths.append(depth[y * dw + x])

                let nx = Double(x) / Double(dw), ny = Double(y) / Double(dh)
                minX = min(minX, nx); maxX = max(maxX, nx)
                minY = min(minY, ny); maxY = max(maxY, ny)
            }
        }

        let coverage = Float(hits) / Float(dw * dh)
        // Nobody there (or a few stray pixels) — don't refocus or re-meter on noise.
        guard coverage > 0.02, !subjectDepths.isEmpty else { return nil }

        subjectDepths.sort()
        let median = subjectDepths[subjectDepths.count / 2]

        return SubjectInfo(
            depth: median,
            bounds: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
            coverage: coverage)
    }
}
