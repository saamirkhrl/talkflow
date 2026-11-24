import Foundation

/// Part of `--notestest` (called from NotesSelfTest). Canned replies only: no network, no Keychain, no real
/// Preferences, and every note lives in a temporary folder that is removed at the end of each case.
enum NoteAssistantSelfTest {
    private static let speakers = [NoteSpeaker(key: "you"), NoteSpeaker(key: "s1", name: "Maya"), NoteSpeaker(key: "s2")]
    private static let turns = [
        TranscriptTurn(speaker: "you", start: 4, end: 12, text: "Okay, the launch order."),
        TranscriptTurn(speaker: "s1", start: 19, end: 26, text: "Demo video?"),
        TranscriptTurn(speaker: "you", start: 27, end: 35, text: "Still a recording."),
        TranscriptTurn(speaker: "s2", start: 36, end: 47, text: "Lead with privacy."),
        TranscriptTurn(speaker: "s1", start: 48, end: 60, text: "I'll draft it tonight."),
    ]
    private static let transcript = Transcript(turns: turns)

    private static let good = """
    {"summary":" The team agreed. ","summary_times":[4,36,36],"action_items":[{"owner":"You","task":"Cut the demo video","time":27},{"owner":"maya","task":"Draft the post","time":48},{"owner":"","task":"Book a room","time":19},{"owner":"Priya","task":"Review","time":36}],"decisions":[{"text":"Launch together","time":4}],"open_questions":[{"text":"When is the demo?","time":19}]}
    """

    private static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private static var goodReply: CannedNotesTransport.Reply {
        .http(status: 200, headers: [:], body: json(["content": [["type": "text", "text": good]], "stop_reason": "end_turn"]))
    }

