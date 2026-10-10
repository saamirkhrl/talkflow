import ApplicationServices
import CoreGraphics
import Foundation

/// The hold-to-dictate shortcut: modifier keys that must all be held, each
/// group satisfied by any of its keys (left or right Option, say). Fn by
/// default. Only modifier keys, so the listen-only event tap never has to
/// hold back a keystroke from the app being typed into.
struct HotkeySpec: Hashable {
    /// A modifier key, by its virtual keycode.
    enum Key: Int, CaseIterable {
        case fn = 63
        case leftControl = 59, rightControl = 62
        case leftOption = 58, rightOption = 61
        case leftShift = 56, rightShift = 60
        case leftCommand = 55, rightCommand = 54

        /// macOS's own order for modifiers (Control, Option, Shift, Command), Fn first.
        var rank: Int {
            switch self {
            case .fn: return 0
            case .leftControl, .rightControl: return 1
            case .leftOption, .rightOption: return 2
            case .leftShift, .rightShift: return 3
            case .leftCommand, .rightCommand: return 4
            }
        }

        /// Both keys of this one's kind (just Fn for Fn).
        var family: [Key] {
            switch self {
            case .fn: return [.fn]
            case .leftControl, .rightControl: return [.leftControl, .rightControl]
            case .leftOption, .rightOption: return [.leftOption, .rightOption]
            case .leftShift, .rightShift: return [.leftShift, .rightShift]
            case .leftCommand, .rightCommand: return [.leftCommand, .rightCommand]
            }
        }

        var familyName: String {
            switch self {
            case .fn: return "Fn"
            case .leftControl, .rightControl: return "Control"
            case .leftOption, .rightOption: return "Option"
            case .leftShift, .rightShift: return "Shift"
            case .leftCommand, .rightCommand: return "Command"
            }
        }

        var name: String {
            switch self {
            case .fn: return "Fn"
            case .leftControl, .leftOption, .leftShift, .leftCommand: return "Left " + familyName
            case .rightControl, .rightOption, .rightShift, .rightCommand: return "Right " + familyName
            }
        }

        /// The device-dependent flag bit (NX_DEVICE*KEYMASK) that says which
        /// side is down; nil for Fn.
        var deviceMask: UInt64? {
            switch self {
            case .fn: return nil
            case .leftControl: return 0x0001
            case .leftShift: return 0x0002
            case .rightShift: return 0x0004
            case .leftCommand: return 0x0008
            case .rightCommand: return 0x0010
            case .leftOption: return 0x0020
            case .rightOption: return 0x0040
            case .rightControl: return 0x2000
            }
        }

        var familyMask: CGEventFlags {
            switch self {
            case .fn: return .maskSecondaryFn
            case .leftControl, .rightControl: return .maskControl
            case .leftOption, .rightOption: return .maskAlternate
            case .leftShift, .rightShift: return .maskShift
            case .leftCommand, .rightCommand: return .maskCommand
            }
        }

        static let allDeviceMasks: UInt64 = allCases.compactMap(\.deviceMask).reduce(0, |)

        /// Whether this key is down, from a flagsChanged event's flags. Events
        /// without the side bits (some synthetic ones) fall back to the
        /// left-or-right flag.
        func isDown(in flags: CGEventFlags) -> Bool {
            guard let deviceMask else { return flags.contains(.maskSecondaryFn) }
            if flags.rawValue & Self.allDeviceMasks == 0 { return flags.contains(familyMask) }
            return flags.rawValue & deviceMask != 0
        }
    }

    let groups: [[Key]]

    static let fn = HotkeySpec(groups: [[.fn]])

    static let presets: [HotkeySpec] = [
        .fn,
        HotkeySpec(groups: [[.rightOption]]),
        HotkeySpec(groups: [[.rightCommand]]),
        HotkeySpec(groups: [Key.leftControl.family, Key.leftOption.family]),
    ]

    var keys: Set<Key> { Set(groups.joined()) }

    var usesFn: Bool { keys.contains(.fn) }

    /// "Fn", "Right Option", "Control + Option".
    var name: String {
        groups.map { group in
            group.count == 1 ? group[0].name : group[0].familyName
        }.joined(separator: " + ")
    }

    /// For a sentence: "the Fn key", otherwise the name.
    var phrase: String { self == .fn ? "the Fn key" : name }

    /// Every group has a key down, and nothing else is: Command + Right Option
    /// is someone's app shortcut, not a dictation on Right Option.
    func isSatisfied(by held: Set<Key>) -> Bool {
        groups.allSatisfy { group in group.contains(where: held.contains) } && held.isSubset(of: keys)
    }

    /// The shortcut for keys that were held together while recording. A
    /// right-hand key on its own stays that side only (Right Option);
    /// otherwise either side counts (Control + Option).
    static func fromRecorded(_ recorded: Set<Key>) -> HotkeySpec? {
        guard !recorded.isEmpty else { return nil }
        if recorded.count == 1, let key = recorded.first, key.name.hasPrefix("Right") {
            return HotkeySpec(groups: [[key]])
        }
        var groups: [[Key]] = []
        for key in recorded.sorted(by: { $0.rank < $1.rank }) where !groups.contains(key.family) {
            groups.append(key.family)
        }
        return HotkeySpec(groups: groups)
    }

    /// Stored as keycodes: [[58, 61], [59, 62]].
    var stored: [[Int]] { groups.map { $0.map(\.rawValue) } }

