// The frame shown when nothing is feeding the camera: a quiet card instead of
// a frozen last frame or black. Rendered once with CoreGraphics (no
// AppKit in a system extension) and re-timestamped 30 times a second.

import CoreGraphics
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

        // Soft glow behind the camera-off symbol.
        let glow = CGGradient(colorsSpace: nil,
                              colors: [CGColor(red: 1.0, green: 0.72, blue: 0.58, alpha: 0.22),
                                       CGColor(red: 1.0, green: 0.72, blue: 0.58, alpha: 0.0)] as CFArray,
                              locations: [0, 1])!
        ctx.drawRadialGradient(glow,
                               startCenter: CGPoint(x: w / 2, y: h / 2), startRadius: 0,
                               endCenter: CGPoint(x: w / 2, y: h / 2), endRadius: h * 0.55,
                               options: [])

        // Meeting apps often mirror only their local preview. A pictogram
        // makes sense in both orientations; baked-in text cannot do that.
        ctx.saveGState()
        ctx.translateBy(x: w / 2, y: h / 2)
        let scale = min(w, h) / 1080
        ctx.scaleBy(x: scale, y: scale)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.72))
        ctx.setLineWidth(6)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)

        let camera = CGMutablePath()
        camera.move(to: CGPoint(x: -64, y: -44))
        camera.addLine(to: CGPoint(x: 64, y: -44))
        camera.addQuadCurve(to: CGPoint(x: 78, y: -30), control: CGPoint(x: 78, y: -44))
        camera.addLine(to: CGPoint(x: 78, y: 32))
        camera.addQuadCurve(to: CGPoint(x: 64, y: 46), control: CGPoint(x: 78, y: 46))
        camera.addLine(to: CGPoint(x: 34, y: 46))
        camera.addLine(to: CGPoint(x: 22, y: 60))
        camera.addLine(to: CGPoint(x: -22, y: 60))
        camera.addLine(to: CGPoint(x: -34, y: 46))
        camera.addLine(to: CGPoint(x: -64, y: 46))
        camera.addQuadCurve(to: CGPoint(x: -78, y: 32), control: CGPoint(x: -78, y: 46))
        camera.addLine(to: CGPoint(x: -78, y: -30))
        camera.addQuadCurve(to: CGPoint(x: -64, y: -44), control: CGPoint(x: -78, y: -44))
        camera.closeSubpath()
        ctx.addPath(camera)
        ctx.strokePath()
        ctx.strokeEllipse(in: CGRect(x: -22, y: -22, width: 44, height: 44))

        let slash = CGMutablePath()
        slash.move(to: CGPoint(x: -84, y: 70))
        slash.addLine(to: CGPoint(x: 84, y: -68))
        // Clear a small gap underneath the slash within this layer, keeping
        // the existing gradient intact rather than painting over it.
        ctx.setBlendMode(.clear)
        ctx.setLineWidth(18)
        ctx.addPath(slash)
        ctx.strokePath()
        ctx.setBlendMode(.normal)
        ctx.setLineWidth(6)
        ctx.addPath(slash)
        ctx.strokePath()
        ctx.endTransparencyLayer()
        ctx.restoreGState()

        return pb
    }
}
