import Foundation

/// The Summary tab's editable document, saved as document.json next to summary.json. It is made from the
/// generated summary when the tab shows a summary that has no matching saved document; after the user's first
/// edit it is saved and shown instead. The generated summary is never changed. All of its logic is here, free of
/// any UI, so --notestest can check it.
struct NoteDocument: Equatable {
    enum Kind: String, CaseIterable, Equatable, Hashable {
        case paragraph, heading, bullet, todo
    }

    /// A run of text in a block: plain, bold (a topic or owner lead-in) or a time link into the transcript.
    struct Span: Equatable {
        var text: String
        var bold: Bool
        /// The transcript time this text links to, in seconds; nil for plain text.
        var cite: Double?

        init(_ text: String, bold: Bool = false, cite: Double? = nil) {
            self.text = text
            self.bold = bold
            self.cite = cite
        }
    }

    struct Block: Equatable {
        var kind: Kind
        /// To-dos only; always false for the other kinds.
        var checked: Bool
        var spans: [Span]

        init(_ kind: Kind, checked: Bool = false, _ spans: [Span] = []) {
            self.kind = kind
            self.checked = kind == .todo && checked
            self.spans = NoteDocument.normalized(spans)
        }

        var text: String { spans.map(\.text).joined() }
        /// In UTF-16 units, as the text view counts.
        var length: Int { text.utf16.count }
    }

    var schemaVersion: Int = NotesSchema.version
    /// `written` (seconds since 1970) of the summary this document was made from. A document whose summary was
    /// written again is stale and is not shown (see `matches`); it stays on disk until the next edit replaces it.
    var basedOn: Double
    var blocks: [Block]

    init(basedOn: Double, blocks: [Block]) {
        self.basedOn = basedOn
        self.blocks = blocks
    }
}

extension NoteDocument.Span: Codable {
    private enum CodingKeys: String, CodingKey { case text, bold, cite }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(try c.decode(String.self, forKey: .text),
                  bold: try c.decodeIfPresent(Bool.self, forKey: .bold) ?? false,
                  cite: try c.decodeIfPresent(Double.self, forKey: .cite))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        if bold { try c.encode(true, forKey: .bold) }
        try c.encodeIfPresent(cite, forKey: .cite)
    }
}

extension NoteDocument.Block: Codable {
    private enum CodingKeys: String, CodingKey { case kind, checked, spans }

    /// An unknown kind (from a later version) reads as a paragraph, so the text is never lost.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = NoteDocument.Kind(rawValue: try c.decodeIfPresent(String.self, forKey: .kind) ?? "") ?? .paragraph
        self.init(kind, checked: try c.decodeIfPresent(Bool.self, forKey: .checked) ?? false,
                  try c.decodeIfPresent([NoteDocument.Span].self, forKey: .spans) ?? [])
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind.rawValue, forKey: .kind)
        if checked { try c.encode(true, forKey: .checked) }
        try c.encode(spans, forKey: .spans)
    }
}

extension NoteDocument: Codable {}

extension NoteDocument {
    /// Drops empty spans and joins neighbours that look the same, so equal documents compare equal.
    static func normalized(_ spans: [Span]) -> [Span] {
        var out: [Span] = []
        for s in spans where !s.text.isEmpty {
            if let last = out.last, last.bold == s.bold, last.cite == s.cite {
                out[out.count - 1].text += s.text
            } else {
                out.append(s)
            }
        }
        return out
    }

    /// True when `d` was made from this summary (not one written before or after it). One second of slack,
    /// because summary.json stores whole seconds.
    static func matches(_ d: NoteDocument, _ s: NoteSummary) -> Bool {
        abs(d.basedOn - s.written.timeIntervalSince1970) < 1
    }

    /// " (0:12, 1:15)": the times as links, in the same form the notes used before.
    static func citeSpans(_ times: [Double]) -> [Span] {
        guard !times.isEmpty else { return [] }
        var out = [Span(" (")]
        for (i, t) in times.enumerated() {
            if i > 0 { out.append(Span(", ")) }
            out.append(Span(NotesLogic.timestamp(t), cite: t))
        }
        out.append(Span(")"))
        return out
    }

