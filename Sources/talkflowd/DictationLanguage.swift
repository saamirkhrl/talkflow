import Foundation
import NaturalLanguage

/// The language the user dictates in, from the Settings page.
///
/// whisper-server assumes English unless told otherwise, and it does not just
/// mishear other languages, it translates them: German speech came back as an
/// English paraphrase ("Hallo Markus, kannst du mir bitte bis Freitag die
/// Unterlagen ... schicken?" -> "Hello Marcus, can you please please give me
/// the information for the project?"). Measured on large-v3-turbo; sending
/// `language=de` with the same clip returned the German sentence word for
/// word. So the language goes with every request (`Transcriber`), and
/// small.en, which only knows English, is swapped for the multilingual small
/// model as the live engine (`LiveModel`).
///
/// A fixed language is safer than `auto` for short clips, where whisper's
/// detection guesses from very little audio, but it also translates: with
/// German set, English speech comes back in German. `auto` is for people who
/// switch between languages.
enum DictationLanguage: String, CaseIterable {
    case english = "en"
    case german = "de"
    case automatic = "auto"

    var title: String {
        switch self {
        case .english: return "English"
        case .german: return "Deutsch"
        case .automatic: return "Automatic"
        }
    }

    var detail: String {
        switch self {
        case .english: return "Speak English."
        case .german: return "Speak German."
        case .automatic: return "Detects the language of each dictation."
        }
    }

    /// Shown under the language choice in Settings and setup.
    static let moreComing = "More languages are coming."

    /// The `language` field whisper-server takes.
    var whisperCode: String { rawValue }

    /// small.en only knows English.
    var needsMultilingualModel: Bool { self != .english }

    /// The language the whisper prompt is written in. Automatic follows the
    /// Mac's own language, since that is most likely what is spoken.
    var promptLanguage: DictationLanguage {
        guard self == .automatic else { return self }
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.hasPrefix("de") ? .german : .english
    }

    /// For OpenAI: an ISO 639-1 code, or nil to let it detect. English is
    /// left to detection too, as it was before this setting existed.
    var openAICode: String? { self == .german ? "de" : nil }

    /// Whether the English-only rules (filler sounds that are German words,
    /// self-corrections, lowercasing a continued sentence) may run on
    /// `transcript`. Automatic decides per dictation from the text itself.
    /// Pure, for `--streamtest`.
    func usesEnglishRules(for transcript: String) -> Bool {
        switch self {
        case .english: return true
        case .german: return false
        case .automatic:
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(transcript)
            return (recognizer.dominantLanguage ?? .english) == .english
        }
    }
}
