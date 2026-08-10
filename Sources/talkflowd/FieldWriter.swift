import ApplicationServices
import Foundation

/// Replaces the text this app has typed, atomically, via the Accessibility API.
///
/// Streaming into a live text field means rewriting the tail every time whisper
/// revises its guess. Doing that with synthetic keystrokes does not work: a
/// rewrite is one key event per deleted character plus more for the replacement,
/// several hundred events every 0.7s, and the window server coalesces and drops
/// them under that load. The visible result was silent data loss - "could you
/// please" arriving as "uld you please", and a whole clause vanishing out of the
/// middle of a sentence - while the app's own log showed it had transcribed
/// everything correctly. A single self-test rewrite passed, because one rewrite
/// with time to settle is not the situation that breaks.
///
/// An AX replacement is one IPC call regardless of length, so there is nothing to
/// drop. It also allows something keystrokes never could: reading back the text
/// about to be replaced and refusing unless it is exactly what this app believes
/// it typed. If the user has clicked elsewhere or edited by hand, the write is
/// declined rather than eating their words.
enum FieldWriter {
    /// Replaces the `expected` characters immediately before the caret with
    /// `replacement`. Returns false if the app doesn't support AX text editing,
    /// or if what's in front of the caret isn't what we expected - in which case
    /// nothing has been modified.
    static func replaceBeforeCaret(expected: String, with replacement: String) -> Bool {
        guard let field = focusedTextElement() else { return false }
        guard let caret = caretLocation(in: field) else { return false }

        let expectedUnits = expected.utf16.count
        guard caret >= expectedUnits else { return false }
        let start = caret - expectedUnits

        // Only proceed if the text there is exactly what we think we typed.
        if expectedUnits > 0 {
            guard let onScreen = string(in: field, location: start, length: expectedUnits),
                  onScreen == expected else { return false }
        }

        var range = CFRange(location: start, length: expectedUnits)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return false }
        guard AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, rangeValue) == .success else {
            return false
        }
        guard AXUIElementSetAttributeValue(field, kAXSelectedTextAttribute as CFString, replacement as CFTypeRef) == .success else {
            return false
        }
        return true
    }

    private static func focusedTextElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.3)

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        let field = element as! AXUIElement
        AXUIElementSetMessagingTimeout(field, 0.3)
        return field
    }

    /// The caret offset, and only when nothing is selected - a non-empty
    /// selection means the user has highlighted something and replacing it would
    /// destroy their selection.
    private static func caretLocation(in field: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let raw = value, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range), range.length == 0 else { return nil }
        return range.location
    }

    private static func string(in field: AXUIElement, location: Int, length: Int) -> String? {
        var range = CFRange(location: location, length: length)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var text: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            field,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &text
        ) == .success else { return nil }
        return text as? String
    }
}
