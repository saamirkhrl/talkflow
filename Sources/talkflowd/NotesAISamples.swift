import Foundation

// Canned replies and made-up sample content for meeting-note summaries and answers. The canned transport drives
// `--notestest` and the preview/snapshot builds without a network or a key.

// MARK: - Canned transport

final class CannedNotesTransport: NotesTransport {
    enum Reply {
        case http(status: Int, headers: [String: String], body: String)
        case stream(status: Int, lines: [String])
        case failure(URLError.Code)
    }

    private(set) var requests: [URLRequest] = []
    var replies: [Reply]
    /// When set, used instead of `replies` (the preview never runs out).
    var provider: ((URLRequest) -> Reply)?
    /// Seconds between streamed lines; the preview animates, tests use 0.
    var lineDelay: Double = 0

    init(_ replies: [Reply] = []) {
        self.replies = replies
    }

    static func preview() -> CannedNotesTransport {
        let transport = CannedNotesTransport()
        transport.lineDelay = 0.12
        transport.provider = { request in
            var streaming = false
            if let body = request.httpBody, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                streaming = (object["stream"] as? Bool) == true
            }
            return streaming
                ? .stream(status: 200, lines: NotesAISamples.streamAnswerLines)
                : .http(status: 200, headers: [:], body: NotesAISamples.summaryResponseBody())
        }
        return transport
    }

    /// Flipped by NotesCancel so a cancelled request delivers nothing more.
    private final class Stop {
        var stopped = false
    }

    private func nextReply(_ request: URLRequest) -> Reply {
        requests.append(request)
        if let reply = provider?(request) { return reply }
        return replies.isEmpty ? .failure(.notConnectedToInternet) : replies.removeFirst()
    }

    private func response(_ request: URLRequest, _ status: Int, _ headers: [String: String]) -> HTTPURLResponse {
        // The only way this is nil is an invalid status code, which no caller passes.
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    func send(_ request: URLRequest, completion: @escaping (Result<(HTTPURLResponse, Data), URLError>) -> Void) -> NotesCancel {
        let reply = nextReply(request)
        let stop = Stop()
        let result: Result<(HTTPURLResponse, Data), URLError>
        switch reply {
        case .http(let status, let headers, let body):
            result = .success((response(request, status, headers), Data(body.utf8)))
        case .stream(let status, let lines):
            result = .success((response(request, status, [:]), Data(lines.joined(separator: "\n").utf8)))
        case .failure(let code):
            result = .failure(URLError(code))
        }
        DispatchQueue.main.async {
            guard !stop.stopped else { return }
            completion(result)
        }
        return NotesCancel { stop.stopped = true }
    }

    func stream(_ request: URLRequest, onLine: @escaping (String) -> Void,
                completion: @escaping (Result<(HTTPURLResponse, Data?), URLError>) -> Void) -> NotesCancel {
        let reply = nextReply(request)
        let stop = Stop()
        let status: Int
        let lines: [String]
        let headers: [String: String]
        switch reply {
        case .failure(let code):
            DispatchQueue.main.async {
                guard !stop.stopped else { return }
                completion(.failure(URLError(code)))
            }
            return NotesCancel { stop.stopped = true }
        case .http(let s, let h, let body):
            status = s
            headers = h
            lines = body.components(separatedBy: "\n")
        case .stream(let s, let l):
            status = s
            headers = [:]
            lines = l
        }
        let http = response(request, status, headers)
        if !(200...299).contains(status) {
            // A failed request has no event stream: the lines are the error body.
            let body = Data(lines.joined(separator: "\n").utf8)
            DispatchQueue.main.async {
                guard !stop.stopped else { return }
                completion(.success((http, body)))
            }
            return NotesCancel { stop.stopped = true }
        }
        let delay = lineDelay
        if delay <= 0 {
            DispatchQueue.main.async {
                for line in lines {
                    guard !stop.stopped else { return }
                    onLine(line)
                }
                guard !stop.stopped else { return }
                completion(.success((http, nil)))
            }
        } else {
            for (index, line) in lines.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay * Double(index + 1)) {
                    guard !stop.stopped else { return }
                    onLine(line)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay * Double(lines.count + 1)) {
                guard !stop.stopped else { return }
                completion(.success((http, nil)))
            }
        }
        return NotesCancel { stop.stopped = true }
    }
}

// MARK: - Sample content (made up)

enum NotesAISamples {
    private static let model = "claude-haiku-5-5"

    static func summary(now: Date) -> NoteSummary {
        NoteSummary(
            summary: "The team agreed to ship the correction fix and the new app window together, with the note taker following once the summary part is in. The launch post will lead with privacy, and everyone checks in again on Thursday.",
            summaryTimes: [4, 36, 61],
            actionItems: [
                NoteSummary.ActionItem(owner: "you", task: "Cut a proper demo video once the Settings page is final", time: 27, done: false),
                NoteSummary.ActionItem(owner: "s1", task: "Draft the launch post tonight and send it for edits", time: 48, done: true),
                NoteSummary.ActionItem(owner: "s2", task: "Line up the screenshots for launch day", time: 75, done: false),
                NoteSummary.ActionItem(owner: "you", task: "Set up Thursday's check-in", time: 92, done: false),
            ],
            decisions: [
                NoteSummary.Point(text: "The correction fix and the new app window launch together.", time: 4, status: "aligned"),
                NoteSummary.Point(text: "The launch post leads with the privacy angle.", time: 36, status: "aligned"),
                NoteSummary.Point(text: "The note taker waits until the summary part is in.", time: 61, status: "aligned"),
                NoteSummary.Point(text: "When the Settings page will be final.", time: 27, status: "needs_discussion"),
            ],
            openQuestions: [],
            provider: "Anthropic", model: model, written: now, parts: 1,
            details: sampleDetails,
            title: "Launch order and post plan",
            subtitle: sampleSubtitle,
            suggestedNames: nil)
    }

