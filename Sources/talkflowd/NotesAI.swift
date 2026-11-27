import Foundation

// Summary and Ask for meeting notes, with the user's own Anthropic or OpenAI key: the pure part. Prompts, the
// JSON schema, request builders, token estimates and the long-meeting split, reply validation, citation parsing,
// stream event parsing and error wording. No networking here (NotesAIClient) and no state (NoteAssistant), so all
// of it is checked by `--notestest` on canned replies.
//
// API details were read from the live documentation on 2026-11-23 (platform.claude.com/docs,
// developers.openai.com/api/docs). Not confirmed there, and so handled defensively: OpenAI's stream event names
// other than response.created, response.output_text.delta, response.completed and error; the Response status
// values; and OpenAI's error body shape.

// MARK: - Provider, model, access

enum NotesProvider: String, Codable, Equatable {
    case anthropic
    case openAI = "openai"

    /// "Anthropic" or "OpenAI", as shown to the user and stored in summaries.
    var name: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openAI: return "OpenAI"
        }
    }

    var keyProvider: APIKeys.Provider {
        switch self {
        case .anthropic: return .anthropic
        case .openAI: return .openAI
        }
    }
}

/// The models offered for meeting notes. Ids from each provider's models page (2026-11-23).
enum NotesAIModel: String, CaseIterable, Equatable {
    case claudeHaiku = "claude-haiku-5-5"
    case claudeSonnet = "claude-sonnet-5-5"
    case claudeOpus = "claude-opus-5-5"
    case gptLuna = "gpt-6-luna"
    case gptSol = "gpt-6.2-sol"
    case gptAstra = "gpt-6.2-astra"

    var provider: NotesProvider {
        switch self {
        case .claudeHaiku, .claudeSonnet, .claudeOpus: return .anthropic
        case .gptLuna, .gptSol, .gptAstra: return .openAI
        }
    }

    /// "Claude Haiku 5.5", "Claude Sonnet 5.5", "Claude Opus 5.5", "GPT-6 Luna", "GPT-6.2 Sol", "GPT-6.2 Astra".
    var shortTitle: String {
        switch self {
        case .claudeHaiku: return "Claude Haiku 5.5"
        case .claudeSonnet: return "Claude Sonnet 5.5"
        case .claudeOpus: return "Claude Opus 5.5"
        case .gptLuna: return "GPT-6 Luna"
        case .gptSol: return "GPT-6.2 Sol"
        case .gptAstra: return "GPT-6.2 Astra"
        }
    }


    /// The picker's text: shortTitle, plus " (cheapest)" for the default of its provider.
    var pickerTitle: String {
        self == NotesAIModel.defaultModel(for: provider) ? shortTitle + " (cheapest)" : shortTitle
    }

    static func defaultModel(for provider: NotesProvider) -> NotesAIModel {
        switch provider {
        case .anthropic: return .claudeHaiku
        case .openAI: return .gptLuna
        }
    }

    static func models(for provider: NotesProvider) -> [NotesAIModel] {
        allCases.filter { $0.provider == provider }
    }
    /// shortTitle for a known id, else the id itself (a summary saved by a later talkflow).
    static func title(forID id: String) -> String {
        NotesAIModel(rawValue: id)?.shortTitle ?? id
    }
}

/// Proof that the user has a saved Anthropic or OpenAI key: every request builder takes one, and the only way
/// to get one is `resolve`, which returns nil without a key. That makes "no request can be built without a
/// key" a property of the types, not of each caller. There is no separate switch: a saved key is enough
/// (NoteAssistant still asks once before the first send to a provider).
struct NotesAccess: Equatable {
    let provider: NotesProvider
    let model: NotesAIModel

    fileprivate init(provider: NotesProvider, model: NotesAIModel) {
        self.provider = provider
        self.model = model
    }

    /// Nil when there is no key. Anthropic when that key exists, otherwise OpenAI. A stored model id that is
    /// unknown or belongs to the other provider falls back to the cheapest model.
    static func resolve(hasAnthropic: () -> Bool, hasOpenAI: () -> Bool,
                        anthropicModel: String?, openAIModel: String?) -> NotesAccess? {
        func pick(_ stored: String?, _ provider: NotesProvider) -> NotesAIModel {
            if let model = NotesAIModel(rawValue: stored ?? ""), model.provider == provider { return model }
            return NotesAIModel.defaultModel(for: provider)
        }
        if hasAnthropic() { return NotesAccess(provider: .anthropic, model: pick(anthropicModel, .anthropic)) }
        if hasOpenAI() { return NotesAccess(provider: .openAI, model: pick(openAIModel, .openAI)) }
        return nil
    }

    /// The app's own settings and Keychain; tests pass `hasKey`. Reads no switch: the retired "notesUseKey"
    /// value is never read (Preferences.retireNotesSwitch).
    static func current(hasKey: (APIKeys.Provider) -> Bool = { APIKeys.hasKey($0) }) -> NotesAccess? {
        resolve(hasAnthropic: { hasKey(.anthropic) }, hasOpenAI: { hasKey(.openAI) },
                anthropicModel: Preferences.notesAnthropicModel, openAIModel: Preferences.notesOpenAIModel)
    }
}

extension NotesAccess {
    /// Posted when a key is saved or removed.
    static let changed = Notification.Name("talkflow.notesAccessChanged")
}

// MARK: - Errors

/// Everything that can go wrong, in categories. The transcript is never touched by any of them.
enum NotesAIError: Error, Equatable {
    case noKey
    case badKey
    case rateLimited(retryAfter: Double?)
    case spendCap
    case overloaded(retryAfter: Double?)
    case server(Int)
    case offline
    case timedOut
    case refused
    case truncated
    case incomplete
    case malformed
    case badTimes(Int)
    case modelUnavailable
    case request(Int)
    case tooLong(hours: Int)

    /// For logs: the case name only ("rateLimited", "server", ...), never a message from the provider.
    var category: String {
        switch self {
        case .noKey: return "noKey"
        case .badKey: return "badKey"
        case .rateLimited: return "rateLimited"
        case .spendCap: return "spendCap"
        case .overloaded: return "overloaded"
        case .server: return "server"
        case .offline: return "offline"
        case .timedOut: return "timedOut"
        case .refused: return "refused"
        case .truncated: return "truncated"
        case .incomplete: return "incomplete"
        case .malformed: return "malformed"
        case .badTimes: return "badTimes"
        case .modelUnavailable: return "modelUnavailable"
        case .request: return "request"
        case .tooLong: return "tooLong"
        }
    }

