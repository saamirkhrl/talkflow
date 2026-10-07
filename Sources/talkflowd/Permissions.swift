import ApplicationServices
import AppKit
import AVFoundation
import CoreGraphics
import IOKit.hid
import Security

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

    // MARK: - Grants that no longer apply

    /// The permissions by the names `tccutil` uses.
    enum Service: String, CaseIterable {
        case microphone = "Microphone"
        case accessibility = "Accessibility"
        case inputMonitoring = "ListenEvent"

        var pane: Pane {
            switch self {
            case .microphone: return .microphone
            case .accessibility: return .accessibility
            case .inputMonitoring: return .inputMonitoring
            }
        }
    }

    /// Whether macOS has ever been asked about Input Monitoring for this app.
    /// Its prompt appears only the first time; after that only System
    /// Settings can change it.
    static var inputMonitoringAsked: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeUnknown
    }

    /// This build's designated requirement, as text. macOS stores the
    /// requirement of the copy a permission was granted to and checks every
    /// later copy against it. An ad-hoc signature's requirement is its own
    /// cdhash, so each release (and each update the updater signs ad hoc) is
    /// a new app to macOS: System Settings keeps showing the old entry
    /// switched on while this copy is not trusted. See docs/signing.md.
    static let designatedRequirement: String? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement else { return nil }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return nil }
        return text as String
    }()

    /// Arguments for `/usr/bin/tccutil` that reset one permission for one
    /// app. Nil unless `bundleID` is a plain reverse-DNS identifier: without
    /// one, `tccutil reset <service>` resets that permission for every app on
    /// the Mac, which must never happen from here.
    static func tccResetArguments(_ service: Service, bundleID: String?) -> [String]? {
        guard let bundleID, bundleID.contains("."), !bundleID.hasPrefix("."), !bundleID.hasSuffix("."),
              bundleID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else { return nil }
        return ["reset", service.rawValue, bundleID]
    }

    /// Removes talkflow's entry for one permission, so macOS asks again and
    /// records this copy. Only this app's bundle identifier, never all apps.
    /// Calls back on the main thread with whether tccutil succeeded.
    static func resetGrant(_ service: Service, completion: @escaping (Bool) -> Void) {
        guard let arguments = tccResetArguments(service, bundleID: Bundle.main.bundleIdentifier) else {
            completion(false)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            var succeeded = false
            if (try? process.run()) != nil {
                process.waitUntilExit()
                succeeded = process.terminationStatus == 0
            }
            print("talkflowd: tccutil \(arguments.joined(separator: " ")) -> \(succeeded ? "ok" : "failed")")
            DispatchQueue.main.async { completion(succeeded) }
        }
    }
}

/// Why a permission that is not working looks like it was granted to an
/// older copy of talkflow rather than never given.
enum StaleReason: Equatable {
    /// It was granted to a build with a different signature (an update).
    case appChanged
    /// The user says it is switched on in System Settings.
    case userSaysOn
    /// The user went to System Settings for it, came back, and it still
    /// does not apply.
    case backFromSettings
}

enum GrantStatus: Equatable {
    case granted
    case missing
    case stale(StaleReason)

    var isStale: Bool { if case .stale = self { return true } else { return false } }

    /// What talkflow can know about one permission, since System Settings'
    /// own list cannot be read. Pure, for `--streamtest`.
    static func classify(trusted: Bool, grantedTo: String?, current: String?, userSaysOn: Bool, backFromSettings: Bool) -> GrantStatus {
        if trusted { return .granted }
        if userSaysOn { return .stale(.userSaysOn) }
        if let grantedTo, let current, grantedTo != current { return .stale(.appChanged) }
        if backFromSettings { return .stale(.backFromSettings) }
        return .missing
    }
}

/// The designated requirement each permission was last seen granted to,
/// so a later build can tell that a grant belongs to an older copy.
struct PermissionHistory {
    let defaults: UserDefaults

    private func key(_ service: Permissions.Service) -> String { "grantedTo.\(service.rawValue)" }

    func grantedTo(_ service: Permissions.Service) -> String? {
        defaults.string(forKey: key(service))
    }

    var isEmpty: Bool { Permissions.Service.allCases.allSatisfy { grantedTo($0) == nil } }

    func record(_ service: Permissions.Service, granted: Bool, requirement: String?) {
        guard granted, let requirement, grantedTo(service) != requirement else { return }
        defaults.set(requirement, forKey: key(service))
    }

    func forget(_ service: Permissions.Service) {
        defaults.removeObject(forKey: key(service))
    }

    /// At launch, so a grant made before this build is known about when the
    /// next update arrives.
    static func recordCurrent() {
        let history = PermissionHistory(defaults: .standard)
        let requirement = Permissions.designatedRequirement
        history.record(.microphone, granted: Permissions.microphone == .granted, requirement: requirement)
        history.record(.accessibility, granted: Permissions.accessibility, requirement: requirement)
        history.record(.inputMonitoring, granted: Permissions.inputMonitoring, requirement: requirement)
    }
}