    private static func streamReply(_ text: String) -> CannedNotesTransport.Reply {
        .stream(status: 200, lines: [
            "data: " + json(["type": "message_start", "message": ["id": "m"]]),
            "data: " + json(["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": text]]),
            "data: " + json(["type": "message_delta", "delta": ["stop_reason": "end_turn"]]),
            "data: " + json(["type": "message_stop"]),
        ])
    }

    private static let off: () -> NotesAccess? = {
        NotesAccess.resolve(switchOn: false, hasAnthropic: { true }, hasOpenAI: { true }, anthropicModel: nil, openAIModel: nil)
    }
    private static let on: () -> NotesAccess? = {
        NotesAccess.resolve(switchOn: true, hasAnthropic: { true }, hasOpenAI: { false }, anthropicModel: nil, openAIModel: nil)
    }
    private static let onOpenAI: () -> NotesAccess? = {
        NotesAccess.resolve(switchOn: true, hasAnthropic: { false }, hasOpenAI: { true }, anthropicModel: nil, openAIModel: nil)
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

    /// One case's world: a fresh temp store, canned transport, and the assistant on top.
    private final class Env {
        let root: URL
        let store: NoteStore
        let transport: CannedNotesTransport
        let assistant: NoteAssistant
        var confirmed: String?
        var saved: [String] = []

        init(replies: [CannedNotesTransport.Reply], access: @escaping () -> NotesAccess?, confirmed: String?) {
            root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("talkflow-notestest-assistant-\(UUID().uuidString)")
            store = NoteStore(root: root)
            transport = CannedNotesTransport(replies)
            let client = NotesAIClient(transport: transport, keyFor: { _ in "k-test" })
            client.sleep = { _, body in body() }
            client.jitter = { 0 }
            self.confirmed = confirmed
            // The closures capture a placeholder until `self` is complete, so build via a box.
            let box = Box()
            assistant = NoteAssistant(store: store, client: client, access: access,
                                      confirmedProvider: { box.env?.confirmed },
                                      setConfirmedProvider: { box.env?.confirmed = $0 })
            box.env = self
            assistant.onSummarySaved = { [weak self] id in self?.saved.append(id) }
        }

        private final class Box { weak var env: Env? }

        /// A ready note with transcript T and speakers SP.
        func makeNote() -> String {
            guard var meta = try? store.create(title: "t", started: Date(timeIntervalSince1970: 1_792_000_000)) else { return "" }
            try? store.save(NoteAssistantSelfTest.transcript, for: meta.id)
            meta.speakers = NoteAssistantSelfTest.speakers
            meta.state = .ready
            try? store.save(meta)
            return meta.id
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

    static func run(check: (Bool, String, String) -> Void) {
        // AS01 with the switch off nothing is sent, whatever is called.
        do {
            let e = Env(replies: [goodReply, goodReply], access: off, confirmed: "anthropic")
            let id = e.makeNote()
            e.assistant.transcriptSaved(id)
            e.assistant.writeSummary(id)
            e.assistant.load(id)
            e.assistant.askDraft = "q"
            e.assistant.ask()
            e.assistant.retryAsk()
            e.assistant.confirmSend()
            spinFor(0.2)
            check(e.transport.requests.isEmpty && e.assistant.phase(for: id) == .idle && e.assistant.pending == nil
                    && e.assistant.asking == nil && e.store.summary(id) == nil,
                  "AS01 switch off sends nothing", "requests \(e.transport.requests.count) pending \(String(describing: e.assistant.pending))")
            gone(e, "AS01", check: check)
        }

        // AS02 not confirmed yet: nothing goes out until the user confirms.
        do {
            let e = Env(replies: [goodReply], access: on, confirmed: nil)
            let id = e.makeNote()
            e.assistant.transcriptSaved(id)
            let quiet = e.transport.requests.isEmpty && e.assistant.phase(for: id) == .idle
            e.assistant.writeSummary(id)
            let waiting = e.assistant.pending == .summary(id) && e.transport.requests.isEmpty
            e.assistant.confirmSend()
            let confirmed = e.confirmed == "anthropic"
            spin(5) { e.store.summary(id) != nil }
            check(quiet && waiting && confirmed && e.transport.requests.count == 1 && e.store.summary(id) != nil
                    && e.store.meta(id)?.actionItemCount == 4 && e.saved == [id] && e.assistant.phase(for: id) == .idle,
                  "AS02 confirmation gate",
                  "quiet \(quiet) waiting \(waiting) confirmed \(confirmed) requests \(e.transport.requests.count) saved \(e.saved)")
            gone(e, "AS02", check: check)
        }

        // AS03 already confirmed: one summary, and never a second request.
        do {
            let e = Env(replies: [goodReply, goodReply], access: on, confirmed: "anthropic")
            let id = e.makeNote()
            e.assistant.transcriptSaved(id)
            // The client sends on its own queue, so wait for the summary before counting.
            spin(5) { e.store.summary(id) != nil }
            let one = e.transport.requests.count == 1
            e.assistant.transcriptSaved(id)
            spinFor(0.1)
            check(one && e.store.summary(id) != nil && e.transport.requests.count == 1,
                  "AS03 one summary only", "requests \(e.transport.requests.count)")
            gone(e, "AS03", check: check)
        }

        // AS04 a failure never touches the transcript or the note's state.
        do {
            let capped = CannedNotesTransport.Reply.http(
                status: 429, headers: [:],
                body: #"{"type":"error","error":{"type":"rate_limit_error","message":"x","details":{"error_code":"enforced_spend_limit_reached"}}}"#)
            let e = Env(replies: [capped], access: on, confirmed: "anthropic")
            let id = e.makeNote()
            e.assistant.transcriptSaved(id)
            spin(5) { if case .failed = e.assistant.phase(for: id) { return true } else { return false } }
            check(e.assistant.phase(for: id) == .failed(.spendCap, retryAt: nil) && e.store.summary(id) == nil
                    && e.store.transcript(id) == transcript && e.store.meta(id)?.state == .ready,
                  "AS04 failure keeps the transcript", "\(e.assistant.phase(for: id))")
            gone(e, "AS04", check: check)
        }

        // AS05 a long rate limit is shown, not retried on its own.
        do {
            let limited = CannedNotesTransport.Reply.http(
                status: 429, headers: ["Retry-After": "40"],
                body: #"{"type":"error","error":{"type":"rate_limit_error","message":"x"}}"#)
            let e = Env(replies: [limited], access: on, confirmed: "anthropic")
            let id = e.makeNote()
            let before = Date()
            e.assistant.transcriptSaved(id)
            spin(5) { if case .failed = e.assistant.phase(for: id) { return true } else { return false } }
            var ok = false
            var detail = "\(e.assistant.phase(for: id))"
            if case .failed(let error, let retryAt) = e.assistant.phase(for: id), let at = retryAt {
                let wait = at.timeIntervalSince(before)
                ok = error == .rateLimited(retryAfter: 40) && wait > 38 && wait < 45
                detail = "wait \(wait)"
            }
            check(ok && e.transport.requests.count == 1, "AS05 rate limited with retry-after", detail)
            gone(e, "AS05", check: check)
        }

        // AS06 a question is answered, saved, and its citation kept.
        do {
            let e = Env(replies: [streamReply("Lead with privacy [36].")], access: on, confirmed: "anthropic")
            let id = e.makeNote()
            e.assistant.load(id)
            e.assistant.askDraft = "What about the post?"
            e.assistant.ask()
            spin(5) { e.assistant.questions.count == 1 }
            check(e.assistant.questions.count == 1 && e.assistant.questions.first?.citations == [36]
                    && e.store.questions(id)?.entries.count == 1 && e.assistant.asking == nil && e.assistant.askDraft.isEmpty,
                  "AS06 ask", "questions \(e.assistant.questions.count) asking \(String(describing: e.assistant.asking))")
            gone(e, "AS06", check: check)
        }

        // AS07 a failed question keeps its text and can be retried.
        do {
            let bad = CannedNotesTransport.Reply.stream(
                status: 401, lines: [#"{"type":"error","error":{"type":"authentication_error","message":"x"}}"#])
            let e = Env(replies: [bad, streamReply("Lead with privacy [36].")], access: on, confirmed: "anthropic")
            let id = e.makeNote()
            e.assistant.load(id)
            e.assistant.askDraft = "What about the post?"
            e.assistant.ask()
            spin(5) { e.assistant.askFailure != nil }
            let failed = e.assistant.askFailure?.error == .badKey && e.assistant.askFailure?.question == "What about the post?"
                && e.store.questions(id) == nil
            e.assistant.retryAsk()
            spin(5) { e.assistant.questions.count == 1 }
            check(failed && e.assistant.questions.count == 1 && e.assistant.askFailure == nil,
                  "AS07 ask failure and retry", "failed \(failed) questions \(e.assistant.questions.count)")
            gone(e, "AS07", check: check)
        }

        // AS08 a changed provider asks again before anything is sent.
        do {
            let e = Env(replies: [streamReply("x")], access: onOpenAI, confirmed: "anthropic")
            let id = e.makeNote()
            e.assistant.load(id)
            let needs = onOpenAI().map { e.assistant.needsConfirmation($0) } ?? false
            e.assistant.askDraft = "What next?"
            e.assistant.ask()
            let waiting = e.assistant.pending == .ask("What next?") && e.transport.requests.isEmpty
            e.assistant.cancelPending()
            check(needs && waiting && e.assistant.pending == nil && e.assistant.askDraft == "What next?",
                  "AS08 provider changed", "needs \(needs) waiting \(waiting) draft \(e.assistant.askDraft)")
            gone(e, "AS08", check: check)
        }

        // AS09 a jump lands on the turn that holds the time; an unknown time changes nothing.
        do {
            let e = Env(replies: [], access: on, confirmed: "anthropic")
            let id = e.makeNote()
            e.assistant.load(id)
            e.assistant.jump(to: 26)
            let hit = e.assistant.highlightedTurn == 2 && e.assistant.jump?.turn == 2
            let before = e.assistant.jump
            e.assistant.jump(to: 99)
            check(hit && e.assistant.jump == before && e.assistant.highlightedTurn == 2,
                  "AS09 jump", "turn \(String(describing: e.assistant.highlightedTurn))")
            gone(e, "AS09", check: check)
        }

        // AS10 ticking an action item is saved.
        do {
            let e = Env(replies: [goodReply], access: on, confirmed: "anthropic")
            let id = e.makeNote()
            e.assistant.load(id)
            e.assistant.writeSummary(id)
            spin(5) { e.assistant.summary != nil }
            e.assistant.setDone(0, true)
            check(e.store.summary(id)?.actionItems.first?.done == true && e.assistant.summary?.actionItems.first?.done == true,
                  "AS10 setDone", "summary \(e.assistant.summary != nil)")
            gone(e, "AS10", check: check)
        }

        // AS11 forgetting a note while its summary is writing drops the result.
        do {
            let e = Env(replies: [goodReply], access: on, confirmed: "anthropic")
            let id = e.makeNote()
            e.assistant.writeSummary(id)
            e.assistant.forget(id)
            spinFor(0.3)
            check(e.store.summary(id) == nil && e.assistant.phase(for: id) == .idle && e.saved.isEmpty,
                  "AS11 forget while writing", "phase \(e.assistant.phase(for: id))")
            gone(e, "AS11", check: check)
        }

        // AS12 opening another note cancels a running question.
        do {
            let e = Env(replies: [streamReply("Lead with privacy [36].")], access: on, confirmed: "anthropic")
            let first = e.makeNote()
            let other = e.makeNote()
            e.assistant.load(first)
            e.assistant.askDraft = "What about the post?"
            e.assistant.ask()
            let started = e.assistant.asking != nil
            e.assistant.load(other)
            spinFor(0.3)
            check(started && e.assistant.asking == nil && e.store.questions(first) == nil && e.assistant.questions.isEmpty,
                  "AS12 load cancels the ask", "started \(started) asking \(String(describing: e.assistant.asking))")
            gone(e, "AS12", check: check)
        }
    }
}
