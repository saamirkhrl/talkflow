import AppKit
import SwiftUI

/// Snapshots only: once the editor is in a window, give it the caret at the end of block `focusBlock` and, when
/// `slash` is true and that block reads "/query", open the slash menu on it.
struct DocEditorStage {
    var focusBlock: Int
    var slash: Bool
}

/// Keeps the text view's styling in step with every edit (attributes only). This runs in didProcessEditing, not
/// willProcessEditing: attributes changed in willProcessEditing widen the storage's edited range to whole
/// paragraphs, and the layout manager then moves the caret to the end of that widened range. A character typed
/// mid-block sent the caret to the start of the next block, and the next keystroke landed there with the previous
/// block's kind, which the restyle then spread over that whole block. Attributes changed here leave the selection
/// alone and are still laid out (the editor harness, NE checks, compares the layout with a fresh load).
private final class DocStorageDelegate: NSObject, NSTextStorageDelegate {
    weak var view: DocTextView?

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard let view else { return }
        DocText.restyle(textStorage, around: editedRange, tail: view.tail)
        view.mirrorTail()
    }
}

/// The document editor: one text view for the whole document, so selection, copy, undo and arrow keys work across
/// blocks as in any Mac text view. Each paragraph is a block; its kind is an attribute (DocText). Return, Delete,
/// the typed shortcuts and the slash menu follow NoteDocument's rules.
final class DocTextView: NSTextView {
    /// The kind of the empty last paragraph, which has no characters to hold it.
    var tail = NoteDocument.Block(.paragraph)
    var onChange: (([NoteDocument.Block]) -> Void)?
    var onCite: ((Double) -> Void)?
    var onHeight: ((CGFloat) -> Void)?
    /// Focus left or the editor is going away: save now.
    var onEndEditing: (() -> Void)?
    private(set) var slash: NoteDocument.SlashState?

    /// The text view does not keep its storage alive; this does.
    private var keepStorage: NSTextStorage?
    private let storageDelegate = DocStorageDelegate()
    private let docUndo = UndoManager()
    private let slashMenu = DocSlashMenu()
    /// The string being inserted by the current insertText, so an edit can tell typing from other changes.
    private var typed: String?
    /// True while loading or applying a transform, so didChangeText does not react to it.
    private var applying = false

    static func make() -> DocTextView {
        let storage = NSTextStorage()
        let lm = NSLayoutManager()
        storage.addLayoutManager(lm)
        let tc = NSTextContainer(size: NSSize(width: DocStyle.columnWidth, height: CGFloat.greatestFiniteMagnitude))
        tc.widthTracksTextView = true
        tc.heightTracksTextView = false
        tc.lineFragmentPadding = 0
        lm.addTextContainer(tc)
        let tv = DocTextView(frame: NSRect(x: 0, y: 0, width: DocStyle.columnWidth, height: 200), textContainer: tc)
        tv.keepStorage = storage
        tv.storageDelegate.view = tv
        storage.delegate = tv.storageDelegate
        tv.configure()
        return tv
    }

    private func configure() {
        isRichText = true
        importsGraphics = false
        allowsImageEditing = false
        usesFontPanel = false
        usesRuler = false
        isRulerVisible = false
        allowsUndo = true
        isEditable = true
        isSelectable = true
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        autoresizingMask = []
        focusRingType = .none
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        smartInsertDeleteEnabled = false
        insertionPointColor = DocStyle.ink
        linkTextAttributes = [.foregroundColor: DocStyle.muted,
                              .underlineStyle: NSUnderlineStyle.single.rawValue,
                              .cursor: NSCursor.pointingHand]
        setAccessibilityLabel("Meeting notes")
        slashMenu.isHidden = true
        slashMenu.onPick = { [weak self] i in self?.pickSlash(i) }
        slashMenu.onHover = { [weak self] i in
            guard let self, var s = self.slash else { return }
            s.selected = i
            self.slash = s
            self.layoutSlashMenu()
        }
        addSubview(slashMenu)
    }

    override var undoManager: UndoManager? { docUndo }

    // MARK: Content

