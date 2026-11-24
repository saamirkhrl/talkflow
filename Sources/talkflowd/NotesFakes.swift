import Foundation

// Stand-ins for the parts of the note taker that are built separately (the real
// capture and the transcribing pipeline), plus made-up sample meetings for the
// window preview and the snapshots. Nothing here records, listens or reaches
// the network.

struct NotesError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Live app until the real code lands

/// Stand-in for the live app until the real capture is built: it says so
/// plainly instead of pretending to record.
final class UnbuiltCapture: MeetingCapture {
    private static let text = "Meeting recording isn't in this build of talkflow yet."

    var unavailableReason: String? { Self.text }
    var microphoneName: String { "" }
    var isRecording: Bool { false }

    func start(into folder: URL) throws {
        throw NotesError(message: Self.text)
    }

    func levels() -> CaptureLevels { CaptureLevels() }

    func stop() -> Double { 0 }
}

/// Stand-in for the live app until the real pipeline is built. Fails at once,
/// in words, so a note never sits at "Writing" forever.
final class UnbuiltPipeline: NotesPipeline {
    func run(audioFolder: URL, progress: @escaping (WritingProgress) -> Void,
             completion: @escaping (PipelineOutcome) -> Void) {
        DispatchQueue.main.async {
            completion(.failed(NoteFailure(step: .transcribing,
                                           message: "Writing notes isn't in this build of talkflow yet.",
                                           retry: .notes)))
        }
    }

    func cancel() {}
}

// MARK: - Preview and snapshots

/// For --windowpreview and --dashboardshot: levels that move, never a microphone.
final class FakeCapture: MeetingCapture {
    var unavailableReason: String? = nil
    var microphoneName = "MacBook Pro Microphone"
    /// When set, levels() always returns it (snapshots).
    var fixed: CaptureLevels?
    var echoHandlingActive = true
    private var startedAt: Date?

    var isRecording: Bool { startedAt != nil }

    func start(into folder: URL) throws {
        startedAt = Date()
        // Empty files, so the note has audio for NotesModel to delete, as a real recording would.
        for name in ["you.fake", "others.fake"] {
            try Data().write(to: folder.appendingPathComponent(name))
        }
    }

    func levels() -> CaptureLevels {
        if let fixed { return fixed }
        let t = elapsed
        let you = min(1, max(0, 0.35 + 0.25 * sin(t * 2.1) + 0.1 * sin(t * 7.3)))
        let others = min(1, max(0, 0.25 + 0.2 * sin(t * 1.3 + 1)))
        return CaptureLevels(elapsed: t, you: you, others: others, noComputerAudio: false,
                             echoHandlingActive: echoHandlingActive)
    }

    func stop() -> Double {
        let d = elapsed
        startedAt = nil
        return d
    }

    private var elapsed: Double {
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }
}

/// Walks the steps on a timer and returns SampleNotes.fakePieces (or `failure`).
final class FakePipeline: NotesPipeline {
    var totalSeconds: Double = 6
    var failure: NoteFailure?
    private var timer: Timer?

