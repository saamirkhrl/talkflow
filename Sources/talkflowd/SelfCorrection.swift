import Foundation

/// Collapses what people say while thinking into what they meant:
///
///     let's change that to Friday, wait no, Thursday  ->  let's change that to Thursday
///     meet at 2, no wait, 3                           ->  meet at 3
///     the the meeting                                 ->  the meeting
///     It was, you know, kind of weird.                ->  It was kind of weird.
///
/// The safety rule is the same one Cleanup and StructurePolish live by: this
/// can only DELETE WHOLE WORDS. Every rule removes a span of tokens and
/// nothing else, and the result is then checked mechanically - its words must
/// be an in-order subsequence of the input's (`isDeletionOnly`) - or the input
/// comes back untouched. Inventing, changing or reordering a word is impossible
/// by construction. That is why there is no model here: both local models
/// tried for cleanup rewrote the user's sentence instead (see Cleanup.swift).
///
/// The rules are deliberately narrow, because deleting a word the user meant
/// is worse than leaving a false start in. A correction marker counts only
/// when what follows it is a replacement of the same kind as what precedes it
/// (a day for a day, a number for a number, a name for a name), or a restart
/// that repeats the opening words of the clause. "No, I don't think so",
/// "wait, let me check" and "I like both, I mean really both" have neither and
/// are left alone. When unsure, nothing happens.
///
/// Release-only (`Dictation.render(structure: true)`): a correction deletes
/// words the live path may already have typed, and a live update may only
/// append.
enum SelfCorrection {
    struct Token {
        var leading: String
        var word: String

        /// Lowercased, with edge punctuation removed: "Friday," -> "friday".
        var norm: String { SelfCorrection.normalize(word) }
        var trailingPunctuation: Character? {
            guard let last = word.last, ",.!?;:".contains(last) else { return nil }
            return last
        }
        var endsSentence: Bool { trailingPunctuation.map { ".!?".contains($0) } ?? false }
    }

    static func apply(to text: String) -> String {
        var tokens = tokenize(text)
        // One edit per pass, re-scanned from the start, so each rule always
        // sees the text the previous one left. Bounded in case two rules ever
        // disagree about a fixed point.
        for _ in 0..<16 {
            guard let next = scratchThat(tokens) ?? typedRepair(tokens) ?? restart(tokens)
                ?? stutter(tokens) ?? hedge(tokens) else { break }
            tokens = next
        }
        let result = tokens.map { $0.leading + $0.word }.joined() + trailingWhitespace(text)
        return isDeletionOnly(original: text, result: result) ? result : text
    }

    /// The guard: `result` may only be `original` with whole words removed (and
    /// the punctuation next to them). Compared on normalised words so that a
    /// moved comma or a capital carried onto the next word still passes, while
    /// any changed, inserted or reordered word does not.
    static func isDeletionOnly(original: String, result: String) -> Bool {
        let source = tokenize(original).map(\.norm)
        var index = source.startIndex
        for word in tokenize(result).map(\.norm) {
            guard let found = source[index...].firstIndex(of: word) else { return false }
            index = source.index(after: found)
        }
        return true
    }

    // MARK: - Markers

    private struct Marker {
        let words: [String]
        /// Strong markers are corrections whatever the punctuation. Weak ones
        /// are ordinary words just as often ("I'm sorry", "I actually liked
        /// it"), so they count only after a comma or a sentence end.
        let strong: Bool
        /// "sorry" and "actually" also open a new thought ("Paris, sorry, Tom
        /// will go instead"), so their replacement must end its clause.
        let needsClauseEnd: Bool
        /// Whether an ordinary word may be swapped for another after it. "I
        /// like both, I mean really both" shows why "I mean" may not.
        var trustsPlainWords: Bool { strong || words == ["or", "rather"] || words == ["correction"] }
    }