    func load(_ blocks: [NoteDocument.Block]) {
        applying = true
        let (text, t) = DocText.attributed(blocks)
        tail = t
        textStorage?.setAttributedString(text)
        applying = false
        slash = nil
        layoutSlashMenu()
        docUndo.removeAllActions()
        setSelectedRange(NSRange(location: 0, length: 0))
        reportHeight()
        needsDisplay = true
    }

    var blocks: [NoteDocument.Block] {
        guard let s = textStorage else { return [] }
        return DocText.blocks(from: s, tail: tail)
    }

    /// While the last paragraph has characters, remember its kind, so emptying it keeps the kind.
    func mirrorTail() {
        guard let s = textStorage, s.length > 0 else { return }
        guard let last = DocText.paragraphs(s.string as NSString).last, last.whole.length > 0 else { return }
        tail = NoteDocument.Block(DocText.kind(s, at: last.whole.location), checked: DocText.checked(s, at: last.whole.location))
    }

    struct ParagraphInfo {
        var index: Int
        var whole: NSRange
        var content: NSRange
        var kind: NoteDocument.Kind
        var checked: Bool
        var text: String
    }

    func paragraphInfo(at loc: Int) -> ParagraphInfo {
        let s = textStorage ?? NSTextStorage()
        let ns = s.string as NSString
        let list = DocText.paragraphs(ns)
        let i = DocText.paragraphIndex(list, at: min(loc, ns.length))
        let p = list[i]
        let kind = p.whole.length > 0 ? DocText.kind(s, at: p.whole.location) : tail.kind
        let checked = kind == .todo && (p.whole.length > 0 ? DocText.checked(s, at: p.whole.location) : tail.checked)
        return ParagraphInfo(index: i, whole: p.whole, content: p.content, kind: kind, checked: checked,
                             text: ns.substring(with: p.content))
    }

    /// Changes paragraph `index` to a kind, as one undoable step (the empty last paragraph: remembered on the side).
    func setKind(_ kind: NoteDocument.Kind, checked: Bool, paragraph index: Int) {
        guard let s = textStorage else { return }
        let list = DocText.paragraphs(s.string as NSString)
        guard list.indices.contains(index) else { return }
        let p = list[index]
        let isChecked = kind == .todo && checked
        if p.whole.length == 0 {
            tail = NoteDocument.Block(kind, checked: isChecked)
            if s.length > 0 {
                // Restyles the paragraph above, whose spacing depends on this kind.
                s.beginEditing()
                s.edited(.editedAttributes, range: NSRange(location: s.length - 1, length: 1), changeInLength: 0)
                s.endEditing()
            }
            typingAttributes = [:]
            changed()
            return
        }
        guard shouldChangeText(in: p.whole, replacementString: nil) else { return }
        s.beginEditing()
        s.addAttribute(.docKind, value: kind.rawValue, range: p.whole)
        if isChecked {
            s.addAttribute(.docChecked, value: true, range: p.whole)
        } else {
            s.removeAttribute(.docChecked, range: p.whole)
        }
        s.endEditing()
        didChangeText()
        typingAttributes = [:]
    }

    /// Typing never continues a link, and takes its kind from the caret's block.
    override var typingAttributes: [NSAttributedString.Key: Any] {
        get { super.typingAttributes }
        set {
            guard textStorage != nil else { super.typingAttributes = newValue; return }
            let info = paragraphInfo(at: selectedRange().location)
            let bold = (newValue[.docBold] as? NSNumber)?.boolValue ?? false
            super.typingAttributes = DocStyle.typingAttributes(info.kind, checked: info.checked, bold: bold)
        }
    }

    private func changed() {
        onChange?(blocks)
        reportHeight()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    func reportHeight() {
        guard let lm = layoutManager, let tc = textContainer else { return }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        onHeight?(ceil(used.maxY + textContainerOrigin.y) + DocStyle.bottomPadding)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged {
            reportHeight()
            layoutSlashMenu()
        }
    }

    // MARK: Editing

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let previous = typed
        typed = (string as? String) ?? (string as? NSAttributedString)?.string
        super.insertText(string, replacementRange: replacementRange)
        typed = previous
    }

    override func didChangeText() {
        super.didChangeText()
        guard !applying else { return }
        afterEdit()
        changed()
    }

