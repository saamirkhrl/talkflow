import AppKit

/// The floating "pill" indicator: a small black rounded bar, bottom-center of the
/// screen the user is dictating into, with a red recording dot and a row of bars
/// that react to live mic input level. Shown while recording/processing; hidden the rest of the time.
/// No separate "processing" color - the dot stays red for as long as the pill is
/// visible, whether actively recording or wrapping up.
final class OverlayController {
    private var panel: NSPanel?
    private var dotLayer: CALayer?
    private var barLayers: [CALayer] = []
    private var levelHistory: [Float] = []

    private let width: CGFloat = 150
    private let height: CGFloat = 40
    private let barCount = 9
    private let dotSize: CGFloat = 10
    private let sidePadding: CGFloat = 16
    /// Gap between the bottom of the screen and the pill.
    private let bottomOffset: CGFloat = 70

    /// The screen the pill is on, picked again at every `show()`. The caption
    /// and error notice stack above the pill on the same screen.
    private var screen: NSScreen?
    private var screenObserver: NSObjectProtocol?

    init() {
        // A display plugged in, unplugged or rearranged moves every screen's
        // coordinates; a pill on screen re-places itself so it never sits at
        // the old ones (or on a display that is gone). The caption follows on
        // its next update, which reads `screen`.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if self.panel?.isVisible == true { self.placePill() } else { self.screen = nil }
        }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    /// What lets a panel sit over another app's full-screen Space: on every
    /// Space, auxiliary to full screen, above the menu bar level. Shared by the
    /// pill, caption and error notice; checked by `--streamtest`.
    static let overlayLevel: NSWindow.Level = .statusBar
    static let overlayBehavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

    static func applyOverlayBehavior(_ panel: NSPanel) {
        panel.level = overlayLevel
        panel.collectionBehavior = overlayBehavior
        panel.hidesOnDeactivate = false
    }

    func show() {
        if panel == nil {
            buildPanel()
        }
        placePill()
        panel?.orderFrontRegardless()
    }

    /// Centers the pill horizontally at the bottom of the screen the user is
    /// dictating into. Recomputed on every show, never cached across them.
    private func placePill() {
        guard let panel, let screen = Self.targetScreen() else { return }
        self.screen = screen
        let frame = screen.frame
        panel.setFrame(NSRect(x: (frame.midX - width / 2).rounded(), y: frame.minY + bottomOffset,
                              width: width, height: height), display: true)
    }

