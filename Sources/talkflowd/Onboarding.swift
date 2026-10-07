import AppKit
import ServiceManagement
import SwiftUI

/// First-run setup: two macOS permissions, the local speech engine, then a
/// place to try it. Shown automatically whenever something talkflow needs is
/// missing (so it also reappears if a permission is later revoked), and from
/// the menu bar at any time.
///
/// The speech engine gets ready in the background from the moment setup
/// opens, so the model download usually finishes while the user is busy
/// with the permissions and its step is skipped like a granted one.
final class OnboardingController: NSWindowController, NSWindowDelegate {
    let model: OnboardingModel

    /// `startHotkey` is called once Input Monitoring is granted and returns
    /// whether the Fn event tap is now live.
    init(startHotkey: @escaping () -> Bool) {
        model = OnboardingModel(startHotkey: startHotkey)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: OnboardingView.width, height: OnboardingView.height),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        // Follows the user to whichever Space they are on when it is brought
        // forward, instead of staying behind on the one it opened on.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: OnboardingView(model: model))
        // Only raises the window. It must not restart the flow: this runs
        // when a grant lands while the user is in System Settings, and
        // restarting here is what used to send them back to the first page.
        model.bringToFront = { [weak self] in self?.bringToFront() }
        model.close = { [weak self] in self?.window?.close() }
        // Back from System Settings (by the Dock icon, Cmd-Tab or a click):
        // setup comes forward and checks whether the grant took.
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.model.isActive else { return }
            self.window?.makeKeyAndOrderFront(nil)
            let away = self.resignedAt.map { Date().timeIntervalSince($0) } ?? 0
            self.model.appBecameActive(awayFor: away)
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.resignedAt = Date() }
    }

    private var activeObserver: NSObjectProtocol?
    private var resignObserver: NSObjectProtocol?
    private var resignedAt: Date?

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }

    /// Opens setup, or raises it if it is already open. A setup already in
    /// progress keeps its step.
    func show() {
        model.begin()
        bringToFront()
    }

    /// talkflow is a menu bar app with no Dock icon, so once System Settings
    /// covered this window there was no way back to it but Mission Control.
    /// While setup is open it is a regular app: Dock icon, Cmd-Tab, and
    /// clicking the icon brings setup back (AppDelegate's reopen handler).
    private func bringToFront() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        model.stop()
        NSApp.setActivationPolicy(.accessory)
    }
}

enum Onboarding {
    static let completedKey = "onboardingCompleted"
    /// The step a first-run setup had reached, so a relaunch in the middle of
    /// it (System Settings' "Quit & Reopen", or Restart talkflow) resumes
    /// there instead of on the welcome page. Removed when setup finishes.
    static let progressKey = "onboardingProgress"

    /// Whether to open the setup window on launch: only when something is
    /// actually missing. A Mac that already has every permission and a working
    /// speech engine never sees it.
    static func needsSetup() -> Bool {
        opensOnLaunch(allGranted: Permissions.allGranted, engineInstalled: SpeechEngine.isInstalled, interrupted: false, forced: false)
    }

    /// Whether launch opens setup. Pure, for `--streamtest`: after an update
    /// whose grants still apply, nothing opens.
    static func opensOnLaunch(allGranted: Bool, engineInstalled: Bool, interrupted: Bool, forced: Bool) -> Bool {
        forced || interrupted || !allGranted || !engineInstalled
    }

    /// What setup says when a permission looks stale: why it happens, and how
    /// to fix it by hand if the Reset button is not wanted.
    static func staleHelp(_ service: Permissions.Service, _ reason: StaleReason) -> (why: String, fix: String) {
        let why: String
        switch reason {
        case .appChanged:
            why = "talkflow was updated since you allowed this. macOS ties the permission to the exact copy it was given to, so System Settings can show talkflow switched on while this copy is not allowed."
        case .userSaysOn, .backFromSettings:
            why = "If talkflow is already switched on in System Settings and this still waits, macOS is holding the permission for an older copy of talkflow, from before an update."
                + (service == .inputMonitoring
                   ? " Just switched it on? Input Monitoring can need talkflow to restart before it applies, so try Restart talkflow first."
                   : "")
        }
        let byHand: String
        switch service {
        case .microphone:
            byHand = "Or by hand: in System Settings > Privacy & Security > Microphone, switch talkflow off and on again."
        case .accessibility, .inputMonitoring:
            let list = service == .accessibility ? "Accessibility" : "Input Monitoring"
            byHand = "Or by hand: in System Settings > Privacy & Security > \(list), select talkflow, remove it with the - button, add it again with + and switch it on."
        }
        return (why, "Reset and allow again removes talkflow's old entry so macOS asks again. " + byHand)
    }

    /// Exactly where the switch is and what to do with it, for the few
    /// seconds the user spends in System Settings.
    static func switchOn(_ service: Permissions.Service, appName: String) -> (place: String, action: String) {
        let list: String
        switch service {
        case .microphone: list = "Microphone"
        case .accessibility: list = "Accessibility"
        case .inputMonitoring: list = "Input Monitoring"
        }
        return ("System Settings > Privacy & Security > \(list)", "Switch on \(appName)")
    }

    /// A first-run setup was interrupted part way (most often by macOS
    /// relaunching talkflow after a grant), so it opens again where it was.
    static func wasInterrupted(defaults: UserDefaults = .standard) -> Bool {
        guard !defaults.bool(forKey: completedKey),
              let saved = OnboardingStep(rawValue: defaults.integer(forKey: progressKey)) else { return false }
        return saved != .welcome && saved != .ready
    }
}

// MARK: - Model

enum OnboardingStep: Int, CaseIterable {
    case welcome, microphone, accessibility, inputMonitoring, engine, ready

    var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
    var previous: OnboardingStep? { OnboardingStep(rawValue: rawValue - 1) }
}

/// The three permissions as plain values, so the step logic below can be
/// checked by `--streamtest` without touching the real ones.
struct PermissionGrants: Equatable {
    var microphone: Bool
    var accessibility: Bool
    var inputMonitoring: Bool

    /// Whether the permission a step asks for is granted; nil for the steps
    /// that are not about a permission.
    func isGranted(_ step: OnboardingStep) -> Bool? {
        switch step {
        case .microphone: return microphone
        case .accessibility: return accessibility
        case .inputMonitoring: return inputMonitoring
        case .welcome, .engine, .ready: return nil
        }
    }
}

/// Which step setup shows. Pure, for `--streamtest`.
enum OnboardingFlow {
    /// The first permission step still missing, then the engine.
    static func firstMissing(_ grants: PermissionGrants, engineInstalled: Bool) -> OnboardingStep? {
        if !grants.microphone { return .microphone }
        if !grants.accessibility { return .accessibility }
        if !grants.inputMonitoring { return .inputMonitoring }
        if !engineInstalled { return .engine }
        return nil
    }

    /// Nothing to do on this step: its permission is granted, or it is the
    /// engine and the engine is already answering.
    static func isDone(_ step: OnboardingStep, grants: PermissionGrants, engineReady: Bool) -> Bool {
        if let granted = grants.isGranted(step) { return granted }
        return step == .engine && engineReady
    }

    /// The step after `step`, skipping the ones that are already done.
    static func nextNeeded(after step: OnboardingStep, grants: PermissionGrants, engineReady: Bool = false) -> OnboardingStep {
        var candidate = step.next ?? .ready
        while isDone(candidate, grants: grants, engineReady: engineReady), let next = candidate.next { candidate = next }
        return candidate
    }

    /// Where Back goes: the closest earlier step that still has something to
    /// do, or the welcome page on a first run. Nil hides Back. Input
    /// Monitoring is only ever a step after Accessibility is granted (that
    /// grant usually covers it), so Back never lands on it before then.
    static func previousShown(before step: OnboardingStep, grants: PermissionGrants, engineReady: Bool, returning: Bool) -> OnboardingStep? {
        var candidate = step.previous
        while let shown = candidate {
            if shown == .welcome { return returning ? nil : .welcome }
            let skipped = isDone(shown, grants: grants, engineReady: engineReady)
                || (shown == .inputMonitoring && !grants.accessibility)
            if !skipped { return shown }
            candidate = shown.previous
        }
        return nil
    }

    /// Where setup opens when it was not already open. A finished setup goes
    /// to whatever is missing, or to the last page (with the practice field)
    /// when nothing is, never through the whole flow again. A first run
    /// starts on the welcome page, or,
    /// when it was interrupted (`saved`), where it was, moved past a
    /// permission that has since been granted and back to an earlier one that
    /// has since been lost.
    static func initialStep(completed: Bool, saved: OnboardingStep?, grants: PermissionGrants, engineInstalled: Bool) -> OnboardingStep {
        let missing = firstMissing(grants, engineInstalled: engineInstalled)
        if completed { return missing ?? .ready }
        guard let saved, saved != .welcome else { return .welcome }
        var resumed = saved
        if grants.isGranted(saved) == true { resumed = nextNeeded(after: saved, grants: grants) }
        if let missing, missing.rawValue < resumed.rawValue { return missing }
        return resumed
    }

