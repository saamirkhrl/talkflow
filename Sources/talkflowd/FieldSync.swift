import Foundation

/// Keeps a text field in agreement with a string, rewriting only what changed.
///
/// Two ways to write, and BOTH have to work everywhere, because the apps people
/// dictate into most - Slack, Discord, VS Code, anything Electron - do not
/// support Accessibility text editing:
///
///  - `accessibility`: one atomic call, and it verifies the text it is about to
///    replace really is ours before touching it. Best when available.
///  - `keystrokes`: paced backspaces and paced key events. Works in every app.
///
/// The keystroke path is not a degraded fallback; it is held to the same standard
/// and tested under the same streaming load (see TypeSelfTest, which runs the
/// whole sequence with Accessibility disabled). The original failure here was
/// never about which API was used - it was hundreds of unpaced key events per
/// second being coalesced and dropped by the window server, which silently ate
/// characters out of the middle of sentences.
final class FieldSync {
    enum Strategy {
        case preferAccessibility
        case keystrokesOnly
    }

    /// Exactly what has been written to the field, character for character. Every
    /// replacement is bounded by this, so it can never remove text it did not put
    /// there.
    private(set) var typedText = ""

    /// Which path the most recent write actually took. The release pass needs it:
    /// an Accessibility write is atomic and verified, so its size does not matter,
    /// while a keystroke rewrite is hundreds of droppable events and its size is
    /// the whole risk. See `Dictation.reconcile`.
    private(set) var lastOutcome: Outcome = .unchanged

    private let strategy: Strategy

    init(strategy: Strategy = .preferAccessibility) {
        self.strategy = strategy
    }

    func reset() {
        typedText = ""
        lastOutcome = .unchanged
    }

    enum Outcome: Equatable {
        case unchanged
        case accessibility
        /// Carries why Accessibility was not used, because "which path did this
        /// app take" was unanswerable from the log while the app appeared
        /// completely dead in Slack, Discord and Terminal.
        case keystrokes(String)
        /// Nothing was written: the edit needed to delete, and the field said
        /// the text it would delete is not ours. See `keystrokesMayDelete`.
        case refused(String)

        var rawValue: String {
            switch self {
            case .unchanged: return "unchanged"
            case .accessibility: return "accessibility"
            case let .keystrokes(reason): return "keystrokes (\(reason))"
            case let .refused(reason): return "nothing, refused (\(reason))"
            }
        }
    }

    /// Whether a keystroke rewrite may send its backspaces after the AX attempt
    /// came back as `attempt`. Backspaces delete whatever is in front of the
    /// caret, ours or not, so when the field has just reported that it is not
    /// ours they would eat the user's text - "Three things" became "Three t" in
    /// Gmail exactly this way. Every other refusal is about AX itself (Chrome
    /// accepts and ignores AX writes, Terminal refuses them), says nothing
    /// about the text, and keeps the keystroke path. Pure, for `--streamtest`.
    static func keystrokesMayDelete(after attempt: FieldWriter.Attempt) -> Bool {
        if case .notOurs = attempt { return false }
        return true
    }

    /// The edit `sync` would make: how many characters come off the end of what
    /// we typed, and what goes on in their place. Pure, so a test can measure the
    /// real edit rather than a reimplementation of it - the streaming self-test
    /// asserts `deleting == 0` on every live update, which is the whole point of
    /// the append-only commit buffer upstream.
    static func edit(from current: String, to desired: String) -> (deleting: Int, inserting: String) {
        let old = Array(current)
        let new = Array(desired)
        var shared = 0
        while shared < old.count, shared < new.count, old[shared] == new[shared] { shared += 1 }
        return (old.count - shared, String(new[shared...]))
    }

    /// The furthest `current` can be moved towards `final` without deleting
    /// anything: `current`, plus the words of `final` that have never been on
    /// screen.
    ///
    /// The release pass does two jobs at once, and they carry opposite risk. The
    /// words the live path held back have never been shown, so adding them cannot
    /// destroy anything no matter how the write path behaves. Correcting words
    /// that are already on screen means deleting text the user can see and is
    /// happy with, and then retyping it - and when that retype is dropped, the
    /// dictation is gone. Splitting them lets the safe half always happen.
    ///
    /// Word-aligned, not character-aligned, because the live path commits whole
    /// words: the count of words on screen indexes straight into the final
    /// transcript. That is the same positional assumption `StreamCommit` makes.
    /// If whisper re-splits a word in its final pass the seam can gain or lose
    /// one word, which the correction pass repairs when it runs, and which is a
    /// far smaller failure than the one this exists to prevent.
    ///
    /// Returns nil when there is nothing to add.
    static func appendOnlyTarget(current: String, final: String) -> String? {
        let onScreen = tokenize(current).count
        let tokens = tokenize(final)
        guard tokens.count > onScreen else { return nil }
        let tail = tokens[onScreen...].map { $0.leading + $0.word }.joined()
        return tail.isEmpty ? nil : current + tail
    }

    /// Words, each carrying the whitespace in front of it, so a slice can be
    /// reassembled character for character. Whitespace after the last word
    /// belongs to the word that has not arrived yet and is dropped.
    private static func tokenize(_ text: String) -> [(leading: String, word: String)] {
        var tokens: [(leading: String, word: String)] = []
        var leading = ""
        var word = ""
        for character in text {
            if character.isWhitespace {
                if !word.isEmpty {
                    tokens.append((leading, word))
                    word = ""
                    leading = ""
                }
                leading.append(character)
            } else {
                word.append(character)
            }
        }
        if !word.isEmpty { tokens.append((leading, word)) }
        return tokens
    }

    @discardableResult
    func sync(to desired: String) -> Outcome {
        guard desired != typedText else { return .unchanged }

        let (deleteCount, freshTail) = Self.edit(from: typedText, to: desired)
        let staleTail = String(typedText.suffix(deleteCount))

        var reason = "strategy is keystrokes only"
        if strategy == .preferAccessibility {
            let attempt = FieldWriter.replaceBeforeCaret(expected: staleTail, with: freshTail)
            if attempt.succeeded {
                typedText = desired
                lastOutcome = .accessibility
                return .accessibility
            }
            reason = attempt.reason
            if deleteCount > 0, !Self.keystrokesMayDelete(after: attempt) {
                lastOutcome = .refused(reason)
                return .refused(reason)
            }
        }

        // One ordered unit on LiveType's serial queue, so a later update can
        // never overtake an earlier one and interleave its keystrokes.
        LiveType.rewrite(deleting: deleteCount, inserting: freshTail)
        typedText = desired
        lastOutcome = .keystrokes(reason)
        return .keystrokes(reason)
    }
}
