import Foundation

// The two optional downloads that make notes better: the large-v3-turbo-q5_0 speech model (shared with the
// accurate final pass) and the speaker models (through the helper's prepare mode). They start only from the
// user's click on the Notes list; together with the API-key features these are the only network requests Notes
// makes, and the user sees them with progress.

enum NoteDownloadState: Equatable {
    case absent                  // not on this Mac, not downloading
    case downloading(Double)     // 0...1
    case done
    case failed                  // the last try did not finish
    case unavailable             // this Mac cannot use it (speaker helper: Intel, macOS 13, not bundled); never offered
}

enum NoteDownloadsLogic {
    /// For labels only. The model file is 574,041,195 bytes (FinalPassEngine.minimumModelBytes comment); the speaker
    /// models folder is 21 MB on disk (measured: du -sh of a prepared speaker-diarization folder).
    static let modelMB = 574
    static let speakersMB = 21

    static func needed(_ s: NoteDownloadState) -> Bool { s == .absent || s == .failed }

    static func busy(_ s: NoteDownloadState) -> Bool {
        if case .downloading = s { return true }
        return false
    }

    /// Shown while anything is needed and the user has not declined, and always while a download runs.
    static func showsCard(model: NoteDownloadState, speakers: NoteDownloadState, declined: Bool) -> Bool {
        if busy(model) || busy(speakers) { return true }
        if declined { return false }
        return needed(model) || needed(speakers)
    }

    /// After "Not now", one link under the list brings the card back while something is still missing.
    static func showsReofferLink(model: NoteDownloadState, speakers: NoteDownloadState, declined: Bool) -> Bool {
        declined && !busy(model) && !busy(speakers) && (needed(model) || needed(speakers))
    }

    /// "241 of 574 MB": whole megabytes, rounded down, fraction clamped to 0...1.
    static func progressLabel(fraction: Double, totalMB: Int) -> String {
        let f = fraction.isFinite ? min(1, max(0, fraction)) : 0
        let done = min(totalMB, Int((f * Double(totalMB)).rounded(.down)))
        return "\(done) of \(totalMB) MB"
    }

    /// Number of items the card lists: those not .unavailable and not .done, plus those .done while the other is
    /// busy or needed (so a finished row stays visible next to one still downloading).
    static func rowCount(model: NoteDownloadState, speakers: NoteDownloadState) -> Int {
        let anyActive = [model, speakers].contains { busy($0) || needed($0) }
        return [model, speakers].filter { $0 != .unavailable && ($0 != .done || anyActive) }.count
    }

    enum PrepareEvent: Equatable { case progress(Double), done }

    /// One stdout line of `talkflow-diarize prepare`. {"event":"progress","fraction":F} -> .progress(F clamped to
    /// 0...1); {"event":"done", ...} -> .done; anything else (other JSON, non-JSON) -> nil.
    static func parsePrepare(_ line: String) -> PrepareEvent? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = object["event"] as? String else { return nil }
        switch event {
        case "progress":
            guard let f = (object["fraction"] as? NSNumber)?.doubleValue, f.isFinite else { return nil }
            return .progress(min(1, max(0, f)))
        case "done":
            return .done
        default:
            return nil
        }
    }
}

/// A running download; cancel() may be called from any thread and more than once.
protocol NoteDownloadTask: AnyObject { func cancel() }
extension FileDownloader: NoteDownloadTask {}

