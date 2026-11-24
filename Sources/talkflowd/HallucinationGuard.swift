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
