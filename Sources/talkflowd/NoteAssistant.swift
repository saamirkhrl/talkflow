import Foundation

/// The Summary and Ask tabs' state for the meeting on screen, and the summary jobs (which keep going for a note
/// that is not on screen). Owned by NotesModel; used from the main thread. Every request goes through
/// `access`, which is nil while no Anthropic or OpenAI key is saved, so without a key nothing here sends
/// anything. Before the first request to a provider the user confirms once (`pending`), and again if the provider
/// changes. Failures never touch the transcript or the note's state: the note stays ready, and the tab shows what
/// happened with Try again.
final class NoteAssistant: ObservableObject {
    enum SummaryPhase: Equatable {
        case idle
        /// step 1...total while writing the parts; total + 1 while combining them (NotesAIClient.writeSummary).
        case writing(step: Int, total: Int)
        case failed(NotesAIError, retryAt: Date?)
    }

    /// Waiting for the one-time confirmation: the summary of a note, or a question.
    enum Pending: Equatable {
        case summary(String)
        case ask(String)
    }

    struct AskFailure: Equatable {
        var question: String
        var error: NotesAIError
        var retryAt: Date?
    }

    /// A request to show a transcript row; `token` makes a second jump to the same row a change.
    struct Jump: Equatable {
        var turn: Int
        var token: Int
    }

    @Published private(set) var openID: String?
    @Published private(set) var summary: NoteSummary?
    @Published private(set) var questions: [NoteQuestions.Entry] = []
    /// Per note, so a summary written in the background shows its state when that note is opened.
    @Published private(set) var summaryPhases: [String: SummaryPhase] = [:]
    @Published var askDraft = ""
    /// The question being answered, and the answer so far.
    @Published private(set) var asking: String?
    @Published private(set) var partialAnswer = ""
    @Published private(set) var askFailure: AskFailure?
    @Published private(set) var pending: Pending?
    @Published private(set) var jump: Jump?
    @Published private(set) var highlightedTurn: Int?

    let store: NoteStore
    var client: NotesAIClient
    /// NotesAccess.current in the app; the snapshots and tests swap it.
    var access: () -> NotesAccess?
    var confirmedProvider: () -> String?
    var setConfirmedProvider: (String) -> Void
    /// A summary was saved (NotesModel refreshes the list's action item count).
    var onSummarySaved: ((String) -> Void)?

    private var summaryJobs: [String: NotesCancel] = [:]
    private var askJob: NotesCancel?
    private var askNoteID: String?
    /// The provider each running job was started with, so a change of access can tell which jobs it affects.
    private var summaryJobProviders: [String: NotesProvider] = [:]
    private var askProvider: NotesProvider?
    private var accessObserver: NSObjectProtocol?
    private var highlightToken = 0

    init(store: NoteStore, client: NotesAIClient = .live(), access: @escaping () -> NotesAccess? = { NotesAccess.current() },
         confirmedProvider: @escaping () -> String? = { Preferences.notesConfirmedProvider },
         setConfirmedProvider: @escaping (String) -> Void = { Preferences.notesConfirmedProvider = $0 }) {
        self.store = store
        self.client = client
        self.access = access
        self.confirmedProvider = confirmedProvider
        self.setConfirmedProvider = setConfirmedProvider
        // The client asks this before every send, so a key removed (or replaced by another provider's) stops the next send
        // and any retry; accessChanged() below stops the request already in flight.
        self.client.allowed = { [weak self] provider in self?.access()?.provider == provider }
        accessObserver = NotificationCenter.default.addObserver(forName: NotesAccess.changed, object: nil, queue: .main) { [weak self] _ in
            self?.accessChanged()
        }
    }

    deinit {
        if let accessObserver { NotificationCenter.default.removeObserver(accessObserver) }
    }