    /// Typed shortcuts, then the slash menu.
    private func afterEdit() {
        let sel = selectedRange()
        guard sel.length == 0 else {
            if slash != nil { slash = nil; layoutSlashMenu() }
            return
        }
        let info = paragraphInfo(at: sel.location)
        let offset = sel.location - info.content.location
        if typed == " ", let m = NoteDocument.shortcut(kind: info.kind, text: info.text, offset: offset) {
            applying = true
            insertText("", replacementRange: NSRange(location: info.content.location, length: m.prefixLength))
            applying = false
            setKind(m.kind, checked: false, paragraph: info.index)
            return
        }
        let next = NoteDocument.slashAfterEdit(slash, block: info.index, text: info.text, offset: offset, typed: typed)
        if next != slash {
            slash = next
            layoutSlashMenu()
        }
    }

    override func insertNewline(_ sender: Any?) {
        if let s = slash {
            pickSlash(s.selected)
            return
        }
        if selectedRange().length > 0 { insertText("", replacementRange: selectedRange()) }
        let caret = selectedRange().location
        let info = paragraphInfo(at: caret)
        switch NoteDocument.returnAction(kind: info.kind, text: info.text, offset: caret - info.content.location) {
        case .convert(let k):
            setKind(k, checked: false, paragraph: info.index)
        case .insertAbove(let k):
            // The new empty paragraph takes this block's index; the caret stays at the start of this block.
            insertText("\n", replacementRange: NSRange(location: info.content.location, length: 0))
            setKind(k, checked: false, paragraph: info.index)
        case .split(let k):
            super.insertNewline(sender)
            setKind(k, checked: false, paragraph: paragraphInfo(at: selectedRange().location).index)
        }
    }

    override func deleteBackward(_ sender: Any?) {
        let sel = selectedRange()
        if sel.length == 0 {
            let info = paragraphInfo(at: sel.location)
            if sel.location == info.content.location, let k = NoteDocument.deleteAtStartConverts(info.kind) {
                setKind(k, checked: false, paragraph: info.index)
                return
            }
            if sel.location == info.content.location, info.index > 0 { matchKindBeforeMerge(into: info.index - 1) }
        }
        super.deleteBackward(sender)
    }

    /// Forward delete at the end of a block pulls the next block up into it.
    override func deleteForward(_ sender: Any?) {
        let sel = selectedRange()
        if sel.length == 0 {
            let info = paragraphInfo(at: sel.location)
            if sel.location == NSMaxRange(info.content) { matchKindBeforeMerge(into: info.index) }
        }
        super.deleteForward(sender)
    }

    /// Before the line break after block `upper` is deleted: gives the block below it the upper block's kind as its
    /// own undoable change. The restyle would give it that kind anyway, but the restyle is not undoable, so Undo
    /// brought the line break back and left the lower block with the upper block's kind.
    private func matchKindBeforeMerge(into upper: Int) {
        guard let s = textStorage else { return }
        let list = DocText.paragraphs(s.string as NSString)
        guard list.indices.contains(upper + 1), list[upper].whole.length > 0, list[upper + 1].whole.length > 0 else { return }
        let a = paragraphInfo(at: list[upper].whole.location)
        let b = paragraphInfo(at: list[upper + 1].whole.location)
        if a.kind != b.kind || a.checked != b.checked { setKind(a.kind, checked: a.checked, paragraph: upper + 1) }
    }

    override func moveUp(_ sender: Any?) {
        if let s = slash {
            slash = NoteDocument.slashMove(s, by: -1)
            layoutSlashMenu()
        } else {
            super.moveUp(sender)
        }
    }

    override func moveDown(_ sender: Any?) {
        if let s = slash {
            slash = NoteDocument.slashMove(s, by: 1)
            layoutSlashMenu()
        } else {
            super.moveDown(sender)
        }
    }

    /// Escape closes the menu and leaves "/query" as text.
    override func cancelOperation(_ sender: Any?) {
        if slash != nil { closeSlash() } else { super.cancelOperation(sender) }
    }

    override func complete(_ sender: Any?) {
        if slash != nil { closeSlash() } else { super.complete(sender) }
    }

