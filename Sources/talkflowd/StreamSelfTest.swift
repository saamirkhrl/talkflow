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
        runInsertOnceCases()
        runWritingStyleCases()
        runUpdaterCases()
        runOnboardingStepCases()
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

        // "Three t:" in Gmail. The readback said the text before the caret was
        // not what we had typed (an earlier live append had lost characters),
        // the keystroke fallback sent its 109 backspaces anyway, and they reached
        // five characters too far, into "things". A mismatch the field itself
        // reports is evidence, and it must stop a deleting keystroke rewrite.
        report("case: a keystroke rewrite never deletes text the field says is not ours")
        check(FieldWriter.compare(exactRange: "Three things first, talk", window: "x Three things first, talk", expected: "Three things first, talk") == .exact,
              "identical text -> exact")
        check(FieldWriter.compare(exactRange: "post\u{a0}your stuff", window: "post\u{a0}your stuff", expected: "post your stuff") == .equivalent,
              "Gmail's non-breaking space for a typed space -> equivalent, keystrokes may proceed")
        check(FieldWriter.compare(exactRange: "a,\nCan you", window: "Dear Sarah,\nCan you", expected: "Sarah,\n\nCan you") == .equivalent,
              "a blank line the field reports as one newline -> equivalent")
        check(FieldWriter.compare(exactRange: "ree things t, talk to 50", window: "Three things t, talk to 50", expected: "Three things first, talk to 50") == .different,
              "characters lost from what we typed -> different")
        check(FieldWriter.compare(exactRange: nil, window: nil, expected: "anything") == .unreadable,
              "a field that will not answer -> unreadable, which is not evidence")

        check(!FieldSync.keystrokesMayDelete(after: .notOurs("x")), "a field that says the text is not ours -> no backspaces")
        check(FieldSync.keystrokesMayDelete(after: .no("AX reported success but the field did not change")),
              "AX writes that do not land (Chrome) -> keystrokes as before")
        check(FieldSync.keystrokesMayDelete(after: .no("element does not accept AX text edits")),
              "an element that refuses AX edits (Terminal) -> keystrokes as before")

        let shape = FieldWriter.describeMismatch(expected: "Three things first, talk", onScreen: "Three t first, talk")
        check(!shape.contains("talk") && !shape.contains("Three"), "the mismatch log carries no words", shape)
        check(shape.contains("13 characters before the caret"), "the mismatch log says where the texts diverge", shape)
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
            // From Gmail: the third item was left inside the second.
            ("'third of all' continues a list",
             "Three things, first, talk to 50 customers. Second, build in public and third of all you could submit your product to Product Hunt.",
             "Three things:\n1. Talk to 50 customers.\n2. Build in public\n3. You could submit your product to Product Hunt."),
            ("a lone 'first of all' is prose",
             "First of all, thanks for coming to the meeting today.",
             "First of all, thanks for coming to the meeting today."),
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
             "Good morning Emily.\n\nThank you so much again for using talkflow\n\nBest, Samira"),
            ("'the best option' is prose, not a sign-off",
             "Good morning Emily. I looked at all three vendors and this is the best option we have right now.",
             "Good morning Emily.\n\nI looked at all three vendors and this is the best option we have right now."),
            ("a chat message ending 'thanks Sam' is not an email",
             "Can you send me the file before the meeting today please thanks Sam",
             "Can you send me the file before the meeting today please thanks Sam"),
            ("without a greeting a bare closer stays in the sentence",
             "I asked everyone on the team who did the launch video best Sam",
             "I asked everyone on the team who did the launch video best Sam"),
            // Gmail showed "3 p.M." and "p.M. Where": the capitalisation pass
            // treated the period inside "p.m." as a sentence end.
            ("a.m. and p.m. keep their case",
             "Let's meet at 3 p.m. where we can talk, or at 9 a.m. if that works.",
             "Let's meet at 3 p.m. where we can talk, or at 9 a.m. if that works."),
            ("e.g. and i.e. are not sentence ends",
             "Bring snacks, e.g. chips, i.e. anything salty.",
             "Bring snacks, e.g. chips, i.e. anything salty."),
            ("a spoken period still starts a sentence",
             "that is all period see you tomorrow",
             "That is all. See you tomorrow"),
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
        check(Transcriber.prompt(forFullName: "Samir Kharel") == "I'm Samir, and I use talkflow, a dictation app.",
              "the whisper prompt names this Mac's user, for sign-offs")
        check(Transcriber.prompt(forFullName: "jo") == "I'm Jo, and I use talkflow, a dictation app.",
              "the user's first name is capitalised")
        check(Transcriber.prompt(forFullName: "") == "I use talkflow, a dictation app."
              && Transcriber.prompt(forFullName: "admin2") == "I use talkflow, a dictation app.",
              "no usable name: the sentence goes without one")
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
            // From a Gmail dictation: markers people chain, and a time said as
            // two numbers.
            ("Let's have a meeting on Thursday, wait actually Saturday at 3 p.m.",
             "Let's have a meeting on Saturday at 3 p.m."),
            ("Let's meet at 3 p.m. Wait actually no 7 30 p.m. where we can talk.",
             "Let's meet at 7 30 p.m. where we can talk."),
            ("Let's actually have a meeting on Thursday, wait actually Saturday at 3 p.m. Wait actually no 7 30 p.m. where we can talk about your product.",
             "Let's actually have a meeting on Saturday at 7 30 p.m. where we can talk about your product."),
            ("Meet at 2 30, no wait, 3.", "Meet at 3."),
            ("I'll be there Friday, wait, Saturday.", "I'll be there Saturday."),
            ("We meet Friday, actually no, Saturday.", "We meet Saturday."),
            // The replacement restates the sentence: "let's make that 4pm".
            ("Let's meet tomorrow at 7pm. Wait, actually let's make that 4pm.", "Let's meet tomorrow at 4pm."),
            ("Meet at 2, no wait, make that 3.", "Meet at 3."),
            ("Let's do Friday, wait no, let's do Thursday.", "Let's do Thursday."),
            // Times and numbers, every marker and lead-in people use.
            ("Let's meet at 7pm. Wait, make that 4pm.", "Let's meet at 4pm."),
            ("Let's meet at 7pm. Actually, 4pm.", "Let's meet at 4pm."),
            ("Let's meet at 7pm. Actually, let's make it 4pm.", "Let's meet at 4pm."),
            ("Let's meet at 7pm. Actually let's say 4pm.", "Let's meet at 4pm."),
            ("Let's meet at 7pm. Sorry, I meant 4pm.", "Let's meet at 4pm."),
            ("Let's meet at 7pm, I mean 4pm.", "Let's meet at 4pm."),
            ("Let's meet at 7pm, or rather 4pm.", "Let's meet at 4pm."),
            ("Let's meet at 7pm, correction, 4pm.", "Let's meet at 4pm."),
            ("Let's meet at 7pm. Wait, no, let's make that 4pm.", "Let's meet at 4pm."),
            ("Let's meet at 7pm. Oh wait, actually 4pm.", "Let's meet at 4pm."),
            ("Let's meet at 7pm, no wait, 4pm works better.", "Let's meet at 4pm works better."),
            ("The meeting is at three, no, four o'clock.", "The meeting is at three, no, four o'clock."),
            ("The meeting is at three, no wait, four o'clock.", "The meeting is at four o'clock."),
            ("It costs $20, no wait, $30.", "It costs $30."),
            ("Call me at 3:30, I mean 4:30.", "Call me at 4:30."),
            ("We need 50 units, sorry, 500 units.", "We need 500 units."),
            ("Let's meet at 7pm tomorrow. Wait, actually let's make that 4pm tomorrow.", "Let's meet at 4pm tomorrow."),
            // Compound replacements: the new value is several parts (day, "at",
            // time) and replaces the whole old phrase, not one token.
            ("Hey, let's meet tomorrow at 3pm. Actually, let's make that Tuesday at 2pm.", "Hey, let's meet Tuesday at 2pm."),
            ("Hey, let's meet tomorrow at 3pm actually, let's make that Tuesday at 2pm.", "Hey, let's meet Tuesday at 2pm."),
            ("Let's meet tomorrow at 3pm, wait no, Tuesday at 2pm.", "Let's meet Tuesday at 2pm."),
            ("Let's meet tomorrow at 3pm wait no Tuesday at 2pm", "Let's meet Tuesday at 2pm"),
            ("Let's meet tomorrow at 3pm. No wait, Tuesday at 2pm.", "Let's meet Tuesday at 2pm."),
            ("Let's meet tomorrow at 3pm. Oh wait, Tuesday at 2pm.", "Let's meet Tuesday at 2pm."),
            ("Let's meet tomorrow at 3pm, sorry, Tuesday at 2pm.", "Let's meet Tuesday at 2pm."),
            ("Let's meet tomorrow at 3pm, I mean Tuesday at 2pm.", "Let's meet Tuesday at 2pm."),
            ("Let's meet tomorrow at 3pm, or rather Tuesday at 2pm.", "Let's meet Tuesday at 2pm."),
            ("Let's meet tomorrow at 3pm. Correction, Tuesday at 2pm.", "Let's meet Tuesday at 2pm."),
            ("Let's meet tomorrow at 3pm. Make that Tuesday at 2pm.", "Let's meet Tuesday at 2pm."),
            ("Let's meet tomorrow at 3pm. Actually, let's say Tuesday at 2pm.", "Let's meet Tuesday at 2pm."),
            ("Let's meet tomorrow at 3pm. Sorry, I meant Tuesday at 2pm.", "Let's meet Tuesday at 2pm."),
            ("Let's meet tomorrow at 3pm. Actually, how about Tuesday at 2pm?", "Let's meet Tuesday at 2pm?"),
            ("Let's meet tomorrow at 3 p.m. Wait, Tuesday at 2 p.m.", "Let's meet Tuesday at 2 p.m."),
            ("The deadline is Monday the 5th, no wait, Tuesday the 6th.", "The deadline is Tuesday the 6th."),
            ("The deadline is Monday the 5th no wait Tuesday the 6th", "The deadline is Tuesday the 6th"),
            ("Let's meet at 3 in the park, no wait, at 4 in the park.", "Let's meet at 4 in the park."),
            ("Her birthday is June 3rd, sorry, July 3rd.", "Her birthday is July 3rd."),
            ("Her birthday is June 3rd, I mean July 4th.", "Her birthday is July 4th."),
            ("The flight leaves Friday at 6 am, wait no, Saturday at 7 am.", "The flight leaves Saturday at 7 am."),
            ("Send it to Sarah from sales, sorry, Tom from marketing.", "Send it to Tom from marketing."),
            ("Book a table for 4 at 7, actually, for 6 at 8.", "Book a table for 6 at 8."),
            // Every marker on a plain value, with and without commas.
            ("Call me at 5, wait, 6.", "Call me at 6."),
            ("Call me at 5 no wait 6", "Call me at 6"),
            ("Call me at 5 wait no 6", "Call me at 6"),
            ("Call me at 5. Oh wait, 6.", "Call me at 6."),
            ("Call me at 5. Sorry, 6.", "Call me at 6."),
            ("Call me at 5, or rather 6.", "Call me at 6."),
            ("Call me at 5. Correction, 6.", "Call me at 6."),
            ("Call me at 5, make that 6.", "Call me at 6."),
            ("Call me at 5, I mean 6.", "Call me at 6."),
            ("Call me at 5. Actually, it's 6.", "Call me at 6."),
            ("The budget is $500, wait no, $700.", "The budget is $700."),
            ("The budget is 500 dollars, sorry, 700 dollars.", "The budget is 700 dollars."),
            ("We grew 20%, I mean 25%.", "We grew 25%."),
            ("The meeting is on Wednesday. Wait, no, Thursday.", "The meeting is on Thursday."),
            ("The launch is in September, actually, October.", "The launch is in October."),
            ("Ask Priya, I mean Maria.", "Ask Maria."),
            ("We're flying to Denver, no wait, Boston.", "We're flying to Boston."),
            ("Meet me at Starbucks, sorry, Peet's.", "Meet me at Peet's."),
            // Plain words: only after an unmistakable marker, or "or rather".
            ("Bring the red folder, wait no, the blue folder.", "Bring the blue folder."),
            ("I'll take the train, no wait, the bus.", "I'll take the bus."),
            ("It was good, or rather great.", "It was great."),
            ("Meet me in the lobby, wait no, in the garden.", "Meet me in the garden."),
            // Chained twice, and two corrections in one dictation.
            ("Meet at 3, no wait, 4, no wait, 5.", "Meet at 5."),
            ("Let's do Monday, actually, Tuesday, no wait, Wednesday.", "Let's do Wednesday."),
            ("Meet at 3, wait, 4. Bring Tom, sorry, Sam.", "Meet at 4. Bring Sam."),
            ("Lunch on Friday, wait no, Thursday. Dinner at 7, I mean 8.", "Lunch on Thursday. Dinner at 8."),
            ("Fly out Monday at 9, no wait, Tuesday at 10, and back Friday, sorry, Saturday.",
             "Fly out Tuesday at 10, and back Saturday."),
            // Lowercase, unpunctuated speech-to-text.
            ("lets meet at 3 wait no 4", "lets meet at 4"),
            ("send it to sarah wait no john", "send it to sarah wait no john"),
            // Compound negatives: an answer, a list, a new thought.
            ("Is it Monday at 3? No, Tuesday at 4.", "Is it Monday at 3? No, Tuesday at 4."),
            ("I'm free Monday, actually Tuesday too.", "I'm free Monday, actually Tuesday too."),
            ("I'll pay 20 dollars, actually, 30 is fine.", "I'll pay 20 dollars, actually, 30 is fine."),
            ("I'll pay 20 dollars, no wait, 30 is fine.", "I'll pay 20 dollars, no wait, 30 is fine."),
            ("We met on Monday, sorry, Tuesday was busy.", "We met on Monday, sorry, Tuesday was busy."),
            ("I like Monday at 3, I mean it, Tuesday at 4 is worse.", "I like Monday at 3, I mean it, Tuesday at 4 is worse."),
            ("Call Sarah, actually Tom is out today.", "Call Sarah, actually Tom is out today."),
            ("It's the red one, I mean the one by the door.", "It's the red one, I mean the one by the door."),
            ("Sorry, I meant to call you at 5.", "Sorry, I meant to call you at 5."),
            ("Actually, let's make that work on Tuesday.", "Actually, let's make that work on Tuesday."),
            ("Make that happen by Friday.", "Make that happen by Friday."),
            ("Correction fluid is on the desk.", "Correction fluid is on the desk."),
            ("I'd rather go on Monday.", "I'd rather go on Monday."),
            ("Wait no longer than 5 minutes.", "Wait no longer than 5 minutes."),
            ("Sorry Tom, Sarah is out until Monday.", "Sorry Tom, Sarah is out until Monday."),
            ("It was good, I mean really good.", "It was good, I mean really good."),
            ("I'm sorry, Monday doesn't work.", "I'm sorry, Monday doesn't work."),
            ("No, Friday works.", "No, Friday works."),
            ("Oh wait, I forgot the keys.", "Oh wait, I forgot the keys."),
            ("Never mind, it's fine.", "Never mind, it's fine."),
            ("The train is red, no wait, it's the bus that's red.", "The train is red, no wait, it's the bus that's red."),
            ("I said Monday, actually.", "I said Monday, actually."),
            ("He scored 3, then 4, then 5.", "He scored 3, then 4, then 5."),
            ("Monday, Tuesday, or Wednesday all work.", "Monday, Tuesday, or Wednesday all work."),
            // A lead-in sets off a weak marker, but "actually make that" is
            // still not one; a changed plain word needs a full replacement.
            ("We could actually make that work by Friday.", "We could actually make that work by Friday."),
            ("I actually make it 5 times a week.", "I actually make it 5 times a week."),
            ("I'd actually say Monday at 3 works.", "I'd actually say Monday at 3 works."),
            ("Bring the red folder, wait no, the blue folder is better.", "Bring the red folder, wait no, the blue folder is better."),
            ("Bring the red folder wait no the blue folder", "Bring the red folder wait no the blue folder"),
            ("Pick the big red box, wait no, the small blue box.", "Pick the big red box, wait no, the small blue box."),
            // Days, months, names.
            ("Let's meet on Monday. Actually, let's make it Tuesday.", "Let's meet on Tuesday."),
            ("Let's meet Monday. Wait, I meant Tuesday.", "Let's meet Tuesday."),
            ("It is due on March 5th, no wait, March 6th.", "It is due on March 6th."),
            ("The party is in June, sorry, July.", "The party is in July."),
            ("Tell John, actually tell Mike.", "Tell Mike."),
            ("Send it to Sarah, no wait, send it to Sam.", "Send it to Sam."),
            ("Email Sarah, wait, I mean Sam, about the report.", "Email Sam, about the report."),
            ("Invite Priya, no wait, Priyanka.", "Invite Priyanka."),
            // Plain words, only after an unmistakable marker.
            ("I like cats, wait no, dogs.", "I like dogs."),
            // Unpunctuated, so "is" below could just as well be a swap: left alone.
            ("There is no wait, fine.", "There is no wait, fine."),
            ("He said yes, wait no, it\'s fine.", "He said yes, wait no, it\'s fine."),
            // New rules must not reach too far.
            ("I'll call at 5, actually it's raining, so no.", "I'll call at 5, actually it's raining, so no."),
            ("He told me to ignore that. Fine.", "He told me to ignore that. Fine."),
            ("Please strike that chord again.", "Please strike that chord again."),
            ("It is the 5th, I mean it, we are late.", "It is the 5th, I mean it, we are late."),
            ("Oh, that is great news.", "Oh, that is great news."),
            // Whole-clause retractions.
            ("Let's go to the park. Strike that. Let's go home.", "Let's go home."),
            ("Order pizza, scratch that, order sushi.", "Order sushi."),
            ("We should leave now, ignore that, we should wait.", "We should wait."),
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
            // An answer, not a correction: a lone "no" is never a marker.
            ("Is it Friday? No, Thursday.", "Is it Friday? No, Thursday."),
            ("I'll be there at 5, wait for me.", "I'll be there at 5, wait for me."),
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
            ("a compound correction typed into Notes",
             "Hey, let's meet tomorrow at 3pm. Actually, let's make that Tuesday at 2pm.",
             "Hey, let's meet Tuesday at 2pm."),
            ("two compound corrections in one hold",
             "Fly out Monday at 9, no wait, Tuesday at 10, and back Friday, sorry, Saturday.",
             "Fly out Tuesday at 10, and back Saturday."),
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

    /// The default mode: the caption shows the words while speaking, and the
    /// field is written once at release. Plus the rules that fit the text to
    /// where it lands, and the two that only ever take punctuation, casing and
    /// spellings from elsewhere.
    private static func runInsertOnceCases() {
        report("case: insert once at release, fitted to the field")

        // Nothing is on screen before release, so the corrected text - even
        // a correction at the very start of a long dictation, which the live
        // mode had to refuse over keystrokes - goes in as one pure insert.
        let long = "Let's move the review to Friday, wait no, Thursday, and then we can go over the launch plan, the pricing page, the onboarding emails, the support docs and everything else the team has been working on for the last month so that nothing is left for the week after"
        let final = Dictation.render(long, leadingSpace: "", structure: true)
        let insert = FieldSync.edit(from: "", to: final)
        check(insert.deleting == 0 && insert.inserting == final && final.hasPrefix("Let's move the review to Thursday,"),
              "insert-once: an early correction goes in with the rest, deleting nothing", final.debugDescription)

        // Caption: settled words solid, the rest dimmed; a revised word is
        // never shown as settled.
        let parts = Dictation.captionParts(committed: " Let's meet", rendered: " Let's meet at 3")
        check(parts.settled == "Let's meet" && parts.pending == " at 3", "caption: settled and pending split", "\(parts)")
        let revised = Dictation.captionParts(committed: " Let's meet to", rendered: " Let's meet two")
        check(revised.settled.isEmpty && revised.pending == "Let's meet two", "caption: a revised word is shown dimmed", "\(revised)")

        // Mid-sentence: lowercase the first word, unless it is I, an acronym
        // or a name.
        check(ScreenContext.continuesSentence(after: "Thanks for the notes and"), "context: no sentence end before the caret continues it")
        check(!ScreenContext.continuesSentence(after: "Thanks for the notes. "), "context: after a full stop starts fresh")
        check(!ScreenContext.continuesSentence(after: "Hi Sarah,\n"), "context: a new line starts fresh")
        check(!ScreenContext.continuesSentence(after: ""), "context: an empty field starts fresh")
        check(!ScreenContext.continuesSentence(after: nil), "context: an unreadable field starts fresh")
        let lowered: [(String, String)] = [
            (" Great work on the deck.", " great work on the deck."),
            (" I think so.", " I think so."),
            (" NASA called.", " NASA called."),
            (" Samantha said yes.", " Samantha said yes."),
            (" I'm in.", " I'm in.")
        ]
        for (raw, want) in lowered {
            let got = ScreenContext.lowercasingStart(raw, names: ["Samantha"])
            check(got == want, "context: lowercasing \(raw.debugDescription)", got.debugDescription)
        }

        // Chat apps: a one-sentence message drops its final period.
        let chats: [(String, String)] = [
            ("Sounds good, see you at 5.", "Sounds good, see you at 5"),
            ("See you at 3 p.m.", "See you at 3 p.m."),
            ("Are you coming?", "Are you coming?"),
            ("Thanks. See you soon.", "Thanks. See you soon."),
            ("Wait...", "Wait..."),
            ("Hi,\n\nSee you.", "Hi,\n\nSee you.")
        ]
        for (raw, want) in chats {
            let got = ScreenContext.chatStyled(raw)
            check(got == want, "chat: \(raw.debugDescription)", got.debugDescription)
        }
        check(ScreenContext.isChat(bundleID: "com.tinyspeck.slackmacgap") && !ScreenContext.isChat(bundleID: "com.apple.Notes"),
              "chat: Slack is a chat, Notes is not")

        // Prompt: names and learned words appended as a plain sentence.
        check(ScreenContext.prompt(names: [], learned: []) == Transcriber.vocabularyPrompt, "prompt: unchanged with no context")
        let prompt = ScreenContext.prompt(names: ["Siobhan", "Acme"], learned: ["Kubernetes", "siobhan"])
        check(prompt == Transcriber.vocabularyPrompt + " Names and words here: Siobhan, Acme, Kubernetes.",
              "prompt: names then learned words, without duplicates", prompt)
        let names = ScreenContext.names(in: ["Samantha Lee", "Inbox", "Re: launch plan with Priya Patel and the team"])
        check(names.contains("Samantha") && names.contains("Lee") && !names.contains("Inbox"),
              "names: a recipient chip counts, interface labels do not", "\(names)")

        // Lists whisper wrote without commas, and the sign-off comma: the
        // dictation from the screenshot.
        let screenshot = Dictation.render("Hey Samantha, thank you for getting back with me in the email. I guess three things that I need you to do is first pick up the water, second upload your resume to our app, and then third tell other people about our app. And let's also have a meeting tomorrow at 8 p.m. and have your resume ready by that time. Best Samir.", leadingSpace: "", structure: true)
        check(screenshot == "Hey Samantha,\n\nThank you for getting back with me in the email. I guess three things that I need you to do is:\n1. Pick up the water\n2. Upload your resume to our app\n3. Tell other people about our app. And let's also have a meeting tomorrow at 8 p.m. and have your resume ready by that time.\n\nBest, Samir.",
              "list: bare ordinals become a list, and the sign-off gets its comma", screenshot.debugDescription)
        let prose: [String] = [
            "At first I hated it, but the second time was great.",
            "Wait a second, the first thing is the budget.",
            "I came first and my sister came second.",
            "The first draft was fine and the second one was better.",
            "Thanks Sam."
        ]
        for text in prose {
            let got = Dictation.render(text, leadingSpace: "", structure: true)
            check(got == text, "list: prose stays prose: \(text.debugDescription)", got.debugDescription)
        }
        let bare = Dictation.render("I need three things. First pick up the water, second upload your resume, third tell people about our app.", leadingSpace: "", structure: true)
        check(bare == "I need three things.\n1. Pick up the water\n2. Upload your resume\n3. Tell people about our app.",
              "list: a comma-less chain after its own sentence", bare.debugDescription)
        check(StructurePolish.punctuateSignOff("Body.\n\nThanks Sarah") == "Body.\n\nThanks, Sarah", "sign-off: comma added")
        check(StructurePolish.punctuateSignOff("Body.\n\nBest, Samir.") == "Body.\n\nBest, Samir.", "sign-off: an existing comma stays")
        check(StructurePolish.punctuateSignOff("We should thank Sarah") == "We should thank Sarah", "sign-off: not a sign-off paragraph")

        // AI punctuation: only punctuation, casing and line breaks come from
        // the model. This is its real answer from a probe on this Mac, with
        // "is" changed to "are".
        let original = "I guess three things that I need you to do is first pick up the water, second upload your resume. Best Samir."
        let suggestion = "I guess three things that I need you to do are: first, pick up the water; second, upload your resume. Best, Samir."
        let merged = Polish.merge(original: original, suggestion: suggestion, names: ["Samir"])
        check(merged == "I guess three things that I need you to do is first, pick up the water; second, upload your resume. Best, Samir.",
              "polish: a changed word is ignored, punctuation is taken", merged.debugDescription)
        check(SelfCorrection.isDeletionOnly(original: original, result: merged) && SelfCorrection.isDeletionOnly(original: merged, result: original),
              "polish: the merge has exactly the original's words")
        let invented = Polish.merge(original: "meet at 3 tomorrow", suggestion: "Let's meet at 3 PM tomorrow!")
        check(invented == "meet at 3 tomorrow!", "polish: invented words are dropped", invented.debugDescription)
        let lowered2 = Polish.merge(original: "Thanks Samir and I will call", suggestion: "thanks samir, and i will call.", names: ["Samir"])
        check(lowered2 == "thanks Samir, and I will call.", "polish: names and I keep their capitals", lowered2.debugDescription)
        let broken = Polish.merge(original: "Hi Sarah, the deck is ready.", suggestion: "Hi Sarah,\n\nThe deck is ready.")
        check(broken == "Hi Sarah,\n\nThe deck is ready.", "polish: a line break between kept words is taken", broken.debugDescription)
        let empty = Polish.merge(original: "keep this", suggestion: "")
        check(empty == "keep this", "polish: an empty answer changes nothing")

        // Vocabulary: a fixed spelling between unchanged neighbours is
        // learned; a rewrite is not.
        let known: (String) -> Bool = { $0 != "Shivon" } // what NSSpellChecker answered on this Mac
        let learned = Vocabulary.fixes(inserted: "Thanks Shivon for the notes.", fieldText: "Thanks Siobhan for the notes.", isKnown: known)
        check(learned == ["Siobhan"], "vocabulary: a corrected name is learned", "\(learned)")
        let rewrite = Vocabulary.fixes(inserted: "Let's meet on Friday at noon.", fieldText: "Let's meet on Thursday at noon.", isKnown: known)
        check(rewrite.isEmpty, "vocabulary: a different word is not a spelling fix", "\(rewrite)")
        let untouched = Vocabulary.fixes(inserted: "Thanks Shivon for the notes.", fieldText: "Thanks Shivon for the notes.", isKnown: known)
        check(untouched.isEmpty, "vocabulary: nothing changed, nothing learned")
        check(Vocabulary.isKnownWord("Thursday") && !Vocabulary.isKnownWord("Shivon"), "vocabulary: the real spell checker agrees")
        check(Vocabulary.distance("kitten", "sitting") == 3 && Vocabulary.distance("", "abc") == 3, "vocabulary: edit distance")
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

    /// Settings: Formal / Casual / all lowercase. Only case and the closing
    /// full stop may change - never a word.
    private static func runWritingStyleCases() {
        let text = "Hi Sarah. I'm sure I'll send it, and I think it's fine."
        check(WritingStyle.formal.apply(text) == text, "formal leaves the text alone")
        check(WritingStyle.lowercase.apply(text) == "hi sarah. i'm sure i'll send it, and i think it's fine.",
              "lowercase lowercases every letter", WritingStyle.lowercase.apply(text).debugDescription)
        check(WritingStyle.casual.apply(text) == "hi sarah. I'm sure I'll send it, and I think it's fine",
              "casual lowercases, keeps I, drops the closing full stop", WritingStyle.casual.apply(text).debugDescription)
        check(WritingStyle.casual.apply("Wait for it...") == "wait for it...", "casual keeps an ellipsis")
        check(WritingStyle.casual.apply("Is it in the inbox? Yes. ") == "is it in the inbox? yes ",
              "casual keeps trailing whitespace", WritingStyle.casual.apply("Is it in the inbox? Yes. ").debugDescription)
        check(WritingStyle.casual.apply("ice is nice") == "ice is nice", "casual does not touch i inside words")
        let rendered = Dictation.render("can you check the deck period thanks", leadingSpace: " ", structure: true, style: .lowercase)
        check(rendered == " can you check the deck. thanks", "render applies the style after casing", rendered.debugDescription)
        for style in WritingStyle.allCases {
            let raw = "Dear Sarah, can you send the file. Thanks, Samir."
            let styled = style.apply(raw)
            check(SelfCorrection.tokenize(styled).map(\.norm) == SelfCorrection.tokenize(raw).map(\.norm),
                  "\(style.rawValue) keeps every word")
        }
    }

    /// Setup keeps its step when the window comes back after a grant, moves
    /// on by itself when the pending grant lands, and resumes after a relaunch.
    private static func runOnboardingStepCases() {
        report("case: setup keeps its step and moves on when a grant lands")
        typealias G = PermissionGrants
        let none = G(microphone: false, accessibility: false, inputMonitoring: false)
        let mic = G(microphone: true, accessibility: false, inputMonitoring: false)
        let micAX = G(microphone: true, accessibility: true, inputMonitoring: false)
        let all = G(microphone: true, accessibility: true, inputMonitoring: true)
        let micIM = G(microphone: true, accessibility: false, inputMonitoring: true)

        // The pure rule.
        for step in OnboardingStep.allCases {
            for grants in [none, mic, micAX, all, micIM] {
                check(OnboardingFlow.stepAfterRefresh(current: step, before: grants, now: grants) == step,
                      "flow: nothing changed keeps \(step) (grants \(grants.microphone)/\(grants.accessibility)/\(grants.inputMonitoring))")
            }
        }
        check(OnboardingFlow.stepAfterRefresh(current: .microphone, before: none, now: mic) == .accessibility,
              "flow: the microphone grant moves on to Accessibility")
        check(OnboardingFlow.stepAfterRefresh(current: .accessibility, before: mic, now: micAX) == .inputMonitoring,
              "flow: the Accessibility grant moves on to Input Monitoring")
        check(OnboardingFlow.stepAfterRefresh(current: .accessibility, before: micIM, now: all) == .engine,
              "flow: an already granted Input Monitoring is skipped")
        check(OnboardingFlow.stepAfterRefresh(current: .inputMonitoring, before: micAX, now: all) == .engine,
              "flow: the Input Monitoring grant moves on to the engine")
        check(OnboardingFlow.stepAfterRefresh(current: .microphone, before: mic, now: micAX) == .microphone,
              "flow: a grant for another step does not move this one")
        check(OnboardingFlow.stepAfterRefresh(current: .welcome, before: none, now: all) == .welcome,
              "flow: the welcome page never moves by itself")
        check(OnboardingFlow.stepAfterRefresh(current: .accessibility, before: micAX, now: mic) == .accessibility,
              "flow: a lost grant does not move the step")

        check(OnboardingFlow.initialStep(completed: false, saved: nil, grants: none, engineInstalled: false) == .welcome,
              "flow: a first run opens on the welcome page")
        check(OnboardingFlow.initialStep(completed: false, saved: .accessibility, grants: mic, engineInstalled: false) == .accessibility,
              "flow: an interrupted first run resumes on its step")
        check(OnboardingFlow.initialStep(completed: false, saved: .inputMonitoring, grants: all, engineInstalled: false) == .engine,
              "flow: an interrupted first run moves past a grant that landed during the relaunch")
        check(OnboardingFlow.initialStep(completed: false, saved: .inputMonitoring, grants: micIM, engineInstalled: false) == .accessibility,
              "flow: an interrupted first run goes back to a grant that was lost")
        check(OnboardingFlow.initialStep(completed: true, saved: nil, grants: micIM, engineInstalled: true) == .accessibility,
              "flow: a finished setup reopens on what is missing")

        // The model, with fake permissions, as the window drives it.
        final class Fake { var mic = Permissions.MicrophoneStatus.notDetermined; var ax = false; var im = false }
        let fake = Fake()
        let defaults = MemoryDefaults()
        let environment = OnboardingEnvironment(
            microphone: { fake.mic }, accessibility: { fake.ax }, inputMonitoring: { fake.im },
            engineInstalled: { false }, defaults: defaults, advanceDelay: 0)
        let model = OnboardingModel(startHotkey: { true }, environment: environment)
        var raised = 0
        model.bringToFront = { raised += 1 }
        model.begin()
        check(model.step == .welcome, "model: a first run opens on the welcome page", "\(model.step)")
        model.goNext()
        check(model.step == .microphone, "model: Get started goes to the microphone", "\(model.step)")
        fake.mic = .granted
        model.refresh(announce: true)
        check(model.step == .accessibility, "model: the microphone grant moves on by itself", "\(model.step)")
        check(raised == 1, "model: a grant brings the window forward", "\(raised)")
        model.refresh(announce: true)
        model.begin() // what showing the window again does (menu bar, or a grant raising it)
        check(model.step == .accessibility, "model: showing the window again keeps the step", "\(model.step)")
        fake.ax = true
        model.refresh(announce: true)
        model.begin()
        check(model.step == .inputMonitoring, "model: back from System Settings, the Accessibility step is done, not the first page", "\(model.step)")
        model.stop()

        // macOS relaunches the app after the Input Monitoring grant.
        fake.im = true
        check(Onboarding.wasInterrupted(defaults: defaults), "model: an unfinished first run opens again on launch")
        let relaunched = OnboardingModel(startHotkey: { true }, environment: environment)
        relaunched.begin()
        check(relaunched.step == .engine, "model: after a relaunch setup resumes past the granted step", "\(relaunched.step)")
        relaunched.stop()
        // What finish() records (not called here: it changes the login item).
        defaults.set(true, forKey: Onboarding.completedKey)
        check(!Onboarding.wasInterrupted(defaults: defaults), "model: a finished setup does not reopen on launch")
    }

    /// The few UserDefaults calls setup makes, answered from a dictionary
    /// (a real defaults suite would leave a file in ~/Library/Preferences).
    private final class MemoryDefaults: UserDefaults {
        private var store: [String: Any] = [:]

        override func object(forKey key: String) -> Any? { store[key] }
        override func set(_ value: Any?, forKey key: String) { store[key] = value }
        override func set(_ value: Bool, forKey key: String) { store[key] = value }
        override func set(_ value: Int, forKey key: String) { store[key] = value }
        override func removeObject(forKey key: String) { store[key] = nil }
        override func bool(forKey key: String) -> Bool { store[key] as? Bool ?? false }
        override func integer(forKey key: String) -> Int { store[key] as? Int ?? 0 }
        override func string(forKey key: String) -> String? { store[key] as? String }
    }

    /// GitHub release parsing and version order, for the update check.
    private static func runUpdaterCases() {
        check(Updater.isNewer("0.2.0", than: "0.1.0"), "0.2.0 is newer than 0.1.0")
        check(Updater.isNewer("0.10.0", than: "0.9.2"), "versions compare numerically, not as text")
        check(!Updater.isNewer("0.1", than: "0.1.0"), "a missing part counts as zero")
        check(!Updater.isNewer("0.1.0", than: "0.2.0"), "an older release is not offered")
        let json = #"{"tag_name":"v0.2.0","draft":false,"prerelease":false,"html_url":"https://github.com/x/y/releases/v0.2.0","assets":[{"name":"notes.txt","browser_download_url":"https://e/notes.txt"},{"name":"talkflow-0.2.0.zip","browser_download_url":"https://e/talkflow-0.2.0.zip"}]}"#
        let release = Updater.parse(Data(json.utf8))
        check(release?.version == "0.2.0", "the v prefix is dropped from the tag", String(describing: release))
        check(release?.zipURL.absoluteString == "https://e/talkflow-0.2.0.zip", "the zip asset is chosen")
        check(Updater.parse(Data(#"{"tag_name":"v1.0.0","assets":[]}"#.utf8)) == nil, "a release with no zip is ignored")
        check(Updater.parse(Data(#"{"tag_name":"v1.0.0","prerelease":true,"assets":[{"name":"a.zip","browser_download_url":"https://e/a.zip"}]}"#.utf8)) == nil,
              "a prerelease is not offered")
        check(release?.sha256 == nil, "an API release without a digest has no checksum")
        let digested = Updater.parse(Data(#"{"tag_name":"v0.2.0","assets":[{"name":"talkflow-macos.zip","digest":"sha256:F24AF5EB6080C9E6667C30BB9B3BACC06C0C558543E08B2474037036706DF59A","browser_download_url":"https://e/t.zip"}]}"#.utf8))
        check(digested?.sha256 == "f24af5eb6080c9e6667c30bb9b3bacc06c0c558543e08b2474037036706df59a",
              "GitHub's asset digest is used as the checksum", String(describing: digested))
        runManifestCases()
    }

    /// talkflow-release.json (docs/releases.md), the first thing the update
    /// check reads.
    private static func runManifestCases() {
        let sha = String(repeating: "ab", count: 32)
        func manifest(version: String = "0.2.0", schema: String = "1", platforms: String) -> Updater.Manifest? {
            let json = #"{"schema":\#(schema),"version":"\#(version)","tag":"v\#(version)","published":"2026-10-05T12:00:00Z","notesUrl":"https://github.com/x/y/releases/tag/v\#(version)","notes":"","platforms":{\#(platforms)}}"#
            return Updater.parseManifest(Data(json.utf8))
        }
        let mac = #""macos":{"universal":{"update":{"name":"talkflow-macos.zip","url":"https://e/talkflow-macos.zip","sha256":"\#(sha)","size":123},"installer":{"name":"talkflow-macos.dmg","url":"https://e/talkflow-macos.dmg","sha256":"\#(sha)","size":456}}}"#
        let windows = #""windows":{"x64":{"update":{"name":"talkflow-windows-x64-setup.exe","url":"https://e/w.exe","sha256":"\#(sha)","size":1}}}"#

        let newer = manifest(platforms: mac + "," + windows + #","linux":{}"#)
        check(newer?.release?.version == "0.2.0", "manifest: the macOS update is read", String(describing: newer))
        check(newer?.release?.zipURL.absoluteString == "https://e/talkflow-macos.zip", "manifest: the update zip is chosen, not the dmg")
        check(newer?.release?.sha256 == sha, "manifest: the update's sha256 is kept for the download check")
        check(newer?.release?.pageURL?.absoluteString == "https://github.com/x/y/releases/tag/v0.2.0", "manifest: notesUrl is the release page")
        check(newer?.release.map { Updater.isNewer($0.version, than: "0.1.3") } == true, "manifest: a newer version is offered")

        let same = manifest(version: "0.1.3", platforms: mac)
        check(same?.release.map { Updater.isNewer($0.version, than: "0.1.3") } == false, "manifest: the same version is not offered")

        let windowsOnly = manifest(platforms: windows + #","linux":{}"#)
        check(windowsOnly != nil && windowsOnly?.release == nil, "manifest: no macOS entry means no update", String(describing: windowsOnly))
        let installerOnly = manifest(platforms: #""macos":{"universal":{"installer":{"name":"talkflow-macos.dmg","url":"https://e/d.dmg","sha256":"\#(sha)","size":1}}}"#)
        check(installerOnly != nil && installerOnly?.release == nil, "manifest: a dmg alone is not an update")

        let unknown = manifest(platforms: mac + #","plan9":{"mips":{"update":{"url":"https://e/x"}}},"windows":{"riscv":{"update":{}}}"#)
        check(unknown?.release?.zipURL.absoluteString == "https://e/talkflow-macos.zip", "manifest: unknown platforms and arches are ignored")
        let otherArch = manifest(platforms: #""macos":{"arm64":{"update":{"name":"a.zip","url":"https://e/a.zip","sha256":"\#(sha)","size":1}}}"#)
        check(otherArch != nil && otherArch?.release == nil, "manifest: only the universal macOS build is used")

        check(Updater.parseManifest(Data("not json".utf8)) == nil, "manifest: bad JSON is rejected")
        check(Updater.parseManifest(Data("[1,2]".utf8)) == nil, "manifest: a JSON array is rejected")
        check(manifest(schema: "2", platforms: mac) == nil, "manifest: an unknown schema is rejected")
        let badSum = manifest(platforms: #""macos":{"universal":{"update":{"name":"z","url":"https://e/z.zip","sha256":"1234","size":1}}}"#)
        check(badSum != nil && badSum?.release == nil, "manifest: an entry without a full sha256 is not offered")
        let plainHTTP = manifest(platforms: #""macos":{"universal":{"update":{"name":"z","url":"http://e/z.zip","sha256":"\#(sha)","size":1}}}"#)
        check(plainHTTP != nil && plainHTTP?.release == nil, "manifest: an http (not https) update URL is not offered")

        // The download check: sha256("abc") is a published test vector.
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("talkflow-sha256-\(UUID().uuidString)")
        try? Data("abc".utf8).write(to: file)
        check(Updater.sha256Hex(of: file) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
              "the download's sha256 is computed correctly")
        try? FileManager.default.removeItem(at: file)
        check(Updater.sha256Hex(of: file) == nil, "a missing download has no sha256")
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
