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
/// from the original's own tokens, the deleted runs must pass the structural guard in
/// `check` (inside one paragraph, only what was said before a marker plus the marker
/// itself and fillers; everything said after the marker is kept), and the result
/// must pass `SelfCorrection.isDeletionOnly`. Anything else and the original is used.
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
/// fewer than half of the rephrased corrections (13 of 30 with the structural guard).
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
    /// Words of the marker's sentence that must survive after a deleted run.
    static let minKeptAfter = 2

    enum Stage: String { case model, claude }

    enum GuardFailure: String {
        case empty, notSubsequence, spanNotFound, spanAmbiguous
        case crossesParagraph, noMarkerInRun, nothingBeforeMarker, outsideWindow
        case keepsMarker, deletesAfterMarker, noReplacementLeft, notDeletionOnly, deletesNegation
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

    /// Words that turn a sentence around ("do not ship it" -> "ship it"). Straight or
    /// curly apostrophe, and the apostrophe-less forms speech engines sometimes write.
    static func isNegation(_ token: Token) -> Bool {
        let word = token.norm.replacingOccurrences(of: "\u{2019}", with: "'")
        return negations.contains(word) || word.hasSuffix("n't")
    }
    private static let negations: Set<String> = [
        "not", "no", "never", "cannot", "nor", "neither", "nobody", "none", "nothing", "nowhere",
        "without", "hardly", "barely", "scarcely",
        "dont", "doesnt", "didnt", "wont", "cant", "isnt", "arent", "wasnt", "werent",
        "shouldnt", "wouldnt", "couldnt", "hasnt", "havent", "hadnt", "mustnt", "neednt", "aint",
    ]

    /// Phrases that make up a correction marker, longest first. A marker is a chain
    /// of these ("Wait, no, actually,", "Sorry, I meant").
    private static let markerPhrases: [[String]] = [
        ["scratch", "that"], ["strike", "that"], ["ignore", "that"], ["disregard", "that"],
        ["never", "mind"], ["start", "over"], ["delete", "that"], ["undo", "that"],
        ["i", "meant"], ["i", "mean"], ["or", "rather"], ["make", "that"],
        ["nevermind"], ["actually"], ["wait"], ["sorry"], ["oh"], ["correction"], ["rather"], ["no"],
    ]
    /// Marker phrases that never take an object, so they close the marker even
    /// without punctuation ("Actually let's do Monday", "or rather the blue one").
    private static let objectless: Set<[String]> = [["actually"], ["oh"], ["correction"], ["rather"], ["or", "rather"]]
    /// Retract commands, which filler leads may come in front of ("okay, scratch that").
    private static let commandPhrases: [[String]] = [
        ["scratch", "that"], ["strike", "that"], ["ignore", "that"], ["disregard", "that"],
        ["never", "mind"], ["start", "over"], ["delete", "that"], ["undo", "that"], ["nevermind"],
    ]
    private static let commandLeads: Set<String> = ["okay", "ok", "um", "uh", "hmm", "so", "well"]
    /// Marker words a bare "no" may run into and still be part of the marker ("No wait,").
    private static let chainWords: Set<String> = ["oh", "wait", "actually", "sorry"]

    /// Whether `phrase` is said at `p`, inside one paragraph.
    static func matches(_ phrase: [String], _ tokens: [Token], at p: Int) -> Bool {
        guard p + phrase.count <= tokens.count else { return false }
        let span = tokens[p..<(p + phrase.count)]
        return zip(phrase, span).allSatisfy { $0 == $1.norm } && !span.dropFirst().contains { $0.leading.contains("\n") }
    }

    /// Length of one marker phrase starting at `p`, or nil. A "no" is part of the
    /// marker only when punctuation follows it ("Wait, no," / "Actually no, a
    /// toggle") or it runs into another marker word ("No wait,"); "Actually no
    /// changes are needed" is the start of what is meant.
    static func markerPhraseLength(_ tokens: [Token], at p: Int) -> Int? {
        var q = p
        while q < tokens.count, q - p < 3, commandLeads.contains(tokens[q].norm) { q += 1 }
        if q > p {
            guard let command = commandPhrases.first(where: { matches($0, tokens, at: q) }) else { return nil }
            return q - p + command.count
        }
        for phrase in markerPhrases where matches(phrase, tokens, at: p) {
            if phrase == ["no"] {
                let punctuated = tokens[p].trailingPunctuation != nil
                let chained = p + 1 < tokens.count && chainWords.contains(tokens[p + 1].norm)
                guard punctuated || chained else { return nil }
            }
            return phrase.count
        }
        return nil
    }

    /// Index just past the marker that starts at `m`: its chain of marker phrases,
    /// inside one paragraph, at most about five words, counting only phrases that
    /// are closed: punctuation ends them ("Wait, no,"), they never take an object
    /// ("actually"), or the next phrase of the chain is closed ("No wait,"). "delete
    /// that file", "never mind the tests", "make that change", "Wait for review" and
    /// "I mean it" run into their object: that is what is meant, not the marker.
    /// `m` itself when even the first phrase is not closed.
    static func markerEnd(_ tokens: [Token], from m: Int) -> Int {
        var phrases: [Range<Int>] = []
        var p = m
        while p < tokens.count, p - m < 5, p == m || !tokens[p].leading.contains("\n"),
              let length = markerPhraseLength(tokens, at: p) {
            phrases.append(p..<(p + length))
            p += length
        }
        // From the end: a phrase is closed when it is itself, or when the next one is.
        var closed = Array(repeating: false, count: phrases.count)
        for i in phrases.indices.reversed() {
            let range = phrases[i]
            closed[i] = tokens[range.upperBound - 1].trailingPunctuation != nil
                || objectless.contains(range.map { tokens[$0].norm })
                || (i + 1 < phrases.count && closed[i + 1])
        }
        var end = m
        for i in phrases.indices {
            guard closed[i] else { break }
            end = phrases[i].upperBound
        }
        return end
    }

    /// What may go right after a marker, besides the marker itself: hesitation
    /// sounds, and asides set off by punctuation that carry no content.
    private static let fillerSounds: Set<String> = ["um", "umm", "uh", "uhh", "hmm", "er", "erm"]
    private static let fillerPhrases: [[String]] = [
        ["you", "know", "what"], ["let", "me", "see"], ["you", "know"], ["i", "mean"], ["i", "meant"],
        ["let's", "see"], ["okay"], ["ok"], ["well"],
    ]

    /// Index just past the fillers that directly follow `p`. A filler phrase counts
    /// only when punctuation ends it ("you know what," but not "you know the
    /// answer"); a hesitation sound always counts.
    static func fillerEnd(_ tokens: [Token], from start: Int) -> Int {
        var p = start
        outer: while p < tokens.count, !tokens[p].leading.contains("\n") {
            if fillerSounds.contains(tokens[p].norm) { p += 1; continue }
            for phrase in fillerPhrases where matches(phrase, tokens, at: p)
                && tokens[p + phrase.count - 1].trailingPunctuation != nil {
                p += phrase.count
                continue outer
            }
            break
        }
        return p
    }

    /// Whether a chain of fillers (`fillerEnd`'s own rule: sounds, and closed
    /// phrases that carry punctuation) runs from `start` and ends exactly at `end`.
    static func fillersEndExactly(_ tokens: [Token], from start: Int, at end: Int) -> Bool {
        var p = start
        outer: while p < end {
            if fillerSounds.contains(tokens[p].norm) { p += 1; continue }
            for phrase in fillerPhrases where matches(phrase, tokens, at: p)
                && tokens[p + phrase.count - 1].trailingPunctuation != nil {
                p += phrase.count
                continue outer
            }
            return false
        }
        return p == end
    }

    /// The guard, structural: a correction removes what was said BEFORE its marker
    /// and keeps what was said AFTER it. Every deleted run must:
    /// - stay inside one paragraph;
    /// - hold a marker, and start before its first one (something is taken back);
    /// - start no earlier than that marker's sentence, or the sentence before it
    ///   when the marker opens its sentence (and not across a paragraph start);
    /// - delete the whole of its last marker (`markerEnd`), and leave no marker
    ///   standing right after the cut;
    /// - after EVERY marker in the run, delete nothing but its closed marker
    ///   phrases and fillers (`fillerEnd`): every content word said after a marker
    ///   survives, so the retracted version can never be the one kept;
    /// - leave at least `minKeptAfter` words of the marker's sentence (or of the next one,
    ///   after a filler that ends it: "you know what?");
    /// - delete no negation after the marker (belt and braces: fillers hold none).
    /// A negation before the marker may go only when the kept text restates the word
    /// right after it (`Don't ship it. Actually, ship it.`); otherwise it is refused.
    static func check(runs: [Range<Int>], tokens: [Token], markers: [Int]) -> GuardFailure? {
        for run in runs {
            if run.dropFirst().contains(where: { tokens[$0].leading.contains("\n") }) { return .crossesParagraph }
            let inRun = markers.filter { run.contains($0) }
            guard let m = inRun.min() else { return .noMarkerInRun }
            guard m > run.lowerBound else { return .nothingBeforeMarker }
            let own = sentenceStart(tokens, m)
            let lower = (own == m && m > 0 && !tokens[m].leading.contains("\n")) ? sentenceStart(tokens, m - 1) : own
            guard run.lowerBound >= lower else { return .outsideWindow }
            let k = inRun.max()!
            // The whole last marker goes, and no marker is left standing right after the cut.
            guard run.upperBound >= markerEnd(tokens, from: k), !markers.contains(run.upperBound) else { return .keepsMarker }
            // After EVERY marker in the run, only its closed marker phrases and fillers may go:
            // what was said between two markers is kept like what was said after the last.
            for j in inRun {
                guard run.upperBound <= fillerEnd(tokens, from: markerEnd(tokens, from: j)) else { return .deletesAfterMarker }
            }
            // The speech engine punctuates "you know what" as a sentence of its own ("Actually,
            // you know what? The newsletter is better."), so the marker's sentence ends at the
            // filler and the real replacement is the NEXT sentence. The comma form was already
            // accepted, so count that next sentence as kept, but only when the fillers after the
            // marker end exactly at the sentence end, the cut ends exactly there too, and the next
            // sentence is in the same paragraph. Counting the next sentence whenever only markers
            // and fillers follow was measured and rejected: it accepted "Should we merge?
            // Actually, no. Let's wait for review." and "Hi everyone. Sorry. I was late.". The
            // negation check below must use the same end, or its range runs backwards and crashes.
            let sEnd = sentenceEnd(tokens, k)
            var keptEnd = sEnd
            let next = sEnd + 1
            let mEnd = markerEnd(tokens, from: k)
            if next < tokens.count, !tokens[next].leading.contains("\n"),
               mEnd < next, fillerEnd(tokens, from: mEnd) >= next,
               fillersEndExactly(tokens, from: mEnd, at: next), run.upperBound == next {
                keptEnd = sentenceEnd(tokens, next)
            }
            guard keptEnd - (run.upperBound - 1) >= minKeptAfter else { return .noReplacementLeft }
            let phraseEnd = markerEnd(tokens, from: k)
            if (phraseEnd..<run.upperBound).contains(where: { isNegation(tokens[$0]) }) { return .deletesNegation }
            // A negation said before the marker may go only when the kept text restates the
            // word it negated: "Don't ship it. Actually, ship it." keeps "ship"; "Don't merge
            // yet. Actually, the tests pass now." would drop a standing instruction.
            for i in run.lowerBound..<m where isNegation(tokens[i]) {
                var w = i + 1
                while w < m, isNegation(tokens[w]) { w += 1 }
                guard w < m else { return .deletesNegation }
                let negated = tokens[w].norm
                guard (run.upperBound...keptEnd).contains(where: { tokens[$0].norm == negated }) else { return .deletesNegation }
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
    static func askClaude(_ text: String, timeout: TimeInterval = claudeBudget, completion: @escaping (String?, String?) -> Void) -> URLSessionDataTask? {
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
        request.timeoutInterval = timeout
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
