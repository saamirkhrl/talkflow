import AppKit

/// What the Settings page does outside itself: the Keychain, checking a key
/// with its provider, the model downloads, the final-pass server and the
/// uninstaller. `.live` is the app. `.preview()` (`--windowpreview`,
/// `--dashboardshot`) keeps keys in memory and does none of the rest, so a
/// test build never reads or writes the real Keychain, downloads a model,
/// stops the installed app's final-pass server or uninstalls anything.
struct SettingsEnvironment {
    var hasKey: (APIKeys.Provider) -> Bool
    /// Calls back with an error message, or nil when the key works.
    var validateKey: (APIKeys.Provider, String, @escaping (String?) -> Void) -> Void
    var saveKey: (String, APIKeys.Provider) -> Bool
    var removeKey: (APIKeys.Provider) -> Void
    /// The last four characters of a saved key, so Settings can show which key it is. Nil without a key or for
    /// a key shorter than 12 characters. Never logged.
    var keySuffix: (APIKeys.Provider) -> String?
    var accurateFinalPassChanged: (Bool) -> Void
    /// The language changed, or the user asked to retry its download.
    var languageChanged: () -> Void
    /// Nil where uninstalling is not offered.
    var uninstall: ((@escaping (String) -> Void) -> Void)?
    var isPreview: Bool

    static let live = SettingsEnvironment(
        hasKey: { APIKeys.hasKey($0) },
        validateKey: { provider, key, done in
            if provider == .openAI { CloudTranscriber.validate(key, completion: done) }
            else { ClaudePolish.validate(key, completion: done) }
        },
        saveKey: { APIKeys.save($0, for: $1) },
        removeKey: { APIKeys.remove($0) },
        keySuffix: { p in
            guard let k = APIKeys.key(for: p), k.count >= 12 else { return nil }
            return String(k.suffix(4))
        },
        accurateFinalPassChanged: { on in if on { FinalPassEngine.prepare() } else { FinalPassEngine.stop() } },
        languageChanged: { LiveModel.prepare() },
        uninstall: { progress in Uninstaller.confirmAndRun(progress: progress) },
        isPreview: false
    )

    /// Keys live in this one value only; nothing is checked over the network.
    static func preview() -> SettingsEnvironment {
        final class Keys { var saved: [APIKeys.Provider: String] = [:] }
        let keys = Keys()
        return SettingsEnvironment(
            hasKey: { keys.saved[$0] != nil },
            validateKey: { _, _, done in done(nil) },
            saveKey: { value, provider in keys.saved[provider] = value; return true },
            removeKey: { keys.saved[$0] = nil },
            keySuffix: { p in
                guard let k = keys.saved[p], k.count >= 12 else { return nil }
                return String(k.suffix(4))
            },
            accurateFinalPassChanged: { _ in },
            languageChanged: {},
            uninstall: nil,
            isPreview: true
        )
    }
}
