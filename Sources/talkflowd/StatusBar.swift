import AppKit

/// Minimal menu bar indicator: a bars glyph (matching the app icon) tinted by
/// state, with a small dot on it while a meeting is being recorded. A left
/// click opens the talkflow window; a right click or Control-click shows a
/// short menu with Open talkflow, the writing style, Settings and Quit (and
/// "Update to X.Y.Z..." while a newer version is available, "Finish setup..."
/// while something setup gives talkflow is missing, "Stop and write notes"
/// while a meeting records).
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
    /// Left click on the icon, and "Open talkflow" in the menu.
    var onDashboardClicked: (() -> Void)?
    var onSettingsClicked: (() -> Void)?
    /// Called on every state change; AppDelegate uses `.idle` to apply a
    /// Dock icon change that waited for the dictation (DockIcon).
    var onStateChange: ((State) -> Void)?
    /// Recording, or still writing the text.
    var isBusy: Bool { state != .idle }
    var onSetupClicked: (() -> Void)?
    /// Whether setup has anything left to do. Asked each time the menu
    /// opens, so a finished setup never shows in it, and one an update
    /// undid (a permission macOS no longer applies) does.
    var setupNeeded: () -> Bool = { false }
    /// Opens the talkflow window on Settings > About, where the Update button is.
    var onUpdateClicked: (() -> Void)?
    private var styleItems: [NSMenuItem] = []
    private let updateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let lowerSeparator = NSMenuItem.separator()
    private let setupItem = NSMenuItem(title: "Finish setup...", action: nil, keyEquivalent: "")
    /// A meeting is being recorded in Notes. Separate from `state`, which is dictation's: dictation keeps working
    /// during a meeting, and only dictation should hold back the Dock icon change (DockIcon).
    private(set) var meetingRecording = false
    /// "Stop and write notes" in the right-click menu, shown only while a meeting records.
    var onStopMeeting: (() -> Void)?
    private let stopMeetingItem = NSMenuItem(title: "Stop and write notes", action: nil, keyEquivalent: "")
    private let meetingSeparator = NSMenuItem.separator()

    override init() {
        Self.keepEarlierPlace()
        item = Self.makeItem()
        super.init()
        menu.delegate = self
        stopMeetingItem.action = #selector(stopMeetingClicked)
        stopMeetingItem.target = self
        stopMeetingItem.isHidden = true
        menu.addItem(stopMeetingItem)
        meetingSeparator.isHidden = true
        menu.addItem(meetingSeparator)
        menu.addItem(withTitle: "Open talkflow", action: #selector(dashboardClicked), keyEquivalent: "")
            .target = self
        // The same setting as on the Settings page, one click away.
        let styleMenu = NSMenu(title: "Writing style")
        for style in WritingStyle.allCases {
            let item = NSMenuItem(title: style.title, action: #selector(styleClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style.rawValue
            item.toolTip = style.detail
            styleMenu.addItem(item)
            styleItems.append(item)
        }
        let styleItem = NSMenuItem(title: "Writing style", action: nil, keyEquivalent: "")
        styleItem.submenu = styleMenu
        menu.addItem(styleItem)
        menu.addItem(withTitle: "Settings...", action: #selector(settingsClicked), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        // Only while a newer version is available (see setUpdate).
        updateItem.action = #selector(updateClicked)
        updateItem.target = self
        updateItem.isHidden = true
        menu.addItem(updateItem)
        setupItem.action = #selector(setupClicked)
        setupItem.target = self
        setupItem.isHidden = true
        menu.addItem(setupItem)
        lowerSeparator.isHidden = true
        menu.addItem(lowerSeparator)
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
        guard let button = item?.button else { return }
        // No menu attached: an item with a menu opens it on every click, and
        // a left click must open the window instead.
        item?.menu = nil
        button.target = self
        button.action = #selector(iconClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        // Through applyLook, so an icon re-made by `move` keeps the meeting look.
        applyLook()
    }

    /// Left click opens the window; right click or Control-click shows the
    /// short menu.
    @objc private func iconClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if wantsMenu { showMenu() } else { onDashboardClicked?() }
    }

    /// Attached only while it is open: performClick shows it and returns
    /// once it closes.
    private func showMenu() {
        guard let item, let button = item.button else { return }
        item.menu = menu
        button.performClick(nil)
        item.menu = nil
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === self.menu { item?.menu = nil }
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

    @objc private func settingsClicked() {
        onSettingsClicked?()
    }

    @objc private func setupClicked() {
        onSetupClicked?()
    }

    @objc private func updateClicked() {
        onUpdateClicked?()
    }

    @objc private func stopMeetingClicked() {
        onStopMeeting?()
    }

    /// Shows the meeting dot on the icon and "Stop and write notes" in the menu, or removes them.
    func setMeetingRecording(_ on: Bool) {
        meetingRecording = on
        stopMeetingItem.isHidden = !on
        meetingSeparator.isHidden = !on
        applyLook()
    }

    /// Shows "Update to X.Y.Z..." in the menu, or hides it (nil). The
    /// separator under it is decided when the menu opens.
    func setUpdate(version: String?) {
        updateItem.title = version.map { "Update to \($0)..." } ?? ""
        updateItem.isHidden = version == nil
    }

    @objc private func styleClicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let style = WritingStyle(rawValue: raw) else { return }
        Preferences.writingStyle = style
    }

    /// Ticks the current style each time the menu opens, so a change made on
    /// the Settings page shows here too, and shows "Finish setup..." only
    /// while it is needed.
    func menuNeedsUpdate(_ menu: NSMenu) {
        setupItem.isHidden = !setupNeeded()
        lowerSeparator.isHidden = updateItem.isHidden && setupItem.isHidden
        let current = Preferences.writingStyle.rawValue
        for item in styleItems { item.state = item.representedObject as? String == current ? .on : .off }
    }

    func setState(_ state: State) {
        self.state = state
        applyLook()
        onStateChange?(state)
    }

    /// The icon as dictation's state and a running meeting make it.
    private func applyLook() {
        item?.button?.image = meetingRecording ? Self.meetingImage : Self.barsImage
        item?.button?.contentTintColor = state == .recording ? .systemRed : (state == .processing ? .systemOrange : nil)
        // No toolTip: talkflow is a menu bar (accessory) app, and a tooltip
        // shown over the icon was left on screen for good when it was
        // replaced (each dictation changes the state) or the icon was moved
        // (see `move`). The tint already shows the state; VoiceOver reads it
        // from the accessibility label instead.
        item?.button?.toolTip = nil
        item?.button?.setAccessibilityLabel(state.description + (meetingRecording ? ", recording a meeting" : ""))
    }

    /// Draws the 5-bar waveform mark, `shiftX` points to the right of centre.
    private static func drawBars(in rect: NSRect, shiftX: CGFloat) {
        let barCount = 5
        let barWidth: CGFloat = 2.2
        let spacing: CGFloat = 1.6
        let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * spacing
        let startX = (rect.width - totalWidth) / 2 + shiftX
        let heights: [CGFloat] = [0.4, 0.65, 1.0, 0.65, 0.4]
        NSColor.black.setFill()
        for i in 0..<barCount {
            let h = rect.height * heights[i]
            let barRect = NSRect(x: startX + CGFloat(i) * (barWidth + spacing), y: (rect.height - h) / 2, width: barWidth, height: h)
            NSBezierPath(roundedRect: barRect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    }

    /// Same 5-bar waveform mark as the app icon, drawn at menu bar size. Always a
    /// template image so contentTintColor can recolor it per state.
    private static let barsImage: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            drawBars(in: rect, shiftX: 0)
            return true
        }
        image.isTemplate = true
        return image
    }()

    /// The mark with a dot on it: the meeting sign. Template, so dictation's
    /// red/orange tint still applies on top during a meeting. The bars sit 2pt
    /// to the left to make room for the dot.
    private static let meetingImage: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            drawBars(in: rect, shiftX: -2)
            let d: CGFloat = 5
            let center = CGPoint(x: rect.width - 3, y: rect.height - 3.5)
            NSBezierPath(ovalIn: NSRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d)).fill()
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
