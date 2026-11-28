import Foundation

/// Part of `--notestest` (called from NotesSelfTest). Document-style notes: the auto title and description, the
/// auto speaker names and their evidence rules, the old-note compatibility mapping, the Copy text and the two
/// flows that use them (NoteAssistant, NotesModel). Made-up content and canned replies only: no network, no
/// Keychain, no real settings, and every note lives in a temp folder that is removed at the end of each case.
enum NotesDocChecks {
    typealias Suggestion = NotesAI.NameSuggestion

    // MARK: Fixtures (made up)

    private static func turn(_ speaker: String, _ start: Double, _ end: Double, _ text: String) -> TranscriptTurn {
        TranscriptTurn(speaker: speaker, start: start, end: end, text: text)
    }

    private static let turns: [TranscriptTurn] = [
        turn("you", 0, 5, "Okay everyone, let's start. Priya, can you give us the budget update?"),
        turn("s1", 6, 13, "Sure. We are about ten percent under for the quarter."),
        turn("s2", 14, 21, "Thanks Priya. This is Marcus, I can cover hiring."),
        turn("s3", 22, 29, "Before that, one question about travel."),
        turn("you", 30, 33, "Go ahead."),
    ]

    private static let defaultSpeakers: [NoteSpeaker] = [
        NoteSpeaker(key: "you"), NoteSpeaker(key: "s1"), NoteSpeaker(key: "s2"), NoteSpeaker(key: "s3"),
    ]

    private static let fixedNow = Date(timeIntervalSince1970: 1_792_000_000)

    private static func suggestion(_ label: String, _ name: String, _ kind: String, _ evidence: String, _ time: Double,
                                   _ confidence: String) -> Suggestion {
        Suggestion(label: label, name: name, kind: kind, evidence: evidence, time: time, confidence: confidence)
    }

    private static let priyaQuote = "Priya, can you give us the budget update"

    private static var goodSuggestions: [Suggestion] {
        [suggestion("Speaker 1", "Priya", "addressed", priyaQuote, 0, "high"),
         suggestion("Speaker 2", "Marcus", "introduced", "This is Marcus", 14, "high")]
    }

    private static func meta(_ title: String, _ source: TitleSource?) -> NoteMeta {
        NoteMeta(id: "20261123-140000-abcd", title: title, started: fixedNow, duration: 60, speakers: [],
                 state: .ready, actionItemCount: nil, titleSource: source, subtitle: nil)
    }

    private static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private static func suggestionObjects(_ list: [Suggestion]) -> [[String: Any]] {
        list.map { s -> [String: Any] in
            ["label": s.label, "name": s.name, "kind": s.kind, "evidence": s.evidence, "time": Int(s.time),
             "confidence": s.confidence]
        }
    }

    /// A reply in the new schema over the five fixture turns. `detailTime` lets a case move one time.
    private static func newReply(title: String = "\"Budget and hiring update.\"",
                                 description: String = "Budget is under and hiring starts next month so the team plans ahead",
                                 owner: String = "You", detailTime: Int = 15,
                                 names: [Suggestion] = []) -> String {
        let decisions: [[String: Any]] = [
            ["text": "Travel policy", "status": "needs_discussion", "time": 22],
            ["text": "Hire two engineers", "status": "maybe", "time": 6],
        ]
        let details: [[String: Any]] = [
            ["topic": "Budget", "text": "About ten percent under.", "times": [detailTime, 6]],
            ["topic": "Hiring", "text": "Marcus covers hiring.", "times": [14]],
        ]
        let actions: [[String: Any]] = [["owner": owner, "task": "Send the budget sheet", "time": 6]]
        let raw: [String: Any] = [
            "title": title, "description": description, "summary": "We are under budget.",
            "summary_times": [6], "decisions": decisions, "details": details, "action_items": actions,
            "speakers": suggestionObjects(names),
        ]
        return json(raw)
    }

    private static func validate(_ text: String, speakers: [NoteSpeaker]? = nil) -> Result<NoteSummary, NotesAIError> {
        NotesAI.validateSummary(text, turns: turns, speakers: speakers ?? defaultSpeakers, provider: .anthropic,
                                model: .claudeHaiku, written: fixedNow, parts: 1)
    }

    private static func accepted(_ list: [Suggestion], speakers: [NoteSpeaker]? = nil) -> [String: String] {
        NotesAI.acceptedNames(list, turns: turns, speakers: speakers ?? defaultSpeakers)
    }

    private static func describe(_ value: Any) -> String { "\(value)" }

    private static func words(_ s: String?) -> Int { (s ?? "").split(separator: " ").count }