    /// The screen holding the frontmost app's frontmost window - the app the
    /// text is going into. Read from the window server, not Accessibility:
    /// this runs the moment the hotkey goes down, before the mic is live, and
    /// must not wait on a slow app. Falls back to the screen under the mouse,
    /// then the main screen.
    static func targetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           let bounds = frontWindowBounds(of: pid),
           let primary = screens.first {
            // Window-server bounds have a top-left origin on the primary
            // display; AppKit's have a bottom-left one.
            let window = NSRect(x: bounds.minX, y: primary.frame.maxY - bounds.maxY,
                                width: bounds.width, height: bounds.height)
            let best = screens.max { overlap($0.frame, window) < overlap($1.frame, window) }
            if let best, overlap(best.frame, window) > 0 { return best }
        }
        let mouse = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? screens.first
    }

    private static func frontWindowBounds(of pid: pid_t) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        // Front to back; the first normal-level window of the app is the one in use.
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict),
                  rect.width > 1, rect.height > 1 else { continue }
            return rect
        }
        return nil
    }

    private static func overlap(_ a: NSRect, _ b: NSRect) -> CGFloat {
        let i = a.intersection(b)
        return i.isNull ? 0 : i.width * i.height
    }

    func hide() {
        panel?.orderOut(nil)
        captionPanel?.orderOut(nil)
        levelHistory = Array(repeating: 0, count: barCount)
        renderBars()
    }

    // MARK: - Caption

    private var captionPanel: NSPanel?
    private var captionLabel: NSTextField?
    private let captionMaxWidth: CGFloat = 560
    private let captionPadding: CGFloat = 14
    /// Only the end of a long dictation is shown: what you are saying now is
    /// what you look at.
    private let captionMaxCharacters = 240

    /// Shows what has been heard so far above the pill. `settled` is the part
    /// two transcripts already agree on and is drawn solid; the rest may still
    /// be revised by whisper, so it is drawn dimmed. Nothing here touches the
    /// user's document - this is the live view, the field is written once at
    /// release.
    func showCaption(settled: String, pending: String) {
        let full = settled + pending
        guard !full.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if captionPanel == nil { buildCaptionPanel() }
        guard let captionPanel, let captionLabel, let screen = screen ?? NSScreen.main else { return }

        // Trim from the front at a word boundary, keeping the solid/dim split.
        var cut = max(0, full.count - captionMaxCharacters)
        if cut > 0, let space = full.dropFirst(cut).firstIndex(of: " ") {
            cut = full.distance(from: full.startIndex, to: space) + 1
        }
        let settledShown = String(settled.dropFirst(min(cut, settled.count)))
        let pendingShown = String(pending.dropFirst(max(0, cut - settled.count)))
        let text = NSMutableAttributedString()
        let font = NSFont.systemFont(ofSize: 15, weight: .medium)
        if cut > 0 { text.append(NSAttributedString(string: "... ", attributes: [.font: font, .foregroundColor: NSColor.white.withAlphaComponent(0.55)])) }
        text.append(NSAttributedString(string: settledShown.replacingOccurrences(of: "\n", with: " "),
                                       attributes: [.font: font, .foregroundColor: NSColor.white]))
        text.append(NSAttributedString(string: pendingShown.replacingOccurrences(of: "\n", with: " "),
                                       attributes: [.font: font, .foregroundColor: NSColor.white.withAlphaComponent(0.55)]))
        captionLabel.attributedStringValue = text

        let textWidth = captionMaxWidth - 2 * captionPadding
        let fitted = text.boundingRect(with: NSSize(width: textWidth, height: 400),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading]).size
        let width = min(captionMaxWidth, ceil(fitted.width) + 2 * captionPadding + 2)
        let height = ceil(fitted.height) + 2 * captionPadding - 6
        let pillTop = screen.frame.minY + bottomOffset + self.height
        captionPanel.setFrame(NSRect(x: (screen.frame.midX - width / 2).rounded(), y: pillTop + 10, width: width, height: height), display: true)
        captionLabel.frame = NSRect(x: captionPadding, y: captionPadding - 3, width: width - 2 * captionPadding, height: ceil(fitted.height))
        captionPanel.orderFrontRegardless()
    }

    private func buildCaptionPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        Self.applyOverlayBehavior(panel)

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.88).cgColor
        container.layer?.cornerRadius = 14
        container.autoresizingMask = [.width, .height]

        let label = NSTextField(labelWithString: "")
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.cell?.wraps = true
        label.isSelectable = false
        container.addSubview(label)

        panel.contentView = container
        captionPanel = panel
        captionLabel = label
    }

    // MARK: - Error notice

    private var noticePanel: NSPanel?
    private var noticeLabel: NSTextField?
    private var noticeHide: DispatchWorkItem?

    /// A short error above the pill (a rejected API key, a cloud service that
    /// did not answer). It outlives `hide()`: the pill goes the moment the
    /// text is in, and the user still has to be able to read why it came out
    /// the way it did. Clears itself after a few seconds.
    func showError(_ message: String) {
        DispatchQueue.main.async { [self] in
            print("talkflowd: pill error: \(message)")
            if noticePanel == nil { buildNoticePanel() }
            guard let noticePanel, let noticeLabel, let screen = screen ?? Self.targetScreen() else { return }
            let text = NSAttributedString(string: message, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.white
            ])
            noticeLabel.attributedStringValue = text
            let maxText: CGFloat = 480
            let fitted = text.boundingRect(with: NSSize(width: maxText, height: 200),
                                           options: [.usesLineFragmentOrigin, .usesFontLeading]).size
            let dot: CGFloat = 8, gap: CGFloat = 8, padding: CGFloat = 14
            let width = ceil(fitted.width) + dot + gap + 2 * padding + 2
            let height = max(32, ceil(fitted.height) + 16)
            // Above the pill, and above the caption when one is showing.
            let pillTop = screen.frame.minY + bottomOffset + self.height
            let captionTop = captionPanel?.isVisible == true ? (captionPanel?.frame.maxY ?? pillTop) : pillTop
            noticePanel.setFrame(NSRect(x: (screen.frame.midX - width / 2).rounded(), y: captionTop + 10, width: width, height: height), display: true)
            noticePanel.contentView?.subviews.first?.frame = NSRect(x: padding, y: (height - dot) / 2, width: dot, height: dot)
            noticeLabel.frame = NSRect(x: padding + dot + gap, y: (height - ceil(fitted.height)) / 2 - 1,
                                       width: ceil(fitted.width) + 2, height: ceil(fitted.height))
            noticePanel.orderFrontRegardless()

            noticeHide?.cancel()
            let hide = DispatchWorkItem { [weak self] in self?.noticePanel?.orderOut(nil) }
            noticeHide = hide
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: hide)
        }
    }

    private func buildNoticePanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 32),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        Self.applyOverlayBehavior(panel)

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.88).cgColor
        container.layer?.cornerRadius = 12
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.6).cgColor
        container.autoresizingMask = [.width, .height]

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 4
        container.addSubview(dot)

        let label = NSTextField(labelWithString: "")
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.isSelectable = false
        container.addSubview(label)

        panel.contentView = container
        noticePanel = panel
        noticeLabel = label
    }

    /// Called from the recorder's audio tap (background thread) with the newest level.
    func pushLevel(_ level: Float) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.levelHistory.append(level)
            if self.levelHistory.count > self.barCount {
                self.levelHistory.removeFirst(self.levelHistory.count - self.barCount)
            }
            self.renderBars()
        }
    }

    private func buildPanel() {
        // Placed by placePill() before every show.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        Self.applyOverlayBehavior(panel)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.88).cgColor
        container.layer?.cornerRadius = height / 2

        let dot = CALayer()
        dot.frame = CGRect(x: sidePadding, y: height / 2 - dotSize / 2, width: dotSize, height: dotSize)
        dot.cornerRadius = dotSize / 2
        dot.backgroundColor = NSColor.systemRed.cgColor
        container.layer?.addSublayer(dot)
        dotLayer = dot
        addPulse(to: dot)

        // A tight cluster of thin bars (waveform look), centered in the space
        // between the dot and the right padding - not stretched edge to edge.
        let barsRegionStart = sidePadding + dotSize + 14
        let barsRegionEnd = width - sidePadding
        let barWidth: CGFloat = 2.5
        let spacing: CGFloat = 3.5
        let minHeight: CGFloat = 4
        let clusterWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * spacing
        let clusterStartX = barsRegionStart + (barsRegionEnd - barsRegionStart - clusterWidth) / 2

        var bars: [CALayer] = []
        for i in 0..<barCount {
            let bar = CALayer()
            bar.backgroundColor = NSColor.white.cgColor
            bar.cornerRadius = barWidth / 2
            let x = clusterStartX + CGFloat(i) * (barWidth + spacing)
            bar.frame = CGRect(x: x, y: height / 2 - minHeight / 2, width: barWidth, height: minHeight)
            container.layer?.addSublayer(bar)
            bars.append(bar)
        }
        barLayers = bars
        levelHistory = Array(repeating: 0, count: barCount)

        panel.contentView = container
        self.panel = panel
    }

    private func renderBars() {
        guard !barLayers.isEmpty else { return }
        let minHeight: CGFloat = 4
        let maxHeight: CGFloat = height * 0.7
        for (i, bar) in barLayers.enumerated() {
            let level = i < levelHistory.count ? CGFloat(levelHistory[i]) : 0
            let h = minHeight + level * (maxHeight - minHeight)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bar.frame = CGRect(x: bar.frame.origin.x, y: height / 2 - h / 2, width: bar.frame.width, height: h)
            CATransaction.commit()
        }
    }

    private func addPulse(to dot: CALayer) {
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.35
        pulse.duration = 0.6
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        dot.add(pulse, forKey: "pulse")
    }
}
