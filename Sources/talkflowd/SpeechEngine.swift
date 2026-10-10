import Foundation

/// Everything needed to get the local Whisper server running on a Mac that has
/// never seen talkflow: find `whisper-server`, fetch the model, and register
/// the LaunchAgent that keeps it warm.
///
/// `whisper-server` ships inside talkflow.app (`Contents/Helpers`), built from
/// a pinned whisper.cpp tag by scripts/build-whisper-macos.sh, so a Mac needs
/// no Homebrew. A Homebrew `whisper-server` is used only when this copy has no
/// bundled one (a bare development build).
///
/// Nothing here overwrites something that already exists, with one exception:
/// a LaunchAgent that runs Homebrew's `whisper-server` (what talkflow set up
/// before the engine was bundled), or a program that is no longer there, is
/// pointed at the bundled engine (`agentPlan`). Everything else in that plist,
/// such as the model and port, is kept. On a machine that is already set up
/// that way, the only thing this does is read.
enum SpeechEngine {
    static let port = 8178
    static let agentLabel = "com.samir.talkflow.whisperserver"
    /// small.en quantized to 5 bits. Measured on this M4 against the f16 file
    /// it replaces, over the same 10 clips: the server's footprint went from
    /// about 700 MB to about 395 MB, word error rate was unchanged (2.73% on
    /// both) and latency stayed within noise (0.25s for 3s of speech, 0.98s
    /// vs 1.24s for 45s).
    static let modelFileName = "ggml-small.en-q5_1.bin"
    static let modelDownloadURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en-q5_1.bin")!

    /// The real file is 190,098,681 bytes. Anything well under that is a partial
    /// or failed download and must not be mistaken for a usable model.
    static let minimumModelBytes: Int64 = 185_000_000

