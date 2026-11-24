import CoreVideo
import Foundation

/// What a frame looks like, from a sparse sample of its pixels.
struct SceneStats: Sendable, Equatable {
    /// Mean brightness as the camera encoded it. 0 is black and 1 is white.
    var luma: Double
    /// Mean red, green and blue, as encoded, over the pixels that are neither
    /// black nor blown out. Nil when too few pixels qualified to trust it.
    var colour: SIMD3<Double>?

    /// 1 is neutral, and more than 1 is a warm cast.
    var redOverBlue: Double? { colour.map { $0.x / $0.z } }
}

enum SceneSampler {
    /// Reads about one pixel in 64 of an NV12 frame. Cheap enough to call from
    /// the capture thread.
    static func sample(_ buffer: CVPixelBuffer) -> SceneStats? {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
              CVPixelBufferGetPlaneCount(buffer) == 2 else { return nil }
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return nil }

        let lumaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let chromaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let width = CVPixelBufferGetWidthOfPlane(buffer, 1)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 1)
        let luma = lumaBase.assumingMemoryBound(to: UInt8.self)
        let chroma = chromaBase.assumingMemoryBound(to: UInt8.self)

        var count = 0, lumaSum = 0
        var tinted = 0, ySum = 0, cbSum = 0, crSum = 0
        for row in stride(from: 4, to: height, by: 8) {
            for column in stride(from: 4, to: width, by: 8) {
                let y = Int(luma[row * 2 * lumaRow + column * 2])
                count += 1
                lumaSum += y
                // Black pixels carry no colour and blown ones have lost it.
                guard y >= 32, y <= 225 else { continue }
                tinted += 1
                ySum += y
                cbSum += Int(chroma[row * chromaRow + column * 2])
                crSum += Int(chroma[row * chromaRow + column * 2 + 1])
            }
        }
        guard count > 0 else { return nil }

        var stats = SceneStats(luma: min(max((Double(lumaSum) / Double(count) - 16) / 219, 0), 1),
                               colour: nil)
        if tinted >= 200 {
            // BT.709, video range: the same conversion the shader does.
            let y = (Double(ySum) / Double(tinted) - 16) / 219
            let cb = (Double(cbSum) / Double(tinted) - 128) / 224
            let cr = (Double(crSum) / Double(tinted) - 128) / 224
            let red = y + 1.5748 * cr
            let green = y - 0.1873 * cb - 0.4681 * cr
            let blue = y + 1.8556 * cb
            if red > 0.01, green > 0.01, blue > 0.01 {
                stats.colour = SIMD3(red, green, blue)
            }
        }
        return stats
    }
}

/// Helps when the camera's own auto exposure and auto white balance run out.
///
/// Both have hard limits. In a dim room lit by warm lamps, one C1 sat at its
/// top ISO of 1600 with the picture still close to black. Its auto white
/// balance stopped at 2634 K with the lamps far warmer than that, so a white
/// wall came out orange, with nine times as much red as blue.
///
/// The camera accepts a manual white balance below where its auto mode stops.
/// That brought red over blue down from nine to three, and then stopped
/// helping somewhere above 1500 K. So this works in two steps. It first sets a
/// lower white balance on the camera, which corrects the colour before the
/// picture is compressed to 8 bits. Whatever tint is left once that has
/// bottomed out, the renderer takes out. It also has the renderer add the
/// brightness the sensor cannot. All of it applies only while the camera is
/// stuck, and control goes back when it is not.
struct LowLightAssist: Equatable {
    /// Brightness to add in the renderer, as a multiple of linear light.
    private(set) var gain = 1.0
    /// A white balance to send in place of auto, or nil to leave the camera to it.
    private(set) var whiteBalanceK: Int?
    /// What the renderer multiplies red, green and blue by, in linear light.
    private(set) var tint = SIMD3<Double>(repeating: 1)

    /// The camera has no exposure left to give.
    private(set) var starved = false
    private var warmStreak = 0
    private var tinting = false

    static let maxGain = 4.0
    /// The camera's auto white balance has been seen to stop near 2630 K.
    static let autoFloorK = 2750
    static let takeoverRangeK = 1500.0...2900.0
    /// Aim a little warm. Fully neutral looks cold under lamps.
    static let wantedColour = SIMD3<Double>(1.06, 1, 0.94)
    /// Blue is the weakest channel under lamps, so it is mostly noise. Raising
    /// it further than this trades the tint for coloured grain.
    static let tintRange = 0.35...3.0