    /// Plain words for the user (see SPEC.md for the exact text).
    func message(_ provider: NotesProvider, model: NotesAIModel?) -> String {
        let p = provider.name
        func wait(_ seconds: Double?) -> String {
            guard let seconds = seconds else { return "Try again in a minute." }
            return "Try again in \(Int(ceil(seconds))) seconds."
        }
        switch self {
        case .noKey:
            return "No API key is saved for meeting notes. Add one in Settings > API keys."
        case .badKey:
            return "\(p) didn't accept your API key. Check it in Settings > API keys."
        case .rateLimited(let s):
            return "\(p) is limiting requests right now. " + wait(s)
        case .spendCap:
            return "Your \(p) account has reached its spending limit or is out of credit. Check billing with \(p), then try again."
        case .overloaded(let s):
            return "\(p) is busy right now. " + wait(s)
        case .server(let c):
            return c == 0 ? "\(p) had a problem on its side. Try again."
                : "\(p) had a problem on its side (error \(c)). Try again."
        case .offline:
            return "Couldn't reach \(p). Check your internet connection, then try again."
        case .timedOut:
            return "\(p) took too long to answer. Try again."
        case .refused:
            return "\(p) declined to write this. Nothing was saved, and the transcript is unchanged."
        case .truncated:
            return "The reply was cut off before it was finished, so it wasn't saved. Try again."
        case .incomplete:
            return "The reply stopped part way, so it wasn't saved. Try again."
        case .malformed:
            return "The reply wasn't in the expected form, so it wasn't saved. Try again."
        case .badTimes(let n):
            return "The reply pointed at \(n) transcript time\(n == 1 ? "" : "s") that don't exist in this meeting, so it wasn't saved. Try again."
        case .modelUnavailable:
            return "\(p) doesn't offer " + (model?.shortTitle ?? "this model") + " to your key. Pick another model in Settings > Meeting notes."
        case .request(let c):
            return c == 413 ? "This meeting is too long to send to \(p) in one request."
                : "\(p) turned down the request (error \(c))."
        case .tooLong(let h):
            return "This meeting is too long for talkflow to send (about \(h) hours of speech)."
        }
    }
}

// MARK: - Constants

enum NotesAI {
    static let anthropicURL = URL(string: "https://api.anthropic.com/v1/messages")!
    static let openAIURL = URL(string: "https://api.openai.com/v1/responses")!
    /// The current Messages API version (api/versioning). It removed temperature, top_p and top_k (a 400 on
    /// every model), so the builders never send them.
    static let anthropicVersion = "2026-10-21"

    /// Token estimate. Anthropic's models overview: 1M tokens is about 2.5M characters on the current tokenizer,
    /// so 2.5 characters per token for Latin text. OpenAI gives no rule of thumb (and warns against chars/4), so
    /// the same, more conservative, figure is used for both. Characters past U+07FF (CJK and the like) count one
    /// token each.
    static let charsPerToken = 2.5

    /// Documented windows: 1M tokens for claude-haiku/sonnet/opus-5-5; 1.05M for the GPT-6 models with at most
    /// 922K of input. Far above any meeting, so the limits below are set by cost and attention instead:
    /// - 90,000 estimated tokens of transcript in one summary request (about 225,000 characters, about 37,000
    ///   words, about 4 hours of two people talking at 150 words a minute). It keeps the whole prompt under
    ///   Haiku 5.5's 100,000-token line, above which every token costs five times as much.
    static let singleRequestTokens = 90_000
    /// - Longer meetings are summarised in parts of at most 60,000 estimated tokens each, then combined.
    static let partTokens = 60_000
    /// - Up to 12 parts: 720,000 estimated tokens, about 33 hours of speech. Past that talkflow says the meeting
    ///   is too long, rather than cutting it.
    static let maxSummaryTokens = 720_000
    /// - Ask sends the whole transcript every time (cached), up to 600,000 estimated tokens (about 27 hours),
    ///   which leaves room under 922K for history and the answer.
    /// Ask can send up to 600K estimated tokens, so a question on a long meeting crosses `priceStepTokens`.
    static let maxAskTokens = 600_000
    /// Haiku 5.5 charges more per token for a prompt above this size, so the Ask tab says so for long meetings.
    static let priceStepTokens = 100_000

    /// Output budgets. Adaptive thinking (on by default for Sonnet and Opus 5.5) counts against max_tokens, so
    /// these are generous; a summary itself is 1,000 to 3,000 tokens.
    static let summaryMaxOutput = 16_000
    static let askMaxOutput = 8_000
    /// Earlier questions sent with a new one, newest last.
    static let askHistoryLimit = 6
    /// A cited time is accepted if it falls within a turn, give or take this many seconds.
    static let timeTolerance: Double = 2
    /// One automatic retry at most, and only if the wait is no longer than this.
    static let maxAutoWait: Double = 30
    static let defaultRetryWait: Double = 4
    /// URLRequest.timeoutInterval (idle time between bytes). A summary arrives in one piece only when it is
    /// finished, so it gets longer.
    static let summaryTimeout: TimeInterval = 180
    static let askTimeout: TimeInterval = 60

    // MARK: Prompts (exact text in SPEC.md; the request-builder tests compare against these)

    static let contextPreamble = "The meeting transcript below was written on the user's Mac by speech recognition, so some words may be misheard. Each line starts with the time in seconds from the start of the recording in square brackets, then the speaker's name, then what they said."

