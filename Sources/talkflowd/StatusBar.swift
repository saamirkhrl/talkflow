import AppKit

/// Minimal menu bar indicator: a bars glyph (matching the app icon) tinted by
/// state, plus a menu with Dashboard, the writing style, and Quit.
final class StatusBar: NSObject, NSMenuDelegate {
    enum State {
        case idle
        case recording
        case processing
    }

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    var onDashboardClicked: (() -> Void)?
    var onSetupClicked: (() -> Void)?
    private var styleItems: [NSMenuItem] = []

    override init() {
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Dashboard...", action: #selector(dashboardClicked), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Setup...", action: #selector(setupClicked), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        // The same setting as on the Settings page, one click away.
        let header = NSMenuItem(title: "Writing style", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for style in WritingStyle.allCases {
            let item = NSMenuItem(title: style.title, action: #selector(styleClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style.rawValue
            item.indentationLevel = 1
            item.toolTip = style.detail
            menu.addItem(item)
            styleItems.append(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit talkflow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        item.button?.image = Self.barsImage
        item.button?.image?.isTemplate = true
        setState(.idle)
    }

    @objc private func dashboardClicked() {
        onDashboardClicked?()
    }

    @objc private func setupClicked() {
        onSetupClicked?()
    }

    @objc private func styleClicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let style = WritingStyle(rawValue: raw) else { return }
        Preferences.writingStyle = style
    }

    /// Ticks the current style each time the menu opens, so a change made on
    /// the Settings page shows here too.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let current = Preferences.writingStyle.rawValue
        for item in styleItems { item.state = item.representedObject as? String == current ? .on : .off }
    }

    func setState(_ state: State) {
        item.button?.contentTintColor = state == .recording ? .systemRed : (state == .processing ? .systemOrange : nil)
        item.button?.toolTip = state.description
    }

    /// Same 5-bar waveform mark as the app icon, drawn at menu bar size. Always a
    /// template image so contentTintColor can recolor it per state.
    private static let barsImage: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let barCount = 5
            let barWidth: CGFloat = 2.2
            let spacing: CGFloat = 1.6
            let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * spacing
            let startX = (rect.width - totalWidth) / 2
            let heights: [CGFloat] = [0.4, 0.65, 1.0, 0.65, 0.4]
            NSColor.black.setFill()
            for i in 0..<barCount {
                let h = rect.height * heights[i]
                let barRect = NSRect(x: startX + CGFloat(i) * (barWidth + spacing), y: (rect.height - h) / 2, width: barWidth, height: h)
                NSBezierPath(roundedRect: barRect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }()
}

private extension StatusBar.State {
    var description: String {
        switch self {
        case .idle: return "talkflow - idle"
        case .recording: return "talkflow - recording"
        case .processing: return "talkflow - processing"
        }
    }
}
