import AppKit
import ServiceManagement
import SwiftUI

/// First-run setup: three macOS permissions, then the local speech engine, then
/// a place to try it. Shown automatically whenever something talkflow needs is
/// missing (so it also reappears if a permission is later revoked), and from the
/// menu bar at any time.
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

    /// The step after `step`, skipping permission steps that are already
    /// granted (there is nothing to do on them).
    static func nextNeeded(after step: OnboardingStep, grants: PermissionGrants) -> OnboardingStep {
        var candidate = step.next ?? .ready
        while grants.isGranted(candidate) == true, let next = candidate.next { candidate = next }
        return candidate
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
    static func stepAfterRefresh(current: OnboardingStep, before: PermissionGrants, now: PermissionGrants) -> OnboardingStep {
        guard before.isGranted(current) == false, now.isGranted(current) == true else { return current }
        return nextNeeded(after: current, grants: now)
    }
}

/// Where the model reads the permissions, the engine and its saved progress,
/// and how it asks for and resets permissions. `--streamtest` passes fakes
/// (so it never raises a real prompt or touches a real grant); the app uses
/// `live`.
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
        fnKeyHasSystemAction: { Permissions.fnKeyHasSystemAction }
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
}

final class OnboardingModel: ObservableObject {
    @Published var step: OnboardingStep = .welcome {
        didSet { saveProgress() }
    }
    @Published var microphone: Permissions.MicrophoneStatus
    @Published var accessibility: Bool
    @Published var inputMonitoring: Bool
    @Published var engine: EngineState = .checking
    @Published var hotkeyRunning = false
    @Published var needsRestart = false
    @Published var launchAtLogin = true
    @Published var practice = ""
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

    var bringToFront: () -> Void = {}
    var close: () -> Void = {}

    private let startHotkey: () -> Bool
    private let environment: OnboardingEnvironment
    private let history: PermissionHistory
    /// Permissions the user was sent to System Settings (or a prompt) for.
    @Published private(set) var settingsVisits: Set<Permissions.Service> = []
    private var timer: Timer?
    private var hotkeyAttempts = 0
    private var downloader: FileDownloader?
    private var setupRunning = false

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
            engineDone: engine == .ready || (step != .engine && engineInstalled))
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
            completed: defaults.bool(forKey: Onboarding.completedKey) || !history.isEmpty,
            saved: saved,
            grants: grants,
            engineInstalled: environment.engineInstalled()))
        let timer = Timer(timeInterval: 0.8, repeats: true) { [weak self] _ in self?.refresh(announce: true) }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        downloader?.cancel()
        downloader = nil
    }

    private func move(to newStep: OnboardingStep) {
        if step != newStep { step = newStep }
        if newStep == .engine { checkEngine() }
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
        let target = OnboardingFlow.stepAfterRefresh(current: current, before: before, now: grants)
        if target != current {
            if environment.advanceDelay <= 0 {
                move(to: target)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + environment.advanceDelay) { [weak self] in
                    // Not if the user has moved on (or back) in the meantime.
                    guard let self, self.step == current else { return }
                    self.move(to: target)
                }
            }
        }

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

    func goNext() {
        guard canContinue, let next = step.next else { return }
        move(to: next)
    }

    func goBack() {
        guard let previous = step.previous else { return }
        step = previous
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

    func checkEngine() {
        guard !setupRunning else { return }
        engine = .checking
        SpeechEngine.isResponding { [weak self] alive in
            DispatchQueue.main.async {
                guard let self, !self.setupRunning else { return }
                self.engine = alive ? .ready : .needsSetup
            }
        }
    }

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

    func runEngineSetup() {
        guard !setupRunning else { return }
        setupRunning = true
        engine = .working("Checking...", nil)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            func post(_ state: EngineState) { DispatchQueue.main.async { self.engine = state } }

            // 1. The whisper-server program.
            if SpeechEngine.serverBinary() == nil {
                guard SpeechEngine.brewBinary() != nil else {
                    self.finishSetup(.needsHomebrew)
                    return
                }
                post(.working("Installing the Whisper program with Homebrew. This can take a few minutes.", nil))
                let result = SpeechEngine.installWhisperCpp { line in
                    post(.working("Installing the Whisper program with Homebrew...\n\(line)", nil))
                }
                guard result.succeeded, SpeechEngine.serverBinary() != nil else {
                    self.finishSetup(.failed("Homebrew could not install it.\n\(result.tail)"))
                    return
                }
            }

            // 2. The model.
            if !SpeechEngine.modelIsComplete {
                post(.working("Downloading the speech model (about 490 MB).", 0))
                let semaphore = DispatchSemaphore(value: 0)
                var failure: Error?
                let downloader = FileDownloader(
                    destination: SpeechEngine.modelPath,
                    minimumBytes: SpeechEngine.minimumModelBytes,
                    onProgress: { fraction in
                        post(.working("Downloading the speech model (about 490 MB).", fraction))
                    },
                    onFinish: { error in
                        failure = error
                        semaphore.signal()
                    }
                )
                DispatchQueue.main.async { self.downloader = downloader }
                downloader.start(url: SpeechEngine.modelDownloadURL)
                semaphore.wait()
                DispatchQueue.main.async { self.downloader = nil }
                if let failure {
                    self.finishSetup(.failed("The model download failed: \(failure.localizedDescription)"))
                    return
                }
            }

            // 3. Start it, and wait for the model to load.
            post(.working("Starting the speech engine...", nil))
            do { try SpeechEngine.startServer() } catch {
                self.finishSetup(.failed(error.localizedDescription))
                return
            }
            if SpeechEngine.waitUntilResponding(timeout: 90) {
                self.finishSetup(.ready)
            } else {
                self.finishSetup(.failed("The engine did not start. Its log is at ~/Library/Logs/TalkFlow/whisper-server.log"))
            }
        }
    }

    private func finishSetup(_ state: EngineState) {
        DispatchQueue.main.async {
            self.setupRunning = false
            self.engine = state
        }
    }
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