    static let summaryRules = """
    You write meeting notes from the transcript above. Fill in every field:
    - title: a short, specific name for this meeting, 3 to 7 words, in sentence case (capitalize only the first word and proper nouns), such as "Q3 hiring plan and budget". No quotes, no ending period, and never just "Meeting".
    - description: what the meeting was about in at most 10 words, as a plain phrase without an ending period.
    - summary: two to four sentences on what the meeting was about and what came out of it.
    - summary_times: the times of up to five lines the summary relies on most.
    - decisions: each decision the group reached or discussed. status is "aligned" when the group agreed, "needs_discussion" when it was raised and left open, "disagreed" when people did not agree, or "shelved" when it was put off on purpose. A question raised and not answered by the end is a decision with status "needs_discussion". time is the time of the line where it was decided or raised.
    - details: the main topics of the meeting in the order they came up, usually three to eight. topic is a label of two to five words. text is one to three sentences on what was said about it, naming who said it when the transcript shows that. times are the times of up to three lines it comes from.
    - action_items: the suggested next steps: each task someone agreed to do or was asked to do. owner is that person's name exactly as it appears in the transcript, or an empty string if nobody took it on. task is a short phrase that starts with a verb. time is the time of the line where the task came up.
    - speakers: real names for the speakers labelled "Speaker 1", "Speaker 2" and so on, only when the transcript states the name directly: the speaker introduces themselves, someone addresses them by name just before or just after they speak, a roll call, or a chair calls on them by name. label is the speaker's label exactly as it appears in the transcript. name is the name as it was used in the meeting, usually a first name; keep a title if one was used, such as "Councilmember Lee". evidence is the words from the transcript line that show the name, at most 15 words, copied character for character. time is that line's time. confidence is "high" only when the line leaves no doubt which speaker it is; otherwise "low". Do not guess from the topic, a role or the way someone talks. If two speakers could match a name, leave both out. Never include "You". Use an empty list when no name is certain.
    Use only what the transcript says. Do not invent tasks, names, dates or numbers. Copy every time exactly from the square brackets at the start of a transcript line. Use an empty list when there is nothing for a field. Write in the language the meeting was held in.
    """

    static let askRules = "Answer the user's questions about the meeting in the transcript above, using only what the transcript says. Be brief: a few sentences, or a short list when the answer is a list. After each statement that comes from the transcript, cite the line it comes from by writing that line's time in square brackets exactly as it appears at the start of the line, for example [754]. If the transcript doesn't answer the question, say so plainly. Write plain text without headings, tables or Markdown formatting."

    static let combineRules = """
    You merge meeting notes. The user message holds notes written from consecutive parts of one long meeting, in order, as JSON. Write one set of notes for the whole meeting with the same fields.
    - title: a short, specific name for the whole meeting, 3 to 7 words, in sentence case. No quotes, no ending period, and never just "Meeting".
    - description: what the whole meeting was about in at most 10 words, as a plain phrase without an ending period.
    - summary: three to five sentences covering the whole meeting.
    - details: one entry per topic for the whole meeting, in the order the topics came up. Entries from different parts about the same topic become one entry that keeps their times.
    - Keep every decision and action item, except that two items saying the same thing become one, keeping the earliest time. A decision with status "needs_discussion" that a later part settles takes the later status and time.
    - Copy every time exactly from the notes. Do not make up times, tasks, names, dates or numbers.
    Write in the language the notes are written in.
    """

    static let combinePrefix = "Notes for each part of the meeting, in order:\n"

    static func summaryInstruction(part: Int, of total: Int) -> String {
        if total <= 1 { return "Write the notes for this meeting." }
        return "Write the notes for this part of the meeting (part \(part) of \(total)). The times are from the start of the whole meeting."
    }

    /// The structured-output schema, accepted by both providers: every property required,
    /// additionalProperties false, no numeric or length bounds (neither dialect allows them everywhere).
    /// `speakers` is true for a summary request and false for the combine request (names are merged from the parts).
    static func summarySchema(speakers: Bool) -> [String: Any] {
        func object(_ properties: [String: Any], _ required: [String]) -> [String: Any] {
            ["type": "object", "additionalProperties": false, "required": required, "properties": properties]
        }
        let text: [String: Any] = ["type": "string"]
        let integer: [String: Any] = ["type": "integer"]
        let integers: [String: Any] = ["type": "array", "items": integer]
        let status: [String: Any] = ["type": "string", "enum": ["aligned", "needs_discussion", "disagreed", "shelved"]]
        let confidence: [String: Any] = ["type": "string", "enum": ["high", "low"]]
        let decision = object(["text": text, "status": status, "time": integer], ["text", "status", "time"])
        let detail = object(["topic": text, "text": text, "times": integers], ["topic", "text", "times"])
        let action = object(["owner": text, "task": text, "time": integer], ["owner", "task", "time"])
        let speaker = object(
            ["label": text, "name": text, "evidence": text, "time": integer, "confidence": confidence],
            ["label", "name", "evidence", "time", "confidence"])
        var properties: [String: Any] = [
            "title": text,
            "description": text,
            "summary": text,
            "summary_times": integers,
            "decisions": ["type": "array", "items": decision] as [String: Any],
            "details": ["type": "array", "items": detail] as [String: Any],
            "action_items": ["type": "array", "items": action] as [String: Any],
        ]
        var required = ["title", "description", "summary", "summary_times", "decisions", "details", "action_items"]
        if speakers {
            properties["speakers"] = ["type": "array", "items": speaker] as [String: Any]
            required.append("speakers")
        }
        return object(properties, required)
    }

    // MARK: Disclosure (the line under every summary and answer)

    static func disclosure(provider: String, modelID: String) -> String {
        "Written by \(NotesAIModel.title(forID: modelID)) with your key. The transcript was sent to \(provider). The audio never left this Mac."
    }

    static func askFooter(_ access: NotesAccess) -> String {
        "Answers come from \(access.model.shortTitle) with your key. Each question sends this transcript to \(access.provider.name)."
    }

    /// Shown under the Ask footer for a long meeting. Same size estimate the client uses to send the transcript.
    static func askCostHint(lines: [String]) -> String? {
        let estimate = lines.reduce(0) { $0 + estimateTokens($1) + 1 }
        return estimate > priceStepTokens ? "This is a long meeting, so each question costs more than usual." : nil
    }

    /// "Write again" starts from a fresh summary, so ticks the user made would be lost. An item that has exactly
    /// the same owner and task as a done item in the old summary stays done; anything reworded starts undone.
    static func carryingDone(from old: NoteSummary?, into new: NoteSummary) -> NoteSummary {
        guard let old else { return new }
        let done = old.actionItems.filter { $0.done }
        var result = new
        for i in result.actionItems.indices {
            let item = result.actionItems[i]
            if done.contains(where: { $0.owner == item.owner && $0.task == item.task }) {
                result.actionItems[i].done = true
            }
        }
        return result
    }

    static func confirmTitle(_ provider: NotesProvider) -> String {
        "Send this meeting's transcript to \(provider.name)?"
    }

    static func confirmBody(_ provider: NotesProvider) -> String {
        "To write summaries and answer questions, talkflow sends the transcript (the words and the speakers' names) to \(provider.name) with your key, billed to your account. The audio never leaves this Mac. talkflow asks once, then does this for every meeting while your key is saved."
    }

