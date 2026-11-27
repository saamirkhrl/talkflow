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

    private static func suggestion(_ label: String, _ name: String, _ evidence: String, _ time: Double,
                                   _ confidence: String) -> Suggestion {
        Suggestion(label: label, name: name, evidence: evidence, time: time, confidence: confidence)
    }

    private static let priyaQuote = "Priya, can you give us the budget update"

    private static var goodSuggestions: [Suggestion] {
        [suggestion("Speaker 1", "Priya", priyaQuote, 0, "high"),
         suggestion("Speaker 2", "Marcus", "This is Marcus", 14, "high")]
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
            ["label": s.label, "name": s.name, "evidence": s.evidence, "time": Int(s.time), "confidence": s.confidence]
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
        let g17 = accepted([suggestion("Speaker 1", "Priya", "Priya, please start us off", 0, "high")])
        check(g17.isEmpty, "DOC17 a quote that is not in the transcript is refused", describe(g17))
        let g18 = accepted([suggestion("Speaker 1", "Priya", "can you give us the budget update", 0, "high")])
        check(g18.isEmpty, "DOC18 a name that is not in its quote is refused", describe(g18))

        // DOC19 the same name on two speakers
        let g19 = accepted([suggestion("Speaker 1", "Priya", priyaQuote, 0, "high"),
                            suggestion("Speaker 2", "Priya", "Thanks Priya", 14, "high")])
        check(g19.isEmpty, "DOC19 one name on two speakers is refused for both", describe(g19))

        // DOC20 over 40 characters
        let longName = "Priya Venkataraman-Subramanian Krishnamurthy"
        let g20 = accepted([suggestion("Speaker 1", longName, longName, 0, "high")])
        check(longName.count == 44 && g20.isEmpty, "DOC20 a name over 40 characters is refused", describe(g20))

        // DOC21 low confidence
        let g21 = accepted([suggestion("Speaker 1", "Priya", priyaQuote, 0, "low")])
        check(g21.isEmpty, "DOC21 low confidence is refused", describe(g21))

        // DOC22 "You" as a name or a label
        let g22a = accepted([suggestion("Speaker 1", "You", "You can start", 0, "high")])
        let g22b = accepted([suggestion("You", "Priya", priyaQuote, 0, "high")])
        check(g22a.isEmpty && g22b.isEmpty, "DOC22 You is never named or renamed", "\(describe(g22a)) \(describe(g22b))")

        // DOC23 a speaker the user renamed
        let renamedSpeakers = [NoteSpeaker(key: "you"), NoteSpeaker(key: "s1", name: "Pri", nameSource: .user),
                               NoteSpeaker(key: "s2"), NoteSpeaker(key: "s3")]
        let g23a = accepted([suggestion("Speaker 1", "Priya", priyaQuote, 0, "high")], speakers: renamedSpeakers)
        let g23b = accepted([suggestion("Pri", "Priya", priyaQuote, 0, "high")], speakers: renamedSpeakers)
        check(g23a.isEmpty && g23b.isEmpty, "DOC23 a name the user typed is never replaced",
              "\(describe(g23a)) \(describe(g23b))")

        // DOC24 a time that matches no turn
        let far = [suggestion("Speaker 1", "Priya", priyaQuote, 9999, "high")]
        let g24 = accepted(far)
        var v24 = "not a success"
        if case .success(let s) = validate(newReply(names: far)) {
            v24 = s.suggestedNames == nil ? "ok" : "names kept"
        }
        check(g24.isEmpty && v24 == "ok", "DOC24 a name at a missing time is dropped, the reply still succeeds", v24)

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
                  && s.suggestedNames == nil && s.openQuestions.isEmpty && (s.details ?? []).count == 2,
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
        let all = ["title", "description", "summary", "summary_times", "decisions", "details", "action_items"]
        let with = NotesAI.summarySchema(speakers: true)
        let without = NotesAI.summarySchema(speakers: false)
        let reqWith = with["required"] as? [String] ?? []
        let reqWithout = without["required"] as? [String] ?? []
        let propsWithout = (without["properties"] as? [String: Any]) ?? [:]
        check(reqWith == all + ["speakers"] && reqWithout == all && propsWithout["speakers"] == nil
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
            check(sProps["speakers"] != nil && !cProps.isEmpty && cProps["speakers"] == nil,
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
