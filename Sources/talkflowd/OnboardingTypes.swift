import Foundation

// Small shared types for setup: where the app runs from, the floating guide
// beside System Settings, and the system audio permission. Kept apart so the
// setup model, the guide panel and the self-tests all agree on them.

/// Where this copy of talkflow runs from. macOS ties a permission to the copy
/// it was given to, and a copy on the disk image or a translocated one (a
/// quarantined app opened where it was downloaded) is thrown away, so setup
/// asks for the move to Applications before anything else.
enum AppLocation: Equatable {
    case fine, diskImage, translocated

    var needsMove: Bool { self != .fine }

    /// Pure, for `--streamtest`. A bare `.build` binary (no `.app`) is always
    /// fine, so development runs are never blocked.
    static func classify(bundlePath: String, onReadOnlyVolume: Bool) -> AppLocation {
        var path = bundlePath
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        guard path.hasSuffix(".app") else { return .fine }
        if path.contains("/AppTranslocation/") { return .translocated }
        if onReadOnlyVolume { return .diskImage }
        return .fine
    }

    /// This copy, read once.
    static let current: AppLocation = {
        let url = Bundle.main.bundleURL
        let readOnly = (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        return classify(bundlePath: url.path, onReadOnlyVolume: readOnly)
    }()
}

/// The permission the guide panel is helping with.
enum GuideTarget: Hashable {
    case accessibility, microphone, systemAudio

    var pane: Permissions.Pane {
        switch self {
        case .accessibility: return .accessibility
        case .microphone: return .microphone
        case .systemAudio: return .systemAudio
        }
    }
}

/// What the panel asks for: drag the icon into the list, or switch on the
/// entry that is already there (after a denied prompt).
enum GuideMode: Equatable {
    case drag, switchOn
}

struct GuideRequest: Equatable {
    var target: GuideTarget
    var mode: GuideMode
}

/// Reported once per request: the panel found System Settings and is docked
/// beside it, or it could not find the window in time (setup then falls back
/// to the open-the-pane-and-switch-it-on flow).
enum GuideOutcome: Equatable {
    case shown, notFound
}

/// System Audio Recording (Screen & System Audio Recording). `unknown` is
/// both "not asked yet" and "cannot tell".
enum SystemAudioStatus: Equatable {
    case unknown, granted, denied
}
