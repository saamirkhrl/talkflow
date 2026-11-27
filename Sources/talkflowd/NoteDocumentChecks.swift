import AppKit

/// Part of `--notestest` (called from NotesSelfTest). The Summary tab's document: conversion from a made-up
/// summary, the editing rules, Copy text, the saved form and the text view's attribute bridge, and the
/// assistant's save and Write again flow. Made-up content only; every note lives in a temp folder removed at the end.
enum NoteDocumentChecks {
    typealias B = NoteDocument.Block
    typealias S = NoteDocument.Span
    typealias Caret = NoteDocument.Caret
    typealias Slash = NoteDocument.SlashState

    static let written = Date(timeIntervalSince1970: 1_792_000_000)
    static let speakers = [NoteSpeaker(key: "you"), NoteSpeaker(key: "s1", name: "Priya")]

    static func fixture() -> NoteSummary {
        NoteSummary(
            summary: "We agreed the beta ships Friday.\nMarketing follows next week.",
            summaryTimes: [12, 75],
            actionItems: [
                NoteSummary.ActionItem(owner: "s1", task: "Send the beta email", time: 30, done: false),
                NoteSummary.ActionItem(owner: "", task: "Book the webinar room", time: 61, done: true),
            ],
            decisions: [
                NoteSummary.Point(text: "Beta ships Friday.", time: 12, status: "aligned"),
                NoteSummary.Point(text: "Pricing page copy.", time: 40, status: "needs_discussion"),
                NoteSummary.Point(text: "Dark icon.", time: 50, status: "disagreed"),
                NoteSummary.Point(text: "Webinar.", time: 60, status: "shelved"),
            ],
            openQuestions: [],
            provider: "Anthropic", model: "claude-test", written: written, parts: 1,
            details: [NoteSummary.Detail(topic: "Beta", text: "Ships Friday to the waitlist.", times: [12, 20])],
            title: nil, subtitle: nil, suggestedNames: nil)
    }

    static let expected: [B] = [
        B(.heading, [S("Summary")]),
        B(.paragraph, [S("We agreed the beta ships Friday.")]),
        B(.paragraph, [S("Marketing follows next week. ("), S("0:12", cite: 12), S(", "), S("1:15", cite: 75), S(")")]),
        B(.heading, [S("Decisions")]),
        B(.bullet, [S("Beta ships Friday. ("), S("0:12", cite: 12), S(")")]),
        B(.heading, [S("Open questions")]),
        B(.bullet, [S("Pricing page copy. ("), S("0:40", cite: 40), S(")")]),
        B(.bullet, [S("Disagreed: ", bold: true), S("Dark icon. ("), S("0:50", cite: 50), S(")")]),
        B(.bullet, [S("Shelved: ", bold: true), S("Webinar. ("), S("1:00", cite: 60), S(")")]),
        B(.heading, [S("Details")]),
        B(.bullet, [S("Beta: ", bold: true), S("Ships Friday to the waitlist. ("), S("0:12", cite: 12), S(", "),
                    S("0:20", cite: 20), S(")")]),
        B(.heading, [S("Action items")]),
        B(.todo, [S("Priya: ", bold: true), S("Send the beta email ("), S("0:30", cite: 30), S(")")]),
        B(.todo, checked: true, [S("Book the webinar room ("), S("1:01", cite: 61), S(")")]),
    ]

    static let expectedCopy = """
        Summary
        We agreed the beta ships Friday.
        Marketing follows next week. (0:12, 1:15)

        Decisions
        - Beta ships Friday. (0:12)

        Open questions
        - Pricing page copy. (0:40)
        - Disagreed: Dark icon. (0:50)
        - Shelved: Webinar. (1:00)

        Details
        - Beta: Ships Friday to the waitlist. (0:12, 0:20)

        Action items
        [ ] Priya: Send the beta email (0:30)
        [x] Book the webinar room (1:01)

        """

