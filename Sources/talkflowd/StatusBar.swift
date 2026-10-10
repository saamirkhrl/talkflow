import AppKit

/// Minimal menu bar indicator: a bars glyph (matching the app icon) tinted by
/// state, plus a menu with Dashboard, the writing style, and Quit (and
/// "Update to X.Y.Z..." while a newer version is available).
final class StatusBar: NSObject, NSMenuDelegate {
    enum State {
        case idle
        case recording
        case processing
    }

    private static let autosaveName = "talkflow-status"
    /// Where macOS keeps the icon's place in the menu bar, as a distance from
    /// the right edge. Cmd-dragging the icon writes it too.
    private static let positionKey = "NSStatusItem Preferred Position \(autosaveName)"
    /// Nil only for the moment the icon is being moved (see `move`).
    private var item: NSStatusItem?
    private var coverTimer: Timer?
    private var moving = false
    private let menu = NSMenu()
    private var state: State = .idle
    var onDashboardClicked: (() -> Void)?
    var onSetupClicked: (() -> Void)?
    /// Opens the dashboard, where the Update button is.
    var onUpdateClicked: (() -> Void)?
    private var styleItems: [NSMenuItem] = []
    private let updateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let updateSeparator = NSMenuItem.separator()

    override init() {
        Self.keepEarlierPlace()
        item = Self.makeItem()
        super.init()
        menu.delegate = self
        // Only while a newer version is available (see setUpdate).
        updateItem.action = #selector(updateClicked)
        updateItem.target = self
        updateItem.isHidden = true
        updateSeparator.isHidden = true
        menu.addItem(updateItem)
        menu.addItem(updateSeparator)
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
        configure()
        // Give the system time to lay the menu bar out (measured: icons still
        // shift for about 4s after launch), then keep checking: a notch app can
        // start after talkflow, or grow its island later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.checkCover() }
        coverTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.checkCover() }
    }

    /// Where the icon is on screen, for --statusbartest.
    var iconFrame: NSRect? { item?.button?.window?.frame }

    private static func makeItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = autosaveName
        return item
    }

    /// Before the icon had a name of its own, macOS saved its place (and
    /// whether the user removed it) under the default name "Item-0". Carry
    /// that over once, so a place the user chose is kept.
    private static func keepEarlierPlace() {
        let defaults = UserDefaults.standard
        for prefix in ["NSStatusItem Preferred Position ", "NSStatusItem Visible "] {
            guard defaults.object(forKey: prefix + autosaveName) == nil,
                  let earlier = defaults.object(forKey: prefix + "Item-0") else { continue }
            defaults.set(earlier, forKey: prefix + autosaveName)
        }
    }

    private func configure() {
        item?.menu = menu
        item?.button?.image = Self.barsImage
        item?.button?.image?.isTemplate = true
        setState(state)
    }

    /// Notch apps (Dynamic Island style, such as Notchy) put a window over the
    /// middle of the menu bar, and their island grows past the notch onto the
    /// icons beside it - often ours, the newest. macOS does not say we are
    /// covered (on macOS 27 the system draws status items, and the item's
    /// window always reports itself visible), so this compares positions: a
    /// window of another app, at menu bar level, centred on the screen like an
    /// island, over the middle of our icon. Seen twice 3s apart, so an island
    /// that only opens while hovered does not count; then the icon moves right,
    /// toward the clock, past the island's edge. It only ever moves right, so it
    /// settles, and a hidden menu bar or a full screen space is never mistaken
    /// for a cover.
    private func checkCover(confirmed: Bool = false) {
        guard !moving, let place = clearPlace(), let needed = place.needed else { return }
        guard confirmed else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.checkCover(confirmed: true) }
            return
        }
        moving = true
        print("talkflowd: menu bar icon is under a notch app's island, moving it right")
        move(toWithin: needed, attempt: 0)
    }

    /// Where the icon is, as a distance from the right edge of the menu bar,
    /// and how far from that edge it has to be to clear every island (nil when
    /// nothing covers it). The icon sits the same distance from the right on
    /// every screen (measured) but is only measured on the active one, so each
    /// screen is checked at that distance.
    private func clearPlace() -> (current: CGFloat, needed: CGFloat?)? {
        guard let window = item?.button?.window, let active = window.screen else { return nil }
        let current = active.frame.maxX - window.frame.maxX
        let size = window.frame.size
        var needed: CGFloat?
        for screen in NSScreen.screens {
            let icon = NSRect(x: screen.frame.maxX - current - size.width, y: screen.frame.maxY - size.height,
                              width: size.width, height: size.height)
            guard let edge = Self.coverEdge(over: icon, on: screen) else { continue }
            let distance = screen.frame.maxX - edge - size.width - 4
            needed = min(needed ?? distance, distance)
        }
        return (current, needed)
    }

    /// Re-adds the icon `distance` from the right edge of the menu bar. macOS
    /// slots it in between the other icons by their own saved places, so it
    /// can land a slot or more short (measured: aims from about 310 to 490 all
    /// landed in one slot); then the next try aims further right by what is
    /// still covered, and by a bigger step each time, up to 8 tries.
    private func move(toWithin distance: CGFloat, attempt: Int) {
        let distance = max(0, distance)
        // Removing the item clears its saved place, and so does the removed
        // item when it is finally freed - measured: kept around until its
        // replacement was made, it wiped the new place. So it is let go at
        // once, and the new place saved a moment later.
        guard let old = item else { return }
        NSStatusBar.system.removeStatusItem(old)
        item = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(Double(distance), forKey: Self.positionKey)
            self.item = Self.makeItem()
            self.configure()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                if attempt < 7, distance > 0, let place = self.clearPlace(), let needed = place.needed,
                   let width = self.item?.button?.window?.frame.width {
                    let step = max(place.current - needed, width * CGFloat(attempt + 1))
                    self.move(toWithin: distance - step, attempt: attempt + 1)
                } else {
                    self.moving = false
                    print("talkflowd: menu bar icon placed \(Int(distance)) from the right edge")
                }
            }
        }
    }

    /// The right edge of a notch app's window over the middle of `icon`, if
    /// there is one. Only another app's window counts, at menu bar level (not a
    /// menu, which sits higher), centred on the screen, and narrower than half
    /// of it; Apple's own windows never count.
    static func coverEdge(over icon: NSRect, on screen: NSScreen) -> CGFloat? {
        guard let primary = NSScreen.screens.first else { return nil }
        // The window list measures from the top left of the primary screen.
        let middle = CGPoint(x: icon.midX, y: primary.frame.maxY - icon.midY)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let menuBarLevel = Int(CGWindowLevelForKey(.statusWindow))
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in windows {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let layer = info[kCGWindowLayer as String] as? Int, layer >= menuBarLevel, layer < menuLevel,
                  (info[kCGWindowAlpha as String] as? Double ?? 0) > 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.contains(middle),
                  abs(rect.midX - screen.frame.midX) < 60, rect.width < screen.frame.width / 2,
                  NSRunningApplication(processIdentifier: pid)?.bundleIdentifier?.hasPrefix("com.apple.") != true
            else { continue }
            return rect.maxX
        }
        return nil
    }

    @objc private func dashboardClicked() {
        onDashboardClicked?()
    }

    @objc private func setupClicked() {
        onSetupClicked?()
    }

    @objc private func updateClicked() {
        onUpdateClicked?()
    }

    /// Shows "Update to X.Y.Z..." at the top of the menu, or hides it (nil).
    func setUpdate(version: String?) {
        updateItem.title = version.map { "Update to \($0)..." } ?? ""
        updateItem.isHidden = version == nil
        updateSeparator.isHidden = version == nil
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
        self.state = state
        item?.button?.contentTintColor = state == .recording ? .systemRed : (state == .processing ? .systemOrange : nil)
        item?.button?.toolTip = state.description
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
