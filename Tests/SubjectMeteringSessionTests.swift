import Foundation

/// Camera-free checks of the production exposure-region policy.
@main
struct SubjectMeteringSessionTests {
    static func main() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let subject = CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.6)
        var session = SubjectMeteringSession()
        let first = session.region(for: subject, at: now)!
        precondition(abs(first.minX - 0.18) < 0.000001)
        precondition(abs(first.minY - 0.2) < 0.000001)
        precondition(abs(first.width - 0.24) < 0.000001)
        precondition(abs(first.height - 0.27) < 0.000001)
        precondition(session.region(for: subject, at: now) == nil)
        precondition(session.region(for: subject.offsetBy(dx: 0.005, dy: 0), at: now) == nil)

        let moved = subject.offsetBy(dx: 0.1, dy: 0)
        let movedRegion = session.region(for: moved, at: now)!
        precondition(session.region(for: moved, at: now) == nil)

        // The new pipeline needs a region even when the subject did not move.
        session.reset()
        precondition(session.region(for: moved, at: now) == movedRegion)
        precondition(session.region(for: moved, at: now) == nil)

        session.suspend(until: now.addingTimeInterval(5))
        precondition(session.region(for: moved, at: now) == nil)
        precondition(session.region(for: moved, at: now.addingTimeInterval(4.999)) == nil)
        precondition(session.region(for: subject, at: now.addingTimeInterval(4.999)) == nil)
        precondition(session.region(for: moved, at: now.addingTimeInterval(5)) == movedRegion)
        precondition(session.region(for: moved, at: now.addingTimeInterval(6)) == nil)

        // Reconnect also discards the previous pipeline's tap-to-focus hold.
        session.suspend(until: now.addingTimeInterval(10))
        session.reset()
        precondition(session.region(for: moved, at: now) == movedRegion)
        session.reset()
        let small = session.region(for: CGRect(x: 0.2, y: 0.3, width: 0.1, height: 0.01), at: now)!
        precondition(small.height == 0.05)
        print("Subject metering: passed region, dead-band, unchanged reconnect, and tap-hold reset checks")
    }
}
