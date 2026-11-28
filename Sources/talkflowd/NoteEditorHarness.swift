import AppKit
import SwiftUI

/// Part of `--notestest` (called from NotesSelfTest): the Summary document editor driven the way typing drives it.
/// The real NotesDocumentView (SwiftUI wrapper, coordinator, DocTextView, its storage delegate) is hosted in an
/// offscreen window that is never shown, with a real NoteAssistant on a note in a temp folder. Actions are AppKit
/// calls on the text view itself (insertText, doCommand, setSelectedRange, mouseDown with a made-up event); after
/// each one the main run loop is pumped and SwiftUI is made to re-render, so the binding write and updateNSView run
/// as they do in the app. No system events, no keystrokes sent to the Mac. Made-up content only.
enum NoteEditorHarness {
    typealias Kind = NoteDocument.Kind
    typealias B = NoteDocument.Block
    typealias S = NoteDocument.Span

    /// One block as the checks compare it.
    struct Row: Equatable, CustomStringConvertible {
        var kind: Kind
        var checked = false
        var text: String
        var description: String { "\(kind.rawValue)\(checked ? "[x]" : ""):\(text.debugDescription)" }
    }

    static func rows(_ blocks: [B]) -> [Row] {
        blocks.map { Row(kind: $0.kind, checked: $0.checked, text: $0.text) }
    }

    /// The fixture document (NoteDocumentChecks.expected), as rows. Indexes used by the cases:
    ///  0 heading "Summary"            1 paragraph "We agreed the beta ships Friday."
    ///  2 paragraph "Marketing follows next week. (0:12, 1:15)" (cites at offsets 30-33 and 36-39)
    ///  3 heading "Decisions"          4 bullet "Beta ships Friday. (0:12)"
    ///  5 heading "Open questions"     6 bullet "Pricing page copy. (0:40)"
    ///  7 bullet "Disagreed: Dark icon. (0:50)"   8 bullet "Shelved: Webinar. (1:00)"
    ///  9 heading "Details"           10 bullet "Beta: Ships Friday to the waitlist. (0:12, 0:20)"
    /// 11 heading "Action items"      12 todo "Priya: Send the beta email (0:30)"
    /// 13 todo checked "Book the webinar room (1:01)" (the last block)
    static var base: [Row] { rows(NoteDocumentChecks.expected) }

    // MARK: The rig

    final class Rig {
        let root: URL
        let store: NoteStore
        let id: String
        let meta: NoteMeta
        let assistant: NoteAssistant
        let window: NSWindow
        private(set) var host: NSHostingView<AnyView>?
        private(set) var tv: DocTextView?
        /// Set when an action did not lead to an updateNSView call (the harness would not be testing the wrapper).
        var missedUpdate = false

        init?() {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "talkflow-notestest-editor-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            store = NoteStore(root: root)
            guard let created = try? store.create(title: "Editor test", started: NoteDocumentChecks.written) else { return nil }
            id = created.id
            try? store.save(NoteDocumentChecks.fixture(), for: id)
            try? store.save(Transcript(turns: [TranscriptTurn(speaker: "you", start: 0, end: 5, text: "Hello.")]), for: id)
            guard var m = store.meta(id) else { return nil }
            // Speaker s1 named Priya, so block 12 reads "Priya: ..." as in NoteDocumentChecks.expected.
            m.speakers = NoteDocumentChecks.speakers
            try? store.save(m)
            meta = m
            assistant = NoteAssistant(
                store: store,
                client: NotesAIClient(transport: CannedNotesTransport([]), keyFor: { _ in "k-test" }),
                access: { nil }, confirmedProvider: { nil }, setConfirmedProvider: { _ in })
            assistant.confirmReplaceEdits = { true }
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 1400), styleMask: [.titled],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            assistant.load(id)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        var documentFile: URL { store.folder(for: id).appendingPathComponent("document.json") }

        /// Runs the main run loop briefly (timers, main-queue work, SwiftUI transactions) and lays the window out.
        func pump(_ seconds: TimeInterval = 0.02) {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
            host?.layoutSubtreeIfNeeded()
        }

        /// Makes SwiftUI re-render the Summary document (as any published change in the app does), so
        /// NoteDocumentEditor.updateNSView runs with whatever blocks the assistant now gives it.
        func rerender() {
            let before = NoteDocumentEditor.updateCount
            assistant.objectWillChange.send()
            pump()
            if NoteDocumentEditor.updateCount == before { missedUpdate = true }
        }

