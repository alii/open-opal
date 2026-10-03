import Foundation
import OSLog

private let log = Logger(subsystem: "com.openopal.launcher", category: "lifecycle")

/// Resolve only our enclosing app. A copied helper or a different app with a
/// similar name must not launch an arbitrary bundle through Launch Services.
private func hostApplication(for helper: Bundle) -> URL? {
    let helperURL = helper.bundleURL.resolvingSymlinksInPath()
    let loginItems = helperURL.deletingLastPathComponent()
    let library = loginItems.deletingLastPathComponent()
    let contents = library.deletingLastPathComponent()
    let hostURL = contents.deletingLastPathComponent()
    guard helperURL.pathExtension == "app",
          loginItems.lastPathComponent == "LoginItems",
          library.lastPathComponent == "Library",
          contents.lastPathComponent == "Contents",
          hostURL.pathExtension == "app",
          let host = Bundle(url: hostURL),
          let identifier = host.bundleIdentifier, !identifier.isEmpty,
          helper.bundleIdentifier == identifier + ".launcher",
          let executable = host.executableURL,
          FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
    return hostURL
}

if let hostURL = hostApplication(for: .main) {
    let watcher = CameraDemandWatcher(hostURL: hostURL)
    watcher.start()
    withExtendedLifetime(watcher) { RunLoop.main.run() }
} else {
    log.error("Launcher must be embedded in its matching host app's Contents/Library/LoginItems directory.")
}
