import Foundation
import NaturalLanguage

/// Inserts blank lines between an email's greeting, body and sign-off. A pure
/// transform on a string - it never edits anything on screen and never removes
/// content.
///
/// Two earlier versions are gone. The first asked a model to echo the whole text
/// back with blank lines added; it corrupted the words every single time it ran
/// (dropped a comma, changed a name, replaced a section with "---", once replied
/// with the literal words "(blank line)"). The second asked a model only to pick
/// clause NUMBERS, which could not corrupt anything by construction, but cost
/// ~1.4s and answered "[2]" almost regardless of the text.
///
/// What remains is the part that measurably worked: greeting and sign-off
/// matched by rule. Deterministic, instant, and it covers the case that actually
/// matters when dictating an email.
enum StructurePolish {
    /// An email opener: "Dear Mr. Clark,", "Hi Sarah,", "Good morning,". Hi, Hey
    /// and Hello need a name after them - a bare "Hey, what's up" is chat, not an
    /// email, and must not be split in two. Deliberately allows "." inside (for
    /// "Mr.") and stops at the first comma.
    private static let greetingPattern = try! NSRegularExpression(
        pattern: "^(?:(?:Hi|Hey|Hello)\\s+[^,]{1,40}|Dear\\b[^,]{0,40}|Good (?:morning|afternoon|evening)\\b[^,]{0,40}),"
    )

    /// A sign-off plus a name at the very end: "Best, Samir", "Thanks Sarah",
    /// "Thank you, Sincerely, Samir". Whisper routinely drops the comma, so it is
    /// optional, and one lowercase adverb may sit between closer and name.
    ///
    /// Closers repeat, because people stack them: "Thank you, Sincerely, Samir".
    /// Matching only the last one left "Thank you," stranded on the end of the
    /// body paragraph, which is exactly how it looked on screen.
    ///
    /// Group 1 is the sign-off itself; what precedes it only anchors the match.
    /// The closer words are matched case-insensitively via an inline `(?i:)` -
    /// whisper writes "best Samir" as often as "Best Samir" - but the name after
    /// them must still be capitalised, and the closer must follow a comma or a
    /// sentence end. Together that admits "..., best Samir." while still refusing
    /// "...is the best option we have right now."
    private static let signOffPattern = try! NSRegularExpression(
        pattern: "(?:^|,\\s*|[.!?]\\s+)"
            + "((?:(?i:best regards|best wishes|best|thanks again|thanks|thank you|regards|sincerely|cheers|talk soon)(?:\\s*,)?\\s*){1,3}"
            + "(?:[a-z]+(?:\\s*,)?\\s*)?[A-Z][A-Za-z]*\\.?)\\s*$"
    )

    /// A sign-off whisper ran straight into the last sentence: "...for using
    /// talkflow best Samira", no comma, no period. The last two words, a closer
    /// then a capitalised name, after a lowercase word or digit (anything
    /// punctuated is the pattern above's job).
    ///
    /// Only tried when the same text opened with an email greeting. Without
    /// that, "...today please thanks Sam" is a chat message and "...who did the
    /// launch video best Sam" is a sentence, and neither is split.
    private static let bareSignOffPattern = try! NSRegularExpression(
        pattern: "(?<=[\\p{Ll}\\d])\\s+((?i:best regards|best wishes|best|regards|sincerely|cheers|thanks)\\s+[A-Z][A-Za-z'-]*\\.?)\\s*$"
    )

    /// A comma-less greeting that is a whole sentence on its own: "Good morning
    /// Emily." Whisper often drops the comma, and without it the pattern above
    /// never matched, so the break was skipped. Requires a capitalised name (an
    /// optional title plus one or two words) and the sentence end, so "Good
    /// morning everyone I hope" is not touched.
    private static let bareGreetingPattern = try! NSRegularExpression(
        pattern: "^(?:Good (?:morning|afternoon|evening)|Dear|Hi|Hey|Hello)\\s+(?:(?:Mr|Mrs|Ms|Dr|Prof)\\.?\\s+)?[A-Z][A-Za-z'-]*(?:\\s+[A-Z][A-Za-z'-]*)?[.!]$"
    )

