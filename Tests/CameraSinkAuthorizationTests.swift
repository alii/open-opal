import Foundation
import Security

@main
struct CameraSinkAuthorizationTests {
    static func main() throws {
        precondition(CommandLine.arguments.count == 4,
                     "Usage: sink-authorization-tests HOST_IDENTIFIER TEAM_IDENTIFIER INFO_PLIST")
        let hostID = CommandLine.arguments[1]
        let teamID = CommandLine.arguments[2]
        let hostInfo = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
        let flags = SecCSFlags()
        var code: SecCode?
        let attributes = [
            kSecGuestAttributePid as String: NSNumber(value: getpid()),
            kSecGuestAttributeDynamicCode as String: true,
            kSecGuestAttributeDynamicCodeInfoPlist as String: hostInfo
        ] as CFDictionary
        precondition(SecCodeCopyGuestWithAttributes(nil, attributes, flags, &code) == errSecSuccess)
        precondition(SecCodeCheckValidity(code!, flags, nil) == errSecSuccess,
                     "Validate the fixture before testing its rejection")
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        precondition(SecCodeCopyStaticCode(code!, flags, &staticCode) == errSecSuccess)
        precondition(SecCodeCopySigningInformation(staticCode!, flags, &information) == errSecSuccess)
        let identifier = (information as? [String: Any])?[kSecCodeInfoIdentifier as String] as? String
        precondition(identifier == hostID, "Sign the fixture with the host identifier")
        let authorizer = SinkClientAuthorizer(hostIdentifier: hostID, teamIdentifier: teamID,
                                              hostInfoPlist: hostInfo)!
        precondition(!authorizer.isAuthorized(pid: -1))
        precondition(!authorizer.isAuthorized(pid: getpid()))
        precondition(SinkClientAuthorizer(hostIdentifier: "", teamIdentifier: teamID,
                                         hostInfoPlist: hostInfo) == nil)
        precondition(SinkClientAuthorizer(hostIdentifier: hostID, teamIdentifier: "",
                                         hostInfoPlist: hostInfo) == nil)
        precondition(SinkClientAuthorizer() == nil)
        print("Sink authorization: valid ad-hoc code with the matching host identifier is rejected")
    }
}
