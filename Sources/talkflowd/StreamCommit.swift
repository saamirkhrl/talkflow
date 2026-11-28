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
    /// The transcript must cover the same text every time. Agreement is
    /// positional, so a transcript that starts later would shift every word
    /// index against what is already committed. After a settle the front of the
    /// hypothesis is replaced; the caller then calls `rebase` before advancing.
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

    /// Lowercased, with everything that is not a letter or digit removed; a word that is all
    /// punctuation keeps its lowercased self.
    private static func norm(_ word: String) -> String {
        let kept = word.lowercased().filter { $0.isLetter || $0.isNumber }
        return kept.isEmpty ? word.lowercased() : String(kept)
    }

    /// Re-anchors the commit point after a settle.
    ///
    /// A settle replaces the front of the hypothesis with the settle request's own text. If whisper
    /// split or merged a word there, the positional `committedWords` no longer points at the end of
    /// what is on screen, and the next commit would repeat or skip words. This finds where the
    /// committed text ends in `hypothesis` by content. `committed` (the screen) is never changed.
    ///
    /// Returns true when it found where the committed text ends; false means try again with the
    /// next hypothesis (nothing should be committed until it returns true). `force` accepts the
    /// best alignment even when it is not confirmed.
    @discardableResult
    func rebase(onto hypothesis: String, force: Bool = false) -> Bool {
        let current = Self.tokenize(hypothesis)
        previous = current

        let c = Self.tokenize(committed).map { Self.norm($0.word) }
        let h = current.map { Self.norm($0.word) }
        if c.isEmpty { committedWords = 0; return true }

        var p = 0
        while p < c.count, p < h.count, c[p] == h[p] { p += 1 }
        if p == c.count { committedWords = p; return true }

        // A bound on the work: a committed tail this long means something is badly off.
        if c.count - p > 400 {
            committedWords = min(c.count, h.count)
            return force
        }

        let cc = Array(c[p...])
        let hh = Array(h[p..<min(h.count, p + cc.count + 40)])
        let rows = cc.count, cols = hh.count
        var d = Array(repeating: Array(repeating: 0, count: cols + 1), count: rows + 1)
        for i in 0...rows { d[i][0] = i }
        for j in 0...cols { d[0][j] = j }
        if rows >= 1, cols >= 1 {
            for i in 1...rows {
                for j in 1...cols {
                    var best = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (cc[i - 1] == hh[j - 1] ? 0 : 1))
                    // "to morrow" -> "tomorrow"
                    if i >= 2, cc[i - 2] + cc[i - 1] == hh[j - 1] { best = min(best, d[i - 2][j - 1]) }
                    // "anytime" -> "any time"
                    if j >= 2, cc[i - 1] == hh[j - 2] + hh[j - 1] { best = min(best, d[i - 1][j - 2]) }
                    d[i][j] = best
                }
            }
        }

        func anchored(_ j: Int) -> Bool {
            guard j >= 1 else { return false }
            if hh[j - 1] == cc[rows - 1] { return true }
            if rows >= 2, cc[rows - 2] + cc[rows - 1] == hh[j - 1] { return true }
            if j >= 2, cc[rows - 1] == hh[j - 2] + hh[j - 1] { return true }
            return false
        }

        let minimum = (0...cols).map { d[rows][$0] }.min() ?? 0
        let tied = (0...cols).filter { d[rows][$0] == minimum }
        let pick = tied.first(where: anchored)
        let j = pick ?? tied[0]
        if pick != nil || force {
            committedWords = p + j
            return true
        }
        return false
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
