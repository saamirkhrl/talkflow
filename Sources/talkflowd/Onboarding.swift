import AppKit
import ServiceManagement
import SwiftUI

/// First-run setup, a page at a time: a welcome page with the languages,
/// one page per macOS permission (each a card with its own Allow button),
/// then a place to try it. Shown automatically whenever something talkflow
/// needs is missing (so it also reappears if a permission is later revoked
/// or an update leaves one behind), and from the menu bar only while that is
/// so: a finished setup is never offered again.
///
/// The speech engine gets ready in the background from the moment setup
/// opens, with its progress in the footer, so the model download usually
/// finishes while the user is busy with the permissions and its page is
/// skipped like a granted one.
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
        DockIcon.require(.setup)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        model.stop()
        DockIcon.release(.setup)
    }
}

enum Onboarding {
    static let completedKey = "onboardingCompleted"
    /// The step a first-run setup had reached, so a relaunch in the middle of
    /// it (System Settings' "Quit & Reopen", or Restart talkflow) resumes
    /// there instead of on the welcome page. Removed when setup finishes.
    static let progressKey = "onboardingProgress"
    /// The user pressed Skip on the meeting notes step: it is not offered again.
    static let notesSkippedKey = "onboardingNotesSkipped"

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
        return (why, "Reset and allow removes talkflow's old entry so macOS asks again. " + byHand)
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
              let saved = OnboardingStep.restored(defaults.integer(forKey: progressKey)) else { return false }
        return saved != .welcome && saved != .tryIt && saved != .meetingNotes && saved != .done
    }
}

// MARK: - Model

enum OnboardingStep: Int, CaseIterable {
    // Raw values stay compatible with the progress saved by older builds
    // (3 was Input Monitoring, which is no longer a step).
    case welcome = 0, microphone = 1, accessibility = 2, engine = 4, tryIt = 5, meetingNotes = 6, done = 7

    /// The neighbour in flow order (not rawValue +- 1: 3 is unused).
    var next: OnboardingStep? {
        guard let index = Self.allCases.firstIndex(of: self), index + 1 < Self.allCases.count else { return nil }
        return Self.allCases[index + 1]
    }

    var previous: OnboardingStep? {
        guard let index = Self.allCases.firstIndex(of: self), index > 0 else { return nil }
        return Self.allCases[index - 1]
    }

    /// A saved progress value as a step. The dropped Input Monitoring step
    /// (3) resumes on Accessibility; anything unknown is nil.
    static func restored(_ raw: Int) -> OnboardingStep? {
        raw == 3 ? .accessibility : OnboardingStep(rawValue: raw)
    }
}

/// The permissions as plain values, so the step logic below can be checked
/// by `--streamtest` without touching the real ones.
struct PermissionGrants: Equatable {
    var microphone: Bool
    var accessibility: Bool
    var systemAudio: Bool = false

    /// Whether the permission a step asks for is granted; nil for the steps
    /// that are not about a permission.
    func isGranted(_ step: OnboardingStep) -> Bool? {
        switch step {
        case .microphone: return microphone
        case .accessibility: return accessibility
        case .meetingNotes: return systemAudio
        case .welcome, .engine, .tryIt, .done: return nil
        }
    }
}

/// Which step setup shows. Pure, for `--streamtest`.
enum OnboardingFlow {
    /// Whether the meeting notes step is still to be offered.
    static func offersNotes(supported: Bool, skipped: Bool, granted: Bool) -> Bool {
        supported && !skipped && !granted
    }

    /// The steps of a flow, without meeting notes where it is not supported.
    static func steps(notesSupported: Bool) -> [OnboardingStep] {
        OnboardingStep.allCases.filter { notesSupported || $0 != .meetingNotes }
    }

    /// The first permission step still missing, then the engine. System
    /// audio is never required.
    static func firstMissing(_ grants: PermissionGrants, engineInstalled: Bool) -> OnboardingStep? {
        if !grants.microphone { return .microphone }
        if !grants.accessibility { return .accessibility }
        if !engineInstalled { return .engine }
        return nil
    }