    // MARK: Transcript text and sizes

    static func estimateTokens(_ text: String) -> Int {
        var narrow = 0
        var wide = 0
        for scalar in text.unicodeScalars {
            if scalar.value < 0x0800 { narrow += 1 } else { wide += 1 }
        }
        // ceil(narrow / 2.5) in integers, so there is no floating-point error at the boundaries.
        return (2 * narrow + 4) / 5 + wide
    }

    static func transcriptLines(_ turns: [TranscriptTurn], speakers: [NoteSpeaker]) -> [String] {
        var lines: [String] = []
        for turn in turns {
            // One turn is one line: a newline inside it would split the line the model is told to cite by its time.
            let text = turn.text
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            let name = NotesLogic.displayName(turn.speaker, in: speakers)
            lines.append("[\(Int(turn.start.rounded(.down)))] \(name): \(text)")
        }
        return lines
    }

    static func contextText(lines: [String]) -> String {
        contextPreamble + "\n\n<transcript>\n" + lines.joined(separator: "\n") + "\n</transcript>"
    }

    static func hoursOfSpeech(tokens: Int) -> Int {
        // 6 characters a word (with the space), 150 words a minute.
        Int(ceil(Double(tokens) * charsPerToken / 6 / 150 / 60))
    }

    enum SummaryPlan: Equatable {
        case single
        case parts([Range<Int>])
        case tooLong(hours: Int)
    }

    /// `tokens` is one estimate per transcript line.
    static func split(tokens: [Int]) -> SummaryPlan {
        let total = tokens.reduce(0, +)
        if total > maxSummaryTokens { return .tooLong(hours: hoursOfSpeech(tokens: total)) }
        if total <= singleRequestTokens { return .single }
        // Equal-sized parts, cut only between lines, so no line is split and no part is far bigger than the rest.
        let count = (total + partTokens - 1) / partTokens
        let target = (total + count - 1) / count
        var parts: [Range<Int>] = []
        var start = 0
        var accumulated = 0
        for (i, t) in tokens.enumerated() {
            if accumulated > 0 && (accumulated + t > partTokens || accumulated >= target) {
                parts.append(start..<i)
                start = i
                accumulated = 0
            }
            accumulated += t
        }
        parts.append(start..<tokens.count)
        return .parts(parts)
    }

    static func plan(lines: [String]) -> SummaryPlan {
        // +1 for the newline that joins the lines.
        split(tokens: lines.map { estimateTokens($0) + 1 })
    }

    static func askTooLong(lines: [String], history: [NoteQuestions.Entry]) -> NotesAIError? {
        var estimate = lines.reduce(0) { $0 + estimateTokens($1) + 1 }
        for entry in history.suffix(askHistoryLimit) {
            estimate += estimateTokens(entry.question) + estimateTokens(entry.answer)
        }
        return estimate > maxAskTokens ? .tooLong(hours: hoursOfSpeech(tokens: estimate)) : nil
    }

    // MARK: Requests

    static func summaryRequest(_ access: NotesAccess, key: String, lines: [String], part: Int, of total: Int) -> URLRequest {
        let messages: [[String: Any]] = [["role": "user", "content": summaryInstruction(part: part, of: total)]]
        return buildRequest(access, key: key, context: contextText(lines: lines), rules: summaryRules,
                            messages: messages, schema: summarySchema(speakers: true), stream: false)
    }

    static func combineRequest(_ access: NotesAccess, key: String, parts: [NoteSummary], speakers: [NoteSpeaker]) -> URLRequest {
        let items: [[String: Any]] = parts.enumerated().map { index, part in
            [
                "part": index + 1,
                "summary": part.summary,
                "summary_times": part.summaryTimes.map { Int($0) },
                "action_items": part.actionItems.map { item -> [String: Any] in
                    ["owner": item.owner.isEmpty ? "" : ownerName(item.owner, speakers: speakers),
                     "task": item.task, "time": Int(item.time)]
                },
                "decisions": NotesDoc.decisions(part).map { p -> [String: Any] in
                    ["text": p.text, "status": DecisionStatus.of(p.status).rawValue, "time": Int(p.time)]
                },
                "details": NotesDoc.details(part).map { d -> [String: Any] in
                    ["topic": d.topic, "text": d.text, "times": d.times.map { Int($0) }]
                },
            ]
        }
        let data = (try? JSONSerialization.data(withJSONObject: items, options: [.sortedKeys])) ?? Data()
        let json = String(data: data, encoding: .utf8) ?? "[]"
        let user: [String: Any] = ["role": "user", "content": combinePrefix + json]
        let combineSchema: [String: Any]? = summarySchema(speakers: false)

        switch access.provider {
        case .anthropic:
            // No cache_control: the combine input is small and used once.
            let body = anthropicBody(access, system: [["type": "text", "text": combineRules]], messages: [user],
                                     maxTokens: summaryMaxOutput, schema: combineSchema, stream: false)
            return makeRequest(url: anthropicURL, headers: anthropicHeaders(key), body: body, timeout: summaryTimeout)
        case .openAI:
            let input: [[String: Any]] = [["role": "developer", "content": combineRules], user]
            let body = openAIBody(access, input: input, maxTokens: summaryMaxOutput, schema: combineSchema, stream: false)
            return makeRequest(url: openAIURL, headers: openAIHeaders(key), body: body, timeout: summaryTimeout)
        }
    }

    static func askRequest(_ access: NotesAccess, key: String, lines: [String], history: [NoteQuestions.Entry],
                           question: String) -> URLRequest {
        var messages: [[String: Any]] = []
        for entry in history.suffix(askHistoryLimit) {
            messages.append(["role": "user", "content": entry.question])
            messages.append(["role": "assistant", "content": entry.answer])
        }
        messages.append(["role": "user", "content": question])
        return buildRequest(access, key: key, context: contextText(lines: lines), rules: askRules,
                            messages: messages, schema: nil, stream: true)
    }

    // The builders never send temperature, top_p, top_k, tool_choice or an assistant prefill: the current
    // Anthropic API rejects them, and nothing here needs them.

    private static func anthropicHeaders(_ key: String) -> [String: String] {
        ["x-api-key": key, "anthropic-version": anthropicVersion, "content-type": "application/json"]
    }

    private static func openAIHeaders(_ key: String) -> [String: String] {
        ["Authorization": "Bearer \(key)", "content-type": "application/json"]
    }