    private static let sampleSubtitle = "Ship order, privacy-first launch post and Thursday check-in"

    private static let sampleDetails: [NoteSummary.Detail] = [
        NoteSummary.Detail(
            topic: "Launch order",
            text: "You want the correction fix and the new app window out together, with the note taker right after. Maya asked whether the window's demo video is ready.",
            times: [4, 19]),
        NoteSummary.Detail(
            topic: "Demo video",
            text: "It is still a screen recording. You will cut a proper one once the Settings page is final.",
            times: [27]),
        NoteSummary.Detail(
            topic: "Launch post",
            text: "Speaker 2 suggested leading with the privacy angle, and Maya will draft the post tonight for edits.",
            times: [36, 48]),
        NoteSummary.Detail(
            topic: "Note taker timing",
            text: "The note taker waits until the summary part is in, so the first impression is the whole thing. Speaker 2 will line up the screenshots for that day.",
            times: [61, 75]),
        NoteSummary.Detail(
            topic: "Next check-in",
            text: "Everyone meets again on Thursday to check where things stand.",
            times: [92]),
    ]

    static func questions(now: Date) -> NoteQuestions {
        NoteQuestions(entries: [
            NoteQuestions.Entry(
                question: "What did we decide about the launch post?",
                answer: "The post will lead with the privacy angle, since everything on your own Mac is what people repeat back [36]. Maya is drafting it tonight and sending it for edits [48].",
                citations: [36, 48], asked: now.addingTimeInterval(-600), provider: "Anthropic", model: model),
            NoteQuestions.Entry(
                question: "What are my action items?",
                answer: "Two: cut a proper demo video once the Settings page is final [27], and set up the check-in on Thursday [92].",
                citations: [27, 92], asked: now.addingTimeInterval(-300), provider: "Anthropic", model: model),
        ])
    }

    /// Writes both for the "Launch planning" sample note. Made-up content only.
    static func seed(into store: NoteStore, launchID: String?, now: Date = Date()) {
        guard let launchID else { return }
        try? store.save(summary(now: now), for: launchID)
        try? store.save(questions(now: now), for: launchID)
        guard var meta = store.meta(launchID) else { return }
        meta.actionItemCount = 4
        meta.subtitle = sampleSubtitle
        try? store.save(meta)
    }

    // MARK: Canned provider replies

    private static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// Anthropic server-sent events for the sample answer, split the way a real stream arrives.
    static let streamAnswerLines: [String] = {
        let chunks = ["From the transcript, ", "the note taker waits ", "until the summary part is in ",
                      "[61], so the first impression ", "is the whole ", "thing."]
        var lines = [
            "data: " + json(["type": "message_start", "message": ["id": "msg_sample", "content": [Any]()]]),
            "data: " + json(["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]]),
        ]
        for chunk in chunks {
            lines.append("data: " + json(["type": "content_block_delta", "index": 0,
                                          "delta": ["type": "text_delta", "text": chunk]]))
        }
        lines.append("data: " + json(["type": "content_block_stop", "index": 0]))
        lines.append("data: " + json(["type": "message_delta", "delta": ["stop_reason": "end_turn"],
                                      "usage": ["output_tokens": 30]]))
        lines.append("data: " + json(["type": "message_stop"]))
        return lines
    }()

    /// An Anthropic Messages reply whose text is the sample summary in the schema's own shape.
    static func summaryResponseBody() -> String {
        func decision(_ p: NoteSummary.Point) -> [String: Any] {
            ["text": p.text, "status": p.status ?? "aligned", "time": Int(p.time)]
        }
        func detail(_ d: NoteSummary.Detail) -> [String: Any] {
            ["topic": d.topic, "text": d.text, "times": d.times.map { Int($0) }]
        }
        func action(_ owner: String, _ task: String, _ time: Int) -> [String: Any] {
            ["owner": owner, "task": task, "time": time]
        }
        let sample = summary(now: Date(timeIntervalSince1970: 0))
        let actions: [[String: Any]] = [
            action("You", sample.actionItems[0].task, 27),
            action("Maya", sample.actionItems[1].task, 48),
            action("Speaker 2", sample.actionItems[2].task, 75),
            action("You", sample.actionItems[3].task, 92),
        ]
        let raw: [String: Any] = [
            "title": sample.title ?? "",
            "description": sample.subtitle ?? "",
            "summary": sample.summary,
            "summary_times": sample.summaryTimes.map { Int($0) },
            "decisions": sample.decisions.map(decision),
            "details": NotesDoc.details(sample).map(detail),
            "action_items": actions,
            "speakers": [Any](),
        ]
        return json(["type": "message", "role": "assistant",
                     "content": [["type": "text", "text": json(raw)]],
                     "stop_reason": "end_turn"])
    }
}
