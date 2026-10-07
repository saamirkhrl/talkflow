import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hotkey = HotkeyMonitor()
    private let overlay = OverlayController()
    private let dashboard = DashboardController()
    private var statusBar: StatusBar!
    private var dictation: Dictation!
    /// Made the first time setup is shown, and kept (with its engine
    /// download) after its window closes.
    private var onboardingController: OnboardingController?
    private var onboarding: OnboardingController {
        if let onboardingController { return onboardingController }
        let controller = OnboardingController(startHotkey: { [weak self] in self?.hotkey.start() ?? false })
        onboardingController = controller
        return controller
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // First, so a reinstall has the user's settings before anything reads them.
        UserData.start()
        statusBar = StatusBar()
        statusBar.onDashboardClicked = { [weak self] in self?.dashboard.show() }
        statusBar.onSetupClicked = { [weak self] in self?.onboarding.show() }

        dictation = Dictation(overlay: overlay, statusBar: statusBar)

        // Setup's Try it page shows when Fn is held (only if setup exists).
        hotkey.onStart = { [weak self] in
            self?.dictation.begin()
            self?.onboardingController?.model.fnChanged(down: true)
        }
        hotkey.onStop = { [weak self] in
            self?.dictation.finish()
            self?.onboardingController?.model.fnChanged(down: false)
        }

        // Which build each working permission belongs to, so after the next
        // update setup can tell a stale grant from a missing one.
        PermissionHistory.recordCurrent()

        // When setup is needed the hotkey is started by the setup window, once
        // it has explained why Accessibility is wanted (which also lets the
        // event tap see Fn). Creating the event tap first would make macOS
        // raise its own permission prompt with no context.
        // A first-run setup that macOS interrupted with a relaunch (after a
        // grant) opens again too, on the step it had reached.
        if Onboarding.opensOnLaunch(allGranted: Permissions.allGranted, engineInstalled: SpeechEngine.isInstalled,
                                    interrupted: Onboarding.wasInterrupted(), forced: CommandLine.arguments.contains("--onboarding")) {
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

    /// Clicking the Dock icon, which exists while setup is open (it makes
    /// the app regular so it can be found again behind System Settings).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let onboardingController, onboardingController.model.isActive { onboardingController.show() } else { dashboard.show() }
        return true
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
