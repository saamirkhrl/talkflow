import Foundation

/// Removes filler words from a transcript. Deterministic and instant.
///
/// This used to send the transcript to a local Ollama model. Measured against
/// real dictation, that model was rejected by its own safety check on every
/// single attempt: asked to clean "Dear Sarah, can you please review the pitch
/// deck", qwen2.5:1.5b replied "Sure, I can review the pitch deck for you";
/// asked to clean a sentence about a UI preference, it replied "I understand
/// your preference... would you like assistance?". mistral:7b did no better -
/// 0 of 4 accepted - while costing up to 3s per call. Both models rewrite rather
/// than edit, and rewriting the user's words is the one thing this must not do.
///
/// So the LLM is gone from the pipeline entirely. What is left only ever deletes
/// exact words from a fixed list, which cannot invent or alter anything.
///
/// Self-corrections ("meet at 2, no wait, 3") are collapsed by rules in
/// SelfCorrection instead, under the same deletion-only rule. No local model
/// could do it without also rephrasing, and a rephrase is worse than a stutter.
enum Cleanup {
    /// Only sounds that are never words. "like", "you know" and "i mean" were
    /// here and are deliberately gone: they are real English as often as they are
    /// filler, and stripping them turned "I would like a coffee" into "I would a
    /// coffee". Deleting a word the user actually said is worse than leaving a
    /// filler in, and no rule can tell the two apart - that judgement needs a
    /// model, and every model tried here rewrote the sentence instead.
    private static let fillers = ["um", "umm", "ummm", "uh", "uhh", "uhhh", "erm", "hmm", "mmm"]

    private static let fillerPattern: NSRegularExpression = {
        let alternation = fillers
            .sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        return try! NSRegularExpression(pattern: "\\b(?:\(alternation))\\b[,]?\\s*", options: [.caseInsensitive])
    }()

    static func tidy(_ raw: String) -> String {
        let ns = raw as NSString
        var text = fillerPattern.stringByReplacingMatches(
            in: raw,
            range: NSRange(location: 0, length: ns.length),
            withTemplate: ""
        )

        text = text.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s+([,.!?;:])", with: "$1", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return text }

        // Removing a leading filler can leave the sentence starting lowercase.
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}