    // Plain text in and out.
    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    override func clicked(onLink link: Any, at charIndex: Int) {
        if let t = DocText.citeTime(link) { onCite?(t) }
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if let s = slash, !applying {
            let sel = selectedRange()
            let info = paragraphInfo(at: sel.location)
            if sel.length > 0 || info.index != s.block || sel.location != NSMaxRange(info.content) { closeSlash() }
        }
        needsDisplay = true
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        needsDisplay = true
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok {
            closeSlash()
            onEndEditing?()
        }
        needsDisplay = true
        return ok
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { onEndEditing?() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        reportHeight()
        if let stage = NoteDocumentEditor.snapshotStage {
            // A run loop block, not the main queue: the snapshot renderer runs inside a main-queue block.
            RunLoop.main.perform(inModes: [.common]) { [weak self] in self?.applyStage(stage) }
        }
    }

    private func applyStage(_ stage: DocEditorStage) {
        guard let window, let s = textStorage else { return }
        window.makeFirstResponder(self)
        let ns = s.string as NSString
        let list = DocText.paragraphs(ns)
        guard list.indices.contains(stage.focusBlock) else { return }
        let p = list[stage.focusBlock]
        setSelectedRange(NSRange(location: NSMaxRange(p.content), length: 0))
        if stage.slash, let q = NoteDocument.slashQuery(text: ns.substring(with: p.content), offset: p.content.length) {
            slash = NoteDocument.SlashState(block: stage.focusBlock, query: q, selected: 0)
            layoutSlashMenu()
        }
        needsDisplay = true
    }

    // MARK: To-dos

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if slash != nil && !slashMenu.frame.contains(p) { closeSlash() }
        if let i = checkboxParagraph(at: p) {
            let info = paragraphInfo(at: DocText.paragraphs((textStorage?.string ?? "") as NSString)[i].whole.location)
            setKind(.todo, checked: !info.checked, paragraph: i)
            return
        }
        super.mouseDown(with: event)
    }

    /// Each to-do's box, in view coordinates, with its paragraph index.
    private func checkboxes() -> [(index: Int, rect: NSRect)] {
        guard let s = textStorage else { return [] }
        let list = DocText.paragraphs(s.string as NSString)
        var out: [(Int, NSRect)] = []
        for (i, p) in list.enumerated() {
            let kind = p.whole.length > 0 ? DocText.kind(s, at: p.whole.location) : tail.kind
            guard kind == .todo, let base = baseline(ofParagraph: i) else { continue }
            out.append((i, DocStyle.checkboxRect(x: textContainerOrigin.x, baseline: base)))
        }
        return out
    }

    private func checkboxParagraph(at p: NSPoint) -> Int? {
        let slop = DocStyle.checkboxHitSlop
        return checkboxes().first { $0.rect.insetBy(dx: -slop, dy: -slop).contains(p) }?.index
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let slop = DocStyle.checkboxHitSlop
        for box in checkboxes() { addCursorRect(box.rect.insetBy(dx: -slop, dy: -slop), cursor: .pointingHand) }
    }

    // MARK: Drawing

    /// The baseline of paragraph `i`'s first line, in view coordinates.
    func baseline(ofParagraph i: Int) -> CGFloat? {
        guard let lm = layoutManager, let tc = textContainer, let s = textStorage else { return nil }
        let list = DocText.paragraphs(s.string as NSString)
        guard list.indices.contains(i) else { return nil }
        let p = list[i]
        lm.ensureLayout(for: tc)
        let origin = textContainerOrigin
        if p.whole.length == 0 {
            let r = lm.extraLineFragmentRect
            guard r.height > 0 else { return nil }
            return origin.y + r.minY + DocStyle.baselineOffset(tail.kind)
        }
        let g = lm.glyphIndexForCharacter(at: p.whole.location)
        let frag = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
        return origin.y + frag.minY + lm.location(forGlyphAt: g).y
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let s = textStorage else { return }
        let list = DocText.paragraphs(s.string as NSString)
        let x = textContainerOrigin.x
        for (i, p) in list.enumerated() {
            let kind = p.whole.length > 0 ? DocText.kind(s, at: p.whole.location) : tail.kind
            guard kind == .bullet || kind == .todo, let base = baseline(ofParagraph: i) else { continue }
            if base < rect.minY - 40 || base > rect.maxY + 40 { continue }
            if kind == .bullet {
                DocStyle.drawBullet(DocStyle.bulletRect(x: x, baseline: base))
            } else {
                let checked = p.whole.length > 0 ? DocText.checked(s, at: p.whole.location) : tail.checked
                DocStyle.drawCheckbox(DocStyle.checkboxRect(x: x, baseline: base), checked: checked)
            }
        }
        drawPlaceholder()
    }