    /// Fixed phrases. Longest first, so "or rather" wins over "rather".
    private static let markers: [Marker] = [
        Marker(words: ["or", "rather"], strong: false, needsClauseEnd: false),
        Marker(words: ["make", "that"], strong: false, needsClauseEnd: false),
        Marker(words: ["i", "mean"], strong: false, needsClauseEnd: false),
        Marker(words: ["correction"], strong: false, needsClauseEnd: false),
        Marker(words: ["rather"], strong: false, needsClauseEnd: false)
    ]

    /// Words people chain into one correction: "wait no", "no wait", "wait
    /// actually", "Wait actually no", "actually no", "sorry". Seen in real
    /// dictation, so they are matched as a run (up to three) rather than as a
    /// list of every ordering.
    private static let runWords: Set<String> = ["oh", "wait", "no", "actually", "sorry"]

    /// The marker made of the run of `runWords` starting at `index`, if any.
    /// - A lone "no" is never one: "Is it Friday? No, Thursday." is an answer.
    /// - Two or more words including "wait" are a correction whatever the
    ///   punctuation ("Friday wait no Thursday").
    /// - A run without "wait" or "no" ("sorry", "actually") also opens new
    ///   thoughts, so its replacement must end its clause.
    private static func run(at index: Int, in tokens: [Token]) -> Marker? {
        var words: [String] = []
        var i = index
        while i < tokens.count, words.count < 3, runWords.contains(tokens[i].norm),
              i == index || !tokens[i].leading.contains("\n") {
            words.append(tokens[i].norm)
            i += 1
        }
        // A lone "no" is an answer and a lone "oh" is an exclamation.
        guard !words.isEmpty, words != ["no"], words != ["oh"] else { return nil }
        let hasWait = words.contains("wait")
        return Marker(words: words, strong: hasWait && words.count >= 2,
                      needsClauseEnd: !hasWait && !words.contains("no"))
    }

    /// Markers starting at `index` that are set off the way a correction is.
    /// Returns (marker, index of the first token after it).
    private static func markers(at index: Int, in tokens: [Token]) -> [(Marker, Int)] {
        guard index > 0 else { return [] } // nothing before it to replace
        var found: [(Marker, Int)] = []
        for marker in markers + [run(at: index, in: tokens)].compactMap({ $0 }) {
            let end = index + marker.words.count
            guard end < tokens.count else { continue } // nothing after it either
            let span = tokens[index..<end]
            guard span.map(\.norm) == marker.words else { continue }
            guard !span.dropFirst().contains(where: { $0.leading.contains("\n") }),
                  !tokens[end].leading.contains("\n") else { continue }
            // "at 3pm actually, let's make that Tuesday": a lead-in that
            // restates the sentence sets the marker off just as well.
            if !marker.strong, tokens[index - 1].trailingPunctuation == nil, leadIn(at: end, in: tokens) == 0 { continue }
            found.append((marker, end))
        }
        return found
    }

    // MARK: - Rules

