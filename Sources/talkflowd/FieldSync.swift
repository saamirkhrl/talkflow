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

    private let strategy: Strategy

    init(strategy: Strategy = .preferAccessibility) {
        self.strategy = strategy
    }

    func reset() { typedText = "" }

    enum Outcome: String {
        case unchanged
        case accessibility
        case keystrokes
        case failed
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

    @discardableResult
    func sync(to desired: String) -> Outcome {
        guard desired != typedText else { return .unchanged }

        let (deleteCount, freshTail) = Self.edit(from: typedText, to: desired)
        let staleTail = String(typedText.suffix(deleteCount))

        if strategy == .preferAccessibility,
           FieldWriter.replaceBeforeCaret(expected: staleTail, with: freshTail) {
            typedText = desired
            return .accessibility
        }

        // One ordered unit on LiveType's serial queue, so a later update can
        // never overtake an earlier one and interleave its keystrokes.
        LiveType.rewrite(deleting: deleteCount, inserting: freshTail)
        typedText = desired
        return .keystrokes
    }
}
