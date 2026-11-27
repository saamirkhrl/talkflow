import AppKit

extension NSAttributedString.Key {
    /// A block's kind (NoteDocument.Kind raw value), on every character of its paragraph including the newline.
    static let docKind = NSAttributedString.Key("talkflow.docKind")
    /// true on every character of a checked to-do's paragraph.
    static let docChecked = NSAttributedString.Key("talkflow.docChecked")
    /// true on bold runs (topic and owner lead-ins).
    static let docBold = NSAttributedString.Key("talkflow.docBold")
}

/// The document's look. Sizes in points.
enum DocStyle {
    /// The text column's widest width; its left edge is the header's.
    static let columnWidth: CGFloat = 720
    static let bodySize: CGFloat = 15
    /// About 1.5 times the body size.
    static let bodyLineHeight: CGFloat = 23
    static let headingSize: CGFloat = 20
    static let headingLineHeight: CGFloat = 28
    /// Where a bullet's or to-do's text starts; the dot or box sits in this gap.
    static let listIndent: CGFloat = 26
    /// Space after a block, by what follows it.
    static let spacingParagraph: CGFloat = 10
    static let spacingList: CGFloat = 6
    static let spacingUnderHeading: CGFloat = 6
    static let spacingAboveHeading: CGFloat = 24
    static let bulletDiameter: CGFloat = 5
    static let bulletCenterX: CGFloat = 9
    static let checkboxSize: CGFloat = 14
    static let checkboxX: CGFloat = 1
    static let checkboxRadius: CGFloat = 4
    /// Extra clickable margin around a to-do's box.
    static let checkboxHitSlop: CGFloat = 5
    /// Below the last line, inside the editor.
    static let bottomPadding: CGFloat = 24
    /// The only hint text: on an empty block that has the caret.
    static let placeholder = "Type / for blocks"

    // The app's colors (same values as Palette).
    static let ink = Palette.dynamicNS(light: 0x1F1E22, dark: 0xF5F5F3)
    static let muted = Palette.dynamicNS(light: 0x5F5E66, dark: 0xA9A8AF)
    static let paper = Palette.dynamicNS(light: 0xF5F5F3, dark: 0x1F1E22)
    static let card = Palette.dynamicNS(light: 0xFFFFFF, dark: 0x2A292F)
    static let menuStroke = Palette.dynamicNS(light: 0x1F1E22, dark: 0xF5F5F3, lightAlpha: 0.14, darkAlpha: 0.14)
    static let menuSelection = Palette.dynamicNS(light: 0x1F1E22, dark: 0xF5F5F3, lightAlpha: 0.07, darkAlpha: 0.10)
    static let checkboxStroke = Palette.dynamicNS(light: 0x1F1E22, dark: 0xF5F5F3, lightAlpha: 0.38, darkAlpha: 0.45)
    static let placeholderColor = Palette.dynamicNS(light: 0x5F5E66, dark: 0xA9A8AF, lightAlpha: 0.6, darkAlpha: 0.6)

    static func font(_ kind: NoteDocument.Kind, bold: Bool) -> NSFont {
        if kind == .heading { return NSFont.systemFont(ofSize: headingSize, weight: .semibold) }
        return NSFont.systemFont(ofSize: bodySize, weight: bold ? .semibold : .regular)
    }

    static func indent(_ kind: NoteDocument.Kind) -> CGFloat {
        kind == .bullet || kind == .todo ? listIndent : 0
    }