    private static func makeRequest(url: URL, headers: [String: String], body: [String: Any],
                                    timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = timeout
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    private static func anthropicBody(_ access: NotesAccess, system: [[String: Any]], messages: [[String: Any]],
                                      maxTokens: Int, schema: [String: Any]?, stream: Bool) -> [String: Any] {
        var body: [String: Any] = [
            "model": access.model.rawValue,
            "max_tokens": maxTokens,
            "system": system,
            "messages": messages,
        ]
        var format: [String: Any] = [:]
        if let schema { format = ["type": "json_schema", "schema": schema] }
        if access.model == .claudeHaiku {
            body["thinking"] = ["type": "disabled"]
            if schema != nil { body["output_config"] = ["format": format] }
        } else {
            var config: [String: Any] = ["effort": "low"]
            if schema != nil { config["format"] = format }
            body["output_config"] = config
        }
        if stream { body["stream"] = true }
        return body
    }

    private static func openAIBody(_ access: NotesAccess, input: [[String: Any]], maxTokens: Int,
                                   schema: [String: Any]?, stream: Bool) -> [String: Any] {
        var body: [String: Any] = [
            "model": access.model.rawValue,
            "store": false,
            "max_output_tokens": maxTokens,
            "reasoning": ["effort": "low"],
            "input": input,
        ]
        if let schema {
            body["text"] = ["format": ["type": "json_schema", "name": "meeting_notes", "strict": true,
                                       "schema": schema] as [String: Any]]
        }
        if stream { body["stream"] = true }
        return body
    }

    /// Summary and Ask share the shape: the transcript as a cached block, the rules, then the messages.
    private static func buildRequest(_ access: NotesAccess, key: String, context: String, rules: String,
                                     messages: [[String: Any]], schema: [String: Any]?, stream: Bool) -> URLRequest {
        let maxTokens = stream ? askMaxOutput : summaryMaxOutput
        let timeout = stream ? askTimeout : summaryTimeout
        switch access.provider {
        case .anthropic:
            let system: [[String: Any]] = [
                ["type": "text", "text": context, "cache_control": ["type": "ephemeral"]],
                ["type": "text", "text": rules],
            ]
            let body = anthropicBody(access, system: system, messages: messages, maxTokens: maxTokens,
                                     schema: schema, stream: stream)
            return makeRequest(url: anthropicURL, headers: anthropicHeaders(key), body: body, timeout: timeout)
        case .openAI:
            let input: [[String: Any]] = [["role": "developer", "content": context],
                                          ["role": "developer", "content": rules]] + messages
            let body = openAIBody(access, input: input, maxTokens: maxTokens, schema: schema, stream: stream)
            return makeRequest(url: openAIURL, headers: openAIHeaders(key), body: body, timeout: timeout)
        }
    }

    // MARK: Replies

    /// The text of a whole (non-streamed) 2xx reply, after checking it was not refused or cut off.
    static func replyText(_ provider: NotesProvider, data: Data) -> Result<String, NotesAIError> {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(.malformed)
        }
        var text = ""
        switch provider {
        case .anthropic:
            let stop = object["stop_reason"] as? String
            if stop == "refusal" { return .failure(.refused) }
            if stop == "max_tokens" || stop == "model_context_window_exceeded" { return .failure(.truncated) }
            for block in (object["content"] as? [[String: Any]]) ?? [] where block["type"] as? String == "text" {
                text += block["text"] as? String ?? ""
            }
        case .openAI:
            let status = object["status"] as? String
            if status == "incomplete" {
                let reason = (object["incomplete_details"] as? [String: Any])?["reason"] as? String
                return .failure(reason == "content_filter" ? .refused : .truncated)
            }
            if status == "failed" { return .failure(.server(0)) }
            var sawRefusal = false
            for item in (object["output"] as? [[String: Any]]) ?? [] where item["type"] as? String == "message" {
                for part in (item["content"] as? [[String: Any]]) ?? [] {
                    switch part["type"] as? String {
                    case "output_text": text += part["text"] as? String ?? ""
                    case "refusal": sawRefusal = true
                    default: break
                    }
                }
            }
            if sawRefusal { return .failure(.refused) }
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .failure(.malformed) }
        return .success(text)
    }

    private struct RawPoint: Decodable {
        let text: String
        let time: Double
        let status: String?
    }

    private struct RawAction: Decodable {
        let owner: String
        let task: String
        let time: Double
    }

    private struct RawDetail: Decodable {
        let topic: String
        let text: String
        let times: [Double]
    }

    /// A real name the reply proposes for one speaker, with the words from the transcript that show it. Only
    /// `acceptedNames` decides whether it is used.
    struct NameSuggestion: Decodable, Equatable {
        var label: String
        var name: String
        var evidence: String
        var time: Double
        var confidence: String
    }

    private struct RawSummary: Decodable {
        let summary: String
        let summaryTimes: [Double]
        let actionItems: [RawAction]
        let decisions: [RawPoint]
        let title: String?
        let description: String?
        let details: [RawDetail]?
        let speakers: [NameSuggestion]?
        let openQuestions: [RawPoint]?

        private enum CodingKeys: String, CodingKey {
            case summary
            case summaryTimes = "summary_times"
            case actionItems = "action_items"
            case decisions
            case title
            case description
            case details
            case speakers
            case openQuestions = "open_questions"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            summary = try c.decode(String.self, forKey: .summary)
            summaryTimes = try c.decode([Double].self, forKey: .summaryTimes)
            actionItems = try c.decode([RawAction].self, forKey: .actionItems)
            decisions = try c.decode([RawPoint].self, forKey: .decisions)
            title = try c.decodeIfPresent(String.self, forKey: .title)
            description = try c.decodeIfPresent(String.self, forKey: .description)
            details = try c.decodeIfPresent([RawDetail].self, forKey: .details)
            speakers = try c.decodeIfPresent([NameSuggestion].self, forKey: .speakers)
            openQuestions = try c.decodeIfPresent([RawPoint].self, forKey: .openQuestions)
        }
    }

    private static func blank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// True when the reply has an empty text, topic or task where one is needed.
    private static func hasBlankField(_ raw: RawSummary) -> Bool {
        if blank(raw.summary) { return true }
        if raw.actionItems.contains(where: { blank($0.task) }) { return true }
        if raw.decisions.contains(where: { blank($0.text) }) { return true }
        if (raw.openQuestions ?? []).contains(where: { blank($0.text) }) { return true }
        let details = raw.details ?? []
        return details.contains(where: { blank($0.topic) || blank($0.text) })
    }