    /// How a step shows in the progress bar.
    enum Mark: Equatable {
        case done, current, attention, pending
    }

    /// A stale permission always asks for attention, even when it is not
    /// the step on screen; otherwise the current step, then what is done.
    static func mark(_ shown: OnboardingStep, current: OnboardingStep, status: GrantStatus?, engineDone: Bool) -> Mark {
        if status?.isStale == true { return .attention }
        if shown == current { return .current }
        if let status { return status == .granted ? .done : .pending }
        if shown == .engine { return engineDone ? .done : .pending }
        return shown.rawValue < current.rawValue ? .done : .pending
    }

    /// The step after a permission re-read. Setup moves on by itself only
    /// when the permission the current step asks for has just been granted;
    /// anything else, including the window simply coming back to the front,
    /// leaves the step alone (so Back to a granted step stays there).
    static func stepAfterRefresh(current: OnboardingStep, before: PermissionGrants, now: PermissionGrants, engineReady: Bool = false) -> OnboardingStep {
        guard before.isGranted(current) == false, now.isGranted(current) == true else { return current }
        return nextNeeded(after: current, grants: now, engineReady: engineReady)
    }

    /// The step once the engine has finished getting ready: on its own step,
    /// setup moves on by itself, as it does when a grant lands. Anywhere
    /// else the step stays (the engine step is simply skipped later).
    static func stepAfterEngine(current: OnboardingStep, ready: Bool, grants: PermissionGrants) -> OnboardingStep {
        guard current == .engine, ready else { return current }
        return nextNeeded(after: .engine, grants: grants, engineReady: true)
    }

    /// After the engine check: start getting it ready without a click when
    /// it is not answering and its program is here (the download and start
    /// need nothing from the user). Without the program it waits for a
    /// click, since getting one means installing something.
    static func startsEngineByItself(responding: Bool, programPresent: Bool) -> Bool {
        !responding && programPresent
    }
}

/// How long step and progress changes animate. None at all with Reduce
/// Motion on. Pure, for `--streamtest`.
enum OnboardingMotion {
    static func duration(reduceMotion: Bool) -> Double { reduceMotion ? 0 : 0.2 }

    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: duration(reduceMotion: false))
    }
}

/// An honest "time left" for the model download, from how fast it has
/// actually gone over the last few seconds. Pure, for `--streamtest`.
struct DownloadEstimate {
    /// Seconds of history the speed is measured over.
    static let window: TimeInterval = 20
    /// No estimate until the speed has been measured for this long.
    static let minimumSpan: TimeInterval = 3

    private var samples: [(time: TimeInterval, fraction: Double)] = []

    mutating func add(_ fraction: Double, at time: TimeInterval) {
        // Started over (a retry without resume data): so does the speed.
        if let last = samples.last, fraction < last.fraction { samples.removeAll() }
        samples.append((time, fraction))
        while samples.count > 2, let first = samples.first, time - first.time > Self.window { samples.removeFirst() }
    }

    /// Seconds left, or nil while there is not enough to go on.
    func secondsLeft() -> TimeInterval? {
        guard let first = samples.first, let last = samples.last, last.time - first.time >= Self.minimumSpan else { return nil }
        let rate = (last.fraction - first.fraction) / (last.time - first.time)
        guard rate > 0 else { return nil }
        return max(0, 1 - last.fraction) / rate
    }

    /// In words, rounded the way people say it.
    static func describe(_ seconds: TimeInterval?) -> String? {
        guard let seconds else { return nil }
        if seconds < 50 { return "Less than a minute left" }
        if seconds < 90 { return "About a minute left" }
        if seconds < 3600 { return "About \(Int((seconds / 60).rounded())) minutes left" }
        return "Over an hour left"
    }
}

/// The last page: what it shows while the user tries Fn in the practice
/// field. Pure, for `--streamtest`.
enum TryIt {
    enum Phase: Equatable {
        /// macOS needs a relaunch before the Fn key can be heard.
        case restart
        /// The Fn listener is not running yet.
        case starting
        /// Ready, nothing tried yet.
        case waiting
        /// Fn is held.
        case listening
        /// Fn was let go; the words are on their way.
        case writing
        /// Words arrived in the field.
        case success
        /// Fn was used but nothing arrived.
        case nothingArrived
        /// Nothing tried for a while: a gentle pointer.
        case hint
    }

    /// Nothing tried for this long shows the hint.
    static let hintAfter: TimeInterval = 20
    /// Let go this long ago with nothing in the field: say so.
    static let nothingAfter: TimeInterval = 8

    /// Whether dictated words have arrived in the field since Fn went down
    /// (`baseline` is the field then; nil when Fn has not been pressed).
    static func arrived(baseline: String?, practice: String) -> Bool {
        guard let baseline else { return false }
        let now = practice.trimmingCharacters(in: .whitespacesAndNewlines)
        let before = baseline.trimmingCharacters(in: .whitespacesAndNewlines)
        return !now.isEmpty && now != before && now.count > before.count
    }

    static func phase(needsRestart: Bool, hotkeyRunning: Bool, fnDown: Bool, succeeded: Bool,
                      pressedFn: Bool, sinceRelease: TimeInterval?, sinceShown: TimeInterval) -> Phase {
        if needsRestart { return .restart }
        if !hotkeyRunning { return .starting }
        if fnDown { return .listening }
        if succeeded { return .success }
        if pressedFn {
            if let sinceRelease, sinceRelease >= nothingAfter { return .nothingArrived }
            return .writing
        }
        return sinceShown >= hintAfter ? .hint : .waiting
    }
}

/// Where the model reads the permissions, the engine and its saved progress,
/// and how it asks for and resets permissions. `--streamtest` passes fakes
/// (so it never raises a real prompt, touches a real grant or downloads
/// anything); the app uses `live`.
struct OnboardingEnvironment {
    var microphone: () -> Permissions.MicrophoneStatus
    var accessibility: () -> Bool
    var inputMonitoring: () -> Bool
    var engineInstalled: () -> Bool
    var defaults: UserDefaults
    /// How long the "Allowed" check shows before setup moves on.
    var advanceDelay: TimeInterval
    /// This build's designated requirement (see Permissions).
    var designatedRequirement: String?
    /// Whether macOS has already shown its own prompt for the permission.
    var asked: (Permissions.Service) -> Bool
    /// Shows macOS's prompt; calls back when it is answered or shown.
    var request: (Permissions.Service, @escaping () -> Void) -> Void
    var openSettings: (Permissions.Pane) -> Void
    /// `tccutil reset <service> <this bundle id>`; calls back with success.
    var resetGrant: (Permissions.Service, @escaping (Bool) -> Void) -> Void
    /// How long after coming back from System Settings a grant still not
    /// applying counts as stale.
    var staleGrace: TimeInterval
    /// macOS's "Press the globe key to" setting is not "Do Nothing".
    var fnKeyHasSystemAction: () -> Bool
    /// Whether the engine answers; calls back on the main thread.
    var engineResponding: (@escaping (Bool) -> Void) -> Void
    /// Whether the whisper-server program is on this Mac.
    var engineProgramPresent: () -> Bool
    /// Downloads what is missing and starts the engine, calling back on the
    /// main thread as it goes. The last call is a finished state.
    var setUpEngine: (@escaping (EngineState) -> Void) -> Void
    /// System Settings > Accessibility > Display > Reduce motion.
    var reduceMotion: () -> Bool
    /// The name System Settings lists this copy under.
    var appName: String

    static let live = OnboardingEnvironment(
        microphone: { Permissions.microphone },
        accessibility: { Permissions.accessibility },
        inputMonitoring: { Permissions.inputMonitoring },
        engineInstalled: { SpeechEngine.isInstalled },
        defaults: .standard,
        advanceDelay: 0.7,
        designatedRequirement: Permissions.designatedRequirement,
        asked: { service in
            switch service {
            case .microphone: return Permissions.microphone != .notDetermined
            case .accessibility: return UserDefaults.standard.bool(forKey: OnboardingModel.askedKey(.accessibility))
            case .inputMonitoring: return Permissions.inputMonitoringAsked
            }
        },
        request: { service, done in
            switch service {
            case .microphone: Permissions.requestMicrophone(completion: done)
            case .accessibility: Permissions.requestAccessibility(); done()
            case .inputMonitoring: Permissions.requestInputMonitoring(); done()
            }
        },
        openSettings: { Permissions.openSettings($0) },
        resetGrant: { Permissions.resetGrant($0, completion: $1) },
        staleGrace: 1.5,
        fnKeyHasSystemAction: { Permissions.fnKeyHasSystemAction },
        engineResponding: { done in SpeechEngine.isResponding { alive in DispatchQueue.main.async { done(alive) } } },
        engineProgramPresent: { SpeechEngine.serverBinary() != nil },
        setUpEngine: { EngineSetup.run(report: $0) },
        reduceMotion: { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
        appName: {
            let info = Bundle.main.infoDictionary
            let name = (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String) ?? ""
            // A bare `.build` binary has no bundle name worth showing.
            return name.isEmpty || name == "talkflowd" ? "talkflow" : name
        }()
    )
}

/// The few UserDefaults calls setup makes, answered from a dictionary, for
/// `--streamtest` and `--onboardingshot` (a real defaults suite would leave
/// a file in ~/Library/Preferences behind).
final class EphemeralDefaults: UserDefaults {
    private var store: [String: Any] = [:]