    /// Nothing to do on this step: its permission is granted, it is the
    /// engine and the engine is already answering, or it is the meeting notes
    /// step and there is nothing to offer. Welcome, Try it and the last page
    /// are never skipped.
    static func isDone(_ step: OnboardingStep, grants: PermissionGrants, engineReady: Bool, offerNotes: Bool = true) -> Bool {
        switch step {
        case .microphone: return grants.microphone
        case .accessibility: return grants.accessibility
        case .engine: return engineReady
        case .meetingNotes: return grants.systemAudio || !offerNotes
        case .welcome, .tryIt, .done: return false
        }
    }

    /// The step after `step`, skipping the ones that are already done.
    static func nextNeeded(after step: OnboardingStep, grants: PermissionGrants, engineReady: Bool = false, offerNotes: Bool = true) -> OnboardingStep {
        var candidate = step.next ?? .done
        while isDone(candidate, grants: grants, engineReady: engineReady, offerNotes: offerNotes), let next = candidate.next { candidate = next }
        return candidate
    }

    /// Where Back goes: the closest earlier step that still has something to
    /// do, or the welcome page on a first run. Nil hides Back.
    static func previousShown(before step: OnboardingStep, grants: PermissionGrants, engineReady: Bool, returning: Bool, offerNotes: Bool = true) -> OnboardingStep? {
        var candidate = step.previous
        while let shown = candidate {
            if shown == .welcome { return returning ? nil : .welcome }
            if !isDone(shown, grants: grants, engineReady: engineReady, offerNotes: offerNotes) { return shown }
            candidate = shown.previous
        }
        return nil
    }

    /// Where setup opens when it was not already open. A finished setup goes
    /// to whatever is missing, or to the Try it page when nothing is, never
    /// through the whole flow again. A first run starts on the welcome page
    /// (where the languages are chosen), or, when it was interrupted
    /// (`saved`), where it was, moved past a permission that has since been
    /// granted and back to an earlier one that has since been lost.
    static func initialStep(completed: Bool, saved: OnboardingStep?, grants: PermissionGrants, engineInstalled: Bool) -> OnboardingStep {
        let missing = firstMissing(grants, engineInstalled: engineInstalled)
        if completed { return missing ?? .tryIt }
        guard let saved, saved != .welcome else { return .welcome }
        var resumed = saved
        if grants.isGranted(saved) == true { resumed = nextNeeded(after: saved, grants: grants) }
        if let missing, missing.rawValue < resumed.rawValue { return missing }
        return resumed
    }

    /// How a step shows in the step dots.
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
    static func stepAfterRefresh(current: OnboardingStep, before: PermissionGrants, now: PermissionGrants, engineReady: Bool = false, offerNotes: Bool = true) -> OnboardingStep {
        guard before.isGranted(current) == false, now.isGranted(current) == true else { return current }
        return nextNeeded(after: current, grants: now, engineReady: engineReady, offerNotes: offerNotes)
    }

