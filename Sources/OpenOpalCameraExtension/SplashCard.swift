// The frame shown when nothing is feeding the camera: a quiet card instead of
// a frozen last frame or black. Rendered once with CoreGraphics/CoreText (no
// AppKit in a system extension) and re-timestamped 30 times a second.

import CoreGraphics
import CoreText
import CoreVideo
import Foundation

enum SplashCard {

    static func render(width: Int, height: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                            &pb)
        guard let pb else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pb),
            width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }

        let w = CGFloat(width), h = CGFloat(height)

        // Plum-to-charcoal wash, matching the app icon's palette.
        let colors = [CGColor(red: 0.16, green: 0.10, blue: 0.14, alpha: 1),
                      CGColor(red: 0.07, green: 0.06, blue: 0.09, alpha: 1)]
        let gradient = CGGradient(colorsSpace: nil, colors: colors as CFArray,
                                  locations: [0, 1])!
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: w / 2, y: h),
                               end: CGPoint(x: w / 2, y: 0), options: [])

        // Soft glow behind the wordmark.
        let glow = CGGradient(colorsSpace: nil,
                              colors: [CGColor(red: 1.0, green: 0.72, blue: 0.58, alpha: 0.22),
                                       CGColor(red: 1.0, green: 0.72, blue: 0.58, alpha: 0.0)] as CFArray,
                              locations: [0, 1])!
        ctx.drawRadialGradient(glow,
                               startCenter: CGPoint(x: w / 2, y: h / 2), startRadius: 0,
                               endCenter: CGPoint(x: w / 2, y: h / 2), endRadius: h * 0.55,
                               options: [])

        func draw(_ text: String, size: CGFloat, weight: CFString, y: CGFloat, alpha: CGFloat) {
            let font = CTFontCreateWithName(weight, size, nil)
            let attr = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: CGColor(gray: 1.0, alpha: alpha),
            ] as CFDictionary
            let line = CTLineCreateWithAttributedString(
                CFAttributedStringCreate(nil, text as CFString, attr))
            let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
            ctx.textPosition = CGPoint(x: (w - bounds.width) / 2, y: y)
            CTLineDraw(line, ctx)
        }

        draw("Open Opal", size: 64, weight: "HelveticaNeue-Medium" as CFString,
             y: h / 2 - 10, alpha: 0.92)
        draw("Launch the app to start the camera", size: 26,
             weight: "HelveticaNeue" as CFString, y: h / 2 - 64, alpha: 0.55)

        return pb
    }
}
