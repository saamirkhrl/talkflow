import ApplicationServices
import AppKit
import AVFoundation
import CoreGraphics

/// The three things macOS makes the user approve before talkflow can work, and
/// the deep links to the System Settings pane for each.
enum Permissions {
    enum MicrophoneStatus {
        case notDetermined, granted, denied
    }

    enum Pane: String {
        case microphone = "Privacy_Microphone"
        case accessibility = "Privacy_Accessibility"
        case inputMonitoring = "Privacy_ListenEvent"
    }

    static var microphone: MicrophoneStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    /// Needed to read the focused text field and write into it.
    static var accessibility: Bool { AXIsProcessTrusted() }

    /// Needed for the Fn-key event tap.
    static var inputMonitoring: Bool { CGPreflightListenEventAccess() }

    static var allGranted: Bool {
        microphone == .granted && accessibility && inputMonitoring
    }

    static func requestMicrophone(completion: @escaping () -> Void = {}) {
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            DispatchQueue.main.async(execute: completion)
        }
    }

    /// Shows the system's own dialog, which lists the app and offers to open
    /// System Settings. It only appears once per app; after that the user has to
    /// go to the pane, which is why the setup window also links there directly.
    static func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
    }

    static func openSettings(_ pane: Pane) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)")!
        NSWorkspace.shared.open(url)
    }

    static func openKeyboardSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }

    /// macOS's "Press the globe key to" setting. 0 is "Do Nothing"; anything else,
    /// including unset (the default), can pop up the emoji picker or start system
    /// dictation when Fn is held, on top of whatever talkflow does.
    static var fnKeyHasSystemAction: Bool {
        let value = UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int
        return value != 0
    }
}
