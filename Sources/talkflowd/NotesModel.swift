import AppKit
import Foundation

/// The Notes section's state: the list, the one meeting being recorded or written, and the meeting open on
/// screen. Owned by AppDelegate (not the window), so a recording keeps going when the window closes. Used from
/// the main thread.
final class NotesModel: ObservableObject {
    @Published var route: NotesRoute = .list
    /// Finished, failed and the session's own note; NOT leftovers.
    @Published private(set) var notes: [NoteMeta] = []
    @Published private(set) var leftovers: [NoteMeta] = []
    @Published private(set) var session: NotesSession?
    /// The name typed on the Recording screen; saved to the note on Return and at Stop.
    @Published var sessionTitle = ""
    /// The session note's recorded seconds, for "Saved 42 minutes of audio".
    @Published private(set) var sessionDuration: Double = 0
    /// A plain-words problem for the current screen; cleared when the screen changes.
    @Published var problem: String?
    @Published var detailTab: NoteTab = .transcript
    @Published private(set) var detailMeta: NoteMeta?
    @Published private(set) var detailTranscript: Transcript?
    /// The speaker being renamed on the meeting screen, and what has been typed.
    @Published var renamingKey: String?
    @Published var renameDraft = ""
    /// Shown as "Copied" on the Copy button for two seconds.
    @Published private(set) var justCopied = false
    /// False before macOS 14.2 (and settable by the snapshots).
    var supportsRecording: Bool
    var unsupportedMessage: String

    let store: NoteStore
    let capture: MeetingCapture
    let pipeline: NotesPipeline
    /// true when a meeting starts recording, false when it stops (the menu bar icon).
    var onRecordingChange: ((Bool) -> Void)?
    /// Opens Settings at Models and API keys (key banner, Summary and Ask tabs). Set by AppWindowModel.
    var openKeySettings: (() -> Void)?
    /// Asks before deleting; replaced in tests. Default: NSAlert (see below).
    var confirmDelete: () -> Bool = NotesModel.askBeforeDeleting
    /// Fixes the headers of WAV files left by a crash, so "Finish notes" can read all the audio. Set by live();
    /// a no-op in previews and tests.
    var repairAudio: (URL) -> Void = { _ in }

    private var timer: Timer?
    /// The last step written to note.json, so the disk is written once per step, not ten times a second.
    private var lastStep: WritingStep = .saving

    init(store: NoteStore, capture: MeetingCapture, pipeline: NotesPipeline,
         os: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) {
        self.store = store
        self.capture = capture
        self.pipeline = pipeline
        supportsRecording = NotesLogic.supportsRecording(os)
        unsupportedMessage = NotesLogic.unsupportedMessage(os)
    }

    static func live() -> NotesModel {
        NotesModel(store: NoteStore(root: NoteStore.defaultRoot), capture: UnbuiltCapture(), pipeline: LocalNotesPipeline())
    }

    static let previewRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("talkflow-preview-notes", isDirectory: true)

    /// Never the user's folder, whatever TALKFLOW_DATA_DIR says: previews seed made-up meetings and wipe them.
    static func preview() -> NotesModel {
        try? FileManager.default.removeItem(at: previewRoot)
        let store = NoteStore(root: previewRoot)
        _ = SampleNotes.seed(into: store)
        let model = NotesModel(store: store, capture: FakeCapture(), pipeline: FakePipeline())
        model.refresh()
        return model
    }

    // MARK: - Derived

    var isRecording: Bool {
        if case .recording? = session?.phase { return true }
        return false
    }

    var keyInUse: Bool { NotesKeys.inUse() }

    var startBlockedReason: String? {
        if !supportsRecording { return unsupportedMessage }
        switch session?.phase {
        case .writing?: return "Notes for the last meeting are still being written."
        case .recording?: return "A meeting is already recording."
        case nil: break
        }
        return capture.unavailableReason
    }

    var canStart: Bool { startBlockedReason == nil }

    // MARK: - List

    func refresh() {
        let all = store.list()
        // A finished note must not keep its audio: if talkflow stopped between saving a transcript and deleting the
        // audio, the next look at the list finishes the job.
        for m in all where m.state == .ready && store.hasAudio(m.id) { store.deleteAudio(m.id) }
        let found = store.leftovers(active: session?.noteID)
        if found.count != leftovers.count && !found.isEmpty { Self.log("\(found.count) interrupted recording(s) found") }
        leftovers = found
        notes = all.filter { !$0.state.isUnfinished || $0.id == session?.noteID }
        if case .detail(let id) = route {
            loadDetail(id)
            if detailMeta == nil { route = .list }
        }
    }

