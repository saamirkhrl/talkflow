import AppKit
import ApplicationServices
import Foundation
import NaturalLanguage

/// What is on screen around the caret when a dictation starts, read through
/// the Accessibility API. Wispr Flow does the same (app, text around the
/// cursor, visible names such as email recipients); this is the local,
/// read-only version of it, and it is used for three things:
///
///  - names on screen go into whisper's prompt, which biases its spelling, so
///    the recipient "Siobhan" is not written "Shivon";
///  - the text before the caret says whether the dictation continues a
///    sentence, in which case its first word is lowercased;
///  - the app says whether this is a chat, where a one-line message drops its
///    final period.
///
/// Nothing here is logged or kept: the snapshot lives for one hold. Password
/// fields are never read. Every read is bounded in time and size, and the
/// snapshot is taken on a background queue, so a slow app cannot delay the
/// recording.
enum ScreenContext {
    struct Snapshot {
        var bundleID: String?
        /// Up to `beforeLimit` characters immediately before the caret, or nil
        /// when the app will not say.
        var textBeforeCaret: String?
        /// The end of the focused field's text, for `Vocabulary`.
        var fieldText: String?
        /// Proper nouns seen on screen, most relevant first.
        var names: [String] = []
    }

    private static let beforeLimit = 300
    private static let fieldLimit = 4000
    private static let maxNodes = 500
    private static let maxNames = 15
    private static let budget: TimeInterval = 0.25

    /// Reads the focused app. Blocking; call off the main thread.
    static func capture() -> Snapshot {
        var snapshot = Snapshot(bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        let deadline = Date().addingTimeInterval(budget)
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)

        var texts: [String] = []
        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
           let ref = focusedRef, CFGetTypeID(ref) == AXUIElementGetTypeID() {
            let field = ref as! AXUIElement
            AXUIElementSetMessagingTimeout(field, 0.15)
            guard string(field, kAXSubroleAttribute) != (kAXSecureTextFieldSubrole as String) else { return snapshot }
            snapshot.textBeforeCaret = textBeforeCaret(field)
            if let value = string(field, kAXValueAttribute) {
                snapshot.fieldText = String(value.suffix(fieldLimit))
                texts.append(snapshot.fieldText!)
            }

            // The window around the field: recipients, a subject line, a chat
            // header. A bounded walk, stopped by node count and the clock.
            var windowRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(field, kAXWindowAttribute as CFString, &windowRef) == .success,
               let window = windowRef, CFGetTypeID(window) == AXUIElementGetTypeID() {
                let root = window as! AXUIElement
                AXUIElementSetMessagingTimeout(root, 0.1)
                if let title = string(root, kAXTitleAttribute) { texts.append(title) }
                collect(from: root, into: &texts, deadline: deadline)
            }
        }
        snapshot.names = names(in: texts)
        return snapshot
    }

    // MARK: - Uses