    /// Call about twice a second with a fresh sample.
    mutating func update(_ stats: SceneStats, iso: Int, reportedK: Int,
                         autoExposure: Bool, autoWhiteBalance: Bool) {
        updateGain(stats, iso: iso, allowed: autoExposure)
        updateWhiteBalance(stats, reportedK: reportedK, allowed: autoWhiteBalance)
        updateTint(stats)
    }

    private mutating func updateGain(_ stats: SceneStats, iso: Int, allowed: Bool) {
        // Auto exposure raises ISO last, so a top ISO means it has nothing left.
        if iso >= 1500 { starved = true } else if iso < 1200 { starved = false }
        var wanted = 1.0
        if allowed, starved {
            // A well exposed frame averages about 0.3 as encoded. Encoded
            // brightness is roughly linear light to the power 1/2.2.
            wanted = min(max(pow(0.3 / max(stats.luma, 0.01), 2.2), 1), Self.maxGain)
        }
        gain += (wanted - gain) * 0.25
        if abs(gain - wanted) < 0.01 { gain = wanted }
    }

    private mutating func updateWhiteBalance(_ stats: SceneStats, reportedK: Int, allowed: Bool) {
        guard allowed else {
            whiteBalanceK = nil
            warmStreak = 0
            return
        }
        guard let ratio = stats.redOverBlue else { return }

        guard let current = whiteBalanceK else {
            // Take over only when the camera is at its floor and the picture is
            // still warm, and has been for two seconds.
            let stuck = reportedK > 0 && reportedK <= Self.autoFloorK && ratio > 1.3
            warmStreak = stuck ? warmStreak + 1 : 0
            if warmStreak >= 4 { whiteBalanceK = reportedK }
            return
        }

        // A lower setting tells the camera the light is warmer, and it adds blue.
        let target = Self.wantedColour.x / Self.wantedColour.z
        let error = log(ratio / target)
        guard abs(error) > 0.04 else { return }
        let next = Double(current) * min(max(exp(-0.3 * error), 0.93), 1.07)
        if next > Self.takeoverRangeK.upperBound {
            // The light is no longer warm, so the camera can cope by itself.
            whiteBalanceK = nil
            warmStreak = 0
        } else {
            whiteBalanceK = Int(max(next, Self.takeoverRangeK.lowerBound).rounded())
        }
    }

    private mutating func updateTint(_ stats: SceneStats) {
        // The renderer only takes over once the camera setting has nothing
        // left to give. It lets go later than it steps in, so it does not
        // flicker on and off at the edge.
        let bottomedOut = whiteBalanceK.map { Double($0) <= Self.takeoverRangeK.lowerBound } ?? false
        var wanted = SIMD3<Double>(repeating: 1)
        if !bottomedOut {
            tinting = false
        } else if let colour = stats.colour, let ratio = stats.redOverBlue {
            if ratio > 1.3 { tinting = true } else if ratio < 1.15 { tinting = false }
            if tinting { wanted = Self.correction(for: colour) }
        } else if tinting {
            // Too dark to measure this time. Keep what was there.
            wanted = tint
        }
        tint += (wanted - tint) * 0.25
    }

    /// Gains that bring an average colour to `wantedColour` without changing
    /// how bright it is.
    static func correction(for colour: SIMD3<Double>) -> SIMD3<Double> {
        func linear(_ encoded: Double) -> Double { pow(max(encoded, 0.001), 2.2) }
        let now = SIMD3(linear(colour.x), linear(colour.y), linear(colour.z))
        let want = SIMD3(linear(colour.y * wantedColour.x), now.y, linear(colour.y * wantedColour.z))
        var gains = want / now
        gains = SIMD3(min(max(gains.x, tintRange.lowerBound), 1), 1,
                      min(max(gains.z, 1), tintRange.upperBound))
        // Taking red out darkens the picture, so give that brightness back.
        let weights = SIMD3<Double>(0.2126, 0.7152, 0.0722)
        let before = (now * weights).sum()
        let after = (now * gains * weights).sum()
        return gains * min(before / max(after, 0.0001), 2)
    }
}

/// Lets the capture thread sample a frame every so often without a lock per frame
/// being held for long.
final class SampleClock: @unchecked Sendable {
    private let lock = NSLock()
    private var next = 0.0

    func due(every interval: Double) -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock(); defer { lock.unlock() }
        guard now >= next else { return false }
        next = now + interval
        return true
    }
}