    override func object(forKey key: String) -> Any? { store[key] }
    override func set(_ value: Any?, forKey key: String) { store[key] = value }
    override func set(_ value: Bool, forKey key: String) { store[key] = value }
    override func set(_ value: Int, forKey key: String) { store[key] = value }
    override func removeObject(forKey key: String) { store[key] = nil }
    override func bool(forKey key: String) -> Bool { store[key] as? Bool ?? false }
    override func integer(forKey key: String) -> Int { store[key] as? Int ?? 0 }
    override func string(forKey key: String) -> String? { store[key] as? String }
}

enum EngineState: Equatable {
    case checking
    case ready
    case needsSetup
    case working(String, Double?)
    case needsHomebrew
    case failed(String)

    /// A state the engine work ends in (the rest are on the way).
    var isFinished: Bool {
        switch self {
        case .ready, .needsSetup, .needsHomebrew, .failed: return true
        case .checking, .working: return false
        }
    }
}

/// The real engine work behind `OnboardingEnvironment.live.setUpEngine`:
/// the program (Homebrew, only for a build without one), the model, then the
/// LaunchAgent. Runs on a background queue; reports on the main thread.
enum EngineSetup {
    static let downloadingMessage = "Downloading the speech model"
    /// How a failed download's message starts (setup then says it resumes).
    static let downloadStopped = "The download stopped"
    /// The model's size, for "x of y MB" (487,614,201 bytes).
    static let modelMegabytes = 488.0
    /// How many times a dropped connection is picked up again by itself
    /// before setup asks the user to press Try again.
    static let attempts = 3

    /// Where a stopped download had got to, so the next attempt (or Try
    /// again) continues it instead of starting over. Only touched by the one
    /// job that runs at a time.
    private static var resumeData: Data?

    static func run(report: @escaping (EngineState) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            func post(_ state: EngineState) { DispatchQueue.main.async { report(state) } }

            // 1. The whisper-server program.
            if SpeechEngine.serverBinary() == nil {
                guard SpeechEngine.brewBinary() != nil else {
                    post(.needsHomebrew)
                    return
                }
                post(.working("Installing the Whisper program with Homebrew. This can take a few minutes.", nil))
                let result = SpeechEngine.installWhisperCpp { line in
                    post(.working("Installing the Whisper program with Homebrew...\n\(line)", nil))
                }
                guard result.succeeded, SpeechEngine.serverBinary() != nil else {
                    post(.failed("Homebrew could not install it.\n\(result.tail)"))
                    return
                }
            }

            // 2. The model.
            if !SpeechEngine.modelIsComplete, let failure = downloadModel(post) {
                post(.failed(failure))
                return
            }

            // 3. Start it, and wait for the model to load.
            post(.working("Starting the speech engine...", nil))
            do { try SpeechEngine.startServer() } catch {
                post(.failed(error.localizedDescription))
                return
            }
            if SpeechEngine.waitUntilResponding(timeout: 90) {
                post(.ready)
            } else {
                post(.failed("The engine did not start. Its log is at ~/Library/Logs/TalkFlow/whisper-server.log"))
            }
        }
    }

    /// Blocking. Nil when the model is in place, otherwise what went wrong.
    /// A dropped connection is resumed a couple of times by itself.
    private static func downloadModel(_ post: @escaping (EngineState) -> Void) -> String? {
        var fraction = 0.0
        for attempt in 1...attempts {
            post(.working(downloadingMessage, fraction))
            let semaphore = DispatchSemaphore(value: 0)
            var failure: Error?
            var posted = fraction
            let downloader = FileDownloader(
                destination: SpeechEngine.modelPath,
                minimumBytes: SpeechEngine.minimumModelBytes,
                onProgress: { progress in
                    fraction = progress
                    // Progress arrives per network chunk; the window needs
                    // it about every half megabyte.
                    guard abs(progress - posted) >= 0.001 || progress >= 1 else { return }
                    posted = progress
                    post(.working(downloadingMessage, progress))
                },
                onFinish: { error in
                    failure = error
                    semaphore.signal()
                }
            )
            downloader.start(url: SpeechEngine.modelDownloadURL, resumeData: resumeData)
            semaphore.wait()
            resumeData = downloader.resumeData
            guard let failure else {
                resumeData = nil
                return nil
            }
            print("talkflowd: model download attempt \(attempt) failed: \(failure.localizedDescription)")
            // Only a dropped connection is worth another go by itself; a bad
            // answer from the server would fail the same way again.
            guard attempt < attempts, failure is URLError else {
                return "\(downloadStopped): \(failure.localizedDescription)"
            }
            post(.working("The connection dropped. Trying again...", fraction))
            Thread.sleep(forTimeInterval: 3)
        }
        return downloadStopped + "."
    }
}

final class OnboardingModel: ObservableObject {
    @Published var step: OnboardingStep = .welcome {
        didSet {
            saveProgress()
            if step == .ready && oldValue != .ready { resetTryIt() }
        }
    }
    @Published var microphone: Permissions.MicrophoneStatus
    @Published var accessibility: Bool
    @Published var inputMonitoring: Bool
    @Published var engine: EngineState = .checking
    @Published var hotkeyRunning = false
    @Published var needsRestart = false
    @Published var launchAtLogin = true
    @Published var practice = "" {
        didSet { checkTryIt() }
    }
    /// Permissions the user says are switched on in System Settings although
    /// this copy is not trusted.
    @Published var userSaysOn: Set<Permissions.Service> = []
    /// Permissions the user went to System Settings for and came back
    /// without them applying.
    @Published var backFromSettings: Set<Permissions.Service> = []
    /// The permission being reset with tccutil, while it runs.
    @Published var resetting: Permissions.Service?
    /// The permission whose reset failed, to say so.
    @Published var resetFailed: Permissions.Service?

    // The Try it page.
    /// Fn is held right now.
    @Published private(set) var fnDown = false
    /// The practice field when Fn last went down; nil until it has.
    @Published private(set) var tryItBaseline: String?
    @Published private(set) var tryItReleasedAt: Date?
    @Published private(set) var tryItShownAt = Date()
    /// Dictated words arrived. Stays true for the visit.
    @Published private(set) var tryItSucceeded = false

    var bringToFront: () -> Void = {}
    var close: () -> Void = {}

    private let startHotkey: () -> Bool
    private let environment: OnboardingEnvironment
    private let history: PermissionHistory
    /// Permissions the user was sent to System Settings (or a prompt) for.
    @Published private(set) var settingsVisits: Set<Permissions.Service> = []
    private var timer: Timer?
    private var hotkeyAttempts = 0
    /// A check of the engine or the engine setup is under way. Never two at
    /// once, whatever starts them (setup opening, its step, a button).
    private(set) var engineBusy = false
    /// How many times the engine setup itself was started, for `--streamtest`.
    private(set) var engineSetupRuns = 0
    private var estimate = DownloadEstimate()

    /// A build made for testing setup alongside a working install must not
    /// register itself as a login item.
    let loginItemAvailable: Bool =
        (Bundle.main.object(forInfoDictionaryKey: "TalkflowDisableLoginItem") as? Bool) != true

    init(startHotkey: @escaping () -> Bool, environment: OnboardingEnvironment = .live) {
        self.startHotkey = startHotkey
        self.environment = environment
        history = PermissionHistory(defaults: environment.defaults)
        microphone = environment.microphone()
        accessibility = environment.accessibility()
        inputMonitoring = environment.inputMonitoring()
    }

    var grants: PermissionGrants {
        PermissionGrants(microphone: microphone == .granted, accessibility: accessibility, inputMonitoring: inputMonitoring)
    }

    static func askedKey(_ service: Permissions.Service) -> String { "asked.\(service.rawValue)" }

    var engineInstalled: Bool { environment.engineInstalled() }
    var fnKeyHasSystemAction: Bool { environment.fnKeyHasSystemAction() }
    var reduceMotion: Bool { environment.reduceMotion() }
    var appName: String { environment.appName }

