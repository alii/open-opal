import Foundation

/// Accessed only on the provider's serial client queue.
struct SinkSession {
    private(set) var clientID: UUID?
    private var generation: UInt64 = 0
    private var isStreaming = false

    mutating func authorize(_ id: UUID) -> Bool {
        guard clientID == nil || clientID == id else { return false }
        clientID = id
        return true
    }

    mutating func start() -> UInt64? {
        guard clientID != nil, !isStreaming else { return nil }
        generation &+= 1
        isStreaming = true
        return generation
    }

    mutating func stop() {
        generation &+= 1
        isStreaming = false
        clientID = nil
    }

    func accepts(_ id: UUID, generation: UInt64) -> Bool {
        isStreaming && clientID == id && self.generation == generation
    }
}
