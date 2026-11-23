import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Optional model step for a spoken correction the rules left in (Settings:
/// "AI corrections"). `SelfCorrection` only deletes what it can prove is a
/// correction; "Let's put it on the blog. Actually, you know what, the newsletter
/// is better." has no rule, so the marker stays. This step runs only then, when
/// `SelfCorrection.hasMarker` still finds one in the rules' output, and
/// everything else dictates exactly as before.
///
/// Like `Polish`, the model never writes the result. Its reply is only used to
/// decide which whole words of the rules' output to delete: the output is rebuilt
/// from the original's own tokens, the deleted runs must pass the bounds in
/// `check` (inside one paragraph, around a marker, close to its sentence, with
/// the replacement left standing), and the result must pass
/// `SelfCorrection.isDeletionOnly`. Anything else and the original is used.
///
/// It is given a hard budget: the on-device model 2.0 s, Claude 4 s. Worst case
/// at release, one step after the other and only when a marker is left: on-device
/// 2.0 s plus AI punctuation 2.5 s = 4.5 s (AI punctuation is off by default, so
/// 2.0 s by default); Claude 4 s plus Claude punctuation 6 s = 10 s, only on a Mac
/// without Apple Intelligence that has Claude punctuation on. Ordinary dictations
/// add 0 s.
///
/// Off by default. Measured with `--correctiontest` on an M4 (macOS 27.2), the
/// on-device model took a non-correction ("I read your proposal. Actually, that
/// sounds great.") for one, the guard cannot tell the two apart, and it found
/// only about half of the rephrased corrections (14 of 30).
enum CorrectionModel {
    /// How the model answers. Chosen by measurement (`--correctiontest`): `text`
    /// found more corrections and changed fewer non-corrections than `span`.
    enum Mode: String { case text, span }
    static var mode: Mode = .text            // `var` so the harness can switch it; production never writes it

    /// Off until the measurement passes (see above). Settings: "AI corrections".
    static let enabledByDefault = false

    /// The longest the release pass waits for the on-device model.
    static let budget: TimeInterval = 2.0
    /// The longest it waits for Claude (network plus a large model).
    static let claudeBudget: TimeInterval = 4.0
    /// Past this many words the step is skipped: text mode's reply grows with the input.
    static let maxWords = 150
    /// Tokens a deleted run may hold after its last marker ("Actually, you know what,").
    static let maxAfterMarker = 3
    /// Words of the marker's sentence that must survive after a deleted run.
    static let minKeptAfter = 2

    enum Stage: String { case model, claude }

    enum GuardFailure: String {
        case empty, notSubsequence, spanNotFound, spanAmbiguous
        case crossesParagraph, noMarkerInRun, nothingBeforeMarker, outsideWindow
        case tooMuchAfterMarker, noReplacementLeft, notDeletionOnly, deletesNegation
    }

    enum Verdict: Equatable {
        case applied(String)
        case unchanged
        case rejected(GuardFailure)
    }

    enum Outcome {
        case verdict(Verdict)
        case timedOut
        case tooLong
        case failed(String)   // a category only, never text: "guardrail", "declined", "error", "no API key", "unreachable", "HTTP 500"

        /// For the log. No transcript content.
        var logPhrase: String {
            switch self {
            case .verdict(.applied): return "applied"
            case .verdict(.unchanged): return "changed nothing"
            case .verdict(.rejected(let reason)): return "rejected by guard (\(reason.rawValue))"
            case .timedOut: return "missed its budget"
            case .tooLong: return "skipped (too long)"
            case .failed(let category): return "failed (\(category))"
            }
        }
    }

    // MARK: - Prompts

    static let textInstructions = """
    You edit dictated text. Sometimes the speaker changes their mind partway: they say one thing, \
    then a correction word such as "actually", "wait", "no", "sorry" or "I mean", then what they \
    want instead. When that happens, delete the words they took back together with the correction \
    words, and keep everything else exactly as it is. Never add, change, reorder or rephrase a word. \
    If the speaker did not take anything back, return the text unchanged. Reply with the text only.

    Examples:
    Text: Let's put the launch post on the blog. Actually, I think the newsletter is better.
    Reply: I think the newsletter is better.
    Text: I was going to call her, I mean, I'll just email her tonight.
    Reply: I'll just email her tonight.
    Text: The demo went well. Actually, the client signed on the spot.
    Reply: The demo went well. Actually, the client signed on the spot.
    Text: I can't make it, sorry. Let's catch up next week.
    Reply: I can't make it, sorry. Let's catch up next week.
    """

    static let spanInstructions = """
    You read dictated text. Sometimes the speaker changes their mind partway: they say one thing, \
    then a correction word such as "actually", "wait", "no", "sorry" or "I mean", then what they \
    want instead. Copy out, word for word, the part they took back, from its first word through \
    the correction words. If the speaker did not take anything back, reply NONE. Reply with the \
    copied words or NONE only.

    Examples:
    Text: Let's put the launch post on the blog. Actually, I think the newsletter is better.
    Reply: Let's put the launch post on the blog. Actually,
    Text: I was going to call her, I mean, I'll just email her tonight.
    Reply: I was going to call her, I mean,
    Text: The demo went well. Actually, the client signed on the spot.
    Reply: NONE
    Text: I can't make it, sorry. Let's catch up next week.
    Reply: NONE
    """

    static func instructions(for mode: Mode) -> String { mode == .text ? textInstructions : spanInstructions }
    /// The user turn: the text, trimmed, after "Text: ".
    static func prompt(for text: String) -> String { "Text: " + text.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: - Pure logic

    typealias Token = SelfCorrection.Token

    /// Strips what models wrap answers in: whitespace, a leading "Reply:" (any case),
    /// then one pair of matching surrounding quotes (" or ').
    static func cleanReply(_ reply: String) -> String {
        var s = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("reply:") { s = String(s.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines) }
        if s.count >= 2, let f = s.first, let l = s.last, f == l, f == "\"" || f == "'" {
            s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }

    /// Token indices of `original` the reply deletes, as sorted contiguous runs.
    /// [] = nothing deleted. A failure = unusable reply.
    static func deletions(original tokens: [Token], reply raw: String, mode: Mode) -> (runs: [Range<Int>], failure: GuardFailure?) {
        let reply = cleanReply(raw)
        let words = SelfCorrection.tokenize(reply).map(\.norm).filter { !$0.isEmpty }
        let source = tokens.map(\.norm)
        switch mode {
        case .text:
            guard !words.isEmpty else { return ([], .empty) }
            // Right-aligned: corrections delete earlier material, so each reply word is
            // matched to its LAST possible position, walking backwards.
            var kept = Set<Int>()
            var i = source.count - 1
            for word in words.reversed() {
                while i >= 0, source[i] != word { i -= 1 }
                guard i >= 0 else { return ([], .notSubsequence) }
                kept.insert(i); i -= 1
            }
            let deleted = source.indices.filter { !kept.contains($0) && !source[$0].isEmpty }
            return (runs(of: deleted), nil)
        case .span:
            if words.isEmpty || words == ["none"] { return ([], nil) }
            guard words.count <= source.count else { return ([], .spanNotFound) }
            let starts = (0...(source.count - words.count)).filter { Array(source[$0..<($0 + words.count)]) == words }
            guard let start = starts.first else { return ([], .spanNotFound) }
            guard starts.count == 1 else { return ([], .spanAmbiguous) }
            return ([start..<(start + words.count)], nil)
        }
    }

    /// Sorted indices -> maximal contiguous ranges.
    static func runs(of indices: [Int]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        for i in indices.sorted() {
            if let last = result.last, last.upperBound == i { result[result.count - 1] = last.lowerBound..<(i + 1) }
            else { result.append(i..<(i + 1)) }
        }
        return result
    }

    static func isSentenceStart(_ tokens: [Token], _ i: Int) -> Bool {
        i == 0 || tokens[i - 1].endsSentence || tokens[i].leading.contains("\n")
    }
    static func sentenceStart(_ tokens: [Token], _ i: Int) -> Int {
        var s = i
        while s > 0, !isSentenceStart(tokens, s) { s -= 1 }
        return s
    }
    /// Index of the last token of the sentence holding `i`.
    static func sentenceEnd(_ tokens: [Token], _ i: Int) -> Int {
        var e = i
        while e + 1 < tokens.count, !tokens[e].endsSentence, !tokens[e + 1].leading.contains("\n") { e += 1 }
        return e
    }

    /// Words that turn a sentence around. Deleting one can reverse what the user
    /// said ("Actually, do not ship it" -> "ship it"), so no deleted run may hold
    /// one. Straight or curly apostrophe: "don't", "don\u{2019}t".
    static func isNegation(_ token: Token) -> Bool {
        let word = token.norm.replacingOccurrences(of: "\u{2019}", with: "'")
        return ["not", "no", "never", "cannot"].contains(word) || word.hasSuffix("n't")
    }

    /// Marker words, as SelfCorrection chains them ("wait, no", "actually no").
    private static let markerWords: Set<String> = ["oh", "wait", "no", "actually", "sorry"]

    /// A negation that is part of the correction itself and may go: a "no" chained
    /// to a marker through marker words only ("Wait, no,", "actually no", "No,
    /// actually"), or "never" in "never mind".
    static func isMarkerNegation(_ tokens: [Token], _ i: Int, markers: [Int]) -> Bool {
        let word = tokens[i].norm
        if word == "never" { return i + 1 < tokens.count && tokens[i + 1].norm == "mind" }
        guard word == "no" else { return false }
        return markers.contains { m in
            m <= i && i - m <= 2 && (m...i).allSatisfy { markerWords.contains(tokens[$0].norm) }
        }
    }

    /// The bounds guard. Every run must: stay inside one paragraph; hold a marker that
    /// is not its first token (something said before the marker is what is taken back);
    /// start no earlier than the marker's sentence, or the sentence before it when the
    /// marker opens its sentence (and that sentence is not the start of a paragraph);
    /// hold at most `maxAfterMarker` tokens after its last marker; and leave at least
    /// `minKeptAfter` tokens of the marker's sentence after it, and delete no negation
    /// that is not part of the marker (`isNegation`).
    static func check(runs: [Range<Int>], tokens: [Token], markers: [Int]) -> GuardFailure? {
        for run in runs {
            if run.dropFirst().contains(where: { tokens[$0].leading.contains("\n") }) { return .crossesParagraph }
            let inRun = markers.filter { run.contains($0) }
            guard !inRun.isEmpty else { return .noMarkerInRun }
            // The FIRST marker must not open the run: "Thursday, sorry, I mean the
            // draft" losing only "sorry, I mean" has nothing taken back, even though
            // "I mean" is a second marker after the run's first token.
            guard let m = inRun.min(), m > run.lowerBound else { return .nothingBeforeMarker }
            let own = sentenceStart(tokens, m)
            let lower = (own == m && m > 0 && !tokens[m].leading.contains("\n")) ? sentenceStart(tokens, m - 1) : own
            guard run.lowerBound >= lower else { return .outsideWindow }
            let lastMarker = inRun.max()!
            guard run.upperBound - 1 - lastMarker <= maxAfterMarker else { return .tooMuchAfterMarker }
            let end = sentenceEnd(tokens, m)
            guard end - (run.upperBound - 1) >= minKeptAfter else { return .noReplacementLeft }
            if run.contains(where: { isNegation(tokens[$0]) && !isMarkerNegation(tokens, $0, markers: markers) }) {
                return .deletesNegation
            }
        }
        return nil
    }

    /// `text` with `runs` removed, the way SelfCorrection deletes: the whitespace in
    /// front of a cut stays, and a cut that started a sentence with a capital passes the
    /// capital to the word that now starts it. Runs are removed last to first.
    static func applying(runs: [Range<Int>], to text: String) -> String {
        var tokens = SelfCorrection.tokenize(text)
        for run in runs.sorted(by: { $0.lowerBound > $1.lowerBound }) {
            guard run.upperBound < tokens.count else { tokens.removeSubrange(run); continue }
            var next = tokens[run.upperBound]
            next.leading = tokens[run.lowerBound].leading
            if isSentenceStart(tokens, run.lowerBound), tokens[run.lowerBound].word.first?.isUppercase == true {
                next.word = next.word.prefix(1).uppercased() + next.word.dropFirst()
            }
            tokens.replaceSubrange(run.lowerBound...run.upperBound, with: [next])
        }
        let trailing = String(text.reversed().prefix(while: \.isWhitespace).reversed())
        return tokens.map { $0.leading + $0.word }.joined() + trailing
    }

    /// The whole decision on a reply, pure. `original` is the rules output.
    static func evaluate(original: String, reply: String, mode: Mode) -> Verdict {
        let tokens = SelfCorrection.tokenize(original)
        let (found, failure) = deletions(original: tokens, reply: reply, mode: mode)
        if let failure { return .rejected(failure) }
        if found.isEmpty { return .unchanged }
        if let failure = check(runs: found, tokens: tokens, markers: SelfCorrection.markerIndices(in: original)) { return .rejected(failure) }
        let result = applying(runs: found, to: original)
        guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              SelfCorrection.isDeletionOnly(original: original, result: result) else { return .rejected(.notDeletionOnly) }
        return .applied(result)
    }

    // MARK: - Asking a model

    static var isAvailable: Bool { Polish.isAvailable }

    /// Loads the model while the user is still speaking.
    static func prewarm() {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), isAvailable { session(mode: mode).prewarm() }
        #endif
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    static func session(mode: Mode) -> LanguageModelSession {
        // Text transformation of the user's own words: the permissive guardrails are
        // Apple's setting for exactly this.
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        return LanguageModelSession(model: model, instructions: instructions(for: mode))
    }

    /// The raw reply, for `run` and the measurement harness. Throws the model's errors.
    @available(macOS 26.0, *)
    static func ask(_ text: String, mode: Mode) async throws -> String {
        let options = GenerationOptions(temperature: 0, maximumResponseTokens: mode == .text ? 400 : 120)
        return try await session(mode: mode).respond(to: prompt(for: text), options: options).content
    }

    @available(macOS 26.0, *)
    static func category(of error: Error) -> String {
        guard let e = error as? LanguageModelSession.GenerationError else { return "error" }
        switch e {
        case .guardrailViolation: return "guardrail"
        case .refusal: return "declined"
        case .exceededContextWindowSize: return "too long"
        default: return "error"
        }
    }
    #endif

    /// Calls `completion` on the main queue exactly once, with the text to use (the
    /// corrected text, or `text` unchanged), what happened, and the seconds it took.
    /// `text` is the rules output. Never longer than the stage's budget.
    static func run(_ text: String, stage: Stage, completion: @escaping (String, Outcome, TimeInterval) -> Void) {
        let startedAt = Date()
        let lock = NSLock()
        var done = false
        func finish(_ outcome: Outcome) {
            lock.lock(); defer { lock.unlock() }
            guard !done else { return }
            done = true
            let result: String
            if case .verdict(.applied(let corrected)) = outcome { result = corrected } else { result = text }
            let elapsed = Date().timeIntervalSince(startedAt)
            DispatchQueue.main.async { completion(result, outcome, elapsed) }
        }
        guard SelfCorrection.tokenize(text).count <= maxWords else { finish(.tooLong); return }
        let budget = stage == .model ? Self.budget : claudeBudget
        var cancel: () -> Void = {}
        switch stage {
        case .model:
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *), isAvailable {
                let task = Task {
                    do { finish(.verdict(evaluate(original: text, reply: try await ask(text, mode: mode), mode: mode))) }
                    catch { finish(.failed(category(of: error))) }
                }
                cancel = { task.cancel() }
            } else { finish(.failed("unavailable")); return }
            #else
            finish(.failed("unavailable")); return
            #endif
        case .claude:
            let request = askClaude(text) { reply, failure in
                if let failure { finish(.failed(failure)) }
                else { finish(.verdict(evaluate(original: text, reply: reply ?? "", mode: mode))) }
            }
            cancel = { request?.cancel() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + budget) {
            cancel()
            finish(.timedOut)
        }
    }

    // MARK: - Claude

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    /// The same request as `ClaudePolish.run`, with this step's prompt. Calls
    /// `completion` with the reply, or a failure category (never a response body or
    /// any text). Returns the task so the budget can cancel it.
    static func askClaude(_ text: String, completion: @escaping (String?, String?) -> Void) -> URLSessionDataTask? {
        guard let key = APIKeys.key(for: .anthropic) else {
            completion(nil, "no API key")
            return nil
        }
        let model = Preferences.claudeModel
        var body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": 1024,
            "system": instructions(for: mode),
            "messages": [["role": "user", "content": prompt(for: text)]]
        ]
        var request = URLRequest(url: endpoint)
        if model != .haiku {
            // Thinking cannot be turned off on these models; low effort keeps
            // it short. Haiku 4.5 takes no effort setting.
            body["output_config"] = ["effort": "low"]
            // A safety classifier declining dictated text re-runs it on the
            // recommended fallback model instead of failing.
            body["fallbacks"] = "default"
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        request.httpMethod = "POST"
        request.timeoutInterval = claudeBudget
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let task = CloudTranscriber.session.dataTask(with: request) { data, response, error in
            if let error {
                let timedOut = (error as? URLError)?.code == .timedOut
                completion(nil, timedOut ? "timed out" : "unreachable")
                return
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(code) else { completion(nil, "HTTP \(code)"); return }
            guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(nil, "error")
                return
            }
            if json["stop_reason"] as? String == "refusal" { completion(nil, "declined"); return }
            let reply = (json["content"] as? [[String: Any]] ?? [])
                .filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
                .joined()
            completion(reply, nil)
        }
        task.resume()
        return task
    }
}