    /// Someone who has been through setup before (or granted talkflow
    /// anything): no welcome page for them.
    var isReturning: Bool {
        environment.defaults.bool(forKey: Onboarding.completedKey) || !history.isEmpty
    }

    /// The user has been sent to System Settings (or macOS's prompt) for
    /// this permission and it has not landed yet.
    func isWaiting(_ service: Permissions.Service) -> Bool {
        settingsVisits.contains(service) && !trusted(service)
    }

    /// How a step shows in the progress bar.
    func mark(_ shown: OnboardingStep) -> OnboardingFlow.Mark {
        let service: Permissions.Service?
        switch shown {
        case .microphone: service = .microphone
        case .accessibility: service = .accessibility
        case .inputMonitoring: service = .inputMonitoring
        case .welcome, .engine, .ready: service = nil
        }
        return OnboardingFlow.mark(
            shown, current: step,
            status: service.map(status),
            engineDone: engine == .ready || (step != .engine && !engineBusy && engineInstalled))
    }

    private func trusted(_ service: Permissions.Service) -> Bool {
        switch service {
        case .microphone: return microphone == .granted
        case .accessibility: return accessibility
        case .inputMonitoring: return inputMonitoring
        }
    }

    /// Granted, missing, or granted to an older copy of talkflow (stale).
    func status(_ service: Permissions.Service) -> GrantStatus {
        // A microphone macOS has not asked about yet just needs asking: the
        // prompt itself records this copy.
        if service == .microphone && microphone == .notDetermined { return .missing }
        return GrantStatus.classify(
            trusted: trusted(service),
            grantedTo: history.grantedTo(service),
            current: environment.designatedRequirement,
            userSaysOn: userSaysOn.contains(service),
            backFromSettings: backFromSettings.contains(service))
    }

    /// Whether setup is open (between `begin` and `stop`).
    var isActive: Bool { timer != nil }

    /// Starts a setup session. While one is running this does nothing, so
    /// showing the window again (from the menu bar, or when a grant brings
    /// it forward) never moves the user off the step they are on.
    func begin() {
        guard !isActive else { return }
        refresh(announce: false)
        let defaults = environment.defaults
        let saved = defaults.object(forKey: Onboarding.progressKey) == nil
            ? nil : OnboardingStep(rawValue: defaults.integer(forKey: Onboarding.progressKey))
        // A Mac that has granted talkflow anything before has been through
        // setup (closing the window counts), so after an update it goes
        // straight to whatever needs attention, not the welcome page.
        move(to: OnboardingFlow.initialStep(
            completed: isReturning,
            saved: saved,
            grants: grants,
            engineInstalled: environment.engineInstalled()))
        let timer = Timer(timeInterval: 0.8, repeats: true) { [weak self] _ in self?.refresh(announce: true) }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // The model download is the slow part, so it starts now and runs
        // while the user deals with the permissions.
        startEngineIfNeeded()
    }

    /// Closing setup does not stop the engine work: the download carries on
    /// and the engine starts when it is done, so it is ready next time.
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func move(to newStep: OnboardingStep) {
        if step != newStep { step = newStep }
        if newStep == .engine && engine == .checking { startEngineIfNeeded() }
    }

    /// Moves from `current` to `target`, after the moment the check shows,
    /// unless the user has moved on (or back) in the meantime.
    private func advance(from current: OnboardingStep, to target: OnboardingStep) {
        guard target != current else { return }
        if environment.advanceDelay <= 0 {
            move(to: target)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + environment.advanceDelay) { [weak self] in
            guard let self, self.step == current else { return }
            self.move(to: target)
        }
    }

    /// Only during a first run: a finished setup always reopens on what is
    /// missing. Reaching the last page finishes it, whether or not the user
    /// then presses the button or closes the window.
    private func saveProgress() {
        let defaults = environment.defaults
        if step == .ready {
            defaults.set(true, forKey: Onboarding.completedKey)
            defaults.removeObject(forKey: Onboarding.progressKey)
            return
        }
        guard !defaults.bool(forKey: Onboarding.completedKey) else { return }
        defaults.set(step.rawValue, forKey: Onboarding.progressKey)
    }

    /// Re-reads the permission state. macOS gives no callback when the user flips
    /// a switch in System Settings, so this polls; when something becomes granted
    /// the window comes forward again, because the user is looking at Settings,
    /// and when it is the permission this step asks for, setup moves on to the
    /// next step by itself after showing the check for a moment.
    func refresh(announce: Bool) {
        let before = grants
        let mic = environment.microphone()
        let ax = environment.accessibility()
        let im = environment.inputMonitoring()
        let gained = (mic == .granted && microphone != .granted)
            || (ax && !accessibility)
            || (im && !inputMonitoring)
        microphone = mic
        accessibility = ax
        inputMonitoring = im
        if gained && announce { bringToFront() }

        for service in Permissions.Service.allCases where trusted(service) {
            history.record(service, granted: true, requirement: environment.designatedRequirement)
            if userSaysOn.contains(service) { userSaysOn.remove(service) }
            if backFromSettings.contains(service) { backFromSettings.remove(service) }
            settingsVisits.remove(service)
        }

        let current = step
        advance(from: current, to: OnboardingFlow.stepAfterRefresh(
            current: current, before: before, now: grants, engineReady: engine == .ready))

        if im && !hotkeyRunning {
            hotkeyRunning = startHotkey()
            if !hotkeyRunning {
                // Input Monitoring is granted but the tap still will not create:
                // macOS applies the grant to a fresh process. Offer a restart
                // rather than letting the user hold Fn at nothing.
                hotkeyAttempts += 1
                if hotkeyAttempts >= 4 { needsRestart = true }
            }
        }
        if hotkeyRunning { needsRestart = false }
    }

    // MARK: Navigation

    var canContinue: Bool {
        switch step {
        case .welcome: return true
        case .microphone: return microphone == .granted
        case .accessibility: return accessibility
        case .inputMonitoring: return inputMonitoring
        case .engine: return engine == .ready
        case .ready: return true
        }
    }

    /// Forward, past anything already done.
    func goNext() {
        guard canContinue, step != .ready else { return }
        move(to: OnboardingFlow.nextNeeded(after: step, grants: grants, engineReady: engine == .ready))
    }

    /// Where Back goes; nil when there is nowhere useful to go.
    var previousStep: OnboardingStep? {
        OnboardingFlow.previousShown(before: step, grants: grants, engineReady: engine == .ready, returning: isReturning)
    }

    func goBack() {
        guard let previousStep else { return }
        step = previousStep
    }

    func finish() {
        environment.defaults.set(true, forKey: Onboarding.completedKey)
        environment.defaults.removeObject(forKey: Onboarding.progressKey)
        if loginItemAvailable { applyLoginItem() }
        close()
    }

    private func applyLoginItem() {
        let service = SMAppService.mainApp
        do {
            if launchAtLogin {
                if service.status != .enabled { try service.register() }
            } else if service.status == .enabled {
                try service.unregister()
            }
        } catch {
            print("talkflowd: login item change failed: \(error.localizedDescription)")
        }
    }

    // MARK: Permissions

    /// The step's main button. macOS shows its own prompt only the first
    /// time it is asked; after that the same click opens the System
    /// Settings pane, so pressing Allow always does something visible.
    func allow(_ service: Permissions.Service) {
        guard !trusted(service) else { return }
        settingsVisits.insert(service)
        if service == .microphone {
            if microphone == .notDetermined {
                environment.request(.microphone) { [weak self] in self?.refresh(announce: true) }
            } else {
                environment.openSettings(.microphone)
            }
            return
        }
        let askedBefore = environment.asked(service)
        environment.request(service) {}
        environment.defaults.set(true, forKey: Self.askedKey(service))
        if askedBefore { environment.openSettings(service.pane) }
    }

    func openSettings(_ service: Permissions.Service) {
        settingsVisits.insert(service)
        environment.openSettings(service.pane)
    }

    /// "It is already on in System Settings": the user is telling us the
    /// grant is stale, so the fix shows straight away.
    func reportAlreadyOn(_ service: Permissions.Service) {
        refresh(announce: false)
        guard !trusted(service) else { return }
        userSaysOn.insert(service)
    }

    /// Shorter than this away from talkflow is a focus flicker (macOS's own
    /// prompt, a stray click), not a visit to System Settings.
    static let minimumAway: TimeInterval = 3

