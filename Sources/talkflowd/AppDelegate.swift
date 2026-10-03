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
        print("talkflowd: ready. Hold Fn to dictate.")
    }

    func applicationWillTerminate(_ notification: Notification) {
        dictation?.abandon()
        FinalPassEngine.stop()
    }
}