/// `talkflow-diarize prepare` as a child process: progress lines on stdout, exit 0 when the models are in place.
final class SpeakerPrepare: NoteDownloadTask, @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var finished = false

    /// Callbacks may arrive on any thread; onFinish is called at most once.
    func start(binary: URL, modelsDir: URL, onProgress: @escaping (Double) -> Void, onFinish: @escaping (Bool) -> Void) {
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = binary
        p.arguments = SpeakerHelper.prepareArguments(modelsDir: modelsDir)
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice

        let lines = LineBuffer(onLine: { line in
            if case .progress(let f)? = NoteDownloadsLogic.parsePrepare(line) { onProgress(f) }
        })
        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { lines.append(data) }
        }
        let finishOnce: (Bool) -> Void = { [weak self] ok in
            guard let self else { onFinish(ok); return }
            self.lock.lock()
            let already = self.finished
            self.finished = true
            self.lock.unlock()
            if !already { onFinish(ok) }
        }
        p.terminationHandler = { [weak self] proc in
            out.fileHandleForReading.readabilityHandler = nil
            if let rest = try? out.fileHandleForReading.readToEnd(), !rest.isEmpty { lines.append(rest) }
            lines.flush()
            self?.lock.lock()
            let wasCancelled = self?.cancelled ?? false
            self?.lock.unlock()
            finishOnce(proc.terminationStatus == 0 && !wasCancelled)
        }

        lock.lock()
        if cancelled {
            lock.unlock()
            finishOnce(false)
            return
        }
        do {
            try p.run()
            process = p
            lock.unlock()
        } catch {
            lock.unlock()
            out.fileHandleForReading.readabilityHandler = nil
            finishOnce(false)
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let p = process
        lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }
}

/// What the Notes list shows and does about the two downloads. All methods are main-thread only.
final class NoteDownloads: ObservableObject {
    struct Environment {
        var modelComplete: () -> Bool
        var speakersAvailable: () -> Bool
        var speakersPresent: () -> Bool
        var startModel: (_ progress: @escaping (Double) -> Void, _ finish: @escaping (Bool) -> Void) -> NoteDownloadTask
        var startSpeakers: (_ progress: @escaping (Double) -> Void, _ finish: @escaping (Bool) -> Void) -> NoteDownloadTask
        var loadDeclined: () -> Bool
        var saveDeclined: (Bool) -> Void

        /// The real files and network.
        static func live() -> Environment {
            Environment(
                modelComplete: { FinalPassEngine.modelIsComplete },
                speakersAvailable: { SpeakerHelper.unavailableReason(binary: SpeakerHelper.bundledBinary()) == nil },
                speakersPresent: { SpeakerHelper.modelsPresent(SpeakerHelper.modelsFolder) },
                startModel: { progress, finish in
                    // Same file, URL and checks as the accurate final pass, so the two features share one copy.
                    let d = FileDownloader(destination: FinalPassEngine.modelPath,
                                           minimumBytes: FinalPassEngine.minimumModelBytes,
                                           onProgress: progress, onFinish: { finish($0 == nil) })
                    d.start(url: FinalPassEngine.modelDownloadURL)
                    return d
                },
                startSpeakers: { progress, finish in
                    let task = SpeakerPrepare()
                    // Only called when speakersAvailable, which needs the bundled binary.
                    if let binary = SpeakerHelper.bundledBinary() {
                        task.start(binary: binary, modelsDir: SpeakerHelper.modelsFolder, onProgress: progress, onFinish: finish)
                    } else {
                        finish(false)
                    }
                    return task
                },
                loadDeclined: { Preferences.notesDownloadsDeclined },
                saveDeclined: { Preferences.notesDownloadsDeclined = $0 })
        }

        private final class NoopTask: NoteDownloadTask { func cancel() {} }

        /// Tests, harnesses and previews: both present, nothing downloads, nothing is stored.
        static var inert: Environment {
            Environment(
                modelComplete: { true },
                speakersAvailable: { false },
                speakersPresent: { false },
                startModel: { _, _ in NoopTask() },
                startSpeakers: { _, _ in NoopTask() },
                loadDeclined: { false },
                saveDeclined: { _ in })
        }
    }

    @Published private(set) var model: NoteDownloadState = .absent
    @Published private(set) var speakers: NoteDownloadState = .absent
    @Published private(set) var declined: Bool = false

    private let env: Environment
    private var modelTask: NoteDownloadTask?
    private var speakersTask: NoteDownloadTask?
    private var modelStarted = Date()
    private var speakersStarted = Date()

