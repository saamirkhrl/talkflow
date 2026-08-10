import Foundation

/// `talkflowd --streamtest` - replays realistic whisper revision sequences
/// through the live path and proves the property the whole design rests on: a
/// live update can only ever append.
///
/// Pure logic. No microphone, no focus, no window - so unlike `--typetest` it can
/// run anywhere, including straight after a build. What it does not cover is the
/// event pipeline; `--typetest` owns that.
///
/// The sequences are raw whisper output, not rendered text, so every case runs
/// through the same `Dictation.render` the hotkey uses. A revision that only
/// appears after formatting - "water emoji" collapsing to a symbol, a spoken
/// "new paragraph" becoming a blank line, capitalisation moving when a sentence
/// ends - is exactly the kind that used to cause a rewrite, so testing against
/// pre-rendered strings would test the wrong thing.
enum StreamSelfTest {
    private static var failures = 0

    /// Each case is what whisper returned at each tick while the user spoke, and
    /// then what it returned for the complete recording on release.
    private struct Case {
        let name: String
        let ticks: [String]
        let onRelease: String
        /// Words that must never appear on screen while speaking. Not the final
        /// text - the point is what the user watches happen.
        var neverShownLive: [String] = []
    }

    private static let cases: [Case] = [
        Case(
            name: "the email that was flashing and mangling",
            ticks: [
                "Dear Sarah",
                "Dear Sarah, can you",
                "Dear Sarah, can you please review",
                "Dear Sarah, can you pleased review my pitch",
                "Dear Sarah, can you please review my pitch deck for the water",
                "Dear Sarah, can you please review my pitch deck for the waterbed willow",
                "Dear Sarah, can you please review my pitch deck for the waterbed willow fish. Thank you"
            ],
            onRelease: "Dear Sarah, can you please review my pitch deck for the waterbed willow fish. Thank you, sincerely, Samir.",
            // "pleased" was whisper's guess for one tick only; agreement must
            // never let a one-tick guess reach the screen.
            neverShownLive: ["pleased"]
        ),
        Case(
            name: "a word revised after it was first emitted (to -> two)",
            ticks: [
                "I need to",
                "I need two tickets",
                "I need two tickets for the",
                "I need two tickets for the show tonight",
                "I need two tickets for the show tonight."
            ],
            onRelease: "I need two tickets for the show tonight."
        ),
        Case(
            name: "a two-word emoji command split across ticks",
            ticks: [
                "Send me the",
                "Send me the water",
                "Send me the water emoji",
                "Send me the water emoji and the bridge",
                "Send me the water emoji and the bridge emoji"
            ],
            onRelease: "Send me the water emoji and the bridge emoji",
            // The first half of a command must not commit as a literal word
            // before the second half arrives.
            neverShownLive: ["water", "bridge", "emoji"]
        ),
        Case(
            name: "a spoken paragraph break mid-hold",
            ticks: [
                "Hi Sarah new paragraph can you",
                "Hi Sarah new paragraph can you review the deck",
                "Hi Sarah new paragraph can you review the deck and tell me",
                "Hi Sarah new paragraph can you review the deck and tell me what you think."
            ],
            onRelease: "Hi Sarah new paragraph can you review the deck and tell me what you think.",
            neverShownLive: ["paragraph"]
        ),
        Case(
            name: "whisper drops tail words and then recovers",
            ticks: [
                "The quick brown fox jumps over",
                "The quick brown fox jumps over the lazy dog",
                "The quick brown fox",
                "The quick brown fox jumps over the lazy dog again",
                "The quick brown fox jumps over the lazy dog again and again"
            ],
            onRelease: "The quick brown fox jumps over the lazy dog again and again."
        ),
        Case(
            name: "late punctuation shifting the tail",
            ticks: [
                "Let me know if that works",
                "Let me know if that works for you",
                "Let me know if that works for you, otherwise",
                "Let me know if that works for you. Otherwise I can move it"
            ],
            onRelease: "Let me know if that works for you. Otherwise I can move it."
        )
    ]

