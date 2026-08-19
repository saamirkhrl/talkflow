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
        runPlaceholderSegmentCases()
        runReleaseSplitCases()
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

    /// Long audio comes back from whisper-server as several segments, one per
    /// line, and a pause in the middle of a dictation is returned as a segment
    /// reading `[BLANK_AUDIO]`. The whole-transcript check cannot see it, so it
    /// was typed into the user's document verbatim.
    private static func runPlaceholderSegmentCases() {
        report("case: placeholder segments inside a real transcript")

        let cases: [(String, String, String)] = [
            ("a trailing blank segment on a long hold",
             "and the middle is kind of gone Fix it, please\n [BLANK_AUDIO]",
             "and the middle is kind of gone Fix it, please"),
            ("a blank segment between two real ones",
             "first part of what I said\n [BLANK_AUDIO]\n second part of what I said",
             "first part of what I said\nsecond part of what I said"),
            ("real multi-segment speech is untouched",
             "the first segment of a long dictation\n and the second segment of it",
             "the first segment of a long dictation\nand the second segment of it"),
            ("a transcript that is nothing but a placeholder",
             "[BLANK_AUDIO]",
             "")
        ]

        for (name, raw, want) in cases {
            let got = Transcriber.stripPlaceholderSegments(raw)
            check(got == want, name, "got \(got.debugDescription), wanted \(want.debugDescription)")
        }

        // The rendered result is what actually reaches the field, so check the
        // whole chain and not just the strip.
        let rendered = Dictation.render(
            Transcriber.stripPlaceholderSegments("and the middle is kind of gone Fix it, please\n [BLANK_AUDIO]"),
            leadingSpace: "",
            structure: true
        )
        check(!rendered.contains("BLANK_AUDIO"),
              "no placeholder survives to the screen", rendered.debugDescription)
    }

    /// The release pass deletes text the user can already see, then retypes it,
    /// and no write path can prove the retype arrived. When it does not, the
    /// field is left with the start of the dictation, a hole, and the tail -
    /// reported twice, from real use, with the survivor beginning mid-word.
    ///
    /// So the pass is split: the words the live path held back are appended (no
    /// deletion, nothing at risk), and only then is the correction attempted, and
    /// only while it is small enough to deliver. These pin both halves.
    private static func runReleaseSplitCases() {
        report("case: the release pass never risks words that are already on screen")

        let appends: [(String, String, String?)] = [
            ("adds the words held back while speaking",
             "I need two tickets", "I need two tickets for the show tonight."),
            ("keeps a word the live path got wrong rather than deleting it",
             "I need to tickets", "I need to tickets for the show tonight."),
            ("carries a paragraph break into the append",
             "Dear Sarah,", "Dear Sarah,\n\nCan you take a look"),
            ("nothing to add when the transcript has no new words",
             "the whole thing was already typed", nil),
            ("nothing to add when the final transcript is shorter",
             "more words on screen than in the transcript", nil)
        ]
        let finals = [
            "I need two tickets for the show tonight.",
            "I need two tickets for the show tonight.",
            "Dear Sarah,\n\nCan you take a look",
            "the whole thing was already typed",
            "fewer words"
        ]
        for (index, (name, current, want)) in appends.enumerated() {
            let got = FieldSync.appendOnlyTarget(current: current, final: finals[index])
            check(got == want, name, "got \(String(describing: got)), wanted \(String(describing: want))")
            if let got {
                let edit = FieldSync.edit(from: current, to: got)
                check(edit.deleting == 0, "  \u{21b3} the append deletes nothing", "\(edit.deleting) deleted")
            }
        }

        report("case: a correction is only attempted when it can be delivered")

        // The two rewrites that destroyed real dictations, from the app's log.
        check(!Dictation.correctionIsAffordable(deleting: 422, inserting: String(repeating: "x", count: 471),
                                                via: .keystrokes("no AX")),
              "-422 +471 by keystrokes is refused")
        check(!Dictation.correctionIsAffordable(deleting: 263, inserting: String(repeating: "x", count: 287),
                                                via: .keystrokes("no AX")),
              "-263 +287 by keystrokes is refused")
        // The everyday release pass, which has always worked and must keep working.
        check(Dictation.correctionIsAffordable(deleting: 31, inserting: String(repeating: "x", count: 37),
                                               via: .keystrokes("no AX")),
              "-31 +37 by keystrokes is allowed")
        // Accessibility is one atomic verified call - length is not the risk.
        check(Dictation.correctionIsAffordable(deleting: 422, inserting: String(repeating: "x", count: 471),
                                               via: .accessibility),
              "-422 +471 via accessibility is allowed, because it is verified")
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
