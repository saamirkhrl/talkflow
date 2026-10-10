import Foundation

/// The one folder that holds everything that is the user's own:
/// `~/Library/Application Support/talkflow/`.
///
/// - `stats.json`: words dictated, sessions, speaking time, words per day
///   (written by `StatsStore`).
/// - `settings.json`: a copy of the Settings page and the learned words,
///   rewritten whenever one changes.
///
/// Uninstalling (`Uninstaller`) keeps this folder, so installing again picks
/// up where the user left off: stats are read straight from it, and settings
/// are copied back into the app's preferences on the first launch that has
/// none. Deleting the folder is a completely fresh start.
enum UserData {
    static let directory: URL = {
        // TALKFLOW_DATA_DIR is for tests only, so they never touch the real folder.
        let dir = ProcessInfo.processInfo.environment["TALKFLOW_DATA_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/talkflow")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var settingsURL: URL { directory.appendingPathComponent("settings.json") }

    /// The preference keys that are the user's choices. Setup state and
    /// API keys (kept in the Keychain) are deliberately not here.
    static let settingKeys = [
        "typeWhileSpeaking", "accurateFinalPass", "aiPolish", "learnedWords", "writingStyle",
        "useOpenAITranscription", "useClaudePunctuation", "claudeModel", "dashboardChart", "macHotkey",
    ]

    private static var observer: NSObjectProtocol?
    private static var pending: DispatchWorkItem?

    /// At launch, before anything reads a preference: restore settings from
    /// the folder when this install has none of its own (a reinstall, or the
    /// preferences file was removed), then keep the folder's copy current.
    static func start() {
        restoreIfNeeded()
        backUp()
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in
            // Coalesce bursts (a toggle writes once, a learned word twice).
            pending?.cancel()
            let work = DispatchWorkItem { backUp() }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
    }

    static func restoreIfNeeded() {
        let defaults = UserDefaults.standard
        guard !settingKeys.contains(where: { defaults.object(forKey: $0) != nil }),
              let raw = try? Data(contentsOf: settingsURL),
              let saved = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { return }
        var restored = 0
        for key in settingKeys {
            guard let value = saved[key] else { continue }
            defaults.set(value, forKey: key)
            restored += 1
        }
        print("talkflowd: restored \(restored) setting(s) from \(settingsURL.path)")
    }

    static func backUp() {
        let defaults = UserDefaults.standard
        var values: [String: Any] = [:]
        for key in settingKeys {
            if let value = defaults.object(forKey: key), JSONSerialization.isValidJSONObject([key: value]) {
                values[key] = value
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: settingsURL, options: .atomic)
    }
}
