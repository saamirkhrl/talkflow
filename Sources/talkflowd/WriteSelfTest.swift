import AppKit
import CoreGraphics
import Foundation

/// `talkflowd --writetest [seconds]` - points both write paths at whatever app
/// the user focuses, and reports what each one claims and what can be proved.
///
/// Unlike `--typetest`, which types into a text view this process owns, this
/// types into somebody else's app. That is the entire point: Slack, Discord,
/// Terminal and Cursor each answer the Accessibility API differently, and the
/// app appeared completely dead in three of them while working in the fourth.
/// Guessing which path an app accepts, from the outside, is what wasted the
/// previous rounds.
///
/// It writes two short markers into the focused field, so run it somewhere
/// harmless - a scratch message box, an empty document, a shell prompt you are
/// about to clear.
enum WriteSelfTest {
    private static let axMarker = "[ax] "
    private static let keyMarker = "[keys] "

    /// `--focusprobe` - the report with nothing written anywhere. Safe to run
    /// against whatever the user happens to have in front.
    static func probe() -> Never {
        let app = NSWorkspace.shared.frontmostApplication
        report("frontmost: \(app?.localizedName ?? "unknown") (pid \(app?.processIdentifier ?? -1))")
        report(FieldWriter.focusReport())
        exit(0)
    }

    static func run(after seconds: Double) -> Never {
        try? FileManager.default.removeItem(at: logURL)
        report("--- writetest ---")
        report("focus the app and the text field you want tested. Two short")
        report("markers get typed into it: \(axMarker.debugDescription) then \(keyMarker.debugDescription).")

        countdown(from: Int(seconds.rounded()))
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: measure)

        // A run loop, because the keystroke path is paced on a background queue
        // and needs real time to pass before its result can be read back.
        RunLoop.main.run()
        exit(0)
    }

    private static func countdown(from seconds: Int) {
        guard seconds > 0 else { return }
        for remaining in stride(from: seconds, through: 1, by: -1) {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(seconds - remaining)) {
                let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
                report("     \(remaining)... (frontmost: \(app))")
            }
        }
    }

    private static func measure() {
        let app = NSWorkspace.shared.frontmostApplication
        let name = app?.localizedName ?? "unknown"
        report("target: \(name) (pid \(app?.processIdentifier ?? -1))")

        // The Fn key is physically held down during a real dictation, and a
        // synthetic key event that inherits that modifier is Fn+key, which is
        // not the key. This says whether that is happening here.
        let flags = CGEventSource.flagsState(.combinedSessionState)
        report("modifier flags right now: \(flags.rawValue == 0 ? "none" : String(describing: flags))")

        report("focused element:")
        report("     " + FieldWriter.focusReport())

        let attempt = FieldWriter.replaceBeforeCaret(expected: "", with: axMarker)
        report(attempt.succeeded
               ? "ok   accessibility write landed and was verified"
               : "     accessibility write declined -> \(attempt.reason)")

        // Runs regardless of the AX result: an app where AX works may still be
        // an app where keystrokes do not, and the streaming path uses whichever
        // one answers.
        LiveType.insert(keyMarker)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            report("     keystrokes posted (\(keyMarker.count) characters)")
            report("look at the field. Report which markers actually appeared:")
            report("     both -> this app accepts either path")
            report("     \(keyMarker.debugDescription) only -> keystroke path only, as expected for Chromium apps")
            report("     \(axMarker.debugDescription) only -> keystrokes are being dropped, which is the real bug")
            report("     neither -> nothing reaches this app at all")
            report("--- end ---")
            exit(0)
        }
    }

    private static let logURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("talkflow-writetest.log")

    /// The process redirects stdout into the app log at launch, so a countdown
    /// printed normally is invisible to the person who has to focus an app while
    /// it runs. Write to the controlling terminal as well.
    private static let tty = FileHandle(forWritingAtPath: "/dev/tty")

    private static func report(_ line: String) {
        print("talkflowd: [writetest] \(line)")
        tty?.write(Data((line + "\n").utf8))
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }
}
