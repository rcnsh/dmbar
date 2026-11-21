import Foundation

/// Runs `dmbard`, the backend bundled beside the app's executable, and says
/// where it is listening.
///
/// With `DMBAR_ADDR` and `DMBAR_TOKEN` set, it starts nothing and uses the
/// daemon already running there, such as `make run`.
final class Daemon {
    nonisolated struct Endpoint: Sendable {
        var base: URL
        var token: String
    }

    nonisolated enum Failure: LocalizedError {
        case missing, noAddress(String)
        var errorDescription: String? {
            switch self {
            case .missing: "dmbard isn't in the app bundle."
            case .noAddress(let why): why.isEmpty ? "dmbard didn't start." : why
            }
        }
    }

    private var process: Process?
    /// Where the running daemon listens.
    private var endpoint: Endpoint?
    /// Kept open: dmbard exits when its stdin closes, so it can't outlive the app.
    private var stdin: Pipe?
    /// How long a new daemon gets to say where it listens.
    static let readyTimeout: Duration = .seconds(15)
    /// Past this size the log starts again.
    private static let maxLogBytes = 2_000_000

    static var logURL: URL {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appending(path: "Logs/dmbar")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "dmbard.log")
    }

    func start() async throws -> Endpoint {
        let env = ProcessInfo.processInfo.environment
        if let addr = env["DMBAR_ADDR"], let token = env["DMBAR_TOKEN"], let url = URL(string: "http://\(addr)/") {
            return Endpoint(base: url, token: token)
        }
        // Still running: only the connection to it dropped.
        if let endpoint, process?.isRunning == true { return endpoint }
        guard let exe = Bundle.main.url(forAuxiliaryExecutable: "dmbard") else { throw Failure.missing }

        // 24 random bytes; passed in the environment so it isn't in `ps`.
        let token = (0..<24).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
        let p = Process()
        p.executableURL = exe
        p.arguments = ["-exit-with-stdin"] + (env["DMBAR_DEMO"] == nil ? [] : ["-demo"])
        p.environment = env.merging(["DMBAR_TOKEN": token]) { $1 }
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        // Appended to, so a daemon that keeps failing doesn't erase why.
        let size = (try? FileManager.default.attributesOfItem(atPath: Self.logURL.path)[.size] as? Int) ?? 0
        if size == 0 || size > Self.maxLogBytes {
            FileManager.default.createFile(atPath: Self.logURL.path, contents: nil)
        }
        let log = try FileHandle(forWritingTo: Self.logURL)
        try log.seekToEnd()
        p.standardError = log
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.process === p else { return }
                self.process = nil
                self.endpoint = nil
            }
        }
        try p.run()
        process = p
        stdin = input

        // The first line of stdout is {"addr":"127.0.0.1:port"}. A daemon
        // that never prints it is stopped, which closes the pipe and ends
        // the wait.
        struct Ready: Decodable { var addr: String }
        let watchdog = Task {
            try await Task.sleep(for: Self.readyTimeout)
            p.terminate()
        }
        defer { watchdog.cancel() }
        for try await line in output.fileHandleForReading.bytes.lines {
            if let ready = try? JSONDecoder().decode(Ready.self, from: Data(line.utf8)),
               let url = URL(string: "http://\(ready.addr)/") {
                let found = Endpoint(base: url, token: token)
                endpoint = found
                return found
            }
        }
        process = nil
        // It exited without saying where it listens; its log says why.
        let tail = (try? String(contentsOf: Self.logURL, encoding: .utf8))?
            .split(separator: "\n").last.map(String.init) ?? ""
        throw Failure.noAddress(tail)
    }

    func stop() {
        guard let p = process else { return }
        process = nil
        endpoint = nil
        p.terminate()
        stdin = nil
    }
}