    /// Back in talkflow: a permission the user went to System Settings for
    /// that still does not apply after a moment is treated as stale.
    func appBecameActive(awayFor away: TimeInterval) {
        refresh(announce: false)
        let pending = settingsVisits.filter { !trusted($0) }
        guard !pending.isEmpty, away >= Self.minimumAway else { return }
        let mark = { [weak self] in
            guard let self else { return }
            self.refresh(announce: false)
            for service in pending where !self.trusted(service) { self.backFromSettings.insert(service) }
        }
        if environment.staleGrace <= 0 {
            mark()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + environment.staleGrace, execute: mark)
        }
    }

    /// Removes talkflow's old entry for this permission (its own bundle id
    /// only) and asks again, so macOS records this copy.
    func resetAndAskAgain(_ service: Permissions.Service) {
        guard resetting == nil else { return }
        resetting = service
        resetFailed = nil
        environment.resetGrant(service) { [weak self] succeeded in
            guard let self else { return }
            self.resetting = nil
            guard succeeded else {
                self.resetFailed = service
                return
            }
            self.history.forget(service)
            self.userSaysOn.remove(service)
            self.backFromSettings.remove(service)
            self.environment.defaults.removeObject(forKey: Self.askedKey(service))
            self.refresh(announce: false)
            self.settingsVisits.insert(service)
            // The entry is gone, so macOS's own prompt appears again and
            // offers to open System Settings.
            self.environment.request(service) { [weak self] in self?.refresh(announce: true) }
        }
    }

    func restartApp() {
        let path = Bundle.main.bundlePath
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$0\"", path]
        try? relaunch.run()
        NSApp.terminate(nil)
    }

    // MARK: Speech engine

    /// Gets the engine ready without a click: checks whether it answers,
    /// and if not, downloads what is missing and starts it. Does nothing
    /// while a check or setup is already under way, or once it is ready.
    func startEngineIfNeeded() {
        guard !engineBusy, engine != .ready else { return }
        engineBusy = true
        if !(engine.isWorking) { engine = .checking }
        environment.engineResponding { [weak self] alive in
            guard let self else { return }
            self.engineBusy = false
            if alive {
                self.engineChanged(.ready)
            } else if OnboardingFlow.startsEngineByItself(responding: alive, programPresent: self.environment.engineProgramPresent()) {
                self.runEngineSetup()
            } else {
                self.engine = .needsSetup
            }
        }
    }

    /// The engine step's button (and Try again). Never runs twice at once.
    func runEngineSetup() {
        guard !engineBusy else { return }
        engineBusy = true
        engineSetupRuns += 1
        estimate = DownloadEstimate()
        engine = .working("Getting ready...", nil)
        environment.setUpEngine { [weak self] state in self?.engineChanged(state) }
    }

    /// Every engine update lands here, on the main thread.
    func engineChanged(_ state: EngineState, at time: TimeInterval = Date().timeIntervalSinceReferenceDate) {
        engine = state
        if case .working(_, let fraction?) = state { estimate.add(fraction, at: time) }
        guard state.isFinished else { return }
        engineBusy = false
        let current = step
        advance(from: current, to: OnboardingFlow.stepAfterEngine(current: current, ready: state == .ready, grants: grants))
    }

    /// How far the model download is, while it runs.
    var engineFraction: Double? {
        if case .working(_, let fraction?) = engine { return fraction }
        return nil
    }

    /// "About 2 minutes left", once the speed is known.
    var downloadTimeLeft: String? { DownloadEstimate.describe(estimate.secondsLeft()) }

    /// Everything is downloaded; the engine just is not answering.
    var engineOnlyStopped: Bool {
        SpeechEngine.serverBinary() != nil && SpeechEngine.modelIsComplete
    }

    /// What is still missing, for the button and the description.
    var engineNeeds: String {
        var parts: [String] = []
        if SpeechEngine.serverBinary() == nil { parts.append("the Whisper program") }
        if !SpeechEngine.modelIsComplete { parts.append("the English speech model (about 490 MB)") }
        if parts.isEmpty { return "The speech engine is installed but not running." }
        return "Still needed: " + parts.joined(separator: " and ") + "."
    }

    // MARK: Try it

    /// The Fn key went down or up (from the hotkey monitor).
    func fnChanged(down: Bool) {
        guard down != fnDown else { return }
        fnDown = down
        if down {
            tryItBaseline = practice
            tryItReleasedAt = nil
        } else {
            tryItReleasedAt = Date()
        }
        checkTryIt()
    }

    func tryItPhase(at date: Date) -> TryIt.Phase {
        TryIt.phase(
            needsRestart: needsRestart, hotkeyRunning: hotkeyRunning, fnDown: fnDown,
            succeeded: tryItSucceeded, pressedFn: tryItBaseline != nil,
            sinceRelease: tryItReleasedAt.map { date.timeIntervalSince($0) },
            sinceShown: date.timeIntervalSince(tryItShownAt))
    }

    private func checkTryIt() {
        guard step == .ready, !tryItSucceeded, TryIt.arrived(baseline: tryItBaseline, practice: practice) else { return }
        tryItSucceeded = true
    }

    private func resetTryIt() {
        tryItShownAt = Date()
        tryItBaseline = fnDown ? practice : nil
        tryItReleasedAt = nil
        tryItSucceeded = false
    }

    /// For `--onboardingshot`: a Try it page as it looks a while in.
    func pretendTryIt(fnDown: Bool = false, pressedAgo: TimeInterval? = nil, shownAgo: TimeInterval = 0, succeeded: Bool = false) {
        self.fnDown = fnDown
        tryItShownAt = Date().addingTimeInterval(-shownAgo)
        tryItBaseline = pressedAgo == nil && !fnDown ? nil : ""
        tryItReleasedAt = pressedAgo.map { Date().addingTimeInterval(-$0) }
        tryItSucceeded = succeeded
    }
}

private extension EngineState {
    var isWorking: Bool { if case .working = self { return true } else { return false } }
}

// MARK: - View

private extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }

    // The dashboard's palette.
    static let paper = Color(light: 0xF5F5F3, dark: 0x1F1E22)
    static let ink = Color(light: 0x1F1E22, dark: 0xF5F5F3)
    static let graphite = Color(light: 0x5F5E66, dark: 0xA9A8AF)
    static let line = Color.ink.opacity(0.12)
    static let wash = Color.ink.opacity(0.035)
    static let good = Color(light: 0x2F7D4F, dark: 0x5FBF86)
    static let warn = Color(light: 0xB4541A, dark: 0xE8955A)
}

private struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        // Disabled: an outline with quiet text, readable in both appearances.
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(isEnabled ? .paper : .graphite)
            .padding(.horizontal, 20)
            .padding(.vertical, 9)
            .background(Capsule().fill(isEnabled ? Color.ink.opacity(configuration.isPressed ? 0.75 : 1) : Color.clear))
            .overlay(Capsule().stroke(isEnabled ? Color.clear : Color.line, lineWidth: 1))
            .contentShape(Capsule())
    }
}

/// Secondary actions are underlined words, so each step has exactly one
/// button that looks like a button.
private struct LinkButtonStyle: ButtonStyle {
    var color: Color = .ink

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .underline()
            .foregroundColor(color)
            .opacity(configuration.isPressed ? 0.55 : 1)
            .contentShape(Rectangle())
    }
}

/// The switch itself, drawn, so it matches the palette and also renders in
/// `--onboardingshot` (AppKit-backed controls draw as placeholders there).
private struct InkSwitch: View {
    var isOn: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? Color.ink : Color.ink.opacity(0.14))
                .frame(width: 32, height: 19)
            Circle()
                .fill(Color.paper)
                .frame(width: 15, height: 15)
                .padding(2)
        }
    }
}

/// An open arc that turns once a second: the "in progress" mark. Drawn
/// rather than a ProgressView so it renders in `--onboardingshot` too, and
/// driven by the clock (no @State, which is a macro in this SDK).
private struct Spinner: View {
    var size: CGFloat = 14

    var body: some View {
        TimelineView(.animation) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(Color.ink.opacity(0.7), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .frame(width: size, height: size)
                .rotationEffect(.degrees(turn * 360))
        }
        .frame(width: size, height: size)
    }
}

/// A dot that breathes while talkflow listens. Still with Reduce Motion on.
private struct PulseDot: View {
    var still: Bool
    var size: CGFloat = 8

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: still)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2
            let level = still ? 1 : 0.55 + 0.45 * (0.5 + 0.5 * cos(phase * 2 * .pi))
            Circle()
                .fill(Color.warn)
                .frame(width: size, height: size)
                .opacity(level)
        }
        .frame(width: size, height: size)
    }
}

/// The practice field: a plain text view that takes the keyboard focus as
/// soon as it is on screen, so holding Fn types straight into it.
private struct PracticeTextView: NSViewRepresentable {
    @Binding var text: String

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        /// The field took the focus once; after that it is the user's call.
        var focused = false
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            if text.wrappedValue != view.string { text.wrappedValue = view.string }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.borderType = .noBorder
        if let view = scroll.documentView as? NSTextView {
            view.delegate = context.coordinator
            view.drawsBackground = false
            view.isRichText = false
            view.allowsUndo = true
            view.font = .systemFont(ofSize: 14)
            view.textColor = .labelColor
            view.insertionPointColor = .labelColor
            view.textContainerInset = NSSize(width: 8, height: 9)
            view.string = text
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.text = $text
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text { view.string = text }
        // Into the field as soon as it is in a window, so holding Fn types
        // straight into it. Tried again on the next update until then.
        if !coordinator.focused {
            DispatchQueue.main.async {
                guard !coordinator.focused, let window = view.window else { return }
                coordinator.focused = window.makeFirstResponder(view)
            }
        }
    }
}

private struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    /// For `--onboardingshot`: the practice field is drawn instead of being
    /// a live text view, which ImageRenderer cannot draw.
    var snapshot = false

    static let width: CGFloat = 560
    static let height: CGFloat = 680
    private let gutter: CGFloat = 36

    /// The steps people see. Input Monitoring is not one of them: the
    /// Accessibility grant covers the Fn key (Permissions.inputMonitoring),
    /// so its step only appears, counted with Accessibility, in the unlikely
    /// case that the key still cannot be heard.
    private static let tracked: [(step: OnboardingStep, label: String)] = [
        (.microphone, "Microphone"),
        (.accessibility, "Accessibility"),
        (.engine, "Speech engine"),
        (.ready, "Try it"),
    ]

    private var motion: Animation? { OnboardingMotion.animation(reduceMotion: model.reduceMotion) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, gutter)
                .padding(.top, 34)
            progress
                .padding(.horizontal, gutter)
                .padding(.top, 22)
                .animation(motion, value: model.step)
                .animation(motion, value: model.engine)
            hairline.padding(.top, 20)
            ZStack(alignment: .topLeading) {
                content
                    .id(model.step)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(x: 10)),
                        removal: .opacity))
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, gutter)
            .padding(.top, 24)
            .animation(motion, value: model.step)
            Spacer(minLength: 12)
            hairline
            footer
                .padding(.horizontal, gutter)
                .padding(.vertical, 16)
        }
        .frame(width: Self.width, height: Self.height, alignment: .topLeading)
        .background(Color.paper)
        .foregroundColor(.ink)
    }

    private var hairline: some View {
        Rectangle().fill(Color.line).frame(height: 1)
    }

    // MARK: Header, progress, footer

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 30, height: 30)
            Text("talkflow")
                .font(.system(size: 22, weight: .regular, design: .serif))
            Spacer()
            Text("Setup")
                .font(.system(size: 12))
                .foregroundColor(.graphite)
        }
    }

    private var progress: some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(Self.tracked, id: \.step) { item in
                let mark = model.mark(item.step)
                // The engine's segment fills while the model downloads in
                // the background, so its progress is visible from any step.
                let fill = item.step == .engine && mark == .pending ? model.engineFraction : nil
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 5) {
                        if item.step == .engine && mark == .pending && model.engineBusy {
                            Spinner(size: 12).frame(width: 14, height: 14)
                        } else {
                            node(mark)
                        }
                        ZStack(alignment: .leading) {
                            Capsule().fill(barColor(mark))
                            if let fill {
                                GeometryReader { geometry in
                                    Capsule()
                                        .fill(Color.ink.opacity(0.55))
                                        .frame(width: max(2, geometry.size.width * CGFloat(fill)))
                                }
                            }
                        }
                        .frame(height: 2)
                    }
                    Text(item.label + (fill.map { " \(Int($0 * 100))%" } ?? ""))
                        .font(.system(size: 11, weight: item.step == model.step ? .semibold : .regular))
                        .monospacedDigit()
                        .foregroundColor(labelColor(mark))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// The circle at the start of each progress segment: a check when done,
    /// a dot for the step on screen, "!" for a stale permission.
    private func node(_ mark: OnboardingFlow.Mark) -> some View {
        ZStack {
            switch mark {
            case .done:
                Circle().fill(Color.ink.opacity(0.75))
                Image(systemName: "checkmark")
                    .font(.system(size: 7, weight: .heavy))
                    .foregroundColor(.paper)
            case .current:
                Circle().stroke(Color.ink, lineWidth: 1.5)
                Circle().fill(Color.ink).frame(width: 5, height: 5)
            case .attention:
                Circle().fill(Color.warn)
                Text("!")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundColor(.paper)
            case .pending:
                Circle().stroke(Color.ink.opacity(0.2), lineWidth: 1.2)
            }
        }
        .frame(width: 14, height: 14)
    }

    private func barColor(_ mark: OnboardingFlow.Mark) -> Color {
        switch mark {
        case .done: return Color.ink.opacity(0.55)
        case .current: return .ink
        case .attention: return .warn
        case .pending: return Color.ink.opacity(0.12)
        }
    }

    private func labelColor(_ mark: OnboardingFlow.Mark) -> Color {
        switch mark {
        case .done: return .graphite
        case .current: return .ink
        case .attention: return .warn
        case .pending: return Color.graphite.opacity(0.75)
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            switch model.step {
            case .welcome:
                Text("About two minutes")
                    .font(.system(size: 12))
                    .foregroundColor(.graphite)
            case .ready:
                if model.loginItemAvailable {
                    Button {
                        model.launchAtLogin.toggle()
                    } label: {
                        HStack(spacing: 10) {
                            InkSwitch(isOn: model.launchAtLogin)
                            Text("Open talkflow when I log in")
                                .font(.system(size: 12))
                                .foregroundColor(.graphite)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("talkflow lives in your menu bar")
                        .font(.system(size: 12))
                        .foregroundColor(.graphite)
                }
            default:
                if model.previousStep != nil {
                    Button("Back") { model.goBack() }
                        .buttonStyle(LinkButtonStyle(color: .graphite))
                }
            }
            Spacer()
            primaryButton
        }
        .frame(height: 36)
    }

    /// The one button on each step, chosen by where the step is.
    @ViewBuilder
    private var primaryButton: some View {
        switch model.step {
        case .welcome:
            Button("Get started") { model.goNext() }.buttonStyle(PrimaryButtonStyle())
        case .microphone:
            permissionButton(.microphone, allowTitle: "Allow microphone")
        case .accessibility:
            permissionButton(.accessibility, allowTitle: "Allow accessibility")
        case .inputMonitoring:
            permissionButton(.inputMonitoring, allowTitle: "Allow input monitoring")
        case .engine:
            switch model.engine {
            case .needsSetup:
                Button(model.engineOnlyStopped ? "Start speech engine" : "Set up speech engine") { model.runEngineSetup() }.buttonStyle(PrimaryButtonStyle())
            case .needsHomebrew, .failed:
                Button("Try again") { model.runEngineSetup() }.buttonStyle(PrimaryButtonStyle())
            case .checking, .working, .ready:
                Button("Continue") { model.goNext() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!model.canContinue)
            }
        case .ready:
            if model.needsRestart {
                Button("Restart talkflow") { model.restartApp() }.buttonStyle(PrimaryButtonStyle())
            } else {
                Button("Done") { model.finish() }.buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    @ViewBuilder
    private func permissionButton(_ service: Permissions.Service, allowTitle: String) -> some View {
        switch model.status(service) {
        case .granted:
            Button("Continue") { model.goNext() }.buttonStyle(PrimaryButtonStyle())
        case .stale:
            Button(model.resetting == service ? "Resetting..." : "Reset and allow again") { model.resetAndAskAgain(service) }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.resetting != nil)
        case .missing:
            // After the first click macOS's prompt is used up, so the same
            // button opens the pane; it says so.
            let opensSettings = model.isWaiting(service) || (service == .microphone && model.microphone == .denied)
            Button(opensSettings ? "Open System Settings" : allowTitle) { model.allow(service) }
                .buttonStyle(PrimaryButtonStyle())
        }
    }

    // MARK: Steps

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .welcome: welcome
        case .microphone:
            permission(
                .microphone, title: "Microphone",
                why: "So talkflow can hear you while you hold Fn. Your voice is turned into text on this Mac and is never saved.",
                ask: "macOS asks once. Choose Allow.",
                allowed: "talkflow can hear you.")
        case .accessibility:
            permission(
                .accessibility, title: "Accessibility",
                why: "So talkflow can notice the Fn key and type your words into the app you are using.",
                ask: "macOS asks first, then takes you to the right place in System Settings.",
                allowed: "talkflow can hear Fn and type for you.")
        case .inputMonitoring:
            permission(
                .inputMonitoring, title: "Input Monitoring",
                why: "So talkflow can tell when you hold the Fn key. It only listens for keys like Fn, never for what you type.",
                ask: "macOS asks first, then takes you to the right place in System Settings.",
                allowed: "talkflow can tell when you hold Fn.")
        case .engine: engine
        case .ready: ready
        }
    }

    private func eyebrow(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .medium))
            .tracking(0.8)
            .foregroundColor(.graphite)
    }

    private func stepEyebrow() -> some View {
        let shown = model.step == .inputMonitoring ? OnboardingStep.accessibility : model.step
        let index = (Self.tracked.firstIndex { $0.step == shown } ?? 0) + 1
        return eyebrow("Step \(index) of \(Self.tracked.count)")
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 30, weight: .regular, design: .serif))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundColor(.graphite)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func small(_ text: String, color: Color = .graphite) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(color)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A hairline panel with a live status line on top.
    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.wash))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.line, lineWidth: 1))
    }

    private enum Tone { case good, waiting, idle, warn, live }

    private func statusLine(_ tone: Tone, _ text: String) -> some View {
        HStack(spacing: 8) {
            Group {
                switch tone {
                case .good:
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.good)
                case .waiting:
                    Spinner()
                case .idle:
                    Circle().stroke(Color.ink.opacity(0.35), lineWidth: 1.4).frame(width: 13, height: 13)
                case .warn:
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.warn)
                case .live:
                    PulseDot(still: model.reduceMotion || snapshot, size: 9)
                }
            }
            .frame(width: 16, height: 16)
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(tone == .warn ? .warn : (tone == .good ? .good : .ink))
        }
        .font(.system(size: 13))
    }

    // MARK: Welcome

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            eyebrow("Welcome")
            title("Dictate anywhere on your Mac.")
            paragraph("Hold Fn, speak, and let go. Your words appear wherever you are typing. It all runs on your Mac, with no account.")
            VStack(spacing: 0) {
                ForEach(Array(Self.tracked.enumerated()), id: \.element.step) { index, item in
                    if index > 0 { hairline }
                    overviewRow(index + 1, item.step)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.line, lineWidth: 1))
            .padding(.top, 6)
        }
    }

    private func overviewRow(_ number: Int, _ step: OnboardingStep) -> some View {
        let (name, detail): (String, String) = {
            switch step {
            case .microphone: return ("Microphone", "To hear you")
            case .accessibility: return ("Accessibility", "To notice Fn and type for you")
            case .inputMonitoring: return ("Input Monitoring", "To notice when you hold Fn")
            case .engine: return ("Speech engine", "About 490 MB, downloads while you set up")
            case .welcome, .ready: return ("Try it", "Right here, before you go")
            }
        }()
        let state: (String, Color) = {
            let service: Permissions.Service? = step == .microphone ? .microphone
                : step == .accessibility ? .accessibility
                : step == .inputMonitoring ? .inputMonitoring : nil
            if let service {
                switch model.status(service) {
                case .granted: return ("Allowed", .good)
                case .stale: return ("Needs a reset", .warn)
                case .missing: return ("Needed", .graphite)
                }
            }
            if step == .engine {
                if model.engine == .ready { return ("Ready", .good) }
                if let fraction = model.engineFraction { return ("\(Int(fraction * 100))%", .graphite) }
                if model.engineBusy { return ("Starting", .graphite) }
                return model.engineInstalled ? ("Installed", .good) : ("Needed", .graphite)
            }
            return ("", .graphite)
        }()
        return HStack(spacing: 12) {
            Text("\(number)")
                .font(.system(size: 13, weight: .regular, design: .serif))
                .frame(width: 22, height: 22)
                .overlay(Circle().stroke(Color.line, lineWidth: 1))
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundColor(.graphite)
            }
            Spacer()
            Text(state.0)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundColor(state.1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    // MARK: Permissions

    private func permission(_ service: Permissions.Service, title heading: String, why: String, ask: String, allowed: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            stepEyebrow()
            title(heading)
            paragraph(why)
            panel {
                switch model.status(service) {
                case .granted:
                    statusLine(.good, "Allowed")
                    small(allowed)
                case .stale(let reason):
                    staleFix(service, reason)
                case .missing:
                    if model.isWaiting(service) {
                        statusLine(.waiting, Onboarding.switchOn(service, appName: model.appName).action)
                        switchOnGuide(service)
                        small((service == .microphone ? "" : "Not listed? Add it with the + button. ")
                              + "This page moves on by itself.")
                        alreadyOnLink(service)
                    } else if service == .microphone && model.microphone == .denied {
                        statusLine(.idle, "Microphone access is off")
                        switchOnGuide(service)
                        alreadyOnLink(service)
                    } else {
                        statusLine(.idle, "Not allowed yet")
                        small(ask)
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    /// What to look for in System Settings: the place, and the row with its
    /// switch on, drawn the way it looks there.
    private func switchOnGuide(_ service: Permissions.Service) -> some View {
        let guide = Onboarding.switchOn(service, appName: model.appName)
        return VStack(alignment: .leading, spacing: 8) {
            small("In \(guide.place):")
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 18, height: 18)
                Text(model.appName).font(.system(size: 13))
                Spacer()
                InkSwitch(isOn: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.paper))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.line, lineWidth: 1))
        }
    }

    private func alreadyOnLink(_ service: Permissions.Service) -> some View {
        Button("Already switched on?") { model.reportAlreadyOn(service) }
            .buttonStyle(LinkButtonStyle())
    }

    /// The permission is on in System Settings for an older copy of
    /// talkflow: say so and how to fix it. Reset is the footer button.
    @ViewBuilder
    private func staleFix(_ service: Permissions.Service, _ reason: StaleReason) -> some View {
        let help = Onboarding.staleHelp(service, reason)
        statusLine(.warn, "macOS is holding on to an older talkflow")
        small(help.why)
        small(help.fix)
        HStack(spacing: 16) {
            if service == .inputMonitoring && reason != .appChanged {
                Button("Restart talkflow") { model.restartApp() }
                    .buttonStyle(LinkButtonStyle())
            }
            Button("Open System Settings") { model.openSettings(service) }
                .buttonStyle(LinkButtonStyle())
        }
        if model.resetFailed == service {
            small("The reset did not work. Use the steps above in System Settings instead.", color: .warn)
        }
    }

    // MARK: Engine

    private var engine: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepEyebrow()
            title("Speech engine")
            paragraph("talkflow turns speech into text with Whisper, right on your Mac. The model is a one-time download of about 490 MB.")
            panel {
                switch model.engine {
                case .checking:
                    statusLine(.waiting, "Checking...")
                case .ready:
                    statusLine(.good, "Ready")
                    small("The speech engine is running on this Mac.")
                case .needsSetup:
                    statusLine(.idle, model.engineOnlyStopped ? "Not running" : "Not set up yet")
                    small(model.engineNeeds)
                case .working(let message, let fraction):
                    let lines = message.components(separatedBy: "\n")
                    statusLine(.waiting, lines[0])
                    if let fraction {
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.ink.opacity(0.1))
                                Capsule().fill(Color.ink).frame(width: max(6, geometry.size.width * CGFloat(fraction)))
                            }
                        }
                        .frame(height: 5)
                        HStack {
                            small("\(Int(fraction * EngineSetup.modelMegabytes)) of \(Int(EngineSetup.modelMegabytes)) MB")
                                .monospacedDigit()
                            Spacer()
                            small(model.downloadTimeLeft ?? "Working out the time left")
                        }
                    } else if lines.count > 1 {
                        small(lines.dropFirst().joined(separator: "\n"))
                            .lineLimit(3)
                    }
                    small("Setup moves on by itself when it is ready.")
                case .needsHomebrew:
                    statusLine(.warn, "Homebrew is needed")
                    small("The Whisper program is installed with Homebrew, which is not on this Mac yet. Install it from brew.sh, then come back and press Try again.")
                    Button("Open brew.sh") { NSWorkspace.shared.open(URL(string: "https://brew.sh")!) }
                        .buttonStyle(LinkButtonStyle())
                case .failed(let message):
                    statusLine(.warn, "Setup did not finish")
                    small(message, color: .warn)
                        .lineLimit(7)
                    if message.hasPrefix(EngineSetup.downloadStopped) {
                        small("Check your internet connection, then press Try again. The download picks up where it stopped.")
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    // MARK: Try it

    private var ready: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let phase = model.tryItPhase(at: context.date)
            VStack(alignment: .leading, spacing: 14) {
                stepEyebrow()
                title(phase == .success ? "That's it." : "Hold Fn and say something.")
                paragraph(phase == .success
                          ? "Hold Fn in any app, speak, and let go. talkflow waits in your menu bar."
                          : "Hold the Fn key, speak, then let go. Try it right here.")
                practiceField(phase)
                tryItStatus(phase)
            }
            .animation(motion, value: phase)
        }
    }

    @ViewBuilder
    private func tryItStatus(_ phase: TryIt.Phase) -> some View {
        switch phase {
        case .restart:
            panel {
                statusLine(.warn, "macOS needs talkflow to restart")
                small("macOS applies the new permission when talkflow starts again. Press Restart talkflow, then hold Fn in any text field.")
            }
        case .starting:
            statusLine(.waiting, "Getting the Fn key ready...")
        case .waiting:
            statusLine(.idle, "Ready when you are")
        case .listening:
            statusLine(.live, "Let go when you are done.")
        case .writing:
            statusLine(.waiting, "Writing it down...")
        case .success:
            statusLine(.good, "It works")
        case .nothingArrived, .hint:
            panel {
                statusLine(.idle, phase == .hint ? "Nothing yet?" : "Nothing arrived")
                small(phase == .hint
                      ? "Hold the Fn key, bottom left on most keyboards, and keep holding it while you speak."
                      : "Hold Fn for the whole sentence and speak up a little, then let go.")
                if model.fnKeyHasSystemAction {
                    small("If the emoji picker or system dictation opens, set \"Press the globe key to\" to \"Do Nothing\".")
                    Button("Open Keyboard settings") { Permissions.openKeyboardSettings() }
                        .buttonStyle(LinkButtonStyle())
                }
            }
        }
    }

    @ViewBuilder
    private func practiceField(_ phase: TryIt.Phase) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        let border: Color = phase == .listening ? .ink : (phase == .success ? Color.good.opacity(0.7) : .line)
        ZStack(alignment: .topLeading) {
            if snapshot {
                if !model.practice.isEmpty {
                    Text(model.practice)
                        .font(.system(size: 14))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 9)
                }
            } else {
                PracticeTextView(text: $model.practice)
            }
            if model.practice.isEmpty {
                Text(phase == .listening ? "Speak now..." : "Your words appear here")
                    .font(.system(size: 14))
                    .foregroundColor(Color.graphite.opacity(0.7))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 84, maxHeight: 84, alignment: .topLeading)
        .background(shape.fill(Color.paper))
        .overlay(shape.stroke(border, lineWidth: phase == .listening ? 1.5 : 1))
        .overlay(alignment: .topTrailing) {
            if phase == .listening {
                HStack(spacing: 6) {
                    PulseDot(still: model.reduceMotion || snapshot, size: 7)
                    Text("Listening")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.graphite)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .transition(.opacity)
            }
        }
    }
}

