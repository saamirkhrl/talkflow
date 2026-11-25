import Foundation

/// Drops what whisper makes up on silence and noise: bracketed sound labels, music notes, low-confidence
/// segments, repetition loops. Pure logic, no I/O. Thresholds follow whisper's own rules and the transcription
/// spike (RESULTS.md 3).
enum HallucinationGuard {
    /// whisper's own skip rule: no_speech_thold 0.6 together with logprob_thold -1.0 (server.cpp defaults).
    static let noSpeechProb = 0.6
    static let lowLogprob = -1.0
    /// Stricter for replies decoded at temperature 0.4: a retry must be confident.
    static let retryLogprob = -1.0
    /// whisper's compression_ratio_threshold: repetition loops.
    static let maxCompression = 2.4
    /// Normal speech runs 2.2-3.7 words per second, the failures 0.11-0.82 (spike RESULTS.md 3).
    static let minRetrySpeech = 5.0
    static let minWordsPerSecond = 1.0

    struct Cleaned: Equatable {
        var segments: [WhisperSegment]
        var dropped: Int
        var inaudible: Int
    }

    static let inaudibleText = "[inaudible]"

    private static let spanPattern = try! NSRegularExpression(pattern: "\\[[^\\]]*\\]|\\([^)]*\\)|\\*[^*]*\\*")
    private static let inaudiblePattern = try! NSRegularExpression(
        pattern: "inaudible|unintelligible|indistinct", options: [.caseInsensitive])

