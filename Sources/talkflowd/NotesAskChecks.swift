import Foundation

/// The offline checks for `--notesasktest` (called from NotesSelfTest, labels AK..): the argument parser, speaker
/// labels and names, score.py's summary shape and both scores, and the run itself driven by canned replies. No
/// network, no Keychain, no live client; every file lives in a temporary folder that is removed afterwards. The
/// meeting, truth and answers are made up here, none of it comes from a fixture except AK15, which only runs when
/// the fake meeting's truth.json is on this Mac.
enum NotesAskChecks {
    // MARK: Made-up data

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
    private static let answerText = "Lead with privacy [36]."

    private static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private static var goodReply: CannedNotesTransport.Reply {
        .http(status: 200, headers: [:], body: json(["content": [["type": "text", "text": good]], "stop_reason": "end_turn"]))
    }

    private static var badKeyReply: CannedNotesTransport.Reply {
        .http(status: 401, headers: [:], body: #"{"type":"error","error":{"type":"authentication_error","message":"x"}}"#)
    }

    private static func streamReply(_ text: String) -> CannedNotesTransport.Reply {
        .stream(status: 200, lines: [
            "data: " + json(["type": "message_start", "message": ["id": "m"]]),
            "data: " + json(["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": text]]),
            "data: " + json(["type": "message_delta", "delta": ["stop_reason": "end_turn"]]),
            "data: " + json(["type": "message_stop"]),
        ])
    }

    private static func truthQuestions(_ count: Int) -> [NotesAskRun.TruthQuestion] {
        (1...count).map {
            NotesAskRun.TruthQuestion(id: "T\($0)", question: "Question number \($0)?", answer: "Privacy comes first.",
                                      evidence: [30...40])
        }
    }

    /// One run through perform with canned replies; returns the output and how many requests the transport saw.
    private static func perform(_ replies: [CannedNotesTransport.Reply], mode: NotesAskRun.Mode,
                                truth: [NotesAskRun.TruthQuestion] = []) -> (out: NotesAskRun.Output, requests: Int)? {
        let transport = CannedNotesTransport(replies)
        let client = NotesAIClient(transport: transport, keyFor: { _ in "k-test" })
        client.sleep = { _, body in body() }
        client.jitter = { 0 }
        guard let access = NotesAccess.resolve(switchOn: true, hasAnthropic: { true }, hasOpenAI: { false },
                                               anthropicModel: nil, openAIModel: nil) else { return nil }
        let out = NotesAskRun.perform(client: client, access: access, transcript: transcript, speakers: speakers,
                                      mode: mode, truth: truth, timeout: 10)
        return (out, transport.requests.count)
    }

    private static func args(_ a: [String]) -> NotesAskRun.Args? {
        if case .success(let parsed) = NotesAskRun.parse(a) { return parsed }
        return nil
    }