    /// The step once the engine has finished getting ready: on its own step,
    /// setup moves on by itself, as it does when a grant lands. Anywhere
    /// else the step stays (the engine step is simply skipped later).
    static func stepAfterEngine(current: OnboardingStep, ready: Bool, grants: PermissionGrants, offerNotes: Bool = true) -> OnboardingStep {
        guard current == .engine, ready else { return current }
        return nextNeeded(after: .engine, grants: grants, engineReady: true, offerNotes: offerNotes)
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
    /// The shortcut held to dictate. Setup only names it; Settings changes it.
    var shortcut: () -> HotkeySpec = { .fn }
    /// System Audio Recording, which meeting notes need.
    var systemAudio: () -> SystemAudioStatus = { .unknown }
    /// Raises the system's own prompt for it (or its stand-in); calls back on the main thread.
    var requestSystemAudio: (@escaping () -> Void) -> Void = { $0() }
    /// Whether this macOS can record system audio at all (14.2 and later).
    var notesSupported: Bool = false
    /// Where this copy runs from.
    var appLocation: AppLocation = .fine
    /// Docks the guide panel beside System Settings; answers once per request.
    var showGuide: (GuideRequest, @escaping (GuideOutcome) -> Void) -> Void = { _, done in done(.notFound) }
    var hideGuide: () -> Void = {}

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
        }(),
        shortcut: { Preferences.hotkey },
        systemAudio: { SystemAudioPermission.status() },
        requestSystemAudio: { SystemAudioPermission.request($0) },
        notesSupported: SystemAudioPermission.isSupported,
        appLocation: AppLocation.current,
        showGuide: { PermissionGuide.shared.show($0, outcome: $1) },
        hideGuide: { PermissionGuide.shared.hide() }
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
    /// How a failed Homebrew install's message starts (setup then shows the
    /// Terminal command).
    static let homebrewFailed = "Homebrew could not install it."
    /// The model's size, for "x of y MB" (190,098,681 bytes).
    static let modelMegabytes = 190.0
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
                // talkflow.app carries its own engine; Homebrew is only for a bare dev build.
                if SpeechEngine.bundledServerPath != nil {
                    post(.failed(SpeechEngine.missingBundledEngineMessage))
                    return
                }
                guard SpeechEngine.brewBinary() != nil else {
                    post(.needsHomebrew)
                    return
                }
                post(.working("Installing the Whisper program with Homebrew. This can take a few minutes.", nil))
                let result = SpeechEngine.installWhisperCpp { line in
                    post(.working("Installing the Whisper program with Homebrew...\n\(line)", nil))
                }
                guard result.succeeded, SpeechEngine.serverBinary() != nil else {
                    post(.failed("\(homebrewFailed)\n\(result.tail)"))
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
            if oldValue != step { hideGuideIfShown() }
            if step == .tryIt && oldValue != .tryIt { resetTryIt() }
        }
    }
    @Published var microphone: Permissions.MicrophoneStatus
    @Published var accessibility: Bool
    /// Only decides when the hotkey is started; no step asks for it.
    @Published var inputMonitoring: Bool
    @Published var systemAudio: SystemAudioStatus
    /// The user pressed Allow for system audio at least once this session.
    @Published private(set) var systemAudioAsked = false
    /// The guide panel is docked beside System Settings for this target.
    @Published private(set) var guideShown: Set<GuideTarget> = []
    /// The panel could not find System Settings: the old flow is shown.
    @Published private(set) var guideFailed: Set<GuideTarget> = []
    @Published var engine: EngineState = .checking
    @Published var hotkeyRunning = false
    /// The same setting as in Settings, ticked as a list on the welcome page
    /// (`toggleSpoken`). Any language but English starts the multilingual
    /// model's download right away (`LiveModel`).
    @Published var language = Preferences.language {
        didSet {
            guard Preferences.language != language else { return }
            Preferences.language = language
            LiveModel.prepare()
        }
    }
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
    /// The permission whose by-hand fix is open. Folded away otherwise:
    /// Reset and allow is the one click most people need.
    @Published var manualFixShown: Permissions.Service?

    // The Try it page.
    /// Fn is held right now.
    @Published private(set) var fnDown = false
    /// The practice field when Fn last went down; nil until it has.
    @Published private(set) var tryItBaseline: String?
    @Published private(set) var tryItReleasedAt: Date?
    @Published private(set) var tryItShownAt = Date()
    /// Dictated words arrived. Stays true for the visit.
    @Published private(set) var tryItSucceeded = false

    /// Setup has never been finished on this Mac: the welcome page and the
    /// step dots show. Read when setup opens, so it does not change under
    /// the user as grants land.
    @Published private(set) var firstRun: Bool

    var bringToFront: () -> Void = {}
    var close: () -> Void = {}

    /// This copy runs from the disk image or a translocated path: setup asks
    /// for the move to Applications instead of any step.
    let needsMove: Bool

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
        firstRun = !environment.defaults.bool(forKey: Onboarding.completedKey)
        microphone = environment.microphone()
        accessibility = environment.accessibility()
        inputMonitoring = environment.inputMonitoring()
        systemAudio = environment.systemAudio()
        needsMove = environment.appLocation.needsMove
    }

    var grants: PermissionGrants {
        PermissionGrants(microphone: microphone == .granted, accessibility: accessibility, systemAudio: systemAudio == .granted)
    }

    var notesSkipped: Bool { environment.defaults.bool(forKey: Onboarding.notesSkippedKey) }
    var offerNotes: Bool {
        OnboardingFlow.offersNotes(supported: environment.notesSupported, skipped: notesSkipped, granted: systemAudio == .granted)
    }
    var notesSupported: Bool { environment.notesSupported }

    static func askedKey(_ service: Permissions.Service) -> String { "asked.\(service.rawValue)" }

    var engineInstalled: Bool { environment.engineInstalled() }
    var fnKeyHasSystemAction: Bool { environment.fnKeyHasSystemAction() }
    var reduceMotion: Bool { environment.reduceMotion() }
    var appName: String { environment.appName }
    var shortcut: HotkeySpec { environment.shortcut() }

    /// Someone who has been through setup before (or granted talkflow
    /// anything): no welcome page for them, only what is missing.
    var isReturning: Bool {
        environment.defaults.bool(forKey: Onboarding.completedKey) || !history.isEmpty
    }

    /// The user has been sent to System Settings (or macOS's prompt) for
    /// this permission and it has not landed yet.
    func isWaiting(_ service: Permissions.Service) -> Bool {
        settingsVisits.contains(service) && !trusted(service)
    }

    /// How a step shows in the step dots.
    func mark(_ shown: OnboardingStep) -> OnboardingFlow.Mark {
        let service: Permissions.Service?
        switch shown {
        case .microphone: service = .microphone
        case .accessibility: service = .accessibility
        case .welcome, .engine, .tryIt, .meetingNotes, .done: service = nil
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
        firstRun = !environment.defaults.bool(forKey: Onboarding.completedKey)
        refresh(announce: false)
        let defaults = environment.defaults
        let saved = defaults.object(forKey: Onboarding.progressKey) == nil
            ? nil : OnboardingStep.restored(defaults.integer(forKey: Onboarding.progressKey))
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
        hideGuideIfShown()
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
        if step == .tryIt || step == .meetingNotes || step == .done {
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
        let audio = environment.systemAudio()
        let gained = (mic == .granted && microphone != .granted)
            || (ax && !accessibility)
            || (im && !inputMonitoring)
            || (audio == .granted && systemAudio != .granted)
        microphone = mic
        accessibility = ax
        inputMonitoring = im
        systemAudio = audio
        if gained && announce { bringToFront() }

        // A permission the guide was helping with has landed: the panel's job is done.
        for target in guideShown where isGranted(target) {
            hideGuideIfShown()
            break
        }

        for service in Permissions.Service.allCases where trusted(service) {
            history.record(service, granted: true, requirement: environment.designatedRequirement)
            if userSaysOn.contains(service) { userSaysOn.remove(service) }
            if backFromSettings.contains(service) { backFromSettings.remove(service) }
            settingsVisits.remove(service)
        }

        let current = step
        advance(from: current, to: OnboardingFlow.stepAfterRefresh(
            current: current, before: before, now: grants, engineReady: engine == .ready, offerNotes: offerNotes))

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
        case .engine: return engine == .ready
        case .tryIt: return true
        case .meetingNotes: return systemAudio == .granted || (systemAudioAsked && systemAudio == .unknown)
        case .done: return true
        }
    }

    /// Forward, past anything already done.
    func goNext() {
        guard canContinue, step != .done else { return }
        move(to: OnboardingFlow.nextNeeded(after: step, grants: grants, engineReady: engine == .ready, offerNotes: offerNotes))
    }

    /// Where Back goes; nil when there is nowhere useful to go.
    var previousStep: OnboardingStep? {
        OnboardingFlow.previousShown(before: step, grants: grants, engineReady: engine == .ready, returning: isReturning, offerNotes: offerNotes)
    }

    func goBack() {
        guard let previousStep else { return }
        step = previousStep
    }

    // MARK: Languages

    /// Ticks or unticks a language on the welcome page. The last ticked one
    /// stays ticked: talkflow has to listen for something.
    func toggleSpoken(_ spoken: DictationLanguage) {
        var ticked = language.spoken
        if ticked.contains(spoken) {
            guard ticked.count > 1 else { return }
            ticked.remove(spoken)
        } else {
            ticked.insert(spoken)
        }
        language = DictationLanguage.speaking(ticked)
    }

    func finish() {
        hideGuideIfShown()
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

    /// The card's Allow button. macOS shows its own prompt only the first
    /// time it is asked; after that the same click opens the System
    /// Settings pane, so pressing Allow always does something visible.
    func allow(_ service: Permissions.Service) {
        guard !needsMove, !trusted(service) else { return }
        settingsVisits.insert(service)
        switch service {
        case .microphone:
            if microphone == .notDetermined {
                environment.request(.microphone) { [weak self] in self?.refresh(announce: true) }
            } else {
                environment.openSettings(.microphone)
                guide(.microphone, .switchOn)
            }
        case .accessibility:
            environment.openSettings(.accessibility)
            guide(.accessibility, .drag) { [weak self] in self?.accessibilityFallback() }
        case .inputMonitoring:
            // No step shows it any more; kept for completeness.
            let askedBefore = environment.asked(service)
            environment.request(service) {}
            environment.defaults.set(true, forKey: Self.askedKey(service))
            if askedBefore { environment.openSettings(service.pane) }
        }
    }

    /// The old flow: macOS's own prompt adds talkflow to the list switched
    /// off; the page then shows the switch-on guide.
    private func accessibilityFallback() {
        environment.request(.accessibility) {}
        environment.defaults.set(true, forKey: Self.askedKey(.accessibility))
    }

    // MARK: Guide panel

    private func guide(_ target: GuideTarget, _ mode: GuideMode, onNotFound: @escaping () -> Void = {}) {
        guideFailed.remove(target)
        environment.showGuide(GuideRequest(target: target, mode: mode)) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .shown:
                self.guideShown.insert(target)
            case .notFound:
                self.guideShown.remove(target)
                self.guideFailed.insert(target)
                onNotFound()
            }
        }
    }

    private func hideGuideIfShown() {
        guard !guideShown.isEmpty else { return }
        guideShown.removeAll()
        environment.hideGuide()
    }

    private func isGranted(_ target: GuideTarget) -> Bool {
        switch target {
        case .accessibility: return accessibility
        case .microphone: return microphone == .granted
        case .systemAudio: return systemAudio == .granted
        }
    }

    // MARK: Meeting notes

    /// The meeting notes card's button: macOS's prompt the first time, then
    /// the System Audio pane with the guide beside it.
    func allowSystemAudio() {
        guard !needsMove, systemAudio != .granted else { return }
        switch systemAudio {
        case .denied:
            environment.openSettings(.systemAudio)
            guide(.systemAudio, SystemAudioPermission.dragIntoList ? .drag : .switchOn)
        case .unknown, .granted:
            systemAudioAsked = true
            environment.requestSystemAudio { [weak self] in self?.refresh(announce: true) }
        }
    }

    /// "Skip": meeting notes are not offered again.
    func skipNotes() {
        environment.defaults.set(true, forKey: Onboarding.notesSkippedKey)
        move(to: .done)
    }

    // MARK: Move to Applications

    func openApplicationsFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
    }

    func quit() {
        NSApp.terminate(nil)
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
        advance(from: current, to: OnboardingFlow.stepAfterEngine(current: current, ready: state == .ready, grants: grants, offerNotes: offerNotes))
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
        if !SpeechEngine.modelIsComplete { parts.append("the English speech model (about 190 MB)") }
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
        guard step == .tryIt, !tryItSucceeded, TryIt.arrived(baseline: tryItBaseline, practice: practice) else { return }
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

// MARK: - --onboardingshot

extension OnboardingController {
    /// `--onboardingshot`: draws every setup step, and the stale-grant,
    /// engine, Try it, meeting notes and guide states, light and dark, to
    /// PNGs in `directory`, from fixed fake permission states, so the layout
    /// can be checked without a screen. Read-only: no permission is read or
    /// asked for, nothing is downloaded or saved.
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
                    let renderer = ImageRenderer(content: shot.view
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
    /// engine state it shows. The guide answers `guide`.
    private static func snapshotModel(
        mic: Permissions.MicrophoneStatus = .granted, ax: Bool = true, im: Bool = true,
        engineInstalled: Bool = true, olderGrants: Bool = false,
        audio: SystemAudioStatus = .unknown, location: AppLocation = .fine,
        guide: GuideOutcome = .shown
    ) -> OnboardingModel {
        let defaults = EphemeralDefaults()
        if olderGrants {
            // Grants from an older build mean setup was finished before.
            defaults.set(true, forKey: Onboarding.completedKey)
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
            reduceMotion: { true }, appName: "talkflow",
            systemAudio: { audio }, requestSystemAudio: { $0() },
            notesSupported: true, appLocation: location,
            showGuide: { _, done in done(guide) }, hideGuide: {})
        return OnboardingModel(startHotkey: { true }, environment: environment)
    }

    /// The model download part way, at a known speed (a 12-point gain over
    /// 30 seconds: about 2 minutes left at 42%).
    private static func downloading(_ model: OnboardingModel, _ fraction: Double = 0.42) {
        model.runEngineSetup()
        model.engineChanged(.working(EngineSetup.downloadingMessage, max(0, fraction - 0.12)), at: 0)
        model.engineChanged(.working(EngineSetup.downloadingMessage, fraction), at: 30)
    }

    /// The guide panel alone, on the window colour so its rounded card shows.
    @MainActor
    private static func guideShot(_ mode: GuideMode) -> AnyView {
        AnyView(
            GuidePanelView(request: GuideRequest(target: .accessibility, mode: mode), appName: "talkflow", snapshot: true)
                .frame(width: 280, height: 84)
                .padding(24)
                .background(Palette.window))
    }

    @MainActor
    private static func snapshotStates() -> [(name: String, view: AnyView)] {
        func make(_ name: String, _ model: OnboardingModel, _ configure: (OnboardingModel) -> Void) -> (name: String, view: AnyView) {
            configure(model)
            return (name, AnyView(OnboardingView(model: model, snapshot: true)))
        }
        func tryIt(_ configure: (OnboardingModel) -> Void) -> OnboardingModel {
            let model = snapshotModel()
            model.step = .tryIt
            model.hotkeyRunning = true
            model.engine = .ready
            configure(model)
            return model
        }
        return [
            make("welcome", snapshotModel(mic: .notDetermined, ax: false, im: false, engineInstalled: false)) {
                $0.step = .welcome
                downloading($0, 0.06)
            },
            make("move-to-applications", snapshotModel(location: .diskImage)) { $0.step = .welcome },
            make("after-update", snapshotModel(ax: false, im: false, olderGrants: true)) { $0.step = .accessibility },
            make("microphone", snapshotModel(mic: .notDetermined, ax: false, im: false, engineInstalled: false)) {
                $0.step = .microphone
                downloading($0, 0.12)
            },
            make("microphone-denied", snapshotModel(mic: .denied, ax: false, im: false)) {
                $0.step = .microphone
                $0.allow(.microphone)
            },
            make("accessibility", snapshotModel(ax: false, im: false, engineInstalled: false)) {
                $0.step = .accessibility
                downloading($0, 0.31)
            },
            make("accessibility-dragging", snapshotModel(ax: false, im: false, engineInstalled: false)) {
                $0.step = .accessibility
                $0.allow(.accessibility)
                downloading($0)
            },
            make("accessibility-fallback", snapshotModel(ax: false, im: false, engineInstalled: false, guide: .notFound)) {
                $0.step = .accessibility
                $0.allow(.accessibility)
                downloading($0)
            },
            make("accessibility-allowed", snapshotModel(im: false)) { $0.step = .accessibility },
            make("accessibility-reset-failed", snapshotModel(ax: false, im: false, olderGrants: true)) {
                $0.step = .accessibility
                $0.resetFailed = .accessibility
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
            make("try-it", tryIt { _ in }) { _ in },
            make("try-it-listening", tryIt { $0.pretendTryIt(fnDown: true) }) { _ in },
            make("try-it-success", tryIt {
                $0.practice = "Hello from talkflow, this is my first dictation."
                $0.pretendTryIt(pressedAgo: 1, succeeded: true)
            }) { _ in },
            make("try-it-hint", tryIt { $0.pretendTryIt(shownAgo: 40) }) { _ in },
            make("try-it-nothing-arrived", tryIt { $0.pretendTryIt(pressedAgo: 12, shownAgo: 30) }) { _ in },
            make("try-it-restart", snapshotModel()) {
                $0.step = .tryIt
                $0.needsRestart = true
            },
            make("meeting-notes", snapshotModel()) { $0.step = .meetingNotes },
            make("meeting-notes-denied", snapshotModel(audio: .denied)) {
                $0.step = .meetingNotes
                $0.allowSystemAudio()
            },
            make("meeting-notes-allowed", snapshotModel(audio: .granted)) { $0.step = .meetingNotes },
            make("done", snapshotModel()) { $0.step = .done },
            ("guide-drag", guideShot(.drag)),
            ("guide-switch-on", guideShot(.switchOn)),
        ]
    }
}