    static func run() -> Never {
        // Start clean, so a passing run can't be read out of a previous one's
        // leftovers.
        try? FileManager.default.removeItem(at: logURL)
        report("--- streamtest ---")
        for testCase in cases { runCase(testCase) }
        runWriteVerificationCases()
        report(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
        exit(failures == 0 ? 0 : 1)
    }

    /// The rule that decides whether an Accessibility write is believed.
    ///
    /// Discord accepts every AX call, returns success, and changes nothing. For
    /// as long as that return code was trusted, the text vanished and the
    /// keystroke path that Discord does accept never ran - the app looked
    /// completely dead there, and in Terminal, while working in Cursor. This is
    /// the rule that keeps that from coming back, so it is pinned here rather
    /// than left to a comment.
    private static func runWriteVerificationCases() {
        report("case: an AX write is only believed when it can be proved")

        check(FieldWriter.landed(caretAfter: 12, expectedCaret: 12, readback: nil, replacement: "hello"),
              "caret moved to the end of the insertion -> believed")
        check(!FieldWriter.landed(caretAfter: 7, expectedCaret: 12, readback: nil, replacement: "hello"),
              "caret did not move (this is Discord) -> refused")
        check(FieldWriter.landed(caretAfter: nil, expectedCaret: 12, readback: "hello", replacement: "hello"),
              "caret unreadable but the text reads back -> believed")
        check(!FieldWriter.landed(caretAfter: nil, expectedCaret: 12, readback: nil, replacement: "hello"),
              "no caret and no readback -> refused, because nothing was proved")
        check(!FieldWriter.landed(caretAfter: nil, expectedCaret: 12, readback: "hell", replacement: "hello"),
              "readback does not match what was written -> refused")
        check(FieldWriter.landed(caretAfter: 5, expectedCaret: 5, readback: nil, replacement: ""),
              "a pure deletion leaves the caret where the text was removed -> believed")
    }

    private static func runCase(_ testCase: Case) {
        let stream = StreamCommit()
        // Stands in for the user's text field. Updated only through
        // FieldSync.edit, so what is measured is the real edit the app would
        // make, not a description of it.
        var screen = ""
        var liveDeletions = 0
        var lastShown = ""
        var shownLive: [String] = []

        report("case: \(testCase.name)")

        for (index, tick) in testCase.ticks.enumerated() {
            let rendered = Dictation.render(tick, leadingSpace: "", structure: false)
            guard let settled = stream.advance(rendered) else {
                report("     tick \(index) -> (nothing settled yet)")
                continue
            }

            check(settled.hasPrefix(lastShown),
                  "tick \(index) extends what was already on screen",
                  "was \(lastShown.debugDescription), now \(settled.debugDescription)")
            lastShown = settled

            let edit = FieldSync.edit(from: screen, to: settled)
            liveDeletions += edit.deleting
            screen = settled
            shownLive.append(settled)
            report("     tick \(index) [-\(edit.deleting) +\(edit.inserting.count)] screen=\(screen.debugDescription)")

            // The word whisper is still hearing is held back on purpose:
            // committing it is what makes the next tick want to take it back.
            let renderedWords = rendered.split(whereSeparator: { $0.isWhitespace }).count
            let shownWords = screen.split(whereSeparator: { $0.isWhitespace }).count
            check(shownWords < renderedWords,
                  "tick \(index) holds back the trailing word",
                  "showed \(shownWords) of \(renderedWords) words")
        }

        check(liveDeletions == 0,
              "nothing was deleted while speaking",
              "\(liveDeletions) characters deleted")

        for forbidden in testCase.neverShownLive {
            let leaked = shownLive.contains { containsWord(forbidden, in: $0) }
            check(!leaked, "\"\(forbidden)\" never reached the screen while speaking")
        }

        // Release: one pass, and the only one allowed to delete.
        let final = Dictation.render(testCase.onRelease, leadingSpace: "", structure: true)
        let closing = FieldSync.edit(from: screen, to: final)
        screen = final
        report("     release [-\(closing.deleting) +\(closing.inserting.count)] screen=\(screen.debugDescription)")
        check(screen == final, "the field ends up as the final transcript")
    }

    /// Whole-word containment - "water" inside "waterbed" is not the word
    /// leaking, and the emoji case would otherwise fail on its own final text.
    private static func containsWord(_ word: String, in text: String) -> Bool {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .contains { $0.lowercased() == word.lowercased() }
    }

    private static func check(_ condition: Bool, _ label: String, _ detail: String = "") {
        report((condition ? "ok   " : "FAIL ") + label + (condition || detail.isEmpty ? "" : " -> " + detail))
        if !condition { failures += 1 }
    }

    private static let logURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("talkflow-streamtest.log")

    /// stdout goes to the app log; also written next to the other self-test
    /// results so the caller can read it directly.
    private static func report(_ line: String) {
        print("talkflowd: [streamtest] \(line)")
        let url = logURL
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