    /// "Type / for blocks" on the empty block that has the caret, only while the editor has focus.
    private func drawPlaceholder() {
        guard window?.firstResponder === self, slash == nil else { return }
        let sel = selectedRange()
        guard sel.length == 0 else { return }
        let info = paragraphInfo(at: sel.location)
        guard info.content.length == 0, let base = baseline(ofParagraph: info.index) else { return }
        let font = DocStyle.font(info.kind, bold: false)
        let origin = NSPoint(x: textContainerOrigin.x + DocStyle.indent(info.kind), y: base - font.ascender)
        (DocStyle.placeholder as NSString).draw(at: origin, withAttributes: [.font: font, .foregroundColor: DocStyle.placeholderColor])
    }

    // MARK: Slash menu

    private func closeSlash() {
        guard slash != nil else { return }
        slash = nil
        layoutSlashMenu()
    }

    private func pickSlash(_ i: Int) {
        guard let s = slash else { return }
        let items = NoteDocument.slashMatches(s.query)
        guard items.indices.contains(i), let storage = textStorage else { return }
        slash = nil
        layoutSlashMenu()
        let list = DocText.paragraphs(storage.string as NSString)
        guard list.indices.contains(s.block) else { return }
        let p = list[s.block]
        if p.content.length > 0 { insertText("", replacementRange: p.content) }
        setKind(items[i].kind, checked: false, paragraph: s.block)
        let after = DocText.paragraphs(storage.string as NSString)
        if after.indices.contains(s.block) { setSelectedRange(NSRange(location: after[s.block].content.location, length: 0)) }
        window?.makeFirstResponder(self)
    }

    /// Under the "/" line, or above it when there is no room below in the visible part.
    private func layoutSlashMenu() {
        guard let s = slash, let base = baseline(ofParagraph: s.block) else {
            slashMenu.isHidden = true
            needsDisplay = true
            return
        }
        let kind = paragraphInfo(at: DocText.paragraphs((textStorage?.string ?? "") as NSString)[s.block].whole.location).kind
        slashMenu.items = NoteDocument.slashMatches(s.query)
        slashMenu.selected = s.selected
        let font = DocStyle.font(kind, bold: false)
        let h = slashMenu.fittingHeight
        let x = max(0, textContainerOrigin.x + DocStyle.indent(kind) - 6)
        var y = base + abs(font.descender) + 6
        let limit = min(visibleRect.maxY, bounds.maxY)
        let above = base - font.ascender - 6 - h
        if y + h > limit && above >= max(visibleRect.minY, 0) { y = above }
        slashMenu.frame = NSRect(x: x, y: y, width: DocSlashMenu.width, height: h)
        slashMenu.isHidden = false
        slashMenu.needsDisplay = true
        needsDisplay = true
    }
}

/// The slash menu: a small rounded panel with one row per block kind (symbol and label), the highlighted row
/// filled. A subview of the text view, so it scrolls with the text and renders in snapshots.
final class DocSlashMenu: NSView {
    static let width: CGFloat = 220
    static let rowHeight: CGFloat = 30
    static let padding: CGFloat = 6
    static let radius: CGFloat = 10