    private static func allTimes(_ raw: RawSummary) -> [Double] {
        var times = raw.summaryTimes + raw.actionItems.map { $0.time } + raw.decisions.map { $0.time }
        times += (raw.openQuestions ?? []).map { $0.time }
        for d in raw.details ?? [] { times += d.times }
        return times
    }

    static func validateSummary(_ text: String, turns: [TranscriptTurn], speakers: [NoteSpeaker],
                                provider: NotesProvider, model: NotesAIModel, written: Date,
                                parts: Int) -> Result<NoteSummary, NotesAIError> {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Defensive: structured output should never fence its JSON, but a fence is cheap to tolerate.
        if t.hasPrefix("```") {
            if let newline = t.firstIndex(of: "\n") { t = String(t[t.index(after: newline)...]) } else { t = "" }
            t = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasSuffix("```") { t = String(t.dropLast(3)) }
            t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = t.data(using: .utf8), let raw = try? JSONDecoder().decode(RawSummary.self, from: data) else {
            return .failure(.malformed)
        }
        if hasBlankField(raw) { return .failure(.malformed) }
        // A time that points at no turn would be a link to nowhere, so the whole reply is refused, not patched.
        let bad = allTimes(raw).filter { snap($0, turns: turns) == nil }.count
        if bad > 0 { return .failure(.badTimes(bad)) }

        func snapped(_ time: Double) -> Double { snap(time, turns: turns) ?? time }
        func snappedUnique(_ times: [Double]) -> [Double] {
            var out: [Double] = []
            for time in times.map(snapped) where !out.contains(time) { out.append(time) }
            return out
        }
        let trim = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        let accepted = acceptedNames(raw.speakers ?? [], turns: turns, speakers: speakers)
        let ownerSpeakers = NotesDoc.applyingSuggestedNames(accepted, to: speakers)
        let actions = raw.actionItems.map { a in
            NoteSummary.ActionItem(owner: ownerKey(trim(a.owner), speakers: ownerSpeakers), task: trim(a.task),
                                   time: snapped(a.time), done: false)
        }
        let decisions = raw.decisions.map { p -> NoteSummary.Point in
            var status: String?
            if let given = p.status { status = DecisionStatus(rawValue: given) != nil ? given : DecisionStatus.aligned.rawValue }
            return NoteSummary.Point(text: trim(p.text), time: snapped(p.time), status: status)
        }
        let openQuestions = (raw.openQuestions ?? []).map { NoteSummary.Point(text: trim($0.text), time: snapped($0.time)) }
        var details: [NoteSummary.Detail]?
        if let rawDetails = raw.details {
            details = rawDetails.map { NoteSummary.Detail(topic: trim($0.topic), text: trim($0.text), times: snappedUnique($0.times)) }
        }
        return .success(NoteSummary(
            summary: trim(raw.summary),
            summaryTimes: snappedUnique(raw.summaryTimes),
            actionItems: actions,
            decisions: decisions,
            openQuestions: openQuestions,
            provider: provider.name, model: model.rawValue, written: written, parts: parts,
            details: details,
            title: NotesDoc.cleanTitle(raw.title ?? ""),
            subtitle: NotesDoc.cleanDescription(raw.description ?? ""),
            suggestedNames: accepted.isEmpty ? nil : accepted))
    }

    // MARK: Speaker names

    /// Lowercase, accents and width folded, every character that is not a letter or number a space, runs of
    /// spaces collapsed.
    private static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var out = ""
        var lastSpace = true
        for ch in folded.lowercased() {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastSpace = false
            } else if !lastSpace {
                out.append(" ")
                lastSpace = true
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    private static func collapsedSpaces(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func isGenericSpeakerName(_ lower: String) -> Bool {
        if lower == "you" || lower == "everyone else" { return true }
        guard lower.hasPrefix("speaker ") else { return false }
        let rest = lower.dropFirst("speaker ".count)
        return !rest.isEmpty && rest.allSatisfy { $0 >= "0" && $0 <= "9" }
    }

    /// The names from a reply's `speakers` that are safe to use: each one is a direct, high-confidence claim whose
    /// quote is in the transcript near the cited line, said by (or next to) that speaker, and that no other
    /// speaker or suggestion contradicts. Everything else is dropped; invalid names never fail a reply.
    static func acceptedNames(_ raw: [NameSuggestion], turns: [TranscriptTurn],
                              speakers: [NoteSpeaker]) -> [String: String] {
        var candidates: [(key: String, name: String)] = []
        for s in raw {
            guard s.confidence.lowercased() == "high" else { continue }
            let name = collapsedSpaces(s.name)
            guard !name.isEmpty, name.count <= NotesLogic.maxNameLength else { continue }
            guard !isGenericSpeakerName(name.lowercased()) else { continue }
            let label = s.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let match = speakers.first { sp in
                guard NotesDoc.isOtherVoice(sp.key), NotesDoc.nameSource(sp) == .default else { return false }
                return NotesLogic.displayName(sp.key, in: speakers).caseInsensitiveCompare(label) == .orderedSame
            }
            guard let key = match?.key else { continue }
            let ne = normalize(s.evidence)
            let nn = normalize(name)
            guard ne.count >= 2, !nn.isEmpty, (" " + ne + " ").contains(" " + nn + " ") else { continue }
            guard let c = turnIndex(for: s.time, in: turns) else { continue }
            let lo = max(0, c - NotesDoc.nameEvidenceWindow)
            let hi = min(turns.count - 1, c + NotesDoc.nameEvidenceWindow)
            guard lo <= hi else { continue }
            guard (lo...hi).contains(where: { normalize(turns[$0].text).contains(ne) }) else { continue }
            guard (lo...hi).contains(where: { turns[$0].speaker == key }) else { continue }
            candidates.append((key, name))
        }
        return settleNames(candidates, speakers: speakers)
    }

    /// Drops a key given two different names, a name given to two or more keys, and a name another speaker shows.
    private static func settleNames(_ candidates: [(key: String, name: String)],
                                    speakers: [NoteSpeaker]) -> [String: String] {
        var result: [String: String] = [:]
        var order: [String] = []
        for c in candidates {
            if !order.contains(c.key) { order.append(c.key) }
        }
        for key in order {
            let mine = candidates.filter { $0.key == key }
            let first = mine[0].name
            if mine.contains(where: { $0.name.caseInsensitiveCompare(first) != .orderedSame }) { continue }
            let sharing = Set(candidates.filter { $0.name.caseInsensitiveCompare(first) == .orderedSame }.map { $0.key })
            if sharing.count >= 2 { continue }
            let others = speakers.filter { $0.key != key }
            let clash = others.contains { NotesLogic.displayName($0.key, in: speakers).caseInsensitiveCompare(first) == .orderedSame }
            if clash { continue }
            result[key] = first
        }
        return result
    }

    /// The names of all the parts of a long meeting: the union, minus a key with two different names and a name
    /// on two or more keys.
    static func mergedNames(_ parts: [[String: String]]) -> [String: String] {
        var candidates: [(key: String, name: String)] = []
        for part in parts {
            for key in part.keys.sorted() {
                if let name = part[key] { candidates.append((key, name)) }
            }
        }
        return settleNames(candidates, speakers: [])
    }

    /// The start of the turn a cited time points at, or nil if it points at none.
    static func snap(_ time: Double, turns: [TranscriptTurn]) -> Double? {
        guard let index = snapIndex(time, turns: turns) else { return nil }
        return turns[index].start
    }

    /// The model reads whole seconds off the line labels, so distance is measured from the rounded-down start.
    private static func snapIndex(_ time: Double, turns: [TranscriptTurn]) -> Int? {
        var best: Int?
        var bestDistance = Double.infinity
        for (index, turn) in turns.enumerated() {
            guard turn.start - timeTolerance <= time, time <= max(turn.end, turn.start) + timeTolerance else { continue }
            let distance = abs(turn.start.rounded(.down) - time)
            if distance < bestDistance {
                best = index
                bestDistance = distance
            }
        }
        return best
    }

    /// The row to jump to for a stored time.
    static func turnIndex(for time: Double, in turns: [TranscriptTurn]) -> Int? {
        if let exact = turns.firstIndex(where: { $0.start == time }) { return exact }
        return snapIndex(time, turns: turns)
    }

    static func ownerKey(_ owner: String, speakers: [NoteSpeaker]) -> String {
        let trimmed = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        // A speaker key, not the name, so a later rename of that speaker carries over to the action item.
        for speaker in speakers
        where NotesLogic.displayName(speaker.key, in: speakers).caseInsensitiveCompare(trimmed) == .orderedSame {
            return speaker.key
        }
        return trimmed
    }

    static func ownerName(_ owner: String, speakers: [NoteSpeaker]) -> String {
        if speakers.contains(where: { $0.key == owner }) { return NotesLogic.displayName(owner, in: speakers) }
        return owner.isEmpty ? "No owner" : owner
    }

    enum AnswerSegment: Equatable {
        case text(String)
        case cite(Double)
    }

    static func parseAnswer(_ answer: String, turns: [TranscriptTurn]) -> (segments: [AnswerSegment], times: [Double]) {
        guard let regex = try? NSRegularExpression(pattern: "\\[([^\\[\\]]{1,40})\\]") else {
            return ([.text(answer)], [])
        }
        let ns = answer as NSString
        var segments: [AnswerSegment] = []
        var times: [Double] = []
        var pending = ""
        var cursor = 0
        for match in regex.matches(in: answer, range: NSRange(location: 0, length: ns.length)) {
            pending += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            cursor = match.range.location + match.range.length
            let inside = ns.substring(with: match.range(at: 1))
            var snappedTimes: [Double] = []
            var allCite = true
            for token in inside.split(separator: ",", omittingEmptySubsequences: false) {
                let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
                if let seconds = citedSeconds(trimmed), let snapped = snap(seconds, turns: turns) {
                    snappedTimes.append(snapped)
                } else {
                    allCite = false
                    break
                }
            }
            if allCite {
                if !pending.isEmpty { segments.append(.text(pending)) }
                pending = ""
                for time in snappedTimes {
                    segments.append(.cite(time))
                    if !times.contains(time) { times.append(time) }
                }
            } else {
                // Not a citation (or one that points nowhere): the user sees the brackets as written.
                pending += ns.substring(with: match.range)
            }
        }
        pending += ns.substring(from: cursor)
        if !pending.isEmpty { segments.append(.text(pending)) }
        return (segments, times)
    }

    /// "754", "754s", "12:34" or "1:02:03" as seconds; nil for anything else.
    private static func citedSeconds(_ token: String) -> Double? {
        func digits(_ s: Substring, _ range: ClosedRange<Int>) -> Int? {
            guard range.contains(s.count), s.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return nil }
            return Int(s)
        }
        let parts = token.split(separator: ":", omittingEmptySubsequences: false)
        switch parts.count {
        case 1:
            var number = parts[0]
            if number.hasSuffix("s") { number = number.dropLast() }
            return digits(number, 1...6).map(Double.init)
        case 2:
            guard let m = digits(parts[0], 1...2), let s = digits(parts[1], 2...2), s < 60 else { return nil }
            return Double(m * 60 + s)
        case 3:
            guard let h = digits(parts[0], 1...2), let m = digits(parts[1], 2...2), m < 60,
                  let s = digits(parts[2], 2...2), s < 60 else { return nil }
            return Double(h * 3600 + m * 60 + s)
        default:
            return nil
        }
    }

    // MARK: Errors and retries

    /// Error codes and types, from either provider, that mean the money is gone rather than "slow down".
    fileprivate static let spendCodes: Set<String> = [
        "insufficient_quota", "credit_balance_exhausted", "organization_spend_limit_exceeded",
        "project_spend_limit_exceeded", "organization_usage_limit_exceeded", "billing_hard_limit_reached",
    ]

    static func classify(status: Int, headers: [String: String], body: Data?, provider: NotesProvider, now: Date) -> NotesAIError {
        var lowered: [String: String] = [:]
        for (name, value) in headers { lowered[name.lowercased()] = value }
        let wait = retryAfter(lowered["retry-after"], now: now)

        var errType: String?
        var errCode: String?
        var detailsCode: String?
        var message = ""
        if let body = body, let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
           let error = object["error"] as? [String: Any] {
            errType = error["type"] as? String
            errCode = error["code"] as? String
            detailsCode = (error["details"] as? [String: Any])?["error_code"] as? String
            message = (error["message"] as? String ?? "").lowercased()
        }

        switch status {
        case 401, 403: return .badKey
        case 402: return .spendCap
        case 404: return .modelUnavailable
        case 413: return .request(413)
        case 429:
            if detailsCode == "enforced_spend_limit_reached" { return .spendCap }
            if let code = errCode, spendCodes.contains(code) { return .spendCap }
            if let type = errType, spendCodes.contains(type) { return .spendCap }
            return .rateLimited(retryAfter: wait)
        case 400:
            // Providers report an empty balance as a plain 400.
            for needle in ["credit balance", "spend limit", "usage limit", "billing"] where message.contains(needle) {
                return .spendCap
            }
            return .request(400)
        case 503, 529: return .overloaded(retryAfter: wait)
        case 500...599: return .server(status)
        case 400...499: return .request(status)
        default: return .server(status)
        }
    }

    static func classify(urlError: URLError) -> NotesAIError {
        urlError.code == .timedOut ? .timedOut : .offline
    }

    static func retryAfter(_ value: String?, now: Date) -> Double? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if let seconds = Double(value) { return min(600, max(1, seconds)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return min(600, max(1, date.timeIntervalSince(now)))
    }

    static func autoRetryWait(_ error: NotesAIError, attempt: Int) -> Double? {
        if attempt >= 1 { return nil }
        switch error {
        case .rateLimited(let seconds), .overloaded(let seconds):
            let wait = seconds ?? defaultRetryWait
            return wait <= maxAutoWait ? wait : nil
        case .server:
            return defaultRetryWait
        default:
            return nil
        }
    }

    static func retryNotBefore(_ error: NotesAIError, now: Date) -> Date? {
        switch error {
        case .rateLimited(let seconds?), .overloaded(let seconds?): return now.addingTimeInterval(seconds)
        default: return nil
        }
    }
}

// MARK: - Streams

enum NotesStreamEvent: Equatable {
    case text(String)
    case done
    case failed(NotesAIError)
}

/// Turns server-sent-event lines into answer text, for either provider. Keyed on each data line's JSON "type",
/// so blank lines, `event:` lines and unknown event types are ignored.
struct NotesStreamParser {
    let provider: NotesProvider
    private(set) var finished = false
    private(set) var text = ""

    init(provider: NotesProvider) {
        self.provider = provider
    }

    mutating func feed(_ line: String) -> [NotesStreamEvent] {
        if finished { return [] }
        var line = line
        if line.hasSuffix("\r") { line.removeLast() }
        if line.isEmpty { return [] }
        for ignored in [":", "event:", "id:", "retry:"] where line.hasPrefix(ignored) { return [] }
        guard line.hasPrefix("data:") else { return [] }
        var payload = String(line.dropFirst(5))
        if payload.hasPrefix(" ") { payload.removeFirst() }
        if payload == "[DONE]" {
            // The real end events come before this marker, so reaching it unfinished means the stream was cut.
            finished = true
            return [.failed(.incomplete)]
        }
        guard let data = payload.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String else { return [] }
        switch provider {
        case .anthropic: return feedAnthropic(type, object)
        case .openAI: return feedOpenAI(type, object)
        }
    }

    private mutating func finish(_ event: NotesStreamEvent) -> [NotesStreamEvent] {
        finished = true
        return [event]
    }

    private mutating func feedAnthropic(_ type: String, _ object: [String: Any]) -> [NotesStreamEvent] {
        switch type {
        case "content_block_delta":
            guard let delta = object["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                  let piece = delta["text"] as? String else { return [] }
            text += piece
            return [.text(piece)]
        case "message_delta":
            let stop = (object["delta"] as? [String: Any])?["stop_reason"] as? String
            if stop == "refusal" { return finish(.failed(.refused)) }
            if stop == "max_tokens" || stop == "model_context_window_exceeded" { return finish(.failed(.truncated)) }
            return []
        case "message_stop":
            return finish(.done)
        case "error":
            let kind = (object["error"] as? [String: Any])?["type"] as? String
            return finish(.failed(NotesStreamParser.anthropicError(kind)))
        default:
            return []
        }
    }

    private static func anthropicError(_ type: String?) -> NotesAIError {
        switch type {
        case "invalid_request_error": return .request(400)
        case "authentication_error", "permission_error": return .badKey
        case "billing_error": return .spendCap
        case "not_found_error": return .modelUnavailable
        case "request_too_large": return .request(413)
        case "rate_limit_error": return .rateLimited(retryAfter: nil)
        case "api_error": return .server(500)
        case "timeout_error": return .server(504)
        case "overloaded_error": return .overloaded(retryAfter: nil)
        default: return .server(0)
        }
    }

    private static func openAICode(_ code: String?) -> NotesAIError {
        guard let code = code else { return .server(0) }
        if NotesAI.spendCodes.contains(code) { return .spendCap }
        switch code {
        case "rate_limit_exceeded", "slow_down": return .rateLimited(retryAfter: nil)
        case "server_is_overloaded": return .overloaded(retryAfter: nil)
        case "invalid_api_key": return .badKey
        default: return .server(0)
        }
    }

    private mutating func feedOpenAI(_ type: String, _ object: [String: Any]) -> [NotesStreamEvent] {
        func incomplete() -> NotesStreamEvent {
            let details = (object["response"] as? [String: Any])?["incomplete_details"] as? [String: Any]
            return .failed(details?["reason"] as? String == "content_filter" ? .refused : .truncated)
        }
        switch type {
        case "response.output_text.delta":
            guard let piece = object["delta"] as? String else { return [] }
            text += piece
            return [.text(piece)]
        case "response.completed":
            let status = (object["response"] as? [String: Any])?["status"] as? String
            if status == nil || status == "completed" { return finish(.done) }
            if status == "incomplete" { return finish(incomplete()) }
            if status == "failed" { return finish(.failed(.server(0))) }
            return []
        case "error":
            let code = object["code"] as? String ?? (object["error"] as? [String: Any])?["code"] as? String
            return finish(.failed(NotesStreamParser.openAICode(code)))
        case "response.refusal.delta":
            return finish(.failed(.refused))
        case "response.incomplete":
            return finish(incomplete())
        case "response.failed":
            let code = ((object["response"] as? [String: Any])?["error"] as? [String: Any])?["code"] as? String
            return finish(.failed(NotesStreamParser.openAICode(code)))
        default:
            return []
        }
    }
    /// Called when the connection closes: nil if the stream finished (done or failed), else `.incomplete`.
    mutating func end() -> NotesAIError? {
        if finished { return nil }
        finished = true
        return .incomplete
    }
}
