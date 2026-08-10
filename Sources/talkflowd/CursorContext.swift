import ApplicationServices
import Foundation

/// Answers "what character is immediately left of the insertion point?" so a new
/// dictation can decide whether it needs to type a leading space.
///
/// Each key-hold starts with nothing on screen from its own point of view, so
/// without this two dictations in a row run together ("...America." + "I'm going
/// to" -> "America.I'm going to"). Uses the Accessibility API to look at the real
/// text field where it can, and falls back to remembering how the previous hold
/// ended when the focused app doesn't expose its text (Electron apps, terminals,
/// canvas-drawn editors).
enum CursorContext {
    /// Whether inserted text should open with a space so it doesn't run into
    /// whatever is already there. When the app won't say, assume not - a missing
    /// space is easier to live with than one that shouldn't be there.
    static func needsSeparatorBeforeInsertion() -> Bool {
        guard let previous = precedingCharacter() else { return false }
        return !previous.isWhitespace
    }

    /// The character before the caret, or nil when the app won't tell us.
    /// Also nil when the caret is genuinely at offset 0 - there is nothing to
    /// separate from there, which is the same answer a space would give.
    static func precedingCharacter() -> Character? {
        let system = AXUIElementCreateSystemWide()
        // This runs on the main thread the moment the hotkey goes down. An
        // unresponsive frontmost app would otherwise block the default 6-second
        // AX timeout right there and swallow the start of the recording.
        AXUIElementSetMessagingTimeout(system, 0.25)

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        let field = element as! AXUIElement
        // The timeout is per-element, so the system-wide one above doesn't cover
        // the two queries below - and those are the ones that talk to the app.
        AXUIElementSetMessagingTimeout(field, 0.25)

        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeRef = rangeValue, CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range) else { return nil }
        guard range.location > 0 else { return nil }

        var previous = CFRange(location: range.location - 1, length: 1)
        guard let previousValue = AXValueCreate(.cfRange, &previous) else { return nil }

        var text: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            field,
            kAXStringForRangeParameterizedAttribute as CFString,
            previousValue,
            &text
        ) == .success else { return nil }

        return (text as? String)?.last
    }
}
