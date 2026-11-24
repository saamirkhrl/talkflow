import Foundation

/// `talkflowd --notesasktest <transcript.json> [summary|ask "<question>"] [anthropic|openai]`
///
/// The real Summary or Ask request on a made-up transcript, with the key in the Keychain (billed). Nothing
/// else in the app calls this. The result goes to $TMPDIR/talkflow-notesasktest.json; stdout and logs hold
/// counts only, never transcript text.
enum NotesAskTest {
    private static let usage = """
    usage: talkflowd --notesasktest <transcript.json> [summary | ask "<question>"] [anthropic | openai]
      transcript.json: {"turns":[{"speaker":"you","start":0,"end":5,"text":"..."}], "speakers":[{"key":"you"}]}
    """

    private struct Input: Decodable {
        var schemaVersion: Int?
        var turns: [TranscriptTurn]
        var speakers: [NoteSpeaker]?
    }

    private struct Output: Encodable {
        struct Failure: Encodable {
            var category: String
            var message: String
        }
        var mode: String
        var provider: String
        var model: String
        var ok: Bool
        var elapsedSeconds: Double
        var error: Failure?
        var summary: NoteSummary?
        var question: String?
        var answer: String?
        var citations: [Double]?
    }

    static func run(_ arguments: [String]) -> Never {
        var rest = arguments
        guard !rest.isEmpty else { fail(usage) }
        let path = rest.removeFirst()

        var forced: NotesProvider?
        if let last = rest.last, last == "anthropic" || last == "openai" {
            forced = last == "anthropic" ? .anthropic : .openAI
            rest.removeLast()
        }
        var question: String?
        switch rest.first {
        case nil, "summary"?:
            if rest.count > 1 { fail(usage) }
        case "ask"?:
            guard rest.count == 2, !rest[1].isEmpty else { fail(usage) }
            question = rest[1]
        default:
            fail(usage)
        }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let input = try? JSONDecoder().decode(Input.self, from: data) else {
            fail("notesasktest: can't read that transcript file")
        }
        let speakers = input.speakers ?? NotesLogic.speakers(for: input.turns, keeping: [])
        let transcript = Transcript(turns: input.turns)
        let mode = question == nil ? "summary" : "ask"
        let started = Date()

        // The switch is on because running this flag is the opt-in: the orchestrator tests from the installed app
        // before the switch exists in the owner's settings, and only ever with made-up transcripts.
        guard let access = NotesAccess.resolve(
            switchOn: true,
            hasAnthropic: forced == .openAI ? { false } : { APIKeys.hasKey(.anthropic) },
            hasOpenAI: forced == .anthropic ? { false } : { APIKeys.hasKey(.openAI) },
            anthropicModel: Preferences.notesAnthropicModel, openAIModel: Preferences.notesOpenAIModel) else {
            let output = Output(mode: mode, provider: "none", model: "none", ok: false, elapsedSeconds: 0,
                                error: Output.Failure(category: NotesAIError.noKey.category,
                                                      message: NotesAIError.noKey.message(forced ?? .anthropic, model: nil)))
            finish(output, line: "notesasktest: failed, \(NotesAIError.noKey.category)")
        }

        var output = Output(mode: mode, provider: access.provider.name, model: access.model.rawValue, ok: false, elapsedSeconds: 0)
        var line = ""
        var done = false
        func failed(_ error: NotesAIError) {
            output.error = Output.Failure(category: error.category, message: error.message(access.provider, model: access.model))
            line = "notesasktest: failed, \(error.category)"
            done = true
        }

        let client = NotesAIClient.live()
        if let question {
            client.ask(access: access, transcript: transcript, speakers: speakers, history: [], question: question,
                       onText: { _ in }, completion: { result in
                switch result {
                case .success(let entry):
                    output.ok = true
                    output.question = entry.question
                    output.answer = entry.answer
                    output.citations = entry.citations
                    line = "notesasktest: ask ok, \(entry.citations.count) citation(s), \(seconds(since: started)) s, \(access.model.rawValue)"
                    done = true
                case .failure(let error):
                    failed(error)
                }
            })
        } else {
            client.writeSummary(access: access, transcript: transcript, speakers: speakers, progress: { _, _ in },
                                completion: { result in
                switch result {
                case .success(let summary):
                    output.ok = true
                    output.summary = summary
                    line = "notesasktest: summary ok, \(summary.parts) part(s), \(summary.actionItems.count) action items, "
                        + "\(seconds(since: started)) s, \(access.model.rawValue)"
                    done = true
                case .failure(let error):
                    failed(error)
                }
            })
        }

        let deadline = Date().addingTimeInterval(600)
        while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        if !done { failed(.timedOut) }
        output.elapsedSeconds = (Date().timeIntervalSince(started) * 10).rounded() / 10
        finish(output, line: line)
    }

    private static func seconds(since start: Date) -> String {
        String(format: "%.1f", Date().timeIntervalSince(start))
    }

    private static func fail(_ message: String) -> Never {
        print(message)
        exit(2)
    }

    /// Writes the result file, prints one counts-only line and the file's path, and exits 0 or 1.
    private static func finish(_ output: Output, line: String) -> Never {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("talkflow-notesasktest.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(output) { try? data.write(to: url, options: .atomic) }
        print(line)
        print("notesasktest: result in \(url.path)")
        exit(output.ok ? 0 : 1)
    }
}