    /// No space ABOVE any paragraph (so a line's baseline sits at the same height in every line, including the
    /// empty last line); the gap above a heading is the space after the block before it.
    static func paragraphStyle(_ kind: NoteDocument.Kind, next: NoteDocument.Kind?) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        let lineHeight = kind == .heading ? headingLineHeight : bodyLineHeight
        p.minimumLineHeight = lineHeight
        p.maximumLineHeight = lineHeight
        p.firstLineHeadIndent = indent(kind)
        p.headIndent = indent(kind)
        p.lineBreakMode = .byWordWrapping
        let isList = kind == .bullet || kind == .todo
        if next == .heading {
            p.paragraphSpacing = spacingAboveHeading
        } else if kind == .heading {
            p.paragraphSpacing = spacingUnderHeading
        } else if isList && (next == .bullet || next == .todo || next == nil) {
            p.paragraphSpacing = spacingList
        } else {
            p.paragraphSpacing = spacingParagraph
        }
        return p
    }

    /// What typing inserts in a block of this kind: never a link, bold only inside a bold run.
    static func typingAttributes(_ kind: NoteDocument.Kind, checked: Bool, bold: Bool) -> [NSAttributedString.Key: Any] {
        let isBold = bold && kind != .heading
        var a: [NSAttributedString.Key: Any] = [
            .docKind: kind.rawValue,
            .font: font(kind, bold: isBold),
            .paragraphStyle: paragraphStyle(kind, next: nil),
            .foregroundColor: checked ? muted : ink,
        ]
        if checked {
            a[.docChecked] = true
            a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if isBold { a[.docBold] = true }
        return a
    }

    private static var baselineCache: [NoteDocument.Kind: CGFloat] = [:]

    /// From the top of a line to its baseline for a block of this kind (the same on every line, because nothing
    /// adds space above a line). Measured once with a throwaway layout; used for the empty last line, which has
    /// no glyph to ask.
    static func baselineOffset(_ kind: NoteDocument.Kind) -> CGFloat {
        if let v = baselineCache[kind] { return v }
        let storage = NSTextStorage(string: "Xg", attributes: [.font: font(kind, bold: false),
                                                               .paragraphStyle: paragraphStyle(kind, next: nil)])
        let lm = NSLayoutManager()
        let tc = NSTextContainer(size: NSSize(width: 1000, height: 1000))
        tc.lineFragmentPadding = 0
        lm.addTextContainer(tc)
        storage.addLayoutManager(lm)
        lm.ensureLayout(for: tc)
        let v = lm.location(forGlyphAt: 0).y
        baselineCache[kind] = v
        return v
    }

    static func bulletRect(x: CGFloat, baseline: CGFloat) -> NSRect {
        let xHeight = font(.bullet, bold: false).xHeight
        let cy = baseline - xHeight / 2
        return NSRect(x: x + bulletCenterX - bulletDiameter / 2, y: cy - bulletDiameter / 2,
                      width: bulletDiameter, height: bulletDiameter)
    }

    /// In a flipped view: centered on the first line's capital letters.
    static func checkboxRect(x: CGFloat, baseline: CGFloat) -> NSRect {
        let capHeight = font(.todo, bold: false).capHeight
        let cy = baseline - capHeight / 2
        return NSRect(x: x + checkboxX, y: cy - checkboxSize / 2, width: checkboxSize, height: checkboxSize)
    }

    static func drawBullet(_ r: NSRect) {
        ink.setFill()
        NSBezierPath(ovalIn: r).fill()
    }

    /// Flipped coordinates (y grows down).
    static func drawCheckbox(_ r: NSRect, checked: Bool) {
        if checked {
            ink.setFill()
            NSBezierPath(roundedRect: r, xRadius: checkboxRadius, yRadius: checkboxRadius).fill()
            let check = NSBezierPath()
            check.move(to: NSPoint(x: r.minX + r.width * 0.26, y: r.minY + r.height * 0.52))
            check.line(to: NSPoint(x: r.minX + r.width * 0.43, y: r.minY + r.height * 0.70))
            check.line(to: NSPoint(x: r.minX + r.width * 0.75, y: r.minY + r.height * 0.32))
            check.lineWidth = 1.75
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            paper.setStroke()
            check.stroke()
        } else {
            let box = NSBezierPath(roundedRect: r.insetBy(dx: 0.625, dy: 0.625), xRadius: checkboxRadius - 0.5,
                                   yRadius: checkboxRadius - 0.5)
            box.lineWidth = 1.25
            checkboxStroke.setStroke()
            box.stroke()
        }
    }
}

/// Blocks to attributed text and back, and the styling of every paragraph from its kind. No window needed.
enum DocText {
    static func citeURL(_ t: Double) -> URL {
        URL(string: "talkflow-cite://t/\(t)")!
    }

    /// The time in a talkflow-cite link (a URL or its string), or nil.
    static func citeTime(_ value: Any?) -> Double? {
        let url = (value as? URL) ?? (value as? String).flatMap { URL(string: $0) }
        guard let url, url.scheme == "talkflow-cite" else { return nil }
        return Double(url.lastPathComponent)
    }

    static func kind(_ s: NSAttributedString, at loc: Int) -> NoteDocument.Kind {
        guard loc < s.length else { return .paragraph }
        return NoteDocument.Kind(rawValue: s.attribute(.docKind, at: loc, effectiveRange: nil) as? String ?? "") ?? .paragraph
    }

    static func checked(_ s: NSAttributedString, at loc: Int) -> Bool {
        guard loc < s.length else { return false }
        return (s.attribute(.docChecked, at: loc, effectiveRange: nil) as? NSNumber)?.boolValue ?? false
    }

    struct Paragraph: Equatable {
        /// With its terminator.
        var whole: NSRange
        /// Without it.
        var content: NSRange
    }

