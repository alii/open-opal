import CoreImage
import CoreVideo

/// The installed extension advertises one format: 1920×1080 BGRA.
/// Used only under the feeder's lock. Native 1080p frames need no copy.
final class VirtualCameraFrameConverter {
    private lazy var context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var pool: CVPixelBufferPool?
    static let width = 1920
    static let height = 1080

    func convert(_ input: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(input)
        let height = CVPixelBufferGetHeight(input)
        guard width > 0, height > 0 else { return nil }
        if width == Self.width, height == Self.height,
           CVPixelBufferGetPixelFormatType(input) == kCVPixelFormatType_32BGRA {
            return input
        }
        if pool == nil {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Self.width,
                kCVPixelBufferHeightKey as String: Self.height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
                    == kCVReturnSuccess else { return nil }
        }
        guard let pool else { return nil }
        var output: CVPixelBuffer?
        let limits = [kCVPixelBufferPoolAllocationThresholdKey as String: 6] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, limits, &output)
                == kCVReturnSuccess, let output else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: Self.width, height: Self.height)
        let scale = min(CGFloat(Self.width) / CGFloat(width), CGFloat(Self.height) / CGFloat(height))
        let image = CIImage(cvPixelBuffer: input)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(
                translationX: (CGFloat(Self.width) - CGFloat(width) * scale) / 2,
                y: (CGFloat(Self.height) - CGFloat(height) * scale) / 2))
            .composited(over: CIImage(color: .black).cropped(to: bounds))
        context.render(image, to: output, bounds: bounds, colorSpace: colorSpace)
        return output
    }
}