/// A drawn switch, so it matches the palette and also renders in
/// `--onboardingshot` (AppKit-backed controls draw as placeholders there).
private struct InkSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 12) {
                configuration.label
                Spacer(minLength: 8)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(configuration.isOn ? Color.ink : Color.ink.opacity(0.14))
                        .frame(width: 32, height: 19)
                    Circle()
                        .fill(Color.paper)
                        .frame(width: 15, height: 15)
                        .padding(2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

private struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    /// For `--onboardingshot`: the practice field is drawn instead of being
    /// a live text editor, which ImageRenderer cannot draw.
    var snapshot = false

    static let width: CGFloat = 560
    static let height: CGFloat = 680
    private let gutter: CGFloat = 36

    /// The steps in the progress bar; the welcome page comes before them.
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, gutter)
                .padding(.top, 34)
            progress
                .padding(.horizontal, gutter)
                .padding(.top, 22)
            hairline.padding(.top, 20)
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.horizontal, gutter)
            .padding(.top, 24)
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
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 5) {
                        node(mark)
                        Capsule()
                            .fill(barColor(mark))
                            .frame(height: 2)
                    }
                    Text(item.label)
                        .font(.system(size: 11, weight: item.step == model.step ? .semibold : .regular))
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
                Text("talkflow lives in your menu bar")
                    .font(.system(size: 12))
                    .foregroundColor(.graphite)
            default:
                Button("Back") { model.goBack() }
                    .buttonStyle(LinkButtonStyle(color: .graphite))
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
            permissionButton(.microphone, allowTitle: model.microphone == .denied ? "Open System Settings" : "Allow microphone")
        case .accessibility:
            permissionButton(.accessibility, allowTitle: "Allow accessibility")
        case .inputMonitoring:
            permissionButton(.inputMonitoring, allowTitle: "Allow input monitoring")
        case .engine:
            switch model.engine {
            case .needsSetup:
                Button("Set up speech engine") { model.runEngineSetup() }.buttonStyle(PrimaryButtonStyle())
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
                Button("Start using talkflow") { model.finish() }.buttonStyle(PrimaryButtonStyle())
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
            Button(allowTitle) { model.allow(service) }.buttonStyle(PrimaryButtonStyle())
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
                why: "So talkflow can hear you. Your voice is turned into text on your Mac by a local speech model. It is held in memory only, never saved, and never sent anywhere.",
                hint: model.microphone == .denied
                    ? "Microphone access was turned off. Open System Settings, find talkflow in the list and switch it on."
                    : "macOS asks once. Choose Allow in its dialog.",
                allowed: "talkflow can hear you.")
        case .accessibility:
            permission(
                .accessibility, title: "Accessibility",
                why: "So talkflow can type your words into the app you are using. This is how it finds the text field you have selected and writes into it.",
                hint: "In System Settings, find talkflow in the list and switch it on. If it is not listed, add it with the + button.",
                allowed: "talkflow can type into the app you are using.")
        case .inputMonitoring:
            permission(
                .inputMonitoring, title: "Input Monitoring",
                why: "So talkflow can tell when you press and hold the Fn key. It only listens for modifier keys such as Fn. It does not record what you type.",
                hint: "In System Settings, find talkflow in the list and switch it on.",
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

    private enum Tone { case good, waiting, idle, warn }

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
            paragraph("Hold the Fn key, speak, and let go. Your words appear in whatever you are typing in. The speech model runs on your Mac: no account, and your voice never leaves your computer.")
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
            case .accessibility: return ("Accessibility", "To notice Fn and type into your apps")
            case .inputMonitoring: return ("Input Monitoring", "To notice when you hold Fn")
            case .engine: return ("Speech engine", "A one-time download, about 490 MB")
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
            if step == .engine { return model.engineInstalled ? ("Installed", .good) : ("Needed", .graphite) }
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
                .foregroundColor(state.1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    // MARK: Permissions

    private func permission(_ service: Permissions.Service, title heading: String, why: String, hint: String, allowed: String) -> some View {
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
                        statusLine(.waiting, "Waiting for System Settings")
                        small(hint + " This page moves on by itself.")
                    } else {
                        statusLine(.idle, "Not allowed yet")
                        small(hint)
                    }
                    // Not before macOS has asked about the microphone: its
                    // own dialog is the whole step then. A denied microphone's
                    // main button already opens System Settings.
                    if service != .microphone || model.microphone == .denied {
                        HStack(spacing: 16) {
                            if service != .microphone {
                                Button("Open System Settings") { model.openSettings(service) }
                                    .buttonStyle(LinkButtonStyle())
                            }
                            Button("Already switched on?") { model.reportAlreadyOn(service) }
                                .buttonStyle(LinkButtonStyle())
                        }
                    }
                }
            }
            .padding(.top, 4)
        }
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
            paragraph("talkflow uses Whisper, an open speech model that runs entirely on your Mac. Setting it up is a one-time step and needs the internet only for the download.")
            panel {
                switch model.engine {
                case .checking:
                    statusLine(.waiting, "Checking...")
                case .ready:
                    statusLine(.good, "Speech engine is running")
                    small("Installed and answering on this Mac.")
                case .needsSetup:
                    statusLine(.idle, model.engineOnlyStopped ? "Not running" : "Not set up yet")
                    small(model.engineNeeds)
                case .working(let message, let fraction):
                    statusLine(.waiting, fraction.map { "Downloading... \(Int($0 * 100))%" } ?? "Working...")
                    if let fraction {
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.ink.opacity(0.1))
                                Capsule().fill(Color.ink).frame(width: max(6, geometry.size.width * CGFloat(fraction)))
                            }
                        }
                        .frame(height: 5)
                    }
                    small(message)
                        .lineLimit(4)
                case .needsHomebrew:
                    statusLine(.warn, "Homebrew is needed")
                    small("The Whisper program is installed with Homebrew, which is not on this Mac yet. Install it from brew.sh, then come back and press Try again.")
                    Button("Open brew.sh") { NSWorkspace.shared.open(URL(string: "https://brew.sh")!) }
                        .buttonStyle(LinkButtonStyle())
                case .failed(let message):
                    statusLine(.warn, "Setup did not finish")
                    small(message, color: .warn)
                        .lineLimit(7)
                    Text("Or in Terminal: brew install whisper-cpp")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.graphite)
                        .textSelection(.enabled)
                }
            }
            .padding(.top, 4)
        }
    }

    // MARK: Ready

    private var ready: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepEyebrow()
            title("You are all set.")
            paragraph("Click into any text field, hold Fn, speak, and let go. Try it here first:")
            practiceField
            panel {
                if model.needsRestart {
                    statusLine(.warn, "macOS needs talkflow to restart")
                    small("macOS applies the new permission when talkflow starts again. Press Restart talkflow, then hold Fn in any text field.")
                } else if model.hotkeyRunning {
                    statusLine(.good, "Fn key is listening")
                } else {
                    statusLine(.waiting, "Starting the Fn key listener...")
                }
                if model.fnKeyHasSystemAction {
                    hairline.padding(.vertical, 2)
                    small("If the emoji picker or system dictation opens when you press Fn, set \"Press the globe key to\" to \"Do Nothing\" in Keyboard settings.")
                    Button("Open Keyboard settings") { Permissions.openKeyboardSettings() }
                        .buttonStyle(LinkButtonStyle())
                }
                if model.loginItemAvailable {
                    hairline.padding(.vertical, 2)
                    Toggle(isOn: $model.launchAtLogin) {
                        Text("Open talkflow when I log in").font(.system(size: 13))
                    }
                    .toggleStyle(InkSwitchStyle())
                }
            }
        }
    }

    @ViewBuilder
    private var practiceField: some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        ZStack(alignment: .topLeading) {
            if snapshot {
                Color.clear
            } else {
                TextEditor(text: $model.practice)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .padding(8)
            }
            if model.practice.isEmpty {
                Text("Hold Fn and say something...")
                    .font(.system(size: 14))
                    .foregroundColor(Color.graphite.opacity(0.7))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: 84)
        .background(shape.fill(Color.paper))
        .overlay(shape.stroke(Color.line, lineWidth: 1))
    }
}

