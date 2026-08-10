import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hotkey = HotkeyMonitor()
    private let overlay = OverlayController()
    private let dashboard = DashboardController()
    private var statusBar: StatusBar!
    private var dictation: Dictation!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBar = StatusBar()
        statusBar.onDashboardClicked = { [weak self] in self?.dashboard.show() }

        dictation = Dictation(overlay: overlay, statusBar: statusBar)

        hotkey.onStart = { [weak self] in self?.dictation.begin() }
        hotkey.onStop = { [weak self] in self?.dictation.finish() }
        hotkey.start()

        print("talkflowd: ready. Hold Fn to dictate.")
    }

    func applicationWillTerminate(_ notification: Notification) {
        dictation?.abandon()
    }
}
