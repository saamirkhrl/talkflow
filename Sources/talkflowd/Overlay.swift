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
        levelHistory = Array(repeating: 0, count: barCount)
        renderBars()
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