        /// A new editor on screen, as when the Summary tab opens, with keyboard focus.
        func open() {
            let view = NotesDocumentView(assistant: assistant, meta: meta, summary: assistant.summary ?? NoteDocumentChecks.fixture())
                .frame(width: 760, alignment: .topLeading)
            let h = NSHostingView(rootView: AnyView(view))
            h.frame = NSRect(x: 0, y: 0, width: 800, height: 1400)
            window.contentView = h
            host = h
            pump()
            tv = Rig.find(h)
            if let tv { window.makeFirstResponder(tv) }
            pump()
        }

        /// The editor leaves the screen (its dismantle flushes a waiting edit).
        func close() {
            window.makeFirstResponder(nil)
            window.contentView = NSView()
            host = nil
            tv = nil
            pump()
        }

        /// Back to the fixture: no document.json, the note opened again, a new editor.
        func reset() {
            close()
            assistant.flushDocument()
            try? FileManager.default.removeItem(at: documentFile)
            assistant.load(nil)
            assistant.load(id)
            missedUpdate = false
            open()
        }

        static func find(_ v: NSView) -> DocTextView? {
            if let t = v as? DocTextView { return t }
            for s in v.subviews { if let t = find(s) { return t } }
            return nil
        }

        /// The editor that is on screen now (nil or a different object means SwiftUI rebuilt it).
        var current: DocTextView? { host.flatMap { Rig.find($0) } }

        // MARK: Actions (each followed by a re-render)

        /// Puts the caret in block `block` at UTF-16 offset `offset`.
        func caret(_ block: Int, _ offset: Int) {
            guard let tv else { return }
            let list = DocText.paragraphs(tv.string as NSString)
            guard list.indices.contains(block) else { return }
            tv.setSelectedRange(NSRange(location: list[block].content.location + offset, length: 0))
            rerender()
        }

