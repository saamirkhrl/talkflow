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
    /// On by default, except on a Mac with under 8 GB of memory, where holding
    /// both models would crowd out everything else. The small model still
    /// drives the live caption. A choice made in Settings always wins.
    static var accurateFinalPass: Bool {
        get { defaults.object(forKey: "accurateFinalPass") as? Bool ?? !hasLittleMemory }
        set { defaults.set(newValue, forKey: "accurateFinalPass") }
    }

    /// Under 8 GB. An "8 GB" Mac reports a little less than 8 GiB of usable
    /// memory, so the cut is 7.5 GiB, which leaves every 8 GB Mac on.
    static var hasLittleMemory: Bool {
        ProcessInfo.processInfo.physicalMemory < 8_053_063_680 // 7.5 GiB
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

    /// How dictated text is written: capitals and full stops, casual, or all
    /// lowercase. Settings and the menu bar menu both change it.
    static var writingStyle: WritingStyle {
        get { WritingStyle(rawValue: defaults.string(forKey: "writingStyle") ?? "") ?? .formal }
        set {
            defaults.set(newValue.rawValue, forKey: "writingStyle")
            NotificationCenter.default.post(name: .writingStyleChanged, object: nil)
        }
    }

    /// Transcribe the final text with OpenAI, using the user's own key. The
    /// live caption stays on the local model either way.
    static var useOpenAITranscription: Bool {
        get { defaults.bool(forKey: "useOpenAITranscription") }
        set { defaults.set(newValue, forKey: "useOpenAITranscription") }
    }

    /// Run the punctuation pass with Claude, using the user's own key, in
    /// place of Apple's on-device model.
    static var useClaudePunctuation: Bool {
        get { defaults.bool(forKey: "useClaudePunctuation") }
        set { defaults.set(newValue, forKey: "useClaudePunctuation") }
    }

    /// Which Claude model the punctuation pass uses.
    static var claudeModel: ClaudePolish.Model {
        get { ClaudePolish.Model(rawValue: defaults.string(forKey: "claudeModel") ?? "") ?? .opus }
        set { defaults.set(newValue.rawValue, forKey: "claudeModel") }
    }

    /// The keys held to dictate, from the Settings page. Fn by default.
    /// "macHotkey" because the keycodes are the Mac's own; the Windows app
    /// keeps its shortcut in windows.json and leaves this key alone.
    static var hotkey: HotkeySpec {
        get { (defaults.array(forKey: "macHotkey") as? [[Int]]).flatMap(HotkeySpec.init(stored:)) ?? .fn }
        set {
            defaults.set(newValue.stored, forKey: "macHotkey")
            NotificationCenter.default.post(name: .hotkeyChanged, object: nil)
        }
    }
}

extension Notification.Name {
    /// Posted when the writing style changes, so the menu and the Settings
    /// page stay in step whichever one changed it.
    static let writingStyleChanged = Notification.Name("talkflowWritingStyleChanged")
    /// Posted when talkflow turns the accurate final pass off by itself (see
    /// `FinalPassSpeed`), so the Settings toggle follows.
    static let accurateFinalPassChanged = Notification.Name("talkflowAccurateFinalPassChanged")
    /// Posted when the shortcut changes, so the key listener follows it.
    static let hotkeyChanged = Notification.Name("talkflowHotkeyChanged")
}