    static func clean(_ segments: [WhisperSegment], fromRetry: Bool) -> Cleaned {
        var kept: [WhisperSegment] = []
        var dropped = 0
        var inaudible = 0
        for original in segments {
            var segment = original
            var text = original.text
            var flagged = false
            var removed = false

            // a) sound labels and music notes
            let spans = spanPattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
            if !spans.isEmpty {
                removed = true
                for match in spans {
                    guard let range = Range(match.range, in: text) else { continue }
                    let span = String(text[range])
                    if inaudiblePattern.firstMatch(in: span, range: NSRange(span.startIndex..., in: span)) != nil {
                        flagged = true
                    }
                }
                text = spanPattern.stringByReplacingMatches(
                    in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
            }
            if text.contains("\u{266A}") || text.contains("\u{266B}") {
                removed = true
                text = text.replacingOccurrences(of: "\u{266A}", with: " ")
                    .replacingOccurrences(of: "\u{266B}", with: " ")
            }
            text = collapse(text)
            if removed { segment.words = [] }

            // b) nothing speakable left
            if !text.contains(where: { $0.isLetter || $0.isNumber }) {
                if flagged {
                    segment.text = inaudibleText
                    segment.words = []
                    kept.append(segment)
                    inaudible += 1
                } else {
                    dropped += 1
                }
                continue
            }
            // c) whisper's own skip rule
            if let nsp = segment.noSpeechProb, let lp = segment.avgLogprob, nsp > noSpeechProb, lp < lowLogprob {
                dropped += 1
                continue
            }
            // d) a retry must be confident
            if fromRetry, let lp = segment.avgLogprob, lp < retryLogprob {
                dropped += 1
                continue
            }
            // e) repetition loops
            if text.utf8.count >= 40, compressionRatio(text) > maxCompression {
                dropped += 1
                continue
            }
            segment.text = text
            kept.append(segment)
        }
        return Cleaned(segments: kept, dropped: dropped, inaudible: inaudible)
    }

    /// Whisper sometimes repeats its initial prompt on near-silent audio (measured: the fake meeting, 8 times on
    /// residual echo). Removes every run of 4 or more consecutive words that also occur consecutively in the prompt.
    static let promptRunWords = 4

    private static func normalise(_ token: Substring) -> String {
        String(token.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    static func stripPrompt(_ segments: [WhisperSegment], prompt: String) -> (segments: [WhisperSegment], removed: Int) {
        let promptWords = prompt.split(whereSeparator: { $0.isWhitespace }).map(normalise).filter { !$0.isEmpty }
        if promptWords.count < promptRunWords { return (segments, 0) }
        var out: [WhisperSegment] = []
        var removed = 0
        for original in segments {
            let tokens = original.text.split(whereSeparator: { $0.isWhitespace })
            let norm = tokens.map(normalise)
            var drop = [Bool](repeating: false, count: tokens.count)
            var i = 0
            while i < tokens.count {
                if norm[i].isEmpty { i += 1; continue }
                // the longest prompt stretch starting at token i (empty-normalised tokens are skipped)
                var bestEnd = -1   // index of the last token of the best run
                var bestWords = 0
                for start in promptWords.indices where promptWords[start] == norm[i] {
                    var t = i
                    var p = start
                    var lastMatch = i
                    var matched = 0
                    while t < tokens.count && p < promptWords.count {
                        if norm[t].isEmpty { t += 1; continue }
                        if norm[t] != promptWords[p] { break }
                        matched += 1
                        lastMatch = t
                        t += 1
                        p += 1
                    }
                    if matched > bestWords { bestWords = matched; bestEnd = lastMatch }
                }
                if bestWords >= promptRunWords {
                    for k in i...bestEnd { drop[k] = true }
                    i = bestEnd + 1
                } else {
                    i += 1
                }
            }
            if !drop.contains(true) { out.append(original); continue }
            removed += 1
            var segment = original
            segment.text = zip(tokens, drop).filter { !$0.1 }.map { String($0.0) }.joined(separator: " ")
            segment.words = []
            if segment.text.contains(where: { $0.isLetter || $0.isNumber }) { out.append(segment) }
        }
        return (out, removed)
    }

    /// The vocabulary label's first three words as the prompt carries them (ScreenContext.prompt: "Names and words
    /// here:", "Namen und Wörter hier:"). Whisper repeats the label without "here" and with any one of the listed words
    /// ("Names and words: <word>."), which the 4-word run rule cannot see (measured: the owner's 13 minute run, about 15
    /// times; the silent-user fake meeting, once). The first three words are matched, and the third must end in ":" or
    /// be followed by "here"/"hier", so a user saying "names and words for the glossary" keeps it.
    static let promptLabels: [[String]] = [["names", "and", "words"], ["namen", "und", "wörter"]]
    static let promptLabelTails: Set<String> = ["here", "hier"]

    /// Removes every repeat of the prompt's vocabulary label: from the label through the end of its sentence (the
    /// first token ending in ".", "!" or "?"), at most the label plus twice the prompt's word count after its label
    /// plus 2 tokens. Does nothing when the prompt carries no label. `removed` counts segments changed.
    static func stripPromptLabel(_ segments: [WhisperSegment], prompt: String) -> (segments: [WhisperSegment], removed: Int) {
        let promptWords = prompt.split(whereSeparator: { $0.isWhitespace }).map(normalise).filter { !$0.isEmpty }
        var label: [String]?
        var listCount = 0
        for candidate in promptLabels {
            guard let at = firstRun(candidate, in: promptWords) else { continue }
            label = candidate
            // the label's own words ("here") and the listed words after it
            listCount = max(0, promptWords.count - at - candidate.count)
        }
        guard let label else { return (segments, 0) }
        let maxTail = 2 * listCount + 2
        var out: [WhisperSegment] = []
        var removed = 0
        for original in segments {
            let tokens = original.text.split(whereSeparator: { $0.isWhitespace })
            let norm = tokens.map(normalise)
            var drop = [Bool](repeating: false, count: tokens.count)
            var i = 0
            while i + label.count <= tokens.count {
                if Array(norm[i..<(i + label.count)]) != label { i += 1; continue }
                var j = i + label.count - 1
                let colon = tokens[j].hasSuffix(":")
                let tail = j + 1 < tokens.count && promptLabelTails.contains(norm[j + 1])
                if !colon && !tail { i += 1; continue }
                let limit = min(tokens.count - 1, j + maxTail)
                while j < limit && !endsSentence(tokens[j]) { j += 1 }
                for k in i...j { drop[k] = true }
                i = j + 1
            }
            if !drop.contains(true) { out.append(original); continue }
            removed += 1
            var segment = original
            segment.text = zip(tokens, drop).filter { !$0.1 }.map { String($0.0) }.joined(separator: " ")
            segment.words = []
            if segment.text.contains(where: { $0.isLetter || $0.isNumber }) { out.append(segment) }
        }
        return (out, removed)
    }

    /// Index of the first place `run` occurs consecutively in `words`, or nil.
    private static func firstRun(_ run: [String], in words: [String]) -> Int? {
        guard !run.isEmpty, words.count >= run.count else { return nil }
        for i in 0...(words.count - run.count) where Array(words[i..<(i + run.count)]) == run { return i }
        return nil
    }

    private static func endsSentence(_ token: Substring) -> Bool {
        let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"')]"))
        guard let last = trimmed.last else { return false }
        return last == "." || last == "!" || last == "?"
    }

    private static func collapse(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// utf8 byte count / zlib-compressed byte count.
    static func compressionRatio(_ text: String) -> Double {
        let raw = Data(text.utf8)
        guard !raw.isEmpty else { return 0 }
        guard let packed = try? (raw as NSData).compressed(using: .zlib), packed.length > 0 else { return 0 }
        return Double(raw.count) / Double(packed.length)
    }

    /// Whitespace tokens with a letter or digit; "[inaudible]" counts 0.
    static func wordCount(_ segments: [WhisperSegment]) -> Int {
        var n = 0
        for segment in segments where segment.text != inaudibleText {
            for token in segment.text.split(whereSeparator: { $0.isWhitespace })
            where token.contains(where: { $0.isLetter || $0.isNumber }) {
                n += 1
            }
        }
        return n
    }

    /// True when a piece looks like the decoder stopped early: speech >= 5 s and words/speech < 1.0.
    static func needsRetry(words: Int, speech: Double) -> Bool {
        speech >= minRetrySpeech && Double(words) / speech < minWordsPerSecond
    }

    /// The candidate with the most words; ties go to the earlier one. 0 for an empty list.
    static func best(_ candidates: [Cleaned]) -> Int {
        var bestIndex = 0
        var bestWords = -1
        for (i, candidate) in candidates.enumerated() {
            let n = wordCount(candidate.segments)
            if n > bestWords { bestWords = n; bestIndex = i }
        }
        return bestIndex
    }
}
