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
        let start = caret - expectedUnits

        // Only proceed if the text there is exactly what we think we typed.
        //
        // When it is NOT, that is evidence, and the caller must not answer it by
        // backspacing over the same text with keystrokes. That is what happened
        // in Gmail: an earlier live append had lost characters, the readback
        // here said so, and the keystroke fallback deleted 109 characters
        // anyway - five past the start of what was ours, leaving "Three t:".
        // A field that merely stores the same text differently (a non-breaking
        // space, a blank line kept as one newline) is not evidence of anything,
        // and keystrokes stay allowed; only the AX write, which addresses exact
        // offsets, needs an exact match.
        if expectedUnits > 0 {
            let exact = start >= 0 ? string(in: field, location: start, length: expectedUnits) : nil
            let windowStart = max(0, start - 32)
            let window = string(in: field, location: windowStart, length: caret - windowStart)
            switch compare(exactRange: exact, window: window, expected: expected) {
            case .exact:
                break
            case .equivalent:
                return .no("text before the caret is ours, stored with different whitespace")
            case .unreadable:
                return .no(start >= 0 ? "text before the caret is unreadable" : "caret is before the text we typed")
            case .different:
                return .notOurs("text before the caret is not ours: " + describeMismatch(expected: expected, onScreen: window ?? ""))
            }
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
        /// AX could not or would not do it; keystrokes may.
        case no(String)
        /// The field itself reports that the text before the caret is not what
        /// this app typed. Nothing may be deleted on the strength of that.
        case notOurs(String)

        var succeeded: Bool { self == .yes }
        var reason: String {
            switch self {
            case .yes: return ""
            case let .no(reason), let .notOurs(reason): return reason
            }
        }
    }

    enum Match: Equatable { case exact, equivalent, different, unreadable }

    /// Is what the field holds before the caret the text we typed? Pure, for
    /// `--streamtest`. `exactRange` is the field's text at exactly our offsets;
    /// `window` is a little more than that, ending at the caret, because a
    /// field that stores a blank line as one newline shifts the offsets.
    static func compare(exactRange: String?, window: String?, expected: String) -> Match {
        if exactRange == expected { return .exact }
        guard let window else { return exactRange == nil ? .unreadable : .different }
        return normalized(window).hasSuffix(normalized(expected)) ? .equivalent : .different
    }

    /// Whitespace as a rich-text field may store it: non-breaking and thin
    /// spaces for spaces, other line separators for "\n", invisible joiners
    /// dropped, and a run of newlines counted once.
    private static func normalized(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x00A0, 0x2007, 0x2009, 0x202F: out.append(" ")
            case 0x000D, 0x0085, 0x2028, 0x2029, 0x000A:
                if out.last != "\n" { out.append("\n") }
            case 0x200B, 0xFEFF, 0xFFFC: continue
            default: out.append(scalar)
            }
        }
        return String(out)
    }

    /// Where the field and our record diverge, counted back from the caret,
    /// with the characters described by class only. The log must not carry
    /// what the user dictated (see `Dictation.logTranscripts`).
    static func describeMismatch(expected: String, onScreen: String) -> String {
        let want = Array(normalized(expected)), have = Array(normalized(onScreen))
        var back = 0
        while back < want.count, back < have.count, want[want.count - 1 - back] == have[have.count - 1 - back] { back += 1 }
        func kind(_ index: Int, in chars: [Character]) -> String {
            guard index >= 0 else { return "nothing" }
            let c = chars[index]
            if c == " " { return "space" }
            if c == "\n" { return "newline" }
            if c.isLetter { return "letter" }
            if c.isNumber { return "digit" }
            if c.isPunctuation { return "punctuation" }
            return c.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined()
        }
        return "diverges \(back + 1) characters before the caret (expected \(kind(want.count - 1 - back, in: want)), "
            + "found \(kind(have.count - 1 - back, in: have))); we typed \(expected.count) there"
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

    /// The `count` characters immediately before the caret, read only, for
    /// `--stresstest`. This is not the trust check `replaceBeforeCaret` makes -
    /// it is a diagnostic, and it says what an app really contains after a
    /// rewrite, in an app that only ever answers "I changed it" and cannot be
    /// believed. Nil when the app will not answer at all.
    static func readBeforeCaret(_ count: Int) -> String? {
        guard let field = focusedTextElement(), let caret = caretLocation(in: field) else { return nil }
        let length = min(count, caret)
        guard length > 0 else { return nil }
        return string(in: field, location: caret - length, length: length)
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