    /// The full-precision small.en that talkflow used before. A Mac that has it
    /// keeps working on it until the new one has downloaded in the background
    /// (`upgradeModel`), which then deletes it.
    static let legacyModelFileName = "ggml-small.en.bin"
    /// The real file is 487,614,201 bytes.
    static let legacyMinimumModelBytes: Int64 = 480_000_000

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static var modelPath: URL {
        home.appendingPathComponent("Library/Application Support/TalkFlow/models/\(modelFileName)")
    }
    static var legacyModelPath: URL {
        modelPath.deletingLastPathComponent().appendingPathComponent(legacyModelFileName)
    }
    static var logDirectory: URL { home.appendingPathComponent("Library/Logs/TalkFlow") }
    static var agentPlistURL: URL {
        home.appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    // MARK: - What is already there

    /// Where the engine sits inside talkflow.app (release.sh, deploy.sh and
    /// install.sh put it there).
    static let bundledServerSubpath = "Contents/Helpers/whisper-server"
    /// Homebrew's, on Apple Silicon and on Intel. A fallback only.
    static let homebrewServerPaths = ["/opt/homebrew/bin/whisper-server", "/usr/local/bin/whisper-server"]

    /// Where this copy's own engine would be, whether or not it is there. Nil
    /// for a bare `.build` binary, which has no bundle to carry one.
    static var bundledServerPath: String? {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { return nil }
        return bundle.appendingPathComponent(bundledServerSubpath).path
    }

    /// The bundled engine, when it is there and runnable.
    static var bundledServerBinary: String? {
        bundledServerPath.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
    }

    /// Shown by setup when talkflow.app has lost its engine (a damaged copy).
    static let missingBundledEngineMessage =
        "The speech engine is missing from this copy of talkflow. Download talkflow again from talkflow.live and replace this copy, then press Try again."

    /// The bundled engine first, then Homebrew's.
    static func serverBinary() -> String? {
        resolveServerBinary(bundled: bundledServerPath) { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The order `serverBinary` uses, with the file check passed in, for
    /// `--streamtest`.
    static func resolveServerBinary(
        bundled: String?, homebrew: [String] = homebrewServerPaths, isExecutable: (String) -> Bool
    ) -> String? {
        ([bundled].compactMap { $0 } + homebrew).first(where: isExecutable)
    }

    /// A Homebrew install, by prefix: `/opt/homebrew` on Apple Silicon,
    /// `/usr/local` on Intel (its `bin` links and its `Cellar` alike).
    static func isHomebrewPath(_ path: String) -> Bool {
        path.hasPrefix("/opt/homebrew/") || path.hasPrefix("/usr/local/")
    }

    static func brewBinary() -> String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var modelIsComplete: Bool { fileSize(modelPath) >= minimumModelBytes }
    static var legacyModelIsComplete: Bool { fileSize(legacyModelPath) >= legacyMinimumModelBytes }

    private static func fileSize(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Installed means "set up", not "running right now". The server is started
    /// by a LaunchAgent at login at about the same time as talkflow itself, so
    /// using liveness here would pop the setup window on every login. The old
    /// full-precision model counts, so an update never reopens setup while the
    /// new one downloads.
    static var isInstalled: Bool {
        serverBinary() != nil && (modelIsComplete || legacyModelIsComplete)
            && FileManager.default.fileExists(atPath: agentPlistURL.path)
    }

    /// Any HTTP answer at all means the server is up; whisper-server serves a
    /// small HTML page at `/`.
    static func isResponding(port: Int = port, completion: @escaping (Bool) -> Void) {
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
    static func isRespondingBlocking(port: Int = port) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var alive = false
        isResponding(port: port) { alive = $0; semaphore.signal() }
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
    /// arrives. Only for a bare development build, which has no bundled
    /// engine; talkflow.app never runs it. Blocking: call from a background
    /// thread.
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
    /// one already, and starts it. An existing plist is kept as it is (it may
    /// have been edited: a different model, a different port), except that one
    /// still running Homebrew's engine, or a program that is gone, is moved to
    /// the bundled one (`migrateAgentIfNeeded`).
    /// Blocking: call from a background thread.
    static func startServer() throws {
        guard let binary = serverBinary() else {
            throw EngineError("whisper-server is not installed.")
        }
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        clearBundledQuarantine()

        if !FileManager.default.fileExists(atPath: agentPlistURL.path) {
            try writeAgent(agentPlist(binary: binary))
            print("talkflowd: engine agent: created, runs \(binary)")
        } else {
            migrateAgentIfNeeded()
        }

        let domain = "gui/\(getuid())"
        // bootstrap fails harmlessly when the agent is already loaded; kickstart
        // then starts it if it is loaded but not running.
        _ = runQuietly("/bin/launchctl", ["bootstrap", domain, agentPlistURL.path])
        _ = runQuietly("/bin/launchctl", ["kickstart", "\(domain)/\(agentLabel)"])
    }

    // MARK: - The LaunchAgent

    /// What the agent runs: the server on the model, on localhost only.
    static func agentArguments(binary: String, model: String = modelPath.path, port: Int = port) -> [String] {
        [binary, "-m", model, "--host", "127.0.0.1", "--port", String(port), "-nt"]
    }

    static func agentPlist(binary: String) -> [String: Any] {
        let log = logDirectory.appendingPathComponent("whisper-server.log").path
        return [
            "Label": agentLabel,
            "ProgramArguments": agentArguments(binary: binary),
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardOutPath": log,
            "StandardErrorPath": log
        ]
    }

    /// What to do with the agent plist on this Mac.
    enum AgentPlan: Equatable {
        /// There is none yet; setup writes it.
        case create
        /// Left alone, and why.
        case keep(String)
        /// Point it at the bundled engine. `from` is the program it ran.
        case repoint(from: String)
    }

    /// Pure, for `--streamtest`. `existing` is the plist as read (nil when
    /// there is none), `bundled` this copy's engine (nil when it has none).
    ///
    /// Repointed: a Homebrew program (setups from before the engine was
    /// bundled), or a program that is gone (talkflow.app was moved, or
    /// Homebrew's whisper-cpp was uninstalled). Kept: the bundled engine
    /// already, or a program elsewhere that is still there, which someone
    /// chose on purpose. Also kept while talkflow runs from a translocated
    /// copy (opened in place from Downloads or a disk image): that path is
    /// gone after a restart, so a working program is not swapped for it.
    static func agentPlan(existing: [String: Any]?, bundled: String?, isExecutable: (String) -> Bool) -> AgentPlan {
        guard let existing else { return .create }
        guard let bundled, isExecutable(bundled) else { return .keep("this copy of talkflow has no bundled engine") }
        let program = (existing["Program"] as? String) ?? (existing["ProgramArguments"] as? [String])?.first ?? ""
        if program == bundled { return .keep("it already runs the bundled engine") }
        if program.isEmpty || !isExecutable(program) { return .repoint(from: program) }
        if bundled.contains("/AppTranslocation/") {
            return .keep("talkflow is running from a temporary copy; move it to Applications")
        }
        if isHomebrewPath(program) { return .repoint(from: program) }
        return .keep("it runs \(program), which is not Homebrew's and is still there")
    }

    /// The same plist running `binary`. Only the program changes; the model,
    /// port, logs and everything else stay as they were.
    static func repointed(_ plist: [String: Any], to binary: String) -> [String: Any] {
        var plist = plist
        var arguments = plist["ProgramArguments"] as? [String] ?? []
        if arguments.isEmpty { arguments = agentArguments(binary: binary) } else { arguments[0] = binary }
        plist["ProgramArguments"] = arguments
        plist.removeValue(forKey: "Program")
        return plist
    }

    /// The same arguments loading `model` instead of `legacy`. Nil when they do
    /// not load `legacy`, so a model someone chose on purpose is left alone.
    /// Pure, for `--streamtest`.
    static func remodeled(_ arguments: [String], from legacy: String, to model: String) -> [String]? {
        guard let flag = arguments.firstIndex(where: { $0 == "-m" || $0 == "--model" }),
              flag + 1 < arguments.count, arguments[flag + 1] == legacy else { return nil }
        var arguments = arguments
        arguments[flag + 1] = model
        return arguments
    }

    /// Whether the agent plist still loads the old full-precision model.
    static func agentLoadsLegacyModel() -> Bool {
        guard let arguments = readAgent()?["ProgramArguments"] as? [String] else { return false }
        return remodeled(arguments, from: legacyModelPath.path, to: modelPath.path) != nil
    }

    private static let agentLock = NSLock()

    /// A copy installed for testing next to a working install (install.sh
    /// with TALKFLOW_BUNDLE_ID) shares the agent and the models, and must not
    /// take either over.
    private static var isTestCopy: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "TalkflowDisableLoginItem") as? Bool) == true
    }

    /// Run once at launch, off the main thread: makes sure the bundled engine
    /// can be started by launchd, moves an agent set up with Homebrew's
    /// engine onto it, and moves a Mac on the old model to the new one.
    static func prepareOnLaunch() {
        clearBundledQuarantine()
        migrateAgentIfNeeded()
        upgradeModel()
    }

    /// Moves a Mac set up with the full-precision small.en onto the quantized
    /// one: downloads it in the background (the old one keeps serving until
    /// then), points the agent at it, and once the server answers on it,
    /// deletes the old file, which nothing else uses. A failed download is
    /// tried again at the next launch. Blocking: call from a background thread.
    static func upgradeModel() {
        guard !isTestCopy, legacyModelIsComplete || FileManager.default.fileExists(atPath: legacyModelPath.path) else { return }
        if !modelIsComplete {
            guard legacyModelIsComplete else { return }
            print("talkflowd: downloading the smaller speech model in the background")
            let semaphore = DispatchSemaphore(value: 0)
            var failure: Error?
            let download = FileDownloader(destination: modelPath, minimumBytes: minimumModelBytes, onProgress: { _ in }) { error in
                failure = error
                semaphore.signal()
            }
            download.start(url: modelDownloadURL)
            semaphore.wait()
            if let failure {
                print("talkflowd: smaller speech model download failed, staying on the old one: \(failure.localizedDescription)")
                return
            }
            migrateAgentIfNeeded()
        }
        guard modelIsComplete, !agentLoadsLegacyModel() else { return }
        guard waitUntilResponding(timeout: 60) else {
            print("talkflowd: the engine is not answering on the new model yet; the old model is kept for now")
            return
        }
        do {
            try FileManager.default.removeItem(at: legacyModelPath)
            print("talkflowd: removed the old speech model (\(legacyModelFileName))")
        } catch {
            print("talkflowd: could not remove the old speech model: \(error.localizedDescription)")
        }
    }

    private static func readAgent() -> [String: Any]? {
        guard let data = try? Data(contentsOf: agentPlistURL) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// Applies `agentPlan` to this Mac's agent plist, and moves it from the old
    /// model to the new one once that is downloaded (`remodeled`). Reloads the
    /// agent when it is loaded, so the change runs now rather than at the next
    /// login. Safe to call on every launch: once the plist runs the bundled
    /// engine on the new model it is only read. Returns whether it rewrote the
    /// plist. Blocking: call from a background thread.
    @discardableResult
    static func migrateAgentIfNeeded() -> Bool {
        agentLock.lock(); defer { agentLock.unlock() }
        let url = agentPlistURL
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        if isTestCopy {
            print("talkflowd: engine agent: left alone by a test copy")
            return false
        }
        guard let existing = readAgent() else {
            print("talkflowd: engine agent: \(url.path) is not a readable plist; left alone")
            return false
        }
        var plist = existing
        var changes: [String] = []
        let bundled = bundledServerPath
        switch agentPlan(existing: existing, bundled: bundled, isExecutable: { FileManager.default.isExecutableFile(atPath: $0) }) {
        case .create:
            return false
        case .keep(let reason):
            print("talkflowd: engine agent: kept, \(reason)")
        case .repoint(let from):
            if let bundled {
                plist = repointed(plist, to: bundled)
                changes.append("now runs \(bundled) (was \(from.isEmpty ? "no program" : from))")
            }
        }
        if modelIsComplete, let arguments = plist["ProgramArguments"] as? [String],
           let updated = remodeled(arguments, from: legacyModelPath.path, to: modelPath.path) {
            plist["ProgramArguments"] = updated
            changes.append("now loads \(modelFileName) (was \(legacyModelFileName))")
        }
        guard !changes.isEmpty else { return false }
        do {
            try writeAgent(plist)
        } catch {
            print("talkflowd: engine agent: could not rewrite \(url.path): \(error.localizedDescription)")
            return false
        }
        changes.forEach { print("talkflowd: engine agent: \($0)") }
        clearBundledQuarantine()
        reloadAgentIfLoaded()
        return true
    }

    private static func writeAgent(_ plist: [String: Any]) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(
            at: agentPlistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: agentPlistURL, options: .atomic)
    }

    /// launchd keeps the plist it loaded, so a rewritten one takes effect only
    /// after bootout and bootstrap. An agent that is not loaded stays that
    /// way; it picks up the new plist when it is next loaded.
    private static func reloadAgentIfLoaded() {
        let domain = "gui/\(getuid())"
        guard runQuietly("/bin/launchctl", ["print", "\(domain)/\(agentLabel)"]) == 0 else {
            print("talkflowd: engine agent: not loaded, so not reloaded")
            return
        }
        runQuietly("/bin/launchctl", ["bootout", "\(domain)/\(agentLabel)"])
        // bootout can return before the old server has exited, and bootstrap
        // fails until it has.
        for attempt in 1...10 {
            if runQuietly("/bin/launchctl", ["bootstrap", domain, agentPlistURL.path]) == 0 {
                print("talkflowd: engine agent: reloaded")
                return
            }
            if attempt < 10 { Thread.sleep(forTimeInterval: 0.5) }
        }
        print("talkflowd: engine agent: reload failed; the new engine runs from the next login")
    }

    /// A download from the website carries macOS's quarantine flag onto every
    /// file in the app. The user approves talkflow when they first open it,
    /// but launchd starts the engine on its own, and a flagged program started
    /// that way could be held by Gatekeeper with no one there to approve it.
    /// The flag is cleared on this one file, which the app's signature covers;
    /// the updater does the same for a whole update. Does nothing when there
    /// is no flag, or no bundled engine.
    static func clearBundledQuarantine() {
        guard let path = bundledServerBinary else { return }
        let name = "com.apple.quarantine"
        guard getxattr(path, name, nil, 0, 0, 0) >= 0 else { return }
        if removexattr(path, name, 0) == 0 {
            print("talkflowd: cleared the quarantine flag on \(path)")
        } else {
            print("talkflowd: could not clear the quarantine flag on \(path): \(String(cString: strerror(errno)))")
        }
    }

    /// Polls until the server answers. Loading the model takes a few seconds.
    static func waitUntilResponding(port: Int = port, timeout: TimeInterval, interval: TimeInterval = 0.5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isRespondingBlocking(port: port) { return true }
            Thread.sleep(forTimeInterval: interval)
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

/// The large model, for the final pass only.
///
/// small.en stays the live engine: it re-transcribes the whole buffer every
/// 0.7s, and only something that fast keeps the caption current. The final
/// pass runs once, after the key is released, and is the only transcript that
/// reaches the document, so that is where accuracy pays. Measured on this M4
/// against the warm small.en server: 1.11s vs 0.36s for 5s of speech, 2.62s vs
/// 1.49s for 46s. Earlier large-v3-turbo was rejected for being 2-4x slower,
/// but that was as the live engine, where it ran every tick.
///
/// Loaded only while dictating. It costs about 745 MB while loaded, which is
/// more than everything else in talkflow together, so it is started when the
/// key goes down (`warmUp`) and stopped `idleTimeout` after the last hold
/// (`scheduleIdleStop`). Measured on this M4 with the model in the file cache:
/// it answers 0.4s after launch, so it is ready long before a normal hold
/// ends. A hold that ends sooner waits for it up to `releaseWait`, then goes
/// to small.en. After a reboot the first load reads the file from disk and
/// can take a little longer.
///
/// Owned by this process rather than a LaunchAgent: it is optional, it is
/// fetched in the background on first use, and when it is missing or does not
/// answer the final pass simply goes to small.en. A child process does NOT die
/// with talkflow on its own - measured, one outlived a deploy's SIGTERM with
/// launchd as its new parent - so talkflow stops it on SIGTERM (AppDelegate),
/// a later hold adopts one that is still answering, `stop` ends an adopted
/// one too, and launch stops any that is left over (`prepare`).
///
/// All state is read and written on the main thread.
enum FinalPassEngine {
    static let port = 8179
    static let modelFileName = "ggml-large-v3-turbo-q5_0.bin"
    static let modelDownloadURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin")!
    /// The real file is 574,041,195 bytes.
    static let minimumModelBytes: Int64 = 570_000_000

    /// How long the server stays loaded after the last hold. Short, because
    /// every second loaded is about 745 MB on top of everything else; a reload
    /// costs about 0.6s and happens while the next hold is still speaking.
    /// Long enough that dictating sentence after sentence keeps it loaded.
    static let idleTimeout: TimeInterval = 15
    /// How long a release waits for a server that is still loading.
    static let releaseWait: TimeInterval = 1.5

    static var modelPath: URL {
        SpeechEngine.modelPath.deletingLastPathComponent().appendingPathComponent(modelFileName)
    }
    static var inferenceURL: URL { URL(string: "http://127.0.0.1:\(port)/inference")! }

    /// Set once the server has answered, cleared when it stops.
    private(set) static var isReady = false
    private static var isLaunching = false
    private static var process: Process?
    private static var downloader: FileDownloader?
    private static var idleStop: DispatchWorkItem?
    /// Bumped by `stop`, so a launch that finishes after it does not come back.
    private static var generation = 0
    private static var waiters: [(id: UUID, done: (Bool) -> Void)] = []

    static var modelIsComplete: Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: modelPath.path)
        return ((attributes?[.size] as? NSNumber)?.int64Value ?? 0) >= minimumModelBytes
    }

    /// At launch and when the setting is turned on: stops a server left over
    /// from an earlier run, and downloads the model if it is not there yet.
    /// Loads nothing. Safe to call more than once.
    static func prepare() {
        stop()
        guard Preferences.accurateFinalPass, downloader == nil, !modelIsComplete else { return }
        print("talkflowd: downloading the final-pass model in the background")
        let download = FileDownloader(destination: modelPath, minimumBytes: minimumModelBytes, onProgress: { _ in }) { error in
            DispatchQueue.main.async {
                downloader = nil
                if let error { print("talkflowd: final-pass model download failed: \(error.localizedDescription)") }
            }
        }
        downloader = download
        download.start(url: modelDownloadURL)
    }

    /// The key went down: start loading, so the server is ready by release.
    /// Does nothing when the setting is off, the model is not downloaded, or
    /// it is already loaded or loading.
    static func warmUp() {
        idleStop?.cancel()
        idleStop = nil
        guard Preferences.accurateFinalPass, modelIsComplete, !isReady, !isLaunching else { return }
        isLaunching = true
        let launchGeneration = generation
        DispatchQueue.global(qos: .userInitiated).async { launch(generation: launchGeneration) }
    }

    /// The hold is over: unload once no other hold has started for
    /// `idleTimeout`.
    static func scheduleIdleStop() {
        idleStop?.cancel()
        guard isReady || isLaunching || process != nil else { return }
        let work = DispatchWorkItem {
            // A slow first load (a new engine binary is checked by macOS on
            // its first run) is let finish, or it would start over every hold.
            if isLaunching { scheduleIdleStop(); return }
            print("talkflowd: final-pass model unloaded after \(Int(idleTimeout))s idle")
            stop()
        }
        idleStop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + idleTimeout, execute: work)
    }

    /// Calls back on the main thread with whether the server is ready,
    /// waiting up to `timeout` when it is still loading.
    static func whenReady(timeout: TimeInterval, _ done: @escaping (Bool) -> Void) {
        if isReady { done(true); return }
        guard isLaunching else { done(false); return }
        let id = UUID()
        waiters.append((id, done))
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
            waiters.remove(at: index).done(false)
        }
    }

