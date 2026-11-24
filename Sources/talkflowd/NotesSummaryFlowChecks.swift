import Foundation

/// Part of `--notestest` (called from NotesSelfTest). The real Notes flow end to end: a NotesModel records and
/// stops on fakes, the pipeline hands back the sample meeting, and the real NoteAssistant (on a canned transport)
/// must ask for the summary exactly once, or not at all, and never leave the note anywhere but ready. No network,
/// no Keychain, no real Preferences, no sound; every note lives in a temp folder removed at the end of each case.
enum NotesSummaryFlowChecks {
    /// What NotesModel will save for the fake pieces. The canned summary may cite only these turn starts, so they
    /// are read from the same function instead of being typed in twice.
    private static let starts: [Double] = NotesLogic.transcript(from: SampleNotes.fakePieces).turns.map(\.start)

    private static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// One action item, one decision, citing real turns (first, second, last, and the fifth turn).
    private static var goodReply: CannedNotesTransport.Reply {
        let s = starts
        let first = s.first ?? 0, second = s.count > 1 ? s[1] : 0
        let fifth = s.count > 4 ? s[4] : 0, last = s.last ?? 0
        let summary = json(["summary": "Plan the newsletter.", "summary_times": [first, second],
                            "action_items": [["owner": "You", "task": "Put it together", "time": last]],
                            "decisions": [["text": "Add the tool library hours", "time": fifth]],
                            "open_questions": [[String: Any]]()] as [String: Any])
        return .http(status: 200, headers: [:],
                     body: json(["content": [["type": "text", "text": summary]], "stop_reason": "end_turn"]))
    }

    private static let unauthorized = CannedNotesTransport.Reply.http(status: 401, headers: [:], body: "{}")

    private static let on: () -> NotesAccess? = {
        NotesAccess.resolve(switchOn: true, hasAnthropic: { true }, hasOpenAI: { false }, anthropicModel: nil, openAIModel: nil)
    }
    private static let off: () -> NotesAccess? = {
        NotesAccess.resolve(switchOn: false, hasAnthropic: { true }, hasOpenAI: { true }, anthropicModel: nil, openAIModel: nil)
    }