        /// Types `s` one character per insertText, as keystrokes arrive. `pumpEach` false types them back to back
        /// with no run loop turn in between (fast typing); the re-render then happens once at the end.
        func type(_ s: String, pumpEach: Bool = true) {
            guard let tv else { return }
            for ch in s {
                tv.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0))
                if pumpEach { rerender() }
            }
            if !pumpEach { rerender() }
        }

        func command(_ sel: Selector) {
            tv?.doCommand(by: sel)
            rerender()
        }

        func undo() {
            tv?.undoManager?.undo()
            rerender()
        }

        /// A click on block `block`'s to-do box: a made-up mouse-down event handed to the view's mouseDown.
        func clickCheckbox(_ block: Int) {
            guard let tv, let base = tv.baseline(ofParagraph: block) else { return }
            let r = DocStyle.checkboxRect(x: tv.textContainerOrigin.x, baseline: base)
            let p = tv.convert(NSPoint(x: r.midX, y: r.midY), to: nil)
            guard let e = NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [], timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: 1, pressure: 1) else { return }
            tv.mouseDown(with: e)
            rerender()
        }

        // MARK: Reading

        /// Line fragments (top, height, used width) of a text view, to compare with a fresh load of the same blocks.
        static func geometry(_ tv: DocTextView) -> [String] {
            guard let lm = tv.layoutManager, let tc = tv.textContainer else { return [] }
            lm.ensureLayout(for: tc)
            var out: [String] = []
            var i = 0
            while i < lm.numberOfGlyphs {
                var r = NSRange()
                let frag = lm.lineFragmentRect(forGlyphAt: i, effectiveRange: &r)
                let used = lm.boundingRect(forGlyphRange: r, in: tc)
                out.append("\(Int(frag.minY.rounded()))/\(Int(frag.height.rounded()))/\(Int(used.width.rounded()))")
                i = max(NSMaxRange(r), i + 1)
            }
            return out
        }

        static func freshGeometry(_ blocks: [B], width: CGFloat) -> [String] {
            let other = DocTextView.make()
            other.setFrameSize(NSSize(width: width, height: 200))
            other.load(blocks)
            return geometry(other)
        }

        /// Everything wrong with the editor's state against the expected rows and caret (block, offset); empty
        /// when it all matches. Checks the full text, the caret, every block's kind and tick, that the assistant
        /// holds what the editor shows (the binding write), that SwiftUI kept the same editor, that every action
        /// reached updateNSView, and that the layout equals a fresh load of the same blocks (styles applied).
        func problems(_ want: [Row], caret: (Int, Int)?) -> [String] {
            guard let tv else { return ["no editor"] }
            var out: [String] = []
            let text = want.map(\.text).joined(separator: "\n")
            if tv.string != text { out.append("text \(tv.string.debugDescription)") }
            if let caret {
                let abs = want.prefix(caret.0).reduce(0) { $0 + $1.text.utf16.count + 1 } + caret.1
                if tv.selectedRange() != NSRange(location: abs, length: 0) {
                    out.append("caret \(tv.selectedRange()) want {\(abs), 0}")
                }
            }
            let got = NoteEditorHarness.rows(tv.blocks)
            if got.map({ "\($0.kind)\($0.checked)" }) != want.map({ "\($0.kind)\($0.checked)" }) {
                out.append("kinds \(got)")
            }
            if assistant.document(for: meta)?.blocks != tv.blocks { out.append("assistant copy differs from the editor") }
            if current !== tv { out.append("SwiftUI rebuilt the editor") }
            if missedUpdate { out.append("an action did not reach updateNSView") }
            if Rig.geometry(tv) != Rig.freshGeometry(tv.blocks, width: tv.frame.width) { out.append("layout differs from a fresh load") }
            return out
        }
    }

    // MARK: Checks

    static func run(_ check: (Bool, String, String) -> Void) {
        _ = NSApplication.shared
        guard let rig = Rig() else {
            check(false, "NE0 editor harness set up", "could not create the test note")
            return
        }
        defer { rig.close() }
        rig.open()
        check(rig.tv != nil && rig.problems(base, caret: (0, 0)).isEmpty, "NE0 editor harness hosts the real editor",
              rig.problems(base, caret: (0, 0)).joined(separator: "; "))

        func expect(_ label: String, _ want: [Row], caret: (Int, Int)?) {
            let p = rig.problems(want, caret: caret)
            check(p.isEmpty, label, p.joined(separator: "; "))
        }

        // NE1 type in the middle of a paragraph
        rig.reset()
        rig.caret(1, 3)
        rig.type("x")
        var w = base
        w[1].text = "We xagreed the beta ships Friday."
        expect("NE1 typing mid paragraph inserts at the caret, kinds unchanged", w, caret: (1, 4))

        // NE2 type in the middle of a heading, then a second character
        rig.reset()
        rig.caret(0, 3)
        rig.type("xy")
        w = base
        w[0].text = "Sumxymary"
        expect("NE2 typing mid heading inserts at the caret, kinds unchanged", w, caret: (0, 5))

        // CASES-START (the worker adds the remaining cases here, in the order of the spec)
        /// expect() plus one more condition (slash state, store copy, exact spans).
        func expectAlso(_ label: String, _ want: [Row], caret: (Int, Int)?, _ ok: Bool, _ detail: String) {
            var p = rig.problems(want, caret: caret)
            if !ok { p.append(detail) }
            check(p.isEmpty, label, p.joined(separator: "; "))
        }
        func newParagraphBelow() {
            rig.reset()
            rig.caret(1, 32)
            rig.command(#selector(NSResponder.insertNewline(_:)))
        }
        func slashState() -> String { "slash \(String(describing: rig.tv?.slash))" }

        // Typing
        rig.reset()
        rig.caret(6, 4)
        rig.type("x")
        w = base
        w[6].text = "Pricxing page copy. (0:40)"
        expect("NE3 typing mid bullet", w, caret: (6, 5))

        rig.reset()
        rig.caret(12, 10)
        rig.type("x")
        w = base
        w[12].text = "Priya: Senxd the beta email (0:30)"
        expect("NE4 typing mid to-do", w, caret: (12, 11))

        rig.reset()
        rig.caret(0, 3)
        rig.type("abc", pumpEach: false)
        w = base
        w[0].text = "Sumabcmary"
        expect("NE5 fast typing, no run loop turn between keys", w, caret: (0, 6))

        rig.reset()
        rig.caret(1, 32)
        rig.type(" Yes")
        w = base
        w[1].text = "We agreed the beta ships Friday. Yes"
        expect("NE6 several characters at the end of a paragraph", w, caret: (1, 36))

        rig.reset()
        rig.caret(3, 9)
        rig.type("!")
        w = base
        w[3].text = "Decisions!"
        expect("NE7 typing at the end of a heading", w, caret: (3, 10))

        rig.reset()
        rig.caret(1, 0)
        rig.type("x")
        w = base
        w[1].text = "xWe agreed the beta ships Friday."
        expect("NE8 typing at the start of a paragraph under a heading", w, caret: (1, 1))

        rig.reset()
        rig.caret(4, 0)
        rig.type("x")
        w = base
        w[4].text = "xBeta ships Friday. (0:12)"
        expect("NE9 typing at the start of a bullet", w, caret: (4, 1))

        rig.reset()
        rig.caret(12, 0)
        rig.type("x")
        w = base
        w[12].text = "xPriya: Send the beta email (0:30)"
        expect("NE10 typing at the start of a to-do", w, caret: (12, 1))

        rig.reset()
        rig.caret(5, 0)
        rig.type("x")
        w = base
        w[5].text = "xOpen questions"
        expect("NE11 typing at the start of a heading", w, caret: (5, 1))

        rig.reset()
        rig.caret(13, 28)
        rig.type("!")
        w = base
        w[13].text = "Book the webinar room (1:01)!"
        expect("NE12 typing at the end of the last block", w, caret: (13, 29))

        // Return
        rig.reset()
        rig.caret(4, 5)
        rig.command(#selector(NSResponder.insertNewline(_:)))
        w = base
        w[4].text = "Beta "
        w.insert(Row(kind: .bullet, text: "ships Friday. (0:12)"), at: 5)
        expect("NE13 Return mid bullet splits into two bullets", w, caret: (5, 0))
        rig.type("x")
        w[5].text = "xships Friday. (0:12)"
        expect("NE14 typing after the split lands in the new bullet", w, caret: (5, 1))

        rig.reset()
        rig.caret(0, 7)
        rig.command(#selector(NSResponder.insertNewline(_:)))
        w = base
        w.insert(Row(kind: .paragraph, text: ""), at: 1)
        expect("NE15 Return at the end of a heading adds a paragraph", w, caret: (1, 0))
        rig.type("Hi")
        w[1].text = "Hi"
        expect("NE16 typing in the new paragraph", w, caret: (1, 2))

        rig.reset()
        rig.caret(12, 33)
        rig.command(#selector(NSResponder.insertNewline(_:)))
        w = base
        w.insert(Row(kind: .todo, text: ""), at: 13)
        expect("NE17 Return at the end of a to-do adds an empty to-do", w, caret: (13, 0))
        rig.command(#selector(NSResponder.insertNewline(_:)))
        w[13] = Row(kind: .paragraph, text: "")
        expect("NE18 Return on an empty to-do makes it a paragraph", w, caret: (13, 0))

        rig.reset()
        rig.caret(13, 28)
        rig.command(#selector(NSResponder.insertNewline(_:)))
        w = base
        w.append(Row(kind: .todo, text: ""))
        expect("NE19 Return at the end of the last block adds an empty to-do", w, caret: (14, 0))
        rig.command(#selector(NSResponder.insertNewline(_:)))
        w[14] = Row(kind: .paragraph, text: "")
        expect("NE20 Return on the empty last to-do makes it a paragraph", w, caret: (14, 0))

        // Delete
        rig.reset()
        rig.caret(4, 0)
        rig.command(#selector(NSResponder.deleteBackward(_:)))
        w = base
        w[4].kind = .paragraph
        expect("NE21 Delete at the start of a bullet makes it a paragraph", w, caret: (4, 0))

        rig.reset()
        rig.caret(2, 0)
        rig.command(#selector(NSResponder.deleteBackward(_:)))
        w = base
        w[1].text = "We agreed the beta ships Friday.Marketing follows next week. (0:12, 1:15)"
        w.remove(at: 2)
        expect("NE22 Delete at the start of a paragraph merges it up", w, caret: (1, 32))

        rig.reset()
        rig.caret(1, 0)
        rig.command(#selector(NSResponder.deleteBackward(_:)))
        w = base
        w[0].text = "SummaryWe agreed the beta ships Friday."
        w.remove(at: 1)
        expect("NE23 Delete at the start of a paragraph under a heading merges into the heading", w, caret: (0, 7))

        // Typed shortcuts
        newParagraphBelow()
        rig.type("[] ")
        w = base
        w.insert(Row(kind: .todo, text: ""), at: 2)
        expect("NE24 '[] ' makes a to-do", w, caret: (2, 0))

        newParagraphBelow()
        rig.type("- ")
        w = base
        w.insert(Row(kind: .bullet, text: ""), at: 2)
        expect("NE25 '- ' makes a bullet", w, caret: (2, 0))

        newParagraphBelow()
        rig.type("# ")
        w = base
        w.insert(Row(kind: .heading, text: ""), at: 2)
        expect("NE26 '# ' makes a heading", w, caret: (2, 0))

        newParagraphBelow()
        rig.type("- ")
        rig.type("Milk")
        w = base
        w.insert(Row(kind: .bullet, text: "Milk"), at: 2)
        expect("NE27 typing after '- ' stays a bullet", w, caret: (2, 4))

        // Slash
        newParagraphBelow()
        rig.type("/")
        w = base
        w.insert(Row(kind: .paragraph, text: "/"), at: 2)
        expectAlso("NE28 '/' opens the slash menu", w, caret: (2, 1), rig.tv?.slash != nil, slashState())
        rig.command(#selector(NSResponder.moveDown(_:)))
        rig.command(#selector(NSResponder.moveDown(_:)))
        rig.command(#selector(NSResponder.moveDown(_:)))
        rig.command(#selector(NSResponder.insertNewline(_:)))
        w[2] = Row(kind: .todo, text: "")
        expectAlso("NE29 picking To-do converts the block and removes '/'", w, caret: (2, 0), rig.tv?.slash == nil, slashState())

        newParagraphBelow()
        rig.type("/")
        rig.command(#selector(NSResponder.cancelOperation(_:)))
        w = base
        w.insert(Row(kind: .paragraph, text: "/"), at: 2)
        expectAlso("NE30 Escape leaves '/' as text", w, caret: (2, 1), rig.tv?.slash == nil, slashState())

        // To-do box
        rig.reset()
        rig.caret(1, 3)
        rig.clickCheckbox(12)
        w = base
        w[12].checked = true
        expect("NE31 ticking a to-do changes only that block, caret stays", w, caret: (1, 3))
        rig.clickCheckbox(13)
        w[13].checked = false
        expect("NE32 unticking the checked to-do", w, caret: (1, 3))

        // Citation links
        func spansCase(_ label: String, caretAt: Int, typed: String, text: String, caretAfter: Int, _ spans: [S]) {
            rig.reset()
            rig.caret(2, caretAt)
            rig.type(typed)
            var r = base
            r[2].text = text
            let eb: [B] = { var b = NoteDocumentChecks.expected; b[2] = B(.paragraph, spans); return b }()
            expectAlso(label, r, caret: (2, caretAfter), rig.tv?.blocks == eb,
                       "block 2 \(String(describing: rig.tv?.blocks[2]))")
        }
        spansCase("NE33 typing right after a citation keeps the link, typed text is plain", caretAt: 34, typed: "x",
                  text: "Marketing follows next week. (0:12x, 1:15)", caretAfter: 35,
                  [S("Marketing follows next week. ("), S("0:12", cite: 12), S("x, "), S("1:15", cite: 75), S(")")])
        spansCase("NE34 typing inside a citation leaves the link on both untouched parts", caretAt: 32, typed: "x",
                  text: "Marketing follows next week. (0:x12, 1:15)", caretAfter: 33,
                  [S("Marketing follows next week. ("), S("0:", cite: 12), S("x"), S("12", cite: 12), S(", "),
                   S("1:15", cite: 75), S(")")])
        spansCase("NE35 typing right before a citation", caretAt: 30, typed: "x",
                  text: "Marketing follows next week. (x0:12, 1:15)", caretAfter: 31,
                  [S("Marketing follows next week. (x"), S("0:12", cite: 12), S(", "), S("1:15", cite: 75), S(")")])

        // Undo
        rig.reset()
        rig.caret(0, 3)
        rig.type("abc")
        rig.undo()
        expect("NE36 undo after typing restores text and kinds", base, caret: (0, 3))

        rig.reset()
        rig.caret(4, 0)
        rig.command(#selector(NSResponder.deleteBackward(_:)))
        rig.undo()
        // Undoing a kind change selects the block it restores (block 4 with its line break: {93, 26}), as Undo
        // selects what it brings back anywhere in a Mac text view.
        expectAlso("NE37 undo after Delete at the start of a bullet restores the bullet", base, caret: nil,
                   rig.tv?.selectedRange() == NSRange(location: 93, length: 26), "selection \(String(describing: rig.tv?.selectedRange()))")

        rig.reset()
        rig.caret(1, 0)
        rig.command(#selector(NSResponder.deleteBackward(_:)))
        rig.undo()
        // Undo brings back the line break and the paragraph's kind, and selects the paragraph ({8, 33}).
        expectAlso("NE38 undo after merging a paragraph into a heading restores both", base, caret: nil,
                   rig.tv?.selectedRange() == NSRange(location: 8, length: 33), "selection \(String(describing: rig.tv?.selectedRange()))")

        rig.reset()
        rig.caret(0, 7)
        rig.command(#selector(NSResponder.deleteForward(_:)))
        w = base
        w[0].text = "SummaryWe agreed the beta ships Friday."
        w.remove(at: 1)
        expect("NE44 forward delete at the end of a heading pulls the paragraph up into it", w, caret: (0, 7))
        rig.undo()
        expectAlso("NE45 undo after forward delete restores both blocks and kinds", base, caret: nil,
                   rig.tv?.selectedRange() == NSRange(location: 8, length: 33), "selection \(String(describing: rig.tv?.selectedRange()))")

        // Save and reload
        func storeMatches() -> Bool { rig.store.document(rig.id)?.blocks == rig.tv?.blocks }
        rig.reset()
        rig.caret(0, 3)
        rig.type("x")
        rig.caret(4, 4)
        rig.type("y")
        rig.caret(12, 10)
        rig.type("z")
        rig.pump(1.0)
        w = base
        w[0].text = "Sumxmary"
        w[4].text = "Betay ships Friday. (0:12)"
        w[12].text = "Priya: Senzd the beta email (0:30)"
        expectAlso("NE39 edits in a heading, a bullet and a to-do are saved after the delay", w, caret: (12, 11),
                   storeMatches(), "saved document differs from the editor")
        shot(rig, name: "60-editor-after-typing")

        rig.type("q")
        rig.pump(1.0)
        rig.type("r")
        w[12].text = "Priya: Senzqrd the beta email (0:30)"
        // The "r" is not on disk yet (its save waits 0.8 s); the assistant's copy is checked by problems().
        expect("NE40 the autosave between two keystrokes does not reset the editor", w, caret: (12, 13))

        rig.pump(1.0)
        rig.assistant.load(rig.id)
        rig.rerender()
        expectAlso("NE41 the note re-read from disk (refresh) keeps the editor as it is", w, caret: (12, 13),
                   storeMatches(), "saved document differs from the editor")

        rig.close()
        rig.open()
        expectAlso("NE42 a new editor opens the saved document", w, caret: (0, 0),
                   storeMatches(), "saved document differs from the editor")

        var s2 = NoteDocumentChecks.fixture()
        s2.written = NoteDocumentChecks.written.addingTimeInterval(100)
        s2.summary = "Replaced summary."
        s2.summaryTimes = [12]
        try? rig.store.save(s2, for: rig.id)
        rig.assistant.load(rig.id)
        rig.rerender()
        expect("NE43 a new summary (Write again) replaces the document",
               rows(NoteDocument.converting(s2, speakers: rig.meta.speakers)), caret: (0, 0))
        // CASES-END
    }

    /// With TALKFLOW_EDITOR_SHOT set to a folder, renders the rig's hosting view there as <name>-light.png and
    /// <name>-dark.png (the page color behind it). Does nothing, and writes nothing, when it is unset.
    static func shot(_ rig: Rig, name: String) {
        guard let folder = ProcessInfo.processInfo.environment["TALKFLOW_EDITOR_SHOT"], !folder.isEmpty,
              let host = rig.host else { return }
        let dir = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            guard let look = NSAppearance(named: appearance) else { continue }
            let before = (host.appearance, rig.window.appearance)
            host.appearance = look
            rig.window.appearance = look
            rig.pump(0.2)
            let size = host.bounds.size
            if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
                rep.size = size
                look.performAsCurrentDrawingAppearance {
                    if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
                        NSGraphicsContext.saveGraphicsState()
                        NSGraphicsContext.current = ctx
                        Palette.dynamicNS(light: 0xF5F5F3, dark: 0x1F1E22).setFill()
                        NSRect(origin: .zero, size: size).fill()
                        NSGraphicsContext.restoreGraphicsState()
                    }
                    host.cacheDisplay(in: host.bounds, to: rep)
                }
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: dir.appendingPathComponent("\(name)-\(suffix).png"))
                }
            }
            host.appearance = before.0
            rig.window.appearance = before.1
        }
        rig.pump(0.1)
    }
}