    /// "to Friday, wait no, Thursday", "tomorrow at 3pm. Actually, let's make
    /// that Tuesday at 2pm.": the phrase that ends at the marker is replaced
    /// by the phrase of the same shape after it. The two are aligned unit by
    /// unit, and every pair must either be the same word said again ("at",
    /// "the", "pm") or two values of the same kind (a day for a day, a number
    /// for a number, a name for a name). So "tomorrow at 3pm" -> "Tuesday at
    /// 2pm", "Monday the 5th" -> "Tuesday the 6th", "at 3 in the park" -> "at 4
    /// in the park" and "tell John" -> "tell Mike" are one rule. The shortest
    /// phrase that aligns wins, so as little as possible is deleted.
    ///
    /// A time said as several numbers is one unit on either side: "3 p.m.
    /// Wait actually no 7 30 p.m." replaces "3" with "7 30", and "2 30, no
    /// wait, 3" replaces all of "2 30" rather than leaving "2 3".
    private static func typedRepair(_ tokens: [Token]) -> [Token]? {
        for m in tokens.indices {
            for (marker, markerEnd) in markers(at: m, in: tokens) {
                let staticLead = leadIn(at: markerEnd, in: tokens)
                // A weak marker that only the lead-in set off needs that lead-in.
                let setOff = marker.strong || tokens[m - 1].trailingPunctuation != nil
                for lead in staticLead > 0 ? (setOff ? [staticLead, 0] : [staticLead]) : [0] {
                    let after = markerEnd + lead
                    guard after < tokens.count else { continue }
                    let old = unitsBackward(from: m, in: tokens)
                    let new = unitsForward(from: after, in: tokens)
                    for n in 1...maxUnits where n <= old.count && n <= new.count {
                        let olds = Array(old.prefix(n).reversed()), news = Array(new.prefix(n))
                        guard aligns(olds, news, tokens: tokens, marker: marker, lead: lead) else { continue }
                        return delete(tokens, olds[0].range.lowerBound..<after)
                    }
                }
            }
        }
        return nil
    }

    /// Longest old or new phrase, in units: "at 3 in the park" is five.
    private static let maxUnits = 6

    /// A value (a run of numbers counts as one) or a single other word.
    private struct Unit {
        let range: Range<Int>
        let kind: Kind
        let norm: String
    }

    /// Units ending right before `end`, nearest first, that stay inside one
    /// sentence and one line and have no punctuation inside them: only the
    /// unit right before the marker may carry a comma or a full stop.
    private static func unitsBackward(from end: Int, in tokens: [Token]) -> [Unit] {
        var units: [Unit] = []
        var i = end - 1
        while i >= 0, units.count < maxUnits {
            if !units.isEmpty {
                guard tokens[i].trailingPunctuation == nil || isAbbreviation(tokens[i]),
                      !tokens[i + 1].leading.contains("\n") else { break }
            }
            var start = i
            if kind(of: tokens, at: i) == .number {
                while start > 0, i - start < 2, kind(of: tokens, at: start - 1) == .number,
                      tokens[start - 1].trailingPunctuation == nil,
                      !tokens[start].leading.contains("\n") { start -= 1 }
            }
            units.append(unit(start..<(i + 1), in: tokens))
            i = start - 1
        }
        return units
    }

    /// Units starting at `start`, in order, up to the first punctuation: a
    /// replacement ends where its clause does.
    private static func unitsForward(from start: Int, in tokens: [Token]) -> [Unit] {
        var units: [Unit] = []
        var i = start
        while i < tokens.count, units.count < maxUnits {
            if i > start { guard !tokens[i].leading.contains("\n") else { break } }
            var end = i + 1
            if kind(of: tokens, at: i) == .number {
                while end < tokens.count, end - i < 3, tokens[end - 1].trailingPunctuation == nil,
                      kind(of: tokens, at: end) == .number,
                      !tokens[end].leading.contains("\n") { end += 1 }
            }
            units.append(unit(i..<end, in: tokens))
            if let p = tokens[end - 1].trailingPunctuation, !isAbbreviation(tokens[end - 1]) || p != "." { break }
            i = end
        }
        return units
    }

    private static func unit(_ range: Range<Int>, in tokens: [Token]) -> Unit {
        let kind = range.count > 1 ? .number : self.kind(of: tokens, at: range.lowerBound)
        return Unit(range: range, kind: kind, norm: tokens[range].map(\.norm).joined(separator: " "))
    }

    /// "p.m." and "a.m." end in a full stop that ends nothing.
    private static func isAbbreviation(_ token: Token) -> Bool {
        ["p.m", "a.m"].contains(token.norm)
    }

