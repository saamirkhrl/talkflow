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
    .appendingPathComponent("Library/Logs/talkflow/talkflow.log")
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
// Read-only: renders the dashboard to PNGs for checking its layout.
if CommandLine.arguments.contains("--dashboardshot") {
    Task { @MainActor in
        for url in DashboardController.renderSnapshots() { print("talkflowd: wrote \(url.path)") }
        exit(0)
    }
    dispatchMain()
}

// Read-only: renders every setup step (fake permission states, including a
// grant left over from an older build) to PNGs, in the folder given or the
// temporary directory. Usage: --onboardingshot [folder]
if let index = CommandLine.arguments.firstIndex(of: "--onboardingshot") {
    let folder = CommandLine.arguments.dropFirst(index + 1).first.map { URL(fileURLWithPath: $0) }
        ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("talkflow-onboarding")
    Task { @MainActor in
        for url in OnboardingController.renderSnapshots(to: folder) { print("talkflowd: wrote \(url.path)") }
        exit(0)
    }
    dispatchMain()
}

// Runs the updater's install step (unpack, verify, sign, swap) on a local zip
// and a target bundle, without downloading or relaunching anything.
// Usage: --updatetest <zip> <target.app> <version>
if let index = CommandLine.arguments.firstIndex(of: "--updatetest") {
    let rest = Array(CommandLine.arguments.dropFirst(index + 1))
    guard rest.count == 3 else { exit(2) }
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("talkflow-updatetest-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let failure = Updater.installBundle(zip: URL(fileURLWithPath: rest[0]), in: work, version: rest[2], over: URL(fileURLWithPath: rest[1]))
    try? FileManager.default.removeItem(at: work)
    print("updatetest: \(failure ?? "installed")")
    exit(failure == nil ? 0 : 1)
}

if let index = CommandLine.arguments.firstIndex(of: "--formattest") {
    let raw = CommandLine.arguments.dropFirst(index + 1).first ?? ""
    let started = Date()
    let final = Dictation.render(raw, leadingSpace: "", structure: true)
    let elapsed = Date().timeIntervalSince(started)
    let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("talkflow-formattest.txt")
    try? "\(String(format: "%.3f", elapsed))s\n\(final)".write(to: out, atomically: true, encoding: .utf8)
    exit(0)
}

// Shows only the menu bar icon, with its check for a notch app's island, for
// the given seconds, logging where it sits. Best run as the bare built binary,
// whose settings are separate from the installed app's.
// Usage: --statusbartest [seconds]
if let index = CommandLine.arguments.firstIndex(of: "--statusbartest") {
    let seconds = CommandLine.arguments.dropFirst(index + 1).first.flatMap(Double.init) ?? 20
    NSApplication.shared.setActivationPolicy(.accessory)
    let bar = StatusBar()
    let started = Date()
    Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
        let frame = bar.iconFrame.map { "x \(Int($0.minX))-\(Int($0.maxX))" } ?? "no frame"
        print("statusbartest: \(Int(Date().timeIntervalSince(started)))s icon \(frame)")
        if Date().timeIntervalSince(started) >= seconds { exit(0) }
    }
    NSApplication.shared.run()
}

// Read-only: what Settings > Uninstall talkflow would do on this Mac, step by
// step, and where the kept data folder is. Changes nothing.
if CommandLine.arguments.contains("--uninstallplan") {
    for (i, step) in Uninstaller.steps().enumerated() { print("\(i + 1). \(step.title)") }
    print("Kept: \(UserData.directory.path)")
    exit(0)
}

// Read-only report of what setup would find: the whisper program, the model,
// the LaunchAgent, and whether the server answers. Changes nothing.
if CommandLine.arguments.contains("--enginecheck") {
    let alive = SpeechEngine.isRespondingBlocking()
    let agent = (try? Data(contentsOf: SpeechEngine.agentPlistURL))
        .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
    let plan = SpeechEngine.agentPlan(existing: agent, bundled: SpeechEngine.bundledServerPath) {
        FileManager.default.isExecutableFile(atPath: $0)
    }
    let report = """
    whisper-server: \(SpeechEngine.serverBinary() ?? "not found")
    bundled whisper-server: \(SpeechEngine.bundledServerPath.map { "\($0) (\(SpeechEngine.bundledServerBinary == nil ? "missing" : "present"))" } ?? "none (not running from an app bundle)")
    homebrew: \(SpeechEngine.brewBinary() ?? "not found")
    launch agent program: \((agent?["ProgramArguments"] as? [String])?.first ?? "none")
    launch agent plan: \(plan)
    model complete: \(SpeechEngine.modelIsComplete) (\(SpeechEngine.modelPath.path))
    launch agent plist: \(FileManager.default.fileExists(atPath: SpeechEngine.agentPlistURL.path))
    server responding on :\(SpeechEngine.port): \(alive)
    isInstalled: \(SpeechEngine.isInstalled)
    permissions: microphone=\(Permissions.microphone) accessibility=\(Permissions.accessibility) inputMonitoring=\(Permissions.inputMonitoring)
    needsSetup: \(Onboarding.needsSetup())

    """
    let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("talkflow-enginecheck.txt")
    try? report.write(to: out, atomically: true, encoding: .utf8)
    exit(0)
}

// Exercises the real model downloader against a small file and a temp
// destination, so the download path can be checked without fetching 490 MB.
// Usage: --downloadtest <url> <destination> <minimum bytes>
if let index = CommandLine.arguments.firstIndex(of: "--downloadtest") {
    let rest = Array(CommandLine.arguments.dropFirst(index + 1))
    guard rest.count == 3, let url = URL(string: rest[0]), let minimum = Int64(rest[2]) else { exit(2) }
    let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("talkflow-downloadtest.txt")
    let semaphore = DispatchSemaphore(value: 0)
    var lastProgress = 0.0
    let downloader = FileDownloader(
        destination: URL(fileURLWithPath: rest[1]),
        minimumBytes: minimum,
        onProgress: { lastProgress = $0 },
        onFinish: { error in
            let size = (try? FileManager.default.attributesOfItem(atPath: rest[1])[.size] as? NSNumber)??.int64Value ?? -1
            let line = "error: \(error?.localizedDescription ?? "none")\nprogress: \(lastProgress)\nfile size: \(size)\n"
            try? line.write(to: out, atomically: true, encoding: .utf8)
            semaphore.signal()
        }
    )
    downloader.start(url: url)
    semaphore.wait()
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