    private static func tempFolder() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("talkflow-notestest-ask-\(UUID().uuidString)")
    }

    // MARK: Checks

    static func run(_ check: (Bool, String, String) -> Void) {
        parseChecks(check)
        speakerChecks(check)
        summaryScoreChecks(check)
        questionScoreChecks(check)
        runChecks(check)
    }

    private static func parseChecks(_ check: (Bool, String, String) -> Void) {
        let a1 = args(["t.json"])
        check(a1 == NotesAskRun.Args(transcript: "t.json", mode: .summary, provider: nil, model: nil, speakerMap: nil,
                                     out: nil, scoreOut: nil),
              "AK01 bare transcript is a summary", "\(String(describing: a1))")

        let a2 = args(["t.json", "summary", "openai"])
        check(a2?.mode == .summary && a2?.provider == .openAI, "AK02 provider word", "\(String(describing: a2))")

        let a3 = args(["t.json", "ask", "What?"])
        check(a3?.mode == .ask("What?"), "AK03 ask", "\(String(describing: a3))")

        let a4 = args(["t.json", "questions", "truth.json", "--speakers", "n.json", "--provider", "anthropic",
                       "--out", "o.json", "--score-out", "s.json"])
        check(a4?.mode == .questions(truth: "truth.json") && a4?.speakerMap == "n.json" && a4?.provider == .anthropic
                && a4?.out == "o.json" && a4?.scoreOut == "s.json",
              "AK04 questions with every flag", "\(String(describing: a4))")

        let a5 = args(["t.json", "--model", "claude-sonnet-5-5"])
        check(a5?.model == .claudeSonnet && a5?.provider == .anthropic, "AK05 model sets provider", "\(String(describing: a5))")

        let bad: [[String]] = [
            [], ["--out", "x"], ["t.json", "ask"], ["t.json", "ask", ""], ["t.json", "questions"],
            ["t.json", "--model", "gpt-9"], ["t.json", "--model", "gpt-6-luna", "--provider", "anthropic"],
            ["t.json", "--speakers"], ["t.json", "--speakers", "--out", "x"], ["t.json", "bogus"],
            ["t.json", "openai", "--provider", "anthropic"], ["t.json", "--bogus"],
        ]
        let notRejected = bad.filter { if case .failure = NotesAskRun.parse($0) { return false } else { return true } }
        check(notRejected.isEmpty, "AK06 bad arguments are rejected", "accepted \(notRejected)")
    }

    private static func speakerChecks(_ check: (Bool, String, String) -> Void) {
        let labels: [(String, String)] = [
            ("You", "you"), ("you", "you"), ("Speaker 3", "s3"), ("speaker 12", "s12"), ("s2", "s2"),
            (" Speaker 4 ", "s4"), ("Speaker 0", "Speaker 0"), ("Bob", "Bob"),
        ]
        let wrong = labels.filter { NotesAskRun.key(forLabel: $0.0) != $0.1 }.map { "\($0.0)->\(NotesAskRun.key(forLabel: $0.0))" }
        check(wrong.isEmpty, "AK07 speaker labels become keys", "wrong \(wrong)")

        let file = #"{"turns":[{"speaker":"You","start":0,"end":2,"text":"a"},{"speaker":"Speaker 2","start":3,"end":4,"text":"b"}]}"#
        let read = NotesAskRun.readTranscript(Data(file.utf8))
        check(read?.0.turns.map(\.speaker) == ["you", "s2"] && read?.1.map(\.key) == ["you", "s2"]
                && read?.1.allSatisfy({ $0.name == nil }) == true
                && NotesAskRun.readTranscript(Data(#"{"turns":[]}"#.utf8)) == nil
                && NotesAskRun.readTranscript(Data("not json".utf8)) == nil,
              "AK08 transcript file is read", "\(String(describing: read?.1))")

        let base = [NoteSpeaker(key: "you"), NoteSpeaker(key: "s1"), NoteSpeaker(key: "s2")]
        let r = NotesAskRun.applyNames(["You": "Samir", "Speaker 1": "Bob", "s2": "Emily", "Speaker 9": "Zed",
                                        "Speaker 1 ": "  "], to: base)
        check(r.applied == 2 && r.ignored == 3 && r.speakers.first { $0.key == "s1" }?.name == "Bob"
                && r.speakers.first { $0.key == "s2" }?.name == "Emily" && r.speakers.first { $0.key == "you" }?.name == nil,
              "AK09 names applied", "applied \(r.applied) ignored \(r.ignored)")
    }

    private static func summaryScoreChecks(_ check: (Bool, String, String) -> Void) {
        let sp = [NoteSpeaker(key: "you"), NoteSpeaker(key: "s1", name: "Bob"), NoteSpeaker(key: "s2", name: "Emily")]
        let summary = NoteSummary(
            summary: "x", summaryTimes: [],
            actionItems: [("you", "Write the draft"), ("s2", "Send contract"), ("Priya", "Review"), ("", "Book room")].map {
                NoteSummary.ActionItem(owner: $0.0, task: $0.1, time: 0, done: false)
            },
            decisions: [NoteSummary.Point(text: "Launch moves", time: 4)], openQuestions: [],
            provider: "Anthropic", model: "m", written: Date(timeIntervalSince1970: 0), parts: 1)
        let sf = NotesAskRun.scoreFormat(summary, speakers: sp)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let text = (try? encoder.encode(sf)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let want = #"{"action_items":[{"owner":"You","task":"Write the draft"},{"owner":"Emily","task":"Send contract"},{"owner":"Priya","task":"Review"},{"owner":"","task":"Book room"}],"decisions":["Launch moves"]}"#
        check(sf.action_items.map { "\($0.owner)|\($0.task)" }
                == ["You|Write the draft", "Emily|Send contract", "Priya|Review", "|Book room"]
                && sf.decisions == ["Launch moves"] && text == want,
              "AK10 score.py summary shape", text)

        let truth = Data(#"{"action_items":[{"owner":"dave","keywords":["release plan"]},{"owner":"emily","keywords":["contract","vendor"]}],"decisions":[{"keywords":["garden","friday"]},{"keywords":["annual pass","forty-nine"]}]}"#.utf8)
        let pred = NotesAskRun.ScoreSummary(
            action_items: [.init(owner: "Dave", task: "Update the release plan"),
                           .init(owner: "Speaker 3", task: "Send the contract to the vendor"),
                           .init(owner: "You", task: "Order snacks")],
            decisions: ["Annual passes cost 49 dollars", "Newsletter goes out on Friday"])
        let s = NotesAskRun.summaryScore(pred, truthData: truth)
        check(s == NotesAskRun.SummaryScore(actionsMatched: 2, actionsPredicted: 3, actionsTruth: 2, ownersRight: 1,
                                            decisionsMatched: 2, decisionsPredicted: 2, decisionsTruth: 2),
              "AK11 summary score", "\(String(describing: s))")
        check(NotesAskRun.keywordHits("Annual passes cost 49 dollars", ["annual pass", "forty-nine"]) == 2,
              "AK12 digits meet spelled numbers", "")
        let owners = [("You", "samir"), ("me", "samir"), ("Dave Smith", "dave"), ("Speaker 3", "speaker"), ("", "")]
        check(owners.allSatisfy { NotesAskRun.normOwner($0.0) == $0.1 }, "AK13 owner names",
              "\(owners.map { NotesAskRun.normOwner($0.0) })")
        check(NotesAskRun.summaryScore(pred, truthData: Data("{}".utf8)) == nil, "AK14 truth without items", "")

        fixtureCheck(check)
    }

    /// AK15: the real fake meeting's truth, scored against a summary built from it, when it is on this Mac. Only
    /// counts are reported; nothing from the file is printed.
    private static func fixtureCheck(_ check: (Bool, String, String) -> Void) {
        let path = NSHomeDirectory() + "/Library/Application Support/talkflow/test-fixtures/fakemeeting/truth.json"
        guard let data = FileManager.default.contents(atPath: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            check(true, "AK15 fixture absent, skipped", "")
            return
        }
        func items(_ key: String) -> [[String: Any]] { (object[key] as? [[String: Any]]) ?? [] }
        func text(_ item: [String: Any], _ keys: [String]) -> String {
            for k in keys { if let v = item[k] as? String, !v.isEmpty { return v } }
            return ((item["keywords"] as? [String]) ?? []).joined(separator: " ")
        }
        let perfect = NotesAskRun.ScoreSummary(
            action_items: items("action_items").map { .init(owner: ($0["owner"] as? String) ?? "", task: text($0, ["task", "text"])) },
            decisions: items("decisions").map { text($0, ["text", "decision"]) })
        let s = NotesAskRun.summaryScore(perfect, truthData: data)
        let q = NotesAskRun.truthQuestions(data)
        check(s?.actionsMatched == 6 && s?.actionsTruth == 6 && s?.ownersRight == 6 && s?.decisionsMatched == 5
                && s?.decisionsTruth == 5 && q?.count == 5 && q?.allSatisfy({ !$0.evidence.isEmpty }) == true,
              "AK15 fixture truth scores itself perfectly",
              "\(String(describing: s)) questions \(q?.count ?? -1)")
    }

    private static func questionScoreChecks(_ check: (Bool, String, String) -> Void) {
        let tq = NotesAskRun.TruthQuestion(
            id: "K", question: "How many signed up?",
            answer: "2,400. The 4,200 said first was app downloads, corrected by Lucia.", evidence: [40...50, 370...375])
        check(NotesAskRun.numbers(in: tq.answer) == [2400, 4200]
                && NotesAskRun.contentWords(tq.answer) == ["app", "downloads", "corrected", "lucia"],
              "AK16 numbers and content words",
              "\(NotesAskRun.numbers(in: tq.answer)) \(NotesAskRun.contentWords(tq.answer))")

        let full = "About 2,400 people signed up; the 4,200 figure was app downloads (Lucia corrected it)."
        let s17 = NotesAskRun.scoreAnswer(full, citations: [371], truth: tq)
        check(s17.leadNumber == true && s17.numbersFound == 2 && s17.numbers == 2 && s17.wordRecall == 1.0
                && s17.cited && s17.correct, "AK17 a right answer", "\(s17)")

        let s18 = NotesAskRun.scoreAnswer("4,200 people signed up.", citations: [10], truth: tq)
        check(s18.leadNumber == false && s18.numbersFound == 1 && s18.numbers == 2 && s18.wordRecall == 0.0
                && !s18.cited && !s18.correct, "AK18 the wrong number leads", "\(s18)")

        let s19 = NotesAskRun.scoreAnswer("", citations: [], truth: tq)
        let s19b = NotesAskRun.scoreAnswer(full, citations: [38.5], truth: tq)
        check(s19.leadNumber == false && s19.numbersFound == 0 && s19.wordRecall == 0 && !s19.cited && !s19.correct
                && s19b.cited, "AK19 empty answer, and 2 s slack on a citation", "\(s19) \(s19b)")

        let tn = NotesAskRun.TruthQuestion(id: "N", question: "Why?", answer: "The payment provider takes a cut of every tip.",
                                           evidence: [100...110])
        let s20 = NotesAskRun.scoreAnswer("Because the provider charges a cut on each tip.", citations: [112], truth: tn)
        check(s20.leadNumber == nil && s20.numbers == 0 && s20.wordRecall == 0.6 && s20.cited && s20.correct,
              "AK20 truth answer without numbers", "\(s20)")

        let qs = Data(#"{"utterances":[{"id":"u1","start":1,"end":2},{"id":"u2","start":5,"end":7}],"ask_questions":[{"id":"Q1","question":"a","answer":"b","evidence":["u1"]},{"id":"Q2","question":"a","answer":"b","evidence":["u2","nope"]},{"id":"Q3","question":"a","answer":"b","evidence":["u1"]},{"id":"Q4","question":"a","answer":"b","evidence":["u1"]},{"id":"Q5","question":"a","answer":"b","evidence":["u1"]},{"id":"Q6","question":"a","answer":"b","evidence":["u1"]}]}"#.utf8)
        let read = NotesAskRun.truthQuestions(qs)
        check(read?.count == 5 && read?.first?.evidence == [1...2] && read?[1].evidence == [5...7]
                && NotesAskRun.truthQuestions(Data("{}".utf8)) == nil,
              "AK21 truth questions", "\(String(describing: read?.count))")
    }

    private static func runChecks(_ check: (Bool, String, String) -> Void) {
        // AK22 summary mode: one request, the cheapest model, the score.py shape filled in.
        if let r = perform([goodReply], mode: .summary) {
            check(r.requests == 1 && r.out.ok && r.out.calls == 1 && r.out.mode == "summary"
                    && r.out.model == "claude-haiku-5-5" && r.out.scoreSummary?.action_items.count == r.out.summary?.actionItems.count
                    && r.out.summary?.actionItems.count == 4,
                  "AK22 summary mode", "requests \(r.requests) ok \(r.out.ok) calls \(r.out.calls) model \(r.out.model)")
        } else {
            check(false, "AK22 summary mode", "no access")
        }

        // AK23 questions mode: one summary, then five questions each on its own.
        let five = [goodReply] + (1...5).map { _ in streamReply(answerText) }
        var full: NotesAskRun.Output?
        if let r = perform(five, mode: .questions(truth: "unused"), truth: truthQuestions(5)) {
            full = r.out
            check(r.requests == 6 && r.out.calls == 6 && r.out.answers?.count == 5
                    && r.out.answers?.allSatisfy({ $0.ok && !($0.citations ?? []).isEmpty }) == true
                    && r.out.questionsCited == 5 && r.out.ok,
                  "AK23 questions mode", "requests \(r.requests) calls \(r.out.calls) answers \(r.out.answers?.count ?? -1) cited \(r.out.questionsCited ?? -1)")
        } else {
            check(false, "AK23 questions mode", "no access")
        }

        // AK24 more truth questions than five: still one summary and five asks.
        if let r = perform(five, mode: .questions(truth: "unused"), truth: truthQuestions(7)) {
            check(r.requests == 6 && r.out.answers?.count == 5, "AK24 at most five questions",
                  "requests \(r.requests) answers \(r.out.answers?.count ?? -1)")
        } else {
            check(false, "AK24 at most five questions", "no access")
        }

        // AK25 a failed summary does not stop the questions, and the failure is what is reported.
        let failedFirst = [badKeyReply] + (1...5).map { _ in streamReply(answerText) }
        if let r = perform(failedFirst, mode: .questions(truth: "unused"), truth: truthQuestions(5)) {
            check(!r.out.ok && r.out.error?.category == NotesAIError.badKey.category && r.requests == 6
                    && r.out.answers?.count == 5,
                  "AK25 summary failure keeps asking", "ok \(r.out.ok) error \(r.out.error?.category ?? "none") requests \(r.requests)")
        } else {
            check(false, "AK25 summary failure keeps asking", "no access")
        }

        // AK26 ask mode.
        if let r = perform([streamReply(answerText)], mode: .ask("What about privacy?")) {
            check(r.requests == 1 && r.out.ok && r.out.question == "What about privacy?" && !(r.out.answer ?? "").isEmpty
                    && r.out.answers == nil,
                  "AK26 ask mode", "requests \(r.requests) ok \(r.out.ok)")
        } else {
            check(false, "AK26 ask mode", "no access")
        }

        guard let full else {
            check(false, "AK27 result files", "no questions output")
            check(false, "AK28 printed lines hold no text", "no questions output")
            return
        }
        fileChecks(full, check)
        lineChecks(full, check)
    }

    private static func fileChecks(_ out: NotesAskRun.Output, _ check: (Bool, String, String) -> Void) {
        let folder = tempFolder()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let resultURL = folder.appendingPathComponent("result.json")
        let scoreURL = folder.appendingPathComponent("score.json")
        let wrote = NotesAskTest.write(out, to: resultURL, scoreTo: scoreURL)
        let result = (try? Data(contentsOf: resultURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let answers = result?["answers"] as? [[String: Any]]
        let score = (try? Data(contentsOf: scoreURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let keysOK = ["mode", "provider", "model", "ok", "calls", "answers"].allSatisfy { result?[$0] != nil }
        let answersOK = answers?.count == 5
            && answers?.allSatisfy({ $0["question"] != nil && $0["answer"] != nil && $0["citations"] != nil && $0["score"] != nil }) == true
        let scoreOK = (score?["action_items"] as? [Any]) != nil && (score?["decisions"] as? [Any]) != nil
        check(wrote && keysOK && answersOK && scoreOK, "AK27 result files",
              "wrote \(wrote) keys \(keysOK) answers \(answersOK) score \(scoreOK)")
        try? FileManager.default.removeItem(at: folder)
        check(!FileManager.default.fileExists(atPath: folder.path), "AK27 temp folder removed", folder.path)
    }

    private static func lineChecks(_ out: NotesAskRun.Output, _ check: (Bool, String, String) -> Void) {
        let lines = NotesAskRun.lines(out)
        var secrets = turns.map(\.text) + [answerText, "Lead with privacy"]
        if let s = out.summary {
            secrets += [s.summary] + s.actionItems.map(\.task) + s.decisions.map(\.text) + s.openQuestions.map(\.text)
        }
        let leaked = secrets.filter { secret in lines.contains { $0.contains(secret) } }
        check(leaked.isEmpty && lines.contains { $0.hasPrefix("notesasktest: questions ") },
              "AK28 printed lines hold no text", "lines \(lines.count) leaked \(leaked.count)")
    }
}