    /// Whether `new` can stand in for `old`, pair by pair. At least one value
    /// must change; an ordinary word may change only on its own after an
    /// unmistakable marker ("I like cats, wait no, dogs.", "the red folder,
    /// wait no, the blue folder."), or next to a changed value ("Sarah from sales, sorry, Tom from
    /// marketing."). A changed name or plain word, and any marker that also
    /// opens new thoughts ("sorry", "actually"), needs the replacement to end
    /// its clause: "Paris, sorry, Tom will go instead" is not a correction.
    private static func aligns(_ old: [Unit], _ new: [Unit], tokens: [Token], marker: Marker, lead: Int) -> Bool {
        var changedValues = 0, changedWords: [Int] = [], changedName = false
        for (index, (o, r)) in zip(old, new).enumerated() where o.norm != r.norm {
            guard o.kind == r.kind else { return false }
            if o.kind == .other {
                guard !stutterWords.contains(o.norm), !stutterWords.contains(r.norm) else { return false }
                changedWords.append(index)
            } else {
                changedValues += 1
                if o.kind == .name { changedName = true }
            }
        }
        if changedValues == 0 {
            // "There is no wait, fine" must not lose "is": the old word is set
            // off by punctuation, and nothing restates the sentence first.
            guard changedWords.count == 1, lead == 0, marker.trustsPlainWords,
                  tokens[old[old.count - 1].range.upperBound - 1].trailingPunctuation != nil else { return false }
        }
        if marker.needsClauseEnd || changedName || !changedWords.isEmpty {
            let end = new[new.count - 1].range.upperBound
            guard end == tokens.count || tokens[end - 1].trailingPunctuation != nil else { return false }
        }
        return true
    }

    private static let leadIns: [[String]] = [
        ["let's", "make", "that"], ["let's", "make", "it"], ["make", "that"], ["make", "it"],
        ["let's", "say"], ["let's", "do"], ["let's", "go", "with"], ["i", "meant", "to", "say"],
        ["i", "mean", "to", "say"], ["i", "meant"], ["i", "mean"], ["i", "said"], ["it", "should", "be"],
        ["it", "is"], ["it's"], ["how", "about"]
    ]

    /// How many words at `index` restate the sentence before the replacement
    /// ("let's make that"). Only when a word still follows, and only when they
    /// run on without punctuation or a line break.
    private static func leadIn(at index: Int, in tokens: [Token]) -> Int {
        for phrase in leadIns where index + phrase.count < tokens.count {
            let span = tokens[index..<(index + phrase.count)]
            guard span.map(\.norm) == phrase,
                  !span.contains(where: { $0.trailingPunctuation != nil }),
                  !span.contains(where: { $0.leading.contains("\n") }) else { continue }
            return phrase.count
        }
        return 0
    }

    /// "I went home, I mean I went to the office": the words after the marker
    /// restart the clause, repeating at least two of its words from where they
    /// first appeared. Everything from that point through the marker goes.
    private static func restart(_ tokens: [Token]) -> [Token]? {
        for m in tokens.indices {
            for (_, after) in markers(at: m, in: tokens) where after + 1 < tokens.count {
                guard !tokens[after + 1].leading.contains("\n") else { continue }
                let opening = [tokens[after].norm, tokens[after + 1].norm]
                let start = max(clauseStart(tokens, before: m - 1), m - 12)
                var p = m - 2
                while p >= start {
                    if tokens[p].norm == opening[0], tokens[p + 1].norm == opening[1], tokens[p].trailingPunctuation == nil {
                        return delete(tokens, p..<after)
                    }
                    p -= 1
                }
            }
        }
        return nil
    }

    private static let retractVerbs: Set<String> = ["scratch", "strike", "ignore", "disregard"]

