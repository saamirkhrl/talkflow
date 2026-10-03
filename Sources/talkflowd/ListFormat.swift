import Foundation

/// Turns a dictated enumeration into a numbered list:
///
///     The three things I like about it are number one, it's free. Number two,
///     it's available anywhere. And number three, it's open source.
///
/// becomes
///
///     The three things I like about it are:
///     1. It's free.
///     2. It's available anywhere.
///     3. It's open source.
///
/// Pure string transform, run once at release on the whole transcript (never
/// live: whether "number one" opens a list or is just a phrase - "talkflow is
/// number one" - cannot be known until the second item is spoken).
///
/// The spoken cue is a command, like "new paragraph", so it is consumed and
/// replaced by the marker. Nothing else is ever removed.
enum ListFormat {
    private static let numberWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5,
        "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10,
    ]

    /// "number two", "number 2", an ordinal followed by a comma ("second,"), or
    /// an ordinal plus "of all" ("third of all"). Bare ordinals demand the comma
    /// because "first" and "second" are ordinary words ("wait a second");
    /// "number N" and "N of all" are cues on their own - a lone "First of all,
    /// thanks" still stays prose, because a list needs a chain from 1. A leading "and"/"then"
    /// belongs to the cue ("and number three"). Trailing punctuation is eaten so
    /// the item doesn't start with a stray comma or period.
    private static let cuePattern = try! NSRegularExpression(
        pattern: "(?:\\b(?:and|then)\\s+)?\\b(?:number\\s+(one|two|three|four|five|six|seven|eight|nine|ten|\\d{1,2})\\b"
            + "|(first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth)(?:\\s+of\\s+all\\b|(?=\\s*,)))[,.:]?\\s*",
        options: [.caseInsensitive]
    )

    static func apply(to text: String) -> String {
        text.components(separatedBy: "\n\n").map(format(paragraph:)).joined(separator: "\n\n")
    }

    private static func format(paragraph: String) -> String {
        let ns = paragraph as NSString
        let cues = cuePattern.matches(in: paragraph, range: NSRange(location: 0, length: ns.length))
            .compactMap { match -> (range: NSRange, value: Int)? in
                let word = [1, 2].map { match.range(at: $0) }.first { $0.location != NSNotFound }
                guard let word, let value = value(of: ns.substring(with: word)) else { return nil }
                return (match.range, value)
            }

        // A list opens at 1 and climbs. Cues that don't continue it are prose.
        var chain: [(range: NSRange, value: Int)] = []
        for cue in cues {
            if chain.isEmpty { if cue.value == 1 { chain.append(cue) } }
            else if cue.value > chain[chain.count - 1].value { chain.append(cue) }
        }
        guard chain.count >= 2 else { return paragraph }

        var items: [String] = []
        for (index, cue) in chain.enumerated() {
            let start = cue.range.location + cue.range.length
            let end = index + 1 < chain.count ? chain[index + 1].range.location : ns.length
            var item = ns.substring(with: NSRange(location: start, length: end - start))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !item.isEmpty else { return paragraph } // cue with nothing after it
            item = item.prefix(1).uppercased() + item.dropFirst()
            items.append("\(cue.value). \(item)")
        }

        var intro = ns.substring(to: chain[0].range.location).trimmingCharacters(in: .whitespacesAndNewlines)
        if !intro.isEmpty {
            if intro.hasSuffix(",") || intro.hasSuffix(";") { intro.removeLast() }
            if let last = intro.last, !".!?:".contains(last) { intro += ":" }
            return intro + "\n" + items.joined(separator: "\n")
        }
        return items.joined(separator: "\n")
    }

    private static func value(of word: String) -> Int? {
        let lower = word.lowercased()
        return numberWords[lower] ?? Int(lower)
    }
}