    private static func spin(_ seconds: Double, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    /// Lets queued callbacks (and anything wrongly still in flight) run.
    private static func spinFor(_ seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    /// One case's world: temp store, fakes, canned transport, the real assistant and the real model.
    private final class Env {
        let root: URL
        let store: NoteStore
        let transport: CannedNotesTransport
        let pipeline = FakePipeline()
        let assistant: NoteAssistant
        let model: NotesModel
        /// The confirmed provider lives here, never in Preferences.
        var confirmed: String?
        var noteID = ""

        init(replies: [CannedNotesTransport.Reply], access: @escaping () -> NotesAccess?, confirmed: String?,
             key: String? = "k-test", failure: NoteFailure? = nil) {
            root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("talkflow-notestest-summaryflow-\(UUID().uuidString)")
            store = NoteStore(root: root)
            transport = CannedNotesTransport(replies)
            let client = NotesAIClient(transport: transport, keyFor: { _ in key })
            client.sleep = { _, body in body() }
            client.jitter = { 0 }
            self.confirmed = confirmed
            // The closures need `self`, which is not complete yet, so they go through a box.
            let box = Box()
            assistant = NoteAssistant(store: store, client: client, access: access,
                                      confirmedProvider: { box.env?.confirmed },
                                      setConfirmedProvider: { box.env?.confirmed = $0 })
            pipeline.totalSeconds = 0.3
            pipeline.failure = failure
            // 15.0 is past the 14.2 that recording needs, so start() is allowed.
            model = NotesModel(store: store, capture: FakeCapture(), pipeline: pipeline, assistant: assistant,
                               os: OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0))
            box.env = self
        }

        private final class Box { weak var env: Env? }

        private var summaryWriting: Bool {
            if case .writing = assistant.phase(for: noteID) { return true }
            return false
        }

        /// Records, stops, and waits for the meeting to finish and for any summary to settle; then waits a bit more
        /// so a request that should not exist has the chance to show up.
        func recordAndFinish() {
            model.start()
            noteID = model.session?.noteID ?? ""
            spinFor(0.1)
            model.stop()
            spin(5) { self.model.session == nil && !self.summaryWriting }
            spinFor(0.2)
        }

        /// Removes the temp folder; true when it is gone.
        func cleanUp() -> Bool {
            try? FileManager.default.removeItem(at: root)
            return !FileManager.default.fileExists(atPath: root.path)
        }
    }

    private static func gone(_ env: Env, _ label: String, check: (Bool, String, String) -> Void) {
        check(env.cleanUp(), "\(label) temp folder removed", env.root.path)
    }

    private static func isFailed(_ p: NoteAssistant.SummaryPhase) -> Bool {
        if case .failed = p { return true }
        return false
    }

    static func run(_ check: (Bool, String, String) -> Void) {
        // SF01 the whole happy path asks once and leaves a finished, summarized note.
        do {
            let e = Env(replies: [goodReply, goodReply], access: on, confirmed: "anthropic")
            e.recordAndFinish()
            let id = e.noteID
            let meta = e.store.meta(id)
            check(!id.isEmpty && e.transport.requests.count == 1 && meta?.state == .ready
                    && e.store.transcript(id) != nil && !e.store.hasAudio(id) && e.store.summary(id) != nil
                    && meta?.actionItemCount == 1 && e.model.keyInUse,
                  "SF01 one summary request after the note is ready",
                  "requests \(e.transport.requests.count) state \(String(describing: meta?.state)) summary \(e.store.summary(id) != nil) items \(String(describing: meta?.actionItemCount)) audio \(e.store.hasAudio(id)) keyInUse \(e.model.keyInUse)")
            gone(e, "SF01", check: check)
        }

        // SF02 looking at the note or the list never asks again.
        do {
            let e = Env(replies: [goodReply, goodReply], access: on, confirmed: "anthropic")
            e.recordAndFinish()
            let id = e.noteID
            e.model.refresh()
            e.model.open(id)
            e.model.backToList()
            e.model.refresh()
            spinFor(0.3)
            check(e.transport.requests.count == 1 && e.store.summary(id) != nil,
                  "SF02 opening or listing never asks again", "requests \(e.transport.requests.count)")
            gone(e, "SF02", check: check)
        }

        // SF03 a bad key leaves the note ready; Try again then writes the summary.
        do {
            let e = Env(replies: [unauthorized], access: on, confirmed: "anthropic")
            e.recordAndFinish()
            let id = e.noteID
            let kept = e.store.meta(id)?.state == .ready && e.store.transcript(id) != nil && e.store.summary(id) == nil
            let failed = isFailed(e.assistant.phase(for: id)) && e.transport.requests.count == 1
            e.transport.replies.append(goodReply)
            e.assistant.writeSummary(id)
            spin(5) { if case .writing = e.assistant.phase(for: id) { return false } else { return true } }
            spinFor(0.1)
            check(kept && failed && e.store.summary(id) != nil && e.assistant.phase(for: id) == .idle
                    && e.transport.requests.count == 2 && e.store.meta(id)?.state == .ready,
                  "SF03 failure keeps the note ready and Try again works",
                  "kept \(kept) failed \(failed) phase \(e.assistant.phase(for: id)) requests \(e.transport.requests.count)")
            gone(e, "SF03", check: check)
        }

        // SF04 switch off: nothing is sent and the Notes list shows the key banner (it shows when !keyInUse).
        do {
            let e = Env(replies: [goodReply], access: off, confirmed: "anthropic")
            e.recordAndFinish()
            let id = e.noteID
            check(e.transport.requests.isEmpty && e.store.summary(id) == nil && e.assistant.phase(for: id) == .idle
                    && !e.model.keyInUse && e.store.meta(id)?.state == .ready,
                  "SF04 switch off sends nothing", "requests \(e.transport.requests.count) keyInUse \(e.model.keyInUse)")
            gone(e, "SF04", check: check)
        }

        // SF05 switch on but the provider was never confirmed: it waits for the one-time confirmation.
        do {
            let e = Env(replies: [goodReply], access: on, confirmed: nil)
            e.recordAndFinish()
            let id = e.noteID
            check(e.transport.requests.isEmpty && e.store.meta(id)?.state == .ready && e.store.summary(id) == nil,
                  "SF05 unconfirmed provider sends nothing", "requests \(e.transport.requests.count)")
            gone(e, "SF05", check: check)
        }

        // SF06 the pipeline fails: there is no transcript, so no summary request, and the note is failed.
        do {
            let failure = NoteFailure(step: .transcribing, message: "x", retry: .notes)
            let e = Env(replies: [goodReply], access: on, confirmed: "anthropic", failure: failure)
            e.recordAndFinish()
            let id = e.noteID
            var isFailedState = false
            if case .failed? = e.store.meta(id)?.state { isFailedState = true }
            check(e.transport.requests.isEmpty && isFailedState,
                  "SF06 a failed pipeline asks for no summary",
                  "requests \(e.transport.requests.count) state \(String(describing: e.store.meta(id)?.state))")
            gone(e, "SF06", check: check)
        }

        // SF07 switch on but no key in the Keychain: nothing reaches the transport, the note stays ready.
        do {
            let e = Env(replies: [goodReply], access: on, confirmed: "anthropic", key: nil)
            e.recordAndFinish()
            let id = e.noteID
            check(e.transport.requests.isEmpty && e.store.meta(id)?.state == .ready && e.store.summary(id) == nil,
                  "SF07 no key sends nothing", "requests \(e.transport.requests.count)")
            gone(e, "SF07", check: check)
        }
    }
}