    func run(audioFolder: URL, progress: @escaping (WritingProgress) -> Void,
             completion: @escaping (PipelineOutcome) -> Void) {
        cancel()
        let start = Date()
        let total = totalSeconds
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let elapsed = Date().timeIntervalSince(start)
            let f = elapsed / total
            if f >= 1 {
                self.cancel()
                if let failure = self.failure {
                    completion(.failed(failure))
                } else {
                    completion(.finished(pieces: SampleNotes.fakePieces, duration: 0))
                }
            } else if f < 0.7 {
                progress(WritingProgress(step: .transcribing, fraction: f / 0.7, secondsLeft: total - elapsed))
            } else {
                progress(WritingProgress(step: .speakers, fraction: (f - 0.7) / 0.3, secondsLeft: total - elapsed))
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - Sample content (made up)

enum SampleNotes {
    /// What FakePipeline hands back: the mic as "you", the computer audio under
    /// the separator's own labels, which NotesLogic renumbers.
    static let fakePieces: [SpeechPiece] = [
        SpeechPiece(speaker: "you", start: 0, end: 6,
                    text: "Thanks for joining. Today I want to plan the next garden club newsletter."),
        SpeechPiece(speaker: "spk_a", start: 7, end: 14,
                    text: "I can cover the spring planting calendar. Most of it is already written."),
        SpeechPiece(speaker: "you", start: 15, end: 20,
                    text: "Great. Do we still need photos from the seed swap?"),
        SpeechPiece(speaker: "spk_b", start: 21, end: 29,
                    text: "I have about a dozen. I'll pick the best four and send them tomorrow."),
        SpeechPiece(speaker: "spk_a", start: 30, end: 35,
                    text: "Let's also add a short note about the tool library hours."),
        SpeechPiece(speaker: "you", start: 36, end: 40,
                    text: "Perfect. I'll put it all together by Friday."),
    ]

    /// Creates the sample meetings in `store` and returns role -> id for the
    /// roles "launch", "robotics", "untitled", "design" and "failed".
    static func seed(into store: NoteStore, now: Date = Date(), calendar: Calendar = .current) -> [String: String] {
        func day(_ ago: Int, _ hour: Int, _ minute: Int) -> Date {
            let base = calendar.date(byAdding: .day, value: -ago, to: now) ?? now
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: base) ?? base
        }

        func turn(_ speaker: String, _ start: Double, _ text: String) -> TranscriptTurn {
            TranscriptTurn(speaker: speaker, start: start, end: start + 8, text: text)
        }

        /// Writes one note. A failed write only leaves that sample out of the preview.
        func make(title: String, started: Date, duration: Double, names: [String: String],
                  state: NoteState, items: Int?, turns: [TranscriptTurn]?) -> String? {
            guard var meta = try? store.create(title: title, started: started) else { return nil }
            meta.duration = duration
            meta.state = state
            meta.actionItemCount = items
            if let turns {
                let keep = names.map { NoteSpeaker(key: $0.key, name: $0.value) }
                meta.speakers = NotesLogic.speakers(for: turns, keeping: keep)
                try? store.save(Transcript(turns: turns), for: meta.id)
            }
            try? store.save(meta)
            return meta.id
        }

        var ids: [String: String] = [:]

        ids["launch"] = make(
            title: "Launch planning", started: day(0, 14, 0), duration: 2520,
            names: ["s1": "Maya"], state: .ready, items: 4,
            turns: [
                turn("you", 4, "Okay, so the main thing today is the launch order. I want the correction fix and the new app window out together, and the note taker right after."),
                turn("s1", 19, "That works. Do we have the demo video for the window yet, or is that still a screen recording?"),
                turn("you", 27, "Still a screen recording. I'll cut a proper one once the Settings page is final."),
                turn("s2", 36, "For the post, I'd lead with the privacy angle. Everything on your own Mac is the part people repeat back to us."),
                turn("s1", 48, "Agreed. I can draft that tonight and send it over for edits."),
                turn("you", 61, "Good. Let's hold the note taker until the summary part is in, so the first impression is the whole thing."),
                turn("s2", 75, "Then I'll line up the screenshots for that day and keep them in the shared folder."),
                turn("you", 92, "Perfect. Let's talk again on Thursday to check where everything stands."),
            ])

        ids["robotics"] = make(
            title: "Robotics team sync", started: day(1, 16, 30), duration: 1080,
            names: ["s1": "Priya"], state: .ready, items: 2,
            turns: [
                turn("you", 3, "Let's go through what's left before the regional competition."),
                turn("s1", 14, "The arm still drops the ball about one time in five. I think the grip pads are worn."),
                turn("s2", 29, "I can print new pads tonight. The spare motor also needs a test."),
                turn("you", 44, "Good. Priya, can you rerun the drive code on the practice field?"),
                turn("s3", 58, "I'll bring the battery chargers and the field tape on Saturday."),
                turn("s1", 71, "Yes, I'll run it twice and write down the times."),
            ])

        ids["untitled"] = make(
            title: "", started: day(2, 11, 5), duration: 420,
            names: [:], state: .ready, items: nil,
            turns: [
                turn("you", 2, "Quick check on the delivery dates for the new shelves."),
                turn("s1", 11, "They said the second week of next month, but they'd confirm by Friday."),
                turn("you", 23, "Then let's plan the move for the week after."),
                turn("s1", 34, "Works for me. I'll tell the others."),
            ])

        ids["design"] = make(
            title: "Design review", started: day(9, 10, 0), duration: 2700,
            names: ["s1": "Jordan"], state: .ready, items: 3,
            turns: [
                turn("you", 5, "Let's start with the new settings layout and see if the sections read clearly."),
                turn("s1", 21, "The grouping is better. The word list buried under Advanced is easy to miss, though."),
                turn("s2", 40, "I'd move it up and give it a short explanation of what it does."),
                turn("you", 57, "Agreed. I'll try that and share a new screenshot tomorrow."),
                turn("s1", 80, "Then the last thing is the empty state. It needs one friendly sentence."),
            ])

        ids["failed"] = make(
            title: "Customer call", started: day(12, 15, 15), duration: 1500,
            names: [:],
            state: .failed(NoteFailure(step: .transcribing,
                                       message: "The speech engine stopped before the transcript was finished.",
                                       retry: .notes)),
            items: nil, turns: nil)
        if let id = ids["failed"] {
            // Audio left on disk, so the failed note has something to retry from.
            try? Data().write(to: store.audioFolder(for: id).appendingPathComponent("you.fake"))
        }

        return ids
    }
}
