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
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: OnboardingView(model: model))
        model.bringToFront = { [weak self] in self?.show() }
        model.close = { [weak self] in self?.window?.close() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        model.start()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        model.stop()
    }
}

enum Onboarding {
    static let completedKey = "onboardingCompleted"

    /// Whether to open the setup window on launch: only when something is
    /// actually missing. A Mac that already has every permission and a working
    /// speech engine never sees it.
    static func needsSetup() -> Bool {
        !Permissions.allGranted || !SpeechEngine.isInstalled
    }
}

// MARK: - Model

enum OnboardingStep: Int, CaseIterable {
    case welcome, microphone, accessibility, inputMonitoring, engine, ready

    var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
    var previous: OnboardingStep? { OnboardingStep(rawValue: rawValue - 1) }
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
    @Published var step: OnboardingStep = .welcome
    @Published var microphone = Permissions.microphone
    @Published var accessibility = Permissions.accessibility
    @Published var inputMonitoring = Permissions.inputMonitoring
    @Published var engine: EngineState = .checking
    @Published var hotkeyRunning = false
    @Published var needsRestart = false
    @Published var launchAtLogin = true
    @Published var practice = ""

    var bringToFront: () -> Void = {}
    var close: () -> Void = {}

    private let startHotkey: () -> Bool
    private var timer: Timer?
    private var hotkeyAttempts = 0
    private var downloader: FileDownloader?
    private var setupRunning = false

    /// A build made for testing setup alongside a working install must not
    /// register itself as a login item.
    let loginItemAvailable: Bool =
        (Bundle.main.object(forInfoDictionaryKey: "TalkflowDisableLoginItem") as? Bool) != true

    init(startHotkey: @escaping () -> Bool) {
        self.startHotkey = startHotkey
    }

    func start() {
        // Pick up where the user needs to be: the welcome screen on a first run,
        // otherwise the first thing still missing.
        if UserDefaults.standard.bool(forKey: Onboarding.completedKey) {
            step = firstMissingStep() ?? .welcome
        } else {
            step = .welcome
        }
        refresh(announce: false)
        if step == .engine { checkEngine() }
        timer?.invalidate()
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

    private func firstMissingStep() -> OnboardingStep? {
        if microphone != .granted { return .microphone }
        if !accessibility { return .accessibility }
        if !inputMonitoring { return .inputMonitoring }
        if !SpeechEngine.isInstalled { return .engine }
        return nil
    }

    /// Re-reads the permission state. macOS gives no callback when the user flips
    /// a switch in System Settings, so this polls; when something becomes granted
    /// the window comes forward again, because the user is looking at Settings.
    private func refresh(announce: Bool) {
        let mic = Permissions.microphone
        let ax = Permissions.accessibility
        let im = Permissions.inputMonitoring
        let gained = (mic == .granted && microphone != .granted)
            || (ax && !accessibility)
            || (im && !inputMonitoring)
        microphone = mic
        accessibility = ax
        inputMonitoring = im
        if gained && announce { bringToFront() }

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
        step = next
        if next == .engine { checkEngine() }
    }

    func goBack() {
        guard let previous = step.previous else { return }
        step = previous
    }

    func finish() {
        UserDefaults.standard.set(true, forKey: Onboarding.completedKey)
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

    func requestMicrophone() {
        switch microphone {
        case .notDetermined: Permissions.requestMicrophone { [weak self] in self?.refresh(announce: true) }
        case .denied: Permissions.openSettings(.microphone)
        case .granted: break
        }
    }

    func requestAccessibility() {
        Permissions.requestAccessibility()
    }

    func requestInputMonitoring() {
        Permissions.requestInputMonitoring()
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

    static let paper = Color(light: 0xF5F5F3, dark: 0x1F1E22)
    static let ink = Color(light: 0x1F1E22, dark: 0xF5F5F3)
    static let graphite = Color(light: 0x5F5E66, dark: 0xA9A8AF)
    static let line = Color.ink.opacity(0.12)
    static let good = Color(light: 0x2F7D4F, dark: 0x5FBF86)
    static let warn = Color(light: 0xB4541A, dark: 0xE8955A)
}

private struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.paper)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.ink.opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.25)))
    }
}

private struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundColor(.ink)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .overlay(Capsule().stroke(Color.line, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

private struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Spacer(minLength: 16)
            content
            Spacer(minLength: 16)
            footer
        }
        .padding(.horizontal, 40)
        .padding(.top, 44)
        .padding(.bottom, 28)
        .frame(width: 520, height: 640)
        .background(Color.paper)
        .foregroundColor(.ink)
    }

    // MARK: Header and footer

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 26, height: 26)
            Text("talkflow")
                .font(.system(size: 15, weight: .medium))
            Spacer()
            HStack(spacing: 6) {
                ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                    Circle()
                        .fill(step.rawValue <= model.step.rawValue ? Color.ink : Color.ink.opacity(0.18))
                        .frame(width: 6, height: 6)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if model.step != .welcome && model.step != .ready {
                Button("Back") { model.goBack() }
                    .buttonStyle(SecondaryButtonStyle())
            }
            Spacer()
            switch model.step {
            case .welcome:
                Button("Get started") { model.goNext() }.buttonStyle(PrimaryButtonStyle())
            case .ready:
                Button("Start using talkflow") { model.finish() }.buttonStyle(PrimaryButtonStyle())
            default:
                Button("Continue") { model.goNext() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!model.canContinue)
            }
        }
    }

    // MARK: Steps

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .welcome: welcome
        case .microphone:
            permission(
                symbol: "mic.fill", title: "Microphone",
                why: "So talkflow can hear you. Your voice is turned into text on your Mac by a local speech model. It is held in memory only, never saved, and never sent anywhere.",
                granted: model.microphone == .granted,
                hint: model.microphone == .denied
                    ? "Microphone access was turned off. Open System Settings, find talkflow in the list and switch it on."
                    : nil,
                actionTitle: model.microphone == .denied ? "Open System Settings" : "Allow microphone",
                action: { model.requestMicrophone() },
                settingsPane: nil)
        case .accessibility:
            permission(
                symbol: "accessibility", title: "Accessibility",
                why: "So talkflow can type your words into the app you are using. This is how it finds the text field you have selected and writes into it.",
                granted: model.accessibility,
                hint: "Click the button, then in System Settings find talkflow in the list and switch it on. If it is not listed, press the + button and add it.",
                actionTitle: "Allow accessibility",
                action: { model.requestAccessibility() },
                settingsPane: .accessibility)
        case .inputMonitoring:
            permission(
                symbol: "keyboard", title: "Input Monitoring",
                why: "So talkflow can tell when you press and hold the Fn key. It only listens for modifier keys such as Fn. It does not record what you type.",
                granted: model.inputMonitoring,
                hint: "Click the button, then in System Settings find talkflow in the list and switch it on.",
                actionTitle: "Allow input monitoring",
                action: { model.requestInputMonitoring() },
                settingsPane: .inputMonitoring)
        case .engine: engine
        case .ready: ready
        }
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 30, weight: .regular, design: .serif))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func body(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundColor(.graphite)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            title("Dictate anywhere on your Mac.")
            body("Hold the Fn key, speak, and let go. Your words appear in whatever you are typing in. Everything runs on your Mac: no account, no cloud, nothing leaves your computer.")
            VStack(alignment: .leading, spacing: 10) {
                bullet("1", "Three quick permissions")
                bullet("2", "A one-time download of the speech model")
                bullet("3", "A chance to try it right here")
            }
            .padding(.top, 6)
            body("This takes about two minutes.")
        }
    }

    private func bullet(_ number: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Text(number)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 22, height: 22)
                .overlay(Circle().stroke(Color.line, lineWidth: 1))
            Text(text).font(.system(size: 13))
        }
    }

    private func permission(
        symbol: String, title heading: String, why: String, granted: Bool, hint: String?,
        actionTitle: String, action: @escaping () -> Void, settingsPane: Permissions.Pane?
    ) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: symbol)
                .font(.system(size: 26))
                .frame(width: 56, height: 56)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.line, lineWidth: 1))
            title(heading)
            body(why)
            statusCard(granted: granted) {
                HStack(spacing: 10) {
                    Button(actionTitle, action: action).buttonStyle(PrimaryButtonStyle())
                    if let settingsPane {
                        Button("Open System Settings") { Permissions.openSettings(settingsPane) }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }
                if let hint {
                    Text(hint)
                        .font(.system(size: 12))
                        .foregroundColor(.graphite)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Shows a green "Allowed" row once granted; the call to action otherwise.
    private func statusCard<Actions: View>(granted: Bool, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.good)
            } else {
                actions()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.line, lineWidth: 1))
    }

    private var engine: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "cpu")
                .font(.system(size: 26))
                .frame(width: 56, height: 56)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.line, lineWidth: 1))
            title("Speech engine")
            body("talkflow uses Whisper, an open speech model that runs entirely on your Mac. Setting it up is a one-time step and needs the internet only for the download.")
            VStack(alignment: .leading, spacing: 12) {
                switch model.engine {
                case .checking:
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Checking...").font(.system(size: 13)).foregroundColor(.graphite)
                    }
                case .ready:
                    Label("Speech engine is running", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.good)
                case .needsSetup:
                    Text(model.engineNeeds)
                        .font(.system(size: 12)).foregroundColor(.graphite)
                    Button("Set up speech engine") { model.runEngineSetup() }
                        .buttonStyle(PrimaryButtonStyle())
                case .working(let message, let fraction):
                    if let fraction {
                        ProgressView(value: fraction)
                        Text("\(message) \(Int(fraction * 100))%")
                            .font(.system(size: 12)).foregroundColor(.graphite)
                    } else {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text(message)
                                .font(.system(size: 12)).foregroundColor(.graphite)
                                .lineLimit(4)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                case .needsHomebrew:
                    Text("The Whisper program is installed with Homebrew, which is not on this Mac yet. Install it from brew.sh, then come back and press Try again.")
                        .font(.system(size: 12)).foregroundColor(.graphite)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button("Open brew.sh") { NSWorkspace.shared.open(URL(string: "https://brew.sh")!) }
                            .buttonStyle(SecondaryButtonStyle())
                        Button("Try again") { model.runEngineSetup() }
                            .buttonStyle(PrimaryButtonStyle())
                    }
                case .failed(let message):
                    Text(message)
                        .font(.system(size: 12)).foregroundColor(.warn)
                        .lineLimit(7)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button("Try again") { model.runEngineSetup() }.buttonStyle(PrimaryButtonStyle())
                        Text("or in Terminal: brew install whisper-cpp")
                            .font(.system(size: 11, design: .monospaced)).foregroundColor(.graphite)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.line, lineWidth: 1))
        }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 16) {
            title("You are all set.")
            body("Click into any text field, hold Fn, speak, and let go. Try it here first:")
            TextEditor(text: $model.practice)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 92)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.ink.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.line, lineWidth: 1))

            if model.needsRestart {
                VStack(alignment: .leading, spacing: 8) {
                    Text("macOS needs talkflow to restart before the Fn key works.")
                        .font(.system(size: 12)).foregroundColor(.warn)
                    Button("Restart talkflow") { model.restartApp() }.buttonStyle(PrimaryButtonStyle())
                }
            } else if !model.hotkeyRunning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Starting the Fn key listener...").font(.system(size: 12)).foregroundColor(.graphite)
                }
            }

            if Permissions.fnKeyHasSystemAction {
                VStack(alignment: .leading, spacing: 8) {
                    Text("If the emoji picker or system dictation opens when you press Fn, set \"Press the globe key to\" to \"Do Nothing\" in Keyboard settings.")
                        .font(.system(size: 12)).foregroundColor(.graphite)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Keyboard settings") { Permissions.openKeyboardSettings() }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }

            if model.loginItemAvailable {
                Toggle("Open talkflow when I log in", isOn: $model.launchAtLogin)
                    .font(.system(size: 13))
            }
            body("talkflow lives in your menu bar. Use it to open your stats, reopen this setup, or quit.")
        }
    }
}