    /// The whisper prompt for this hold: the fixed vocabulary sentence, plus
    /// what is on screen and what the user has taught it. Kept a normal,
    /// punctuated sentence - whisper imitates the prompt's style (see
    /// `Transcriber.vocabularyPrompt`). Pure, for `--streamtest`.
    static func prompt(names: [String], learned: [String]) -> String {
        var words: [String] = []
        for word in names + learned where !words.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) {
            words.append(word)
        }
        let kept = Array(words.prefix(25))
        guard !kept.isEmpty else { return Transcriber.vocabularyPrompt }
        return Transcriber.vocabularyPrompt + " Names and words here: " + kept.joined(separator: ", ") + "."
    }

    /// Whether the dictation lands mid-sentence: something is before the caret
    /// on the same line and it does not end a sentence. Pure, for `--streamtest`.
    static func continuesSentence(after before: String?) -> Bool {
        guard let before else { return false }
        let line = before.split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
        guard let last = line.last(where: { !$0.isWhitespace }) else { return false }
        return !".!?:;".contains(last) && !last.isNewline
    }

    /// "Thanks for" + "Great work" -> "great work": lowercases the dictation's
    /// first word when it continues a sentence, unless it is "I", an acronym,
    /// or a name (on screen, or tagged as one). Changes one letter's case, so
    /// it passes the deletion-only word check. Pure, for `--streamtest`.
    static func lowercasingStart(_ text: String, names: [String]) -> String {
        let body = text.drop(while: \.isWhitespace)
        let firstWord = String(body.prefix(while: { !$0.isWhitespace }))
        let bare = firstWord.trimmingCharacters(in: .punctuationCharacters)
        guard let first = bare.first, first.isUppercase else { return text }
        if bare == "I" || bare.hasPrefix("I'") { return text }
        if bare.count > 1, bare.allSatisfy({ $0.isUppercase || !$0.isLetter }) { return text } // "NASA", "OK"
        if names.contains(where: { $0.split(separator: " ").contains(Substring(bare)) }) { return text }
        if isName(bare) { return text }
        let leading = text.prefix(while: \.isWhitespace)
        return leading + first.lowercased() + body.dropFirst()
    }

    /// Chat apps, where a one-line message conventionally has no final period.
    private static let chatBundles: Set<String> = [
        "com.apple.MobileSMS", "com.tinyspeck.slackmacgap", "com.hnc.Discord", "net.whatsapp.WhatsApp",
        "desktop.WhatsApp", "ru.keepcoder.Telegram", "org.whispersystems.signal-desktop", "com.facebook.archon",
        "com.microsoft.teams2", "com.microsoft.teams"
    ]

    static func isChat(bundleID: String?) -> Bool {
        bundleID.map(chatBundles.contains) ?? false
    }

    /// A chat message that is a single sentence loses its final period, as
    /// people type them: "sounds good, see you at 5". Only one trailing "."
    /// goes - not "?", "!" or "..." - and only from a single line with no
    /// other "." "!" or "?" in it, which also keeps "3 p.m." whole. Pure, for
    /// `--streamtest`.
    static func chatStyled(_ text: String) -> String {
        guard text.hasSuffix("."), !text.hasSuffix(".."), !text.contains("\n") else { return text }
        let body = text.dropLast()
        guard !body.contains(where: { ".!?".contains($0) }) else { return text }
        return String(body)
    }

    // MARK: - Reading

    private static func textBeforeCaret(_ field: AXUIElement) -> String? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let raw = rangeRef, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range) else { return nil }
        guard range.location > 0 else { return "" }
        let length = min(beforeLimit, range.location)
        var window = CFRange(location: range.location - length, length: length)
        guard let value = AXValueCreate(.cfRange, &window) else { return nil }
        var text: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(field, kAXStringForRangeParameterizedAttribute as CFString, value, &text) == .success
        else { return nil }
        return text as? String
    }

    private static func collect(from root: AXUIElement, into texts: inout [String], deadline: Date) {
        var queue: [AXUIElement] = [root]
        var visited = 0
        while !queue.isEmpty, visited < maxNodes, Date() < deadline {
            let element = queue.removeFirst()
            visited += 1
            AXUIElementSetMessagingTimeout(element, 0.05)
            if string(element, kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String) { continue }
            for attribute in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                if let text = string(element, attribute), !text.isEmpty, text.count < 400 { texts.append(text) }
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
               let list = children as? [AXUIElement] {
                queue.append(contentsOf: list.prefix(60))
            }
        }
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    // MARK: - Names

    /// Words that are capitalised on screen because they are interface, not
    /// because they are names.
    private static let interfaceWords: Set<String> = [
        "inbox", "send", "sent", "reply", "forward", "compose", "search", "settings", "file", "edit", "view",
        "window", "help", "gmail", "google", "mail", "chrome", "safari", "to", "cc", "bcc", "subject", "re",
        "fwd", "draft", "drafts", "more", "new", "message", "messages", "today", "yesterday", "notes", "home",
        "close", "minimize", "zoom", "untitled", "format", "insert", "tools", "back", "next", "done", "cancel",
        "general", "threads", "channels", "direct", "starred", "snoozed", "important", "spam", "trash", "labels"
    ]

    /// Proper nouns: anything the tagger calls a person, place or
    /// organisation, plus short all-capitalised labels ("Samantha Lee", a
    /// recipient chip), ranked by how often they appear.
    static func names(in texts: [String]) -> [String] {
        var counts: [String: Int] = [:]
        let tagger = NLTagger(tagSchemes: [.nameType])
        for text in texts {
            let words = text.split(separator: " ")
            if (1...3).contains(words.count),
               words.allSatisfy({ $0.first?.isUppercase == true && $0.dropFirst().allSatisfy { $0.isLowercase || $0 == "'" || $0 == "-" } && $0.count > 1 }) {
                for word in words { counts[String(word), default: 0] += 2 }
                continue
            }
            tagger.string = text
            tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                                 options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
                if let tag, [.personalName, .placeName, .organizationName].contains(tag) {
                    for word in text[range].split(separator: " ") { counts[String(word), default: 0] += 1 }
                }
                return true
            }
        }
        return counts
            .filter { $0.key.count > 1 && !interfaceWords.contains($0.key.lowercased()) && $0.key.first?.isLetter == true }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(maxNames)
            .map(\.key)
    }

    static func isName(_ word: String) -> Bool {
        let tagger = NLTagger(tagSchemes: [.nameType])
        let sentence = "I met " + word + " today."
        tagger.string = sentence
        guard let range = sentence.range(of: word) else { return false }
        let (tag, _) = tagger.tag(at: range.lowerBound, unit: .word, scheme: .nameType)
        return tag == .personalName || tag == .placeName || tag == .organizationName
    }
}
