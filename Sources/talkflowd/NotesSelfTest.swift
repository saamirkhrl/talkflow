import Foundation

/// `talkflowd --notestest`: the note taker's merge, speaker, label and copy
/// rules on plain values, and the notes store in a temporary folder. Never
/// touches the real notes folder or any UserDefaults.
enum NotesSelfTest {
    private static var failures = 0

    private static var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private static func d(_ s: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s) ?? Date(timeIntervalSince1970: 0)
    }

    private static func p(_ speaker: String, _ start: Double, _ end: Double, _ text: String) -> SpeechPiece {
        SpeechPiece(speaker: speaker, start: start, end: end, text: text)
    }

    private static func meta(_ id: String, _ started: Date, title: String = "T", duration: Double = 0,
                             speakers: [NoteSpeaker] = [], state: NoteState = .ready, items: Int? = nil) -> NoteMeta {
        NoteMeta(id: id, title: title, started: started, duration: duration, speakers: speakers,
                 state: state, actionItemCount: items)
    }

    static func run() -> Never {
        // Start clean, so a passing run can't be read out of a previous one's
        // leftovers.
        try? FileManager.default.removeItem(at: logURL)
        report("--- notestest ---")

        let now = d("2026-11-23 15:00")

        // MARK: Assembly

        let a1 = NotesLogic.assemble([p("you", 0, 2, "Hello"), p("s1", 2.5, 4, "Hi"), p("you", 4.2, 6, "How are you")])
        check(a1.count == 3 && a1.map { $0.speaker } == ["you", "s1", "you"] && a1.map { $0.text } == ["Hello", "Hi", "How are you"],
              "A1 alternating speakers stay separate turns", "\(a1)")

        let a2 = NotesLogic.assemble([p("you", 0, 2, "a"), p("you", 10, 12, "c"), p("s1", 5, 7, "b")])
        check(a2.map { $0.text } == ["a", "b", "c"] && a2.map { $0.speaker } == ["you", "s1", "you"],
              "A2 two tracks are put in time order", "\(a2)")

        let a3 = NotesLogic.assemble([p("you", 0, 2, "one"), p("you", 3, 5, "two")])
        check(a3.count == 1 && a3[0].text == "one two" && a3[0].start == 0 && a3[0].end == 5,
              "A3 same speaker, gap 1.0, merges", "\(a3)")

        let a4a = NotesLogic.assemble([p("s1", 0, 1, "a"), p("s1", 4, 5, "b")])
        check(a4a.count == 1, "A4 gap exactly 3.0 merges", "\(a4a)")
        let a4b = NotesLogic.assemble([p("s1", 0, 1, "a"), p("s1", 4.01, 5, "b")])
        check(a4b.count == 2, "A4 gap 3.01 does not merge", "\(a4b)")

        let a5a = NotesLogic.assemble([p("you", 0, 50, "a"), p("you", 50.5, 95, "b")])
        check(a5a.count == 2, "A5 a turn past 90 s is split", "\(a5a)")
        let a5b = NotesLogic.assemble([p("you", 0, 50, "a"), p("you", 50.5, 90, "b")])
        check(a5b.count == 1 && a5b[0].end == 90, "A5 a turn of exactly 90 s merges", "\(a5b)")

        let a6 = NotesLogic.assemble([p("you", 0, 1, "a"), p("s1", 1.2, 1.5, "  \n"), p("you", 2, 3, "b")])
        check(a6.count == 1 && a6[0].text == "a b", "A6 an empty piece is dropped and does not split", "\(a6)")

        let a7 = NotesLogic.assemble([p("you", 0, 1, "  hi \n")])
        check(a7.count == 1 && a7[0].text == "hi", "A7 text is trimmed", "\(a7)")

        check(NotesLogic.assemble([]).isEmpty, "A8 no pieces, no turns")

        let a9 = NotesLogic.assemble([p("you", 0, 5, "a"), p("s1", 3, 6, "b")])
        check(a9.map { $0.speaker } == ["you", "s1"], "A9 overlap across speakers keeps two turns", "\(a9)")

        let a10 = NotesLogic.assemble([p("s1", 0, 1, "x"), p("you", 0, 1, "y")])
        check(a10.map { $0.speaker } == ["s1", "you"], "A10 a tie on start keeps input order", "\(a10)")

        let a11 = NotesLogic.assemble([p("you", 5, 4, "z")])
        check(a11.count == 1 && a11[0].start == 5 && a11[0].end == 5, "A11 an end before the start is clamped", "\(a11)")

        // MARK: Speakers

        let n1 = NotesLogic.numberSpeakers([p("B", 0, 1, "x"), p("A", 5, 6, "y"), p("B", 9, 10, "z")]).map { $0.speaker }
        check(n1 == ["s1", "s2", "s1"], "N1 voices are numbered by first appearance", "\(n1)")

        let n2 = NotesLogic.numberSpeakers([p("you", 0, 1, "x"), p("C", 1, 2, "y")]).map { $0.speaker }
        check(n2 == ["you", "s1"], "N2 you is never renumbered", "\(n2)")

        let n3 = NotesLogic.numberSpeakers([p("A", 10, 11, "x"), p("B", 2, 3, "y")]).map { $0.speaker }
        check(n3 == ["s2", "s1"], "N3 first appearance is by time, not input order", "\(n3)")

        let n4 = NotesLogic.transcript(from: [p("spk0", 1, 2, "Hi there"), p("you", 0, 0.8, "Hello"),
                                              p("spk1", 3, 4, "Morning"), p("spk0", 4.5, 5, "Welcome")])
        let n4Expected = [TranscriptTurn(speaker: "you", start: 0, end: 0.8, text: "Hello"),
                          TranscriptTurn(speaker: "s1", start: 1, end: 2, text: "Hi there"),
                          TranscriptTurn(speaker: "s2", start: 3, end: 4, text: "Morning"),
                          TranscriptTurn(speaker: "s1", start: 4.5, end: 5, text: "Welcome")]
        check(n4.turns == n4Expected && NotesLogic.speakerKeys(in: n4.turns) == ["you", "s1", "s2"] && n4.schemaVersion == 1,
              "N4 transcript(from:) assembles, numbers and versions", "\(n4)")

        let n5 = [NotesLogic.defaultName("you"), NotesLogic.defaultName("s1"), NotesLogic.defaultName("s12"),
                  NotesLogic.defaultName("s0"), NotesLogic.defaultName("x")]
        check(n5 == ["You", "Speaker 1", "Speaker 12", "s0", "x"], "N5 default names", "\(n5)")

        let n6 = NotesLogic.speakers(for: n4.turns, keeping: [NoteSpeaker(key: "s1", name: "Maya"), NoteSpeaker(key: "s9", name: "Old")])
        check(n6 == [NoteSpeaker(key: "you", name: nil), NoteSpeaker(key: "s1", name: "Maya"), NoteSpeaker(key: "s2", name: nil)],
              "N6 names carry over, absent speakers drop", "\(n6)")

        // MARK: Rename

        let base = [NoteSpeaker(key: "you", name: nil), NoteSpeaker(key: "s1", name: nil), NoteSpeaker(key: "s2", name: nil)]
        let r1 = NotesLogic.renaming("s1", to: " Maya ", in: base)
        check(r1[1].name == "Maya" && NotesLogic.displayName("s1", in: r1) == "Maya", "R1 rename trims", "\(r1)")

        let r2 = NotesLogic.renaming("s1", to: "", in: r1)
        check(r2[1].name == nil && NotesLogic.displayName("s1", in: r2) == "Speaker 1", "R2 empty name resets", "\(r2)")

        let r3 = NotesLogic.renaming("you", to: "Sam", in: base)
        check(r3 == base && NotesLogic.displayName("you", in: r3) == "You", "R3 you cannot be renamed", "\(r3)")

        let r4 = NotesLogic.renaming("s2", to: "Speaker 2", in: base)
        check(r4[2].name == nil, "R4 the default name is stored as nil", "\(r4)")

        let r5 = NotesLogic.renaming("s1", to: String(repeating: "a", count: 50), in: base)
        check(r5[1].name?.count == 40, "R5 a long name is cut to 40", "\(r5[1].name?.count ?? -1)")

        let r6 = NotesLogic.renaming("s7", to: "X", in: base)
        check(r6 == base, "R6 an unknown speaker changes nothing", "\(r6)")

        let r7 = NotesLogic.displayName("s1", in: [NoteSpeaker(key: "s1", name: "  ")])
        check(r7 == "Speaker 1", "R7 a blank name shows the default", r7)

        // MARK: Labels

        let ts: [(Double, String)] = [(0, "0:00"), (4.9, "0:04"), (59, "0:59"), (60, "1:00"), (754, "12:34"),
                                      (3600, "1:00:00"), (3725, "1:02:05"), (-3, "0:00"), (.nan, "0:00")]
        let tsGot = ts.map { NotesLogic.timestamp($0.0) }
        check(tsGot == ts.map { $0.1 }, "T1 timestamps", "\(tsGot)")

        let dt: [(Double, String)] = [(0, "1 min"), (29, "1 min"), (90, "2 min"), (2520, "42 min"), (3570, "1 h"),
                                      (3900, "1 h 5 min"), (7200, "2 h")]
        let dtGot = dt.map { NotesLogic.durationText($0.0) }
        check(dtGot == dt.map { $0.1 }, "T2 durationText", "\(dtGot)")

        let sd: [(Double, String)] = [(60, "1 minute"), (2520, "42 minutes"), (3660, "1 hour 1 minute"),
                                      (7500, "2 hours 5 minutes"), (3600, "1 hour")]
        let sdGot = sd.map { NotesLogic.spokenDuration($0.0) }
        check(sdGot == sd.map { $0.1 }, "T3 spokenDuration", "\(sdGot)")

        let dot = " \u{00B7} "
        let three = [NoteSpeaker(key: "you", name: nil), NoteSpeaker(key: "s1", name: nil), NoteSpeaker(key: "s2", name: nil)]
        let two = Array(three.prefix(2))
        let one = Array(three.prefix(1))
        let rd = [
            NotesLogic.rowDetail(meta("x", now, duration: 2520, speakers: three, state: .ready, items: 4)),
            NotesLogic.rowDetail(meta("x", now, duration: 420, speakers: two, state: .ready, items: nil)),
            NotesLogic.rowDetail(meta("x", now, duration: 60, speakers: one, state: .ready, items: 1)),
            NotesLogic.rowDetail(meta("x", now, duration: 0, speakers: [], state: .ready, items: nil)),
            NotesLogic.rowDetail(meta("x", now, state: .recording)),
            NotesLogic.rowDetail(meta("x", now, state: .writing(.speakers))),
            NotesLogic.rowDetail(meta("x", now, state: .failed(NoteFailure(step: .saving, message: "m", retry: .none)))),
        ]
        let rdExpected = ["42 min" + dot + "3 speakers" + dot + "4 action items",
                          "7 min" + dot + "2 speakers" + dot + "Transcript only",
                          "1 min" + dot + "1 speaker" + dot + "1 action item",
                          "1 min" + dot + "Transcript only",
                          "Recording", "Writing notes...", "Couldn't finish the notes"]
        check(rd == rdExpected, "T4 rowDetail", "\(rd)")

        let t5 = [NotesLogic.displayTitle(meta("x", now, title: "  ")), NotesLogic.displayTitle(meta("x", now, title: " Sync "))]
        check(t5 == ["Untitled meeting", "Sync"], "T5 displayTitle", "\(t5)")

        // MARK: Dates

        func label(_ s: String) -> String { NotesLogic.dateLabel(d(s), now: now, calendar: cal) }
        func group(_ s: String) -> String { NotesLogic.groupTitle(d(s), now: now, calendar: cal) }
        check(label("2026-11-23 14:00") == "Today, 2:00 PM" && group("2026-11-23 14:00") == "This week",
              "D1 today", label("2026-11-23 14:00"))
        check(label("2026-11-22 16:30") == "Yesterday, 4:30 PM", "D2 yesterday", label("2026-11-22 16:30"))
        check(label("2026-11-21 11:05") == "Saturday, 11:05 AM", "D3 weekday name", label("2026-11-21 11:05"))
        check(label("2026-11-17 09:00") == "Tuesday, 9:00 AM" && group("2026-11-17 09:00") == "This week",
              "D4 six days ago is still this week", label("2026-11-17 09:00"))
        check(label("2026-11-16 09:00") == "November 16, 9:00 AM" && group("2026-11-16 09:00") == "November 2026",
              "D5 seven days ago uses the date", label("2026-11-16 09:00") + " / " + group("2026-11-16 09:00"))
        check(label("2025-12-30 08:15") == "December 30, 2025, 8:15 AM" && group("2025-12-30 08:15") == "December 2025",
              "D6 another year shows the year", label("2025-12-30 08:15") + " / " + group("2025-12-30 08:15"))
        check(label("2026-11-23 00:00") == "Today, 12:00 AM" && label("2026-11-22 23:59") == "Yesterday, 11:59 PM",
              "D7 midnight boundaries", label("2026-11-23 00:00") + " / " + label("2026-11-22 23:59"))

        let g1 = meta("20261123-140000-aaaa", d("2026-11-23 14:00"))
        let g3 = meta("20261121-110500-bbbb", d("2026-11-21 11:05"))
        let g5 = meta("20261116-090000-cccc", d("2026-11-16 09:00"))
        let g6 = meta("20251230-081500-dddd", d("2025-12-30 08:15"))
        let groups = NotesLogic.grouped([g5, g1, g6, g3], now: now, calendar: cal)
        check(groups.map { $0.title } == ["This week", "November 2026", "December 2025"]
              && groups[0].notes.map { $0.id } == [g1.id, g3.id],
              "D8 grouped", "\(groups.map { $0.title }) \(groups.first?.notes.map { $0.id } ?? [])")

        // MARK: Copy

        let cMeta = meta("20261123-140000-aaaa", d("2026-11-23 14:00"), title: "Launch planning", duration: 2520,
                         speakers: [NoteSpeaker(key: "you", name: nil), NoteSpeaker(key: "s1", name: "Maya"), NoteSpeaker(key: "s2", name: nil)])
        let cTurns = Transcript(turns: [TranscriptTurn(speaker: "you", start: 4, end: 6, text: "Okay."),
                                        TranscriptTurn(speaker: "s1", start: 19, end: 22, text: "That works."),
                                        TranscriptTurn(speaker: "s2", start: 36, end: 40, text: "Lead with privacy.")])
        let c1 = NotesLogic.copyText(meta: cMeta, transcript: cTurns, calendar: cal)
        let c1Expected = "Launch planning\nNovember 23, 2026, 2:00 PM \u{00B7} 42 min\nSpeakers: You, Maya, Speaker 2\n\n[0:04] You: Okay.\n\n[0:19] Maya: That works.\n\n[0:36] Speaker 2: Lead with privacy.\n"
        check(c1 == c1Expected, "C1 copy text with speakers and turns", c1)

        let c2 = NotesLogic.copyText(meta: meta("x", d("2026-11-23 14:00"), title: "", duration: 0, speakers: []),
                                     transcript: Transcript(turns: []), calendar: cal)
        check(c2 == "Untitled meeting\nNovember 23, 2026, 2:00 PM \u{00B7} 1 min\n", "C2 copy text with nothing in it", c2)

        // MARK: Writing

        let tail = " You can keep using your Mac."
        let w1: [(Double?, String)] = [(nil, "Working out how long this will take." + tail),
                                       (0, "Less than a minute left." + tail), (45, "Less than a minute left." + tail),
                                       (46, "About a minute left." + tail), (60, "About a minute left." + tail),
                                       (61, "About 2 minutes left." + tail), (125, "About 3 minutes left." + tail)]
        let w1Got = w1.map { NotesLogic.estimateText($0.0) }
        check(w1Got == w1.map { $0.1 }, "W1 estimateText", "\(w1Got)")

        let w2 = [NotesLogic.overallProgress(WritingProgress(step: .transcribing, fraction: 0.8, secondsLeft: nil)),
                  NotesLogic.overallProgress(WritingProgress(step: .saving, fraction: 0, secondsLeft: nil)),
                  NotesLogic.overallProgress(WritingProgress(step: .finishing, fraction: 1, secondsLeft: nil)),
                  NotesLogic.overallProgress(WritingProgress(step: .speakers, fraction: 2, secondsLeft: nil))]
        let w2Expected = [0.45, 0, 1, 0.75]
        check(zip(w2, w2Expected).allSatisfy { abs($0 - $1) < 1e-9 }, "W2 overallProgress", "\(w2)")

        let w3 = [NotesLogic.stepLabel(.saving, duration: 2520, done: true, summaryProvider: nil),
                  NotesLogic.stepLabel(.saving, duration: 2520, done: false, summaryProvider: nil),
                  NotesLogic.stepLabel(.finishing, duration: 0, done: false, summaryProvider: "Anthropic"),
                  NotesLogic.stepLabel(.finishing, duration: 0, done: false, summaryProvider: nil)]
        check(w3 == ["Saved 42 minutes of audio", "Saving the audio",
                     "Writing the summary with your Anthropic key, then deleting the audio",
                     "Saving the transcript and deleting the audio"], "W3 stepLabel", "\(w3)")

        check(!NotesKeys.inUse() && NotesKeys.provider() == nil, "W4 no key is in use yet")

        // MARK: Availability

        func v(_ major: Int, _ minor: Int) -> OperatingSystemVersion {
            OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: 0)
        }
        let v1 = [NotesLogic.supportsRecording(v(13, 6)), NotesLogic.supportsRecording(v(14, 1)),
                  NotesLogic.supportsRecording(v(14, 2)), NotesLogic.supportsRecording(v(15, 0)),
                  NotesLogic.supportsRecording(v(27, 2))]
        check(v1 == [false, false, true, true, true], "V1 supportsRecording", "\(v1)")

        let v2 = NotesLogic.unsupportedMessage(v(13, 6))
        check(v2.contains("macOS 13.6") && v2.contains("14.2"), "V2 unsupportedMessage names both versions")

        // MARK: Store

        let rootURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("talkflow-notestest-\(UUID().uuidString)")
        let store = NoteStore(root: rootURL)
        let fm = FileManager.default
        let tmpPrefix = URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.path
        check(rootURL.standardizedFileURL.path.hasPrefix(tmpPrefix), "S0 the store root is in the temporary folder", rootURL.path)

        do {
            let m = try store.create(title: "", started: d("2026-11-23 14:00"))
            check(fm.fileExists(atPath: store.folder(for: m.id).path)
                  && fm.fileExists(atPath: store.audioFolder(for: m.id).path)
                  && fm.fileExists(atPath: store.folder(for: m.id).appendingPathComponent("note.json").path)
                  && m.state == .recording && m.duration == 0 && m.speakers.isEmpty && NoteStore.isValidID(m.id),
                  "S1 create makes the folders and note.json")

            let m2 = try store.create(title: "", started: d("2026-11-23 14:00"))
            check(m2.id != m.id, "S2 two creates in the same second get different ids")

            // S3 round trip over every state.
            var rt = m
            rt.title = "Launch planning"
            rt.duration = 2520.5
            rt.speakers = [NoteSpeaker(key: "you", name: nil), NoteSpeaker(key: "s1", name: "Maya")]
            rt.actionItemCount = 4
            let states: [NoteState] = [.recording, .writing(.saving), .writing(.transcribing), .writing(.speakers),
                                       .writing(.finishing), .ready,
                                       .failed(NoteFailure(step: .transcribing, message: "The speech engine stopped.", retry: .notes))]
            var roundTrips = true
            for state in states {
                rt.state = state
                try store.save(rt)
                if store.meta(rt.id) != rt { roundTrips = false }
            }
            check(roundTrips, "S3 every state round-trips through note.json")

            let cut = try store.create(title: "", started: Date(timeIntervalSince1970: 1_795_000_000.7))
            check(cut.started.timeIntervalSince1970 == 1_795_000_000 && store.meta(cut.id)?.started == cut.started,
                  "S4 started is cut to whole seconds and round-trips", "\(cut.started.timeIntervalSince1970)")

            // S5 a newer schema is left alone.
            let noteFile = store.folder(for: m.id).appendingPathComponent("note.json")
            let text = (try? String(contentsOf: noteFile, encoding: .utf8)) ?? ""
            check(text.contains("\"schemaVersion\" : 1"), "S5 note.json carries its schemaVersion")
            let bumped = text.replacingOccurrences(of: "\"schemaVersion\" : 1", with: "\"schemaVersion\" : 99")
            try bumped.write(to: noteFile, atomically: true, encoding: .utf8)
            let before = try Data(contentsOf: noteFile)
            let listed = store.list()
            let after = try Data(contentsOf: noteFile)
            check(store.meta(m.id) == nil && !listed.contains { $0.id == m.id } && before == after,
                  "S5 a newer file is skipped and not rewritten")

            // S6 transcript, summary, questions.
            let s6 = try store.create(title: "s6", started: d("2026-11-23 09:00"))
            check(store.summary(s6.id) == nil && store.questions(s6.id) == nil && store.transcript(s6.id) == nil,
                  "S6 absent files read as nil")
            let tr = NotesLogic.transcript(from: [p("you", 0, 1, "Hello"), p("A", 2, 3, "Hi")])
            let sum = NoteSummary(summary: "A short talk.",
                                  actionItems: [NoteSummary.ActionItem(owner: "s1", task: "Send notes", time: 12.5, done: false)],
                                  decisions: ["Ship"], openQuestions: ["When?"], provider: "Anthropic", model: "test",
                                  written: d("2026-11-23 10:00"))
            let qs = NoteQuestions(entries: [NoteQuestions.Entry(question: "Q", answer: "A", citations: [1.5],
                                                                 asked: d("2026-11-23 10:05"), provider: "Anthropic", model: "test")])
            try store.save(tr, for: s6.id)
            try store.save(sum, for: s6.id)
            try store.save(qs, for: s6.id)
            check(store.transcript(s6.id) == tr && store.summary(s6.id) == sum && store.questions(s6.id) == qs,
                  "S6 transcript, summary and questions round-trip")

            // S7 no stray files after repeated saves.
            let s7 = try store.create(title: "s7", started: d("2026-11-23 08:00"))
            for _ in 0..<5 { try store.save(s7) }
            try store.save(tr, for: s7.id)
            let names = Set(((try? fm.contentsOfDirectory(atPath: store.folder(for: s7.id).path)) ?? []).filter { !$0.hasPrefix(".") })
            check(names == ["audio", "note.json", "transcript.json"], "S7 saves leave no stray files", "\(names.sorted())")

            // S8 a corrupt file is skipped, not touched.
            let s8 = try store.create(title: "s8", started: d("2026-11-23 07:00"))
            let s8File = store.folder(for: s8.id).appendingPathComponent("note.json")
            try Data("{not json".utf8).write(to: s8File)
            let listed8 = store.list()
            check(store.meta(s8.id) == nil && !listed8.contains { $0.id == s8.id }
                  && (try? Data(contentsOf: s8File)) == Data("{not json".utf8),
                  "S8 a corrupt note is skipped and left as it was")

            // S9 delete.
            let s9 = try store.create(title: "s9", started: d("2026-11-23 06:00"))
            try store.delete(s9.id)
            var lateSaveThrew = false
            do { try store.save(s9) } catch { lateSaveThrew = true }
            check(!fm.fileExists(atPath: store.folder(for: s9.id).path) && !store.list().contains { $0.id == s9.id }
                  && lateSaveThrew,
                  "S9 delete removes the note and a late save cannot bring it back")

            // S10 delete refuses anything that is not a note id.
            var allThrew = true
            for bad in ["", "../x", "a/b", ".", "20261123-140000-zzzz"] {
                do { try store.delete(bad); allThrew = false } catch {}
            }
            check(allThrew && fm.fileExists(atPath: rootURL.path), "S10 delete refuses ids that are not notes")

            // S11 audio.
            let s11 = try store.create(title: "s11", started: d("2026-11-23 05:00"))
            try Data([1, 2, 3]).write(to: store.audioFolder(for: s11.id).appendingPathComponent("you.wav"))
            let hadAudio = store.hasAudio(s11.id)
            let removed = store.deleteAudio(s11.id)
            let hasAfter = store.hasAudio(s11.id)
            let folderGone = !fm.fileExists(atPath: store.audioFolder(for: s11.id).path)
            let again = store.deleteAudio(s11.id)
            check(hadAudio && removed && !hasAfter && folderGone && again, "S11 audio is detected and verified gone")
            try fm.createDirectory(at: store.audioFolder(for: s11.id), withIntermediateDirectories: true)
            try Data().write(to: store.audioFolder(for: s11.id).appendingPathComponent(".DS_Store"))
            check(!store.hasAudio(s11.id), "S11 a folder with only .DS_Store has no audio")

            // S12 leftovers, in a store of their own.
            let root12 = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("talkflow-notestest-\(UUID().uuidString)")
            let store12 = NoteStore(root: root12)
            var rec = try store12.create(title: "rec", started: d("2026-11-23 10:00"))
            var writing = try store12.create(title: "writing", started: d("2026-11-23 11:00"))
            var ready = try store12.create(title: "ready", started: d("2026-11-23 12:00"))
            var failed = try store12.create(title: "failed", started: d("2026-11-23 13:00"))
            rec.state = .recording
            writing.state = .writing(.speakers)
            ready.state = .ready
            failed.state = .failed(NoteFailure(step: .transcribing, message: "m", retry: .notes))
            for m in [rec, writing, ready, failed] { try store12.save(m) }
            let l1 = Set(store12.leftovers(active: nil).map { $0.id })
            let l2 = Set(store12.leftovers(active: rec.id).map { $0.id })
            check(l1 == [rec.id, writing.id] && l2 == [writing.id], "S12 leftovers are the unfinished notes without a session")
            try? fm.removeItem(at: root12)

            // S13 newest first.
            let root13 = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("talkflow-notestest-\(UUID().uuidString)")
            let store13 = NoteStore(root: root13)
            let t10 = try store13.create(title: "10", started: d("2026-11-23 10:00"))
            let t12 = try store13.create(title: "12", started: d("2026-11-23 12:00"))
            let t11 = try store13.create(title: "11", started: d("2026-11-23 11:00"))
            check(store13.list().map { $0.id } == [t12.id, t11.id, t10.id], "S13 list is newest first")
            try? fm.removeItem(at: root13)
        } catch {
            // Only the error type: nothing from a note ever goes in a log.
            check(false, "S store steps ran without an unexpected error", "\(type(of: error))")
        }

        try? fm.removeItem(at: rootURL)
        check(!fm.fileExists(atPath: rootURL.path), "S14 cleanup leaves no folder behind")

        report(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
        exit(failures == 0 ? 0 : 1)
    }

    private static func check(_ condition: Bool, _ label: String, _ detail: String = "") {
        report((condition ? "ok   " : "FAIL ") + label + (condition || detail.isEmpty ? "" : " -> " + detail))
        if !condition { failures += 1 }
    }

    private static let logURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("talkflow-notestest.log")

    /// stdout goes to the app log; also written next to the other self-test
    /// results so the caller can read it directly.
    private static func report(_ line: String) {
        print("talkflowd: [notestest] \(line)")
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
