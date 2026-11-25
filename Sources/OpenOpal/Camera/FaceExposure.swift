import CoreVideo
import Foundation
import Vision

/// How bright a face is in the camera's own picture, as encoded, 0 to 1.
struct FaceLight: Sendable, Equatable {
    var mean: Double
    /// The level 95% of the skin is below. Near 1, skin is blowing out.
    var bright: Double
}

enum FaceLightSampler {
    /// Finds the largest face and measures its skin. A few milliseconds, so not
    /// for the capture thread.
    static func sample(_ buffer: CVPixelBuffer) -> FaceLight? {
        let request = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cvPixelBuffer: buffer).perform([request])
        guard let found = request.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width })?.boundingBox,
              found.width > 0.04 else { return nil }
        // Vision counts from the bottom. Trim the edges, which are hair and wall.
        let face = CGRect(x: found.minX, y: 1 - found.maxY, width: found.width, height: found.height)
            .insetBy(dx: found.width * 0.12, dy: found.height * 0.12)

        guard CVPixelBufferGetPlaneCount(buffer) == 2,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let xs = max(0, Int(face.minX * Double(width)))..<max(1, min(width, Int(face.maxX * Double(width))))
        let ys = max(0, Int(face.minY * Double(height)))..<max(1, min(height, Int(face.maxY * Double(height))))
        guard xs.count > 12, ys.count > 12 else { return nil }

        var histogram = [Int](repeating: 0, count: 256)
        var count = 0, sum = 0
        for y in stride(from: ys.lowerBound, to: ys.upperBound, by: 3) {
            for x in stride(from: xs.lowerBound, to: xs.upperBound, by: 3) {
                let value = Int(pixels[y * row + x])
                histogram[value] += 1
                sum += value
                count += 1
            }
        }
        var below = 0, level = 0
        while level < 255, below + histogram[level] < count * 95 / 100 {
            below += histogram[level]
            level += 1
        }
        func encoded(_ value: Double) -> Double { min(max((value - 16) / 219, 0), 1) }
        return FaceLight(mean: encoded(Double(sum) / Double(count)), bright: encoded(Double(level)))
    }
}

/// Moves the camera's exposure compensation so that a face is well lit.
///
/// Pointing the camera's own metering box at the face does not do it. Measured
/// on one C1 by a window, skin averaged 93 of 255 with the whole picture
/// metered and 95 with the box on the face: auto exposure gives the box little
/// weight. Two steps of exposure compensation took the same face to 124.
/// A third blew out 6% of it, so brightness stops before the skin does.
///
/// It is slow on purpose. The limits for stepping up and stepping down are
/// further apart than one step moves the picture, so it cannot hunt.
struct FaceExposure: Equatable {
    /// Steps to add to the user's own exposure compensation.
    private(set) var offset = 0

    private var vote = 0
    private var votes = 0
    private var steppedAt = Date.distantPast
    private var seenAt = Date.distantPast

    static let range = -3...3
    /// What one step of compensation does to mean skin, roughly.
    static let stepSize = 0.055

    /// Call about twice a second. `userSteps` is the user's own compensation,
    /// which moves the target, so this does not undo it.
    mutating func update(_ face: FaceLight?, userSteps: Int, at now: Date) {
        guard let face else {
            // Nobody there, or someone looking down: a face seen from above is
            // not found. Hold for a minute, so reading something does not slowly
            // darken the picture, then ease back to the camera's choice.
            if now.timeIntervalSince(seenAt) > 60, now.timeIntervalSince(steppedAt) > 2, offset != 0 {
                offset -= offset.signum()
                steppedAt = now
            }
            votes = 0
            return
        }
        seenAt = now
        let shift = Double(userSteps) * Self.stepSize
        let wanted: Int
        if face.bright > min(0.95 + max(shift, 0), 0.99) || face.mean > 0.60 + shift {
            wanted = -1
        } else if face.mean < 0.46 + shift, face.bright < 0.80 + max(shift, 0) {
            wanted = 1
        } else {
            wanted = 0
        }
        votes = wanted == vote ? votes + 1 : 1
        vote = wanted
        guard wanted != 0, votes >= 3, now.timeIntervalSince(steppedAt) > 2 else { return }
        let next = min(max(offset + wanted, Self.range.lowerBound), Self.range.upperBound)
        if next != offset {
            offset = next
            steppedAt = now
        }
        votes = 0
    }
}

/// Allows one face measurement at a time, about twice a second.
final class FaceSampleGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    private var next = 0.0

    func tryBegin(every interval: Double) -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock(); defer { lock.unlock() }
        guard !busy, now >= next else { return false }
        busy = true
        next = now + interval
        return true
    }

    func end() { lock.withLock { busy = false } }
}
