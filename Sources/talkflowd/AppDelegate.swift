import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Computed, so the listener is made after `UserData.start()` has
    /// restored a reinstall's shortcut, not when this delegate is.
    private var hotkey: HotkeyMonitor { HotkeyMonitor.shared }
    private let overlay = OverlayController()
    /// Made on first use, after `UserData.start()` has restored a
    /// reinstall's settings, so the window reads the restored ones.
    /// The Notes section's state. Owned here, not by the window, so a meeting keeps recording when the window is
    /// closed and the menu bar can stop it. Made on first use, after UserData.start().
    private lazy var notes = NotesModel.live()
    private lazy var dashboard = DashboardController(notes: notes)
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
        installEditMenu()
        statusBar = StatusBar()
        statusBar.onDashboardClicked = { [weak self] in self?.dashboard.show() }
        statusBar.onSetupClicked = { [weak self] in self?.onboarding.show() }
        // Setup is done once. The menu only offers it again when something
        // is missing (most often a permission an update left behind) or the
        // shortcut cannot be heard, or while setup is still open.
        statusBar.setupNeeded = { [weak self] in
            Onboarding.needsSetup() || !(self?.hotkey.isRunning ?? true)
                || self?.onboardingController?.model.isActive == true
        }

        dictation = Dictation(overlay: overlay, statusBar: statusBar)
        // The window and the Dock icon never take focus mid-dictation (DockIcon).
        DockIcon.isDictating = { [weak self] in self?.statusBar.isBusy ?? false }
        statusBar.onStateChange = { state in if state == .idle { DockIcon.dictationEnded() } }
        statusBar.onSettingsClicked = { [weak self] in self?.dashboard.show(.settings) }
        // The menu bar shows a meeting being recorded and can stop it, window open or not.
        notes.onRecordingChange = { [weak self] on in self?.statusBar.setMeetingRecording(on) }
        statusBar.onStopMeeting = { [weak self] in self?.notes.stop() }
        // Finds recordings an earlier run left unfinished; the Notes page offers to finish or delete them.
        notes.refresh()
        dashboard.setupNeeded = statusBar.setupNeeded
        dashboard.openSetup = { [weak self] in self?.onboarding.show() }

        // Setup's Try it page shows when the shortcut is held (only if setup exists).
        hotkey.onStart = { [weak self] in
            self?.dictation.begin()
            self?.onboardingController?.model.fnChanged(down: true)
        }
        hotkey.onStop = { [weak self] in
            self?.dictation.finish()
            self?.onboardingController?.model.fnChanged(down: false)
        }
        // Another key while the shortcut is held: an app shortcut, not a dictation.
        hotkey.onInterrupt = { [weak self] in
            self?.dictation.abandon()
            self?.onboardingController?.model.fnChanged(down: false)
        }

        // Which build each working permission belongs to, so after the next
        // update setup can tell a stale grant from a missing one.
        PermissionHistory.recordCurrent()

        // When setup is needed the hotkey is started by the setup window, once
        // it has explained why Accessibility is wanted (which also lets the
        // event tap see the shortcut). Creating the event tap first would make macOS
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

        DispatchQueue.global(qos: .utility).async {
            SpeechEngine.prepareOnLaunch()
            DispatchQueue.main.async { LiveModel.prepare() }
        }
        FinalPassEngine.prepare()
        startUpdateChecks()
        stopOnSIGTERM()
        print("talkflowd: ready. Hold \(Preferences.hotkey.name) to dictate.")
    }

    /// A menu bar app has no menus of its own, and text fields only get
    /// Cmd+X/C/V/A and undo through a main menu's key equivalents. Never shown
    /// (the app is an accessory), so it only makes those shortcuts work in the
    /// dashboard's and setup's fields, such as pasting an API key.
    private func installEditMenu() {
        EditMenu.install()
    }

    /// Shortly after launch when online, then every few hours. A newer version
    /// shows as a menu bar item and one notification; both open the dashboard,
    /// where installing is still a click.
    @MainActor
    private func startUpdateChecks() {
        statusBar.onUpdateClicked = { [weak self] in self?.dashboard.show(.settings, anchor: .about) }
        UpdateNotice.shared.onOpen = { [weak self] in self?.dashboard.show(.settings, anchor: .about) }
        UpdateNotice.shared.start()
        Updater.shared.onAvailabilityChange = { [weak self] version in self?.statusBar.setUpdate(version: version) }
        Updater.shared.startBackgroundChecks()
        // Release builds only: one empty POST, once per install (docs/telemetry.md).
        InstallCounter.startWhenOnline()
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
            self?.notes.appWillTerminate()
            self?.dictation?.abandon()
            FinalPassEngine.stop()
            exit(0)
        }
        source.resume()
        termination = source
    }

    func applicationWillTerminate(_ notification: Notification) {
        notes.appWillTerminate()
        dictation?.abandon()
        FinalPassEngine.stop()
    }
}
