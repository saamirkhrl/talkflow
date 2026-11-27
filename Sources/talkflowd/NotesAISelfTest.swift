import Foundation

/// Part of `--notestest` (called from NotesSelfTest). Canned replies only.
enum NotesAISelfTest {
    typealias Check = (Bool, String, String) -> Void

    // MARK: Fixtures

    private static func turn(_ speaker: String, _ start: Double, _ end: Double, _ text: String) -> TranscriptTurn {
        TranscriptTurn(speaker: speaker, start: start, end: end, text: text)
    }

    private static let turns: [TranscriptTurn] = [
        turn("you", 4, 12, "Okay, the launch order."),
        turn("s1", 19, 26, "Demo video?"),
        turn("you", 27, 35, "Still a recording."),
        turn("s2", 36, 47, "Lead with privacy."),
        turn("s1", 48, 60, "I'll draft it tonight."),
    ]

    private static let speakers: [NoteSpeaker] = [
        NoteSpeaker(key: "you", name: nil),
        NoteSpeaker(key: "s1", name: "Maya"),
        NoteSpeaker(key: "s2", name: nil),
    ]

    private static let fixedNow = Date(timeIntervalSince1970: 1_792_000_000)

    private static func describe<T>(_ value: T) -> String { String(describing: value) }

    private static func json(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func body(_ request: URLRequest) -> [String: Any] {
        guard let data = request.httpBody,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        return object
    }

    private static func same(_ a: Any?, _ b: Any?) -> Bool {
        guard let a = a, let b = b else { return a == nil && b == nil }
        return (a as AnyObject).isEqual(b)
    }

    private static func sameDict(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        NSDictionary(dictionary: a).isEqual(to: b)
    }

    private static func events(_ provider: NotesProvider, _ lines: [String]) -> (events: [NotesStreamEvent], parser: NotesStreamParser) {
        var parser = NotesStreamParser(provider: provider)
        var all: [NotesStreamEvent] = []
        for line in lines { all += parser.feed(line) }
        return (all, parser)
    }

    private static func anthropicDelta(_ text: String) -> String {
        "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"text_delta\",\"text\":\"\(text)\"}}"
    }

    private static func openAIDelta(_ text: String) -> String {
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"\(text)\"}"
    }

    /// A summary reply in the shape the schema asks for. The time arguments let a case move one value.
    private static func goodJSON(actionTime: String = "27", decisionTime: String = "4", summaryTimes: String = "[4,36,36]") -> String {
        "{\"summary\":\" The team agreed. \",\"summary_times\":\(summaryTimes),"
            + "\"action_items\":[{\"owner\":\"You\",\"task\":\"Cut the demo video\",\"time\":\(actionTime)},"
            + "{\"owner\":\"maya\",\"task\":\"Draft the post\",\"time\":48},"
            + "{\"owner\":\"\",\"task\":\"Book a room\",\"time\":19},"
            + "{\"owner\":\"Priya\",\"task\":\"Review\",\"time\":36}],"
            + "\"decisions\":[{\"text\":\"Launch together\",\"time\":\(decisionTime)}],"
            + "\"open_questions\":[{\"text\":\"When is the demo?\",\"time\":19}]}"
    }

    private static func validate(_ text: String) -> Result<NoteSummary, NotesAIError> {
        NotesAI.validateSummary(text, turns: turns, speakers: speakers, provider: .anthropic, model: .claudeHaiku,
                                written: fixedNow, parts: 1)
    }

    private static func errorOf(_ result: Result<NoteSummary, NotesAIError>) -> NotesAIError? {
        if case .failure(let e) = result { return e }
        return nil
    }

    // MARK: Run

    static func run(check raw: Check) {
        // The caller's closure has no default for the detail text; most cases pass none.
        func check(_ condition: Bool, _ label: String, _ detail: String = "") { raw(condition, label, detail) }

        let aH = NotesAccess.resolve(hasAnthropic: { true }, hasOpenAI: { false },
                                     anthropicModel: nil, openAIModel: nil)!
        let aS = NotesAccess.resolve(hasAnthropic: { true }, hasOpenAI: { false },
                                     anthropicModel: "claude-sonnet-5-5", openAIModel: nil)!
        let oL = NotesAccess.resolve(hasAnthropic: { false }, hasOpenAI: { true },
                                     anthropicModel: nil, openAIModel: nil)!

        // MARK: Gate (no switch: a saved key is enough)
        let gateSuite = "talkflow-notestest-gate-\(UUID().uuidString)"
        let savedDefaults = Preferences.defaults
        if let d = UserDefaults(suiteName: gateSuite) {
            Preferences.defaults = d
            let a1 = NotesAccess.current(hasKey: { $0 == .anthropic })
            check(a1?.provider == .anthropic && a1?.model == .claudeHaiku, "NA01 a saved key allows notes with no switch value stored", describe(a1))
            d.set(true, forKey: "notesUseKey")
            let n1 = NotesAccess.current(hasKey: { _ in false })
            check(n1 == nil, "NA07 no key gives nil, even with the old switch stored on", describe(n1))
            d.set(false, forKey: "notesUseKey")
            let o1 = NotesAccess.current(hasKey: { $0 == .openAI })
            check(o1?.provider == .openAI, "NA08 a stale old switch value of off does not block notes", describe(o1))
            d.set(false, forKey: "notesUseKey"); d.set("anthropic", forKey: "notesConfirmedProvider")
            Preferences.retireNotesSwitch(d)
            let offGone = d.object(forKey: "notesUseKey") == nil && d.string(forKey: "notesConfirmedProvider") == nil
            d.set(true, forKey: "notesUseKey"); d.set("openai", forKey: "notesConfirmedProvider")
            Preferences.retireNotesSwitch(d)
            let onKept = d.object(forKey: "notesUseKey") == nil && d.string(forKey: "notesConfirmedProvider") == "openai"
            Preferences.retireNotesSwitch(d)
            let absentKept = d.string(forKey: "notesConfirmedProvider") == "openai"
            check(offGone && onKept && absentKept, "NA09 the old switch is removed; stored off asks for the confirmation again",
                  "off \(offGone) on \(onKept) absent \(absentKept)")
            Preferences.defaults = savedDefaults
            d.removePersistentDomain(forName: gateSuite)
        } else {
            check(false, "NA01 test settings suite could not be made", "")
        }

        check(aH.provider == .anthropic && aH.model == .claudeHaiku, "NA02 Anthropic key gives Haiku", describe(aH))
        check(oL.provider == .openAI && oL.model == .gptLuna, "NA03 OpenAI key gives Luna", describe(oL))
        let none = NotesAccess.resolve(hasAnthropic: { false }, hasOpenAI: { false },
                                       anthropicModel: nil, openAIModel: nil)
        check(none == nil, "NA04 no key gives nil", describe(none))

        let stored1 = NotesAccess.resolve(hasAnthropic: { true }, hasOpenAI: { false },
                                          anthropicModel: "claude-sonnet-5-5", openAIModel: nil)
        let stored2 = NotesAccess.resolve(hasAnthropic: { true }, hasOpenAI: { false },
                                          anthropicModel: "gpt-6-luna", openAIModel: nil)
        let stored3 = NotesAccess.resolve(hasAnthropic: { true }, hasOpenAI: { false },
                                          anthropicModel: "garbage", openAIModel: nil)
        let stored4 = NotesAccess.resolve(hasAnthropic: { false }, hasOpenAI: { true },
                                          anthropicModel: nil, openAIModel: "gpt-6.2-sol")
        check(stored1?.model == .claudeSonnet && stored2?.model == .claudeHaiku && stored3?.model == .claudeHaiku
              && stored4?.model == .gptSol, "NA05 stored model ids are honoured only for their own provider",
              "\(describe(stored1)) \(describe(stored2)) \(describe(stored3)) \(describe(stored4))")

        check(NotesAIModel.claudeHaiku.pickerTitle == "Claude Haiku 5.5 (cheapest)"
              && NotesAIModel.claudeSonnet.pickerTitle == "Claude Sonnet 5.5"
              && NotesAIModel.title(forID: "x-1") == "x-1",
              "NA06 picker titles and unknown id fall back",
              "\(NotesAIModel.claudeHaiku.pickerTitle) | \(NotesAIModel.claudeSonnet.pickerTitle) | \(NotesAIModel.title(forID: "x-1"))")

        // MARK: Sizes

        let est = ["", "abcde", "abcdef", "日本", "ab日"].map { NotesAI.estimateTokens($0) }
        check(est == [0, 2, 3, 2, 2], "NA10 estimateTokens", describe(est))

        let naTurns = [turn("you", 4.6, 10, "Hello there."), turn("s1", 19, 25, "Hi.\nAgain"), turn("you", 30, 31, "  ")]
        let naLines = NotesAI.transcriptLines(naTurns, speakers: [NoteSpeaker(key: "you", name: nil), NoteSpeaker(key: "s1", name: "Maya")])
        check(naLines == ["[4] You: Hello there.", "[19] Maya: Hi. Again"], "NA11 transcriptLines", describe(naLines))

        check(NotesAI.contextText(lines: ["a", "b"]) == NotesAI.contextPreamble + "\n\n<transcript>\na\nb\n</transcript>",
              "NA12 contextText")

        let s1 = NotesAI.split(tokens: [89_999])
        let s2 = NotesAI.split(tokens: [90_000])
        let s3 = NotesAI.split(tokens: [])
        check(s1 == .single && s2 == .single && s3 == .single, "NA13 small meetings are one request",
              "\(describe(s1)) \(describe(s2)) \(describe(s3))")

        let s4 = NotesAI.split(tokens: [45_000, 45_001])
        check(s4 == .parts([0..<1, 1..<2]), "NA14 just over the single limit splits in two", describe(s4))

        let tens = Array(repeating: 20_000, count: 10)
        let s5 = NotesAI.split(tokens: tens)
        check(s5 == .parts([0..<3, 3..<6, 6..<9, 9..<10]), "NA15 ten 20K lines split into four parts", describe(s5))

        let uneven = [10_000, 70_000, 30_000]
        let s6 = NotesAI.split(tokens: uneven)
        check(s6 == .parts([0..<1, 1..<2, 2..<3]), "NA16 an oversized line gets its own part", describe(s6))

        let s7 = NotesAI.split(tokens: [721_000])
        let s8 = NotesAI.split(tokens: [720_000])
        var s8Parts = false
        if case .parts = s8 { s8Parts = true }
        check(s7 == .tooLong(hours: 34) && s8Parts, "NA17 over 720K is too long, 720K is not",
              "\(describe(s7)) \(describe(s8))")

        func covers(_ plan: NotesAI.SummaryPlan, _ n: Int) -> Bool {
            guard case .parts(let ranges) = plan else { return false }
            return ranges.flatMap { Array($0) } == Array(0..<n)
        }
        check(covers(s5, 10) && covers(s6, 3), "NA18 parts cover every line once, in order")

        let tooLong = NotesAI.askTooLong(lines: [String(repeating: "a", count: 1_600_000)], history: [])
        let short = NotesAI.askTooLong(lines: ["short"], history: [])
        check(tooLong == .tooLong(hours: NotesAI.hoursOfSpeech(tokens: 640_001)) && short == nil,
              "NA19 askTooLong", "\(describe(tooLong)) \(describe(short))")

        // MARK: Requests

        let lines = NotesAI.transcriptLines(turns, speakers: speakers)
        let context = NotesAI.contextText(lines: lines)
        let cachedContext: [String: Any] = ["type": "text", "text": context, "cache_control": ["type": "ephemeral"]]
        let format: [String: Any] = ["type": "json_schema", "schema": NotesAI.summarySchema(speakers: true)]
        let forbidden = ["temperature", "top_p", "top_k", "stream", "tool_choice"]

        let r20 = NotesAI.summaryRequest(aH, key: "k-test", lines: lines, part: 1, of: 1)
        let b20 = body(r20)
        let exp20: [String: Any] = [
            "model": "claude-haiku-5-5", "max_tokens": 16000, "thinking": ["type": "disabled"],
            "system": [cachedContext, ["type": "text", "text": NotesAI.summaryRules]],
            "messages": [["role": "user", "content": "Write the notes for this meeting."]],
            "output_config": ["format": format],
        ]
        check(r20.url == NotesAI.anthropicURL && r20.httpMethod == "POST"
              && r20.value(forHTTPHeaderField: "x-api-key") == "k-test"
              && r20.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21"
              && r20.value(forHTTPHeaderField: "content-type") == "application/json"
              && r20.timeoutInterval == 180 && sameDict(b20, exp20),
              "NA20 Haiku summary request", "keys \(b20.keys.sorted())")

        let r21 = NotesAI.summaryRequest(aS, key: "k-test", lines: lines, part: 1, of: 1)
        let b21 = body(r21)
        let exp21config: [String: Any] = ["effort": "low", "format": format]
        let noForbidden = forbidden.allSatisfy { b20[$0] == nil && b21[$0] == nil }
        check(b21["thinking"] == nil && same(b21["output_config"], exp21config) && noForbidden,
              "NA21 Sonnet summary request has effort low, no thinking, no forbidden keys", "keys \(b21.keys.sorted())")

        let r22 = NotesAI.summaryRequest(aH, key: "k", lines: lines, part: 2, of: 3)
        let m22 = (body(r22)["messages"] as? [[String: Any]])?.first?["content"] as? String
        check(m22 == "Write the notes for this part of the meeting (part 2 of 3). The times are from the start of the whole meeting.",
              "NA22 part instruction", m22 ?? "nil")

        let history = (1...8).map {
            NoteQuestions.Entry(question: "q\($0)", answer: "a\($0)", citations: [], asked: fixedNow,
                                provider: "Anthropic", model: "claude-haiku-5-5")
        }
        let r23 = NotesAI.askRequest(aH, key: "k", lines: lines, history: history, question: "What next?")
        var msgs23: [[String: Any]] = []
        for i in 3...8 {
            msgs23.append(["role": "user", "content": "q\(i)"])
            msgs23.append(["role": "assistant", "content": "a\(i)"])
        }
        msgs23.append(["role": "user", "content": "What next?"])
        let exp23: [String: Any] = [
            "model": "claude-haiku-5-5", "max_tokens": 8000, "stream": true, "thinking": ["type": "disabled"],
            "system": [cachedContext, ["type": "text", "text": NotesAI.askRules]],
            "messages": msgs23,
        ]
        let b23 = body(r23)
        check(sameDict(b23, exp23) && msgs23.count == 13 && r23.timeoutInterval == 60 && b23["output_config"] == nil,
              "NA23 Haiku ask request keeps the last six exchanges", "keys \(b23.keys.sorted())")

        let r24 = NotesAI.askRequest(aS, key: "k", lines: lines, history: [], question: "What next?")
        let b24 = body(r24)
        check(same(b24["output_config"], ["effort": "low"]) && b24["thinking"] == nil
              && same(b24["messages"], [["role": "user", "content": "What next?"]]),
              "NA24 Sonnet ask request", "keys \(b24.keys.sorted())")

        let r25 = NotesAI.summaryRequest(oL, key: "k-o", lines: lines, part: 1, of: 1)
        let exp25: [String: Any] = [
            "model": "gpt-6-luna", "store": false, "max_output_tokens": 16000, "reasoning": ["effort": "low"],
            "input": [["role": "developer", "content": context],
                      ["role": "developer", "content": NotesAI.summaryRules],
                      ["role": "user", "content": "Write the notes for this meeting."]],
            "text": ["format": ["type": "json_schema", "name": "meeting_notes", "strict": true,
                                "schema": NotesAI.summarySchema(speakers: true)] as [String: Any]],
        ]
        check(r25.url == NotesAI.openAIURL && r25.value(forHTTPHeaderField: "Authorization") == "Bearer k-o"
              && r25.value(forHTTPHeaderField: "content-type") == "application/json"
              && r25.value(forHTTPHeaderField: "x-api-key") == nil && sameDict(body(r25), exp25),
              "NA25 OpenAI summary request", "keys \(body(r25).keys.sorted())")

        let h1 = [NoteQuestions.Entry(question: "q1", answer: "a1", citations: [], asked: fixedNow,
                                      provider: "OpenAI", model: "gpt-6-luna")]
        let r26 = NotesAI.askRequest(oL, key: "k-o", lines: lines, history: h1, question: "What next?")
        let exp26: [String: Any] = [
            "model": "gpt-6-luna", "store": false, "max_output_tokens": 8000, "reasoning": ["effort": "low"],
            "stream": true,
            "input": [["role": "developer", "content": context],
                      ["role": "developer", "content": NotesAI.askRules],
                      ["role": "user", "content": "q1"], ["role": "assistant", "content": "a1"],
                      ["role": "user", "content": "What next?"]],
        ]
        check(sameDict(body(r26), exp26), "NA26 OpenAI ask request", "keys \(body(r26).keys.sorted())")

        let p1 = NoteSummary(summary: "One.", summaryTimes: [4],
                             actionItems: [NoteSummary.ActionItem(owner: "s1", task: "Draft", time: 48, done: false)],
                             decisions: [NoteSummary.Point(text: "Ship", time: 36)], openQuestions: [],
                             provider: "Anthropic", model: "claude-haiku-5-5", written: fixedNow, parts: 1)
        let p2 = NoteSummary(summary: "Two.", summaryTimes: [27],
                             actionItems: [NoteSummary.ActionItem(owner: "", task: "Cut video", time: 27, done: false)],
                             decisions: [], openQuestions: [NoteSummary.Point(text: "When?", time: 19)],
                             provider: "Anthropic", model: "claude-haiku-5-5", written: fixedNow, parts: 1)
        let r27 = NotesAI.combineRequest(aH, key: "k", parts: [p1, p2], speakers: speakers)
        let b27 = body(r27)
        let content27 = ((b27["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
        let rest27 = content27.hasPrefix(NotesAI.combinePrefix) ? String(content27.dropFirst(NotesAI.combinePrefix.count)) : ""
        let exp27json: [[String: Any]] = [
            ["part": 1, "summary": "One.", "summary_times": [4],
             "action_items": [["owner": "Maya", "task": "Draft", "time": 48]],
             "decisions": [["text": "Ship", "status": "aligned", "time": 36]], "details": []],
            ["part": 2, "summary": "Two.", "summary_times": [27],
             "action_items": [["owner": "", "task": "Cut video", "time": 27]],
             "decisions": [["text": "When?", "status": "needs_discussion", "time": 19]], "details": []],
        ]
        let format27: [String: Any] = ["type": "json_schema", "schema": NotesAI.summarySchema(speakers: false)]
        let output27 = b27["output_config"] as? [String: Any]
        check(same(b27["system"], [["type": "text", "text": NotesAI.combineRules]]) && content27.hasPrefix(NotesAI.combinePrefix)
              && same(json(rest27), exp27json) && same(output27?["format"], format27) && b27["max_tokens"] as? Int == 16000,
              "NA27 combine request", "content \(content27.count) chars")

        // MARK: Replies

        func reply(_ text: String) -> Data { text.data(using: .utf8) ?? Data() }
        let r30 = NotesAI.replyText(.anthropic, data: reply("{\"content\":[{\"type\":\"thinking\",\"thinking\":\"x\"},{\"type\":\"text\",\"text\":\"{\\\"a\\\":1}\"}],\"stop_reason\":\"end_turn\"}"))
        check(r30 == .success("{\"a\":1}"), "NA30 Anthropic reply text skips thinking blocks", describe(r30))

        let r31a = NotesAI.replyText(.anthropic, data: reply("{\"content\":[],\"stop_reason\":\"refusal\"}"))
        let r31b = NotesAI.replyText(.anthropic, data: reply("{\"content\":[{\"type\":\"text\",\"text\":\"x\"}],\"stop_reason\":\"max_tokens\"}"))
        let r31c = NotesAI.replyText(.anthropic, data: reply("not json"))
        check(r31a == .failure(.refused) && r31b == .failure(.truncated) && r31c == .failure(.malformed),
              "NA31 Anthropic refusal, cut off, not JSON", "\(describe(r31a)) \(describe(r31b)) \(describe(r31c))")

        let r32 = NotesAI.replyText(.openAI, data: reply("{\"status\":\"completed\",\"output\":[{\"type\":\"reasoning\"},{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"Hi\"}]}]}"))
        check(r32 == .success("Hi"), "NA32 OpenAI reply text", describe(r32))

        let r33a = NotesAI.replyText(.openAI, data: reply("{\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"max_output_tokens\"},\"output\":[]}"))
        let r33b = NotesAI.replyText(.openAI, data: reply("{\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"content_filter\"},\"output\":[]}"))
        let r33c = NotesAI.replyText(.openAI, data: reply("{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"refusal\",\"refusal\":\"no\"}]}]}"))
        let r33d = NotesAI.replyText(.openAI, data: reply("{\"status\":\"failed\",\"output\":[]}"))
        check(r33a == .failure(.truncated) && r33b == .failure(.refused) && r33c == .failure(.refused)
              && r33d == .failure(.server(0)), "NA33 OpenAI incomplete, filtered, refusal, failed",
              "\(describe(r33a)) \(describe(r33b)) \(describe(r33c)) \(describe(r33d))")

        // MARK: Validation

        let v40 = validate(goodJSON())
        if case .success(let s) = v40 {
            check(s.summary == "The team agreed." && s.summaryTimes == [4, 36]
                  && s.actionItems.map({ $0.owner }) == ["you", "s1", "", "Priya"]
                  && s.actionItems.map({ $0.time }) == [27, 48, 19, 36]
                  && s.decisions == [NoteSummary.Point(text: "Launch together", time: 4)]
                  && s.openQuestions == [NoteSummary.Point(text: "When is the demo?", time: 19)]
                  && s.parts == 1 && s.actionItems.allSatisfy({ !$0.done })
                  && s.provider == "Anthropic" && s.model == "claude-haiku-5-5",
                  "NA40 a good reply is validated and normalised", describe(s))
        } else {
            check(false, "NA40 a good reply is validated and normalised", describe(v40))
        }

        func firstActionTime(_ text: String) -> Double? {
            if case .success(let s) = validate(text) { return s.actionItems.first?.time }
            return nil
        }
        let times41 = [firstActionTime(goodJSON(actionTime: "26")), firstActionTime(goodJSON(actionTime: "13")),
                       firstActionTime(goodJSON(actionTime: "47")), firstActionTime(goodJSON(actionTime: "62"))]
        check(times41 == [27, 4, 48, 48], "NA41 times snap to the nearest turn start", describe(times41))

        let e42a = errorOf(validate(goodJSON(actionTime: "15")))
        let e42b = errorOf(validate(goodJSON(actionTime: "15", decisionTime: "63")))
        let e42c = errorOf(validate(goodJSON(summaryTimes: "[0]")))
        check(e42a == .badTimes(1) && e42b == .badTimes(2) && e42c == .badTimes(1), "NA42 times that match no turn",
              "\(describe(e42a)) \(describe(e42b)) \(describe(e42c))")

        let missingDecisions = "{\"summary\":\"S\",\"summary_times\":[],\"action_items\":[],\"open_questions\":[]}"
        let blankSummary = goodJSON().replacingOccurrences(of: "\" The team agreed. \"", with: "\"  \"")
        let stringTime = goodJSON(actionTime: "\"27\"")
        let boolTime = goodJSON(actionTime: "true")
        let blankTask = goodJSON().replacingOccurrences(of: "Cut the demo video", with: "")
        let e43 = [validate(missingDecisions), validate("Sure! Here are the notes"), validate(blankSummary),
                   validate(stringTime), validate(boolTime), validate(blankTask)].map { errorOf($0) }
        check(e43.allSatisfy { $0 == .malformed }, "NA43 malformed replies are refused", describe(e43))

        let fenced = validate("```json\n" + goodJSON() + "\n```")
        var fencedOK = false
        if case .success = fenced { fencedOK = true }
        check(fencedOK, "NA44 a fenced reply is accepted", describe(fenced))

        let snaps = [NotesAI.snap(25, turns: turns), NotesAI.snap(14, turns: turns), NotesAI.snap(16, turns: turns),
                     NotesAI.snap(1, turns: turns), NotesAI.snap(2, turns: turns)]
        check(snaps[0] == 27 && snaps[1] == 4 && snaps[2] == nil && snaps[3] == nil && snaps[4] == 4,
              "NA45 snap", describe(snaps))

        let idx = [NotesAI.turnIndex(for: 27, in: turns), NotesAI.turnIndex(for: 26, in: turns),
                   NotesAI.turnIndex(for: 99, in: turns)]
        check(idx[0] == 2 && idx[1] == 2 && idx[2] == nil, "NA46 turnIndex", describe(idx))

        let names = [NotesAI.ownerName("s1", speakers: speakers), NotesAI.ownerName("you", speakers: speakers),
                     NotesAI.ownerName("", speakers: speakers), NotesAI.ownerName("Priya", speakers: speakers)]
        check(names == ["Maya", "You", "No owner", "Priya"], "NA47 ownerName", describe(names))

        // MARK: Citations

        let a50 = NotesAI.parseAnswer("The post leads with privacy [36]. Maya drafts it [48, 0:19]. Unknown [99]. Not a cite [see above].", turns: turns)
        check(a50.segments == [.text("The post leads with privacy "), .cite(36), .text(". Maya drafts it "), .cite(48), .cite(19),
                               .text(". Unknown [99]. Not a cite [see above].")] && a50.times == [36, 48, 19],
              "NA50 citations are split out, unknown brackets stay text", describe(a50))

        let a51 = NotesAI.parseAnswer("Twice [36] and [36s] and [0:00:48]", turns: turns)
        check(a51.segments == [.text("Twice "), .cite(36), .text(" and "), .cite(36), .text(" and "), .cite(48)]
              && a51.times == [36, 48], "NA51 time forms and unique times", describe(a51))

        let a52 = NotesAI.parseAnswer("[26]", turns: turns)
        check(a52.segments == [.cite(27)] && a52.times == [27], "NA52 a cite snaps", describe(a52))

        let a53 = NotesAI.parseAnswer("No cites.", turns: turns)
        check(a53.segments == [.text("No cites.")] && a53.times.isEmpty, "NA53 no citations", describe(a53))

        let a54 = NotesAI.parseAnswer("[36, 99]", turns: turns)
        check(a54.segments == [.text("[36, 99]")] && a54.times.isEmpty, "NA54 one bad time keeps the bracket as text", describe(a54))

        // MARK: Streams

        let n60lines = [
            "event: message_start",
            "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"content\":[]}}",
            "",
            "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}",
            "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"hmm\"}}",
            "data: {\"type\":\"content_block_stop\",\"index\":0}",
            "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}",
            "event: ping",
            "data: {\"type\":\"ping\"}",
            anthropicDelta("The post"),
            "data:{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"text_delta\",\"text\":\" leads [36].\"}}",
            "data: {\"type\":\"content_block_stop\",\"index\":1}",
            "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":15}}",
            "data: {\"type\":\"message_stop\"}",
        ]
        var n60 = events(.anthropic, n60lines)
        check(n60.events == [.text("The post"), .text(" leads [36]."), .done] && n60.parser.text == "The post leads [36]."
              && n60.parser.end() == nil, "NA60 Anthropic stream", describe(n60.events))

        var n61 = events(.anthropic, [
            anthropicDelta("Partial"), "event: error",
            "data: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}",
            anthropicDelta("later"),
        ])
        check(n61.events == [.text("Partial"), .failed(.overloaded(retryAfter: nil))] && n61.parser.end() == nil,
              "NA61 Anthropic error mid-stream", describe(n61.events))

        let n62a = events(.anthropic, ["data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"refusal\"}}"])
        let n62b = events(.anthropic, ["data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"max_tokens\"}}"])
        check(n62a.events == [.failed(.refused)] && n62b.events == [.failed(.truncated)],
              "NA62 Anthropic refusal and cut-off stop reasons", "\(describe(n62a.events)) \(describe(n62b.events))")

        var n63 = events(.anthropic, [anthropicDelta("Cut")])
        let end1 = n63.parser.end()
        let end2 = n63.parser.end()
        check(end1 == .incomplete && end2 == nil, "NA63 a stream that stops early is incomplete", "\(describe(end1)) \(describe(end2))")

        let n64 = events(.openAI, [
            "event: response.created",
            "data: {\"type\":\"response.created\",\"response\":{\"status\":\"in_progress\"}}",
            "data: {\"type\":\"response.output_item.added\"}",
            openAIDelta("Hello"), openAIDelta(" [19]"),
            "data: {\"type\":\"response.output_text.done\",\"text\":\"Hello [19]\"}",
            "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}",
        ])
        check(n64.events == [.text("Hello"), .text(" [19]"), .done] && n64.parser.text == "Hello [19]",
              "NA64 OpenAI stream", describe(n64.events))

        let n65a = events(.openAI, [openAIDelta("Par"), "data: {\"type\":\"error\",\"code\":\"server_is_overloaded\",\"message\":\"busy\"}"])
        let n65b = events(.openAI, ["data: {\"type\":\"error\",\"error\":{\"code\":\"insufficient_quota\"}}"])
        check(n65a.events == [.text("Par"), .failed(.overloaded(retryAfter: nil))] && n65b.events == [.failed(.spendCap)],
              "NA65 OpenAI error events", "\(describe(n65a.events)) \(describe(n65b.events))")

        let n66a = events(.openAI, ["data: {\"type\":\"response.incomplete\",\"response\":{\"incomplete_details\":{\"reason\":\"max_output_tokens\"}}}"])
        let n66b = events(.openAI, ["data: {\"type\":\"response.completed\",\"response\":{\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"content_filter\"}}}"])
        check(n66a.events == [.failed(.truncated)] && n66b.events == [.failed(.refused)],
              "NA66 OpenAI incomplete responses", "\(describe(n66a.events)) \(describe(n66b.events))")

        let n67a = events(.openAI, ["data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}", "data: [DONE]"])
        let n67b = events(.openAI, ["data: [DONE]"])
        check(n67a.events == [.done] && n67b.events == [.failed(.incomplete)],
              "NA67 DONE marker", "\(describe(n67a.events)) \(describe(n67b.events))")

        let n68 = events(.openAI, ["data: {\"type\":\"response.refusal.delta\",\"delta\":\"no\"}"])
        check(n68.events == [.failed(.refused)], "NA68 OpenAI refusal delta", describe(n68.events))

        // MARK: Errors and retries

        func classify(_ status: Int, _ headers: [String: String] = [:], _ body: String?, _ provider: NotesProvider = .anthropic) -> NotesAIError {
            NotesAI.classify(status: status, headers: headers, body: body.flatMap { $0.data(using: .utf8) },
                             provider: provider, now: fixedNow)
        }
        let c70 = classify(401, [:], "{\"type\":\"error\",\"error\":{\"type\":\"authentication_error\",\"message\":\"invalid x-api-key\"}}")
        check(c70 == .badKey, "NA70 401 is a bad key", describe(c70))

        let c71 = classify(429, ["Retry-After": "17"], "{\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"message\":\"x\"}}")
        check(c71 == .rateLimited(retryAfter: 17), "NA71 429 honours Retry-After", describe(c71))

        let c72 = classify(429, [:], "{\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"message\":\"x\",\"details\":{\"error_code\":\"enforced_spend_limit_reached\"}}}")
        check(c72 == .spendCap, "NA72 a spend limit is not a rate limit", describe(c72))

        let c73 = classify(529, [:], nil)
        let c74 = classify(429, [:], "{\"error\":{\"code\":\"insufficient_quota\",\"type\":\"insufficient_quota\",\"message\":\"m\"}}", .openAI)
        check(c73 == .overloaded(retryAfter: nil) && c74 == .spendCap, "NA73 529 is overloaded; NA74 OpenAI quota is a spend cap",
              "\(describe(c73)) \(describe(c74))")

        let c75 = classify(429, ["retry-after": "3"], "{\"error\":{\"code\":\"rate_limit_exceeded\"}}", .openAI)
        check(c75 == .rateLimited(retryAfter: 3), "NA75 OpenAI rate limit", describe(c75))

        let c76 = [classify(503, [:], nil), classify(500, [:], nil), classify(404, [:], nil),
                   classify(400, [:], "{\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"Your credit balance is too low to access the API\"}}"),
                   classify(400, [:], "{\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"bad field\"}}"),
                   classify(413, [:], nil)]
        check(c76 == [.overloaded(retryAfter: nil), .server(500), .modelUnavailable, .spendCap, .request(400), .request(413)],
              "NA76 other statuses", describe(c76))

        let u77 = [NotesAI.classify(urlError: URLError(.notConnectedToInternet)), NotesAI.classify(urlError: URLError(.timedOut)),
                   NotesAI.classify(urlError: URLError(.cannotFindHost))]
        check(u77 == [.offline, .timedOut, .offline], "NA77 URL errors", describe(u77))

        let gmt = DateFormatter()
        gmt.locale = Locale(identifier: "en_US_POSIX")
        gmt.timeZone = TimeZone(identifier: "GMT")
        gmt.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let httpDate = gmt.string(from: fixedNow.addingTimeInterval(120))
        let ra = [NotesAI.retryAfter("0", now: fixedNow), NotesAI.retryAfter("9999", now: fixedNow),
                  NotesAI.retryAfter("garbage", now: fixedNow), NotesAI.retryAfter(nil, now: fixedNow),
                  NotesAI.retryAfter("2.5", now: fixedNow), NotesAI.retryAfter(httpDate, now: fixedNow)]
        check(ra[0] == 1 && ra[1] == 600 && ra[2] == nil && ra[3] == nil && ra[4] == 2.5 && ra[5] == 120,
              "NA78 retryAfter", describe(ra))

        let w = [NotesAI.autoRetryWait(.rateLimited(retryAfter: 10), attempt: 0), NotesAI.autoRetryWait(.rateLimited(retryAfter: 45), attempt: 0),
                 NotesAI.autoRetryWait(.rateLimited(retryAfter: nil), attempt: 0), NotesAI.autoRetryWait(.overloaded(retryAfter: 2), attempt: 0),
                 NotesAI.autoRetryWait(.server(500), attempt: 0), NotesAI.autoRetryWait(.rateLimited(retryAfter: 10), attempt: 1)]
        let never: [NotesAIError] = [.badKey, .spendCap, .refused, .offline, .timedOut, .truncated]
        check(w[0] == 10 && w[1] == nil && w[2] == 4 && w[3] == 2 && w[4] == 4 && w[5] == nil
              && never.allSatisfy { NotesAI.autoRetryWait($0, attempt: 0) == nil },
              "NA79 autoRetryWait", describe(w))

        check(NotesAI.retryNotBefore(.rateLimited(retryAfter: 30), now: fixedNow) == fixedNow.addingTimeInterval(30)
              && NotesAI.retryNotBefore(.badKey, now: fixedNow) == nil, "NA80 retryNotBefore")

        let all: [NotesAIError] = [.noKey, .badKey, .rateLimited(retryAfter: nil), .rateLimited(retryAfter: 2.2), .spendCap,
                                   .overloaded(retryAfter: nil), .overloaded(retryAfter: 5), .server(0), .server(500), .offline,
                                   .timedOut, .refused, .truncated, .incomplete, .malformed, .badTimes(1), .badTimes(2),
                                   .modelUnavailable, .request(413), .request(400), .tooLong(hours: 34)]
        var messageProblem = ""
        for error in all {
            for provider in [NotesProvider.anthropic, .openAI] {
                let m = error.message(provider, model: nil)
                if m.isEmpty || m.unicodeScalars.contains(where: { $0.value > 0x7E || ($0.value < 0x20) }) || m.contains("\u{2014}") {
                    messageProblem = error.category
                }
            }
        }
        let bt1 = NotesAIError.badTimes(1).message(.anthropic, model: nil)
        let bt2 = NotesAIError.badTimes(2).message(.anthropic, model: nil)
        check(messageProblem.isEmpty && bt1.contains("1 transcript time that") && bt2.contains("2 transcript times"),
              "NA81 every message is plain ASCII, with the right plural", messageProblem.isEmpty ? "\(bt1) | \(bt2)" : messageProblem)

        let d82 = NotesAI.disclosure(provider: "Anthropic", modelID: "claude-haiku-5-5")
        check(d82 == "Written by Claude Haiku 5.5 with your key. The transcript was sent to Anthropic. The audio never left this Mac.",
              "NA82 disclosure line", d82)

        // NA90 "Write again" keeps a tick only for an item with the same owner and task.
        func item(_ owner: String, _ task: String, _ done: Bool) -> NoteSummary.ActionItem {
            NoteSummary.ActionItem(owner: owner, task: task, time: 1, done: done)
        }
        func summaryWith(_ items: [NoteSummary.ActionItem]) -> NoteSummary {
            NoteSummary(summary: "S.", summaryTimes: [], actionItems: items, decisions: [], openQuestions: [],
                        provider: "Anthropic", model: "claude-haiku-5-5", written: fixedNow, parts: 1)
        }
        let oldS = summaryWith([item("you", "A", true), item("s1", "B", false), item("s2", "C", true)])
        let newS = summaryWith([item("you", "A", false), item("s1", "B", false), item("s2", "C changed", false), item("s3", "A", false)])
        let carried = NotesAI.carryingDone(from: oldS, into: newS)
        check(carried.actionItems.map { $0.done } == [true, false, false, false]
                && carried.actionItems.map { $0.task } == newS.actionItems.map { $0.task }
                && NotesAI.carryingDone(from: nil, into: newS) == newS,
              "NA90 carryingDone", describe(carried.actionItems.map { $0.done }))

        // NA91 the cost hint shows only past the price step, and is plain ASCII.
        let shortLines = (0..<10).map { _ in "[0:04] You: Okay." }
        let longLines = [String(repeating: "a", count: 260_000)]
        let hint = NotesAI.askCostHint(lines: longLines)
        check(NotesAI.askCostHint(lines: shortLines) == nil
                && hint == "This is a long meeting, so each question costs more than usual."
                && (hint ?? "").unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7F },
              "NA91 askCostHint", hint ?? "nil")
    }
}
