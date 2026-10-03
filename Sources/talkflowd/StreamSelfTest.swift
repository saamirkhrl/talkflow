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
        runEmailAndListCases()
        runSelfCorrectionCases()
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
             "and that was the last thing I wanted to go over\n [BLANK_AUDIO]",
             "and that was the last thing I wanted to go over"),
            ("a blank segment between two real ones",
             "first part of what I said\n [BLANK_AUDIO]\n second part of what I said",
             "first part of what I said second part of what I said"),
            // This used to pin "\n" between the segments. A segment boundary is
            // where whisper's 30s window ended, not a paragraph the user asked
            // for: it put a hard line break mid-sentence in a Gmail dictation and
            // capitalised the word after it ("about your work\nWins, post").
            ("real multi-segment speech joins with a space",
             "the first segment of a long dictation\n and the second segment of it",
             "the first segment of a long dictation and the second segment of it"),
            // Measured from whisper-server: a 32s clip came back as
            // "...around the product.\n over the last year." The period is
            // whisper closing its window, not the user's sentence end.
            ("a period whisper put at a mid-sentence cut is dropped",
             "the community that formed around the product.\n over the last year.",
             "the community that formed around the product over the last year."),
            ("a real sentence end at a cut is kept",
             "that is all for today.\n Next week we start.",
             "that is all for today. Next week we start."),
            ("an abbreviation at a cut keeps its period",
             "I spoke to Dr.\n smith about it",
             "I spoke to Dr. smith about it"),
            ("a transcript that is nothing but a placeholder",
             "[BLANK_AUDIO]",
             "")
        ]

        for (name, raw, want) in cases {
            let got = Transcriber.joinSegments(raw)
            check(got == want, name, "got \(got.debugDescription), wanted \(want.debugDescription)")
        }

        // The rendered result is what actually reaches the field, so check the
        // whole chain and not just the strip.
        let rendered = Dictation.render(
            Transcriber.joinSegments("and that was the last thing I wanted to go over\n [BLANK_AUDIO]"),
            leadingSpace: "",
            structure: true
        )
        check(!rendered.contains("BLANK_AUDIO"),
              "no placeholder survives to the screen", rendered.debugDescription)

        let joined = Dictation.render(
            Transcriber.joinSegments("so post about your work\n wins, post about your losses"),
            leadingSpace: "",
            structure: true
        )
        check(joined == "So post about your work wins, post about your losses",
              "a segment cut neither breaks the line nor capitalises the next word", joined.debugDescription)
    }

    /// The flat email in Gmail: the greeting/sign-off break was only decided at
    /// release, and in a keystroke app that rewrite (-227 +235 = 246 events)
    /// exceeded `correctionEventBudget` and was refused, so the email stayed one
    /// paragraph. These replay a dictation word by word, the way the committer
    /// delivers it, and pin both halves of the fix: the live steps stay
    /// append-only, and what is left for the release pass fits the budget.
    private static func runEmailAndListCases() {
        report("case: emails and lists reach the screen formatted")

        let emails: [(name: String, raw: String, want: String, fitsBudget: Bool)] = [
            ("a grade email, greeting and sign-off",
             "Good morning, Mr. Johnson. I would like to ask you to update my grade in the grade book from a 97 to a 98 so my average will go to a 99. I would really appreciate it if you did that since this semester is about to end. Sincerely, Samira.",
             "Good morning, Mr. Johnson.\n\nI would like to ask you to update my grade in the grade book from a 97 to a 98 so my average will go to a 99. I would really appreciate it if you did that since this semester is about to end.\n\nSincerely, Samira.", true),
            ("an email whose body is a numbered list",
             "Good morning, Emily. The three things that I really like about talkflow is number one. It's free. Number two, it's available anywhere. And number three, it's completely open source under the MIT license. So you can use it whenever you want. Best, Samir.",
             "Good morning, Emily.\n\nThe three things that I really like about talkflow is:\n1. It's free.\n2. It's available anywhere.\n3. It's completely open source under the MIT license. So you can use it whenever you want.\n\nBest, Samir.", false) // list rewrite is ~195 events: delivered via Accessibility, refused over keystrokes until the budget is measured
        ]
        for email in emails {
            let words = email.raw.split(separator: " ").map(String.init)
            var screen = ""
            var liveAppendOnly = true
            for count in 1...words.count {
                let next = Dictation.render(words.prefix(count).joined(separator: " "), leadingSpace: "", structure: false)
                if FieldSync.edit(from: screen, to: next).deleting > 0 { liveAppendOnly = false }
                screen = next
            }
            check(liveAppendOnly, "\(email.name): every live step is an append")

            let final = Dictation.render(email.raw, leadingSpace: "", structure: true)
            check(final == email.want, "\(email.name): final text", final.debugDescription)

            let edit = FieldSync.edit(from: screen, to: final)
            check(Dictation.correctionIsAffordable(deleting: edit.deleting, inserting: edit.inserting, via: .accessibility),
                  "\(email.name): the release rewrite is deliverable via Accessibility")
            if email.fitsBudget {
                check(Dictation.correctionIsAffordable(deleting: edit.deleting, inserting: edit.inserting, via: .keystrokes("test")),
                      "\(email.name): the release rewrite fits the keystroke budget",
                  "-\(edit.deleting) +\(edit.inserting.count) = \(Dictation.eventCost(deleting: edit.deleting, inserting: edit.inserting)) events")
            }
        }

        let renders: [(String, String, String)] = [
            ("ordinal cues become a numbered list",
             "My grocery list is first, milk. Second, eggs. Third, bread.",
             "My grocery list is:\n1. Milk.\n2. Eggs.\n3. Bread."),
            ("a single 'number one' is just a phrase",
             "I think talkflow is number one in my book.",
             "I think talkflow is number one in my book."),
            ("a greeting whisper wrote without a comma",
             "Good morning Emily. Three things I really like about it are fast. Thank you so much for using it. Best, Samir.",
             "Good morning Emily.\n\nThree things I really like about it are fast. Thank you so much for using it.\n\nBest, Samir."),
            ("a chat greeting with no name is not split",
             "Hey, what's up with the build today.",
             "Hey, what's up with the build today."),
            // The Gmail dictation: whisper put no comma or period before
            // "best", so the sign-off was never found.
            ("a sign-off with no punctuation before it, in an email",
             "Good morning Emily. Thank you so much again for using talkflow best Samira",
             "Good morning Emily.\n\nThank you so much again for using talkflow\n\nBest Samira"),
            ("'the best option' is prose, not a sign-off",
             "Good morning Emily. I looked at all three vendors and this is the best option we have right now.",
             "Good morning Emily.\n\nI looked at all three vendors and this is the best option we have right now."),
            ("a chat message ending 'thanks Sam' is not an email",
             "Can you send me the file before the meeting today please thanks Sam",
             "Can you send me the file before the meeting today please thanks Sam"),
            ("without a greeting a bare closer stays in the sentence",
             "I asked everyone on the team who did the launch video best Sam",
             "I asked everyone on the team who did the launch video best Sam"),
            ("a spoken new paragraph survives the sign-off pass",
             "Hi Sarah new paragraph can you review the deck and tell me what you think. Thanks, Samir.",
             "Hi Sarah\n\nCan you review the deck and tell me what you think.\n\nThanks, Samir.")
        ]
        for (name, raw, want) in renders {
            let got = Dictation.render(raw, leadingSpace: "", structure: true)
            check(got == want, name, got.debugDescription)
        }

        // whisper copies the prompt's style: a terse "Vocabulary: talkflow."
        // turned a punctuated clip into "hey can you check ... let me know".
        let prompt = Transcriber.vocabularyPrompt
        check(prompt.contains("talkflow"), "the whisper prompt names talkflow")
        check(prompt.first?.isUppercase == true && prompt.hasSuffix("."),
              "the whisper prompt is a cased, punctuated sentence", prompt.debugDescription)
        check(Transcriber.multipartBody(wav: Data(), boundary: "b", prompt: prompt).range(of: Data("name=\"prompt\"\r\n\r\n\(prompt)\r\n".utf8)) != nil,
              "the prompt is sent as its own form field")

        check(LiveType.isBrowser(bundleID: "com.google.Chrome"), "Chrome gets Shift+Return for line breaks")
        check(!LiveType.isBrowser(bundleID: "com.tinyspeck.slackmacgap"), "Slack keeps unicode newlines")
    }

    /// Spoken self-corrections, stutters and comma-set hedges are collapsed at
    /// release by `SelfCorrection`, which may only delete whole words. The
    /// negatives matter more than the positives: deleting a word the user
    /// meant is worse than leaving a false start in.
    private static func runSelfCorrectionCases() {
        report("case: self-corrections collapse, and nothing the user meant is deleted")

        let pure: [(String, String)] = [
            // corrections: marker plus a replacement of the same kind
            ("let's change that to Friday, wait no, Thursday", "let's change that to Thursday"),
            ("let's change that to Friday wait no Thursday", "let's change that to Thursday"),
            ("Meet at 2, no wait, 3.", "Meet at 3."),
            ("Meet at 2 pm, no wait, 3 pm.", "Meet at 3 pm."),
            ("Meet at 2. No wait, 3.", "Meet at 3."),
            ("Send it to Sarah, sorry, Sam.", "Send it to Sam."),
            ("We met on Monday, actually, Tuesday.", "We met on Tuesday."),
            ("Let's do it tomorrow, scratch that, let's do it Monday.", "Let's do it Monday."),
            ("We'll go. Scratch that, we'll stay.", "We'll stay."),
            ("I went home, I mean I went to the office.", "I went to the office."),
            // stutters and restarts
            ("the the meeting is at noon", "the meeting is at noon"),
            ("The the meeting is at noon.", "The meeting is at noon."),
            ("I I think so.", "I think so."),
            ("we should we should go now", "we should go now"),
            // hedges, only where commas set them off
            ("Basically, we need more users.", "We need more users."),
            ("It was, you know, kind of weird.", "It was kind of weird."),
            ("That's the plan, I guess.", "That's the plan."),
            // negatives: must come back untouched
            ("No, I don't think so.", "No, I don't think so."),
            ("Wait, let me check.", "Wait, let me check."),
            ("I actually liked it.", "I actually liked it."),
            ("Is Friday or Thursday better?", "Is Friday or Thursday better?"),
            // Decided: emphasis, not a correction. Nothing precedes the
            // marker, so there is nothing for it to replace.
            ("no no no I love it", "no no no I love it"),
            ("I like both, I mean really both.", "I like both, I mean really both."),
            ("I'm sorry, Sarah, I can't make it.", "I'm sorry, Sarah, I can't make it."),
            ("I can't make it to Paris, sorry, Tom will go instead.", "I can't make it to Paris, sorry, Tom will go instead."),
            ("I'll pay 20, actually, 30 is fine.", "I'll pay 20, actually, 30 is fine."),
            ("There is no wait time on Friday.", "There is no wait time on Friday."),
            ("I know that that is true.", "I know that that is true."),
            ("I gave her her book.", "I gave her her book."),
            ("It was very very good.", "It was very very good."),
            ("I guess so.", "I guess so."),
            ("I kind of like it.", "I kind of like it."),
            ("You know the answer.", "You know the answer."),
            ("It was good, kind of.", "It was good, kind of."),
            ("Please scratch that itch.", "Please scratch that itch."),
            // Collapsing would need "three coffees", an insertion; "Order
            // three." would drop a word the user meant. Left alone.
            ("Order two coffees, make that three.", "Order two coffees, make that three."),
            ("I would like a coffee.", "I would like a coffee.")
        ]
        for (raw, want) in pure {
            let got = SelfCorrection.apply(to: raw)
            check(got == want, "\(raw.debugDescription) -> \(want.debugDescription)", got.debugDescription)
        }

        // The guard that makes corruption impossible by construction.
        check(SelfCorrection.isDeletionOnly(original: "meet at 2, no wait, 3", result: "meet at 3"),
              "guard: deleting words is accepted")
        check(!SelfCorrection.isDeletionOnly(original: "meet at 2", result: "meet at 3"),
              "guard: a changed word is refused")
        check(!SelfCorrection.isDeletionOnly(original: "meet at 2", result: "at meet 2"),
              "guard: reordered words are refused")
        check(!SelfCorrection.isDeletionOnly(original: "meet at 2", result: "meet me at 2"),
              "guard: an inserted word is refused")

        // Through the real pipeline: live steps stay append-only (the live
        // render never applies corrections), the final text is corrected, and
        // the release pass reports what it costs.
        let dictations: [(name: String, raw: String, want: String)] = [
            ("a correction at the end of a short dictation",
             "Let's change the meeting to Friday, wait no, Thursday.",
             "Let's change the meeting to Thursday."),
            ("a stutter in an email",
             "Hi Sarah, the the deck is ready for review. Thanks, Samir.",
             "Hi Sarah,\n\nThe deck is ready for review.\n\nThanks, Samir.")
        ]
        for dictation in dictations {
            let words = dictation.raw.split(separator: " ").map(String.init)
            var screen = ""
            var liveAppendOnly = true
            for count in 1...words.count {
                let next = Dictation.render(words.prefix(count).joined(separator: " "), leadingSpace: "", structure: false)
                if FieldSync.edit(from: screen, to: next).deleting > 0 { liveAppendOnly = false }
                screen = next
            }
            check(liveAppendOnly, "\(dictation.name): every live step is an append")
            let final = Dictation.render(dictation.raw, leadingSpace: "", structure: true)
            check(final == dictation.want, "\(dictation.name): final text", final.debugDescription)
            let verbatim = Dictation.render(dictation.raw, leadingSpace: "", structure: true, corrections: false)
            let plan = Dictation.correctionTarget(screen: screen, corrected: final, verbatim: verbatim, via: .keystrokes("test"))
            let edit = FieldSync.edit(from: screen, to: final)
            check(plan.target == final, "\(dictation.name): the release rewrite fits the keystroke budget",
                  "-\(edit.deleting) +\(edit.inserting.count) = \(Dictation.eventCost(deleting: edit.deleting, inserting: edit.inserting)) events")
            report("     release [-\(edit.deleting) +\(edit.inserting.count)] = \(Dictation.eventCost(deleting: edit.deleting, inserting: edit.inserting)) events")
        }

        // Nothing typed live yet (a short hold): the corrected text is a pure
        // append, so it goes straight in and the false start is never shown.
        let short = Dictation.render("Meet at 2, no wait, 3.", leadingSpace: "", structure: true)
        check(Dictation.correctionTarget(screen: "", corrected: short, verbatim: "Meet at 2, no wait, 3.", via: .keystrokes("test")).target == short,
              "a short hold types only the corrected text")

        // A correction early in a long dictation over keystrokes: the rewrite
        // is from the correction to the end, which is past the budget. It is
        // skipped, the rest of the release pass still runs, and no word on
        // screen is lost.
        let long = "Let's move the review to Friday, wait no, Thursday, and then we can go over the launch plan, the pricing page, the onboarding emails, the support docs and everything else the team has been working on for the last month so that nothing is left for the week after"
        let liveScreen = Dictation.render(long, leadingSpace: "", structure: false)
        let longVerbatim = Dictation.render(long, leadingSpace: "", structure: true, corrections: false)
        let longFinal = Dictation.render(long, leadingSpace: "", structure: true)
        check(longFinal.hasPrefix("Let's move the review to Thursday, and then"), "long: the final text is corrected", longFinal.debugDescription)
        let keys = Dictation.correctionTarget(screen: liveScreen, corrected: longFinal, verbatim: longVerbatim, via: .keystrokes("test"))
        check(keys.target != longFinal, "long: the early correction is refused over keystrokes")
        check(keys.note?.contains("self-correction") == true, "long: the log says a self-correction was skipped", keys.note ?? "no note")
        let ax = Dictation.correctionTarget(screen: liveScreen, corrected: longFinal, verbatim: longVerbatim, via: .accessibility)
        check(ax.target == longFinal, "long: the same correction is applied via Accessibility")

        // The held-back words are appended aligned to the uncorrected text.
        // Aligned to the corrected text, deleting "Friday, wait no," shifts the
        // word index by three and the append would drop words.
        let partial = Dictation.render("Let's move the review to Friday, wait no, Thursday, and then we", leadingSpace: "", structure: false)
        let appended = FieldSync.appendOnlyTarget(current: partial, final: longVerbatim) ?? partial
        check(appended == longVerbatim, "long: the append loses no words when the correction is refused", appended.debugDescription)
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
