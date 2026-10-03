import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Optional on-device punctuation pass (Settings: "AI punctuation"), using
/// Apple's built-in model - nothing is downloaded and nothing leaves the Mac.
///
/// Every local model tried before rewrote the user's words, and this one does
/// too: asked only to punctuate, it changed "three things I need you to do is"
/// to "... are". So the model never writes the result. Its answer is aligned
/// word by word with the original (`merge`), and only what sits AROUND a word
/// that both agree on is taken from it: punctuation, capitalisation and the
/// line break before it. A word the model changed, added or dropped is
/// ignored and the original word stays. The words of the output are therefore
/// exactly the words of the input, by construction, and it still has to pass
/// `SelfCorrection.isDeletionOnly` before it is used.
///
/// Off by default, because it costs time at release: measured on this M4,
/// 0.5s for a short sentence and 1.7s for a 60-word email, warm. It is
/// prewarmed when the key goes down and given a hard budget; if it is not back
/// in time, the text goes in without it.
enum Polish {
    static let instructions = """
    You fix punctuation, capitalization and line breaks in dictated text. \
    Never add, remove, reorder or change any word. You may add commas, periods, \
    colons, question marks and line breaks. Reply with the corrected text only.
    """

    /// The longest the release pass waits for the model.
    static let budget: TimeInterval = 2.5

    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// Loads the model while the user is still speaking, so release does not
    /// pay the ~3s cold start.
    static func prewarm() {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), isAvailable {
            LanguageModelSession(instructions: instructions).prewarm()
        }
        #endif
    }

    /// Calls `completion` on the main queue with the polished text, or with
    /// `text` unchanged if the model is unavailable, fails, wanders off, or
    /// misses the budget.
    static func run(_ text: String, names: [String], completion: @escaping (String) -> Void) {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), isAvailable {
            let lock = NSLock()
            var done = false
            func finish(_ result: String) {
                lock.lock(); defer { lock.unlock() }
                guard !done else { return }
                done = true
                DispatchQueue.main.async { completion(result) }
            }
            let startedAt = Date()
            let task = Task {
                do {
                    let session = LanguageModelSession(instructions: instructions)
                    let response = try await session.respond(to: text, options: GenerationOptions(temperature: 0))
                    let merged = merge(original: text, suggestion: response.content, names: names)
                    let safe = SelfCorrection.isDeletionOnly(original: text, result: merged) ? merged : text
                    print("talkflowd: AI punctuation \(safe == text ? "changed nothing" : "applied") in \(String(format: "%.2f", Date().timeIntervalSince(startedAt)))s")
                    finish(safe)
                } catch {
                    print("talkflowd: AI punctuation failed: \(error.localizedDescription)")
                    finish(text)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + budget) {
                task.cancel()
                lock.lock(); let late = !done; lock.unlock()
                if late { print("talkflowd: AI punctuation missed its \(budget)s budget, inserted without it") }
                finish(text)
            }
            return
        }
        #endif
        DispatchQueue.main.async { completion(text) }
    }

    /// The original's words, with the model's punctuation, capitalisation and
    /// line breaks wherever the two agree on the word. Pure, for `--streamtest`.
    ///
    /// Capitals the model takes away are kept for names and "I" - a model that
    /// lowercases "Samir" has not improved anything.
    static func merge(original: String, suggestion: String, names: [String] = []) -> String {
        let old = SelfCorrection.tokenize(original), new = SelfCorrection.tokenize(suggestion)
        guard !old.isEmpty, !new.isEmpty else { return original }
        let a = old.map(\.norm), b = new.map(\.norm)

        // Longest common subsequence of the normalised words.
        var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var pairs: [Int: Int] = [:]
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] { pairs[i] = j; i += 1; j += 1 }
            else if lcs[i + 1][j] >= lcs[i][j + 1] { i += 1 }
            else { j += 1 }
        }

        var out = ""
        for (index, token) in old.enumerated() {
            guard let match = pairs[index], !a[index].isEmpty else {
                out += token.leading + token.word
                continue
            }
            let suggested = new[match]
            var word = suggested.word
            if let first = token.word.first(where: \.isLetter), first.isUppercase,
               let theirs = word.first(where: \.isLetter), theirs.isLowercase,
               keepsCapital(token.norm, names: names) {
                word = token.word.prefix(while: { !$0.isLetter }) + String(first) + String(word.drop(while: { !$0.isLetter }).dropFirst())
            }
            // Spacing is the original's, except a line break the model added
            // between two words that both kept their place.
            var leading = token.leading
            if index > 0, suggested.leading.contains("\n"), pairs[index - 1] != nil,
               suggested.leading.allSatisfy({ $0 == "\n" || $0 == " " }) {
                leading = suggested.leading.contains("\n\n") ? "\n\n" : "\n"
            }
            out += leading + word
        }
        // Whitespace after the last word belongs to the original.
        return out + original.reversed().prefix(while: \.isWhitespace).reversed()
    }

    private static func keepsCapital(_ norm: String, names: [String]) -> Bool {
        if norm == "i" || norm.hasPrefix("i'") { return true }
        if names.contains(where: { $0.lowercased() == norm }) { return true }
        return ScreenContext.isName(norm.prefix(1).uppercased() + norm.dropFirst())
    }
}
