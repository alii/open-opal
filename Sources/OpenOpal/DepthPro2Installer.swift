import CoreML
import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "com.openopal", category: "depth")

/// Downloads, prepares and deletes the optional Depth Pro 2 model.
///
/// The app does not ship this model. Its weights are under Apple's research-only
/// model licence, so each person chooses to fetch them, from Apple's own
/// Hugging Face repo, and can remove them again.
@Observable
@MainActor
final class DepthPro2Installer {

    enum Status: Equatable {
        case notInstalled
        /// Fraction of the download done, 0...1.
        case downloading(Double)
        /// Downloaded, and Core ML is compiling it for this Mac.
        case preparing
        case installed
        case failed(String)
    }

    private(set) var status: Status
    var isInstalled: Bool { status == .installed }

    private let modelURL: URL
    private var task: Task<Void, Never>?

    init(modelURL: URL = DepthPro2.installedModelURL) {
        self.modelURL = modelURL
        status = FileManager.default.fileExists(atPath: modelURL.path) ? .installed : .notInstalled
    }

    func install() {
        guard task == nil, status != .installed else { return }
        status = .downloading(0)
        let destination = modelURL

        task = Task { [weak self] in
            let result: Status
            do {
                try await Self.fetch(
                    to: destination,
                    progress: { fraction in
                        Task { @MainActor in self?.downloaded(fraction) }
                    },
                    preparing: {
                        Task { @MainActor in self?.status = .preparing }
                    })
                result = .installed
            } catch where Self.isCancellation(error) {
                result = .notInstalled
            } catch {
                log.error("Depth Pro 2 install failed: \(error.localizedDescription, privacy: .public)")
                result = .failed(error.localizedDescription)
            }
            self?.status = result
            self?.task = nil
        }
    }

    func cancel() {
        task?.cancel()
    }

    func delete() {
        guard task == nil else { return }
        do {
            if FileManager.default.fileExists(atPath: modelURL.path) {
                try FileManager.default.removeItem(at: modelURL)
            }
            status = .notInstalled
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Progress arrives on its own schedule, so a late report must not undo
    /// "preparing" or "installed".
    private func downloaded(_ fraction: Double) {
        if case .downloading = status { status = .downloading(fraction) }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    // MARK: - The work, off the main actor

    /// An .mlpackage is a folder, so there is no single file to download. These
    /// three are the whole package.
    private nonisolated static let weights = "Data/com.apple.CoreML/weights/weight.bin"
    private nonisolated static let members = [
        "Manifest.json",
        "Data/com.apple.CoreML/model.mlmodel",
        weights,
    ]

    private nonisolated static func fetch(to destination: URL,
                                          progress: @escaping @Sendable (Double) -> Void,
                                          preparing: @Sendable () -> Void) async throws {
        let fm = FileManager.default
        // Everything happens in a scratch folder. The model only appears at its
        // real path once it is complete, so a half download is never loaded.
        let staging = fm.temporaryDirectory
            .appendingPathComponent("OpenOpal-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }

        let package = staging.appendingPathComponent("\(DepthPro2.resourceName).mlpackage",
                                                     isDirectory: true)
        for member in members {
            let file = package.appendingPathComponent(member)
            try fm.createDirectory(at: file.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            // The weights are 51 of the 52 MB, so they alone drive the bar.
            try await download(DepthPro2.downloadBase.appendingPathComponent(member), to: file,
                               progress: member == weights ? progress : nil)
        }

        preparing()
        let compiled = try await MLModel.compileModel(at: package)
        defer { try? fm.removeItem(at: compiled) }
        try Task.checkCancellation()

        try fm.createDirectory(at: destination.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: compiled)
        } else {
            try fm.moveItem(at: compiled, to: destination)
        }
    }

    private nonisolated static func download(_ url: URL, to file: URL,
                                             progress: (@Sendable (Double) -> Void)?) async throws {
        try Task.checkCancellation()
        let running = RunningDownload()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                let task = URLSession.shared.downloadTask(with: url) { temporary, response, error in
                    do {
                        if let error { throw error }
                        // Without this check a 404 page would be saved as the model.
                        guard let temporary,
                              (response as? HTTPURLResponse)?.statusCode == 200 else {
                            throw URLError(.badServerResponse)
                        }
                        // The temporary file is deleted when this handler returns.
                        try FileManager.default.moveItem(at: temporary, to: file)
                        done.resume()
                    } catch {
                        done.resume(throwing: error)
                    }
                }
                let observation = progress.map { report in
                    task.progress.observe(\.fractionCompleted) { value, _ in
                        report(value.fractionCompleted)
                    }
                }
                running.start(task, observation: observation)
            }
        } onCancel: {
            running.cancel()
        }
    }
}

/// Lets a cancelled Swift task stop the URLSession download under it, whichever
/// of the two gets there first.
private final class RunningDownload: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?
    private var cancelled = false

    func start(_ task: URLSessionDownloadTask, observation: NSKeyValueObservation?) {
        lock.lock()
        self.task = task
        self.observation = observation
        let alreadyCancelled = cancelled
        lock.unlock()
        if alreadyCancelled { task.cancel() }
        task.resume()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}
