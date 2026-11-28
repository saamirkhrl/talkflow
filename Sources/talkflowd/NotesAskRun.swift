import Foundation

/// The parts of `--notesasktest` and of the fake meeting's Summary and Ask scoring that need no network: the
/// arguments, speaker labels and names, the result file's shape, the summary in score.py's `--summary` shape, and
/// the summary and question scores. `perform` runs the requests through whatever NotesAIClient it is given, so
/// NotesAskChecks drives it with canned replies; only NotesAskTest and FakeMeeting hand it the live client.
enum NotesAskRun {
    static let usage = """
    usage: talkflowd --notesasktest <transcript.json> [summary | ask "<question>" | questions <truth.json>]
                     [anthropic | openai] [--provider anthropic|openai] [--model <id>] [--speakers <names.json>]
                     [--out <result.json>] [--score-out <summary.json>]
      transcript.json: {"turns":[{"speaker":"You","start":0,"end":5,"text":"..."}]}; speakers "You", "Speaker N"
        (or the app's keys "you", "sN")
      questions: one summary plus the first five ask_questions of truth.json, each asked on its own
      names.json: {"Speaker 1":"Bob","s2":"Emily"}, applied the way renaming a speaker in the app does
      model: the cheapest of the provider unless --model is given
    """

    enum Mode: Equatable {
        case summary
        case ask(String)
        /// Path to a fake-meeting truth.json.
        case questions(truth: String)

        var name: String {
            switch self {
            case .summary: return "summary"
            case .ask: return "ask"
            case .questions: return "questions"
            }
        }
    }

    struct Args: Equatable {
        var transcript: String
        var mode: Mode = .summary
        /// Forced provider; nil = Anthropic when that key exists, otherwise OpenAI.
        var provider: NotesProvider?
        /// nil = the cheapest model of the provider, whatever the settings say.
        var model: NotesAIModel?
        var speakerMap: String?
        var out: String?
        var scoreOut: String?
    }

    static let defaultOut = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("talkflow-notesasktest.json")
    static let defaultScoreOut = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("talkflow-notesasktest-summary.json")

    struct ParseError: Error, Equatable {
        let message: String
    }

    /// `arguments` = everything after "--notesasktest". Errors are one line, without the usage text.
    static func parse(_ arguments: [String]) -> Result<Args, ParseError> {
        guard let first = arguments.first, !first.hasPrefix("--") else { return .failure(ParseError(message: "no transcript file given")) }
        var args = Args(transcript: first)
        var positionals: [String] = []
        var flagProvider: NotesProvider?
        var i = 1
        while i < arguments.count {
            let a = arguments[i]
            if ["--provider", "--model", "--speakers", "--out", "--score-out"].contains(a) {
                guard i + 1 < arguments.count, !arguments[i + 1].hasPrefix("--"), !arguments[i + 1].isEmpty else {
                    return .failure(ParseError(message: "\(a) needs a value"))
                }
                let v = arguments[i + 1]
                switch a {
                case "--provider":
                    guard let p = provider(v) else { return .failure(ParseError(message: "unknown provider \(v)")) }
                    flagProvider = p
                case "--model":
                    guard let m = NotesAIModel(rawValue: v) else { return .failure(ParseError(message: "unknown model \(v)")) }
                    args.model = m
                case "--speakers": args.speakerMap = v
                case "--out": args.out = v
                default: args.scoreOut = v
                }
                i += 2
            } else if a.hasPrefix("--") {
                return .failure(ParseError(message: "unknown flag \(a)"))
            } else {
                positionals.append(a)
                i += 1
            }
        }
        // The provider word at the end, as the first version of this flag took it.
        var wordProvider: NotesProvider?
        if let last = positionals.last, let p = provider(last) {
            wordProvider = p
            positionals.removeLast()
        }
        if let w = wordProvider, let f = flagProvider, w != f { return .failure(ParseError(message: "two different providers given")) }
        args.provider = flagProvider ?? wordProvider
        if let m = args.model {
            if let p = args.provider, p != m.provider { return .failure(ParseError(message: "\(m.rawValue) is not a \(p.name) model")) }
            args.provider = m.provider
        }
        switch positionals.first {
        case nil:
            args.mode = .summary
        case "summary"?:
            guard positionals.count == 1 else { return .failure(ParseError(message: "summary takes no more words")) }
            args.mode = .summary
        case "ask"?:
            guard positionals.count == 2, !positionals[1].trimmingCharacters(in: .whitespaces).isEmpty else {
                return .failure(ParseError(message: "ask needs one question"))
            }
            args.mode = .ask(positionals[1])
        case "questions"?:
            guard positionals.count == 2 else { return .failure(ParseError(message: "questions needs the truth.json path")) }
            args.mode = .questions(truth: positionals[1])
        default:
            // Not echoed: a mistyped question would land in the log, which never holds what was said or asked.
            return .failure(ParseError(message: "unknown mode (expected summary, ask or questions)"))
        }
        return .success(args)
    }