    /// A key was saved or removed: stop every job that was started with a provider that is no longer the one in
    /// use, and drop a waiting confirmation when nothing may be sent at all.
    func accessChanged() {
        let now = access()?.provider
        var stopped = 0
        for (id, provider) in summaryJobProviders where provider != now {
            summaryJobs[id]?.cancel()
            summaryJobs[id] = nil
            summaryJobProviders[id] = nil
            summaryPhases[id] = .failed(.noKey, retryAt: nil)
            stopped += 1
        }
        if let provider = askProvider, provider != now {
            askJob?.cancel()
            askJob = nil
            askNoteID = nil
            askProvider = nil
            if let q = asking { askFailure = AskFailure(question: q, error: .noKey, retryAt: nil) }
            asking = nil
            partialAnswer = ""
            stopped += 1
        }
        if now == nil, pending != nil { cancelPending() }
        if stopped > 0 { Self.log("\(stopped) request(s) stopped, key removed or changed") }
    }

    var currentAccess: NotesAccess? { access() }

    func phase(for id: String) -> SummaryPhase { summaryPhases[id] ?? .idle }

    func needsConfirmation(_ access: NotesAccess) -> Bool { confirmedProvider() != access.provider.rawValue }

    func load(_ id: String?) {
        if id == openID {
            // Re-reading is safe: questions change only after a successful save.
            if let id {
                summary = store.summary(id)
                questions = store.questions(id)?.entries ?? []
            }
            return
        }
        askJob?.cancel()
        askJob = nil
        askNoteID = nil
        askProvider = nil
        openID = id
        summary = id.flatMap { store.summary($0) }
        questions = id.flatMap { store.questions($0)?.entries } ?? []
        askDraft = ""
        asking = nil
        partialAnswer = ""
        askFailure = nil
        switch pending {
        case .ask?: pending = nil
        case .summary(let x)? where x != id: pending = nil
        default: break
        }
        highlightedTurn = nil
        jump = nil
    }

    func transcriptSaved(_ id: String) {
        // No key: nothing is sent.
        guard let a = access() else { return }
        if needsConfirmation(a) {
            Self.log("summary waits for the one-time confirmation")
            return
        }
        guard store.summary(id) == nil else { return }
        start(id, a)
    }

    func writeSummary(_ id: String) {
        guard let a = access() else { return }
        if case .writing = phase(for: id) { return }
        if needsConfirmation(a) {
            pending = .summary(id)
            return
        }
        start(id, a)
    }

    private func start(_ id: String, _ a: NotesAccess) {
        guard let t = store.transcript(id), !t.turns.isEmpty, let meta = store.meta(id) else { return }
        if case .writing = phase(for: id) { return }
        summaryPhases[id] = .writing(step: 1, total: 1)
        summaryJobProviders[id] = a.provider
        summaryJobs[id] = client.writeSummary(
            access: a, transcript: t, speakers: meta.speakers,
            progress: { [weak self] s, n in self?.summaryPhases[id] = .writing(step: s, total: n) },
            completion: { [weak self] r in self?.summaryFinished(id, r) })
    }

    private func summaryFinished(_ id: String, _ result: Result<NoteSummary, NotesAIError>) {
        summaryJobs[id] = nil
        summaryJobProviders[id] = nil
        switch result {
        case .success(let written):
            // "Write again" must not lose the ticks on items that came back unchanged.
            let s = NotesAI.carryingDone(from: store.summary(id), into: written)
            do {
                try store.save(s, for: id)
            } catch {
                summaryPhases[id] = nil
                Self.log("summary not saved: the note is gone")
                return
            }
            if var meta = store.meta(id) {
                meta.actionItemCount = s.actionItems.count
                let before = meta
                meta = NotesDoc.applyingAuto(title: s.title, subtitle: s.subtitle, to: meta)
                meta.speakers = NotesDoc.applyingSuggestedNames(s.suggestedNames ?? [:], to: meta.speakers)
                try? store.save(meta)
                let titleSet = meta.title != before.title ? "auto" : "kept"
                let autoNames = zip(before.speakers, meta.speakers).filter { $0.name != $1.name }.count
                Self.log("summary applied: title \(titleSet), \(autoNames) auto name(s)")
            }
            summaryPhases[id] = nil
            if openID == id { summary = s }
            onSummarySaved?(id)
        case .failure(let e):
            // The note's state is not touched: it stays ready with its transcript.
            summaryPhases[id] = .failed(e, retryAt: NotesAI.retryNotBefore(e, now: Date()))
        }
    }