    private func loadDetail(_ id: String) {
        detailMeta = store.meta(id)
        detailTranscript = store.transcript(id)
    }

    // MARK: - Recording

    func start() {
        guard canStart else { problem = startBlockedReason; return }
        sessionTitle = ""
        let meta: NoteMeta
        do {
            meta = try store.create(title: "", started: Date())
        } catch {
            problem = "talkflow couldn't make a folder for this meeting."
            Self.log("couldn't create a note folder (\(type(of: error)))")
            return
        }
        do {
            try capture.start(into: store.audioFolder(for: meta.id))
        } catch {
            try? store.delete(meta.id)
            problem = error.localizedDescription
            Self.log("recording could not start (\(type(of: error)))")
            return
        }
        session = NotesSession(noteID: meta.id, phase: .recording(capture.levels()))
        sessionDuration = 0
        problem = nil
        route = .session
        startTimer()
        onRecordingChange?(true)
        Self.log("recording started")
        refresh()
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard var s = session, case .recording = s.phase else { stopTimer(); return }
        let l = capture.levels()
        s.phase = .recording(l)
        session = s
        if l.stoppedByItself {
            // The capture already closed its files (disk nearly full); finish the meeting the normal way and keep
            // the reason on screen.
            stop()
            problem = l.problem
            Self.log("recording stopped by itself")
        }
    }

    func stop() {
        guard case .recording? = session?.phase, let id = session?.noteID else { return }
        stopTimer()
        let duration = capture.stop()
        onRecordingChange?(false)
        saveSessionTitle()
        sessionDuration = duration
        if var meta = store.meta(id) {
            meta.duration = duration
            try? store.save(meta)
        }
        Self.log("recording stopped after \(Int(duration)) s")
        runPipeline(id)
    }

    private func runPipeline(_ id: String) {
        guard var meta = store.meta(id) else { return }
        sessionDuration = meta.duration
        session = NotesSession(noteID: id, phase: .writing(WritingProgress(step: .saving, fraction: 1, secondsLeft: nil)))
        meta.state = .writing(.saving)
        try? store.save(meta)
        lastStep = .saving
        pipeline.run(audioFolder: store.audioFolder(for: id),
                     progress: { [weak self] in self?.progressed(id, $0) },
                     completion: { [weak self] in self?.finished(id, $0) })
        refresh()
    }

    private func progressed(_ id: String, _ p: WritingProgress) {
        guard var s = session, s.noteID == id else { return }
        s.phase = .writing(p)
        session = s
        if p.step != lastStep {
            if var meta = store.meta(id) {
                meta.state = .writing(p.step)
                try? store.save(meta)
            }
            lastStep = p.step
        }
    }

    private func finished(_ id: String, _ outcome: PipelineOutcome) {
        guard session?.noteID == id else { return }
        switch outcome {
        case .finished(let pieces, let duration):
            session = NotesSession(noteID: id, phase: .writing(WritingProgress(step: .finishing, fraction: 0, secondsLeft: nil)))
            let transcript = NotesLogic.transcript(from: pieces)
            guard var meta = store.meta(id) else {   // deleted meanwhile
                session = nil
                refresh()
                return
            }
            do {
                try store.save(transcript, for: id)
            } catch {
                fail(id, NoteFailure(step: .finishing, message: "talkflow couldn't save the transcript.", retry: .notes))
                return
            }
            // The audio goes the moment the transcript is safely saved; then the note is marked ready.
            let gone = store.deleteAudio(id)
            meta.duration = max(meta.duration, duration)
            meta.speakers = NotesLogic.speakers(for: transcript.turns, keeping: meta.speakers)
            meta.state = .ready
            try? store.save(meta)
            Self.log("notes written: \(transcript.turns.count) turns, \(meta.speakers.count) speakers, audio deleted: \(gone ? "yes" : "NO")")
            let wasWatching = route == .session
            session = nil
            refresh()
            if wasWatching { open(id) }
        case .failed(let failure):
            fail(id, failure)
        }
    }

    private func fail(_ id: String, _ failure: NoteFailure) {
        var f = failure
        if f.retry == .notes && !store.hasAudio(id) { f.retry = .none }
        if var meta = store.meta(id) {
            meta.state = .failed(f)
            try? store.save(meta)
        }
        Self.log("writing notes failed at \(f.step.rawValue), retry \(f.retry.rawValue)")
        let wasWatching = route == .session
        session = nil
        refresh()
        if wasWatching { open(id) }
    }