    private static func provider(_ word: String) -> NotesProvider? {
        switch word {
        case "anthropic": return .anthropic
        case "openai": return .openAI
        default: return nil
        }
    }

    // MARK: - Speakers

    /// A transcript file's speaker label as the app's key: "You" -> "you", "Speaker 3" -> "s3", "s3" stays. Any
    /// other label is kept as its own key, so it shows as itself.
    static func key(forLabel label: String) -> String {
        let t = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        if lower == "you" { return NotesLogic.youKey }
        if lower.hasPrefix("speaker ") {
            let rest = lower.dropFirst("speaker ".count).trimmingCharacters(in: .whitespaces)
            if let n = Int(rest), n > 0 { return "s\(n)" }
        }
        if lower.hasPrefix("s"), let n = Int(lower.dropFirst()), n > 0 { return "s\(n)" }
        return t
    }

    /// Applies {"Speaker 3": "Emily"} through NotesLogic.renaming, as the app's rename does. Names for You, blank
    /// names and labels no turn uses are not applied (the app never renames You either).
    static func applyNames(_ map: [String: String], to speakers: [NoteSpeaker])
        -> (speakers: [NoteSpeaker], applied: Int, ignored: Int) {
        var out = speakers
        var applied = 0, ignored = 0
        // Sorted, so two labels for the same key always resolve the same way.
        for label in map.keys.sorted() {
            let key = key(forLabel: label)
            let name = (map[label] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard key != NotesLogic.youKey, !name.isEmpty, out.contains(where: { $0.key == key }) else {
                ignored += 1
                continue
            }
            out = NotesLogic.renaming(key, to: name, in: out)
            applied += 1
        }
        return (out, applied, ignored)
    }

    private struct TranscriptFile: Decodable {
        var turns: [TranscriptTurn]
        var speakers: [NoteSpeaker]?
    }

    /// The transcript file with labels turned into keys, and its speakers (from the file when it has them).
    static func readTranscript(_ data: Data) -> (Transcript, [NoteSpeaker])? {
        guard let file = try? JSONDecoder().decode(TranscriptFile.self, from: data), !file.turns.isEmpty else { return nil }
        let turns = file.turns.map { TranscriptTurn(speaker: key(forLabel: $0.speaker), start: $0.start, end: $0.end, text: $0.text) }
        let speakers = file.speakers.map { list in list.map { NoteSpeaker(key: key(forLabel: $0.key), name: $0.name) } }
            ?? NotesLogic.speakers(for: turns, keeping: [])
        return (Transcript(turns: turns), speakers)
    }

    // MARK: - Truth

    struct TruthQuestion: Equatable {
        var id: String
        var question: String
        var answer: String
        /// The evidence utterances' spans, in seconds.
        var evidence: [ClosedRange<Double>]
    }

    private struct TruthFile: Decodable {
        struct Utterance: Decodable { var id: String; var start: Double; var end: Double }
        struct Question: Decodable { var id: String; var question: String; var answer: String; var evidence: [String] }
        struct Item: Decodable { var owner: String?; var keywords: [String]? }
        var utterances: [Utterance]?
        var ask_questions: [Question]?
        var action_items: [Item]?
        var decisions: [Item]?
    }

    /// The first five ask_questions; nil when the file can't be read or has none.
    static func truthQuestions(_ data: Data) -> [TruthQuestion]? {
        guard let t = try? JSONDecoder().decode(TruthFile.self, from: data), let qs = t.ask_questions, !qs.isEmpty else { return nil }
        let spans = Dictionary((t.utterances ?? []).map { ($0.id, $0.start...max($0.start, $0.end)) }, uniquingKeysWith: { a, _ in a })
        return qs.prefix(5).map { q in
            TruthQuestion(id: q.id, question: q.question, answer: q.answer, evidence: q.evidence.compactMap { spans[$0] })
        }
    }

    // MARK: - score.py's summary shape

    struct ScoreSummary: Codable, Equatable {
        struct Item: Codable, Equatable {
            var owner: String
            var task: String
        }
        var action_items: [Item]
        var decisions: [String]
    }

    /// Owners as the Summary tab shows them: a speaker key becomes its name ("you" -> "You"), any other owner
    /// stays as the model wrote it.
    static func scoreFormat(_ original: NoteSummary, speakers: [NoteSpeaker]) -> ScoreSummary {
        let s = NotesDoc.resolving(original, speakers: speakers)
        return ScoreSummary(
            action_items: s.actionItems.map { a in
                let owner = speakers.contains { $0.key == a.owner } ? NotesLogic.displayName(a.owner, in: speakers) : a.owner
                return ScoreSummary.Item(owner: owner, task: a.task)
            },
            decisions: NotesDoc.decisions(s).filter { DecisionStatus.of($0.status) != .needsDiscussion }.map(\.text))
    }

    struct SummaryScore: Codable, Equatable {
        var actionsMatched: Int
        var actionsPredicted: Int
        var actionsTruth: Int
        var ownersRight: Int
        var decisionsMatched: Int
        var decisionsPredicted: Int
        var decisionsTruth: Int
    }

    /// score.py's keyword_hits: a keyword phrase is present when every one of its normalised words starts some
    /// normalised token of the text (digits are spelled out on both sides, so "49" meets "forty-nine").
    static func keywordHits(_ text: String, _ keywords: [String]) -> Int {
        let toks = FMScorer.normalise(text)
        return keywords.filter { kw in
            let k = FMScorer.normalise(kw)
            return !k.isEmpty && k.allSatisfy { w in toks.contains { $0.hasPrefix(w) } }
        }.count
    }

    /// score.py's greedy_match: truth index -> prediction index, one to one, most keyword hits first (ties: lower
    /// truth index, then lower prediction index). A pair counts only with at least half the keywords (rounded up).
    static func greedyMatch(_ preds: [String], _ truths: [[String]]) -> [Int: Int] {
        var pairs: [(h: Int, t: Int, p: Int)] = []
        for (ti, kws) in truths.enumerated() where !kws.isEmpty {
            let need = (kws.count + 1) / 2
            for (pi, text) in preds.enumerated() {
                let h = keywordHits(text, kws)
                if h >= need { pairs.append((h, ti, pi)) }
            }
        }
        pairs.sort { a, b in a.h != b.h ? a.h > b.h : (a.t != b.t ? a.t < b.t : a.p < b.p) }
        var usedT = Set<Int>(), usedP = Set<Int>(), out: [Int: Int] = [:]
        for pair in pairs where !usedT.contains(pair.t) && !usedP.contains(pair.p) {
            usedT.insert(pair.t)
            usedP.insert(pair.p)
            out[pair.t] = pair.p
        }
        return out
    }

    /// score.py's norm_owner: the first word, lowercased; you, me, i and samir all mean the user.
    static func normOwner(_ owner: String) -> String {
        let words = owner.lowercased().split { !("a"..."z").contains($0) }
        guard let w = words.first.map(String.init) else { return "" }
        return ["you", "me", "i", "samir"].contains(w) ? "samir" : w
    }

    /// score.py's score_summary, counts only. nil when the truth file has no action items or decisions.
    static func summaryScore(_ s: ScoreSummary, truthData: Data) -> SummaryScore? {
        guard let t = try? JSONDecoder().decode(TruthFile.self, from: truthData),
              let actions = t.action_items, let decisions = t.decisions else { return nil }
        let am = greedyMatch(s.action_items.map(\.task), actions.map { $0.keywords ?? [] })
        let owners = am.filter { ti, pi in normOwner(s.action_items[pi].owner) == normOwner(actions[ti].owner ?? "") }.count
        let dm = greedyMatch(s.decisions, decisions.map { $0.keywords ?? [] })
        return SummaryScore(actionsMatched: am.count, actionsPredicted: s.action_items.count, actionsTruth: actions.count,
                            ownersRight: owners, decisionsMatched: dm.count, decisionsPredicted: s.decisions.count,
                            decisionsTruth: decisions.count)
    }

    // MARK: - Question scores

    struct QuestionScore: Codable, Equatable {
        /// The truth answer's first number is in the answer; nil when the truth answer has no number.
        var leadNumber: Bool?
        var numbersFound: Int
        var numbers: Int
        /// Share of the truth answer's content words found in the answer (same first five letters), 4 decimals.
        var wordRecall: Double
        /// A cited time falls inside an evidence utterance, with 2 s slack either side.
        var cited: Bool
        /// (leadNumber ?? true) && wordRecall >= 0.4
        var correct: Bool
    }

    /// Generic English filler, so the recall counts the words that carry the answer. Nothing meeting-specific.
    static let stopwords: Set<String> = [
        "the", "and", "but", "for", "from", "with", "are", "was", "were", "been", "being", "its", "this", "that",
        "these", "those", "than", "then", "there", "their", "they", "them", "his", "her", "our", "you", "your",
        "not", "nor", "would", "will", "can", "could", "should", "has", "have", "had", "does", "did", "said",
        "says", "which", "who", "whom", "what", "when", "where", "why", "how", "also", "just", "only", "about",
        "into", "over", "after", "before", "more", "most", "first", "every", "each", "any", "all", "some", "such",
        "very", "much", "many", "plus", "because", "she", "him", "out", "off",
    ]

    /// Whole numbers written with digits, commas dropped ("2,400" -> 2400), in order, without repeats.
    static func numbers(in text: String) -> [Int] {
        var out: [Int] = []
        var current = ""
        func flush() {
            if let n = Int(current), !out.contains(n) { out.append(n) }
            current = ""
        }
        let chars = Array(text)
        for (i, c) in chars.enumerated() {
            if c.isASCII && c.isNumber {
                current.append(c)
            } else if c == ",", !current.isEmpty, i + 1 < chars.count, chars[i + 1].isASCII, chars[i + 1].isNumber {
                continue   // a thousands comma
            } else if !current.isEmpty {
                flush()
            }
        }
        if !current.isEmpty { flush() }
        return out
    }

    /// Lowercased runs of letters, three or more long, not stopwords, without repeats, in order.
    static func contentWords(_ text: String) -> [String] {
        var out: [String] = []
        for w in text.lowercased().split(whereSeparator: { !("a"..."z").contains($0) }).map(String.init)
        where w.count >= 3 && !stopwords.contains(w) && !out.contains(w) {
            out.append(w)
        }
        return out
    }

    static func scoreAnswer(_ answer: String, citations: [Double], truth: TruthQuestion) -> QuestionScore {
        let want = numbers(in: truth.answer)
        let got = Set(numbers(in: answer))
        let lead = want.first.map { got.contains($0) }
        let words = contentWords(truth.answer)
        let stems = Set(contentWords(answer).map { String($0.prefix(5)) })
        let hit = words.filter { stems.contains(String($0.prefix(5))) }.count
        let recall = words.isEmpty ? 1 : (Double(hit) / Double(words.count) * 10_000).rounded() / 10_000
        let cited = citations.contains { t in truth.evidence.contains { ($0.lowerBound - 2)...($0.upperBound + 2) ~= t } }
        return QuestionScore(leadNumber: lead, numbersFound: want.filter { got.contains($0) }.count, numbers: want.count,
                             wordRecall: recall, cited: cited, correct: (lead ?? true) && recall >= 0.4)
    }

    // MARK: - The run

    struct Output: Encodable {
        struct Failure: Encodable, Equatable {
            var category: String
            var message: String
        }
        struct Answer: Encodable {
            var id: String?
            var question: String
            var ok: Bool
            var answer: String?
            var citations: [Double]?
            var error: Failure?
            var score: QuestionScore?
        }
        var mode: String
        var provider: String
        var model: String
        var ok: Bool
        var elapsedSeconds: Double = 0
        /// Summary and ask requests started (a summary of a long meeting may take several HTTP requests).
        var calls: Int = 0
        var speakerNamesApplied: Int = 0
        /// Diagnostics for the speaker names: the raw reply text of every summary request, the review of every
        /// proposed name, and how many speakers the accepted names would rename. Holds meeting text, so it goes to
        /// the result file only, never to a line (see `lines`).
        var rawReplies: [String]?
        var nameReview: [NotesAI.NameVerdict]?
        var autoNamesApplied: Int?
        /// The local vocative pass over the transcript (NotesAI.localVotes / localNames).
        var localVotes: [NotesAI.LocalVote]?
        var localNames: [String: String]?
        var error: Failure?
        var summary: NoteSummary?
        /// The summary in score.py's --summary shape (also written to its own file).
        var scoreSummary: ScoreSummary?
        // ask mode
        var question: String?
        var answer: String?
        var citations: [Double]?
        // questions mode
        var answers: [Answer]?
        var questionsCorrect: Int?
        var questionsCited: Int?
    }

    static func failure(_ e: NotesAIError, _ a: NotesAccess) -> Output.Failure {
        Output.Failure(category: e.category, message: e.message(a.provider, model: a.model))
    }

    /// Runs the mode's requests one after another on the main run loop and returns the result. Questions mode:
    /// one summary, then each truth question on its own (no history, so one answer can't lean on another).
    /// At most 1 summary + 5 asks.
    static func perform(client: NotesAIClient, access: NotesAccess, transcript: Transcript, speakers: [NoteSpeaker],
                        mode: Mode, truth: [TruthQuestion] = [], timeout: Double = 600) -> Output {
        let started = Date()
        var out = Output(mode: mode.name, provider: access.provider.name, model: access.model.rawValue, ok: false)
        var done = false
        var queue: [TruthQuestion] = mode == .summary ? [] : Array(truth.prefix(5))
        if case .ask(let q) = mode { queue = [TruthQuestion(id: "", question: q, answer: "", evidence: [])] }
        var answers: [Output.Answer] = []
        var summaryOK = true
        var rawReplies: [String] = []
        client.onReplyText = { rawReplies.append($0) }

        func finish() {
            done = true
            switch mode {
            case .summary:
                out.ok = out.summary != nil
            case .ask:
                let a = answers.first
                out.ok = a?.ok == true
                out.question = a?.question
                out.answer = a?.answer
                out.citations = a?.citations
                out.error = out.error ?? a?.error
            case .questions:
                out.answers = answers
                out.questionsCorrect = answers.filter { $0.score?.correct == true }.count
                out.questionsCited = answers.filter { $0.score?.cited == true }.count
                out.ok = summaryOK && answers.count == queue.count && answers.allSatisfy(\.ok)
            }
        }

        func askNext() {
            guard answers.count < queue.count else { finish(); return }
            let tq = queue[answers.count]
            out.calls += 1
            client.ask(access: access, transcript: transcript, speakers: speakers, history: [], question: tq.question,
                       onText: { _ in }, completion: { result in
                let scored = mode != .ask(tq.question)
                switch result {
                case .success(let e):
                    answers.append(Output.Answer(
                        id: scored ? tq.id : nil, question: tq.question, ok: true, answer: e.answer, citations: e.citations,
                        error: nil, score: scored ? scoreAnswer(e.answer, citations: e.citations, truth: tq) : nil))
                case .failure(let err):
                    answers.append(Output.Answer(
                        id: scored ? tq.id : nil, question: tq.question, ok: false, answer: nil, citations: nil,
                        error: failure(err, access),
                        score: scored ? scoreAnswer("", citations: [], truth: tq) : nil))
                }
                askNext()
            })
        }

        if case .ask = mode {
            askNext()
        } else {
            out.calls += 1
            client.writeSummary(access: access, transcript: transcript, speakers: speakers, progress: { _, _ in },
                                completion: { result in
                switch result {
                case .success(let s):
                    out.summary = s
                    out.scoreSummary = scoreFormat(s, speakers: speakers)
                    out.rawReplies = rawReplies
                    var proposals: [NotesAI.NameSuggestion] = []
                    for text in rawReplies { proposals += NotesAI.speakerProposals(fromReply: text) }
                    out.nameReview = NotesAI.nameReview(proposals, turns: transcript.turns, speakers: speakers)
                    out.localVotes = NotesAI.localVotes(turns: transcript.turns, speakers: speakers)
                    out.localNames = NotesAI.localNames(turns: transcript.turns, speakers: speakers)
                    let renamed = NotesDoc.applyingSuggestedNames(s.suggestedNames ?? [:], to: speakers)
                    out.autoNamesApplied = zip(speakers, renamed).filter { $0.name != $1.name }.count
                case .failure(let err):
                    summaryOK = false
                    out.error = failure(err, access)
                }
                askNext()
            })
        }

        let deadline = Date().addingTimeInterval(timeout)
        while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        if !done {
            out.error = out.error ?? failure(.timedOut, access)
            finish()
            out.ok = false
        }
        out.elapsedSeconds = (Date().timeIntervalSince(started) * 10).rounded() / 10
        return out
    }

    /// "names: proposed N, applied M, rejected K (reason xC, ...)". Reasons are fixed strings, never meeting text.
    static func namesLine(_ review: [NotesAI.NameVerdict], applied: Int) -> String {
        let proposed = review.filter { $0.kind != "none" && !$0.name.isEmpty }
        let rejected = proposed.filter { !$0.accepted }
        var line = "notesasktest: names: proposed \(proposed.count), applied \(applied), rejected \(rejected.count)"
        if !rejected.isEmpty {
            var counts: [String: Int] = [:]
            for v in rejected { counts[v.reason, default: 0] += 1 }
            let parts = counts.keys.sorted().map { "\($0) x\(counts[$0] ?? 0)" }
            line += " (" + parts.joined(separator: ", ") + ")"
        }
        return line
    }

    /// The counts-only lines a run prints: never transcript, summary or answer text.
    static func lines(_ o: Output) -> [String] {
        var l: [String] = []
        if let s = o.summary {
            let details = (s.details ?? []).count
            let names = (s.suggestedNames ?? [:]).count
            let hasTitle = s.title == nil ? "no" : "yes"
            let hasDescription = s.subtitle == nil ? "no" : "yes"
            l.append("notesasktest: summary ok, \(s.parts) part(s), \(s.actionItems.count) action items, "
                + "\(s.decisions.count) decisions, \(o.model), \(details) details, title \(hasTitle), "
                + "description \(hasDescription), \(names) name(s) suggested")
        } else if o.mode != "ask" {
            l.append("notesasktest: summary failed, \(o.error?.category ?? "unknown")")
        }
        if let review = o.nameReview { l.append(namesLine(review, applied: o.autoNamesApplied ?? 0)) }
        if let votes = o.localVotes {
            let counted = votes.filter { $0.counted }.count
            l.append("notesasktest: local names: \(counted) vote(s) counted, \((o.localNames ?? [:]).count) name(s)")
        }
        if o.mode == "ask" {
            l.append(o.ok ? "notesasktest: ask ok, \(o.citations?.count ?? 0) citation(s), \(o.model)"
                          : "notesasktest: ask failed, \(o.error?.category ?? "unknown")")
        }
        if let a = o.answers {
            let failed = a.filter { !$0.ok }.count
            l.append("notesasktest: questions \(o.questionsCorrect ?? 0)/\(a.count) correct, \(o.questionsCited ?? 0)/\(a.count) cited"
                + (failed > 0 ? ", \(failed) failed" : ""))
        }
        l.append(String(format: "notesasktest: %d call(s), %.1f s", o.calls, o.elapsedSeconds))
        return l
    }
}
