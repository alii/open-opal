import Foundation
import Security

@main
struct CameraSinkAuthorizationTests {
    static func main() {
        let hostID = "com.jamiedubs.open-opal"
        var selfCode: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        precondition(SecCodeCopySelf(SecCSFlags(), &selfCode) == errSecSuccess)
        precondition(SecCodeCopyStaticCode(selfCode!, SecCSFlags(), &staticCode) == errSecSuccess)
        precondition(SecCodeCopySigningInformation(staticCode!, SecCSFlags(), &information) == errSecSuccess)
        let identifier = (information as? [String: Any])?[kSecCodeInfoIdentifier as String] as? String
        precondition(identifier == hostID, "Sign this fixture ad hoc with the host identifier")
        let authorizer = SinkClientAuthorizer(hostIdentifier: hostID, teamIdentifier: "GFU82T28YT")!
        precondition(!authorizer.isAuthorized(signingID: nil, pid: getpid()))
        precondition(!authorizer.isAuthorized(signingID: "another.app", pid: getpid()))
        precondition(!authorizer.isAuthorized(signingID: hostID, pid: -1))
        precondition(!authorizer.isAuthorized(signingID: hostID, pid: getpid()))
        precondition(SinkClientAuthorizer(hostIdentifier: "", teamIdentifier: "GFU82T28YT") == nil)
        precondition(SinkClientAuthorizer(hostIdentifier: hostID, teamIdentifier: "") == nil)
        precondition(SinkClientAuthorizer() == nil)
        print("Sink authorization: an ad-hoc process with the real host identifier is rejected")
    }
}
