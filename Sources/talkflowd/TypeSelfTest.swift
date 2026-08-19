import AppKit
import Foundation

/// `talkflowd --typetest` - proves LiveType against the real event pipeline by
/// typing into a text view this process owns and reading back what arrived.
///
/// In-field streaming rewrites what it has typed as whisper revises its guess, so
/// a backspace that runs followed by an insert that doesn't is the difference
/// between a live transcript and a destroyed one. That exact failure has already
/// happened here once. Reasoning about it is not enough - what matters is what
/// the window server actually delivers, which is what this measures.
///
/// Must run from the signed bundle: posting events needs the Accessibility grant
/// tied to that bundle's signature.
enum TypeSelfTest {
    private static var window: NSWindow?
    private static var textView: NSTextView?
    private static var failures = 0

    private static let cases: [(String, String)] = [
        ("short chunk", "can you please review the"),
        ("long insert - the payload that once vanished",
         "Dear Mr. Clark, can you please review my portfolio for the annual typographic elevation map of the Alaska Bluewater Salmin"),
        ("emoji across chunk boundaries",
         "I am going to 🍆 💧 you and then some more text follows here 🌉 to push well past one event"),
        ("exactly one chunk", String(repeating: "a", count: 16)),
        ("one past a chunk", String(repeating: "b", count: 17)),
        ("newlines survive", "line one\n\nline two follows after a blank line")
    ]

    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        let frame = NSRect(x: 200, y: 200, width: 560, height: 220)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "TalkFlow LiveType self-test"
        let view = NSTextView(frame: frame)
        view.isEditable = true
        view.isRichText = false
        // Otherwise the text view "helpfully" turns ' into a curly quote and the
        // test reports a character the event pipeline delivered correctly as a
        // dropped one. The harness must measure delivery, nothing else.
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.smartInsertDeleteEnabled = false
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        app.activate(ignoringOtherApps: true)
        self.window = window
        self.textView = view

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { runCase(0) }
        app.run()
        exit(failures == 0 ? 0 : 1)
    }

    /// The sequence that actually broke: whisper re-transcribes the whole buffer
    /// every tick and revises words it already emitted, so the field is rewritten
    /// over and over. Doing that with keystrokes lost characters silently -
    /// "could you please" arrived as "uld you please" - and a single rewrite test
    /// passed anyway, because one rewrite with time to settle is not the problem.
    /// This replays a real revision sequence and checks the exact final text.
    private static let streamingRevisions = [
        "Dear Sarah",
        "Dear Sarah, can you",
        "Dear Sarah, can you please review",
        "Dear Sarah, can you pleased review my pitch",
        "Dear Sarah, can you please review my pitch deck for the water",
        "Dear Sarah, can you please review my pitch deck for the waterbed willow",
        "Dear Sarah, can you please review my pitch deck for the waterbed willow fish. Thank you",
        "Dear Sarah,\n\ncan you please review my pitch deck for the waterbed willow fish.\n\nThank you, Sincerely, Samir."
    ]

    /// Runs the streaming sequence twice: once through Accessibility, and once
    /// with it disabled so the keystroke path used by Slack, Discord and VS Code
    /// is measured on its own. The keystroke run is the one that matters - it is
    /// the path that was silently losing characters.
    private static func runStreamingCase() {
        guard ensureFocused() else { exit(2) }
        textView?.string = ""
        replay(sync: FieldSync(strategy: .preferAccessibility), label: "accessibility", index: 0)
    }

    private static func runKeystrokeStreamingCase() {
        guard ensureFocused() else { exit(2) }
        textView?.string = ""
        replay(sync: FieldSync(strategy: .keystrokesOnly), label: "keystrokes (Electron path)", index: 0)
    }

    /// A late paragraph break rewrites everything after it in one go - the
    /// biggest single edit the app ever makes, and pure keystrokes for a target
    /// with no AX support.
    private static func runLargeRewriteCase() {
        guard ensureFocused() else { exit(2) }
        textView?.string = ""
        let sync = FieldSync(strategy: .keystrokesOnly)
        let flat = "Dear Sarah, can you please review the pitch deck for the quarterly numbers and let me know what you think about the revenue slide. Thank you, Sincerely, Samir."
        let structured = "Dear Sarah,\n\nCan you please review the pitch deck for the quarterly numbers and let me know what you think about the revenue slide.\n\nThank you, Sincerely, Samir."
        sync.sync(to: flat)
        settle(expecting: flat) { _, _ in
            sync.sync(to: structured)
            settle(expecting: structured) { arrived, _ in
                let got = textView?.string ?? ""
                check(arrived, "large keystroke rewrite (\(flat.count) chars restructured)",
                      arrived ? "" : "got \(got.debugDescription)")
                runReleaseSizedRewriteCase(0)
            }
        }
    }

    /// The size the release pass actually reaches in real dictation, taken from
    /// the app's own log: `-422 +471`, `-365 +392`, `-263 +287` are routine.
    /// Every case above is an order of magnitude smaller, which is why they all
    /// pass while a long hold loses its middle on screen.
    ///
    /// Each pair is (what the live path committed, what the release pass wants),
    /// diverging early so the edit deletes and retypes almost the whole string -
    /// exactly the burst that is being reported as lossy.
    private static let releaseSizedRewrites: [(String, String)] = [
        (
            "However, I keep running into this error where once I speak for a long amount of time and I let go it Erases everything so it can rewrite it and that's fine But after it's rewriting it it cuts off like a lot of the thing that I wrote so it writes like the beginning of a couple of seconds of what I said and then only the end and the middle is kind of gone Fix it, please",
            "However, I keep running into this error where once I speak for a long amount of time and I let go, it erases everything so it can rewrite it, and that's fine. But after it is rewriting it, it cuts off a lot of the thing that I wrote, so it writes the beginning, a couple of seconds of what I said, and then only the end, and the middle is kind of gone. Fix it, please."
        ),
        (
            "Dear Sarah I wanted to follow up on the quarterly planning document that we discussed on Tuesday because there are a few numbers in the revenue section that no longer match what finance sent over on Thursday and I think we should reconcile them before the board meeting so that nobody has to ask the same question twice and we can spend the time on the roadmap instead of on the spreadsheet Thanks Samir",
            "Dear Sarah,\n\nI wanted to follow up on the quarterly planning document that we discussed on Tuesday, because there are a few numbers in the revenue section that no longer match what finance sent over on Thursday, and I think we should reconcile them before the board meeting so that nobody has to ask the same question twice and we can spend the time on the roadmap instead of on the spreadsheet.\n\nThanks, Samir."
        )
    ]

    private static func runReleaseSizedRewriteCase(_ index: Int) {
        guard index < releaseSizedRewrites.count else {
            report(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
            exit(failures == 0 ? 0 : 1)
        }
        guard ensureFocused() else { exit(2) }
        textView?.string = ""

        let (live, final) = releaseSizedRewrites[index]
        let sync = FieldSync(strategy: .keystrokesOnly)
        sync.sync(to: live)
        settle(expecting: live, within: 30) { landed, _ in
            let got = textView?.string ?? ""
            check(landed, "release case \(index): live text lands (\(live.count) chars)",
                  "got \(got.count) chars: \(got.debugDescription)")
            let edit = FieldSync.edit(from: live, to: final)
            report("     release case \(index) edit is -\(edit.deleting) +\(edit.inserting.count)")
            sync.sync(to: final)
            self.settle(expecting: final, within: 30) { arrived, elapsed in
                let after = textView?.string ?? ""
                check(arrived, "release case \(index): -\(edit.deleting) +\(edit.inserting.count) rewrite",
                      "after \(String(format: "%.1f", elapsed))s got \(after.count) of \(final.count) chars: \(after.debugDescription)")
                runReleaseSizedRewriteCase(index + 1)
            }
        }
    }

    private static func replay(sync: FieldSync, label: String, index: Int) {
        guard index < streamingRevisions.count else {
            let want = streamingRevisions[streamingRevisions.count - 1]
            settle(expecting: want) { arrived, _ in
                let got = textView?.string ?? ""
                check(arrived, "streaming sequence via \(label) keeps every character",
                      arrived ? "" : "got \(got.debugDescription)")
                check(sync.typedText == got, "internal record matches screen (\(label))")
                if label == "accessibility" {
                    runKeystrokeStreamingCase()
                } else {
                    runLargeRewriteCase()
                }
            }
            return
        }
        let outcome = sync.sync(to: streamingRevisions[index])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            report("     step \(index) [\(outcome.rawValue)] screen=\((textView?.string ?? "").debugDescription)")
            replay(sync: sync, label: label, index: index + 1)
        }
    }

    private static func runCase(_ index: Int) {
        guard index < cases.count else {
            runRewriteCase()
            return
        }
        let (label, text) = cases[index]
        guard ensureFocused() else { exit(2) }

        textView?.string = ""
        LiveType.insert(text)
        settle(expecting: text) { arrived, elapsed in
            check(arrived, "\(label) (\(text.count) chars)",
                  "got \((textView?.string ?? "").count) chars after \(String(format: "%.1f", elapsed))s")
            runCase(index + 1)
        }
    }

    /// Waits for the field to match, rather than checking once after a fixed
    /// pause.
    ///
    /// The fixed pause was 0.7s, and on a busy machine a 122-character insert
    /// came back 120 characters - which reads as the window server dropping
    /// events, the exact historical bug this file exists to catch, but is
    /// indistinguishable from the last event simply not having been delivered
    /// yet. Those are opposite conclusions and the test has to be able to tell
    /// them apart, so it waits for quiescence and reports how long it took. A
    /// slow delivery passes and says so; a lost character still fails.
    private static func settle(
        expecting expected: String,
        within timeout: TimeInterval = 4.0,
        then finish: @escaping (Bool, TimeInterval) -> Void
    ) {
        let startedAt = Date()
        func poll() {
            let elapsed = Date().timeIntervalSince(startedAt)
            if textView?.string == expected {
                if elapsed > 1.0 { report("     (took \(String(format: "%.1f", elapsed))s to arrive)") }
                finish(true, elapsed)
                return
            }
            guard elapsed < timeout else {
                finish(false, elapsed)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: poll)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: poll)
    }

    /// The operation in-field streaming actually performs: type a guess, then
    /// backspace part of it and type a correction. Both halves must land.
    private static func runRewriteCase() {
        guard ensureFocused() else { exit(2) }
        let first = "send me the water emoji and the bridge"
        let corrected = "send me the 💧 and the 🌉 right now please, thanks a lot"

        textView?.string = ""
        LiveType.insert(first)
        settle(expecting: first) { _, _ in
            let onScreen = textView?.string ?? ""
            let shared = commonPrefix(onScreen, corrected)
            LiveType.backspace(count: onScreen.count - shared.count)
            LiveType.insert(String(corrected.dropFirst(shared.count)))
            settle(expecting: corrected) { arrived, _ in
                check(arrived, "backspace-then-retype rewrite",
                      (textView?.string ?? "").debugDescription)
                runStreamingCase()
            }
        }
    }

    private static func commonPrefix(_ a: String, _ b: String) -> String {
        var result = ""
        for (x, y) in zip(a, b) {
            guard x == y else { break }
            result.append(x)
        }
        return result
    }

    /// Never post keystrokes unless this process really is frontmost, or the
    /// fixtures would be typed into whatever the user has open.
    private static func ensureFocused() -> Bool {
        let mine = ProcessInfo.processInfo.processIdentifier
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == mine else {
            report("SKIP could not take focus, refusing to type into another app")
            return false
        }
        return true
    }

    private static func check(_ condition: Bool, _ label: String, _ detail: String = "") {
        report((condition ? "ok   " : "FAIL ") + label + (condition || detail.isEmpty ? "" : " -> " + detail))
        if !condition { failures += 1 }
    }

    /// stdout is redirected into the app log at launch, so results also go to a
    /// file the caller can read directly.
    private static func report(_ line: String) {
        print("talkflowd: [typetest] \(line)")
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("talkflow-typetest.log")
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