    init(groups: [[Key]]) {
        self.groups = groups
    }

    init?(stored: [[Int]]) {
        let groups = stored.map { $0.compactMap(Key.init(rawValue:)) }
        guard !groups.isEmpty, groups.allSatisfy({ !$0.isEmpty }), groups.count == stored.count,
              zip(groups, stored).allSatisfy({ $0.count == $1.count }) else { return nil }
        self.groups = groups
    }
}

/// Listens for the shortcut going down/up via a listen-only CGEventTap on
/// flagsChanged events (modifier keys never generate keyDown/keyUp, only
/// flagsChanged with the changed key's keycode in the event payload). Key
/// downs are watched too, only to notice that another key was pressed while
/// the shortcut was held: that is an app shortcut (Command + C), not a
/// dictation. Which key it was is never looked at.
final class HotkeyMonitor {
    /// The one listener: dictation, setup's Try it page and Settings' Record share it.
    static let shared = HotkeyMonitor()
    static let escapeKeycode: Int64 = 53

    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    /// Another key went down while the shortcut was held.
    var onInterrupt: (() -> Void)?

    var spec: HotkeySpec {
        didSet {
            guard spec != oldValue else { return }
            interruptIfActive()
        }
    }

    private var held: Set<HotkeySpec.Key> = []
    private var active = false
    /// While recording a new shortcut in Settings: the keys pressed so far,
    /// and who to tell when they are all let go.
    private var recorded: Set<HotkeySpec.Key> = []
    private var onRecorded: ((HotkeySpec?) -> Void)?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var specObserver: NSObjectProtocol?

    init(spec: HotkeySpec = Preferences.hotkey, followsPreferences: Bool = true) {
        self.spec = spec
        guard followsPreferences else { return }
        specObserver = NotificationCenter.default.addObserver(forName: .hotkeyChanged, object: nil, queue: .main) { [weak self] _ in
            self?.spec = Preferences.hotkey
        }
    }

    /// Safe to call repeatedly: it does nothing once the tap exists, and returns
    /// false (rather than giving up for good) while Input Monitoring is still
    /// missing, so setup can retry after the user grants it.
    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        print("talkflowd: AXIsProcessTrusted at tap setup = \(AXIsProcessTrusted())")

        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.tapDisabledByTimeout.rawValue)
            | (1 << CGEventType.tapDisabledByUserInput.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: hotkeyEventCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("talkflowd: CGEvent.tapCreate returned nil - neither Accessibility nor Input Monitoring applies to this copy")
            return false
        }

        print("talkflowd: event tap created successfully")
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        print("talkflowd: event tap enabled = \(CGEvent.tapIsEnabled(tap: tap))")
        return true
    }

    var isRunning: Bool { tap != nil }

    /// Captures the next modifier keys pressed together, instead of
    /// dictating. `done` gets the new shortcut, or nil when Escape cancels.
    func record(_ done: @escaping (HotkeySpec?) -> Void) {
        interruptIfActive()
        onRecorded?(nil)
        recorded = []
        onRecorded = done
    }

    func cancelRecording() {
        let done = onRecorded
        onRecorded = nil
        recorded = []
        done?(nil)
    }

    var isRecording: Bool { onRecorded != nil }

    fileprivate func handleEvent(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            print("talkflowd: tap was disabled (\(type)), re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        switch type {
        case .flagsChanged:
            flagsChanged(keycode: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags)
        case .keyDown:
            // Keystrokes talkflow typed itself (live typing) are not the user's.
            guard event.getIntegerValueField(.eventSourceUnixProcessID) != Int64(getpid()) else { return }
            keyDown(keycode: event.getIntegerValueField(.keyboardEventKeycode),
                    isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
        default:
            break
        }
    }

    /// A modifier went down or up. Internal, not private, for the self-test.
    func flagsChanged(keycode: Int64, flags: CGEventFlags) {
        guard let key = HotkeySpec.Key(rawValue: Int(keycode)) else { return }
        let pressed = key.isDown(in: flags)
        if pressed { held.insert(key) } else { held.remove(key) }
        // A key-up the tap never saw (the lock screen, a secure input field)
        // must not leave a key held forever. Fn is only ever judged by its own
        // events, as it always has been.
        held = held.filter { $0 == .fn || $0 == key || flags.contains($0.familyMask) }

        if onRecorded != nil {
            if pressed { recorded.insert(key) }
            if held.isEmpty, !recorded.isEmpty {
                let done = onRecorded
                let spec = HotkeySpec.fromRecorded(recorded)
                onRecorded = nil
                recorded = []
                done?(spec)
            }
            return
        }

        if active {
            if !spec.groups.allSatisfy({ $0.contains(where: held.contains) }) {
                active = false
                onStop?()
            } else if pressed && !spec.keys.contains(key) {
                active = false
                onInterrupt?()
            }
        } else if pressed && spec.isSatisfied(by: held) {
            active = true
            onStart?()
        }
    }

    /// Any other key went down. Internal, not private, for the self-test.
    func keyDown(keycode: Int64, isRepeat: Bool) {
        if onRecorded != nil {
            if keycode == Self.escapeKeycode { cancelRecording() }
            return
        }
        guard active, !isRepeat else { return }
        active = false
        onInterrupt?()
    }

    private func interruptIfActive() {
        guard active else { return }
        active = false
        onInterrupt?()
    }
}

private func hotkeyEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let refcon {
        let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
        monitor.handleEvent(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}
