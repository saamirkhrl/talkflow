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

    /// `--newlinetest` - types a two-line marker into the focused field.
    ///
    /// A dictation containing a paragraph break sends "\n" as a unicode
    /// character rather than as the Return key, precisely so that Slack and
    /// Discord don't send the message halfway through. That assumption has never
    /// been tested in either app, and it only became reachable now that
    /// keystrokes actually land there. Run it in a DM to yourself: if the
    /// assumption is wrong, this posts a message.
    static func newlineProbe(after seconds: Double) -> Never {
        try? FileManager.default.removeItem(at: logURL)
        report("--- newlinetest ---")
        report("focus a message box you don't mind typing into - a DM to yourself.")
        report("if the newline sends the message, that is the answer, and you will")
        report("have posted \"talkflow line one\".")

        countdown(from: Int(seconds.rounded()))
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
            report("target: \(app)")
            LiveType.insert("talkflow line one\nline two")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                report("posted. What happened?")
                report("     both lines sitting in the box -> newlines are safe here")
                report("     \"talkflow line one\" was sent as a message -> paragraph breaks")
                report("       must be suppressed in this app")
                report("     only one line, no send -> the newline was swallowed")
                report("--- end ---")
                exit(0)
            }
        }
        RunLoop.main.run()
        exit(0)
    }

    /// `--stresstest [seconds] [characters]` - the measurement nobody has ever
    /// taken: how large a keystroke rewrite the app you actually dictate into can
    /// receive without losing part of it.
    ///
    /// Every existing test types into a text view this process owns, which is the
    /// fastest possible consumer and keeps every character at any rate measured.
    /// The failures are in Terminal and the Electron apps, and they are invisible
    /// from inside this process - a dropped key event is reported nowhere. So the
    /// payload is written to be read: numbered five-character groups, `a001 a002
    /// a003 ...`, then rewritten to `b001 b002 b003 ...`. If groups are missing
    /// the sequence jumps, and where it jumps says exactly which part of the
    /// burst was dropped.
    ///
    /// Run it in an empty text box in the app you care about. Nothing is read
    /// back and nothing is asserted - your eyes are the instrument.
    static func stress(after seconds: Double, characters: Int) -> Never {
        try? FileManager.default.removeItem(at: logURL)
        let before = numbered("a", count: characters)
        let after = numbered("b", count: characters)
        let rewriteEvents = before.count + LiveType.chunked(after).count

        report("--- stresstest ---")
        report("focus an EMPTY text box in the app you want measured.")
        report("\(characters) characters go in, then get rewritten - \(rewriteEvents) key events.")

        countdown(from: Int(seconds.rounded()))
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
            report("target: \(app)")
            LiveType.insert(before)

            // Long enough for the insertion to have finished arriving, so that
            // anything missing after the rewrite is the rewrite's doing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                report("step 1 done: \(before.count) characters posted as a plain insert.")
                LiveType.rewrite(deleting: before.count, inserting: after)

                DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                    report("step 2 done: rewrote all \(before.count) characters (\(rewriteEvents) events).")
                    verdict(expected: after)
                    report("--- end ---")
                    exit(0)
                }
            }
        }
        RunLoop.main.run()
        exit(0)
    }

    /// Reads the field back and says whether the rewrite survived.
    ///
    /// Accessibility reads work in apps where Accessibility *writes* cannot be
    /// trusted - Terminal answers a read and lies about a write - so this can
    /// often measure automatically what otherwise needs a person looking at a
    /// screen. When the app will not answer, it falls back to asking.
    private static func verdict(expected: String) {
        guard let got = FieldWriter.readBeforeCaret(expected.utf16.count) else {
            report("this app will not answer an Accessibility read, so look at the box.")
            report("it should read, unbroken:")
            report("     \(expected)")
            report("b001, b002, b003 ... with no gaps means this app survives a rewrite")
            report("this large. A jump - b007 straight to b031 - is the bug, and the gap")
            report("is what was dropped.")
            report("re-run smaller to find where it starts holding:  --stresstest 8 200")
            return
        }

        if got == expected {
            report("PASS  all \(expected.count) characters arrived, in order, nothing dropped.")
            report("      this app survives a rewrite of \(expected.count) characters.")
            return
        }

        report("FAIL  the field does not match what was posted.")
        report("      posted \(expected.count) characters, read back \(got.count).")
        let wanted = Array(expected)
        let arrived = Array(got)
        var index = 0
        while index < wanted.count, index < arrived.count, wanted[index] == arrived[index] { index += 1 }
        report("      first divergence at character \(index).")
        report("      wanted from there: \(String(wanted[index...].prefix(60)).debugDescription)")
        report("      got from there:    \(String(arrived[min(index, arrived.count)...].prefix(60)).debugDescription)")
        report("      re-run smaller to find the ceiling:  --stresstest 8 200")
    }

    /// `a001 a002 a003 ...`, trimmed to exactly `count` characters. Five
    /// characters per group, so a dropped 16-unit event takes out three of them
    /// and the gap is obvious at a glance.
    private static func numbered(_ tag: Character, count: Int) -> String {
        var out = ""
        var index = 1
        while out.count < count {
            out += "\(tag)\(String(format: "%03d", index)) "
            index += 1
        }
        return String(out.prefix(count))
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
