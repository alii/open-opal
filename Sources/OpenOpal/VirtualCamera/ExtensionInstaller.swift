import Foundation
import Observation
import OSLog
import SystemExtensions

private let log = Logger(subsystem: "com.openopal", category: "sysext")

/// Drives the OS's system-extension activation flow for the virtual camera.
///
/// Installation is a system affair: the user approves it once in System
/// Settings, macOS copies the extension out of our bundle, and from then on the
/// system owns its lifecycle — it runs even when this app doesn't.
@Observable
@MainActor
final class ExtensionInstaller: NSObject {

    static let extensionID = "sh.alistair.open-opal.camera"

    enum Status: Equatable {
        case unknown
        case installing
        case needsApproval
        case installed
        case failed(String)
    }

    private(set) var status: Status = .unknown

    /// What the app can actually see, from inside its own process. macOS reports
    /// several very different failures as the same misleading "Extension not
    /// found in App bundle" — including "your app isn't in /Applications" — so
    /// guessing from the outside is hopeless. Ask the app directly.
    private(set) var diagnostics: [String] = []

    func diagnose() {
        var out: [String] = []
        let bundle = Bundle.main
        let path = bundle.bundleURL.path

        out.append("app path: \(path)")
        out.append("in /Applications: \(path.hasPrefix("/Applications/") ? "yes" : "NO — macOS refuses system extensions for apps outside /Applications")")
        out.append("app id: \(bundle.bundleIdentifier ?? "nil")")

        let sysexts = bundle.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions")
        let items = (try? FileManager.default.contentsOfDirectory(
            at: sysexts, includingPropertiesForKeys: nil)) ?? []
        if items.isEmpty {
            out.append("extensions found: NONE at Contents/Library/SystemExtensions")
        }
        for item in items {
            guard let ext = Bundle(url: item) else {
                out.append("\(item.lastPathComponent): not a loadable bundle")
                continue
            }
            let id = ext.bundleIdentifier ?? "nil"
            let pkg = ext.infoDictionary?["CFBundlePackageType"] as? String ?? "nil"
            out.append("extension: \(id)")
            out.append("  package type: \(pkg)\(pkg == "SYSX" ? "" : "  ← must be SYSX")")
            out.append("  matches requested id: \(id == Self.extensionID ? "yes" : "NO (want \(Self.extensionID))")")
            let exec = ext.executableURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            out.append("  executable present: \(exec ? "yes" : "NO")")
        }

        // Other copies of this app confuse the daemon: it resolves the bundle ID
        // through LaunchServices, and if it lands on a stale build outside
        // /Applications it refuses — then blames the bundle.
        out.append("translocated: \(path.contains("/AppTranslocation/") ? "YES — move the app to /Applications and relaunch" : "no")")

        diagnostics = out
        for line in out { log.info("\(line, privacy: .public)") }
    }

    func install() {
        diagnose()
        status = .installing
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Self.extensionID, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func uninstall() {
        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: Self.extensionID, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }
}

extension ExtensionInstaller: OSSystemExtensionRequestDelegate {

    nonisolated func request(_ request: OSSystemExtensionRequest,
                             actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension ext: OSSystemExtensionProperties)
        -> OSSystemExtensionRequest.ReplacementAction {
        // Always upgrade to the copy in this bundle.
        .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in
            log.info("system extension awaiting approval in System Settings")
            self.status = .needsApproval
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest,
                             didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor in
            log.info("system extension activated (result \(result.rawValue))")
            self.status = .installed
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest,
                             didFailWithError error: Error) {
        let ns = error as NSError
        // The localized string is unreliable — macOS reports several distinct
        // failures as "Extension not found in App bundle". The numeric code is
        // the truth.
        let meaning: String
        switch ns.code {
        case 1:  meaning = "unknown"
        case 2:  meaning = "missingEntitlement"
        case 3:  meaning = "unsupportedParentBundleLocation — app must be in /Applications"
        case 4:  meaning = "extensionNotFound"
        case 5:  meaning = "extensionMissingIdentifier"
        case 6:  meaning = "duplicateExtensionIdentifier"
        case 7:  meaning = "unknownExtensionCategory"
        case 8:  meaning = "codeSignatureInvalid"
        case 9:  meaning = "validationFailed"
        case 10: meaning = "forbiddenBySystemPolicy"
        case 11: meaning = "requestCanceled"
        case 12: meaning = "requestSuperseded"
        case 13: meaning = "authorizationRequired"
        default: meaning = "code \(ns.code)"
        }

        Task { @MainActor in
            log.error("sysext failed [\(ns.domain, privacy: .public) code=\(ns.code) — \(meaning, privacy: .public)]: \(error.localizedDescription, privacy: .public)")
            self.diagnose()
            self.diagnostics.insert("error \(ns.code): \(meaning)", at: 0)
            self.status = .failed(error.localizedDescription)
        }
    }
}