    /// Newlines inside one item become single spaces.
    private static func oneLine(_ s: String) -> String {
        s.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The generated summary as blocks: Summary, Decisions (aligned), Open questions (needs further discussion,
    /// disagreed, shelved), Details, Action items. Speaker references are resolved to the current names.
    static func converting(_ original: NoteSummary, speakers: [NoteSpeaker]) -> [Block] {
        let s = NotesDoc.resolving(original, speakers: speakers)
        var out: [Block] = [Block(.heading, [Span("Summary")])]
        let lines = s.summary.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let paragraphs = lines.isEmpty ? [""] : lines
        for (i, p) in paragraphs.enumerated() {
            let cites = i == paragraphs.count - 1 ? citeSpans(s.summaryTimes) : []
            out.append(Block(.paragraph, [Span(p)] + cites))
        }

        let all = NotesDoc.decisions(s)
        let decided = all.filter { DecisionStatus.of($0.status) == .aligned }
        let open = all.filter { DecisionStatus.of($0.status) != .aligned }
        if !decided.isEmpty {
            out.append(Block(.heading, [Span("Decisions")]))
            for p in decided { out.append(Block(.bullet, [Span(oneLine(p.text))] + citeSpans([p.time]))) }
        }
        if !open.isEmpty {
            out.append(Block(.heading, [Span("Open questions")]))
            for p in open {
                var lead: [Span] = []
                switch DecisionStatus.of(p.status) {
                case .disagreed: lead = [Span("Disagreed: ", bold: true)]
                case .shelved: lead = [Span("Shelved: ", bold: true)]
                case .aligned, .needsDiscussion: break
                }
                out.append(Block(.bullet, lead + [Span(oneLine(p.text))] + citeSpans([p.time])))
            }
        }

        let details = NotesDoc.details(s)
        if !details.isEmpty {
            out.append(Block(.heading, [Span("Details")]))
            for d in details {
                let topic = oneLine(d.topic)
                let lead = topic.isEmpty ? [] : [Span(topic + ": ", bold: true)]
                out.append(Block(.bullet, lead + [Span(oneLine(d.text))] + citeSpans(d.times)))
            }
        }

        if !s.actionItems.isEmpty {
            out.append(Block(.heading, [Span("Action items")]))
            for item in s.actionItems {
                let lead = item.owner.isEmpty
                    ? [] : [Span(NotesAI.ownerName(item.owner, speakers: speakers) + ": ", bold: true)]
                out.append(Block(.todo, checked: item.done, lead + [Span(oneLine(item.task))] + citeSpans([item.time])))
            }
        }
        return out
    }
}

extension NoteDocument {
    struct Caret: Equatable {
        var block: Int
        var offset: Int
    }

    enum ReturnAction: Equatable {
        /// Break the block at the caret; the part after the caret becomes a new block of this kind (unchecked).
        case split(newKind: Kind)
        /// The caret is at the start of a non-empty block: add an empty block of this kind above it.
        case insertAbove(kind: Kind)
        /// An empty list item: turn it into this kind instead of adding a block.
        case convert(to: Kind)
    }

    static func returnAction(kind: Kind, text: String, offset: Int) -> ReturnAction {
        if (kind == .bullet || kind == .todo) && text.isEmpty { return .convert(to: .paragraph) }
        let next: Kind = kind == .heading ? .paragraph : kind
        if offset == 0 && !text.isEmpty { return .insertAbove(kind: next) }
        return .split(newKind: next)
    }

    /// Delete at the start of a block: a heading, bullet or to-do becomes a paragraph (non-nil); a paragraph
    /// merges with the block above (nil: the text view's normal delete does that).
    static func deleteAtStartConverts(_ kind: Kind) -> Kind? {
        kind == .paragraph ? nil : .paragraph
    }

    static func converted(_ b: Block, to kind: Kind) -> Block {
        Block(kind, checked: false, b.spans)
    }

    static func toggled(_ b: Block) -> Block {
        guard b.kind == .todo else { return b }
        return Block(.todo, checked: !b.checked, b.spans)
    }

    /// Splits spans at a UTF-16 offset of their joined text; a link cut in two stays a link on both sides.
    static func split(_ spans: [Span], at offset: Int) -> ([Span], [Span]) {
        var head: [Span] = []
        var tail: [Span] = []
        var pos = 0
        for s in spans {
            let n = s.text.utf16.count
            if pos + n <= offset {
                head.append(s)
            } else if pos >= offset {
                tail.append(s)
            } else {
                let idx = String.Index(utf16Offset: offset - pos, in: s.text)
                var a = s
                a.text = String(s.text[..<idx])
                var b = s
                b.text = String(s.text[idx...])
                head.append(a)
                tail.append(b)
            }
            pos += n
        }
        return (normalized(head), normalized(tail))
    }

    static func applyReturn(_ blocks: [Block], at c: Caret) -> ([Block], Caret) {
        guard blocks.indices.contains(c.block) else { return (blocks, c) }
        var out = blocks
        let b = out[c.block]
        switch returnAction(kind: b.kind, text: b.text, offset: c.offset) {
        case .convert(let k):
            out[c.block] = converted(b, to: k)
            return (out, Caret(block: c.block, offset: 0))
        case .insertAbove(let k):
            out.insert(Block(k), at: c.block)
            return (out, Caret(block: c.block + 1, offset: 0))
        case .split(let k):
            let (head, tail) = split(b.spans, at: c.offset)
            out[c.block] = Block(b.kind, checked: b.checked, head)
            out.insert(Block(k, tail), at: c.block + 1)
            return (out, Caret(block: c.block + 1, offset: 0))
        }
    }

    /// Delete with the caret at the start of block `i` (no selection). Matches what the text view does: a
    /// non-paragraph becomes a paragraph; a paragraph joins the block above (taking its kind), except that an
    /// empty block above is simply removed.
    static func applyDeleteAtStart(_ blocks: [Block], block i: Int) -> ([Block], Caret) {
        guard blocks.indices.contains(i) else { return (blocks, Caret(block: 0, offset: 0)) }
        var out = blocks
        if let k = deleteAtStartConverts(out[i].kind) {
            out[i] = converted(out[i], to: k)
            return (out, Caret(block: i, offset: 0))
        }
        guard i > 0 else { return (out, Caret(block: 0, offset: 0)) }
        let above = out[i - 1]
        if above.text.isEmpty {
            out.remove(at: i - 1)
            return (out, Caret(block: i - 1, offset: 0))
        }
        out[i - 1] = Block(above.kind, checked: above.checked, above.spans + out[i].spans)
        out.remove(at: i)
        return (out, Caret(block: i - 1, offset: above.length))
    }

    /// Typed at the start of a paragraph: "[] " makes a to-do, "- " a bullet, "# " a heading.
    static let shortcuts: [(prefix: String, kind: Kind)] = [("[] ", .todo), ("- ", .bullet), ("# ", .heading)]

    /// The shortcut just completed by typing its space (the caret sits right after the prefix), or nil.
    static func shortcut(kind: Kind, text: String, offset: Int) -> (kind: Kind, prefixLength: Int)? {
        guard kind == .paragraph else { return nil }
        for s in shortcuts where text.hasPrefix(s.prefix) && offset == s.prefix.utf16.count {
            return (s.kind, s.prefix.utf16.count)
        }
        return nil
    }

    static func applyShortcut(_ blocks: [Block], at c: Caret) -> ([Block], Caret)? {
        guard blocks.indices.contains(c.block) else { return nil }
        let b = blocks[c.block]
        guard let m = shortcut(kind: b.kind, text: b.text, offset: c.offset) else { return nil }
        var out = blocks
        out[c.block] = Block(m.kind, split(b.spans, at: m.prefixLength).1)
        return (out, Caret(block: c.block, offset: 0))
    }

    // MARK: Slash menu

    struct SlashItem: Equatable {
        let kind: Kind
        let title: String
        /// An SF Symbol name.
        let symbol: String
        let keywords: [String]
    }

    static let slashItems: [SlashItem] = [
        SlashItem(kind: .paragraph, title: "Text", symbol: "text.alignleft", keywords: ["text", "paragraph", "plain"]),
        SlashItem(kind: .heading, title: "Heading", symbol: "textformat.size", keywords: ["heading", "header", "h1"]),
        SlashItem(kind: .bullet, title: "Bullet list", symbol: "list.bullet", keywords: ["bullet", "list"]),
        SlashItem(kind: .todo, title: "To-do", symbol: "checkmark.square", keywords: ["todo", "to-do", "task", "checkbox"]),
    ]

    /// Items whose title words or keywords start with the query (case-insensitive), in menu order.
    static func slashMatches(_ query: String) -> [SlashItem] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return slashItems }
        return slashItems.filter { item in
            let words = item.title.lowercased().split(separator: " ").map(String.init) + item.keywords
            return words.contains { $0.hasPrefix(q) }
        }
    }

