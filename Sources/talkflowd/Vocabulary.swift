import AppKit
import Foundation

/// Learns the words whisper gets wrong from the fixes the user makes by hand,
/// the way Wispr Flow's dictionary does: dictate "Shivon", correct it to
/// "Siobhan", and from then on "Siobhan" is in whisper's prompt.
///
/// A while after a dictation goes in, the field is read again (and again at
/// the next hold in the same app). A word counts as a fix only when it sits
/// where a dictated word was, between the same two neighbours, and the
/// dictated word was not a real word - whisper spelled something it did not
/// know, and the user spelled it properly. Replacing a real word ("Friday" ->
/// "Thursday") is changing your mind, not teaching a spelling, and the macOS
/// dictionary knows nearly every name, so the dictated word is what tells the
/// two apart: measured, "Shivon" is unknown while "Siobhan" and "Thursday"
/// are both known. Learned words are listed in Settings and can be removed.
enum Vocabulary {
    static let limit = 50

    /// The words in `fieldText` that correct a word of `inserted`. Pure apart
    /// from `isKnown`, which tests replace, for `--streamtest`.
    static func fixes(inserted: String, fieldText: String, isKnown: (String) -> Bool = isKnownWord) -> [String] {
        let typed = SelfCorrection.tokenize(inserted)
        let now = SelfCorrection.tokenize(fieldText)
        let nowWords = Set(now.map(\.norm))
        guard typed.count >= 3, now.count >= 3 else { return [] }

        var found: [String] = []
        for i in 1..<(typed.count - 1) where !nowWords.contains(typed[i].norm) {
            let before = typed[i - 1].norm, after = typed[i + 1].norm
            for k in 1..<(now.count - 1) where now[k - 1].norm == before && now[k + 1].norm == after {
                let candidate = now[k].word.trimmingCharacters(in: .punctuationCharacters)
                let old = typed[i].norm, new = candidate.lowercased()
                // Plausibly the same word: same first letter or under half
                // its letters changed.
                guard candidate.count >= 3, new != old, candidate.allSatisfy({ $0.isLetter || $0.isNumber || "'-".contains($0) }),
                      !isKnown(typed[i].word.trimmingCharacters(in: .punctuationCharacters)),
                      old.first == new.first || distance(old, new) <= max(old.count, new.count) / 2 else { continue }
                if !found.contains(candidate) { found.append(candidate) }
            }
        }
        return found
    }

    /// Adds `words` to the learned list, newest first, without duplicates.
    static func remember(_ words: [String]) {
        guard !words.isEmpty else { return }
        var list = Preferences.learnedWords.filter { old in !words.contains { $0.caseInsensitiveCompare(old) == .orderedSame } }
        list.insert(contentsOf: words, at: 0)
        Preferences.learnedWords = Array(list.prefix(limit))
        print("talkflowd: learned \(words.count) word(s) from a correction")
    }

    static func forget(_ word: String) {
        Preferences.learnedWords.removeAll { $0 == word }
    }

    /// Whether the macOS English dictionary (including words the user taught
    /// it) accepts `word`. Main thread only, as NSSpellChecker is.
    static func isKnownWord(_ word: String) -> Bool {
        NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: "en", wrap: false,
                                            inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
    }

    /// Levenshtein distance.
    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]
            row[0] = i
            for j in 1...b.count {
                let current = row[j]
                row[j] = a[i - 1] == b[j - 1] ? previous : min(previous, row[j], row[j - 1]) + 1
                previous = current
            }
        }
        return row[b.count]
    }
}
