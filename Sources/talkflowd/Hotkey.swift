import ApplicationServices
import CoreGraphics
import Foundation

/// Listens for the Fn key going down/up via a listen-only CGEventTap on
/// flagsChanged events (modifier keys never generate keyDown/keyUp, only
/// flagsChanged with the changed key's keycode in the event payload).
final class HotkeyMonitor {
    private static let fnKeycode: Int64 = 63

    var onStart: (() -> Void)?
    var onStop: (() -> Void)?

    private var fnDown = false
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    func start() {
        print("talkflowd: AXIsProcessTrusted at tap setup = \(AXIsProcessTrusted())")

        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
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
            print("talkflowd: CGEvent.tapCreate returned nil - Input Monitoring not granted")
            return
        }

        print("talkflowd: event tap created successfully")
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        print("talkflowd: event tap enabled = \(CGEvent.tapIsEnabled(tap: tap))")
    }

    fileprivate func handleEvent(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            print("talkflowd: tap was disabled (\(type)), re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }

        guard type == .flagsChanged else { return }
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keycode == Self.fnKeycode else { return }

        let down = event.flags.contains(.maskSecondaryFn)
        if down != fnDown {
            fnDown = down
            down ? onStart?() : onStop?()
        }
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
