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
    /// `replacement`. Returns `.no(reason)` if the app doesn't support AX text
    /// editing, if what's in front of the caret isn't what we expected, or if the
    /// write did not visibly land - in all of which cases nothing has been
    /// modified and the caller must fall back to keystrokes.
    static func replaceBeforeCaret(expected: String, with replacement: String) -> Attempt {
        guard let field = focusedTextElement() else { return .no("no focused element") }
        guard let caret = caretLocation(in: field) else { return .no("no caret") }

        let expectedUnits = expected.utf16.count
        guard caret >= expectedUnits else { return .no("caret is before the text we typed") }
        let start = caret - expectedUnits

        // Only proceed if the text there is exactly what we think we typed.
        if expectedUnits > 0 {
            guard let onScreen = string(in: field, location: start, length: expectedUnits),
                  onScreen == expected else { return .no("text before the caret is not ours") }
        }

        // Ask the element whether it can be edited this way at all before
        // writing to it. Chromium (Slack, Discord, VS Code, Cursor) and
        // Terminal's scrollback both answer AX calls without necessarily
        // honouring them.
        guard isSettable(field, kAXSelectedTextRangeAttribute), isSettable(field, kAXSelectedTextAttribute) else {
            return .no("element does not accept AX text edits")
        }

        var range = CFRange(location: start, length: expectedUnits)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return .no("could not build a range") }
        guard AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, rangeValue) == .success else {
            return .no("setting the range was refused")
        }
        guard AXUIElementSetAttributeValue(field, kAXSelectedTextAttribute as CFString, replacement as CFTypeRef) == .success else {
            return .no("setting the text was refused")
        }

        // A `.success` return is not evidence the text landed. Discord returns
        // success from every one of the calls above and changes nothing; that is
        // measured, not suspected, and it is what made the app look completely
        // dead there - the write claimed to have worked, so the keystroke path
        // that Discord does accept never ran. Nothing may be believed here
        // without proof, which is why this is the only line that can produce a
        // success and why it goes through `landed`.
        let replacementUnits = replacement.utf16.count
        return landed(
            caretAfter: caretLocation(in: field),
            expectedCaret: start + replacementUnits,
            readback: string(in: field, location: start, length: replacementUnits),
            replacement: replacement
        ) ? .yes : .no("AX reported success but the field did not change")
    }

    /// Did the write land? Pure, and the only definition of success in this
    /// file, so the rule can be tested without an app to write into
    /// (`--streamtest`).
    ///
    /// The caret is the primary evidence: setting selected text collapses the
    /// selection to the end of what was inserted, so a caret that has not moved
    /// means nothing was inserted. Reading the text back is the fallback for
    /// apps that report a caret we can't predict; an app that offers neither is
    /// an app whose writes cannot be trusted, so it gets keystrokes.
    static func landed(caretAfter: Int?, expectedCaret: Int, readback: String?, replacement: String) -> Bool {
        if caretAfter == expectedCaret { return true }
        if let readback, readback == replacement { return true }
        return false
    }

    /// Why a write was refused, so the log can say which apps take which path
    /// instead of leaving it to be guessed.
    enum Attempt: Equatable {
        case yes
        case no(String)

        var succeeded: Bool { self == .yes }
        var reason: String {
            if case let .no(reason) = self { return reason }
            return ""
        }
    }

    /// What the focused element will and will not accept, read-only, for
    /// `--writetest`. Whether an app takes the Accessibility path or the
    /// keystroke path is a property of the app, and until this existed the only
    /// way to find out was to dictate into it and watch.
    static func focusReport() -> String {
        guard let field = focusedTextElement() else { return "no focused UI element" }

        func attribute(_ name: String) -> String {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(field, name as CFString, &value) == .success else { return "-" }
            return (value as? String) ?? "(non-string)"
        }

        var lines = [
            "role=\(attribute(kAXRoleAttribute)) subrole=\(attribute(kAXSubroleAttribute))",
            "selectedTextRange settable=\(isSettable(field, kAXSelectedTextRangeAttribute))",
            "selectedText settable=\(isSettable(field, kAXSelectedTextAttribute))",
            "value settable=\(isSettable(field, kAXValueAttribute))"
        ]
        if let caret = caretLocation(in: field) {
            lines.append("caret=\(caret)")
            if caret > 0 {
                let readback = string(in: field, location: caret - 1, length: 1)
                lines.append("stringForRange readable=\(readback != nil)")
            } else {
                lines.append("stringForRange readable=(field is empty, cannot probe)")
            }
        } else {
            lines.append("caret=unreadable (no selection range, or something is selected)")
        }
        return lines.joined(separator: "\n     ")
    }

    private static func isSettable(_ field: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(field, attribute as CFString, &settable) == .success else { return false }
        return settable.boolValue
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
