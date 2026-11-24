import Foundation

/// Part of `--notestest` (called from NotesSelfTest). Canned replies only: no network, no Keychain, and no real
/// waiting (the retry sleep is replaced by a recorder).
enum NotesAIClientSelfTest {
    private final class Recorder {
        var waits: [Double] = []
        var progress: [[Int]] = []
    }

    private static let you = "you"
    private static let speakers = [NoteSpeaker(key: "you"), NoteSpeaker(key: "s1", name: "Maya"), NoteSpeaker(key: "s2")]
    private static let turns = [
        TranscriptTurn(speaker: "you", start: 4, end: 12, text: "Okay, the launch order."),
        TranscriptTurn(speaker: "s1", start: 19, end: 26, text: "Demo video?"),
        TranscriptTurn(speaker: "you", start: 27, end: 35, text: "Still a recording."),
        TranscriptTurn(speaker: "s2", start: 36, end: 47, text: "Lead with privacy."),
        TranscriptTurn(speaker: "s1", start: 48, end: 60, text: "I'll draft it tonight."),
    ]

    private static let good = """
    {"summary":" The team agreed. ","summary_times":[4,36,36],"action_items":[{"owner":"You","task":"Cut the demo video","time":27},{"owner":"maya","task":"Draft the post","time":48},{"owner":"","task":"Book a room","time":19},{"owner":"Priya","task":"Review","time":36}],"decisions":[{"text":"Launch together","time":4}],"open_questions":[{"text":"When is the demo?","time":19}]}
    """

    private static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// An Anthropic Messages reply carrying `text`.
    private static func anth(_ text: String, stop: String = "end_turn") -> String {
        json(["content": [["type": "text", "text": text]], "stop_reason": stop])
    }

    private static func anthLines(_ chunks: [String]) -> [String] {
        var lines = ["data: " + json(["type": "message_start", "message": ["id": "m"]])]
        for chunk in chunks {
            lines.append("data: " + json(["type": "content_block_delta", "index": 0,
                                          "delta": ["type": "text_delta", "text": chunk]]))
        }
        lines.append("data: " + json(["type": "message_delta", "delta": ["stop_reason": "end_turn"]]))
        lines.append("data: " + json(["type": "message_stop"]))
        return lines
    }

    private static let overloadedEvent = "data: " + #"{"type":"error","error":{"type":"overloaded_error","message":"x"}}"#

    private static func access(openAI: Bool = false) -> NotesAccess? {
        NotesAccess.resolve(switchOn: true, hasAnthropic: { !openAI }, hasOpenAI: { openAI },
                            anthropicModel: nil, openAIModel: nil)
    }

    private static func client(_ replies: [CannedNotesTransport.Reply], key: String? = "k-test")
        -> (NotesAIClient, CannedNotesTransport, Recorder) {
        let transport = CannedNotesTransport(replies)
        let recorder = Recorder()
        let client = NotesAIClient(transport: transport, keyFor: { _ in key })
        client.sleep = { seconds, body in
            recorder.waits.append(seconds)
            body()
        }
        client.jitter = { 0 }
        return (client, transport, recorder)
    }

