import Foundation
import Observation
import ServiceManagement

/// The login helper watches virtual-camera demand without opening the camera.
@Observable
@MainActor
final class AutoLaunchController {
    private(set) var status: SMAppService.Status = .notRegistered
    private(set) var isChanging = false
    private(set) var error: String?

    private var service: SMAppService? {
        guard let identifier = Bundle.main.bundleIdentifier else { return nil }
        return SMAppService.loginItem(identifier: identifier + ".launcher")
    }

    var isIncludedInApp: Bool {
        guard let identifier = Bundle.main.bundleIdentifier,
              let helper = Bundle(url: Bundle.main.bundleURL
                .appendingPathComponent("Contents/Library/LoginItems/OpenOpalLauncher.app")),
              helper.bundleIdentifier == identifier + ".launcher",
              let executable = helper.executableURL else { return false }
        return FileManager.default.fileExists(atPath: executable.path)
    }

    var isEnabled: Bool { status == .enabled || status == .requiresApproval }

    init() { refresh() }

    func refresh() { status = service?.status ?? .notFound }

    func setEnabled(_ enabled: Bool) {
        guard !isChanging, let service, isIncludedInApp else { return }
        isChanging = true
        error = nil
        Task {
            defer { refresh(); isChanging = false }
            do {
                if enabled {
                    if service.status != .enabled && service.status != .requiresApproval {
                        try service.register()
                    }
                } else if service.status != .notRegistered && service.status != .notFound {
                    try await service.unregister()
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }
}