    private static func spin(_ seconds: Double, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    private static func spinFor(_ seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    private static let on: () -> NotesAccess? = {
        NotesAccess.resolve(hasAnthropic: { true }, hasOpenAI: { false }, anthropicModel: nil, openAIModel: nil)
    }
    private static let off: () -> NotesAccess? = {
        NotesAccess.resolve(hasAnthropic: { false }, hasOpenAI: { false }, anthropicModel: nil, openAIModel: nil)
    }

    private static func tempRoot(_ name: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("talkflow-notestest-\(name)-\(UUID().uuidString)")
    }

    // MARK: Checks

    static func run(_ check: (Bool, String, String) -> Void) {
        runRules(check)
        runCompat(check)
        runNames(check)
        runReplies(check)
        runCopy(check)
        runFlows(check)
        runNameFix(check)
        runLocalPass(check)
    }

    private static func runRules(_ check: (Bool, String, String) -> Void) {
        // DOC1 titleSource
        let t1 = [NotesDoc.titleSource(meta("", nil)), NotesDoc.titleSource(meta("Untitled meeting", nil)),
                  NotesDoc.titleSource(meta("Sync", nil)), NotesDoc.titleSource(meta("Sync", .auto))]
        check(t1 == [.placeholder, .placeholder, .user, .auto], "DOC1 titleSource reads old notes", describe(t1))

        // DOC2 nameSource
        let n2 = [NotesDoc.nameSource(NoteSpeaker(key: "s1", name: nil, nameSource: nil)),
                  NotesDoc.nameSource(NoteSpeaker(key: "s1", name: "Maya", nameSource: nil)),
                  NotesDoc.nameSource(NoteSpeaker(key: "s1", name: "Lee", nameSource: .auto)),
                  NotesDoc.nameSource(NoteSpeaker(key: "s1", name: nil, nameSource: .user))]
        check(n2 == [.default, .user, .auto, .user], "DOC2 nameSource reads old speakers", describe(n2))

        // DOC3 applyingAuto
        let a3 = NotesDoc.applyingAuto(title: "Launch plan", subtitle: nil, to: meta("", .placeholder))
        let b3 = NotesDoc.applyingAuto(title: "X y z", subtitle: "S", to: meta("Board sync", .user))
        let c3 = NotesDoc.applyingAuto(title: "New one", subtitle: nil, to: meta("Old", .auto))
        let d3 = NotesDoc.applyingAuto(title: nil, subtitle: nil, to: meta("Old", .auto))
        check(a3.title == "Launch plan" && a3.titleSource == .auto
              && b3.title == "Board sync" && b3.titleSource == .user && b3.subtitle == "S"
              && c3.title == "New one" && c3.titleSource == .auto
              && d3.title == "Old" && d3.titleSource == .auto,
              "DOC3 applyingAuto never replaces a typed title",
              "\(a3.title)/\(describe(a3.titleSource as Any)) \(b3.title)/\(describe(b3.titleSource as Any)) \(c3.title) \(d3.title)")

        // DOC7 retitled
        let r7a = NotesDoc.retitled(meta("Old", .auto), to: "  New title  ")
        let r7b = NotesDoc.retitled(meta("Old", .user), to: "")
        let r7c = NotesDoc.retitled(meta("Old", .user), to: String(repeating: "x", count: 100))
        check(r7a.title == "New title" && r7a.titleSource == .user
              && r7b.title == "" && r7b.titleSource == .placeholder && r7c.title.count == NotesDoc.maxTitleLength,
              "DOC7 retitled", "\(r7a.title)/\(describe(r7a.titleSource as Any)) \(r7b.title)/\(describe(r7b.titleSource as Any)) \(r7c.title.count)")

        // DOC8 cleanTitle
        let c8: [String?] = [
            NotesDoc.cleanTitle("\"Q3 hiring plan.\""), NotesDoc.cleanTitle("Meeting"), NotesDoc.cleanTitle("meeting notes"),
            NotesDoc.cleanTitle("one two three four five six seven eight"), NotesDoc.cleanTitle("launch review"),
            NotesDoc.cleanTitle("  Budget   review\n"), NotesDoc.cleanTitle("Why ship now?"),
        ]
        let e8: [String?] = ["Q3 hiring plan", nil, nil, nil, "Launch review", "Budget review", "Why ship now?"]
        check(c8 == e8, "DOC8 cleanTitle", describe(c8))

        // DOC9 cleanDescription
        let tenWords = "One two three four five six seven eight nine ten"
        let c9: [String?] = [
            NotesDoc.cleanDescription("Agreed on the launch order and the plan for the post and screenshots"),
            NotesDoc.cleanDescription(tenWords), NotesDoc.cleanDescription("planned the launch."),
            NotesDoc.cleanDescription("   "),
        ]
        let e9: [String?] = ["Agreed on the launch order and the plan", tenWords, "Planned the launch", nil]
        check(c9 == e9, "DOC9 cleanDescription", describe(c9))

        // DOC10 defaultTab (hasTranscript, hasSummary, keyInUse)
        let d10 = [NotesDoc.defaultTab(hasTranscript: true, hasSummary: true, keyInUse: true),
                   NotesDoc.defaultTab(hasTranscript: true, hasSummary: true, keyInUse: false),
                   NotesDoc.defaultTab(hasTranscript: true, hasSummary: false, keyInUse: true),
                   NotesDoc.defaultTab(hasTranscript: true, hasSummary: false, keyInUse: false),
                   NotesDoc.defaultTab(hasTranscript: false, hasSummary: false, keyInUse: true),
                   NotesDoc.defaultTab(hasTranscript: false, hasSummary: true, keyInUse: false)]
        check(d10 == [.summary, .summary, .summary, .transcript, .transcript, .summary],
              "DOC10 defaultTab", describe(d10))

        // DOC11 decisions of an old summary
        let a11 = NoteSummary.Point(text: "Ship", time: 4)
        let q11 = NoteSummary.Point(text: "When?", time: 19)
        let old11 = NoteSummary(summary: "S", summaryTimes: [], actionItems: [], decisions: [a11], openQuestions: [q11],
                                provider: "Anthropic", model: "m", written: fixedNow, parts: 1)
        let got11 = NotesDoc.decisions(old11)
        let want11 = [a11, NoteSummary.Point(text: "When?", time: 19, status: "needs_discussion")]
        check(got11 == want11 && DecisionStatus.of(got11.first?.status) == .aligned, "DOC11 decisions of an old summary",
              describe(got11))
    }

    private static func runCompat(_ check: (Bool, String, String) -> Void) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // DOC4 a note.json from before auto titles and names
        let legacy = """
        {"schemaVersion":1,"id":"20261123-140000-abcd","title":"Weekly sync","started":"2026-11-23T14:00:00Z",
         "duration":60,"speakers":[{"key":"s1","name":"Maya"},{"key":"s2"}],"state":{"phase":"ready"}}
        """
        if let m = try? decoder.decode(NoteMeta.self, from: Data(legacy.utf8)) {
            let kept = NotesDoc.applyingAuto(title: "Something else", subtitle: nil, to: m)
            let s1 = m.speakers.first { $0.key == "s1" }
            let s2 = m.speakers.first { $0.key == "s2" }
            check(kept.title == "Weekly sync" && s1.map(NotesDoc.nameSource) == .user
                  && s2.map(NotesDoc.nameSource) == .default && m.titleSource == nil && m.subtitle == nil,
                  "DOC4 an old note.json decodes and keeps its title", "\(kept.title)")
        } else {
            check(false, "DOC4 an old note.json decodes and keeps its title", "decode failed")
        }

        // DOC12 a summary.json from before document-style notes, read by the store's own decoder
        let root = tempRoot("doc12")
        let store = NoteStore(root: root)
        var verdict = "no note"
        if let note = try? store.create(title: "old", started: fixedNow) {
            let old = """
            {"schemaVersion":1,"summary":"We agreed.","summaryTimes":[4],
             "actionItems":[{"owner":"s1","task":"Draft","time":48,"done":true}],
             "decisions":[{"text":"Ship","time":4}],"openQuestions":[{"text":"When?","time":19}],
             "provider":"Anthropic","model":"claude-haiku-5-5","written":"2026-11-23T14:00:00Z","parts":1}
            """
            let url = store.folder(for: note.id).appendingPathComponent("summary.json")
            try? Data(old.utf8).write(to: url)
            if let s = store.summary(note.id) {
                let good = NotesDoc.details(s).isEmpty && s.title == nil && s.subtitle == nil && s.suggestedNames == nil
                    && s.decisions.first?.status == nil && NotesDoc.decisions(s).count == 2
                verdict = good ? "ok" : "unexpected fields"
            } else {
                verdict = "summary did not decode"
            }
        }
        check(verdict == "ok", "DOC12 an old summary.json decodes", verdict)
        try? FileManager.default.removeItem(at: root)
    }

    private static func runNames(_ check: (Bool, String, String) -> Void) {
        // DOC5 applyingSuggestedNames
        let long = String(repeating: "a", count: 41)
        let sp5 = [NoteSpeaker(key: "you"), NoteSpeaker(key: "s1"),
                   NoteSpeaker(key: "s2", name: "Bob", nameSource: .user),
                   NoteSpeaker(key: "s3", name: "Lee", nameSource: .auto),
                   NoteSpeaker(key: "s4"), NoteSpeaker(key: "s5")]
        let names5 = ["you": "Me", "s1": "Maya", "s2": "Rob", "s3": "Lena", "s4": "bob", "s5": long]
        let out5 = NotesDoc.applyingSuggestedNames(names5, to: sp5)
        func by(_ key: String) -> NoteSpeaker? { out5.first { $0.key == key } }
        check(by("you") == sp5[0] && by("s1")?.name == "Maya" && by("s1")?.nameSource == .auto
              && by("s2")?.name == "Bob" && by("s2")?.nameSource == .user
              && by("s3")?.name == "Lee" && by("s3")?.nameSource == .auto
              && by("s4") == sp5[4] && by("s5") == sp5[5],
              "DOC5 applyingSuggestedNames", describe(out5))

        // DOC6 renaming and clearing
        let sp6 = [NoteSpeaker(key: "you"), NoteSpeaker(key: "s1", name: "Maya", nameSource: .auto), NoteSpeaker(key: "s2")]
        let renamed = NotesLogic.renaming("s1", to: "Mia", in: sp6)
        let same = NotesLogic.renaming("s2", to: "", in: sp6)
        let cleared = NotesDoc.clearingName("s1", in: sp6)
        let again = NotesDoc.applyingSuggestedNames(["s1": "Maya"], to: cleared)
        let youSame = NotesDoc.clearingName("you", in: sp6)
        check(renamed[1].name == "Mia" && renamed[1].nameSource == .user && same == sp6
              && cleared[1].name == nil && cleared[1].nameSource == .user
              && NotesLogic.displayName("s1", in: cleared) == "Speaker 1"
              && again[1].name == nil && youSame == sp6,
              "DOC6 renaming and clearing a suggested name", "\(describe(renamed[1])) \(describe(cleared[1]))")

        // DOC16 acceptedNames, the good case
        let got16 = accepted(goodSuggestions)
        check(got16 == ["s1": "Priya", "s2": "Marcus"], "DOC16 acceptedNames takes direct, quoted names", describe(got16))

        // DOC17 / DOC18
        let g17 = accepted([suggestion("Speaker 1", "Priya", "addressed", "Priya, please start us off", 0, "high")])
        check(g17.isEmpty, "DOC17 a quote that is not in the transcript is refused", describe(g17))
        let g18 = accepted([suggestion("Speaker 1", "Priya", "addressed", "can you give us the budget update", 0, "high")])
        check(g18.isEmpty, "DOC18 a name that is not in its quote is refused", describe(g18))

        // DOC19 the same name on two speakers
        let g19 = accepted([suggestion("Speaker 1", "Priya", "addressed", priyaQuote, 0, "high"),
                            suggestion("Speaker 3", "Priya", "addressed", "Thanks Priya", 14, "high")])
        check(g19.isEmpty, "DOC19 one name on two speakers is refused for both", describe(g19))

        // DOC20 over 40 characters
        let longName = "Priya Venkataraman-Subramanian Krishnamurthy"
        let g20 = accepted([suggestion("Speaker 1", longName, "addressed", longName, 0, "high")])
        check(longName.count == 44 && g20.isEmpty, "DOC20 a name over 40 characters is refused", describe(g20))

        // DOC21 low confidence
        let g21 = accepted([suggestion("Speaker 1", "Priya", "addressed", priyaQuote, 0, "low")])
        check(g21.isEmpty, "DOC21 low confidence is refused", describe(g21))

        // DOC22 "You" as a name or a label
        let g22a = accepted([suggestion("Speaker 1", "You", "addressed", "You can start", 0, "high")])
        let g22b = accepted([suggestion("You", "Priya", "addressed", priyaQuote, 0, "high")])
        check(g22a.isEmpty && g22b.isEmpty, "DOC22 You is never named or renamed", "\(describe(g22a)) \(describe(g22b))")

        // DOC23 a speaker the user renamed
        let renamedSpeakers = [NoteSpeaker(key: "you"), NoteSpeaker(key: "s1", name: "Pri", nameSource: .user),
                               NoteSpeaker(key: "s2"), NoteSpeaker(key: "s3")]
        let g23a = accepted([suggestion("Speaker 1", "Priya", "addressed", priyaQuote, 0, "high")], speakers: renamedSpeakers)
        let g23b = accepted([suggestion("Pri", "Priya", "addressed", priyaQuote, 0, "high")], speakers: renamedSpeakers)
        check(g23a.isEmpty && g23b.isEmpty, "DOC23 a name the user typed is never replaced",
              "\(describe(g23a)) \(describe(g23b))")

        // DOC24 a quote that is not there, at a time that matches no turn; a wrong time with a real quote still works
        let far = [suggestion("Speaker 1", "Priya", "addressed", "Priya, please start us off", 9999, "high")]
        let g24 = accepted(far)
        let late = accepted([suggestion("Speaker 1", "Priya", "addressed", priyaQuote, 9999, "high")])
        var v24 = "not a success"
        if case .success(let s) = validate(newReply(names: far)) {
            v24 = (s.suggestedNames ?? [:]) == NotesAI.localNames(turns: turns, speakers: defaultSpeakers) ? "ok" : "names kept"
        }
        check(g24.isEmpty && v24 == "ok" && late == ["s1": "Priya"],
              "DOC24 a name without its quote is dropped and the reply still succeeds", "\(v24) \(describe(late))")

        // DOC25 mergedNames
        let m25a = NotesAI.mergedNames([["s1": "Priya"], ["s1": "Priya", "s2": "Marcus"]])
        let m25b = NotesAI.mergedNames([["s1": "Priya"], ["s1": "Pia"]])
        let m25c = NotesAI.mergedNames([["s1": "Priya"], ["s2": "priya"]])
        check(m25a == ["s1": "Priya", "s2": "Marcus"] && m25b.isEmpty && m25c.isEmpty, "DOC25 mergedNames",
              "\(describe(m25a)) \(describe(m25b)) \(describe(m25c))")

        // DOC26 an owner written as an accepted name follows that speaker
        var v26 = "not a success"
        if case .success(let s) = validate(newReply(owner: "Priya", names: goodSuggestions)) {
            v26 = s.actionItems.first?.owner ?? "none"
        }
        check(v26 == "s1", "DOC26 an owner named like an accepted name becomes that speaker", v26)
    }

    private static func runReplies(_ check: (Bool, String, String) -> Void) {
        // DOC13 a new-format reply
        let v13 = validate(newReply())
        if case .success(let s) = v13 {
            let statuses = s.decisions.map { $0.status ?? "nil" }
            let detailTimes = (s.details ?? []).map { $0.times }
            check(s.title == "Budget and hiring update" && words(s.subtitle) <= 10 && s.subtitle != nil
                  && detailTimes == [[14, 6], [14]] && statuses == ["needs_discussion", "aligned"]
                  && (s.suggestedNames ?? [:]) == NotesAI.localNames(turns: turns, speakers: defaultSpeakers)
                  && s.openQuestions.isEmpty && (s.details ?? []).count == 2,
                  "DOC13 a new-format reply is validated and cleaned",
                  "title \(s.title ?? "nil") sub \(s.subtitle ?? "nil") details \(detailTimes) statuses \(statuses)")
        } else {
            check(false, "DOC13 a new-format reply is validated and cleaned", describe(v13))
        }

        // DOC14 a detail time that points at no turn
        let v14 = validate(newReply(detailTime: 9999))
        var e14 = "not a failure"
        if case .failure(let e) = v14 { e14 = describe(e) }
        check(e14 == describe(NotesAIError.badTimes(1)), "DOC14 a detail time at no turn refuses the reply", e14)

        // DOC15 turnIndex
        let i15a = NotesAI.turnIndex(for: 9999, in: turns)
        let i15b = NotesAI.turnIndex(for: turns[2].start, in: turns)
        check(i15a == nil && i15b == 2, "DOC15 turnIndex", "\(describe(i15a as Any)) \(describe(i15b as Any))")

        // DOC28 the schema
        let all = ["decisions", "description", "details", "next_steps", "summary", "summary_times", "title"]
        let with = NotesAI.summarySchema(speakers: true)
        let without = NotesAI.summarySchema(speakers: false)
        let reqWith = with["required"] as? [String] ?? []
        let reqWithout = without["required"] as? [String] ?? []
        let propsWithout = (without["properties"] as? [String: Any]) ?? [:]
        check(reqWith == ["attendees"] + all && reqWithout == all && propsWithout["attendees"] == nil
              && propsWithout["open_questions"] == nil,
              "DOC28 summarySchema required lists", "\(reqWith) \(reqWithout)")

        let access = on()
        if let access = access {
            let lines = NotesAI.transcriptLines(turns, speakers: defaultSpeakers)
            let sReq = NotesAI.summaryRequest(access, key: "k", lines: lines, part: 1, of: 1)
            let part = NotesAISamples.summary(now: fixedNow)
            let cReq = NotesAI.combineRequest(access, key: "k", parts: [part], speakers: defaultSpeakers)
            func props(_ r: URLRequest) -> [String: Any] {
                guard let body = r.httpBody,
                      let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
                      let out = obj["output_config"] as? [String: Any], let format = out["format"] as? [String: Any],
                      let schema = format["schema"] as? [String: Any] else { return [:] }
                return (schema["properties"] as? [String: Any]) ?? [:]
            }
            let sProps = props(sReq)
            let cProps = props(cReq)
            check(sProps["attendees"] != nil && !cProps.isEmpty && cProps["attendees"] == nil,
                  "DOC28 the summary request asks for names, the combine request does not",
                  "summary \(sProps.keys.sorted()) combine \(cProps.keys.sorted())")
        } else {
            check(false, "DOC28 the summary request asks for names, the combine request does not", "no access")
        }
    }

    private static func runCopy(_ check: (Bool, String, String) -> Void) {
        // DOC27 the Markdown copy, exactly
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .current
        let started = utc.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 14, minute: 0)) ?? fixedNow
        let speakers = [NoteSpeaker(key: "you"), NoteSpeaker(key: "s1", name: "Priya", nameSource: .auto),
                        NoteSpeaker(key: "s2")]
        let m = NoteMeta(id: "20261123-140000-abcd", title: "Budget review", started: started, duration: 2520,
                         speakers: speakers, state: .ready)
        let s = NoteSummary(
            summary: "We are under budget.", summaryTimes: [6],
            actionItems: [NoteSummary.ActionItem(owner: "s1", task: "Send the budget sheet", time: 6, done: false),
                          NoteSummary.ActionItem(owner: "", task: "Book the room", time: 30, done: true)],
            decisions: [NoteSummary.Point(text: "Hire two engineers.", time: 14, status: "aligned"),
                        NoteSummary.Point(text: "Travel policy.", time: 22, status: "needs_discussion")],
            openQuestions: [], provider: "Anthropic", model: "m", written: started, parts: 1,
            details: [NoteSummary.Detail(topic: "Budget", text: "About ten percent under.", times: [6])])
        let dot = "\u{00B7}"
        let want = [
            "# Budget review",
            "November 23, 2026, 2:00 PM \(dot) 42 min",
            "Attendees: You, Priya, Speaker 2",
            "",
            "## Summary",
            "We are under budget. (0:06)",
            "",
            "## Decisions",
            "- **Aligned**: Hire two engineers. (0:14)",
            "- **Needs further discussion**: Travel policy. (0:22)",
            "",
            "## Details",
            "- **Budget**: About ten percent under. (0:06)",
            "",
            "## Suggested next steps",
            "- [ ] **Priya**: Send the budget sheet (0:06)",
            "- [x] Book the room (0:30)",
            "",
        ].joined(separator: "\n")
        let got = NotesDoc.markdown(meta: m, summary: s, calendar: utc)
        check(got == want, "DOC27 the Markdown copy", got)
    }

    // MARK: Flows

    private static func replyBody(_ text: String) -> CannedNotesTransport.Reply {
        .http(status: 200, headers: [:], body: json(["content": [["type": "text", "text": text]], "stop_reason": "end_turn"]))
    }

    private final class AssistantEnv {
        let root = NotesDocChecks.tempRoot("doc-assistant")
        let store: NoteStore
        let transport: CannedNotesTransport
        let assistant: NoteAssistant
        var saved: [String] = []

        init(replies: [CannedNotesTransport.Reply], access: @escaping () -> NotesAccess?) {
            store = NoteStore(root: root)
            transport = CannedNotesTransport(replies)
            let client = NotesAIClient(transport: transport, keyFor: { _ in "k-test" })
            client.sleep = { _, body in body() }
            client.jitter = { 0 }
            var confirmed: String? = "anthropic"
            assistant = NoteAssistant(store: store, client: client, access: access,
                                      confirmedProvider: { confirmed }, setConfirmedProvider: { confirmed = $0 })
            assistant.onSummarySaved = { [weak self] id in self?.saved.append(id) }
        }

        /// A ready note with the fixture transcript, an empty title and the four default speakers.
        func makeNote() -> String {
            guard var meta = try? store.create(title: "", started: NotesDocChecks.fixedNow) else { return "" }
            try? store.save(Transcript(turns: NotesDocChecks.turns), for: meta.id)
            meta.speakers = NotesDocChecks.defaultSpeakers
            meta.state = .ready
            try? store.save(meta)
            return meta.id
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    private static func runFlows(_ check: (Bool, String, String) -> Void) {
        // DOC29 the assistant applies a title, a description and names, and never over a typed title
        let reply = replyBody(newReply(title: "Budget and hiring update",
                                       description: "Budget is under and hiring starts next month",
                                       names: goodSuggestions))
        do {
            let e = AssistantEnv(replies: [reply, reply], access: on)
            let id = e.makeNote()
            e.assistant.transcriptSaved(id)
            spin(5) { e.saved.count == 1 }
            let m1 = e.store.meta(id)
            let s1 = m1?.speakers.first { $0.key == "s1" }
            let s2 = m1?.speakers.first { $0.key == "s2" }
            check(m1?.title == "Budget and hiring update" && m1?.titleSource == .auto
                  && m1?.subtitle == "Budget is under and hiring starts next month"
                  && s1?.name == "Priya" && s1?.nameSource == .auto && s2?.name == "Marcus" && s2?.nameSource == .auto,
                  "DOC29 a summary sets the title, description and names",
                  "\(m1?.title ?? "nil") \(describe(m1?.titleSource as Any)) \(describe(s1 as Any))")

            if var typed = m1 {
                typed = NotesDoc.retitled(typed, to: "My title")
                try? e.store.save(typed)
            }
            e.assistant.writeSummary(id)
            spin(5) { e.saved.count == 2 }
            let m2 = e.store.meta(id)
            check(e.saved.count == 2 && m2?.title == "My title" && m2?.titleSource == .user,
                  "DOC29 a second summary keeps a typed title", "\(m2?.title ?? "nil") saved \(e.saved.count)")
            e.cleanUp()
        }
        do {
            let e = AssistantEnv(replies: [reply], access: off)
            let id = e.makeNote()
            e.assistant.transcriptSaved(id)
            spinFor(0.2)
            check(e.transport.requests.isEmpty && e.store.summary(id) == nil,
                  "DOC29 with no key nothing is sent", "requests \(e.transport.requests.count)")
            e.cleanUp()
        }

        // DOC30 NotesModel: the first tab, the title editor and clearing a suggested name
        let root = tempRoot("doc-model")
        let store = NoteStore(root: root)
        let assistant = NoteAssistant(store: store, access: { nil })
        let model = NotesModel(store: store, capture: FakeCapture(), pipeline: FakePipeline(), assistant: assistant)
        func note(_ title: String, speakers: [NoteSpeaker]) -> String {
            guard var m = try? store.create(title: title, started: fixedNow) else { return "" }
            try? store.save(Transcript(turns: turns), for: m.id)
            m.speakers = speakers
            m.state = .ready
            try? store.save(m)
            return m.id
        }
        let plain = note("Weekly", speakers: defaultSpeakers)
        model.open(plain)
        let tabNoSummary = model.detailTab
        model.backToList()
        let withSummary = note("Weekly two", speakers: defaultSpeakers)
        try? store.save(NotesAISamples.summary(now: fixedNow), for: withSummary)
        model.open(withSummary)
        let tabSummary = model.detailTab
        model.backToList()
        check(tabNoSummary == .transcript && tabSummary == .summary,
              "DOC30 a meeting opens on Summary only when there is a summary",
              "\(describe(tabNoSummary)) \(describe(tabSummary))")

        model.open(plain)
        model.beginTitleEdit()
        let began = model.editingTitle
        model.titleDraft = "Renamed"
        model.commitTitle()
        let after = store.meta(plain)
        check(began && !model.editingTitle && after?.title == "Renamed" && after?.titleSource == .user,
              "DOC30 the title editor saves a typed title", "\(after?.title ?? "nil") \(describe(after?.titleSource as Any))")
        model.backToList()

        let autoSpeakers = [NoteSpeaker(key: "you"), NoteSpeaker(key: "s1", name: "Priya", nameSource: .auto)]
        let named = note("Named", speakers: autoSpeakers)
        model.open(named)
        model.clearSuggestedName("s1")
        let cleared = store.meta(named)?.speakers.first { $0.key == "s1" }
        check(cleared?.name == nil && cleared?.nameSource == .user && model.renamingKey == nil,
              "DOC30 Clear on a suggested name", describe(cleared as Any))
        model.backToList()
        try? FileManager.default.removeItem(at: root)
    }
}

// MARK: - Speaker names: direction of address, per-label entries, diagnostics, stored references

extension NotesDocChecks {
    private static func tn(_ speaker: String, _ start: Double, _ text: String) -> TranscriptTurn {
        TranscriptTurn(speaker: speaker, start: start, end: start + 5, text: text)
    }

    private static let meeting: [TranscriptTurn] = [
        tn("you", 13, "Okay, I think we can start. Thanks everyone for joining. Dave said he might be a few minutes late, so let's not wait for him."),
        tn("s1", 22, "Morning. Can everyone hear me okay? I got a new headset and I have no idea how loud it is."),
        tn("s2", 29, "We can hear you, Bob, very clearly. Maybe a little too clearly."),
        tn("you", 34, "Right. So the plan for today is the version 2 launch. Jason, are you there?"),
        tn("s3", 48, "Yeah, I'm here. I'm on my phone in the car park, so the line might be a bit rough."),
        tn("you", 96, "Okay, let's come back to that. The bigger question is the launch date. Emily, you had concerns about that."),
        tn("s2", 106, "I did. The onboarding screens are still the old design."),
        tn("s5", 159, "Hi, sorry, sorry. I'm here now. The meeting link kept sending me to the wrong room."),
        tn("you", 167, "Hi Dave, we were just about to decide on moving the launch."),
        tn("s4", 219, "Do we actually need the animated tutorial? Nobody in the beta watched the video one."),
        tn("s2", 225, "That's exactly what I thought, Lucia."),
        tn("s4", 230, "Hi all, this is Lucia from the data team, by the way."),
    ]

    private static let meetingSpeakers: [NoteSpeaker] = [
        NoteSpeaker(key: "you"), NoteSpeaker(key: "s1"), NoteSpeaker(key: "s2"), NoteSpeaker(key: "s3"),
        NoteSpeaker(key: "s4"), NoteSpeaker(key: "s5"),
    ]

    private static func entry(_ label: String, _ name: String, _ kind: String, _ evidence: String, _ time: Double,
                              _ confidence: String = "high") -> Suggestion {
        Suggestion(label: label, name: name, kind: kind, evidence: evidence, time: time, confidence: confidence)
    }

    private static var meetingEntries: [Suggestion] {
        [entry("Speaker 1", "Bob", "addressed", "We can hear you, Bob, very clearly.", 29),
         entry("Speaker 2", "Emily", "addressed", "Emily, you had concerns about that.", 96),
         entry("Speaker 3", "Jason", "addressed", "Jason, are you there?", 34),
         entry("Speaker 4", "Lucia", "addressed", "That's exactly what I thought, Lucia.", 225),
         entry("Speaker 5", "Dave", "addressed", "Hi Dave", 167)]
    }

    private static func review(_ list: [Suggestion]) -> [NotesAI.NameVerdict] {
        NotesAI.nameReview(list, turns: meeting, speakers: meetingSpeakers)
    }

    private static func reasons(_ list: [Suggestion]) -> [String] {
        review(list).map { $0.accepted ? "ok" : $0.reason }
    }

    private static func meetingReply() -> String {
        func obj(_ k: [String: Any]) -> [String: Any] { k }
        let decisions: [[String: Any]] = [["text": "Move the launch", "status": "needs_discussion", "time": 167]]
        let details: [[String: Any]] = [
            ["topic": "Audio check", "text": "Speaker 2 told Bob the headset is clear.", "times": [29]],
            ["topic": "Onboarding", "text": "Speaker 2 said the screens are old.", "times": [106]],
            ["topic": "Late joiner", "text": "Dave joined late.", "times": [159]],
        ]
        let actions: [[String: Any]] = [
            ["owner": "Speaker 3", "task": "Check the line", "time": 48],
            ["owner": "You", "task": "Set the launch date", "time": 34],
            ["owner": "Dave", "task": "Review the screens", "time": 167],
            ["owner": "", "task": "Book a room", "time": 96],
        ]
        let raw: [String: Any] = [
            "title": "Version 2 launch plan", "description": "Launch date and onboarding screens",
            "summary": "Bob tested his headset and Speaker 2 raised onboarding.", "summary_times": [13],
            "decisions": decisions, "details": details, "action_items": actions,
            "speakers": meetingEntries.map { s -> [String: Any] in
                ["label": s.label, "name": s.name, "kind": s.kind, "evidence": s.evidence, "time": Int(s.time),
                 "confidence": s.confidence]
            },
        ]
        let data = (try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func validated() -> NoteSummary? {
        let r = NotesAI.validateSummary(meetingReply(), turns: meeting, speakers: meetingSpeakers, provider: .anthropic,
                                        model: .claudeHaiku, written: Date(timeIntervalSince1970: 0), parts: 1)
        if case .success(let s) = r { return s }
        return nil
    }

    static func runNameFix(_ check: (Bool, String, String) -> Void) {
        // DOC31 the whole reply
        let s31 = validated()
        let want31 = ["s1": "Bob", "s2": "Emily", "s3": "Jason", "s4": "Lucia", "s5": "Dave"]
        let owners = s31?.actionItems.map { $0.owner } ?? []
        let d0 = NotesDoc.details(s31 ?? emptySummary()).first?.text ?? ""
        check(s31?.suggestedNames == want31 && owners == ["s3", "you", "s5", ""]
              && d0 == "{{s2}} told {{s1}} the headset is clear.",
              "DOC31 a reply in the real shape is validated, names kept, references stored as tokens",
              "\(describe(s31?.suggestedNames as Any)) \(owners) \(d0)")

        // DOC32 addressed by another speaker
        let a32 = NotesAI.acceptedNames([meetingEntries[0]], turns: meeting, speakers: meetingSpeakers)
        check(a32 == ["s1": "Bob"], "DOC32 a name said to a speaker by another speaker is accepted", describe(a32))

        // DOC33 addressed quote spoken by the named speaker
        let r33 = reasons([entry("Speaker 2", "Lucia", "addressed", "That's exactly what I thought, Lucia.", 225)])
        check(r33 == ["named speaker said it"], "DOC33 a quote the named speaker said is refused", describe(r33))

        // DOC34 / DOC35 introduced
        let intro = "this is Lucia from the data team"
        let r34 = reasons([entry("Speaker 4", "Lucia", "introduced", intro, 230)])
        check(r34 == ["ok"], "DOC34 a self-introduction is accepted", describe(r34))
        let r35 = reasons([entry("Speaker 2", "Lucia", "introduced", intro, 230)])
        check(r35 == ["introduced by someone else"], "DOC35 an introduction by someone else is refused", describe(r35))

        // DOC36 normalised quote, wrong time
        let q36 = "we can hear you bob very clearly"
        let r36 = reasons([entry("Speaker 1", "Bob", "addressed", q36, 29), entry("Speaker 1", "Bob", "addressed", q36, 31)])
        check(r36 == ["ok", "ok"], "DOC36 a normalised quote is found, even at a wrong time", describe(r36))

        // DOC37 You, and a quote without the name
        let r37 = reasons([entry("You", "Samr", "addressed", "Hi Dave", 167),
                           entry("Speaker 1", "Samr", "addressed", "Morning", 22)])
        check(r37 == ["not a speaker label", "name not in quote"], "DOC37 You is never named, a quote needs the name",
              describe(r37))

        // DOC38 null name
        let raw38 = "{\"label\":\"Speaker 3\",\"name\":null,\"kind\":\"none\",\"evidence\":null,\"time\":0,\"confidence\":\"low\"}"
        let dec38 = try? JSONDecoder().decode(Suggestion.self, from: Data(raw38.utf8))
        let wrapped = "{\"speakers\":[" + raw38 + "]}"
        let props38 = NotesAI.speakerProposals(fromReply: wrapped)
        let r38 = dec38.map { reasons([$0]) } ?? ["decode failed"]
        let n38 = dec38.map { NotesAI.acceptedNames([$0], turns: meeting, speakers: meetingSpeakers) } ?? ["x": "y"]
        check(r38 == ["no name"] && n38.isEmpty && props38.count == 1, "DOC38 a null name decodes and names nobody",
              "\(r38) \(n38) \(props38.count)")

        // DOC39 duplicates
        let r39 = review([entry("Speaker 2", "Emily", "addressed", "Emily, you had concerns about that.", 96),
                          entry("Speaker 4", "Emily", "addressed", "Emily, you had concerns about that.", 96)])
        let small = [tn("s1", 0, "Hello there."), tn("you", 6, "Dave, please go ahead."), tn("s2", 10, "Sure.")]
        let sp3 = [NoteSpeaker(key: "you"), NoteSpeaker(key: "s1"), NoteSpeaker(key: "s2")]
        let dave = [entry("Speaker 1", "Dave", "addressed", "Dave, please go ahead", 6),
                    entry("Speaker 2", "Dave", "addressed", "Dave, please go ahead", 6)]
        let v39 = NotesAI.nameReview(dave, turns: small, speakers: sp3)
        let a39 = NotesAI.acceptedNames(dave, turns: small, speakers: sp3)
        check(r39.map { $0.accepted } == [true, false] && r39[1].reason == "not next to the named speaker"
              && v39.map { $0.reason } == ["name on two speakers", "name on two speakers"] && a39.isEmpty,
              "DOC39 a name on two speakers is refused for both", "\(r39.map { $0.reason }) \(v39.map { $0.reason })")

        // DOC40 neither neighbour is the named speaker
        let r40 = reasons([entry("Speaker 3", "Bob", "addressed", "We can hear you, Bob, very clearly.", 29)])
        check(r40 == ["not next to the named speaker"], "DOC40 a name said next to someone else is refused", describe(r40))

        // DOC41 stored references follow renames
        if let s = validated() {
            let named = NotesDoc.applyingSuggestedNames(s.suggestedNames ?? [:], to: meetingSpeakers)
            let renamedEm = NotesLogic.renaming("s2", to: "Em", in: named)
            let cleared = NotesDoc.clearingName("s1", in: renamedEm)
            let t1 = NotesDoc.details(NotesDoc.resolving(s, speakers: renamedEm)).first?.text ?? ""
            let t2 = NotesDoc.details(NotesDoc.resolving(s, speakers: cleared)).first?.text ?? ""
            let m = NoteMeta(id: "20261123-140000-abcd", title: "T", started: Date(timeIntervalSince1970: 0), duration: 60,
                             speakers: renamedEm, state: .ready)
            let md = NotesDoc.markdown(meta: m, summary: s, calendar: Calendar(identifier: .gregorian))
            check(t1 == "Em told Bob the headset is clear." && t2 == "Em told Speaker 1 the headset is clear."
                  && md.contains("Em told Bob the headset is clear."),
                  "DOC41 stored references follow renames", "\(t1) | \(t2)")
        } else {
            check(false, "DOC41 stored references follow renames", "no summary")
        }

        // DOC42 the review of the whole reply
        let v42 = review(NotesAI.speakerProposals(fromReply: meetingReply()))
        check(v42.count == 5 && v42.allSatisfy { $0.accepted } && v42.map { $0.quoteTurn ?? -1 } == [2, 5, 3, 10, 8],
              "DOC42 nameReview on the whole reply", "\(v42.map { $0.reason }) \(v42.map { $0.quoteTurn ?? -1 })")

        // DOC43 the names line
        var out = NotesAskRun.Output(mode: "summary", provider: "Anthropic", model: "m", ok: true)
        func verdict(_ kind: String, _ name: String, _ ok: Bool, _ reason: String) -> NotesAI.NameVerdict {
            NotesAI.NameVerdict(label: "Speaker 1", name: name, kind: kind, confidence: "high", evidence: "x", time: 0,
                                quoteTurn: nil, quoteSpeaker: nil, accepted: ok, reason: reason)
        }
        out.nameReview = [verdict("addressed", "Bob", true, ""), verdict("introduced", "Lucia", true, ""),
                          verdict("addressed", "Dave", false, "low confidence"), verdict("none", "", false, "no name")]
        out.autoNamesApplied = 2
        let lines43 = NotesAskRun.lines(out)
        let want43 = "notesasktest: names: proposed 3, applied 2, rejected 1 (low confidence x1)"
        check(lines43.contains(want43), "DOC43 the names line holds counts and fixed reasons only", lines43.joined(separator: " | "))

        // DOC44 the request and the prompt
        if let access = NotesAccess.resolve(hasAnthropic: { true }, hasOpenAI: { false }, anthropicModel: nil, openAIModel: nil) {
            let lines = NotesAI.transcriptLines(meeting, speakers: meetingSpeakers)
            let req = NotesAI.summaryRequest(access, key: "k", lines: lines, part: 1, of: 1)
            var itemRequired: [String] = []
            var strengthEnum: [String] = []
            if let body = req.httpBody, let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
               let outCfg = obj["output_config"] as? [String: Any], let format = outCfg["format"] as? [String: Any],
               let schema = format["schema"] as? [String: Any], let props = schema["properties"] as? [String: Any],
               let sp = props["attendees"] as? [String: Any], let item = sp["items"] as? [String: Any] {
                itemRequired = item["required"] as? [String] ?? []
                let ip = item["properties"] as? [String: Any]
                let st = ip?["strength"] as? [String: Any]
                strengthEnum = st?["enum"] as? [String] ?? []
            }
            check(itemRequired.contains("relation") && strengthEnum.contains("medium")
                  && NotesAI.summaryRules.contains("Speaker 2 is not Marcus"),
                  "DOC44 the summary request asks for a kind and the prompt names the direction",
                  "required \(itemRequired)")
        } else {
            check(false, "DOC44 the summary request asks for a kind and the prompt names the direction", "no access")
        }
    }

    private static func emptySummary() -> NoteSummary {
        NoteSummary(summary: "", summaryTimes: [], actionItems: [], decisions: [], openQuestions: [],
                    provider: "", model: "", written: Date(timeIntervalSince1970: 0), parts: 1)
    }
}

// MARK: - Local vocative pass, field names and medium strength

extension NotesDocChecks {
    private static func lt(_ speaker: String, _ start: Double, _ text: String) -> TranscriptTurn {
        TranscriptTurn(speaker: speaker, start: start, end: start + 5, text: text)
    }

    private static let threeSpeakers: [NoteSpeaker] = [NoteSpeaker(key: "you"), NoteSpeaker(key: "s1"), NoteSpeaker(key: "s2")]

    private static let basic: [TranscriptTurn] = [
        lt("you", 0, "Priya, can you walk us through the numbers?"),
        lt("s1", 10, "Sure. We are ten percent under."),
        lt("s2", 20, "Thanks, Priya. That helps."),
        lt("you", 30, "Marcus, anything on hiring?"),
        lt("s2", 40, "Yes, two offers went out."),
    ]

    /// The made-up fixture meeting's excerpt (turns as the real check saw them), embedded inline.
    private static let excerpt: [TranscriptTurn] = [
        lt("you", 13.51, "Okay, I think we can start. Thanks everyone for joining. Dave said he might be a few minutes late, so let's not wait for him."),
        lt("s2", 29.21, "We can hear you, Bob, very clearly. Maybe a little too clearly."),
        lt("you", 34.42, "Right. So the plan for today is the version 2 launch of Ped alPoint. We need to settle the launch date, the price of the annual pass, and what we do about the onboarding redesign. Jason, are you there?"),
        lt("s3", 48.06, "Yeah, I'm here. I'm on my phone in the car park, so the line might be a bit rough. Sorry about that."),
        lt("you", 55.58, "No problem. Bob, do you want to start with the beta numbers"),
        lt("s1", 59.89, "Sure. So the beta closed on Friday. We had 4200 signups in total, which is way more than we expected, and about 60% of them took at least one ride."),
        lt("s2", 71.82, "That's great. Do we know how many of those were in the new East Side Zone?"),
        lt("s1", 76.04, "Not yet. Lusha has the breakdown, I think."),
        lt("s4", 87.76, "I do, but I haven't finished cleaning it. Some of the rides were test accounts from our own team, so I want to remove those first."),
        lt("you", 92.03, "MMHM."),
        lt("you", 96.6, "Okay, let's come back to that. The bigger question is the launch date. Right now the plan says March 3rd. Emily, you had concerns about that."),
        lt("s2", 106.09, "I did. The onboarding screens are still the old design, and the feedback from the beta was pretty clear. People got lost on the second screen, the one where you pick a pass. If we launch on March 3rd, we launch with the confusing version."),
        lt("s3", 119.77, "Apparently the payment crash isn't fixed yet either, so I'd rather..."),
        lt("s1", 123.48, "If we slip, we miss the spring weather. March is when people start riding again."),
        lt("you", 128.71, "Hang on, Bob, let Jason finish. Jason, you were saying?"),
        lt("s3", 133.72, "I was saying I'd rather have two extra weeks. The crash only happened on older android phones, but that's still about 1 in 10 of our riders."),
        lt("you", 145.7, "Two weeks would put us at March 17th. Does anyone object to that?"),
        lt("s5", 159.16, "Hi, sorry, sorry. I'm here now. The meeting link kept sending me to the wrong room. Did I miss anything important"),
        lt("you", 167.68, "Hi Dave, we were just about to decide on moving the launch from March 3rd to March 17th."),
        lt("s5", 173.85, "Oh, from my side that's fine. Marketing hasn't booked anything yet. Actually, two more weeks helps me."),
        lt("s1", 181.91, "Okay, fine. I can live with March 17th. Spring is long enough."),
        lt("you", 187.58, "Great. So that's decided. The launch moves to March 17th. Dave, can you update the release plan with the new date?"),
        lt("s5", 195.67, "Sure, I'll have it done by Friday, December 4th."),
        lt("you", 199.54, "Perfect. Next, the onboarding redesign. Emily, you talked to the contractor?"),
        lt("s2", 205.52, "Yes, I spoke with Halverson Design last week. They can start on December 9th, and they quoted $14,000 for the full flow. I pushed back, and they said they could do it for $12,000 if we drop the animated tutorial."),
        lt("s4", 219.91, "Do we actually need the animated tutorial? Nobody in the beta watched the video one."),
        lt("s2", 225.59, "That's exactly what I thought, Lucia."),
        lt("you", 228.36, "Then let's do that. We hire Halverson design for the onboarding redesign, without the tutorial, with a cap of $ 12,000. Emily, can you send them the contract?"),
        lt("s2", 239.49, "Yes, I'll send it by Wednesday, December 2nd."),
    ]

    private static let fiveSpeakers: [NoteSpeaker] = [
        NoteSpeaker(key: "you"), NoteSpeaker(key: "s1"), NoteSpeaker(key: "s2"), NoteSpeaker(key: "s3"),
        NoteSpeaker(key: "s4"), NoteSpeaker(key: "s5"),
    ]

    private static func names(_ turns: [TranscriptTurn], _ speakers: [NoteSpeaker]? = nil) -> [String: String] {
        NotesAI.localNames(turns: turns, speakers: speakers ?? threeSpeakers)
    }

    private static func jsonText(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func runLocalPass(_ check: (Bool, String, String) -> Void) {
        // DOC45 / DOC46 two votes name a speaker, one does not
        let n45 = names(basic)
        check(n45 == ["s1": "Priya"], "DOC45 two vocative votes name a speaker", "\(n45)")
        check(n45["s2"] == nil, "DOC46 one vote is not enough", "\(n45)")

        // DOC47 two names with two votes each for one speaker: none
        let more = basic + [lt("you", 50, "Dana, one more thing?"), lt("s1", 60, "Go on."),
                            lt("s2", 70, "Thanks, Dana."), lt("s1", 80, "Sure.")]
        let n47 = names(more)
        check(n47["s1"] == nil, "DOC47 a speaker with two strong names gets none", "\(n47)")

        // DOC48 stopwords
        let stop = [lt("you", 0, "Sorry, I was on mute."), lt("s1", 10, "Everyone, and legal hasn't."),
                    lt("you", 20, "Thanks, everyone."), lt("s1", 30, "Monday, then."), lt("you", 40, "Hi guys.")]
        let v48 = NotesAI.localVotes(turns: stop, speakers: threeSpeakers)
        check(v48.isEmpty, "DOC48 stopwords are not names", "\(v48)")

        // DOC49 said to You
        let toYou = [lt("you", 0, "Anything else?"), lt("s1", 10, "Thanks, Sam."), lt("you", 20, "Okay."),
                     lt("s1", 30, "Thanks, Sam.")]
        let v49 = NotesAI.localVotes(turns: toYou, speakers: threeSpeakers)
        check(v49.count == 2 && v49.allSatisfy { $0.reason == "said to You" && !$0.counted }
              && names(toYou).isEmpty, "DOC49 a name said to You names nobody", "\(v49.map { $0.reason })")

        // DOC50 a name claimed by two speakers
        let claimed = [lt("you", 0, "Priya, can you start?"), lt("s1", 10, "Sure."), lt("you", 20, "Priya, and the chart?"),
                       lt("s1", 30, "Yes."), lt("you", 40, "Priya, one more."), lt("s2", 50, "Okay.")]
        check(names(claimed).isEmpty, "DOC50 a name another speaker also has votes for is dropped", "\(names(claimed))")

        // DOC51 a list of names
        let list = [lt("you", 0, "Actions. Priya, the chart. Marcus, the plan."), lt("s1", 10, "Fine.")]
        let v51 = NotesAI.localVotes(turns: list, speakers: threeSpeakers)
        check(v51.count == 2 && v51.allSatisfy { $0.reason == "list of names" && !$0.counted },
              "DOC51 a list of names counts for nobody", "\(v51.map { $0.reason })")

        // DOC52 combining
        let c1 = NotesAI.combinedNames(model: ["s2": "Emily"], local: ["s1": "Bob"])
        let c2 = NotesAI.combinedNames(model: ["s1": "Rob"], local: ["s1": "Bob"])
        let c3 = NotesAI.combinedNames(model: ["s2": "Bob"], local: ["s1": "Bob"])
        check(c1 == ["s1": "Bob", "s2": "Emily"] && c2.isEmpty && c3.isEmpty, "DOC52 combining the model and the local names",
              "\(c1) \(c2) \(c3)")

        // DOC53 the fixture excerpt, and a reply whose attendees are all none
        let want53 = ["s1": "Bob", "s2": "Emily", "s3": "Jason", "s5": "Dave"]
        let n53 = names(excerpt, fiveSpeakers)
        func none(_ label: String) -> [String: Any] {
            ["label": label, "quote": "", "quote_time": 0, "relation": "none", "speaker_name": "", "strength": "low"]
        }
        let reply53: [String: Any] = [
            "title": "Launch date and onboarding", "description": "Moving the launch and the onboarding redesign",
            "summary": "The launch moves.", "summary_times": [13], "decisions": [[String: Any]](),
            "details": [[String: Any]](),
            "next_steps": [["owner": "Speaker 5", "task": "Update the release plan", "time": 195]],
            "attendees": ["Speaker 1", "Speaker 2", "Speaker 3", "Speaker 4", "Speaker 5"].map(none),
        ]
        let r53 = NotesAI.validateSummary(jsonText(reply53), turns: excerpt, speakers: fiveSpeakers, provider: .anthropic,
                                          model: .claudeHaiku, written: Date(timeIntervalSince1970: 0), parts: 1)
        var ownerOK = false
        var namesOK = false
        if case .success(let s) = r53 {
            namesOK = s.suggestedNames == want53
            let named = NotesDoc.applyingSuggestedNames(s.suggestedNames ?? [:], to: fiveSpeakers)
            let owner = s.actionItems.first?.owner ?? ""
            ownerOK = owner == "s5" && NotesAI.ownerName(owner, speakers: named) == "Dave"
        }
        check(n53 == want53 && namesOK && ownerOK, "DOC53 the excerpt is named locally even when the model names nobody",
              "\(n53) names \(namesOK) owner \(ownerOK)")

        // DOC54 medium strength
        let q54 = "Jason, are you there?"
        let r54 = NotesAI.nameReview([
            Suggestion(label: "Speaker 3", name: "Jason", kind: "addressed", evidence: q54, time: 34.42, confidence: "medium"),
            Suggestion(label: "Speaker 3", name: "Jason", kind: "addressed", evidence: q54, time: 34.42, confidence: "low"),
        ], turns: excerpt, speakers: fiveSpeakers)
        check(r54.map { $0.accepted } == [true, false] && r54[1].reason == "low confidence",
              "DOC54 medium strength is accepted, low is refused", "\(r54.map { $0.reason })")

        // DOC55 both reply shapes decode
        let base: [String: Any] = ["summary": "S.", "summary_times": [13], "decisions": [[String: Any]]()]
        var oldShape = base
        oldShape["action_items"] = [["owner": "", "task": "Do it", "time": 13]]
        oldShape["speakers"] = [["label": "Speaker 3", "name": "Jason", "kind": "addressed", "evidence": q54,
                                 "time": 34, "confidence": "high"]]
        var newShape = base
        newShape["next_steps"] = [["owner": "", "task": "Do it", "time": 13]]
        newShape["attendees"] = [["label": "Speaker 3", "quote": "Jason, are you there?", "quote_time": 34,
                                  "relation": "addressed", "speaker_name": "Jason", "strength": "high"]]
        func run(_ o: [String: Any]) -> Result<NoteSummary, NotesAIError> {
            NotesAI.validateSummary(jsonText(o), turns: excerpt, speakers: fiveSpeakers, provider: .anthropic,
                                    model: .claudeHaiku, written: Date(timeIntervalSince1970: 0), parts: 1)
        }
        var oldNames: [String: String]?
        var newNames: [String: String]?
        if case .success(let s) = run(oldShape) { oldNames = s.suggestedNames }
        if case .success(let s) = run(newShape) { newNames = s.suggestedNames }
        let neither = run(base)
        var neitherMalformed = false
        if case .failure(let e) = neither { neitherMalformed = e == .malformed }
        check(oldNames?["s3"] == "Jason" && newNames?["s3"] == "Jason" && neitherMalformed,
              "DOC55 old and new reply shapes both validate, neither step list is malformed",
              "\(describe(oldNames as Any)) \(describe(newNames as Any)) \(neitherMalformed)")
    }
}
