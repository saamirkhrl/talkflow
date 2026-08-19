import AppKit
import Foundation

// Redirect our own stdout/stderr to the log file directly, rather than relying
// on the LaunchAgent plist's StandardOutPath (which only applies when launchd
// itself starts the process). Anything else that can launch this app - Finder,
// Spotlight, or macOS briefly launching it to fetch an icon when its entry in a
// Privacy & Security pane is viewed - bypasses that redirection entirely, and
// every debugging session today that looked like "nothing happened" was
// actually this: a real session with output going nowhere anyone could see.
let logURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/TalkFlow/talkflow.log")
try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
freopen(logURL.path, "a", stdout)
freopen(logURL.path, "a", stderr)
setvbuf(stdout, nil, _IONBF, 0)
setvbuf(stderr, nil, _IONBF, 0)

print("talkflowd: launched, pid=\(ProcessInfo.processInfo.processIdentifier)")

// Checked before the single-instance guard so it can run while the daemon is up.
// Must be launched from the signed bundle, which holds the microphone grant.
if CommandLine.arguments.contains("--typetest") {
    TypeSelfTest.run()
}

// Pure logic - no mic, no focus, no window - so it can run straight after a
// build, unlike --typetest.
if CommandLine.arguments.contains("--streamtest") {
    StreamSelfTest.run()
}

// Read-only: what the focused element says it accepts, without writing to it.
if CommandLine.arguments.contains("--focusprobe") {
    WriteSelfTest.probe()
}

// Types into whatever app the user focuses, to find out which write path that
// app actually accepts.
if let index = CommandLine.arguments.firstIndex(of: "--writetest") {
    let seconds = CommandLine.arguments.dropFirst(index + 1).first.flatMap(Double.init) ?? 8
    WriteSelfTest.run(after: seconds)
}

// Whether a newline typed into a chat app sends the message.
if let index = CommandLine.arguments.firstIndex(of: "--newlinetest") {
    let seconds = CommandLine.arguments.dropFirst(index + 1).first.flatMap(Double.init) ?? 8
    WriteSelfTest.newlineProbe(after: seconds)
}

// Measures how large a keystroke rewrite the focused app can actually receive.
// Everything else types into a text view this process owns, which never drops
// anything; the apps that do are the ones the user dictates into.
if let index = CommandLine.arguments.firstIndex(of: "--stresstest") {
    let rest = CommandLine.arguments.dropFirst(index + 1)
    let seconds = rest.first.flatMap(Double.init) ?? 8
    let characters = rest.dropFirst().first.flatMap(Int.init) ?? 400
    WriteSelfTest.stress(after: seconds, characters: characters)
}

if let index = CommandLine.arguments.firstIndex(of: "--rectest") {
    let seconds = CommandLine.arguments.dropFirst(index + 1).first.flatMap(Double.init) ?? 3
    RecordSelfTest.run(seconds: seconds)
}

// Drives the exact formatting chain the hotkey uses, on text supplied on the
// command line, so the whole post-transcription path can be checked without a
// microphone.
if let index = CommandLine.arguments.firstIndex(of: "--formattest") {
    let raw = CommandLine.arguments.dropFirst(index + 1).first ?? ""
    let started = Date()
    let final = Dictation.render(raw, leadingSpace: "", structure: true)
    let elapsed = Date().timeIntervalSince(started)
    let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("talkflow-formattest.txt")
    try? "\(String(format: "%.3f", elapsed))s\n\(final)".write(to: out, atomically: true, encoding: .utf8)
    exit(0)
}

// Guard against double-launch (e.g. the LaunchAgent's copy already running, then
// something else launches a second copy) - whichever instance starts second
// just quits immediately, before setting up any taps or audio, so there's never
// two competing hotkey listeners.
let bundleID = Bundle.main.bundleIdentifier ?? "com.samir.talkflow"
if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
    print("talkflowd: another instance is already running, exiting")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
