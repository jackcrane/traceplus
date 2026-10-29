import AppKit
import Foundation
import Observation

/// Starts and stops Contrail (`contrail/`), the flight-planning test app, with Docker Compose.
@MainActor @Observable
public final class ContrailRunner {
    public enum State: Equatable { case stopped, starting, running, stopping }

    public var state: State = .stopped
    public private(set) var output: [String] = []
    public private(set) var status = "Not running"
    public let appURL = URL(string: "http://localhost:4400")!

    /// `contrail/` next to `Sources/`, resolved from this file; override with CONTRAIL_DIR.
    public static var directory: URL {
        if let path = ProcessInfo.processInfo.environment["CONTRAIL_DIR"] { return URL(fileURLWithPath: path) }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("contrail")
    }

    private var process: Process?
    private var partial = ""

    public init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutDownSynchronously() }
        }
    }

    public var isActive: Bool { state != .stopped }

    /// The app runs in a container, so a receiver on this Mac's loopback must be addressed by the host alias.
    static func containerEndpoint(_ endpoint: String) -> String {
        let trimmed = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.replacingOccurrences(of: "127.0.0.1", with: "host.docker.internal").replacingOccurrences(of: "localhost", with: "host.docker.internal")
    }

    public func start(endpoint: String) {
        guard state == .stopped else { return }
        let directory = Self.directory
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("docker-compose.yml").path) else {
            status = "Couldn’t find contrail at \(directory.path)"
            return
        }
        output = []; partial = ""; state = .starting; status = "Building and starting containers…"

        let process = Process()
        // A login+interactive shell so `docker` is on PATH even when launched from Finder.
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lic", "exec docker compose up --build --abort-on-container-exit --no-color"]
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["OTEL_EXPORTER_OTLP_ENDPOINT"] = Self.containerEndpoint(endpoint)
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.append(text) }
        }
        process.terminationHandler = { [weak self] finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            let code = finished.terminationStatus
            Task { @MainActor in
                guard let self else { return }
                self.process = nil
                self.tearDown()
                self.state = .stopped
                self.status = code == 0 || code == 130 || code == 143 ? "Stopped" : "Exited with code \(code) — is Docker running?"
            }
        }
        do {
            try process.run()
            self.process = process
        } catch {
            state = .stopped; status = "Couldn’t start: \(error.localizedDescription)"
        }
    }

    /// SIGTERM makes `docker compose up` stop its containers gracefully (services flush telemetry first).
    public func stop() {
        guard let process, state != .stopping else { return }
        state = .stopping; status = "Stopping…"
        process.terminate()
    }

    public func openApp() { NSWorkspace.shared.open(appURL) }
    public func revealInFinder() { NSWorkspace.shared.activateFileViewerSelecting([Self.directory]) }

    /// Remove the stopped containers (there are no volumes to keep).
    private func tearDown() {
        let cleanup = Process()
        cleanup.executableURL = URL(fileURLWithPath: "/bin/zsh")
        cleanup.arguments = ["-lic", "docker compose down --remove-orphans"]
        cleanup.currentDirectoryURL = Self.directory
        try? cleanup.run()
    }

    private func shutDownSynchronously() {
        guard let process else { return }
        process.terminate()
        process.waitUntilExit()
    }

    private func append(_ text: String) {
        let clean = text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        partial += clean
        var lines = partial.components(separatedBy: "\n")
        partial = lines.removeLast()
        output.append(contentsOf: lines.filter { !$0.isEmpty })
        if output.count > 400 { output.removeFirst(output.count - 400) }
        if state == .starting, lines.contains(where: { $0.contains("Contrail is ready") }) { state = .running; status = "Running at localhost:4400" }
    }
}