    /// "let's do it tomorrow, scratch that (or strike / ignore / disregard that),
    /// let's do it Monday": drops the
    /// clause before the marker. "scratch that" must be set off by punctuation
    /// on both sides - "scratch that itch" is not a command - and something must
    /// follow it to be what was meant instead.
    private static func scratchThat(_ tokens: [Token]) -> [Token]? {
        for m in tokens.indices.dropFirst() where m + 2 < tokens.count {
            guard retractVerbs.contains(tokens[m].norm), tokens[m + 1].norm == "that",
                  tokens[m - 1].trailingPunctuation != nil,
                  tokens[m + 1].trailingPunctuation != nil,
                  !tokens[m + 1].leading.contains("\n"),
                  !tokens[m + 2].leading.contains("\n") else { continue }
            var start = m - 1
            while start > 0, tokens[start - 1].trailingPunctuation == nil, !tokens[start].leading.contains("\n") {
                start -= 1
            }
            return delete(tokens, start..<(m + 2))
        }
        return nil
    }

    /// Single words that are never meant twice in a row. "that that", "had
    /// had", "her her" and "very very" are real English and are not here.
    private static let stutterWords: Set<String> = [
        "a", "an", "the", "i", "to", "of", "in", "on", "at", "for", "and", "but", "or",
        "we", "you", "he", "she", "it", "they", "my", "our", "your", "his", "their",
        "this", "with", "will", "can", "would", "should", "could", "if", "be", "are",
        "was", "were", "me", "us", "them", "i'm", "it's", "we're", "you're", "they're"
    ]

    /// "the the meeting", "I I think", "we should we should go": a word from
    /// the list above, or any run of two or three words, said twice back to
    /// back. The first copy goes.
    private static func stutter(_ tokens: [Token]) -> [Token]? {
        for i in tokens.indices {
            for n in [3, 2, 1] where i + 2 * n <= tokens.count {
                let first = i..<(i + n), second = (i + n)..<(i + 2 * n)
                guard tokens[first].map(\.norm) == tokens[second].map(\.norm) else { continue }
                guard n > 1 || stutterWords.contains(tokens[i].norm) else { continue }
                // "the, the meeting" is a stutter; "Thursday. Thursday" or a
                // repeat across a line break is not.
                guard !tokens[first.dropLast()].contains(where: { $0.trailingPunctuation != nil }),
                      tokens[first.upperBound - 1].trailingPunctuation.map({ $0 == "," }) ?? true,
                      !tokens[second].contains(where: { $0.leading.contains("\n") }),
                      !tokens[first.dropFirst()].contains(where: { $0.leading.contains("\n") }) else { continue }
                return delete(tokens, first)
            }
        }
        return nil
    }

    private static let hedges: [[String]] = [
        ["you", "know"], ["i", "guess"], ["kind", "of"], ["sort", "of"], ["basically"], ["literally"]
    ]
    /// Only these may go at the end of a sentence. "It was good, kind of." is
    /// a real qualification.
    private static let trailingHedges: Set<[String]> = [["you", "know"], ["i", "guess"], ["basically"]]

    /// Hedges are removed only where commas set them off as an aside -
    /// "Basically, we", "It was, you know, kind of", "the plan, I guess." -
    /// never inside the sentence: "I guess so", "you know the answer" and
    /// "I kind of like it" mean what they say.
    private static func hedge(_ tokens: [Token]) -> [Token]? {
        for h in tokens.indices {
            for phrase in hedges where h + phrase.count <= tokens.count {
                let span = h..<(h + phrase.count)
                guard tokens[span].map(\.norm) == phrase,
                      !tokens[span.dropLast()].contains(where: { $0.trailingPunctuation != nil }),
                      !tokens[span.dropFirst()].contains(where: { $0.leading.contains("\n") }) else { continue }
                let last = tokens[span.upperBound - 1].trailingPunctuation
                let hasNext = span.upperBound < tokens.count
                let afterComma = h > 0 && tokens[h - 1].trailingPunctuation == ","

                // "Basically, we need" -> "We need"
                if isSentenceStart(tokens, h), last == ",", hasNext {
                    return delete(tokens, span)
                }
                // "It was, you know, kind of weird" -> "It was kind of weird"
                if afterComma, last == ",", hasNext {
                    var edited = tokens
                    edited[h - 1].word.removeLast()
                    return delete(edited, span)
                }
                // "That's the plan, I guess." -> "That's the plan."
                if afterComma, trailingHedges.contains(phrase), let last, ".!?".contains(last) {
                    var edited = tokens
                    edited[h - 1].word.removeLast()
                    edited[h - 1].word.append(last)
                    return delete(edited, span)
                }
            }
        }
        return nil
    }