    /// Compares two optional results of an edit.
    private static func same(_ a: ([B], Caret)?, _ b: ([B], Caret)?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return x.0 == y.0 && x.1 == y.1
        default: return false
        }
    }

    private static func describe(_ r: ([B], Caret)?) -> String {
        guard let r else { return "nil" }
        return "\(r.0) \(r.1)"
    }

    static func run(_ check: (Bool, String, String) -> Void) {
        let converted = NoteDocument.converting(fixture(), speakers: speakers)

        // MARK: Conversion
        check(converted == expected, "ND1 conversion of the sample summary", "\(converted)")
        let cites = converted.flatMap { $0.spans.compactMap { $0.cite } }
        check(cites == [12, 75, 12, 40, 50, 60, 12, 20, 30, 61], "ND2 citation links survive conversion", "\(cites)")
        let todoOK = converted.count > 13 && converted[12].kind == .todo && converted[13].kind == .todo
        let todoChecked = converted.count > 13 ? [converted[12].checked, converted[13].checked] : []
        check(todoOK && todoChecked == [false, true], "ND3 action items become to-dos, done carried", "\(todoChecked)")

        let old = NoteSummary(
            summary: "Old summary.", summaryTimes: [], actionItems: [],
            decisions: [NoteSummary.Point(text: "Use the old logo.", time: 5)],
            openQuestions: [NoteSummary.Point(text: "Who owns QA?", time: 9)],
            provider: "Anthropic", model: "m", written: written, parts: 1)
        let oldExpected: [B] = [
            B(.heading, [S("Summary")]), B(.paragraph, [S("Old summary.")]), B(.heading, [S("Decisions")]),
            B(.bullet, [S("Use the old logo. ("), S("0:05", cite: 5), S(")")]), B(.heading, [S("Open questions")]),
            B(.bullet, [S("Who owns QA? ("), S("0:09", cite: 9), S(")")]),
        ]
        let oldConverted = NoteDocument.converting(old, speakers: speakers)
        check(oldConverted == oldExpected, "ND4 an old summary (no statuses, open questions, no details) converts", "\(oldConverted)")
        let named = NoteSummary(
            summary: "{{s1}} will send it.", summaryTimes: [], actionItems: [], decisions: [], openQuestions: [],
            provider: "Anthropic", model: "m", written: written, parts: 1)
        let namedBlocks = NoteDocument.converting(named, speakers: speakers)
        check(namedBlocks.count > 1 && namedBlocks[1].text == "Priya will send it.",
              "ND5 speaker references resolve to names", "\(namedBlocks)")

        // MARK: Return
        func ret(_ blocks: [B], _ block: Int, _ offset: Int) -> ([B], Caret)? {
            NoteDocument.applyReturn(blocks, at: Caret(block: block, offset: offset))
        }
        var r = ret([B(.paragraph, [S("Hello world")])], 0, 5)
        check(same(r, ([B(.paragraph, [S("Hello")]), B(.paragraph, [S(" world")])], Caret(block: 1, offset: 0))),
              "ND10 Return in a paragraph splits it", describe(r))
        r = ret([B(.bullet, [S("Item")])], 0, 4)
        check(same(r, ([B(.bullet, [S("Item")]), B(.bullet)], Caret(block: 1, offset: 0))),
              "ND11 Return after a bullet adds a bullet", describe(r))
        r = ret([B(.todo, checked: true, [S("Done")])], 0, 4)
        check(same(r, ([B(.todo, checked: true, [S("Done")]), B(.todo)], Caret(block: 1, offset: 0))),
              "ND12 Return after a to-do adds an unchecked to-do", describe(r))
        r = ret([B(.heading, [S("Title")])], 0, 5)
        check(same(r, ([B(.heading, [S("Title")]), B(.paragraph)], Caret(block: 1, offset: 0))),
              "ND13 Return after a heading adds a paragraph", describe(r))
        r = ret([B(.bullet)], 0, 0)
        check(same(r, ([B(.paragraph)], Caret(block: 0, offset: 0))),
              "ND14 Return on an empty bullet makes a paragraph", describe(r))
        r = ret([B(.todo)], 0, 0)
        check(same(r, ([B(.paragraph)], Caret(block: 0, offset: 0))),
              "ND15 Return on an empty to-do makes a paragraph", describe(r))
        r = ret([B(.heading, [S("Title")])], 0, 0)
        check(same(r, ([B(.paragraph), B(.heading, [S("Title")])], Caret(block: 1, offset: 0))),
              "ND16 Return at the start of a heading adds a paragraph above", describe(r))
        r = ret([B(.paragraph, [S("See ("), S("0:12", cite: 12), S(")")])], 0, 6)
        check(same(r, ([B(.paragraph, [S("See ("), S("0", cite: 12)]), B(.paragraph, [S(":12", cite: 12), S(")")])],
                      Caret(block: 1, offset: 0))),
              "ND17 Return inside a link keeps both halves linked", describe(r))

        // MARK: Delete at the start
        var d = NoteDocument.applyDeleteAtStart([B(.paragraph, [S("A")]), B(.bullet, [S("B")])], block: 1)
        check(same(d, ([B(.paragraph, [S("A")]), B(.paragraph, [S("B")])], Caret(block: 1, offset: 0))),
              "ND20 Delete at the start of a bullet makes a paragraph", describe(d))
        d = NoteDocument.applyDeleteAtStart([B(.todo, checked: true, [S("T")])], block: 0)
        check(same(d, ([B(.paragraph, [S("T")])], Caret(block: 0, offset: 0))),
              "ND21 Delete at the start of a to-do makes an unchecked paragraph", describe(d))
        d = NoteDocument.applyDeleteAtStart([B(.heading, [S("H")])], block: 0)
        check(same(d, ([B(.paragraph, [S("H")])], Caret(block: 0, offset: 0))),
              "ND22 Delete at the start of a heading makes a paragraph", describe(d))
        d = NoteDocument.applyDeleteAtStart([B(.bullet, [S("Item")]), B(.paragraph, [S(" more")])], block: 1)
        check(same(d, ([B(.bullet, [S("Item more")])], Caret(block: 0, offset: 4))),
              "ND23 Delete at the start of a paragraph merges into the block above", describe(d))
        d = NoteDocument.applyDeleteAtStart([B(.heading), B(.paragraph, [S("Text")])], block: 1)
        check(same(d, ([B(.paragraph, [S("Text")])], Caret(block: 0, offset: 0))),
              "ND24 Delete under an empty block removes that block", describe(d))
        d = NoteDocument.applyDeleteAtStart([B(.paragraph, [S("X")])], block: 0)
        check(same(d, ([B(.paragraph, [S("X")])], Caret(block: 0, offset: 0))),
              "ND25 Delete at the start of the first paragraph changes nothing", describe(d))

        // MARK: Typed shortcuts
        var sc = NoteDocument.applyShortcut([B(.paragraph, [S("[] ")])], at: Caret(block: 0, offset: 3))
        check(same(sc, ([B(.todo)], Caret(block: 0, offset: 0))), "ND30 '[] ' makes a to-do", describe(sc))
        sc = NoteDocument.applyShortcut([B(.paragraph, [S("- Buy milk")])], at: Caret(block: 0, offset: 2))
        check(same(sc, ([B(.bullet, [S("Buy milk")])], Caret(block: 0, offset: 0))),
              "ND31 '- ' makes a bullet and keeps the text after it", describe(sc))
        sc = NoteDocument.applyShortcut([B(.paragraph, [S("# ")])], at: Caret(block: 0, offset: 2))
        check(same(sc, ([B(.heading)], Caret(block: 0, offset: 0))), "ND32 '# ' makes a heading", describe(sc))
        let n1 = NoteDocument.applyShortcut([B(.paragraph, [S("a - ")])], at: Caret(block: 0, offset: 4))
        let n2 = NoteDocument.applyShortcut([B(.bullet, [S("- ")])], at: Caret(block: 0, offset: 2))
        let n3 = NoteDocument.applyShortcut([B(.paragraph, [S("- x")])], at: Caret(block: 0, offset: 3))
        check(n1 == nil && n2 == nil && n3 == nil, "ND33 no shortcut mid-text or outside a paragraph",
              "\(describe(n1)) \(describe(n2)) \(describe(n3))")

        // MARK: Slash menu
        check(NoteDocument.slashQuery(text: "/", offset: 1) == "" && NoteDocument.slashQuery(text: "/to", offset: 3) == "to"
              && NoteDocument.slashQuery(text: "/to", offset: 2) == nil && NoteDocument.slashQuery(text: "x/", offset: 2) == nil,
              "ND40 slash query", "")
        func kinds(_ q: String) -> [NoteDocument.Kind] { NoteDocument.slashMatches(q).map(\.kind) }
        check(kinds("") == [.paragraph, .heading, .bullet, .todo] && kinds("t") == [.paragraph, .todo]
              && kinds("to") == [.todo] && kinds("h") == [.heading] && kinds("li") == [.bullet] && kinds("zz") == [],
              "ND41 slash filter", "\(kinds("")) \(kinds("t")) \(kinds("to")) \(kinds("h")) \(kinds("li")) \(kinds("zz"))")
        let opened = NoteDocument.slashAfterEdit(nil, block: 2, text: "/", offset: 1, typed: "/")
        check(opened == Slash(block: 2, query: "", selected: 0), "ND42 '/' typed in an empty block opens the menu", "\(String(describing: opened))")
        let filtered = NoteDocument.slashAfterEdit(Slash(block: 2, query: "", selected: 1), block: 2, text: "/to", offset: 3, typed: "o")
        check(filtered == Slash(block: 2, query: "to", selected: 0), "ND43 typing filters and resets the highlight", "\(String(describing: filtered))")
        let c1 = NoteDocument.slashAfterEdit(Slash(block: 2, query: "", selected: 0), block: 2, text: "/zz", offset: 3, typed: "z")
        let c2 = NoteDocument.slashAfterEdit(Slash(block: 2, query: "", selected: 0), block: 3, text: "/", offset: 1, typed: nil)
        let c3 = NoteDocument.slashAfterEdit(nil, block: 0, text: "a/", offset: 2, typed: "/")
        check(c1 == nil && c2 == nil && c3 == nil, "ND44 no match, another block or a non-empty block closes or never opens",
              "\(String(describing: c1)) \(String(describing: c2)) \(String(describing: c3))")
        check(NoteDocument.slashMove(Slash(block: 0, query: "", selected: 0), by: 1).selected == 1
              && NoteDocument.slashMove(Slash(block: 0, query: "", selected: 0), by: -1).selected == 3,
              "ND45 up and down wrap", "")
        let picked = NoteDocument.applySlash([B(.paragraph, [S("A")]), B(.paragraph, [S("/to")])], block: 1, kind: .todo)
        check(same(picked, ([B(.paragraph, [S("A")]), B(.todo)], Caret(block: 1, offset: 0))),
              "ND46 picking converts the block and removes '/query'", describe(picked))
        let escBlocks = [B(.paragraph, [S("/to")])]
        let afterEsc = NoteDocument.slashAfterEdit(nil, block: 0, text: "/tox", offset: 4, typed: "x")
        check(afterEsc == nil && escBlocks[0].text == "/to",
              "ND47 Escape leaves the text and does not reopen while typing", "\(String(describing: afterEsc))")

        // MARK: Toggle, Copy, saved form
        let todoA = B(.todo, [S("a")])
        check(NoteDocument.toggled(todoA).checked && NoteDocument.toggled(NoteDocument.toggled(todoA)) == todoA
              && NoteDocument.toggled(B(.bullet, [S("a")])) == B(.bullet, [S("a")]),
              "ND50 toggling a to-do", "")
        let copy = NoteDocument.plainText(expected)
        check(copy == expectedCopy, "ND51 Copy text", copy)

        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let doc = NoteDocument(basedOn: written.timeIntervalSince1970, blocks: expected)
        let roundTrip = (try? enc.encode(doc)).flatMap { try? dec.decode(NoteDocument.self, from: $0) }
        check(roundTrip == doc, "ND52 encode and decode round trip", "")
        let j1 = (try? enc.encode(B(.bullet, [S("A")]))).flatMap { String(data: $0, encoding: .utf8) }
        let j2 = (try? enc.encode(B(.todo, checked: true, [S("0:12", cite: 12)]))).flatMap { String(data: $0, encoding: .utf8) }
        check(j1 == #"{"kind":"bullet","spans":[{"text":"A"}]}"#
              && j2 == #"{"checked":true,"kind":"todo","spans":[{"cite":12,"text":"0:12"}]}"#,
              "ND53 compact JSON", "\(String(describing: j1)) \(String(describing: j2))")
        let unknown = #"{"kind":"table","spans":[{"text":"x"}]}"#.data(using: .utf8).flatMap { try? dec.decode(B.self, from: $0) }
        check(unknown == B(.paragraph, [S("x")]), "ND54 unknown kind reads as a paragraph", "\(String(describing: unknown))")

        // MARK: Bridge (no window)
        let (text, tail) = DocText.attributed(expected)
        let back = DocText.blocks(from: text, tail: tail)
        check(back == expected, "ND60 attributed text round trip", "\(back)")
        let emptyIn = [B(.paragraph, [S("x")]), B(.todo)]
        let (t2, tail2) = DocText.attributed(emptyIn)
        check(t2.string == "x\n" && DocText.blocks(from: t2, tail: tail2) == emptyIn,
              "ND61 empty last block survives", t2.string.debugDescription)

        let ns = text.string as NSString
        let linkAt = ns.range(of: "(0:12").location + 1
        let linkValue = text.attribute(.link, at: linkAt, effectiveRange: nil)
        let linkOK = DocText.citeTime(linkValue) == 12
        let betaAt = ns.range(of: "Beta: ").location
        let betaStyle = text.attribute(.paragraphStyle, at: betaAt, effectiveRange: nil) as? NSParagraphStyle
        let headFont = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let bookAt = ns.range(of: "Book the webinar room").location
        let strike = (text.attribute(.strikethroughStyle, at: bookAt, effectiveRange: nil) as? NSNumber)?.intValue
        check(linkOK && betaStyle?.headIndent == DocStyle.listIndent && headFont?.pointSize == DocStyle.headingSize
              && strike == NSUnderlineStyle.single.rawValue,
              "ND62 link and styles",
              "link \(linkOK) indent \(String(describing: betaStyle?.headIndent)) font \(String(describing: headFont?.pointSize)) strike \(String(describing: strike))")

        let merged = NSMutableAttributedString(string: "a", attributes: [.docKind: "bullet"])
        merged.append(NSAttributedString(string: "b", attributes: [.docKind: "paragraph"]))
        DocText.restyle(merged, around: NSRange(location: 0, length: 2), tail: B(.paragraph))
        check(DocText.kind(merged, at: 0) == .bullet && DocText.kind(merged, at: 1) == .bullet,
              "ND63 restyle makes a merged paragraph one kind", "\(DocText.kind(merged, at: 0)) \(DocText.kind(merged, at: 1))")
        let bp = DocStyle.baselineOffset(.paragraph)
        let bh = DocStyle.baselineOffset(.heading)
        check(bp > 0 && bp <= DocStyle.bodyLineHeight && bh > 0 && bh <= DocStyle.headingLineHeight,
              "ND64 empty-line baseline", "\(bp) \(bh)")

        storeChecks(check)
    }

    // MARK: Store and assistant

    private static func storeChecks(_ check: (Bool, String, String) -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "talkflow-notestest-document-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = NoteStore(root: root)
        guard let created = try? store.create(title: "Doc test", started: written) else {
            check(false, "ND70 an old note without document.json opens as before", "could not create the test note")
            return
        }
        let id = created.id
        try? store.save(fixture(), for: id)
        try? store.save(Transcript(turns: [TranscriptTurn(speaker: "you", start: 0, end: 5, text: "Hello.")]), for: id)

        var confirmed: String? = nil
        let assistant = NoteAssistant(
            store: store,
            client: NotesAIClient(transport: CannedNotesTransport([]), keyFor: { _ in "k-test" }),
            access: { NotesAccess.resolve(hasAnthropic: { true }, hasOpenAI: { false }, anthropicModel: nil, openAIModel: nil) },
            confirmedProvider: { confirmed }, setConfirmedProvider: { confirmed = $0 })
        guard let meta = store.meta(id) else {
            check(false, "ND70 an old note without document.json opens as before", "no meta")
            return
        }
        let summaryFile = store.folder(for: id).appendingPathComponent("summary.json")
        let docFile = store.folder(for: id).appendingPathComponent("document.json")

        // ND70
        let noDoc = store.document(id) == nil
        assistant.load(id)
        let readBack = store.summary(id)
        let fresh = NoteDocument.converting(fixture(), speakers: meta.speakers)
        check(noDoc && assistant.summary == readBack && readBack != nil
              && assistant.document(for: meta)?.blocks == fresh && !assistant.documentEdited,
              "ND70 an old note without document.json opens as before", "noDoc \(noDoc) edited \(assistant.documentEdited)")

        // ND71, ND72
        let before = try? Data(contentsOf: summaryFile)
        var edited = fresh
        if edited.indices.contains(12) { edited[12] = NoteDocument.toggled(edited[12]) }
        assistant.editDocument(edited)
        let notYet = store.document(id) == nil
        let inMemory = assistant.document(for: meta)?.blocks == edited
        assistant.flushDocument()
        let written = store.document(id)?.blocks == edited
        check(notYet && inMemory && written, "ND71 an edit is kept in memory and written only after the delay or a flush",
              "notYet \(notYet) inMemory \(inMemory) written \(written)")
        let after = try? Data(contentsOf: summaryFile)
        check(before != nil && after == before, "ND72 saving the document never touches summary.json", "")

        // ND73
        var asked = 0
        assistant.confirmReplaceEdits = { asked += 1; return false }
        assistant.writeAgain(id)
        let declined = asked == 1 && assistant.pending == nil
        assistant.confirmReplaceEdits = { asked += 1; return true }
        assistant.writeAgain(id)
        let accepted = asked == 2 && assistant.pending == .summary(id)
        assistant.cancelPending()
        check(declined && accepted, "ND73 an edited document asks before Write again", "asked \(asked)")

        // ND74
        let plain = NoteDocument(basedOn: fixture().written.timeIntervalSince1970, blocks: fresh)
        try? store.save(plain, for: id)
        assistant.load(nil)
        assistant.load(id)
        asked = 0
        assistant.confirmReplaceEdits = { asked += 1; return false }
        assistant.writeAgain(id)
        check(asked == 0 && assistant.pending == .summary(id), "ND74 an unedited document does not ask", "asked \(asked)")
        assistant.cancelPending()

        // ND75
        try? store.save(NoteDocument(basedOn: fixture().written.timeIntervalSince1970, blocks: edited), for: id)
        var newer = fixture()
        newer.written = newer.written.addingTimeInterval(60)
        newer.summary = "New summary."
        try? store.save(newer, for: id)
        assistant.load(id)
        let firstParagraph = assistant.document(for: meta)?.blocks.first(where: { $0.kind == .paragraph })?.text
        check(firstParagraph?.hasPrefix("New summary.") == true && !assistant.documentEdited && store.document(id)?.blocks == edited,
              "ND75 a summary written again makes the saved document stale, without deleting it",
              "\(String(describing: firstParagraph))")

        // ND76
        try? #"{"schemaVersion":99,"basedOn":0,"blocks":[]}"#.data(using: .utf8)?.write(to: docFile)
        check(store.document(id) == nil, "ND76 a newer document.json is ignored", "")

        // ND77
        try? store.save(fixture(), for: id)
        assistant.load(nil)
        assistant.load(id)
        assistant.editDocument(expected)
        assistant.load(nil)
        check(store.document(id)?.blocks == expected, "ND77 leaving the note writes a waiting edit", "")
    }
}
