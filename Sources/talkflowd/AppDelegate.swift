import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hotkey = HotkeyMonitor()
    private let overlay = OverlayController()
    private let dashboard = DashboardController()
    private var statusBar: StatusBar!
    private var dictation: Dictation!
    private lazy var onboarding = OnboardingController(startHotkey: { [weak self] in self?.hotkey.start() ?? false })

    func applicationDidFinishLaunching(_ notification: Notification) {
        // First, so a reinstall has the user's settings before anything reads them.
        UserData.start()
        statusBar = StatusBar()
        statusBar.onDashboardClicked = { [weak self] in self?.dashboard.show() }
        statusBar.onSetupClicked = { [weak self] in self?.onboarding.show() }

        dictation = Dictation(overlay: overlay, statusBar: statusBar)

        hotkey.onStart = { [weak self] in self?.dictation.begin() }
        hotkey.onStop = { [weak self] in self?.dictation.finish() }

        // When setup is needed the hotkey is started by the setup window, once
        // it has explained why Input Monitoring is wanted. Creating the event tap
        // first would make macOS raise its own permission prompt with no context.
        if CommandLine.arguments.contains("--onboarding") || Onboarding.needsSetup() {
            print("talkflowd: opening setup")
            onboarding.show()
        } else {
            hotkey.start()
        }

        FinalPassEngine.start()
        startUpdateChecks()
        stopOnSIGTERM()
        print("talkflowd: ready. Hold Fn to dictate.")
    }

    /// Shortly after launch when online, then every few hours. A newer version
    /// shows as a menu bar item and one notification; both open the dashboard,
    /// where installing is still a click.
    @MainActor
    private func startUpdateChecks() {
        statusBar.onUpdateClicked = { [weak self] in self?.dashboard.show() }
        UpdateNotice.shared.onOpen = { [weak self] in self?.dashboard.show() }
        UpdateNotice.shared.start()
        Updater.shared.onAvailabilityChange = { [weak self] version in self?.statusBar.setUpdate(version: version) }
        Updater.shared.startBackgroundChecks()
    }

    private var termination: DispatchSourceSignal?

    /// launchd and deploy.sh stop talkflow with SIGTERM, which ends the
    /// process without `applicationWillTerminate`, so the final-pass server
    /// it started would be left running. Caught here instead.
    private func stopOnSIGTERM() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            self?.dictation?.abandon()
            FinalPassEngine.stop()
            exit(0)
        }
        source.resume()
        termination = source
    }

    func applicationWillTerminate(_ notification: Notification) {
        dictation?.abandon()
        FinalPassEngine.stop()
    }
}
