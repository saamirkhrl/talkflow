import Foundation

/// Everything needed to get the local Whisper server running on a Mac that has
/// never seen talkflow: find (or install) `whisper-server`, fetch the model, and
/// register the LaunchAgent that keeps it warm.
///
/// Nothing here ever overwrites something that already exists. On a machine
/// that is already set up (a LaunchAgent plist is present, the model is on disk)
/// the only thing this does is read, so running it against a working install is
/// safe.
enum SpeechEngine {
    static let port = 8178
    static let agentLabel = "com.samir.talkflow.whisperserver"
    static let modelFileName = "ggml-small.en.bin"
    static let modelDownloadURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin")!

    /// The real file is 487,614,201 bytes. Anything well under that is a partial
    /// or failed download and must not be mistaken for a usable model.
    static let minimumModelBytes: Int64 = 480_000_000

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static var modelPath: URL {
        home.appendingPathComponent("Library/Application Support/TalkFlow/models/\(modelFileName)")
    }
    static var logDirectory: URL { home.appendingPathComponent("Library/Logs/TalkFlow") }
    static var agentPlistURL: URL {
        home.appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    // MARK: - What is already there

    static func serverBinary() -> String? {
        ["/opt/homebrew/bin/whisper-server", "/usr/local/bin/whisper-server"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func brewBinary() -> String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var modelIsComplete: Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: modelPath.path)
        return ((attributes?[.size] as? NSNumber)?.int64Value ?? 0) >= minimumModelBytes
    }

    /// Installed means "set up", not "running right now". The server is started
    /// by a LaunchAgent at login at about the same time as talkflow itself, so
    /// using liveness here would pop the setup window on every login.
    static var isInstalled: Bool {
        serverBinary() != nil && modelIsComplete && FileManager.default.fileExists(atPath: agentPlistURL.path)
    }

    /// Any HTTP answer at all means the server is up; whisper-server serves a
    /// small HTML page at `/`.
    static func isResponding(completion: @escaping (Bool) -> Void) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        request.timeoutInterval = 1.5
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        URLSession(configuration: configuration).dataTask(with: request) { _, response, _ in
            completion(response is HTTPURLResponse)
        }.resume()
    }

    /// Blocking variant for background threads.
    static func isRespondingBlocking() -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var alive = false
        isResponding { alive = $0; semaphore.signal() }
        semaphore.wait()
        return alive
    }

    // MARK: - Installing

    struct CommandResult {
        let succeeded: Bool
        /// The last lines of output, for showing the user what went wrong.
        let tail: String
    }

    /// Runs `brew install whisper-cpp`, reporting each line of output as it
    /// arrives. Blocking: call from a background thread.
    static func installWhisperCpp(onLine: @escaping (String) -> Void) -> CommandResult {
        guard let brew = brewBinary() else {
            return CommandResult(succeeded: false, tail: "Homebrew is not installed.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: brew)
        process.arguments = ["install", "whisper-cpp"]
        var environment = ProcessInfo.processInfo.environment
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
        environment["HOMEBREW_NO_INSTALL_UPGRADE"] = "1"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        environment["NONINTERACTIVE"] = "1"
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let lock = NSLock()
        var lines: [String] = []
        var pending = ""
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            lock.lock(); defer { lock.unlock() }
            pending += text
            while let newline = pending.firstIndex(of: "\n") {
                let line = String(pending[..<newline]).trimmingCharacters(in: .whitespaces)
                pending.removeSubrange(...newline)
                if !line.isEmpty { lines.append(line); onLine(line) }
            }
        }

        do { try process.run() } catch {
            return CommandResult(succeeded: false, tail: error.localizedDescription)
        }
        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil

        lock.lock(); defer { lock.unlock() }
        return CommandResult(succeeded: process.terminationStatus == 0, tail: lines.suffix(6).joined(separator: "\n"))
    }

    /// Writes the LaunchAgent that keeps whisper-server resident, if there is not
    /// one already, and starts it. An existing plist is left exactly as it is: it
    /// may have been edited (a different model, a different binary path).
    /// Blocking: call from a background thread.
    static func startServer() throws {
        guard let binary = serverBinary() else {
            throw EngineError("whisper-server is not installed.")
        }
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)

        if !FileManager.default.fileExists(atPath: agentPlistURL.path) {
            let log = logDirectory.appendingPathComponent("whisper-server.log").path
            let plist: [String: Any] = [
                "Label": agentLabel,
                "ProgramArguments": [binary, "-m", modelPath.path, "--host", "127.0.0.1", "--port", String(port), "-nt"],
                "RunAtLoad": true,
                "KeepAlive": true,
                "StandardOutPath": log,
                "StandardErrorPath": log
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try FileManager.default.createDirectory(
                at: agentPlistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: agentPlistURL, options: .atomic)
        }

        let domain = "gui/\(getuid())"
        // bootstrap fails harmlessly when the agent is already loaded; kickstart
        // then starts it if it is loaded but not running.
        _ = runQuietly("/bin/launchctl", ["bootstrap", domain, agentPlistURL.path])
        _ = runQuietly("/bin/launchctl", ["kickstart", "\(domain)/\(agentLabel)"])
    }

    /// Polls until the server answers. Loading the model takes a few seconds.
    static func waitUntilResponding(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isRespondingBlocking() { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    @discardableResult
    private static func runQuietly(_ path: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

struct EngineError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Downloads one file with progress. The file only appears at its destination
/// once it is complete and big enough, so a dropped connection can never leave
/// something there that looks like a finished model.
final class FileDownloader: NSObject, URLSessionDownloadDelegate {
    private let destination: URL
    private let minimumBytes: Int64
    private let onProgress: (Double) -> Void
    private let onFinish: (Error?) -> Void
    private var session: URLSession?
    private var finished = false

    init(
        destination: URL,
        minimumBytes: Int64,
        onProgress: @escaping (Double) -> Void,
        onFinish: @escaping (Error?) -> Void
    ) {
        self.destination = destination
        self.minimumBytes = minimumBytes
        self.onProgress = onProgress
        self.onFinish = onFinish
    }

    func start(url: URL) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        session.downloadTask(with: url).resume()
    }

    func cancel() {
        session?.invalidateAndCancel()
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is deleted when this method returns, so it has to be
        // moved here, synchronously.
        do {
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw EngineError("The download server answered HTTP \(http.statusCode).")
            }
            let size = (try FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard size >= minimumBytes else {
                throw EngineError("The download ended early (\(size) bytes). Check your connection and try again.")
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            complete(nil)
        } catch {
            complete(error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { complete(error) }
    }

    private func complete(_ error: Error?) {
        guard !finished else { return }
        finished = true
        session?.finishTasksAndInvalidate()
        onFinish(error)
    }
}