    /// Every paragraph in order. Text that is empty or ends in a newline has a final empty paragraph at the end
    /// (location == length, length 0): the "tail", which has no characters to carry its kind, so the text view
    /// keeps that kind on the side.
    static func paragraphs(_ ns: NSString) -> [Paragraph] {
        var out: [Paragraph] = []
        var loc = 0
        while loc < ns.length {
            var start = 0, end = 0, contentsEnd = 0
            ns.getParagraphStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: loc, length: 0))
            out.append(Paragraph(whole: NSRange(location: start, length: end - start),
                                 content: NSRange(location: start, length: contentsEnd - start)))
            loc = end
        }
        if let last = out.last, NSMaxRange(last.whole) == NSMaxRange(last.content) { return out }
        out.append(Paragraph(whole: NSRange(location: ns.length, length: 0), content: NSRange(location: ns.length, length: 0)))
        return out
    }

    /// The paragraph a caret at `loc` is in. A caret right after a newline is in the next paragraph.
    static func paragraphIndex(_ list: [Paragraph], at loc: Int) -> Int {
        for (i, p) in list.enumerated() {
            let end = NSMaxRange(p.whole)
            if loc >= p.whole.location && (loc < end || (loc == end && end == NSMaxRange(p.content))) { return i }
        }
        return max(0, list.count - 1)
    }

    static func blocks(from s: NSAttributedString, tail: NoteDocument.Block) -> [NoteDocument.Block] {
        let ns = s.string as NSString
        return paragraphs(ns).map { p in
            if p.whole.length == 0 { return NoteDocument.Block(tail.kind, checked: tail.checked) }
            var spans: [NoteDocument.Span] = []
            if p.content.length > 0 {
                s.enumerateAttributes(in: p.content, options: []) { attrs, r, _ in
                    spans.append(NoteDocument.Span(ns.substring(with: r),
                                                   bold: (attrs[.docBold] as? NSNumber)?.boolValue ?? false,
                                                   cite: citeTime(attrs[.link])))
                }
            }
            return NoteDocument.Block(kind(s, at: p.whole.location), checked: checked(s, at: p.whole.location), spans)
        }
    }

    /// The text for some blocks, styled, and the kind of its last block (the tail's kind when that block is empty).
    static func attributed(_ blocks: [NoteDocument.Block]) -> (text: NSMutableAttributedString, tail: NoteDocument.Block) {
        let list = blocks.isEmpty ? [NoteDocument.Block(.paragraph)] : blocks
        let out = NSMutableAttributedString()
        for (i, b) in list.enumerated() {
            var base: [NSAttributedString.Key: Any] = [.docKind: b.kind.rawValue]
            if b.checked { base[.docChecked] = true }
            for span in b.spans {
                var a = base
                if span.bold { a[.docBold] = true }
                if let t = span.cite { a[.link] = citeURL(t) }
                out.append(NSAttributedString(string: span.text, attributes: a))
            }
            if i < list.count - 1 { out.append(NSAttributedString(string: "\n", attributes: base)) }
        }
        let last = list[list.count - 1]
        let tail = NoteDocument.Block(last.kind, checked: last.checked)
        restyle(out, around: NSRange(location: 0, length: out.length), tail: tail)
        return (out, tail)
    }

    /// Makes each paragraph touching `range` (and the one before it, whose spacing depends on what follows) one
    /// kind throughout (the kind of its first character), and sets its paragraph style, fonts, color and
    /// strikethrough from that kind. Removes underline and background that pasting or menus could add.
    static func restyle(_ s: NSMutableAttributedString, around range: NSRange, tail: NoteDocument.Block) {
        let ns = s.string as NSString
        let list = paragraphs(ns)
        guard !list.isEmpty else { return }
        let first = max(0, paragraphIndex(list, at: min(range.location, ns.length)) - 1)
        let last = max(first, paragraphIndex(list, at: min(NSMaxRange(range), ns.length)))
        for i in first...last {
            let p = list[i]
            guard p.whole.length > 0 else { continue }
            let kind = self.kind(s, at: p.whole.location)
            let isChecked = kind == .todo && checked(s, at: p.whole.location)
            var next: NoteDocument.Kind?
            if i + 1 < list.count {
                next = list[i + 1].whole.length > 0 ? self.kind(s, at: list[i + 1].whole.location) : tail.kind
            }
            s.addAttribute(.docKind, value: kind.rawValue, range: p.whole)
            if isChecked {
                s.addAttribute(.docChecked, value: true, range: p.whole)
            } else {
                s.removeAttribute(.docChecked, range: p.whole)
            }
            s.addAttribute(.paragraphStyle, value: DocStyle.paragraphStyle(kind, next: next), range: p.whole)
            s.addAttribute(.foregroundColor, value: isChecked ? DocStyle.muted : DocStyle.ink, range: p.whole)
            s.removeAttribute(.underlineStyle, range: p.whole)
            s.removeAttribute(.backgroundColor, range: p.whole)
            s.removeAttribute(.strikethroughStyle, range: p.whole)
            if isChecked && p.content.length > 0 {
                s.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: p.content)
            }
            s.enumerateAttribute(.docBold, in: p.whole, options: []) { value, r, _ in
                let bold = (value as? NSNumber)?.boolValue ?? false
                s.addAttribute(.font, value: DocStyle.font(kind, bold: bold), range: r)
            }
        }
    }
}
