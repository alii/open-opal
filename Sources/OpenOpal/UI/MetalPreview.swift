import MetalKit
import SwiftUI
import simd

/// Draws the renderer's output, scaled to fill the window.
///
/// This used to be a blit-encoder copy, which can only move pixels 1:1 — so the
/// frame sat letterboxed inside the window with black bars around it. A tiny
/// render pass with a full-screen triangle lets us aspect-*fill* instead: the
/// short axis fills the window and the long axis crops, so the image always
/// reaches the edges.
struct MetalPreview: NSViewRepresentable {
    var texture: MTLTexture?
    var mirrored: Bool

    /// Two different coordinate spaces, and conflating them is a bug waiting to
    /// happen: `view` is where the click landed on screen (draw the reticle
    /// there), `sensor` is the same point mapped back through the mirror and the
    /// fill-crop onto the actual sensor (send the AF region there).
    var onTapToFocus: ((_ view: CGPoint, _ sensor: CGPoint) -> Void)?

    func makeNSView(context: Context) -> MTKView {
        let view = TapMTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.framebufferOnly = true
        view.colorPixelFormat = .bgra8Unorm
        view.delegate = context.coordinator
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = 30
        view.layer?.isOpaque = true
        context.coordinator.configure(device: view.device)
        context.coordinator.view = view
        bindTap(view, context.coordinator)
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.texture = texture
        context.coordinator.mirrored = mirrored
        if let tapView = view as? TapMTKView { bindTap(tapView, context.coordinator) }
    }

    private func bindTap(_ view: TapMTKView, _ coordinator: Coordinator) {
        view.onTap = { [weak coordinator] point in
            guard let coordinator else { return }
            onTapToFocus?(point, coordinator.viewPointToSensor(point))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MTKViewDelegate {
        var texture: MTLTexture?
        var mirrored = true
        weak var view: MTKView?

        private var queue: MTLCommandQueue?
        private var pipeline: MTLRenderPipelineState?
        private var lastScale = SIMD2<Float>(1, 1)

        struct Uniforms {
            var scale: SIMD2<Float>
            var mirror: Int32
        }

        func configure(device: MTLDevice?) {
            guard let device, let library = device.makeDefaultLibrary() else { return }
            queue = device.makeCommandQueue()

            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "preview_vertex")
            desc.fragmentFunction = library.makeFunction(name: "preview_fragment")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try? device.makeRenderPipelineState(descriptor: desc)
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        /// Aspect-fill: zoom about the centre until both axes are covered.
        private func fillScale(image: CGSize, view: CGSize) -> SIMD2<Float> {
            guard image.width > 0, image.height > 0, view.width > 0, view.height > 0 else {
                return SIMD2(1, 1)
            }
            let imageAspect = image.width / image.height
            let viewAspect = view.width / view.height
            return imageAspect > viewAspect
                // Image is wider than the window: crop its sides.
                ? SIMD2(Float(viewAspect / imageAspect), 1)
                // Image is taller: crop top and bottom.
                : SIMD2(1, Float(imageAspect / viewAspect))
        }

        func draw(in view: MTKView) {
            guard let texture,
                  let pipeline,
                  let queue,
                  let drawable = view.currentDrawable,
                  let pass = view.currentRenderPassDescriptor,
                  let cmd = queue.makeCommandBuffer(),
                  let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }

            let scale = fillScale(
                image: CGSize(width: texture.width, height: texture.height),
                view: view.drawableSize)
            lastScale = scale

            var u = Uniforms(scale: scale, mirror: mirrored ? 1 : 0)

            enc.setRenderPipelineState(pipeline)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setFragmentTexture(texture, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()

            cmd.present(drawable)
            cmd.commit()
        }

        /// Map a click in the view (0..1, top-left) back to sensor coordinates,
        /// reversing the fill-crop and the mirror.
        func viewPointToSensor(_ p: CGPoint) -> CGPoint {
            var x = Float(p.x), y = Float(p.y)
            if mirrored { x = 1 - x }
            x = (x - 0.5) * lastScale.x + 0.5
            y = (y - 0.5) * lastScale.y + 0.5
            return CGPoint(x: CGFloat(min(max(x, 0), 1)),
                           y: CGFloat(min(max(y, 0), 1)))
        }
    }
}

/// MTKView doesn't give us clicks, and tap-to-focus needs them.
final class TapMTKView: MTKView {
    var onTap: ((CGPoint) -> Void)?

    /// The strip along the top occupied by the toolbar and the (hidden) title
    /// bar. The preview covers the whole window, so without this it swallows
    /// every click up there — which both fired a spurious tap-to-focus AND made
    /// the window undraggable, because the drag never reached the title bar.
    static let topChromeHeight: CGFloat = 52

    /// Refuse to be the hit target in the chrome strip. Returning nil lets the
    /// event fall through to the window, which restores dragging and stops the
    /// toolbar area from acting like part of the image.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        // AppKit's origin is bottom-left, so the top strip is HIGH y.
        if local.y > bounds.height - Self.topChromeHeight { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.width > 0, bounds.height > 0 else { return }
        guard p.y <= bounds.height - Self.topChromeHeight else { return }
        // Flip to a top-left origin, which is what the sensor's region math uses.
        onTap?(CGPoint(x: p.x / bounds.width,
                       y: 1 - (p.y / bounds.height)))
    }
}
