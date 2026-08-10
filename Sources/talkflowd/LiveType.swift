import CoreGraphics
import Darwin
import Foundation

/// Synthesizes keystrokes, for streaming the transcript into the focused app's
/// text field as it is spoken.
enum LiveType {
    private static let deleteKeycode: CGKeyCode = 51 // backspace (delete-going-left)

    /// A single synthetic key event can only carry a short unicode payload;
    /// beyond roughly this many UTF-16 units the string is silently truncated or
    /// the event is dropped entirely, with nothing reported anywhere. This is not
    /// hypothetical - a 121-character insertion once vanished completely, after
    /// the backspaces preceding it had already run, and destroyed a dictation.
    /// Every insert goes out in chunks no larger than this.
    private static let maxUnitsPerEvent = 16

    /// Synthetic events posted back-to-back with no gap get coalesced and
    /// dropped by the window server once there are more than a handful. This is
    /// the fallback path (see FieldWriter for the primary one), so it has to
    /// survive long rewrites: pace every event.
    private static let eventGap: useconds_t = 1200 // microseconds

    /// All keystroke writing happens here, off the main thread. Pacing means
    /// sleeping between events, and sleeping on the main thread freezes the app:
    /// a 300-character rewrite would block the run loop for a third of a second,
    /// which in testing was enough for the window to lose focus mid-rewrite and
    /// the remaining keystrokes to land somewhere else entirely. Serial, so
    /// consecutive rewrites stay in order.
    private static let queue = DispatchQueue(label: "com.samir.talkflow.livetype")

    /// Deletes `deleting` characters then inserts `inserting`, as one ordered
    /// unit on the serial queue.
    ///
    /// A Cmd+V paste was tried here for large insertions, on the theory that one
    /// keystroke beats two hundred. It silently did nothing - the deletion ran and
    /// the replacement never arrived, leaving the field truncated. Paced key
    /// events carry any length reliably (measured well past 150 characters), and
    /// they leave the clipboard alone, so there is no reason to reach for paste.
    static func rewrite(deleting deleteCount: Int, inserting text: String) {
        queue.async {
            backspaceNow(count: deleteCount)
            insertNow(text)
        }
    }

    static func backspace(count: Int) {
        queue.async { backspaceNow(count: count) }
    }

    static func insert(_ text: String) {
        queue.async { insertNow(text) }
    }

    private static func backspaceNow(count: Int) {
        guard count > 0 else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        for _ in 0..<count {
            let down = CGEvent(keyboardEventSource: source, virtualKey: deleteKeycode, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: deleteKeycode, keyDown: false)
            // The Fn key is physically held down for the whole recording, and
            // combinedSessionState reflects real hardware modifiers - without
            // clearing flags every synthetic keystroke goes out as Fn+key, and
            // Fn+Delete is forward-delete, not backspace.
            down?.flags = []
            up?.flags = []
            down?.post(tap: .cgSessionEventTap)
            up?.post(tap: .cgSessionEventTap)
            usleep(eventGap)
        }
    }

    private static func insertNow(_ text: String) {
        guard !text.isEmpty else { return }
        for chunk in chunked(text) {
            postUnicode(chunk)
            usleep(eventGap)
        }
    }

    /// Splits into events, never mid-character, and never mixing a newline with
    /// other text.
    ///
    /// Newlines are the reason this is subtle. A unicode key event carrying
    /// "\n\nCan you please review..." delivers the newline and then drops the
    /// rest of that event's string - which is precisely how "Dear Sarah,\n\nCan
    /// you please review" reached the screen as "Dear Sarah,\n review". Giving
    /// each newline its own event fixes it.
    ///
    /// A newline is sent as a unicode character rather than as the Return key on
    /// purpose: in Slack and Discord, Return sends the message.
    static func chunked(_ text: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        var currentUnits = 0

        func flush() {
            if !current.isEmpty { chunks.append(current) }
            current = ""
            currentUnits = 0
        }

        for character in text {
            if character.isNewline {
                flush()
                chunks.append(String(character))
                continue
            }
            let units = String(character).utf16.count
            if currentUnits + units > maxUnitsPerEvent { flush() }
            current.append(character)
            currentUnits += units
        }
        flush()
        return chunks
    }

    private static func postUnicode(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let utf16 = Array(text.utf16)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        down?.flags = []
        up?.flags = []
        down?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        up?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }
}
