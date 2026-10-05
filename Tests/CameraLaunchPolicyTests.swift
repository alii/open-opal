/// No camera, application launch, or operating-system registration is involved.
/// Compile this file alongside CameraLaunchPolicy.swift.
@main
struct CameraLaunchPolicyTests {
    static func main() {
        var policy = CameraLaunchPolicy()
        precondition(!policy.updateDemand(false))
        precondition(policy.updateDemand(true)) // Also handles initial positive state.
        precondition(!policy.updateDemand(true)) // More clients / repeated notification.
        policy.launchCompleted()
        precondition(!policy.updateDemand(true)) // Booting, unplugged, or user quit.
        precondition(!policy.updateDemand(false))
        precondition(policy.updateDemand(true)) // A new capture session may launch again.
        // A session ending and restarting during launch shares that pending
        // launch. Its eventual completion must not launch a second instance.
        precondition(!policy.updateDemand(false))
        precondition(!policy.updateDemand(true))
        policy.launchCompleted()
        precondition(!policy.updateDemand(true))
        precondition(!policy.updateDemand(false))
        precondition(policy.updateDemand(true))

        // Completing after demand ends does not resurrect a stopped session.
        precondition(!policy.updateDemand(false))
        policy.launchCompleted()
        precondition(!policy.hasDemand)
        precondition(!policy.updateDemand(false))
        precondition(policy.updateDemand(true))
        print("Camera launch policy: passed session, duplicate, and in-flight checks")
    }
}
