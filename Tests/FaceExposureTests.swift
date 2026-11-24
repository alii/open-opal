import Foundation

@main
struct FaceExposureTests {
    static func main() {
        // A face that answers each step the way the measured one did.
        func run(from dark: Double, bright: Double, seconds: Int, userSteps: Int = 0) -> (FaceExposure, changes: Int) {
            var control = FaceExposure(), now = Date(timeIntervalSince1970: 1_000), changes = 0
            for _ in 0..<(seconds * 2) {
                let before = control.offset
                let steps = Double(control.offset + userSteps)
                control.update(FaceLight(mean: min(dark + steps * 0.06, 1), bright: min(bright + steps * 0.10, 1)),
                               userSteps: userSteps, at: now)
                if control.offset != before { changes += 1 }
                now += 0.5
            }
            return (control, changes)
        }
        let dim = run(from: 0.365, bright: 0.66, seconds: 60)
        precondition(dim.0.offset == 2 && dim.changes == 2, "dim face: \(dim)")
        let fine = run(from: 0.50, bright: 0.75, seconds: 60)
        precondition(fine.0.offset == 0 && fine.changes == 0, "well lit face: \(fine)")
        let hot = run(from: 0.64, bright: 0.98, seconds: 60)
        precondition(hot.0.offset < 0 && hot.changes <= 3, "overexposed face: \(hot)")
        // Half the face already bright: do not push it past white.
        let split = run(from: 0.40, bright: 0.85, seconds: 60)
        precondition(split.0.offset == 0, "bright side limit: \(split)")
        // The user's own step is kept, not cancelled.
        let brighter = run(from: 0.50, bright: 0.70, seconds: 60, userSteps: 2)
        precondition(brighter.0.offset >= 0, "user step undone: \(brighter)")
        // Nobody in frame: holds, then eases back to nothing.
        var control = dim.0, now = Date(timeIntervalSince1970: 1_060)
        for _ in 0..<110 { control.update(nil, userSteps: 0, at: now); now += 0.5 }
        precondition(control.offset == 2, "let go too soon")
        for _ in 0..<60 { control.update(nil, userSteps: 0, at: now); now += 0.5 }
        precondition(control.offset == 0, "never let go")
        print("Face exposure: brightens a dim face, stops before white, does not hunt, keeps the user's step, lets go")
    }
}