    private static func settle(ready: Bool) {
        isLaunching = false
        isReady = ready
        let pending = waiters
        waiters = []
        pending.forEach { $0.done(ready) }
    }

    /// Ends the server: ours, or one adopted from an earlier run, matched by
    /// its exact model path and port so nothing else is touched.
    static func stop() {
        generation += 1
        idleStop?.cancel()
        idleStop = nil
        process?.terminate()
        process = nil
        settle(ready: false)
        let killer = Process()
        killer.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killer.arguments = ["-f", "\(modelPath.path) --host 127.0.0.1 --port \(port)"]
        try? killer.run()
        killer.waitUntilExit()
    }

    private static func launch(generation launchGeneration: Int) {
        // Left over from a run that did not exit cleanly: use it.
        if SpeechEngine.isRespondingBlocking(port: port) {
            DispatchQueue.main.async { if generation == launchGeneration { settle(ready: true) } }
            return
        }
        guard let binary = SpeechEngine.serverBinary() else {
            DispatchQueue.main.async { if generation == launchGeneration { settle(ready: false) } }
            return
        }
        let started = Date()
        let server = Process()
        server.executableURL = URL(fileURLWithPath: binary)
        server.arguments = ["-m", modelPath.path, "--host", "127.0.0.1", "--port", String(port), "-nt"]
        try? FileManager.default.createDirectory(at: SpeechEngine.logDirectory, withIntermediateDirectories: true)
        let logURL = SpeechEngine.logDirectory.appendingPathComponent("whisper-server-final.log")
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        if let log = try? FileHandle(forWritingTo: logURL) {
            log.truncateFile(atOffset: 0)
            server.standardOutput = log
            server.standardError = log
        }
        // A server that dies on its own is no longer ready; the next hold
        // starts another.
        server.terminationHandler = { ended in
            DispatchQueue.main.async {
                guard process === ended else { return }
                process = nil
                settle(ready: false)
            }
        }
        do { try server.run() } catch {
            print("talkflowd: could not start the final-pass server: \(error.localizedDescription)")
            DispatchQueue.main.async { if generation == launchGeneration { settle(ready: false) } }
            return
        }
        DispatchQueue.main.async {
            // Stopped while it was starting.
            guard generation == launchGeneration else { server.terminate(); return }
            process = server
        }
        // Polled often: a hold may be waiting on it (`releaseWait`).
        let up = SpeechEngine.waitUntilResponding(port: port, timeout: 30, interval: 0.05)
        let elapsed = String(format: "%.2f", Date().timeIntervalSince(started))
        print(up ? "talkflowd: final-pass model ready in \(elapsed)s" : "talkflowd: final-pass server did not answer; using small.en")
        DispatchQueue.main.async {
            guard generation == launchGeneration else { server.terminate(); return }
            if !up { server.terminate(); process = nil }
            settle(ready: up)
        }
    }
}

