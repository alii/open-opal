/// A launch attempt belongs to a capture session, not to the availability of
/// camera frames or the lifetime of the host process. In particular, quitting
/// the host during a call must not immediately launch it again.
struct CameraLaunchPolicy {
    private(set) var hasDemand = false
    private var attemptedForSession = false
    private var launchInFlight = false

    /// Returns true exactly when the caller should begin opening the host.
    mutating func updateDemand(_ active: Bool) -> Bool {
        hasDemand = active
        guard active else {
            attemptedForSession = false
            return false
        }
        guard !attemptedForSession else { return false }
        attemptedForSession = true

        // An opening host also serves a new session that starts before the
        // previous launch has completed. Never create concurrent requests.
        guard !launchInFlight else { return false }
        launchInFlight = true
        return true
    }

    mutating func launchCompleted() {
        launchInFlight = false
    }
}