    /// A name or title left over after the greeting's comma: "Mr. Joseph",
    /// "Sarah". Kept with the greeting rather than pushed into the body.
    private static let greetingNamePattern = try! NSRegularExpression(
        pattern: "^(?:Mr|Mrs|Ms|Dr|Prof)\\.?\\s+[A-Z][A-Za-z]*\\.?$|^[A-Z][A-Za-z]*\\.?$"
    )

    /// A sign-off paragraph whisper wrote without its comma: "Best Samir." /
    /// "Thanks Sarah". Group 1 is the closer, group 2 the name.
    private static let commaLessSignOff = try! NSRegularExpression(
        pattern: "^((?i:best regards|best wishes|best|thanks again|thanks|thank you|regards|sincerely|cheers|talk soon))\\s+([A-Z][A-Za-z'-]*\\.?)$"
    )

    /// "Best Samir." -> "Best, Samir." Only on a final paragraph that `apply`
    /// already split off as a sign-off, so a sentence ending "...thanks Sam"
    /// is never touched. Adds one comma; no word changes. Pure, for
    /// `--streamtest`.
    static func punctuateSignOff(_ text: String) -> String {
        guard let breakRange = text.range(of: "\n\n", options: .backwards) else { return text }
        let last = String(text[breakRange.upperBound...])
        let ns = last as NSString
        guard let match = commaLessSignOff.firstMatch(in: last, range: NSRange(location: 0, length: ns.length)) else { return text }
        let closer = ns.substring(with: match.range(at: 1)), name = ns.substring(with: match.range(at: 2))
        return String(text[..<breakRange.upperBound]) + closer + ", " + name
    }

    /// Returns the text with blank lines inserted between sections.
    ///
    /// `signOff: false` is the live-typing mode: only the greeting break is
    /// decided. A greeting is final the moment the sentence after it begins, so
    /// the break can be appended mid-hold; a sign-off match flickers while words
    /// are still arriving. Deciding the greeting early is what keeps the release
    /// rewrite short - it only ever has to touch the tail, which is the difference
    /// between a rewrite that fits the keystroke budget and one that is refused
    /// (the flat, unformatted email in Gmail).
    static func apply(to text: String, signOff: Bool = true) -> String {
        // Text that already has line breaks (a spoken "new paragraph") must keep
        // them: the clause pass below re-joins with spaces and would flatten
        // them. Treat only its first and last line as candidates.
        if text.contains("\n") { return applyAroundBreaks(text, signOff: signOff) }
        return applySingleLine(text, greeting: true, signOff: signOff)
    }

