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

    @discardableResult
    func sync(to desired: String) -> Outcome {
        guard desired != typedText else { return .unchanged }

        let current = Array(typedText)
        let new = Array(desired)
        var shared = 0
        while shared < current.count, shared < new.count, current[shared] == new[shared] { shared += 1 }

        let staleTail = String(current[shared...])
        let freshTail = String(new[shared...])

        if strategy == .preferAccessibility,
           FieldWriter.replaceBeforeCaret(expected: staleTail, with: freshTail) {
            typedText = desired
            return .accessibility
        }

        // One ordered unit on LiveType's serial queue, so a later update can
        // never overtake an earlier one and interleave its keystrokes.
        LiveType.rewrite(deleting: staleTail.count, inserting: freshTail)
        typedText = desired
        return .keystrokes
    }
}