    var showsCard: Bool { NoteDownloadsLogic.showsCard(model: model, speakers: speakers, declined: declined) }
    var showsReofferLink: Bool { NoteDownloadsLogic.showsReofferLink(model: model, speakers: speakers, declined: declined) }

    init(environment: Environment) {
        env = environment
        declined = environment.loadDeclined()
        refresh()
    }

    func refresh() {
        if !NoteDownloadsLogic.busy(model) {
            model = env.modelComplete() ? .done : (model == .failed ? .failed : .absent)
        }
        if !NoteDownloadsLogic.busy(speakers) {
            speakers = !env.speakersAvailable() ? .unavailable
                : env.speakersPresent() ? .done
                : (speakers == .failed ? .failed : .absent)
        }
    }

    func download() {
        refresh()
        var started: [String] = []
        if NoteDownloadsLogic.needed(model) {
            model = .downloading(0)
            modelStarted = Date()
            var task: NoteDownloadTask?
            task = env.startModel(
                { [weak self] f in
                    DispatchQueue.main.async {
                        guard let self, let t = task, let cur = self.modelTask, ObjectIdentifier(cur) == ObjectIdentifier(t),
                              NoteDownloadsLogic.busy(self.model) else { return }
                        self.model = .downloading(f)
                    }
                },
                { [weak self] ok in
                    DispatchQueue.main.async {
                        guard let self, let t = task, let cur = self.modelTask, ObjectIdentifier(cur) == ObjectIdentifier(t) else { return }
                        self.modelTask = nil
                        let good = ok && self.env.modelComplete()
                        self.model = good ? .done : .failed
                        Self.log("model \(good ? "done" : "failed")", since: self.modelStarted)
                    }
                })
            modelTask = task
            started.append("model")
        }
        if NoteDownloadsLogic.needed(speakers) {
            speakers = .downloading(0)
            speakersStarted = Date()
            var task: NoteDownloadTask?
            task = env.startSpeakers(
                { [weak self] f in
                    DispatchQueue.main.async {
                        guard let self, let t = task, let cur = self.speakersTask, ObjectIdentifier(cur) == ObjectIdentifier(t),
                              NoteDownloadsLogic.busy(self.speakers) else { return }
                        self.speakers = .downloading(f)
                    }
                },
                { [weak self] ok in
                    DispatchQueue.main.async {
                        guard let self, let t = task, let cur = self.speakersTask, ObjectIdentifier(cur) == ObjectIdentifier(t) else { return }
                        self.speakersTask = nil
                        let good = ok && self.env.speakersPresent()
                        self.speakers = good ? .done : .failed
                        Self.log("speakers \(good ? "done" : "failed")", since: self.speakersStarted)
                    }
                })
            speakersTask = task
            started.append("speakers")
        }
        if !started.isEmpty { print("talkflowd: notes downloads: started (\(started.joined(separator: ", ")))") }
    }

    func cancel() {
        let running = modelTask != nil || speakersTask != nil
        let tasks = [modelTask, speakersTask].compactMap { $0 }
        modelTask = nil
        speakersTask = nil
        tasks.forEach { $0.cancel() }
        if NoteDownloadsLogic.busy(model) { model = .absent }
        if NoteDownloadsLogic.busy(speakers) { speakers = .absent }
        refresh()
        if running { print("talkflowd: notes downloads: cancelled") }
    }

    func decline() {
        cancel()
        declined = true
        env.saveDeclined(true)
    }

    func reoffer() {
        declined = false
        env.saveDeclined(false)
    }

    /// Snapshots only: sets the published values with no tasks.
    func stage(model: NoteDownloadState, speakers: NoteDownloadState, declined: Bool) {
        self.model = model
        self.speakers = speakers
        self.declined = declined
    }

    private static func log(_ what: String, since start: Date) {
        print("talkflowd: notes downloads: \(what) after \(Int(Date().timeIntervalSince(start))) s")
    }
}
