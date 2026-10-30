import Foundation

@main
struct CameraSinkSessionTests {
    static func main() {
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        var session = SinkSession()
        precondition(session.start() == nil)
        precondition(session.authorize(first))
        precondition(session.authorize(first))
        precondition(!session.authorize(second))
        let firstGeneration = session.start()!
        precondition(session.start() == nil)
        precondition(session.accepts(first, generation: firstGeneration))
        precondition(!session.accepts(second, generation: firstGeneration))
        session.stop()
        precondition(!session.accepts(first, generation: firstGeneration))
        precondition(session.authorize(second))
        let secondGeneration = session.start()!
        precondition(!session.accepts(first, generation: firstGeneration))
        precondition(session.accepts(second, generation: secondGeneration))
        session.stop()
        precondition(session.authorize(second))
        let restartedGeneration = session.start()!
        precondition(!session.accepts(second, generation: secondGeneration))
        precondition(session.accepts(second, generation: restartedGeneration))
        print("Sink sessions: stopped clients and old callbacks after same-client restart are rejected")
    }
}
