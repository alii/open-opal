import Foundation
import Security

/// Trust the host identifier and Apple developer team sealed into this extension.
struct SinkClientAuthorizer {
    private let hostIdentifier: String
    private let requirement: SecRequirement

    init?() {
        let flags = SecCSFlags()
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf(flags, &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, flags, nil) == errSecSuccess,
              SecCodeCopyStaticCode(code, flags, &staticCode) == errSecSuccess,
              let staticCode,
              SecCodeCopySigningInformation(staticCode,
                  SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let identifier = values[kSecCodeInfoIdentifier as String] as? String,
              identifier.hasSuffix(".camera"),
              let team = values[kSecCodeInfoTeamIdentifier as String] as? String else { return nil }
        self.init(hostIdentifier: String(identifier.dropLast(".camera".count)),
                  teamIdentifier: team)
    }

    init?(hostIdentifier: String, teamIdentifier: String) {
        guard !hostIdentifier.isEmpty, !teamIdentifier.isEmpty else { return nil }
        func quoted(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let expression = "anchor apple generic and identifier \(quoted(hostIdentifier)) "
            + "and certificate leaf[subject.OU] = \(quoted(teamIdentifier))"
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(expression as CFString, SecCSFlags(),
                                             &requirement) == errSecSuccess,
              let requirement else { return nil }
        self.hostIdentifier = hostIdentifier
        self.requirement = requirement
    }

    func isAuthorized(signingID: String?, pid: pid_t) -> Bool {
        guard signingID == hostIdentifier, pid > 0 else { return false }
        var code: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &code)
                == errSecSuccess, let code else { return false }
        return SecCodeCheckValidity(code, SecCSFlags(), requirement) == errSecSuccess
    }
}