// MARK: - --onboardingshot

extension OnboardingController {
    /// `--onboardingshot`: draws every setup step, and the stale-grant,
    /// engine and Try it states, light and dark, to PNGs in `directory`,
    /// from fixed fake permission states, so the layout can be checked
    /// without a screen. Read-only: no permission is read or asked for,
    /// nothing is downloaded or saved.
    @MainActor
    static func renderSnapshots(to directory: URL) -> [URL] {
        _ = NSApplication.shared // the header reads NSApp's icon
        // A bare `.build` binary has no icon of its own; use the app's.
        if Bundle.main.bundleURL.pathExtension != "app" {
            let icon = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Packaging/AppIcon.icns")
            if let image = NSImage(contentsOf: icon) { NSApp.applicationIconImage = image }
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: [URL] = []
        for (index, shot) in snapshotStates().enumerated() {
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                    let renderer = ImageRenderer(content: OnboardingView(model: shot.model, snapshot: true)
                        .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light))
                    renderer.scale = 2
                    guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
                    let url = directory.appendingPathComponent(String(format: "%02d-%@-%@.png", index + 1, shot.name, name))
                    try? png.write(to: url)
                    written.append(url)
                }
            }
        }
        return written
    }

    /// A model on fake permissions. `grantedTo` records the grants as made
    /// to an older build, which is what makes a missing one stale. The
    /// engine never answers and its setup never runs, so each shot sets the
    /// engine state it shows.
    private static func snapshotModel(
        mic: Permissions.MicrophoneStatus = .granted, ax: Bool = true, im: Bool = true,
        engineInstalled: Bool = true, olderGrants: Bool = false
    ) -> OnboardingModel {
        let defaults = EphemeralDefaults()
        if olderGrants {
            let history = PermissionHistory(defaults: defaults)
            for service in Permissions.Service.allCases { history.record(service, granted: true, requirement: "cdhash H\"0ld\"") }
        }
        let environment = OnboardingEnvironment(
            microphone: { mic }, accessibility: { ax }, inputMonitoring: { im },
            engineInstalled: { engineInstalled }, defaults: defaults, advanceDelay: 0,
            designatedRequirement: "cdhash H\"new\"",
            asked: { _ in true }, request: { _, done in done() }, openSettings: { _ in },
            resetGrant: { _, done in done(true) }, staleGrace: 0,
            fnKeyHasSystemAction: { true },
            engineResponding: { _ in }, engineProgramPresent: { true }, setUpEngine: { _ in },
            reduceMotion: { true }, appName: "talkflow")
        return OnboardingModel(startHotkey: { true }, environment: environment)
    }

    /// The model download part way, at a known speed (a 12-point gain over
    /// 30 seconds: about 2 minutes left at 42%).
    private static func downloading(_ model: OnboardingModel, _ fraction: Double = 0.42) {
        model.runEngineSetup()
        model.engineChanged(.working(EngineSetup.downloadingMessage, max(0, fraction - 0.12)), at: 0)
        model.engineChanged(.working(EngineSetup.downloadingMessage, fraction), at: 30)
    }

    @MainActor
    private static func snapshotStates() -> [(name: String, model: OnboardingModel)] {
        func make(_ name: String, _ model: OnboardingModel, _ configure: (OnboardingModel) -> Void) -> (String, OnboardingModel) {
            configure(model)
            return (name, model)
        }
        return [
            make("welcome", snapshotModel(mic: .notDetermined, ax: false, im: false, engineInstalled: false)) {
                $0.step = .welcome
                downloading($0, 0.06)
            },
            make("welcome-after-update", snapshotModel(ax: false, im: false, olderGrants: true)) { $0.step = .welcome },
            make("microphone", snapshotModel(mic: .notDetermined, ax: false, im: false, engineInstalled: false)) {
                $0.step = .microphone
                downloading($0, 0.12)
            },
            make("microphone-denied", snapshotModel(mic: .denied, ax: false, im: false)) { $0.step = .microphone },
            make("accessibility", snapshotModel(ax: false, im: false, engineInstalled: false)) {
                $0.step = .accessibility
                downloading($0, 0.31)
            },
            make("accessibility-waiting", snapshotModel(ax: false, im: false, engineInstalled: false)) {
                $0.step = .accessibility
                $0.allow(.accessibility)
                downloading($0)
            },
            make("accessibility-allowed", snapshotModel(im: false)) { $0.step = .accessibility },
            make("accessibility-stale-update", snapshotModel(ax: false, im: false, olderGrants: true)) { $0.step = .accessibility },
            make("accessibility-reset-failed", snapshotModel(ax: false, im: false, olderGrants: true)) {
                $0.step = .accessibility
                $0.resetFailed = .accessibility
            },
            make("input-monitoring", snapshotModel(im: false)) { $0.step = .inputMonitoring },
            make("input-monitoring-stale-back", snapshotModel(im: false)) {
                $0.step = .inputMonitoring
                $0.allow(.inputMonitoring)
                $0.appBecameActive(awayFor: 30)
            },
            make("engine-needs-setup", snapshotModel(engineInstalled: false)) {
                $0.step = .engine
                $0.engine = .needsSetup
            },
            make("engine-downloading", snapshotModel(engineInstalled: false)) {
                $0.step = .engine
                downloading($0, 0.64)
            },
            make("engine-starting", snapshotModel(engineInstalled: false)) {
                $0.step = .engine
                $0.runEngineSetup()
                $0.engineChanged(.working("Starting the speech engine...", nil))
            },
            make("engine-failed", snapshotModel(engineInstalled: false)) {
                $0.step = .engine
                $0.engine = .failed("The download stopped: The network connection was lost.")
            },
            make("engine-ready", snapshotModel()) {
                $0.step = .engine
                $0.engine = .ready
            },
            make("try-it", snapshotModel()) {
                $0.step = .ready
                $0.hotkeyRunning = true
                $0.engine = .ready
            },
            make("try-it-listening", snapshotModel()) {
                $0.step = .ready
                $0.hotkeyRunning = true
                $0.engine = .ready
                $0.pretendTryIt(fnDown: true)
            },
            make("try-it-success", snapshotModel()) {
                $0.step = .ready
                $0.hotkeyRunning = true
                $0.engine = .ready
                $0.practice = "Hello from talkflow, this is my first dictation."
                $0.pretendTryIt(pressedAgo: 1, succeeded: true)
            },
            make("try-it-hint", snapshotModel()) {
                $0.step = .ready
                $0.hotkeyRunning = true
                $0.engine = .ready
                $0.pretendTryIt(shownAgo: 40)
            },
            make("try-it-nothing-arrived", snapshotModel()) {
                $0.step = .ready
                $0.hotkeyRunning = true
                $0.engine = .ready
                $0.pretendTryIt(pressedAgo: 12, shownAgo: 30)
            },
            make("ready-restart", snapshotModel()) {
                $0.step = .ready
                $0.needsRestart = true
            },
        ]
    }
}