// MARK: - --onboardingshot

extension OnboardingController {
    /// `--onboardingshot`: draws every setup step, and the stale-grant and
    /// engine states, light and dark, to PNGs in `directory`, from fixed fake
    /// permission states, so the layout can be checked without a screen.
    /// Read-only: no permission is read or asked for, nothing is saved.
    @MainActor
    static func renderSnapshots(to directory: URL) -> [URL] {
        _ = NSApplication.shared // the header reads NSApp's icon
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
    /// to an older build, which is what makes a missing one stale.
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
            fnKeyHasSystemAction: { true })
        return OnboardingModel(startHotkey: { true }, environment: environment)
    }

    @MainActor
    private static func snapshotStates() -> [(name: String, model: OnboardingModel)] {
        func make(_ name: String, _ model: OnboardingModel, _ configure: (OnboardingModel) -> Void) -> (String, OnboardingModel) {
            configure(model)
            return (name, model)
        }
        return [
            make("welcome", snapshotModel(mic: .notDetermined, ax: false, im: false, engineInstalled: false)) { $0.step = .welcome },
            make("welcome-after-update", snapshotModel(ax: false, im: false, olderGrants: true)) { $0.step = .welcome },
            make("microphone", snapshotModel(mic: .notDetermined, ax: false, im: false)) { $0.step = .microphone },
            make("microphone-denied", snapshotModel(mic: .denied, ax: false, im: false)) { $0.step = .microphone },
            make("accessibility", snapshotModel(ax: false, im: false)) { $0.step = .accessibility },
            make("accessibility-waiting", snapshotModel(ax: false, im: false)) {
                $0.step = .accessibility
                $0.allow(.accessibility)
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
                $0.engine = .working("Downloading the speech model (about 490 MB).", 0.42)
            },
            make("engine-failed", snapshotModel(engineInstalled: false)) {
                $0.step = .engine
                $0.engine = .failed("The model download failed: The network connection was lost.")
            },
            make("engine-ready", snapshotModel()) {
                $0.step = .engine
                $0.engine = .ready
            },
            make("ready", snapshotModel()) {
                $0.step = .ready
                $0.hotkeyRunning = true
            },
            make("ready-restart", snapshotModel()) {
                $0.step = .ready
                $0.needsRestart = true
            },
        ]
    }
}
