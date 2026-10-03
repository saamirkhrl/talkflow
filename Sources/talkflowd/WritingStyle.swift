import Foundation

/// How dictated text is written. Applied as the last step of `Dictation.render`
/// and again after the punctuation pass, which may put capitals back.
enum WritingStyle: String, CaseIterable {
    /// Capitals and full stops - the original behaviour.
    case formal
    /// Lowercase and no closing full stop, as in a chat message. "I" stays.
    case casual
    /// Every letter lowercase, punctuation kept.
    case lowercase

    var title: String {
        switch self {
        case .formal: return "Formal"
        case .casual: return "Casual"
        case .lowercase: return "all lowercase"
        }
    }

    var detail: String {
        switch self {
        case .formal: return "Capitals and full stops."
        case .casual: return "lowercase, no full stop at the end, \"I\" kept."
        case .lowercase: return "every letter lowercase."
        }
    }

    /// Pure, for `--streamtest`. Only letter case and the closing full stop
    /// change; the words are always the same words.
    func apply(_ text: String) -> String {
        switch self {
        case .formal:
            return text
        case .lowercase:
            return text.lowercased()
        case .casual:
            var out = text.lowercased()
            // "I", "I'm", "I'll": a lowercase "i" alone reads as a typo.
            out = out.replacingOccurrences(of: #"(?<![\p{L}\p{N}])i(?=$|[^\p{L}\p{N}]|'[a-z])"#,
                                           with: "I", options: .regularExpression)
            // The closing full stop, unless it ends an ellipsis.
            let trimmed = out.reversed().prefix(while: \.isWhitespace).count
            let body = out.dropLast(trimmed)
            if body.hasSuffix("."), !body.hasSuffix("..") {
                out = String(body.dropLast()) + out.suffix(trimmed)
            }
            return out
        }
    }
}
