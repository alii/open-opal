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
    static func checkNeutralRamp(settings: CameraSettings) {
        let width = 220, height = 2
        let input = nv12(width: width, height: height)
        CVPixelBufferLockBaseAddress(input, [])
        let stride = CVPixelBufferGetBytesPerRowOfPlane(input, 0)
        let bytes = CVPixelBufferGetBaseAddressOfPlane(input, 0)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width { bytes[y * stride + x] = UInt8(16 + x) }
        }
        CVPixelBufferUnlockBaseAddress(input, [])
        settings.bokehEnabled = false
        let renderer = BokehRenderer()!
        let texture = renderer.render(pixelBuffer: input, settings: RenderSettings(settings))!
        let actual = pixels(renderer.exportFrame(texture)!)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let expected = Int((Double(x) * 255 / 219).rounded())
                require(actual[offset + 3] == 255 &&
                        actual[offset..<(offset + 3)].allSatisfy { abs(Int($0) - expected) <= 1 },
                        "Neutral video-range ramp must preserve absolute sRGB levels at \(x)")
            }
        }
        print("PASS: absolute neutral video-range ramp through production linear-light rendering")
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
        checkNeutralRamp(settings: settings)
    }
}
