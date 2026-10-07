import AppKit
import Foundation
import ServiceManagement

/// Removes talkflow from this Mac: the app (with the speech engine inside
/// it), the engine's background service, the speech models, logs, caches,
/// saved API keys, the login item and the app's permissions.
///
/// The user's data folder (`UserData.directory`: stats and settings) is kept,
/// so installing again picks up where they left off. Homebrew is never
/// touched: the engine ships in the app, and a whisper-cpp the user has in
/// Homebrew is theirs.
enum Uninstaller {
    struct Step {
        let title: String
        let run: () -> Void
    }

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private static var bundleID: String { Bundle.main.bundleIdentifier ?? "com.samir.talkflow" }

    /// The running app bundle, or nil for a bare `.build` binary, which is
    /// never moved to the Trash.
    static var appBundle: URL? {
        let url = Bundle.main.bundleURL
        return url.pathExtension == "app" ? url : nil
    }

    /// Every step, in order. Building the list changes nothing, so
    /// `--uninstallplan` can print it.
    static func steps() -> [Step] {
        var steps: [Step] = []
        let uid = getuid()
        let models = SpeechEngine.modelPath.deletingLastPathComponent()

        steps.append(Step(title: "Save your settings to \(UserData.settingsURL.path)") { UserData.backUp() })
        steps.append(Step(title: "Stop the speech engine") {
            FinalPassEngine.stop()
            run("/bin/launchctl", ["bootout", "gui/\(uid)/\(SpeechEngine.agentLabel)"])
            run("/usr/bin/pkill", ["-f", "\(models.path)/"])
        })
        steps.append(Step(title: "Remove the speech engine's background service (\(SpeechEngine.agentPlistURL.path))") {
            remove(SpeechEngine.agentPlistURL)
        })
        steps.append(Step(title: "Remove the speech models (\(models.path))") { remove(models) })

        if let homebrew = SpeechEngine.homebrewServerPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            steps.append(Step(title: "Keep Homebrew's whisper-cpp (\(homebrew)); talkflow does not use it. To remove it: brew uninstall whisper-cpp") {})
        }

        steps.append(Step(title: "Remove saved API keys from the Keychain") {
            APIKeys.remove(.openAI)
            APIKeys.remove(.anthropic)
        })
        let library = home.appendingPathComponent("Library")
        let leftovers = [
            SpeechEngine.logDirectory,
            library.appendingPathComponent("Caches/\(bundleID)"),
            library.appendingPathComponent("HTTPStorages/\(bundleID)"),
            library.appendingPathComponent("Saved Application State/\(bundleID).savedState"),
        ]
        steps.append(Step(title: "Remove logs and caches") { leftovers.forEach(remove) })
        steps.append(Step(title: "Remove the login item") { try? SMAppService.mainApp.unregister() })
        steps.append(Step(title: "Reset talkflow's Microphone, Accessibility and Input Monitoring permissions") {
            run("/usr/bin/tccutil", ["reset", "All", bundleID])
        })
        if let app = appBundle {
            steps.append(Step(title: "Move \(app.lastPathComponent) to the Trash") {
                try? FileManager.default.trashItem(at: app, resultingItemURL: nil)
            })
        }
        steps.append(Step(title: "Quit, then remove the app's preferences and any login agent") {})
        return steps
    }

    /// Runs every step off the main thread, reporting each title, then quits.
    /// The preferences and a launchd agent for the app itself are removed by
    /// a small script once this process has exited, so nothing rewrites them.
    static func run(progress: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            for step in steps() {
                DispatchQueue.main.async { progress(step.title) }
                print("talkflowd: uninstall: \(step.title)")
                step.run()
            }
            let pid = ProcessInfo.processInfo.processIdentifier
            let agent = home.appendingPathComponent("Library/LaunchAgents/\(bundleID).plist").path
            let script = "for _ in $(seq 50); do kill -0 \(pid) 2>/dev/null || break; sleep 0.2; done; "
                + "/bin/launchctl bootout gui/\(getuid())/\(bundleID) 2>/dev/null; "
                + "/bin/rm -f '\(agent)'; /usr/bin/defaults delete \(bundleID) 2>/dev/null; "
                + "/usr/bin/defaults delete talkflowd 2>/dev/null; true"
            let after = Process()
            after.executableURL = URL(fileURLWithPath: "/bin/sh")
            after.arguments = ["-c", script]
            try? after.run()
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    /// Asks first. Lists what goes and what stays.
    static func confirmAndRun(progress: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Uninstall talkflow?"
        alert.informativeText = """
        This removes talkflow, its speech engine and models, saved API keys, logs, \
        the login item and talkflow's permissions, then quits. Homebrew and anything \
        installed with it are left alone.

        Your stats and settings stay in \(UserData.directory.path), so installing \
        talkflow again picks up where you left off. Delete that folder for a completely \
        fresh start.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        run(progress: progress)
    }

    private static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    private static func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
