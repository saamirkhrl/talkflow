import Foundation

/// The Dictionary page's rules, on plain values so `--dictionarytest` can
/// check them without UserDefaults. The list is `Preferences.learnedWords`
/// (newest first, what whisper is biased towards); `added` is the subset the
/// user typed in, kept under `addedKey` only to label them.
enum WordList {
    static let addedKey = "dictionaryAddedWords"
    static let learnedLabel = "Learned from a fix"
    static let addedLabel = "Added by you"

    struct State: Equatable {
        var words: [String]
        var added: [String]
    }

    /// The word as typed, without surrounding spaces or newlines; nil when
    /// nothing is left.
    static func trimmed(_ raw: String) -> String? {
        let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return word.isEmpty ? nil : word
    }

    /// Puts the word at the top, the way learning a word does
    /// (`Vocabulary.remember`): any spelling of it already in the list goes,
    /// the typed spelling is kept, and the list is cut to `limit`.
    static func adding(_ raw: String, to state: State, limit: Int = Vocabulary.limit) -> State {
        guard let word = trimmed(raw) else { return state }
        var words = state.words.filter { $0.caseInsensitiveCompare(word) != .orderedSame }
        words.insert(word, at: 0)
        words = Array(words.prefix(limit))
        var added = state.added.filter { $0.caseInsensitiveCompare(word) != .orderedSame }
        added.insert(word, at: 0)
        return State(words: words, added: pruned(added, to: words))
    }

    static func removing(_ word: String, from state: State) -> State {
        let words = state.words.filter { $0.caseInsensitiveCompare(word) != .orderedSame }
        return State(words: words, added: pruned(state.added, to: words))
    }

    static func isAddedByUser(_ word: String, in state: State) -> Bool {
        state.added.contains { $0.caseInsensitiveCompare(word) == .orderedSame }
    }

    static func source(of word: String, in state: State) -> String {
        isAddedByUser(word, in: state) ? addedLabel : learnedLabel
    }

    /// Only hand-added words still in the list, so the second key never
    /// outgrows the first.
    static func pruned(_ added: [String], to words: [String]) -> [String] {
        added.filter { word in words.contains { $0.caseInsensitiveCompare(word) == .orderedSame } }
    }
}