    /// The query after "/" while the block is "/query" and the caret is at its end; otherwise nil.
    static func slashQuery(text: String, offset: Int) -> String? {
        guard text.hasPrefix("/"), offset == text.utf16.count else { return nil }
        let q = String(text.dropFirst())
        guard q.utf16.count <= 24, !q.contains("/") else { return nil }
        return q
    }

    /// The open menu: which block, the typed filter, the highlighted row.
    struct SlashState: Equatable {
        var block: Int
        var query: String
        var selected: Int
    }

    /// After any edit. Opens only when "/" is typed into an empty block; stays open while the block reads
    /// "/query" with the caret at its end and something matches; otherwise closes (nil). Escape is simply nil
    /// and leaves the text alone; typing on after Escape does not reopen it.
    static func slashAfterEdit(_ state: SlashState?, block: Int, text: String, offset: Int, typed: String?) -> SlashState? {
        if let s = state {
            guard s.block == block, let q = slashQuery(text: text, offset: offset) else { return nil }
            let n = slashMatches(q).count
            guard n > 0 else { return nil }
            return SlashState(block: block, query: q, selected: q == s.query ? min(s.selected, n - 1) : 0)
        }
        guard typed == "/", text == "/", offset == 1 else { return nil }
        return SlashState(block: block, query: "", selected: 0)
    }