    /// Spins the main run loop until `done` or the deadline.
    private static func spin(_ seconds: Double, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    private static func summary(_ replies: [CannedNotesTransport.Reply], turns: [TranscriptTurn] = turns,
                                speakers: [NoteSpeaker] = speakers, key: String? = "k-test")
        -> (Result<NoteSummary, NotesAIError>?, CannedNotesTransport, Recorder) {
        let (client, transport, recorder) = client(replies, key: key)
        var result: Result<NoteSummary, NotesAIError>?
        client.writeSummary(access: access()!, transcript: Transcript(turns: turns), speakers: speakers,
                            progress: { recorder.progress.append([$0, $1]) },
                            completion: { result = $0 })
        spin(5) { result != nil }
        return (result, transport, recorder)
    }

    private static func ask(_ replies: [CannedNotesTransport.Reply], openAI: Bool = false, key: String? = "k-test",
                            question: String = "What next?")
        -> (Result<NoteQuestions.Entry, NotesAIError>?, [String], CannedNotesTransport, Recorder) {
        let (client, transport, recorder) = client(replies, key: key)
        var result: Result<NoteQuestions.Entry, NotesAIError>?
        var texts: [String] = []
        client.ask(access: access(openAI: openAI)!, transcript: Transcript(turns: turns), speakers: speakers,
                   history: [], question: question, onText: { texts.append($0) }, completion: { result = $0 })
        spin(5) { result != nil }
        return (result, texts, transport, recorder)
    }

    private static func failure<T>(_ result: Result<T, NotesAIError>?) -> NotesAIError? {
        if case .failure(let error)? = result { return error }
        return nil
    }

    private static func success<T>(_ result: Result<T, NotesAIError>?) -> T? {
        if case .success(let value)? = result { return value }
        return nil
    }

    static func run(check: (Bool, String, String) -> Void) {
        // NC01 one request, one summary.
        let (r1, t1, p1) = summary([.http(status: 200, headers: [:], body: anth(good))])
        let s1 = success(r1)
        check(s1?.actionItems.count == 4 && s1?.parts == 1 && t1.requests.count == 1 && p1.progress == [[1, 1]],
              "NC01 single summary", "\(String(describing: r1)) requests \(t1.requests.count) progress \(p1.progress)")

        // NC02 a short rate limit is retried once.
        let limited = CannedNotesTransport.Reply.http(status: 429, headers: ["Retry-After": "1"],
                                                      body: #"{"type":"error","error":{"type":"rate_limit_error","message":"x"}}"#)
        let (r2, t2, p2) = summary([limited, .http(status: 200, headers: [:], body: anth(good))])
        check(success(r2) != nil && p2.waits == [1.0] && t2.requests.count == 2,
              "NC02 429 then success", "waits \(p2.waits) requests \(t2.requests.count)")

        // NC03 never more than one retry.
        let (r3, t3, _) = summary([limited, limited])
        check(failure(r3) == .rateLimited(retryAfter: 1) && t3.requests.count == 2,
              "NC03 429 twice gives up", "\(String(describing: failure(r3))) requests \(t3.requests.count)")

        // NC04 a spend cap is not retried.
        let capped = CannedNotesTransport.Reply.http(
            status: 429, headers: [:],
            body: #"{"type":"error","error":{"type":"rate_limit_error","message":"x","details":{"error_code":"enforced_spend_limit_reached"}}}"#)
        let (r4, t4, p4) = summary([capped])
        check(failure(r4) == .spendCap && t4.requests.count == 1 && p4.waits.isEmpty,
              "NC04 spend cap", "\(String(describing: failure(r4))) requests \(t4.requests.count) waits \(p4.waits)")

        // NC05 a long meeting is written in three parts, then combined.
        let big = { (letter: String) in String(repeating: letter, count: 150_000) }
        let longTurns = [TranscriptTurn(speaker: "you", start: 0, end: 50, text: big("a")),
                         TranscriptTurn(speaker: "s1", start: 100, end: 150, text: big("b")),
                         TranscriptTurn(speaker: "you", start: 200, end: 250, text: big("c"))]
        func part(_ time: Int) -> CannedNotesTransport.Reply {
            .http(status: 200, headers: [:], body: anth(json(["summary": "Part.", "summary_times": [time], "action_items": [Any](),
                                                              "decisions": [Any](), "open_questions": [Any]()])))
        }
        let combined = CannedNotesTransport.Reply.http(
            status: 200, headers: [:],
            body: anth(#"{"summary":"All.","summary_times":[0,200],"action_items":[],"decisions":[],"open_questions":[]}"#))
        let (r5, t5, p5) = summary([part(0), part(100), part(200), combined], turns: longTurns,
                                   speakers: [NoteSpeaker(key: "you"), NoteSpeaker(key: "s1")])
        var combineSystem = ""
        if t5.requests.count == 4, let body = t5.requests[3].httpBody,
           let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let system = object["system"] as? [[String: Any]] {
            combineSystem = system.first?["text"] as? String ?? ""
        }
        check(success(r5)?.parts == 3 && t5.requests.count == 4 && p5.progress == [[1, 3], [2, 3], [3, 3], [4, 3]]
              && combineSystem == NotesAI.combineRules,
              "NC05 long meeting in parts", "\(String(describing: failure(r5))) requests \(t5.requests.count) progress \(p5.progress)")

        // NC06 a refusal is reported, not retried.
        let (r6, t6, _) = summary([.http(status: 200, headers: [:], body: anth("", stop: "refusal"))])
        check(failure(r6) == .refused && t6.requests.count == 1, "NC06 refusal", "\(String(describing: failure(r6)))")

        // NC07 a reply with a time that is not in the meeting is not retried.
        let badTime = good.replacingOccurrences(of: #""task":"Book a room","time":19"#, with: #""task":"Book a room","time":15"#)
        let (r7, t7, _) = summary([.http(status: 200, headers: [:], body: anth(badTime))])
        check(failure(r7) == .badTimes(1) && t7.requests.count == 1, "NC07 bad time", "\(String(describing: failure(r7)))")

        // NC08 an answer streams in and its citations are read.
        let answerLines = anthLines(["Lead with ", "privacy [36]."])
        let (r8, x8, t8, _) = ask([.stream(status: 200, lines: answerLines)])
        let e8 = success(r8)
        check(e8?.answer == "Lead with privacy [36]." && e8?.citations == [36] && x8.last == "Lead with privacy [36]."
              && x8 == ["Lead with ", "Lead with privacy [36]."] && t8.requests.count == 1,
              "NC08 ask success", "\(String(describing: failure(r8))) texts \(x8.count) requests \(t8.requests.count)")

        // NC09 a failure after some text has arrived is not retried (the user has seen the text).
        let (r9, _, t9, _) = ask([.stream(status: 200, lines: anthLines(["Part"]).dropLast(2) + [overloadedEvent])])
        check(failure(r9) == .overloaded(retryAfter: nil) && t9.requests.count == 1,
              "NC09 mid-stream error", "\(String(describing: failure(r9))) requests \(t9.requests.count)")

        // NC10 a failure before any text is retried once.
        let (r10, _, t10, p10) = ask([.stream(status: 200, lines: [overloadedEvent]),
                                      .stream(status: 200, lines: answerLines)])
        check(success(r10) != nil && t10.requests.count == 2 && p10.waits == [4.0],
              "NC10 error before text retried", "\(String(describing: failure(r10))) requests \(t10.requests.count) waits \(p10.waits)")

        // NC11 a rejected key.
        let (r11, _, t11, _) = ask([.stream(status: 401, lines: [#"{"type":"error","error":{"type":"authentication_error","message":"x"}}"#])])
        check(failure(r11) == .badKey && t11.requests.count == 1, "NC11 ask 401", "\(String(describing: failure(r11)))")

        // NC12 no key: no request for either.
        let (r12a, t12a, _) = summary([], key: nil)
        let (r12b, _, t12b, _) = ask([], key: nil)
        check(failure(r12a) == .noKey && failure(r12b) == .noKey && t12a.requests.isEmpty && t12b.requests.isEmpty,
              "NC12 no key", "\(String(describing: failure(r12a))) \(String(describing: failure(r12b)))")

        // NC13 offline.
        let (r13, t13, _) = summary([.failure(.notConnectedToInternet)])
        check(failure(r13) == .offline && t13.requests.count == 1, "NC13 offline", "\(String(describing: failure(r13)))")

        // NC14 the stream ends without message_stop after some text.
        let (r14, _, _, _) = ask([.stream(status: 200, lines: Array(anthLines(["Half"]).dropLast(2)))])
        check(failure(r14) == .incomplete, "NC14 stream cut short", "\(String(describing: failure(r14)))")

        // NC15 after cancel() the completion never runs.
        let (client15, _, _) = client([.http(status: 200, headers: [:], body: anth(good))])
        var called = false
        let job = client15.writeSummary(access: access()!, transcript: Transcript(turns: turns), speakers: speakers,
                                        progress: { _, _ in }, completion: { _ in called = true })
        job.cancel()
        spin(0.3) { called }
        check(!called, "NC15 cancel stops callbacks", "called \(called)")

        // NC16 the same ask path for OpenAI.
        let openAILines = ["data: " + #"{"type":"response.created","response":{"status":"in_progress"}}"#,
                           "data: " + #"{"type":"response.output_text.delta","delta":"Hello"}"#,
                           "data: " + #"{"type":"response.output_text.delta","delta":" [19]"}"#,
                           "data: " + #"{"type":"response.completed","response":{"status":"completed"}}"#]
        let (r16, _, t16, _) = ask([.stream(status: 200, lines: openAILines)], openAI: true)
        let e16 = success(r16)
        check(e16?.answer == "Hello [19]" && e16?.citations == [19] && t16.requests.first?.url == NotesAI.openAIURL,
              "NC16 OpenAI ask", "\(String(describing: failure(r16))) url \(String(describing: t16.requests.first?.url?.host))")
    }
}
