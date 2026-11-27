import Foundation

// Document-style notes: the pure rules behind the auto title and description, auto speaker names, the default
// tab, the old-summary compatibility mapping and the Copy text. No I/O, so --notestest checks all of it
// (NotesDocChecks). The signatures are fixed: the UI calls them.

enum NotesDoc {
    /// Longest title the user can type on the meeting page.
    static let maxTitleLength = 80
    static let maxTitleWords = 7
    static let maxDescriptionWords = 10
    /// How many turns either side of a cited evidence line the named speaker must speak, and the evidence may sit.
    static let nameEvidenceWindow = 2

    private static let dot = " \u{00B7} "

    private static func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// An "s1", "s2", ... key: another voice on the computer-audio track that the separator told apart.
    static func isOtherVoice(_ key: String) -> Bool {
        guard key.hasPrefix("s"), let n = Int(key.dropFirst()) else { return false }
        return n > 0
    }

    // MARK: Sources (backward compatible)

    /// The stored source, or for a note saved before sources: an empty or "Untitled meeting" title is a
    /// placeholder, anything else was typed by the user.
    static func titleSource(_ meta: NoteMeta) -> TitleSource {
        if let s = meta.titleSource { return s }
        let t = trimmed(meta.title)
        return (t.isEmpty || t == "Untitled meeting") ? .placeholder : .user
    }

    /// The stored source, or for a speaker saved before sources: no name is default, a name is the user's.
    static func nameSource(_ speaker: NoteSpeaker) -> NameSource {
        if let s = speaker.nameSource { return s }
        let n = trimmed(speaker.name ?? "")
        return n.isEmpty ? .default : .user
    }

    // MARK: Applying a summary's proposals

    /// The title (when the user has not typed one) and the description from a summary. The description is not
    /// user-editable, so a new summary always refreshes it.
    static func applyingAuto(title: String?, subtitle: String?, to meta: NoteMeta) -> NoteMeta {
        var m = meta
        if let t = title, titleSource(meta) != .user {
            m.title = t
            m.titleSource = .auto
        }
        if let s = subtitle { m.subtitle = s }
        return m
    }

    /// Auto names applied to speakers that still have their default name.
    static func applyingSuggestedNames(_ names: [String: String], to speakers: [NoteSpeaker]) -> [NoteSpeaker] {
        var result = speakers
        for i in result.indices {
            let sp = result[i]
            guard let raw = names[sp.key], isOtherVoice(sp.key), nameSource(sp) == .default else { continue }
            let name = trimmed(raw)
            guard !name.isEmpty, name.count <= NotesLogic.maxNameLength else { continue }
            // No two speakers may show the same name.
            let taken = result.indices.contains { j in
                j != i && NotesLogic.displayName(result[j].key, in: result).caseInsensitiveCompare(name) == .orderedSame
            }
            if taken { continue }
            result[i].name = name
            result[i].nameSource = .auto
        }
        return result
    }

    // MARK: User edits

    /// The meeting page's title editor. Empty = back to the placeholder.
    static func retitled(_ meta: NoteMeta, to draft: String) -> NoteMeta {
        let cut = String(trimmed(draft).prefix(maxTitleLength))
        let t = trimmed(cut)
        var m = meta
        if t.isEmpty {
            m.title = ""
            m.titleSource = .placeholder
            return m
        }
        m.title = t
        m.titleSource = .user
        return m
    }

    /// "Clear" on an auto-named speaker: back to "Speaker N", and never suggested again.
    static func clearingName(_ key: String, in speakers: [NoteSpeaker]) -> [NoteSpeaker] {
        if key == NotesLogic.youKey { return speakers }
        guard let index = speakers.firstIndex(where: { $0.key == key }) else { return speakers }
        var result = speakers
        result[index].name = nil
        result[index].nameSource = .user
        return result
    }

    // MARK: Cleaning model output

    private static let quoteChars: Set<Character> = ["\"", "'", "`", "\u{201C}", "\u{201D}", "\u{2018}", "\u{2019}"]
    private static let endPunctuation: Set<Character> = [".", ",", ";", ":"]

    /// Whitespace runs (spaces, tabs, newlines) become one space; the ends are trimmed.
    private static func collapsed(_ raw: String) -> String {
        let parts = trimmed(raw).split(whereSeparator: { $0.isWhitespace })
        return parts.joined(separator: " ")
    }

    /// Strips one leading and/or one trailing quote character, again and again.
    private static func strippingQuotes(_ text: String) -> String {
        var t = text
        while true {
            var changed = false
            if let first = t.first, quoteChars.contains(first) {
                t.removeFirst()
                changed = true
            }
            if let last = t.last, quoteChars.contains(last) {
                t.removeLast()
                changed = true
            }
            t = trimmed(t)
            if !changed { break }
        }
        return t
    }