    var items: [NoteDocument.SlashItem] = [] { didSet { needsDisplay = true } }
    var selected = 0 { didSet { needsDisplay = true } }
    var onPick: ((Int) -> Void)?
    var onHover: ((Int) -> Void)?
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    var fittingHeight: CGFloat { Self.padding * 2 + CGFloat(items.count) * Self.rowHeight }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let panel = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Self.radius, yRadius: Self.radius)
        DocStyle.card.setFill()
        panel.fill()
        DocStyle.menuStroke.setStroke()
        panel.lineWidth = 1
        panel.stroke()
        let font = NSFont.systemFont(ofSize: 13)
        for (i, item) in items.enumerated() {
            let row = NSRect(x: Self.padding, y: Self.padding + CGFloat(i) * Self.rowHeight,
                             width: bounds.width - Self.padding * 2, height: Self.rowHeight)
            if i == selected {
                DocStyle.menuSelection.setFill()
                NSBezierPath(roundedRect: row, xRadius: 6, yRadius: 6).fill()
            }
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            if let image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let size = image.size
                let r = NSRect(x: row.minX + 10 + (18 - size.width) / 2, y: row.midY - size.height / 2,
                               width: size.width, height: size.height)
                Self.tinted(image, DocStyle.muted).draw(in: r)
            }
            let textHeight = font.ascender - font.descender
            (item.title as NSString).draw(at: NSPoint(x: row.minX + 36, y: row.midY - textHeight / 2),
                                          withAttributes: [.font: font, .foregroundColor: DocStyle.ink])
        }
    }

    /// A template symbol in one color.
    private static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        let out = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return out
    }

    private func row(at p: NSPoint) -> Int? {
        let i = Int(floor((p.y - Self.padding) / Self.rowHeight))
        return items.indices.contains(i) && p.y >= Self.padding ? i : nil
    }

    override func mouseDown(with event: NSEvent) {
        if let i = row(at: convert(event.locationInWindow, from: nil)) { onPick?(i) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with event: NSEvent) {
        if let i = row(at: convert(event.locationInWindow, from: nil)), i != selected { onHover?(i) }
    }
}
/// The document editor in SwiftUI. `token` names the document (note id and summary); a new token reloads the
/// text. The same token reloads only while the user has not edited it (a speaker renamed before any edit).
struct NoteDocumentEditor: NSViewRepresentable {
    /// Snapshots only (see DocEditorStage).
    static var snapshotStage: DocEditorStage?

    let token: String
    let blocks: [NoteDocument.Block]
    let onChange: ([NoteDocument.Block]) -> Void
    let onCite: (Double) -> Void
    let onFlush: () -> Void
    let onHeight: (CGFloat) -> Void

    final class Coordinator {
        var token = ""
        var loaded: [NoteDocument.Block] = []
        var edited = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> DocTextView {
        let tv = DocTextView.make()
        wire(tv, context.coordinator)
        tv.load(blocks)
        context.coordinator.token = token
        context.coordinator.loaded = blocks
        return tv
    }

    /// Test hook for the editor harness: how many times SwiftUI has updated an editor.
    static var updateCount = 0

    func updateNSView(_ tv: DocTextView, context: Context) {
        Self.updateCount += 1
        let c = context.coordinator
        wire(tv, c)
        if c.token != token || (!c.edited && c.loaded != blocks) {
            tv.load(blocks)
            c.token = token
            c.loaded = blocks
            c.edited = false
        }
    }

    private func wire(_ tv: DocTextView, _ c: Coordinator) {
        let onChange = self.onChange
        tv.onChange = { b in
            c.edited = true
            onChange(b)
        }
        tv.onCite = onCite
        tv.onHeight = onHeight
        tv.onEndEditing = onFlush
    }

    static func dismantleNSView(_ tv: DocTextView, coordinator: Coordinator) {
        tv.onEndEditing?()
    }
}

final class DocEditorSizer: ObservableObject {
    @Published var height: CGFloat = 120
}

/// The editor at the height of its text (it has no scroll view of its own).
struct NoteDocumentEditorView: View {
    let token: String
    let blocks: [NoteDocument.Block]
    let onChange: ([NoteDocument.Block]) -> Void
    let onCite: (Double) -> Void
    let onFlush: () -> Void
    @StateObject private var sizer = DocEditorSizer()

    var body: some View {
        let sizer = self.sizer
        NoteDocumentEditor(token: token, blocks: blocks, onChange: onChange, onCite: onCite, onFlush: onFlush,
                           onHeight: { h in
                               guard abs(sizer.height - h) > 0.5 else { return }
                               // Next run loop turn (any mode, so it also lands during a live resize); the main
                               // queue would not run while the snapshot renderer holds it.
                               RunLoop.main.perform(inModes: [.common]) { sizer.height = h }
                           })
            .frame(height: sizer.height)
    }
}
