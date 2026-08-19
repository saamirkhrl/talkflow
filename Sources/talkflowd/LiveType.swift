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
    ///
    /// 1200us was measured against live appends, which are one to five events.
    /// The release pass is not that: a 60-second dictation ends in a rewrite of
    /// `-422 +471` (real numbers, from the app's own log), which is ~450 events
    /// posted in a third of a second - roughly 30x faster than a human can type,
    /// sustained. A native NSTextView in this process keeps every character at
    /// that rate; Terminal and Electron apps do not, and the characters that go
    /// missing come out of the MIDDLE of the insertion, leaving the field with
    /// the start and the end of the dictation and a hole between them. That is
    /// the reported bug.
    ///
    /// So the gap is chosen per burst rather than fixed. Live appends stay at
    /// 1200us and still feel instant; anything long enough to be a release-pass
    /// rewrite is paced at a rate the slowest measured consumer keeps up with.
    private static let eventGap: useconds_t = 1200        // microseconds, small edits
    private static let burstEventGap: useconds_t = 3500   // microseconds, long rewrites
    /// Events in one `rewrite` at or above which the slower pacing is used. Live
    /// appends never reach it (the longest in the log is 65 characters = 5
    /// events); the release pass always does.
    private static let burstThreshold = 24

    /// Breathing room between the end of a long delete burst and the start of the
    /// insertion. The delete burst is what fills the target's input queue, and
    /// the insertion that follows it immediately is what arrives incomplete -
    /// historically the whole insertion (a 121-char payload that vanished after
    /// its backspaces had run), now its leading chunks. Let the target drain
    /// before handing it more.
    private static let burstSettle: useconds_t = 150_000  // microseconds

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
            let chunks = chunked(text)
            let events = deleteCount + chunks.count
            let gap = events >= burstThreshold ? burstEventGap : eventGap
            let startedAt = Date()

            backspaceNow(count: deleteCount, gap: gap)
            // Only after a burst big enough to have filled the target's queue;
            // a live append pays nothing for this.
            if deleteCount >= burstThreshold { usleep(burstSettle) }
            insertNow(chunks, gap: gap)

            if events >= burstThreshold {
                let elapsed = Date().timeIntervalSince(startedAt)
                print("talkflowd: keystroke rewrite -\(deleteCount) +\(text.count) = \(events) events in \(String(format: "%.2f", elapsed))s")
            }
        }
    }

    /// Runs `block` once everything already queued has actually been posted.
    ///
    /// The release pass is now paced slowly enough to survive a slow target,
    /// which means a long dictation spends up to ~2s posting keystrokes after
    /// the transcript is ready. Without this the app reports itself idle while
    /// it is still writing, and the user watches text appear under a menu bar
    /// icon that says nothing is happening.
    static func whenDrained(_ block: @escaping () -> Void) {
        queue.async { block() }
    }

    static func backspace(count: Int) {
        queue.async { backspaceNow(count: count, gap: count >= burstThreshold ? burstEventGap : eventGap) }
    }

    static func insert(_ text: String) {
        queue.async {
            let chunks = chunked(text)
            insertNow(chunks, gap: chunks.count >= burstThreshold ? burstEventGap : eventGap)
        }
    }

    private static func backspaceNow(count: Int, gap: useconds_t) {
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
            usleep(gap)
        }
    }

    private static func insertNow(_ chunks: [String], gap: useconds_t) {
        for chunk in chunks {
            postUnicode(chunk)
            usleep(gap)
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