    func ask() {
        guard let id = openID, let a = access(), asking == nil, pending == nil else { return }
        let q = askDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        if needsConfirmation(a) {
            pending = .ask(q)
            askDraft = ""
            return
        }
        send(q, id, a)
    }

    private func send(_ q: String, _ id: String, _ a: NotesAccess) {
        guard let t = store.transcript(id), !t.turns.isEmpty, let meta = store.meta(id) else { return }
        asking = q
        partialAnswer = ""
        askFailure = nil
        askDraft = ""
        askNoteID = id
        askProvider = a.provider
        askJob = client.ask(
            access: a, transcript: t, speakers: meta.speakers, history: questions, question: q,
            onText: { [weak self] in self?.partialAnswer = $0 },
            completion: { [weak self] r in self?.askFinished(id, q, r) })
    }

    private func askFinished(_ id: String, _ q: String, _ result: Result<NoteQuestions.Entry, NotesAIError>) {
        askJob = nil
        askNoteID = nil
        askProvider = nil
        guard openID == id else { return }
        switch result {
        case .success(let entry):
            let all = questions + [entry]
            do {
                try store.save(NoteQuestions(entries: all), for: id)
                questions = all
            } catch {
                Self.log("answer not saved: the note is gone")
            }
            asking = nil
            partialAnswer = ""
        case .failure(let e):
            askFailure = AskFailure(question: q, error: e, retryAt: NotesAI.retryNotBefore(e, now: Date()))
            asking = nil
            partialAnswer = ""
        }
    }

    func retryAsk() {
        guard let f = askFailure, let id = openID, let a = access(), asking == nil else { return }
        if let r = f.retryAt, r > Date() { return }
        askFailure = nil
        if needsConfirmation(a) {
            pending = .ask(f.question)
            return
        }
        send(f.question, id, a)
    }

    func confirmSend() {
        guard let a = access(), let p = pending else { return }
        setConfirmedProvider(a.provider.rawValue)
        pending = nil
        Self.log("sending transcripts to \(a.provider.name) confirmed")
        switch p {
        case .summary(let id): start(id, a)
        case .ask(let q): if let id = openID { send(q, id, a) }
        }
    }

    func cancelPending() {
        if case .ask(let q)? = pending { askDraft = q }
        pending = nil
    }

    func setDone(_ index: Int, _ done: Bool) {
        guard let id = openID, var s = summary, s.actionItems.indices.contains(index) else { return }
        s.actionItems[index].done = done
        try? store.save(s, for: id)
        summary = s
    }

    func jump(to time: Double) {
        guard let id = openID, let t = store.transcript(id),
              let i = NotesAI.turnIndex(for: time, in: t.turns) else { return }
        highlightToken += 1
        let token = highlightToken
        jump = Jump(turn: i, token: token)
        highlightedTurn = i
        // The token keeps an older jump's timer from clearing a newer highlight.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.highlightToken == token else { return }
            self.highlightedTurn = nil
        }
    }

    func forget(_ id: String) {
        summaryJobs[id]?.cancel()
        summaryJobs[id] = nil
        summaryJobProviders[id] = nil
        summaryPhases[id] = nil
        if askNoteID == id {
            askJob?.cancel()
            askJob = nil
            askNoteID = nil
            askProvider = nil
            asking = nil
            partialAnswer = ""
        }
        if case .summary(let x)? = pending, x == id { pending = nil }
        if openID == id { load(nil) }
    }

    // MARK: - Snapshots only

    func stageSummaryPhase(_ phase: SummaryPhase, for id: String) {
        summaryPhases[id] = phase == .idle ? nil : phase
    }
    func stagePending(_ pending: Pending?) { self.pending = pending }
    func stageAsk(asking: String?, partial: String, failure: AskFailure?) {
        self.asking = asking
        partialAnswer = partial
        askFailure = failure
    }
    func stageHighlight(_ turn: Int?) { highlightedTurn = turn }

    private static func log(_ s: String) {
        print("talkflowd: notes: \(s)")
    }
}