    private static func strippingEndPunctuation(_ text: String) -> String {
        var t = text
        while let last = t.last, endPunctuation.contains(last) {
            t.removeLast()
            t = trimmed(t)
        }
        return t
    }

    private static func uppercasingFirst(_ text: String) -> String {
        guard let first = text.first, first.isLowercase else { return text }
        return String(first).uppercased() + text.dropFirst()
    }

    private static let genericTitles: Set<String> = [
        "meeting", "untitled", "untitled meeting", "meeting notes", "notes", "call", "sync",
    ]

    static func cleanTitle(_ raw: String) -> String? {
        var t = collapsed(raw)
        t = strippingQuotes(t)
        t = strippingEndPunctuation(t)
        let words = t.split(separator: " ")
        if words.count < 1 || words.count > maxTitleWords || t.count > maxTitleLength { return nil }
        if genericTitles.contains(t.lowercased()) { return nil }
        return uppercasingFirst(t)
    }

    private static let danglingWords: Set<String> = [
        "and", "or", "but", "the", "a", "an", "of", "to", "with", "for", "in", "on", "at", "by", "from", "as", "so",
    ]

    static func cleanDescription(_ raw: String) -> String? {
        var t = collapsed(raw)
        t = strippingQuotes(t)
        var words = t.split(separator: " ").map(String.init)
        if words.isEmpty { return nil }
        if words.count > maxDescriptionWords {
            words = Array(words.prefix(maxDescriptionWords))
            while let last = words.last {
                let bare = strippingEndPunctuation(last).lowercased()
                if danglingWords.contains(bare) { words.removeLast() } else { break }
            }
        }
        var out = words.joined(separator: " ")
        out = strippingEndPunctuation(trimmed(out))
        out = trimmed(out)
        if out.isEmpty { return nil }
        return uppercasingFirst(out)
    }

    // MARK: Screens

    static func defaultTab(hasTranscript: Bool, hasSummary: Bool, keyInUse: Bool) -> NoteTab {
        if hasSummary { return .summary }
        if hasTranscript && keyInUse { return .summary }
        return .transcript
    }

    /// Details for any summary: its own, or for an old summary (details nil) an empty list.
    static func details(_ s: NoteSummary) -> [NoteSummary.Detail] { s.details ?? [] }

    /// Every decision with its status: new summaries' decisions as stored; old summaries' decisions as aligned
    /// followed by their open questions as needs_discussion.
    static func decisions(_ s: NoteSummary) -> [NoteSummary.Point] {
        let open: [NoteSummary.Point] = s.openQuestions.map { p in
            var q = p
            q.status = p.status ?? DecisionStatus.needsDiscussion.rawValue
            return q
        }
        return s.decisions + open
    }

    // MARK: Copy

    private static func cites(_ times: [Double]) -> String {
        if times.isEmpty { return "" }
        let stamps = times.map { NotesLogic.timestamp($0) }
        return " (" + stamps.joined(separator: ", ") + ")"
    }

    /// The notes as Markdown in the same document structure, for Copy on the Summary tab.
    static func markdown(meta: NoteMeta, summary: NoteSummary, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "MMMM d, yyyy, h:mm a"
        var dateLine = f.string(from: meta.started)
        if meta.duration > 0 { dateLine += dot + NotesLogic.durationText(meta.duration) }

        var head: [String] = ["# " + NotesLogic.displayTitle(meta), dateLine]
        if !meta.speakers.isEmpty {
            let names = meta.speakers.map { NotesLogic.displayName($0.key, in: meta.speakers) }
            head.append("Attendees: " + names.joined(separator: ", "))
        }
        var blocks: [String] = [head.joined(separator: "\n")]
        blocks.append("## Summary\n" + summary.summary + cites(summary.summaryTimes))

        var decisionLines: [String] = []
        for p in decisions(summary) {
            let label = DecisionStatus.of(p.status).label
            decisionLines.append("- **" + label + "**: " + p.text + cites([p.time]))
        }
        if !decisionLines.isEmpty { blocks.append("## Decisions\n" + decisionLines.joined(separator: "\n")) }

        var detailLines: [String] = []
        for d in details(summary) {
            detailLines.append("- **" + d.topic + "**: " + d.text + cites(d.times))
        }
        if !detailLines.isEmpty { blocks.append("## Details\n" + detailLines.joined(separator: "\n")) }

        var stepLines: [String] = []
        for item in summary.actionItems {
            let box = item.done ? "[x]" : "[ ]"
            var line = "- " + box + " "
            if !item.owner.isEmpty {
                line += "**" + NotesAI.ownerName(item.owner, speakers: meta.speakers) + "**: "
            }
            line += item.task + cites([item.time])
            stepLines.append(line)
        }
        if !stepLines.isEmpty { blocks.append("## Suggested next steps\n" + stepLines.joined(separator: "\n")) }

        return blocks.joined(separator: "\n\n") + "\n"
    }
}
