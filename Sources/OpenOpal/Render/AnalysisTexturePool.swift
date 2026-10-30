import Foundation
import Metal

/// Results and GPU readers keep a lease; inference only reuses released slots.
final class AnalysisTexturePool: @unchecked Sendable {
    final class Lease: @unchecked Sendable {
        let texture: MTLTexture
        private let pool: AnalysisTexturePool
        private let index: Int

        fileprivate init(texture: MTLTexture, pool: AnalysisTexturePool, index: Int) {
            self.texture = texture
            self.pool = pool
            self.index = index
        }

        deinit { pool.release(index) }
    }

    private struct Slot {
        var texture: MTLTexture?
        var inUse = false
    }

    private let device: MTLDevice
    private let format: MTLPixelFormat
    private let lock = NSLock()
    private var slots: [Slot]

    init(device: MTLDevice, format: MTLPixelFormat, capacity: Int) {
        self.device = device
        self.format = format
        slots = Array(repeating: Slot(), count: max(capacity, 1))
    }

    /// Exhaustion drops analysis rather than overwriting a retained result.
    func acquire(width: Int, height: Int) -> Lease? {
        lock.withLock {
            guard let index = slots.firstIndex(where: { !$0.inUse }) else { return nil }
            if slots[index].texture?.width != width || slots[index].texture?.height != height {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: format, width: width, height: height, mipmapped: false)
                descriptor.usage = [.shaderRead]
                descriptor.storageMode = .shared
                slots[index].texture = device.makeTexture(descriptor: descriptor)
            }
            guard let texture = slots[index].texture else { return nil }
            slots[index].inUse = true
            return Lease(texture: texture, pool: self, index: index)
        }
    }

    private func release(_ index: Int) {
        lock.withLock { slots[index].inUse = false }
    }
}