    // MARK: - Kinds

    private enum Kind { case day, month, number, name, other }

    private static let days: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "today", "tomorrow", "tonight", "yesterday"
    ]
    private static let months: Set<String> = [
        "january", "february", "march", "april", "may", "june", "july", "august",
        "september", "october", "november", "december"
    ]
    private static let numberWords: Set<String> = [
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "fifteen", "twenty", "thirty", "forty", "fifty", "hundred",
        "thousand", "noon", "midnight"
    ]

    private static func kind(of tokens: [Token], at index: Int) -> Kind {
        let token = tokens[index]
        let norm = token.norm
        let capitalised = token.word.first?.isUppercase == true
        if days.contains(norm) { return .day }
        // "may" and "march" are verbs far more often than months.
        if months.contains(norm), capitalised { return .month }
        if numberWords.contains(norm) || isNumeral(norm) { return .number }
        // A capital at a sentence start is grammar, not a name.
        if capitalised, norm != "i", !norm.hasPrefix("i'"), !isSentenceStart(tokens, index) { return .name }
        return .other
    }

    /// "3", "3:30", "2pm", "$20", "50%".
    private static func isNumeral(_ word: String) -> Bool {
        var body = Substring(word)
        if body.hasPrefix("$") { body = body.dropFirst() }
        for suffix in ["am", "pm", "%", "st", "nd", "rd", "th"] where body.hasSuffix(suffix) { body = body.dropLast(suffix.count) }
        return !body.isEmpty && body.first!.isNumber && body.allSatisfy { $0.isNumber || $0 == ":" || $0 == "." || $0 == "," }
    }

    // MARK: - Tokens

    /// Removes `range`, keeping the whitespace that stood in front of it so
    /// spacing and line breaks around the cut are exactly what they were. When
    /// the cut started a sentence with a capital, the word that now starts it
    /// takes the capital.
    private static func delete(_ tokens: [Token], _ range: Range<Int>) -> [Token] {
        var result = Array(tokens[..<range.lowerBound])
        guard range.upperBound < tokens.count else { return result }
        var next = tokens[range.upperBound]
        next.leading = tokens[range.lowerBound].leading
        if isSentenceStart(tokens, range.lowerBound), tokens[range.lowerBound].word.first?.isUppercase == true {
            next.word = next.word.prefix(1).uppercased() + next.word.dropFirst()
        }
        result.append(next)
        result.append(contentsOf: tokens[(range.upperBound + 1)...])
        return result
    }

    private static func isSentenceStart(_ tokens: [Token], _ index: Int) -> Bool {
        index == 0 || tokens[index - 1].endsSentence || tokens[index].leading.contains("\n")
    }

    /// The first token of the sentence that `index` is in.
    private static func clauseStart(_ tokens: [Token], before index: Int) -> Int {
        var start = max(index, 0)
        while start > 0, !isSentenceStart(tokens, start) { start -= 1 }
        return start
    }

    private static let edgePunctuation = CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "'$%"))

    static func normalize(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: edgePunctuation)
    }

    /// Words, each carrying the whitespace in front of it, so the text can be
    /// reassembled character for character (as in StreamCommit and FieldSync).
    static func tokenize(_ text: String) -> [Token] {
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

    /// Whitespace after the last word, which no token carries.
    private static func trailingWhitespace(_ text: String) -> String {
        String(text.reversed().prefix(while: { $0.isWhitespace }).reversed())
    }
}
