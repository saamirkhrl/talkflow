import AppKit
import UserNotifications

/// One macOS notification per new version, saying an update is available.
///
/// Permission is asked the first time there is something to say, not at
/// launch. If it is refused, the "Update to X.Y.Z..." item in the menu bar
/// icon's right-click menu is the only sign. Clicking the notification opens the
/// talkflow window, where the Update button is; nothing is installed without
/// that click.
final class UpdateNotice: NSObject, UNUserNotificationCenterDelegate {
    static let shared = UpdateNotice()
    private static let notifiedKey = "updateNotifiedVersion"
    private static let identifierPrefix = "talkflow-update-"

    /// Opens the talkflow window; set by AppDelegate.
    var onOpen: (() -> Void)?

    /// UNUserNotificationCenter raises an exception in a process that is not
    /// running from an app bundle (`swift run`, the self-tests), so there is
    /// no notification there.
    private var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return .current()
    }

    /// At launch, so a click on a notification posted by an earlier run
    /// still opens the talkflow window. Asks for nothing.
    func start() {
        center?.delegate = self
    }

    /// Main thread. Remembers the version first, so it is announced once
    /// whatever the user answers.
    func announce(version: String) {
        guard let center, UserDefaults.standard.string(forKey: Self.notifiedKey) != version else { return }
        UserDefaults.standard.set(version, forKey: Self.notifiedKey)
        center.delegate = self
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "talkflow \(version) is available"
            content.body = "Open talkflow to update. Nothing installs until you click Update."
            let request = UNNotificationRequest(identifier: Self.identifierPrefix + version, content: content, trigger: nil)
            center.add(request) { error in
                if let error { print("talkflowd: update notification failed: \(error.localizedDescription)") }
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.identifier.hasPrefix(Self.identifierPrefix) {
            DispatchQueue.main.async { self.onOpen?() }
        }
        completionHandler()
    }

    /// Shown even while talkflow is the active app (the talkflow window is open).
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }
}
