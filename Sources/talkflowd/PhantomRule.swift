import Foundation

/// Drops a "You" piece whose whole reply is a stock phrase whisper makes up on near-silence ("Thank you.", "Okay.",
/// "I'm sorry.", "Beep.") when the piece is short and quiet. A clearly audible "Thank you." from the user is louder
/// than `maxLevelDB` and stays. Pure; no I/O.
enum PhantomRule {
    /// Pieces with more speech than this are never phantoms (the owner's run: phantoms were 0.2 to 1 s).
    static let maxSpeechSeconds = 1.5
    /// Mean level of the piece's samples, dBFS. A user's short word on the fake meeting's mic sits at -27 to -34 dBFS;
    /// the near-end noise whisper answered with "Thank you." sits at -57 to -66.
    static let maxLevelDB = -45.0

    /// "You" pieces quieter than this (mean level of the samples, dBFS) are not sent at all. Measured on the fake meeting
    /// (mic_speakers.wav, 25 November 2026): the user's pieces sit at -36.5 to -28.5 dBFS; the near-end noise pieces
    /// (keyboard) at -67.9 to -64.8, and every one of those came back as a stock phrase, the prompt or 3 made-up words.
    /// 15 dB under the user's quietest piece of 0.6 s of speech.
    static let minSendLevelDB = -60.0

    /// Phrases, normalised (lowercase, letters, digits and apostrophes, single spaces). A reply that is one or more of
    /// these back to back is a stock reply.
    static let phrases: Set<String> = [
        "thank you", "thanks", "thank you very much", "thank you so much", "thank you for watching",
        "thanks for watching", "okay", "ok", "i'm sorry", "sorry", "bye", "bye bye", "goodbye", "beep", "shh", "shhh",
        "yeah", "yes", "no", "amen", "you", "so", "oh", "hmm", "mm", "uh", "um", "huh", "hey", "hi", "hello", "wow",
        "right", "alright", "all right",
    ]
    private static let longestPhrase = 4

    /// Lowercase words of [a-z0-9'] (other characters split words); "-" and punctuation go.
    static func words(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in text.lowercased() {
            if ch.isLetter || ch.isNumber || ch == "'" || ch == "\u{2019}" {
                current.append(ch == "\u{2019}" ? "'" : ch)
            } else if !current.isEmpty {
                out.append(current)
                current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// True when the words are one or more stock phrases back to back (longest match first). False for no words.
    static func isStock(_ text: String) -> Bool {
        let w = words(text)
        if w.isEmpty { return false }
        var i = 0
        while i < w.count {
            var matched = 0
            for n in stride(from: min(longestPhrase, w.count - i), through: 1, by: -1) {
                if phrases.contains(w[i..<(i + n)].joined(separator: " ")) { matched = n; break }
            }
            if matched == 0 { return false }
            i += matched
        }
        return true
    }

    /// Mean energy of the samples in dBFS (Int16 scale); -120 for none.
    static func levelDB(_ samples: ArraySlice<Int16>) -> Double {
        if samples.isEmpty { return -120 }
        var acc = 0.0
        for v in samples { acc += Double(v) * Double(v) }
        return 10 * log10(max(acc / Double(samples.count), 1e-6) / (32768.0 * 32768.0))
    }

    /// False for a "you" piece below minSendLevelDB; the other track is always sent.
    static func shouldSend(track: String, levelDB: Double) -> Bool {
        track != "you" || levelDB >= minSendLevelDB
    }

    static func isPhantom(_ segments: [WhisperSegment], speech: Double, levelDB: Double) -> Bool {
        if speech > maxSpeechSeconds || levelDB >= maxLevelDB { return false }
        let text = segments.map { $0.text }.joined(separator: " ")
        return isStock(text)
    }
}