    /// Up and down move the highlight, wrapping around.
    static func slashMove(_ s: SlashState, by delta: Int) -> SlashState {
        let n = slashMatches(s.query).count
        guard n > 0 else { return s }
        var out = s
        out.selected = ((s.selected + delta) % n + n) % n
        return out
    }

    /// Picking an item: the block (which reads "/query") becomes an empty block of that kind.
    static func applySlash(_ blocks: [Block], block i: Int, kind: Kind) -> ([Block], Caret) {
        guard blocks.indices.contains(i) else { return (blocks, Caret(block: 0, offset: 0)) }
        var out = blocks
        out[i] = Block(kind)
        return (out, Caret(block: i, offset: 0))
    }

    // MARK: Copy

    /// Copy on the Summary tab: headings as plain lines (a blank line before each one after the first block),
    /// paragraphs as lines, "- " bullets, "[ ] " and "[x] " to-dos. Ends with a newline.
    static func plainText(_ blocks: [Block]) -> String {
        var lines: [String] = []
        for (i, b) in blocks.enumerated() {
            switch b.kind {
            case .heading:
                if i > 0 { lines.append("") }
                lines.append(b.text)
            case .paragraph:
                lines.append(b.text)
            case .bullet:
                lines.append("- " + b.text)
            case .todo:
                lines.append((b.checked ? "[x] " : "[ ] ") + b.text)
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
