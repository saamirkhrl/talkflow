import Foundation

/// `talkflowd --notesasktest <transcript.json> [summary | ask "<question>" | questions <truth.json>]
///   [anthropic | openai] [--provider anthropic|openai] [--model <id>] [--speakers <names.json>]
///   [--out <result.json>] [--score-out <summary.json>]`
///
/// The real Summary or Ask requests on a made-up transcript, with the key in the Keychain (billed). Nothing
/// else in the app calls this. All the logic lives in NotesAskRun (checked offline by NotesAskChecks); this is
/// only the arguments in and the files out. The result goes to --out (default $TMPDIR/talkflow-notesasktest.json)
/// and a summary in score.py's shape to --score-out; stdout holds counts only, never transcript, summary or
/// answer text.
enum NotesAskTest {
    static func run(_ arguments: [String]) -> Never {
        let args: NotesAskRun.Args
        switch NotesAskRun.parse(arguments) {
        case .success(let parsed):
            args = parsed
        case .failure(let error):
            fail("notesasktest: \(error.message)\n\(NotesAskRun.usage)")
        }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: args.transcript)),
              let (transcript, readSpeakers) = NotesAskRun.readTranscript(data) else {
            fail("notesasktest: can't read that transcript file")
        }
        var speakers = readSpeakers
        var applied = 0
        if let path = args.speakerMap {
            guard let names = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let map = try? JSONDecoder().decode([String: String].self, from: names) else {
                fail("notesasktest: can't read that names file")
            }
            let result = NotesAskRun.applyNames(map, to: speakers)
            speakers = result.speakers
            applied = result.applied
            print("notesasktest: \(result.applied) speaker name(s) applied, \(result.ignored) ignored")
        }

        var truth: [NotesAskRun.TruthQuestion] = []
        if case .questions(let path) = args.mode {
            guard let truthData = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let questions = NotesAskRun.truthQuestions(truthData) else {
                fail("notesasktest: can't read ask_questions from that truth file")
            }
            truth = questions
        }

        let outURL = args.out.map { URL(fileURLWithPath: $0) } ?? NotesAskRun.defaultOut
        let scoreURL = args.scoreOut.map { URL(fileURLWithPath: $0) } ?? NotesAskRun.defaultScoreOut

        // Running this flag is the opt-in: the orchestrator tests from the installed app with the owner's saved
        // key, and only ever with made-up transcripts. The model is
        // the cheapest of the provider (or --model); Settings' model choice is deliberately not used, so a test
        // never bills the dearer model the owner picked for real notes.
        guard let access = NotesAccess.resolve(
            hasAnthropic: args.provider == .openAI ? { false } : { APIKeys.hasKey(.anthropic) },
            hasOpenAI: args.provider == .anthropic ? { false } : { APIKeys.hasKey(.openAI) },
            anthropicModel: args.model?.rawValue, openAIModel: args.model?.rawValue) else {
            let output = NotesAskRun.Output(
                mode: args.mode.name, provider: "none", model: "none", ok: false,
                error: NotesAskRun.Output.Failure(
                    category: NotesAIError.noKey.category,
                    message: NotesAIError.noKey.message(args.provider ?? .anthropic, model: nil)))
            _ = write(output, to: outURL, scoreTo: scoreURL)
            print("notesasktest: failed, \(NotesAIError.noKey.category)")
            print("notesasktest: result in \(outURL.path)")
            exit(1)
        }

        var out = NotesAskRun.perform(client: .live(), access: access, transcript: transcript, speakers: speakers,
                                      mode: args.mode, truth: truth)
        out.speakerNamesApplied = applied
        let wroteAll = write(out, to: outURL, scoreTo: scoreURL)
        for line in NotesAskRun.lines(out) { print(line) }
        print("notesasktest: result in \(outURL.path)")
        if out.scoreSummary != nil && wroteAll { print("notesasktest: summary for score.py in \(scoreURL.path)") }
        exit(out.ok ? 0 : 1)
    }

    /// Writes the result file and, when there is a summary, the score.py file. True when every file asked for was
    /// written. Internal so NotesAskChecks can run it on a temporary folder.
    static func write(_ out: NotesAskRun.Output, to: URL, scoreTo: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var ok = true
        if let data = try? encoder.encode(out) {
            do { try data.write(to: to, options: .atomic) } catch { ok = false }
        } else {
            ok = false
        }
        if let score = out.scoreSummary {
            let scoreEncoder = JSONEncoder()
            scoreEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? scoreEncoder.encode(score) {
                do { try data.write(to: scoreTo, options: .atomic) } catch { ok = false }
            } else {
                ok = false
            }
        }
        return ok
    }

    private static func fail(_ message: String) -> Never {
        print(message)
        exit(2)
    }
}
