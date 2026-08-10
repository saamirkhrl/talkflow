import Foundation

/// Decides how much of a still-changing transcript is safe to put on screen.
///
/// Every tick the whole audio buffer is re-transcribed, and whisper revises what
/// it already said as more audio arrives: "to" becomes "two", "pleased" becomes
/// "please", punctuation slides a word to the left, a spoken "water emoji"
/// collapses into a symbol. Typing each transcript in full meant diffing it
/// against the screen and rewriting whatever had moved - text visibly
/// highlighting, deleting and retyping several times a second, and words getting
/// mangled when a rewrite landed badly. That churn was generated here, upstream
/// of the writing layer, by re-deciding the whole string every tick; no amount of
/// work in FieldSync could have fixed it.
///
/// This is LocalAgreement-2, the standard streaming-ASR answer. A word is
/// committed only once two consecutive transcripts agree on it, and once
/// committed it is never taken back. Everything still moving is held here rather
/// than shown, so the caller only ever appends - no deletes, no flash. Agreement
/// is not proof: a word can still be wrong (whisper can repeat a mistake twice,
/// or a spoken command can complete after its first half committed). That is
/// repaired by the single reconciliation pass at the end of the hold, which syncs
/// the field to the final transcript.
final class StreamCommit {
    /// A word plus the whitespace in front of it, kept separate so a commit can
    /// be reassembled character for character. Mid-stream a spoken "new
    /// paragraph" really is a "\n\n" between two words, and the append has to
    /// carry it verbatim.
    private struct Token: Equatable {
        let leading: String
        let word: String
    }

    /// Exactly what has been handed to the screen so far. Only ever grows, and
    /// only ever at the end.
    private(set) var committed = ""

    private var previous: [Token] = []
    private var committedWords = 0

    func reset() {
        committed = ""
        previous = []
        committedWords = 0
    }

    /// Feeds one transcript of the whole buffer. Returns the full text that
    /// should now be on screen - always the previous return value plus more - or
    /// nil when nothing new is stable enough to type.
    ///
    /// The transcript must cover the whole recording every time. Agreement is
    /// positional, so transcribing only the last few seconds would shift every
    /// word index against what is already committed.
    func advance(_ hypothesis: String) -> String? {
        let current = Self.tokenize(hypothesis)
        defer { previous = current }
        guard !current.isEmpty else { return nil }

        var agreed = 0
        while agreed < current.count, agreed < previous.count, current[agreed] == previous[agreed] {
            agreed += 1
        }

        // The last agreed word is held back until another word sits behind it.
        // Whisper is still deciding the word it is currently hearing, and a
        // two-word command ("water emoji", "new paragraph") would otherwise
        // commit its first half as a literal word before the command completed.
        let stable = min(agreed, current.count - 1)

        // Only ever forward. A shorter transcript than last time - whisper does
        // drop tail words - or a disagreement earlier than the commit point
        // leaves everything already committed exactly as it is. The slice below
        // is in range precisely because of this guard.
        guard stable > committedWords else { return nil }

        for token in current[committedWords..<stable] {
            committed += token.leading + token.word
        }
        committedWords = stable
        return committed
    }

    /// Splits into words and the whitespace preceding each one. Whitespace after
    /// the final word is dropped: it belongs in front of the word that has not
    /// arrived yet, and committing it would put a trailing space on screen.
    ///
    /// Reassembly is exact - `tokens.map { $0.leading + $0.word }.joined()` is
    /// the input again, minus that trailing whitespace - which is what lets a
    /// commit be a literal substring of the transcript rather than a re-join
    /// that could quietly normalise spacing.
    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var leading = ""
        var word = ""

        for character in text {
            if character.isWhitespace {
                if !word.isEmpty {
                    tokens.append(Token(leading: leading, word: word))
                    word = ""
                    leading = ""
                }
                leading.append(character)
            } else {
                word.append(character)
            }
        }
        if !word.isEmpty { tokens.append(Token(leading: leading, word: word)) }
        return tokens
    }
}