/// Watches how long the large model takes at release. On a slow Mac it can be
/// several times slower than small.en, or not answer inside `timeout` at all
/// (then every dictation waits the full limit before small.en takes over), so
/// three slow passes in a row turn the accurate final pass off for good and
/// unload the model. Three rather than two, so a short spell of heavy load on a
/// fast Mac does not cost it the large model. The Settings toggle follows and
/// can turn it back on; after that talkflow leaves the choice alone (see
/// `Preferences.finalPassTooSlow`). Fast Macs never get near the limit: 46s of
/// speech takes about 2.6s on an M4.
enum FinalPassSpeed {
    /// How long the large model gets before small.en takes over.
    static let timeout: TimeInterval = 8
    static let slowPassesToTurnOff = 3

    /// A pass is slow past 2s plus a quarter of the audio's length. One that ran
    /// out of time (`elapsed` nil) is slow only when that limit is inside the
    /// timeout: a very long dictation timing out says nothing either way, so it
    /// is nil and leaves the count alone.
    static func isSlow(elapsed: TimeInterval?, audioSeconds: TimeInterval) -> Bool? {
        let limit = 2 + 0.25 * audioSeconds
        guard let elapsed else { return limit < timeout ? true : nil }
        return elapsed > limit
    }

    /// 16 kHz, 16-bit mono PCM behind a 44-byte header.
    static func seconds(ofWav wav: Data) -> TimeInterval {
        Double(max(0, wav.count - 44)) / 32000
    }

