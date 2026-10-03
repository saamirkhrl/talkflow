import AppKit

/// The floating "pill" indicator: a small black rounded bar, bottom-center of the
/// main screen, with a red recording dot and a row of bars that react to live mic
/// input level. Shown while recording/processing; hidden the rest of the time.
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

    func show() {
        if panel == nil {
            buildPanel()
        }
        panel?.orderFrontRegardless()
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
        guard let captionPanel, let captionLabel, let screen = NSScreen.main else { return }

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
        let pillTop = screen.frame.minY + 70 + self.height
        captionPanel.setFrame(NSRect(x: screen.frame.midX - width / 2, y: pillTop + 10, width: width, height: height), display: true)
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
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

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
        guard let screen = NSScreen.main else { return }
        let x = screen.frame.midX - width / 2
        let y: CGFloat = screen.frame.minY + 70

        let panel = NSPanel(
            contentRect: NSRect(x: x, y: y, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

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
