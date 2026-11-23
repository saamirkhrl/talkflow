import AppKit
import Foundation

/// `--windowpreview`: the real app window from a build, on throwaway
/// settings and sample stats, to click around without installing. Closing
/// the window quits.
enum WindowPreview {
    static func run() -> Never {
        PreviewSandbox.enter()
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        PreviewSandbox.useRepoIcon()
        let controller = DashboardController(mode: .preview)
        controller.onClose = {
            PreviewSandbox.leave()
            NSApp.terminate(nil)
        }
        controller.show()
        print("windowpreview: open, data in \(UserData.directory.path), settings in suite \(PreviewSandbox.suiteName)")
        app.run()
        exit(0)
    }
}

/// Settings and data for `--windowpreview` and `--dashboardshot`: a defaults
/// suite of their own and a temporary data folder, both started fresh each
/// run, so neither ever reads or writes the user's own.
enum PreviewSandbox {
    static let suiteName = "com.samir.talkflow.preview"
    private static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("talkflow-preview-data")
    }

    /// First thing, before anything reads a setting, `UserData.directory`
    /// or `StatsStore.shared`.
    static func enter() {
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        setenv("TALKFLOW_DATA_DIR", folder.path, 1)
        guard UserData.directory.standardizedFileURL.path == folder.standardizedFileURL.path else {
            print("preview: the data folder is \(UserData.directory.path), not the sandbox; stopping")
            exit(2)
        }
        guard let suite = UserDefaults(suiteName: suiteName) else {
            print("preview: no defaults suite; stopping")
            exit(2)
        }
        suite.removePersistentDomain(forName: suiteName)
        Preferences.defaults = suite
        Preferences.learnedWords = SampleData.words
        suite.set(SampleData.added, forKey: WordList.addedKey)
        try? SampleData.statsJSON().write(to: folder.appendingPathComponent("stats.json"))
    }

    static func leave() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: folder)
    }

    /// A bare `.build` binary has no icon of its own; use the app's, as
    /// `--onboardingshot` does.
    static func useRepoIcon() {
        _ = NSApplication.shared
        guard Bundle.main.bundleURL.pathExtension != "app" else { return }
        let icon = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Packaging/AppIcon.icns")
        if let image = NSImage(contentsOf: icon) { NSApp.applicationIconImage = image }
    }
}

/// Realistic numbers for the preview and the snapshots, the same each run
/// (relative to today): 45,000 words, 142 wpm, a 51-day streak, 1,240
/// words today, 13 h 28 min saved.
enum SampleData {
    static let words = ["talkflow", "Siobhan", "Kharel", "whisper.cpp", "Vercel", "Supabase"]
    static let added = ["Kharel", "whisper.cpp", "Supabase"]

    static func statsJSON(today: Date = Date()) -> Data {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        let levels = [0, 180, 420, 760, 1240]
        var seed = 7
        var daily: [String: Int] = [:]
        for offset in 0..<(DashboardModel.chartDays + 7) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            seed = (seed * 73 + 11) % 101
            var level = seed % 5
            let weekday = calendar.component(.weekday, from: day)
            if (weekday == 1 || weekday == 7) && level > 1 { level = 1 }
            if offset < 51 && level == 0 { level = 1 }
            daily[formatter.string(from: day)] = levels[level]
        }
        daily[formatter.string(from: today)] = 1240
        if let breaks = calendar.date(byAdding: .day, value: -51, to: today) { daily[formatter.string(from: breaks)] = 0 }
        let json: [String: Any] = [
            "totalWords": 45_000, "totalSessions": 1_800, "totalSpeakingSeconds": 19_014.0, "dailyWordCounts": daily,
        ]
        return (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data()
    }
}