    /// Consecutive slow passes; any quick one resets it.
    private static var slowStreak = 0

    /// `elapsed` is nil for a pass that ran out of time. Called from the
    /// transcription completion, which is not on the main thread.
    static func record(elapsed: TimeInterval?, audioSeconds: TimeInterval) {
        DispatchQueue.main.async { count(elapsed: elapsed, audioSeconds: audioSeconds) }
    }

    private static func count(elapsed: TimeInterval?, audioSeconds: TimeInterval) {
        guard !Preferences.finalPassTooSlow, let slow = isSlow(elapsed: elapsed, audioSeconds: audioSeconds) else { return }
        guard slow else { slowStreak = 0; return }
        slowStreak += 1
        let took = elapsed.map { String(format: "%.1fs", $0) } ?? "no answer in \(Int(timeout))s"
        print("talkflowd: large-model pass was slow (\(took) for \(String(format: "%.1f", audioSeconds))s of speech), \(slowStreak) in a row")
        guard slowStreak >= slowPassesToTurnOff else { return }
        slowStreak = 0
        Preferences.finalPassTooSlow = true
        Preferences.accurateFinalPass = false
        FinalPassEngine.stop()
        NotificationCenter.default.post(name: .accurateFinalPassChanged, object: nil)
        print("talkflowd: accurate final pass turned off, this Mac is too slow for it")
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
    /// Where a download that stopped had got to, when the server allows
    /// picking it up again. Pass it to the next `start` to continue.
    private(set) var resumeData: Data?

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

    /// Starts the download, or continues an earlier one from its
    /// `resumeData` (falling back to the start if that cannot be used).
    func start(url: URL, resumeData: Data? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        if let resumeData {
            session.downloadTask(withResumeData: resumeData).resume()
        } else {
            session.downloadTask(with: url).resume()
        }
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
        guard let error else { return }
        resumeData = (error as? URLError)?.downloadTaskResumeData
        complete(error)
    }

    private func complete(_ error: Error?) {
        guard !finished else { return }
        finished = true
        session?.finishTasksAndInvalidate()
        onFinish(error)
    }
}
