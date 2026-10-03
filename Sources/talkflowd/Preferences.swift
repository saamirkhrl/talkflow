import Foundation

/// The user's settings, from the Settings page. Read at the start of each hold
/// and fixed for its length, so flipping one mid-dictation never changes how a
/// half-finished hold is written.
enum Preferences {
    private static let defaults = UserDefaults.standard

    /// Type into the field while the key is held (the original behaviour).
    /// Off by default: the words are shown in the overlay instead and inserted
    /// once, already corrected, at release - nothing on screen is ever deleted
    /// or retyped, which is what makes a dictation feel smooth.
    static var typeWhileSpeaking: Bool {
        get { defaults.bool(forKey: "typeWhileSpeaking") }
        set { defaults.set(newValue, forKey: "typeWhileSpeaking") }
    }

    /// Transcribe the final pass with the large model when it is installed.
    /// On by default; the small model still drives the live caption.
    static var accurateFinalPass: Bool {
        get { defaults.object(forKey: "accurateFinalPass") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "accurateFinalPass") }
    }

    /// Let Apple's on-device model suggest punctuation, casing and line breaks
    /// (never words - see `Polish`). Off by default: measured on this M4 it adds
    /// 0.5-1.8s at release, which costs more smoothness than it buys.
    static var aiPolish: Bool {
        get { defaults.bool(forKey: "aiPolish") }
        set { defaults.set(newValue, forKey: "aiPolish") }
    }

    /// Words whisper is biased towards, learned from the user's own fixes after
    /// a dictation (see `Vocabulary`). Newest first.
    static var learnedWords: [String] {
        get { defaults.stringArray(forKey: "learnedWords") ?? [] }
        set { defaults.set(newValue, forKey: "learnedWords") }
    }
}