    private static func applyAroundBreaks(_ text: String, signOff: Bool) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let firstIndex = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              let lastIndex = lines.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        else { return text }
        let firstLine = lines[firstIndex]
        lines[firstIndex] = applySingleLine(firstLine, greeting: true, signOff: false)
        if signOff {
            lines[lastIndex] = applySingleLine(lines[lastIndex], greeting: firstIndex == lastIndex, signOff: true,
                                               afterGreeting: lines[firstIndex] != firstLine)
        }
        return lines.joined(separator: "\n")
    }

    private static func applySingleLine(_ text: String, greeting: Bool, signOff: Bool, afterGreeting: Bool = false) -> String {
        // The greeting has no length guard on purpose: the live path decides it
        // as words arrive, and a threshold would make the break appear late, in
        // the middle of text already typed - an edit the live path refuses. A
        // sign-off is only ever decided at release, so it keeps the guard.
        let (clauses, forced) = split(text, greeting: greeting, signOff: signOff && text.count > 40, afterGreeting: afterGreeting)
        guard clauses.count >= 2, !forced.isEmpty else { return text }

        // Reassembling has to reproduce the original exactly, or the clause
        // boundaries don't line up with the real text.
        guard isWhitespaceOnlyDiff(original: text, restructured: clauses.joined(separator: " ")) else {
            return text
        }
        return assemble(text: text, clauses: clauses, breaks: forced)
    }

    /// Breaks the text into clauses and reports which of them must start their
    /// own paragraph. Sentence boundaries come from NLTokenizer so that "Dear Mr.
    /// Clark" isn't cut after the abbreviation; the greeting and sign-off are
    /// then peeled off the first and last sentence.
    static func split(_ text: String, greeting: Bool = true, signOff: Bool = true, afterGreeting: Bool = false) -> (clauses: [String], forcedBreaks: Set<Int>) {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var clauses = tokenizer.tokens(for: text.startIndex..<text.endIndex)
            .map { String(text[$0]).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !clauses.isEmpty else { return ([], []) }

        var forced = Set<Int>()

        if greeting, clauses.count > 1, let first = clauses.first,
           bareGreetingPattern.firstMatch(in: first, range: NSRange(location: 0, length: (first as NSString).length)) != nil {
            forced.insert(1)
        } else if greeting, let first = clauses.first,
           let match = firstMatch(greetingPattern, in: first),
           match.upperBound < first.endIndex {
            let greeting = String(first[..<match.upperBound])
            let rest = String(first[match.upperBound...]).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty || isGreetingName(rest) {
                // "Good afternoon, Mr. Joseph." is all greeting - don't strand the
                // name at the start of the body. The break goes after the whole
                // first sentence instead.
                if clauses.count > 1 { forced.insert(1) }
            } else {
                clauses.replaceSubrange(0...0, with: [greeting, rest])
                forced.insert(1) // index of the clause after the greeting
            }
        }

        // The bare form needs an email around it: a greeting here, or on the
        // first line when spoken paragraph breaks split the text.
        let isEmail = afterGreeting || forced.contains(1)
        if signOff, clauses.count > 1, let last = clauses.last,
           let match = firstMatch(signOffPattern, in: last) ?? (isEmail ? firstMatch(bareSignOffPattern, in: last) : nil) {
            if match.lowerBound == last.startIndex {
                // Whisper already ended a sentence before the closer, so the
                // sign-off is a clause of its own and just needs its own break.
                forced.insert(clauses.count - 1)
            } else {
                let head = String(last[..<match.lowerBound]).trimmingCharacters(in: .whitespaces)
                let signOff = String(last[match.lowerBound...]).trimmingCharacters(in: .whitespaces)
                if !head.isEmpty, !signOff.isEmpty {
                    clauses.replaceSubrange((clauses.count - 1)...(clauses.count - 1), with: [head, signOff])
                    forced.insert(clauses.count - 1)
                }
            }
        }

        return (clauses, forced)
    }

    /// Returns the range of capture group 1 when the pattern defines one, so a
    /// pattern can anchor on text it does not want to consume.
    private static func firstMatch(_ regex: NSRegularExpression, in string: String) -> Range<String.Index>? {
        let ns = string as NSString
        guard let match = regex.firstMatch(in: string, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let range = match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound
            ? match.range(at: 1)
            : match.range
        return Range(range, in: string)
    }

    private static func isGreetingName(_ text: String) -> Bool {
        let ns = text as NSString
        return greetingNamePattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil
    }

    private static func assemble(text: String, clauses: [String], breaks: Set<Int>) -> String {
        // Clauses come back trimmed, but the caller may have handed us text that
        // opens or closes with whitespace it cares about; put it back.
        let leading = String(text.prefix(while: { $0.isWhitespace }))
        let trailing = String(text.reversed().prefix(while: { $0.isWhitespace }).reversed())

        var restructured = leading
        for (index, clause) in clauses.enumerated() {
            if index > 0 { restructured += breaks.contains(index) ? "\n\n" : " " }
            restructured += clause
        }
        return restructured + trailing
    }

    /// The two texts must be identical once ALL whitespace is stripped - this
    /// pass is only ever allowed to add blank lines.
    private static func isWhitespaceOnlyDiff(original: String, restructured: String) -> Bool {
        func strip(_ s: String) -> String {
            String(s.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
        }
        return strip(original) == strip(restructured)
    }
}