    // MARK: - Navigation

    func open(_ id: String) {
        if session?.noteID == id { showSession(); return }
        route = .detail(id)
        detailTab = .transcript
        renamingKey = nil
        renameDraft = ""
        problem = nil
        justCopied = false
        loadDetail(id)
        if detailMeta == nil { route = .list }
    }

    func backToList() {
        route = .list
        problem = nil
        renamingKey = nil
        refresh()
    }

    func showSession() {
        guard session != nil else { return }
        route = .session
        problem = nil
    }

    func saveSessionTitle() {
        guard let id = session?.noteID, var meta = store.meta(id) else { return }
        meta.title = sessionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        try? store.save(meta)
    }

    // MARK: - Speakers

    func beginRename(_ key: String) {
        guard key != NotesLogic.youKey else { return }
        renamingKey = key
        renameDraft = detailMeta?.speakers.first { $0.key == key }?.name ?? ""
    }

    func commitRename() {
        guard let key = renamingKey, var meta = detailMeta else { return }
        meta.speakers = NotesLogic.renaming(key, to: renameDraft, in: meta.speakers)
        try? store.save(meta)
        detailMeta = meta
        renamingKey = nil
        renameDraft = ""
        refresh()
        // No log: names are private.
    }

    func cancelRename() {
        renamingKey = nil
        renameDraft = ""
    }

    // MARK: - Copy and delete

    func copy(_ id: String) {
        guard let meta = store.meta(id) else { return }
        let transcript = store.transcript(id) ?? Transcript(turns: [])
        let text = NotesLogic.copyText(meta: meta, transcript: transcript, calendar: .current)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        justCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.justCopied = false }
        Self.log("copied a transcript (\(transcript.turns.count) turns)")
    }

    static func askBeforeDeleting() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Delete this note?"
        alert.informativeText = "The transcript and everything saved with it are removed from this Mac. This can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func askAndDelete(_ id: String) {
        if confirmDelete() { delete(id) }
    }

    func delete(_ id: String) {
        guard session?.noteID != id else { problem = "Stop the recording before deleting it."; return }
        do {
            try store.delete(id)
        } catch {
            problem = "talkflow couldn't delete this note."
            Self.log("delete failed (\(type(of: error)))")
            return
        }
        Self.log("note deleted")
        if route == .detail(id) { route = .list }
        refresh()
    }

    // MARK: - Retry and leftovers

    func retry(_ id: String) {
        guard session == nil, let meta = store.meta(id), case .failed(let f) = meta.state, f.retry == .notes,
              store.hasAudio(id) else { return }
        runPipeline(id)
        route = .session
        problem = nil
        Self.log("retrying notes")
    }

    func finishLeftover(_ id: String) {
        guard session == nil, var meta = store.meta(id), meta.state.isUnfinished else { return }
        if let t = store.transcript(id) {
            // It quit after saving the transcript: only the audio and the state are left to settle.
            store.deleteAudio(id)
            meta.speakers = NotesLogic.speakers(for: t.turns, keeping: meta.speakers)
            meta.state = .ready
            try? store.save(meta)
            refresh()
            open(id)
            return
        }
        if store.hasAudio(id) {
            repairAudio(store.audioFolder(for: id))
            runPipeline(id)
            route = .session
            return
        }
        meta.state = .failed(NoteFailure(step: .saving, message: "No audio was saved for this meeting.", retry: .none))
        try? store.save(meta)
        refresh()
        open(id)
    }

    // MARK: - Quit

    func appWillTerminate() {
        if isRecording, let id = session?.noteID {
            stopTimer()
            let d = capture.stop()
            // The state stays .recording, so the next launch offers "Finish notes".
            if var meta = store.meta(id) {
                meta.duration = d
                try? store.save(meta)
            }
        } else if case .writing? = session?.phase {
            // The state stays .writing, so the next launch offers "Finish notes".
            pipeline.cancel()
        }
    }

    // MARK: - Snapshots

    /// Snapshots only: puts the model in a state no timer is needed for.
    func stage(route: NotesRoute, session: NotesSession? = nil, title: String = "", duration: Double = 0) {
        self.route = route
        self.session = session
        sessionTitle = title
        sessionDuration = duration
        if case .detail(let id) = route { loadDetail(id) }
    }

    private static func log(_ s: String) {
        print("talkflowd: notes: \(s)")
    }
}
