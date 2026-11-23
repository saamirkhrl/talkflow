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
/// Wider rules, each as narrow: one plain word swapped after "I mean" in a
/// closed class ("blue, I mean green"), a name the marker's full stop
/// capitalised ("Tell John. Wait, no. Mike."), a restart after "just"/"only" or
/// one that repeats the sentence's first word, a negated restart ("Delete it.
/// Wait, don't delete it, archive it." keeps the negation), the spoken commands
/// "actually, never mind" and "wait, start over" after a clause, and a clause
/// broken off after an article ("Can you make the, can you change the font
/// size?"). "delete that" and "undo that" are only detected (`hasMarker`), for
/// the model step; these rules never apply them.
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
            // typedRepair first: it also handles "scratch that" when only a
            // value changed, so "at 4 p.m., scratch that, 5 p.m." keeps the
            // words around the value. scratchThat drops the clause otherwise.
            guard let next = typedRepair(tokens) ?? scratchThat(tokens) ?? restart(tokens)
                ?? negatedRestart(tokens) ?? falseStart(tokens) ?? stutter(tokens) ?? hedge(tokens) else { break }
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

    /// Whether a correction marker, set off the way a correction is, still stands
    /// in `text`. After `apply`, true means the rules saw a marker and left it.
    static func hasMarker(in text: String) -> Bool {
        !markerIndices(in: text).isEmpty
    }

    /// Token indices (as in `tokenize`) where a correction marker or spoken
    /// command, set off the way a correction is, starts. Read-only: what
    /// `hasMarker` checks, with positions, for `CorrectionModel`'s guard.
    static func markerIndices(in text: String) -> [Int] {
        let tokens = tokenize(text)
        return tokens.indices.dropFirst().filter { !markers(at: $0, in: tokens).isEmpty || command(at: $0, in: tokens) != nil }
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
        /// "blue, I mean green", "the left, sorry, the right": may swap ONE ordinary
        /// word, under the narrow conditions of `plainSwapAllowed`.
        var plainAtClauseEnd: Bool = false
        /// Whether an ordinary word may be swapped for another after it. "I
        /// like both, I mean really both" shows why "I mean" may not.
        var trustsPlainWords: Bool { strong || words == ["or", "rather"] || words == ["correction"] }
        /// Firm enough for a restart that repeats only the sentence's first word.
        var firm: Bool { strong || (words.contains("no") && words.contains("actually")) }
        /// May be followed by a name that the sentence break capitalised: "Tell John. Wait, no. Mike."
        var allowsSentenceStartName: Bool { strong }
        /// A marker that takes something back ("actually", "wait", "no", "I mean"), as
        /// opposed to an apology ("sorry") or an exclamation ("oh no").
        var retracts: Bool {
            if words.contains("oh") && !words.contains("wait") { return false }
            return strong || words.contains("actually") || words.contains("wait") || words.contains("no")
                || words == ["i", "mean"] || words == ["i", "meant"] || words == ["or", "rather"] || words == ["correction"]
        }
    }

    /// Fixed phrases. Longest first, so "or rather" wins over "rather".
    private static let markers: [Marker] = [
        Marker(words: ["or", "rather"], strong: false, needsClauseEnd: false),
        Marker(words: ["make", "that"], strong: false, needsClauseEnd: false),
        Marker(words: ["i", "meant"], strong: false, needsClauseEnd: false, plainAtClauseEnd: true),
        Marker(words: ["i", "mean"], strong: false, needsClauseEnd: false, plainAtClauseEnd: true),
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
                      needsClauseEnd: !hasWait && !words.contains("no"),
                      plainAtClauseEnd: hasWait || !words.contains("oh"))
    }

    /// Words that may lead into "scratch that": "10 to 20, actually scratch
    /// that, 10 to 30".
    private static let retractLeads: Set<String> = runWords.union(["okay", "ok", "um", "uh", "hmm", "so", "well"])

    /// "scratch that" (or strike / ignore / disregard that), with any filler
    /// words in front of it, starting at `index`. Always a strong marker, but
    /// only when it is plainly a command: after a filler ("actually scratch
    /// that"), or set off by punctuation on both sides. "Please scratch that
    /// itch" is neither.
    private static func scratch(at index: Int, in tokens: [Token]) -> Marker? {
        var words: [String] = []
        var i = index
        while i < tokens.count, words.count < 3, retractLeads.contains(tokens[i].norm),
              i == index || !tokens[i].leading.contains("\n") {
            words.append(tokens[i].norm)
            i += 1
        }
        guard i + 1 < tokens.count, retractVerbs.contains(tokens[i].norm), tokens[i + 1].norm == "that",
              !tokens[i].leading.contains("\n") || i == index, !tokens[i + 1].leading.contains("\n") else { return nil }
        let setOff = !words.isEmpty
            || (index > 0 && tokens[index - 1].trailingPunctuation != nil && tokens[i + 1].trailingPunctuation != nil)
        guard setOff else { return nil }
        return Marker(words: words + [tokens[i].norm, "that"], strong: true, needsClauseEnd: false)
    }

    /// Markers starting at `index` that are set off the way a correction is.
    /// Returns (marker, index of the first token after it).
    private static func markers(at index: Int, in tokens: [Token]) -> [(Marker, Int)] {
        guard index > 0 else { return [] } // nothing before it to replace
        var found: [(Marker, Int)] = []
        for marker in markers + [run(at: index, in: tokens), scratch(at: index, in: tokens)].compactMap({ $0 }) {
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
                    // "not a short" negates the old phrase; it is no replacement.
                    guard tokens[after].norm != "not" else { continue }
                    let old = unitsBackward(from: m, in: tokens)
                    let new = unitsForward(from: after, in: tokens)
                    for n in 1...maxUnits where n <= old.count && n <= new.count {
                        let olds = Array(old.prefix(n).reversed())
                        var news = Array(new.prefix(n))
                        if n == 1, olds[0].kind == .name, news[0].kind == .other,
                           sentenceStartName(at: news[0].range.lowerBound, old: olds[0].range.lowerBound,
                                             marker: marker, lead: lead, tokens: tokens) {
                            news[0] = Unit(range: news[0].range, kind: .name, norm: news[0].norm)
                        }
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
            guard changedWords.count == 1, lead == 0,
                  tokens[old[old.count - 1].range.upperBound - 1].trailingPunctuation != nil else { return false }
            if !marker.trustsPlainWords {
                guard marker.plainAtClauseEnd,
                      plainSwapAllowed(old, new, changedAt: changedWords[0], marker: marker, tokens: tokens) else { return false }
            }
        }
        if marker.needsClauseEnd || changedName || !changedWords.isEmpty {
            let end = new[new.count - 1].range.upperBound
            guard end == tokens.count || tokens[end - 1].trailingPunctuation != nil else { return false }
        }
        return true
    }

    /// A swap of one ordinary word after a marker that also opens new thoughts.
    /// Deliberately narrow, since nothing here knows parts of speech:
    /// - the changed word is the LAST unit ("the left" -> "the right", never "was good" -> "really good");
    /// - one unit on each side only when both words are in one closed class
    ///   ("blue, I mean green", "left, I mean right"), so "go, I mean soon" stays;
    /// - two or three units only when every unit before the changed one is an
    ///   article, possessive or preposition said again ("a dropdown" -> "a toggle");
    /// - neither word is a filler or pronoun-like word ("Great job, I mean that.");
    /// - the old phrase is not negated ("not bad, I mean good").
    private static func plainSwapAllowed(_ old: [Unit], _ new: [Unit], changedAt index: Int, marker: Marker, tokens: [Token]) -> Bool {
        let n = old.count
        guard index == n - 1, n <= 3 else { return false }
        // "Did you read the book? Actually, the movie." must not become a statement: the old
        // phrase ends in a comma, or in the same mark the replacement ends in.
        let oldEnd = tokens[old[n - 1].range.upperBound - 1].trailingPunctuation
        let newEnd = tokens[new[n - 1].range.upperBound - 1].trailingPunctuation
        guard oldEnd == "," || oldEnd == newEnd else { return false }
        let o = old[index].norm, r = new[index].norm
        guard !plainSwapStop.contains(o), !plainSwapStop.contains(r) else { return false }
        // "sorry" alone is just as often an apology ("Thanks for the gift. Sorry, the delay."):
        // after it, only a swap inside one closed class counts ("the left, sorry, the right").
        if !marker.retracts {
            guard plainClasses.contains(where: { $0.contains(o) && $0.contains(r) }) else { return false }
        }
        if n == 1 {
            guard plainClasses.contains(where: { $0.contains(o) && $0.contains(r) }) else { return false }
        } else {
            guard old[..<index].allSatisfy({ $0.kind == .other && anchorWords.contains($0.norm) }) else { return false }
        }
        let before = old[0].range.lowerBound - 1
        if before >= 0, isNegation(tokens[before].norm) { return false }
        return true
    }

    private static func isNegation(_ word: String) -> Bool {
        word == "not" || word == "never" || word == "no" || word.hasSuffix("n't") || word.hasSuffix("n\u{2019}t")
    }

    private static let plainClasses: [Set<String>] = [
        ["red", "orange", "yellow", "green", "blue", "purple", "pink", "black", "white", "gray", "grey", "brown", "gold", "silver"],
        ["left", "right", "top", "bottom", "up", "down", "front", "back", "above", "below", "inside", "outside",
         "north", "south", "east", "west"],
        ["big", "bigger", "small", "smaller", "large", "larger", "tiny", "huge", "short", "shorter", "long", "longer",
         "wide", "wider", "narrow", "narrower", "tall", "taller", "high", "higher", "low", "lower"],
        ["first", "second", "third", "last", "next", "previous"],
        ["more", "less", "fewer"]
    ]
    private static let anchorWords: Set<String> = [
        "a", "an", "the", "my", "our", "your", "their", "his", "its", "this", "these", "those",
        "on", "in", "at", "to", "for", "with", "from", "into", "onto"
    ]
    private static let plainSwapStop: Set<String> = [
        "that", "this", "it", "so", "too", "yes", "yeah", "no", "okay", "ok", "sure", "well", "really", "very",
        "just", "again", "though", "anyway", "either", "now", "then", "here", "there", "please", "thanks",
        "same", "other", "one", "ones", "rest", "thing", "things", "stuff", "whole", "lot"
    ]

    /// "Tell John. Wait, no. Mike.": the marker ended a sentence, so the name
    /// after it starts one and its capital looks like grammar. Only a given name
    /// from a closed list replaces another, only after a marker that is plainly
    /// a retraction, never after a greeting, thanks or sign-off.
    private static func sentenceStartName(at index: Int, old: Int, marker: Marker, lead: Int, tokens: [Token]) -> Bool {
        let token = tokens[index]
        // Positive evidence, not a stop list: both are given names from one closed list
        // ("Tell John. Wait, no. Mike."). "Phew", "Lunch" or "Congrats" never are.
        guard givenNames.contains(token.norm), givenNames.contains(tokens[old].norm) else { return false }
        // The old name is one capitalised word, not the end of a longer one ("Main Street").
        if old > 0, !isSentenceStart(tokens, old - 1), tokens[old - 1].word.first?.isUppercase == true { return false }
        // Not a greeting, thanks or sign-off: "Hi Tom.", "Thanks, Kevin.", "Love you, Mom."
        if socialOpeners.contains(tokens[clauseStart(tokens, before: old)].norm) { return false }
        // Both end their sentence with a full stop, or the new one ends the text.
        guard tokens[old].trailingPunctuation == ".",
              token.trailingPunctuation == "." || (token.trailingPunctuation == nil && index == tokens.count - 1) else { return false }
        guard lead == 0, marker.allowsSentenceStartName, isSentenceStart(tokens, index),
              !token.leading.contains("\n"), token.word.first?.isUppercase == true else { return false }
        return true
    }

    private static let socialOpeners: Set<String> = [
        "hi", "hey", "hello", "dear", "thanks", "thank", "bye", "goodbye", "love", "good", "cheers",
        "congrats", "congratulations", "welcome", "sorry", "morning", "night", "yo"
    ]

    /// Unambiguous given names: none is also an everyday word (no Will, Mark, Rose, Grace,
    /// May, Hope, Jack, Frank, Bill, Ray, Joy, June, April, Ivy, Holly, Penny, Dawn, Chase).
    /// One list for Mac and Windows; keep them identical.
    private static let givenNames: Set<String> = [
        "aaron", "abigail", "adam", "ahmed", "aiden", "aisha", "alan", "albert", "alex", "alexander", "ali",
        "alice", "amanda", "amelia", "amit", "amy", "ana", "ananya", "andrea", "andrew", "andy", "angela",
        "anna", "anne", "anthony", "arjun", "ashley", "ava", "barbara", "beth", "ben", "benjamin", "betty",
        "bob", "brad", "brandon", "brenda", "brian", "bruce", "bryan", "caleb", "carlos", "carmen", "carol",
        "carolyn", "catherine", "charles", "charlotte", "chen", "cheryl", "chloe", "chris", "christina",
        "christine", "claire", "cynthia", "dan", "daniel", "dave", "david", "deborah", "dennis", "derek",
        "diana", "diane", "diego", "donna", "doris", "dylan", "edward", "elena", "elijah", "elizabeth",
        "ella", "ellie", "emily", "emma", "eric", "erica", "erin", "ethan", "eva", "evelyn", "ezra",
        "fatima", "gabriel", "gary", "george", "gloria", "greg", "gregory", "hannah", "harold", "heather",
        "helen", "henry", "hiroshi", "ian", "isaac", "isabella", "jacob", "jake", "james", "jane", "janet",
        "janice", "jason", "jeff", "jeffrey", "jennifer", "jenny", "jeremy", "jerry", "jessica", "jill",
        "jim", "joan", "joe", "john", "jonathan", "jordan", "jose", "joseph", "josh", "joshua", "joyce",
        "juan", "judith", "julia", "julian", "julie", "justin", "karen", "kate", "katherine", "kathleen",
        "katie", "keith", "kelly", "kenji", "kevin", "kim", "kimberly", "kyle", "larry", "laura", "lauren",
        "lawrence", "leah", "leo", "liam", "linda", "lisa", "logan", "lucas", "lucia", "lucy", "luis",
        "madison", "marcus", "margaret", "maria", "marie", "martha", "mary", "mateo", "matt", "matthew",
        "maya", "megan", "mei", "melissa", "mia", "michael", "michelle", "miguel", "mike", "mohammed",
        "monica", "muhammad", "nancy", "natalie", "nathan", "neil", "nicholas", "nick", "nicole", "nina",
        "noah", "nora", "oliver", "olivia", "omar", "owen", "pamela", "patricia", "patrick", "paul",
        "paula", "peter", "priya", "priyanka", "rachel", "rahul", "raj", "ravi", "raymond", "rebecca",
        "richard", "robert", "roger", "ronald", "ruth", "ryan", "samantha", "samuel", "sam", "sandra",
        "sanjay", "sara", "sarah", "scott", "sean", "sebastian", "sharon", "shirley", "sofia", "sophia",
        "sophie", "stephanie", "stephen", "steve", "steven", "susan", "tara", "teresa", "thomas", "tim",
        "timothy", "tina", "todd", "tom", "tony", "trevor", "tyler", "vanessa", "victoria", "vikram",
        "vincent", "walter", "wei", "wendy", "william", "yuki", "zachary", "zoe"
    ]

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

    private static let restartSkips: Set<String> = ["just", "only"]

    /// Words after which a verb is an instruction: "I want you to refactor", "please send", "let's ship".
    private static let instructionSlots: Set<String> = ["to", "please", "let's", "lets", "i'll", "we'll", "should", "must"]

    /// "I went home, I mean I went to the office": the words after the marker
    /// restart the clause, repeating at least two of its words from where they
    /// first appeared. Everything from that point through the marker goes.
    private static func restart(_ tokens: [Token]) -> [Token]? {
        for m in tokens.indices {
            for (marker, markerEnd) in markers(at: m, in: tokens) {
                let after = skipNegation(at: markerEnd, before: m, in: tokens)
                let start = max(clauseStart(tokens, before: m - 1), m - 12)
                // 1. Unchanged: the first two words after the marker were said earlier in the sentence.
                if let p = repeated(at: after, from: start, before: m, in: tokens) {
                    return delete(tokens, p..<after)
                }
                // 2. "the whole file. Actually, just refactor the render function": the
                //    restart is one "just"/"only" in; that word is kept.
                if marker.retracts, after + 1 < tokens.count, restartSkips.contains(tokens[after].norm),
                   tokens[m - 1].trailingPunctuation != "?",
                   !anchorWords.contains(tokens[after + 1].norm), !stutterWords.contains(tokens[after + 1].norm),
                   let p = repeated(at: after + 1, from: start, before: m, in: tokens),
                   tokens[p + 1].trailingPunctuation == nil, p + 2 < m,
                   isSentenceStart(tokens, p) || instructionSlots.contains(tokens[p - 1].norm) {
                    return delete(tokens, p..<after)
                }
                // 3. "First fix the tests. Wait, no, first pull the latest changes": after
                //    a firm marker, the new clause opens with the old sentence's first word.
                let s = clauseStart(tokens, before: m - 1)
                if marker.firm, after + 1 < tokens.count, !tokens[after + 1].leading.contains("\n"),
                   m - s >= 2, m - s <= 12, tokens[m - 1].trailingPunctuation != nil,
                   tokens[after].norm == tokens[s].norm, !runWords.contains(tokens[s].norm) {
                    return delete(tokens, s..<after)
                }
            }
        }
        return nil
    }

    /// Where the two words at `index` were first said: between `start` and the
    /// marker at `m`, not across punctuation after the first of them.
    private static func repeated(at index: Int, from start: Int, before m: Int, in tokens: [Token]) -> Int? {
        guard index + 1 < tokens.count, !tokens[index + 1].leading.contains("\n") else { return nil }
        var p = m - 2
        while p >= start {
            if tokens[p].norm == tokens[index].norm, tokens[p + 1].norm == tokens[index + 1].norm,
               tokens[p].trailingPunctuation == nil {
                return p
            }
            p -= 1
        }
        return nil
    }

    /// "Delete the old migration. Wait, don't delete it, just rename it.": the user
    /// negates the verb that opened the sentence before the marker, then says what
    /// to do instead. Only the old sentence and the marker go: the negation is the
    /// instruction and stays ("Don't delete it, just rename it.").
    private static func negatedRestart(_ tokens: [Token]) -> [Token]? {
        for m in tokens.indices {
            for (_, markerEnd) in markers(at: m, in: tokens) {
                guard tokens[m - 1].trailingPunctuation != nil else { continue }
                let s = clauseStart(tokens, before: m - 1)
                guard m - s >= 2, m - s <= 12 else { continue }
                let verb = ["let's", "lets", "please"].contains(tokens[s].norm) ? s + 1 : s
                guard verb < m else { continue }
                var v = markerEnd
                if v < tokens.count, ["don't", "dont", "don\u{2019}t"].contains(tokens[v].norm) {
                    v += 1
                } else if v + 1 < tokens.count, tokens[v].norm == "do", tokens[v + 1].norm == "not" {
                    v += 2
                } else { continue }
                guard v < tokens.count, tokens[v].norm == tokens[verb].norm else { continue }
                // Positive evidence that the old instruction itself is negated: the same object again,
                // as a pronoun ("don't delete it") or the same two words ("don't bring the charger").
                // "Go ahead and explore. Actually, don't go too far" only qualifies it.
                var o = v + 1
                if o < tokens.count, objectPronouns.contains(tokens[o].norm) {
                    o += 1
                } else if o + 1 < tokens.count, verb + 2 < m,
                          tokens[o].norm == tokens[verb + 1].norm, tokens[o + 1].norm == tokens[verb + 2].norm,
                          tokens[o].trailingPunctuation == nil {
                    o += 2
                } else { continue }
                // At most one more word ("yet"), then the clause ends: "don't have it too strong" qualifies.
                var k = o - 1
                if tokens[k].trailingPunctuation == nil, o < tokens.count, negationTails.contains(tokens[o].norm) { k = o }
                guard let p = tokens[k].trailingPunctuation, ",;.!".contains(p),
                      !tokens[(markerEnd + 1)...k].contains(where: { $0.leading.contains("\n") }) else { continue }
                // Only the old sentence and the marker go; "Don't delete it, just rename it." stays.
                return delete(tokens, s..<markerEnd)
            }
        }
        return nil
    }

    private static let objectPronouns: Set<String> = ["it", "that", "this", "them", "these", "those", "him", "her", "us", "me"]
    private static let negationTails: Set<String> = ["yet", "now", "anymore", "again", "today"]

    /// "a short, actually no not a short, we'll add a long one": after the
    /// marker, "not" plus the very words just before it (ending in
    /// punctuation) only negates them, so the restart begins after it.
    private static func skipNegation(at index: Int, before m: Int, in tokens: [Token]) -> Int {
        guard index < tokens.count, tokens[index].norm == "not" else { return index }
        for k in 1...4 where index + k < tokens.count && m - k >= 0 {
            let phrase = tokens[(index + 1)...(index + k)]
            guard tokens[index + k].trailingPunctuation != nil,
                  !phrase.dropLast().contains(where: { $0.trailingPunctuation != nil }),
                  phrase.map(\.norm) == tokens[(m - k)..<m].map(\.norm) else { continue }
            return index + k + 1
        }
        return index
    }

    private static let retractVerbs: Set<String> = ["scratch", "strike", "ignore", "disregard"]

    /// Newer retract commands. Unlike scratch that they are everyday instructions
    /// ("look at the last commit, undo that, and rerun the tests"), so only "never
    /// mind" and "start over" ever drop a clause, they never act as markers for
    /// the other rules, and they need more than punctuation: see `scratchThat`.
    private static let commandRetracts: [[String]] = [
        ["never", "mind"], ["nevermind"], ["start", "over"], ["delete", "that"], ["undo", "that"]
    ]

    /// "actually" and "wait" mark a retraction; "oh", "so", "okay" do not ("Oh, never mind, it's fine").
    private static let retractSignals: Set<String> = ["actually", "wait"]

    /// A command at `index`, with optional filler leads, set off the way `scratch`
    /// requires and followed by punctuation ("never mind the dog" is not one).
    /// Returns the number of tokens it spans, the phrase, and whether a lead was
    /// "actually" or "wait".
    private static func command(at index: Int, in tokens: [Token]) -> (count: Int, phrase: [String], retractLead: Bool)? {
        guard index > 0 else { return nil }
        var leadWords: [String] = []
        var i = index
        while i < tokens.count, leadWords.count < 3, retractLeads.contains(tokens[i].norm),
              i == index || !tokens[i].leading.contains("\n") {
            leadWords.append(tokens[i].norm)
            i += 1
        }
        for phrase in commandRetracts where i + phrase.count <= tokens.count {
            let span = tokens[i..<(i + phrase.count)]
            guard span.map(\.norm) == phrase,
                  i == index || !tokens[i].leading.contains("\n"),
                  !span.dropFirst().contains(where: { $0.leading.contains("\n") }),
                  tokens[i + phrase.count - 1].trailingPunctuation != nil else { continue }
            let setOff = !leadWords.isEmpty || tokens[index - 1].trailingPunctuation != nil
            guard setOff else { return nil }
            return (leadWords.count + phrase.count, phrase, leadWords.contains { retractSignals.contains($0) })
        }
        return nil
    }

    private static let requestOpeners: Set<String> = ["please", "let's", "lets", "i'll", "we'll", "i'd", "we'd"]

    /// Words that open a subordinate clause: "If it fails, start over" is an instruction.
    private static let subordinators: Set<String> = [
        "if", "when", "whenever", "once", "unless", "until", "till", "while", "after", "before", "because",
        "since", "as", "though", "although", "where", "wherever", "whether"
    ]

    /// Whether `range` holds a word that is not just a filler lead ("Oh, never mind").
    private static func hasContent(_ tokens: [Token], _ range: Range<Int>) -> Bool {
        tokens[range].contains { !retractLeads.contains($0.norm) }
    }

    /// "let's do it tomorrow, scratch that (or strike / ignore / disregard that),
    /// let's do it Monday": drops the
    /// clause before the marker. "scratch that" must be set off by punctuation
    /// on both sides - "scratch that itch" is not a command - and something must
    /// follow it to be what was meant instead.
    private static func scratchThat(_ tokens: [Token]) -> [Token]? {
        for m in tokens.indices.dropFirst() {
            if let marker = scratch(at: m, in: tokens) {
                var end = m + marker.words.count
                // "scratch that, scratch that" is one command said twice.
                while end + 2 < tokens.count, retractVerbs.contains(tokens[end].norm), tokens[end + 1].norm == "that",
                      !tokens[end].leading.contains("\n") { end += 2 }
                guard end < tokens.count, !tokens[end].leading.contains("\n") else { continue }
                let start = retractStart(tokens, before: m)
                guard hasContent(tokens, start..<m) else { continue }
                return delete(tokens, start..<end)
            }
            if let cmd = command(at: m, in: tokens) {
                let end = m + cmd.count
                guard end < tokens.count, !tokens[end].leading.contains("\n") else { continue }
                let start = retractStart(tokens, before: m)
                guard cmd.retractLead, hasContent(tokens, start..<m), !subordinators.contains(tokens[start].norm) else { continue }
                switch cmd.phrase {
                case ["never", "mind"], ["nevermind"]:
                    // Only a question or a request is taken back ("Rust? Actually, never mind, keep it
                    // in Swift."); a greeting or thanks is not ("Hi team. Actually, never mind, ...").
                    guard tokens[m - 1].trailingPunctuation == "?" || requestOpeners.contains(tokens[start].norm) else { continue }
                    return delete(tokens, start..<end)
                case ["start", "over"]:
                    // "Let's ship today, wait, start over, let's ship tomorrow": the clause is said
                    // again, opening with the same two words but not repeated word for word.
                    let length = m - start
                    guard length >= 2, end + 1 < tokens.count, !tokens[end + 1].leading.contains("\n"),
                          tokens[end].norm == tokens[start].norm, tokens[end + 1].norm == tokens[start + 1].norm else { continue }
                    let repeatsAll = end + length <= tokens.count
                        && tokens[end..<(end + length)].map(\.norm) == tokens[start..<m].map(\.norm)
                    guard !repeatsAll else { continue }
                    return delete(tokens, start..<end)
                default:
                    // "delete that", "undo that": everyday editor instructions ("Select the first row,
                    // delete that, select the next row"). Detected for the model step, never applied here.
                    continue
                }
            }
        }
        return nil
    }

    /// The first token of the clause that ends right before `m` (today's walk-back loop, extracted).
    private static func retractStart(_ tokens: [Token], before m: Int) -> Int {
        var start = m - 1
        while start > 0, tokens[start - 1].trailingPunctuation == nil, !tokens[start].leading.contains("\n") {
            start -= 1
        }
        return start
    }

    /// Articles and possessives never end a phrase, so a comma right after one is
    /// a broken-off clause. Bare "a" is left out: "plan A, plan B" is a label.
    private static let danglers: Set<String> = ["an", "the", "my", "our", "your", "their", "its"]

    /// "Can you make the, can you change the font size?": a clause broken off after
    /// an article or possessive, then begun again with its first two words.
    private static func falseStart(_ tokens: [Token]) -> [Token]? {
        for d in tokens.indices where tokens[d].trailingPunctuation == "," && danglers.contains(tokens[d].norm)
            && tokens[d].word.first?.isLowercase == true {
            var f = d
            while f > 0, tokens[f - 1].trailingPunctuation == nil, !tokens[f].leading.contains("\n") { f -= 1 }
            guard d - f >= 2, d - f <= 7, d + 2 < tokens.count,
                  !tokens[d + 1].leading.contains("\n"), !tokens[d + 2].leading.contains("\n"),
                  tokens[d + 1].norm == tokens[f].norm, tokens[d + 2].norm == tokens[f + 1].norm,
                  // "Search for the, search for an": the same words again with another article is a
                  // list of words, not a restart. A real restart changes something before the slot
                  // ("Can you make the, can you change ...").
                  (d + 1 + (d - f) > tokens.count
                      || tokens[(d + 1)..<(d + 1 + (d - f))].map(\.norm) != tokens[f..<d].map(\.norm)) else { continue }
            return delete(tokens, f..<(d + 1))
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
