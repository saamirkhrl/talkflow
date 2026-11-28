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
    private var spaceObserver: NSObjectProtocol?
    private var reportWork: DispatchWorkItem?
    /// Index into NSScreen.screens of the screen chosen at the last placement.
    private var screenIndex: Int?
    /// The last diagnostic line, for --pilltest.
    private(set) var lastShowReport: String?

    init() {
        // A display plugged in, unplugged or rearranged moves every screen's
        // coordinates; a pill on screen re-places itself so it never sits at
        // the old ones (or on a display that is gone). The caption follows on
        // its next update, which reads `screen`.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // New displays come with new Spaces: a pill on screen is rebuilt so it
            // joins them, then placed at the new coordinates.
            if self.panel?.isVisible == true { self.reshow(reason: "screens") } else { self.screen = nil }
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, let panel = self.panel, panel.isVisible, !panel.isOnActiveSpace else { return }
            // Moved to a Space the pill never joined while it was up.
            self.reshow(reason: "space")
        }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
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

    /// Every overlay panel: no title bar, and never activates talkflow or takes
    /// the key focus, so dictation keeps typing into the app in front.
    static let overlayStyle: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]

    /// A panel joins the Spaces that exist when it is ordered in, and keeps
    /// that set while ordered out. A Space made later (an app entering full
    /// screen, the Spaces macOS rebuilds when a display comes or goes) never
    /// gets it, and nothing done to the existing window brings it back. So
    /// the pill is built fresh whenever it is not already on screen on the
    /// active Space; a new panel joins every Space there is.
    static func needsFreshPanel(exists: Bool, visible: Bool, onActiveSpace: Bool) -> Bool {
        !exists || !visible || !onActiveSpace
    }

    /// Takes an old panel off screen for good.
    private static func retire(_ panel: NSPanel?) {
        panel?.orderOut(nil)
        panel?.close()
    }

    /// A new pill, and no caption until the next one is needed: both join
    /// every Space that exists right now.
    private func rebuildPanels() {
        Self.retire(panel)
        panel = nil
        Self.retire(captionPanel)
        captionPanel = nil
        captionLabel = nil
        buildPanel()
    }

    func show() {
        let fresh = Self.needsFreshPanel(exists: panel != nil, visible: panel?.isVisible == true,
                                         onActiveSpace: panel?.isOnActiveSpace == true)
        if fresh { rebuildPanels() }
        placePill()
        panel?.orderFrontRegardless()
        scheduleShowReport(reason: "show", rebuilt: fresh)
    }

    /// The pill is up but has to be rebuilt (new displays, or a Space it never joined).
    private func reshow(reason: String) {
        rebuildPanels()
        placePill()
        panel?.orderFrontRegardless()
        scheduleShowReport(reason: reason, rebuilt: true)
    }

    /// Centers the pill horizontally at the bottom of the screen the user is
    /// dictating into. Recomputed on every show, never cached across them.
    private func placePill() {
        guard let panel else { return }
        let screens = NSScreen.screens
        guard let index = Self.targetScreenIndex(), screens.indices.contains(index) else { return }
        let screen = screens[index]
        self.screen = screen
        screenIndex = index
        panel.setFrame(Self.pillFrame(on: screen.frame, width: width, height: height, bottomOffset: bottomOffset), display: true)
    }

    /// Bottom-center of `screen` (AppKit coordinates), `bottomOffset` up.
    static func pillFrame(on screen: CGRect, width: CGFloat, height: CGFloat, bottomOffset: CGFloat) -> CGRect {
        CGRect(x: (screen.midX - width / 2).rounded(), y: screen.minY + bottomOffset, width: width, height: height)
    }

    /// The screen the user is working on: the one holding most of the
    /// frontmost app's frontmost window (the app the text goes into); if that
    /// app has no window on screen, the one under the mouse; else the main
    /// screen; else the first. Read fresh at every show from the window server,
    /// not Accessibility: this runs the moment the hotkey goes down and must
    /// not wait on a slow app.
    static func targetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        guard let index = targetScreenIndex(), screens.indices.contains(index) else { return nil }
        return screens[index]
    }

    static func targetScreenIndex() -> Int? {
        let screens = NSScreen.screens
        let front = NSWorkspace.shared.frontmostApplication.flatMap { frontWindowBounds(of: $0.processIdentifier) }
        let main = NSScreen.main.flatMap { m in screens.firstIndex { $0 == m } }
        return pickScreen(screens: screens.map(\.frame), frontWindow: front, mouse: NSEvent.mouseLocation, mainIndex: main)
    }

    /// Pure: `screens` are AppKit frames (bottom-left origin) with the primary
    /// display first, as NSScreen.screens gives them; `frontWindow` is in
    /// window-server coordinates (top-left origin on the primary display);
    /// `mouse` is in AppKit coordinates. A window or mouse on a display that is
    /// gone matches nothing and falls through to the next rule.
    static func pickScreen(screens: [CGRect], frontWindow: CGRect?, mouse: CGPoint, mainIndex: Int?) -> Int? {
        guard let primary = screens.first else { return nil }
        if let bounds = frontWindow {
            let window = CGRect(x: bounds.minX, y: primary.maxY - bounds.maxY, width: bounds.width, height: bounds.height)
            var best: Int?
            var bestArea: CGFloat = 0
            for (i, s) in screens.enumerated() {
                let area = overlap(s, window)
                if area > bestArea { best = i; bestArea = area }
            }
            if let best { return best }
        }
        // Same edges as NSMouseInRect for an unflipped rect.
        if let i = screens.firstIndex(where: { mouse.x >= $0.minX && mouse.x < $0.maxX && mouse.y > $0.minY && mouse.y <= $0.maxY }) {
            return i
        }
        if let mainIndex, screens.indices.contains(mainIndex) { return mainIndex }
        return 0
    }

    /// Pure: whether a window (window-server coordinates) covers a whole
    /// display, as a native full-screen window does; a zoomed window stops
    /// at the menu bar and the Dock. On a display with a camera housing, a
    /// full-screen window may start below it: `topInsets[i]` is display i's
    /// safe-area top (0 elsewhere). Diagnostic only: with the Dock hidden, a
    /// zoomed window on such a display looks the same.
    static func isFullScreen(window: CGRect, displays: [CGRect], topInsets: [CGFloat] = []) -> Bool {
        displays.enumerated().contains { i, d in
            let inset = i < topInsets.count ? topInsets[i] : 0
            let topOK = abs(d.minY - window.minY) <= 1 || (inset > 0 && abs(d.minY + inset - window.minY) <= 1)
            return topOK && abs(d.minX - window.minX) <= 1 && abs(d.width - window.width) <= 1 && abs(d.maxY - window.maxY) <= 1
        }
    }

    /// Whether the frontmost app's frontmost window is full screen right now.
    static func frontIsFullScreen() -> Bool {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        // All of the app's normal windows together: some full-screen apps draw
        // their tab bar as a separate window above the main one.
        let rects = list.compactMap { info -> CGRect? in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid, (info[kCGWindowLayer as String] as? Int) == 0,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
            return CGRect(dictionaryRepresentation: dict)
        }
        guard let first = rects.first else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return false }
        let active = Array(ids.prefix(Int(count)))
        // Only the windows on the display of the frontmost one.
        let display = active.map { CGDisplayBounds($0) }.first { $0.contains(CGPoint(x: first.midX, y: first.midY)) } ?? first
        let bounds = rects.filter { $0.intersects(display) }.reduce(first) { $0.union($1) }
        let insets: [CGFloat] = active.map { id in
            NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }?.safeAreaInsets.top ?? 0
        }
        return isFullScreen(window: bounds, displays: active.map { CGDisplayBounds($0) }, topInsets: insets)
    }

    /// What one pill show looked like, for the log. No dictated text.
    struct ShowFacts {
        var reason: String
        var rebuilt: Bool
        var policy: NSApplication.ActivationPolicy
        var appActive: Bool
        var panelClass: String
        var style: NSWindow.StyleMask
        var level: Int
        var behavior: NSWindow.CollectionBehavior
        var hidesOnDeactivate: Bool
        var screenIndex: Int?
        var screens: [CGRect]
        var frame: CGRect
        var frontFullScreen: Bool
        var visible: Bool
        var onActiveSpace: Bool
        var occlusionVisible: Bool
        var cgOnscreen: Bool
    }

    static func showReport(_ f: ShowFacts) -> String {
        func yn(_ b: Bool) -> String { b ? "yes" : "no" }
        func rect(_ r: CGRect) -> String { "\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))" }
        let policy: String
        switch f.policy {
        case .regular: policy = "regular"
        case .accessory: policy = "accessory"
        case .prohibited: policy = "prohibited"
        @unknown default: policy = "other"
        }
        var style: [String] = [f.style.contains(.titled) ? "titled" : "borderless"]
        if f.style.contains(.nonactivatingPanel) { style.append("nonactivating") }
        let names: [(NSWindow.CollectionBehavior, String)] = [
            (.canJoinAllSpaces, "canJoinAllSpaces"), (.moveToActiveSpace, "moveToActiveSpace"),
            (.managed, "managed"), (.transient, "transient"), (.stationary, "stationary"),
            (.participatesInCycle, "participatesInCycle"), (.ignoresCycle, "ignoresCycle"),
            (.fullScreenPrimary, "fullScreenPrimary"), (.fullScreenAuxiliary, "fullScreenAuxiliary"),
            (.fullScreenNone, "fullScreenNone")
        ]
        let behavior = names.filter { f.behavior.contains($0.0) }.map(\.1).joined(separator: ",")
        return "talkflowd: pill shown: reason=\(f.reason) rebuilt=\(yn(f.rebuilt)) policy=\(policy) active=\(yn(f.appActive))"
            + " panel=\(f.panelClass) style=\(style.joined(separator: ",")) level=\(f.level)"
            + " behavior=\(behavior.isEmpty ? "none" : behavior) hidesOnDeactivate=\(yn(f.hidesOnDeactivate))"
            + " screen=\(f.screenIndex.map(String.init) ?? "none") screens=[\(f.screens.map(rect).joined(separator: "; "))]"
            + " frame=\(rect(f.frame)) frontFullScreen=\(yn(f.frontFullScreen)) visible=\(yn(f.visible))"
            + " onActiveSpace=\(yn(f.onActiveSpace)) occlusionVisible=\(yn(f.occlusionVisible)) cgOnscreen=\(yn(f.cgOnscreen))"
    }

    /// Logs the show 0.3 s later, once the window server has put the pill on
    /// screen (or not), so the line says what the user actually saw.
    private func scheduleShowReport(reason: String, rebuilt: Bool) {
        reportWork?.cancel()
        let frontFullScreen = Self.frontIsFullScreen()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.panel else { return }
            let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(panel.windowNumber)) as? [[String: Any]]
            let facts = ShowFacts(
                reason: reason, rebuilt: rebuilt,
                policy: NSApp.activationPolicy(), appActive: NSApp.isActive,
                panelClass: String(describing: type(of: panel)), style: panel.styleMask,
                level: panel.level.rawValue, behavior: panel.collectionBehavior,
                hidesOnDeactivate: panel.hidesOnDeactivate,
                screenIndex: self.screenIndex, screens: NSScreen.screens.map(\.frame),
                frame: panel.frame, frontFullScreen: frontFullScreen,
                visible: panel.isVisible, onActiveSpace: panel.isOnActiveSpace,
                occlusionVisible: panel.occlusionState.contains(.visible),
                cgOnscreen: (info?.first?[kCGWindowIsOnscreen as String] as? Bool) ?? false
            )
            let line = Self.showReport(facts)
            self.lastShowReport = line
            print(line)
        }
        reportWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
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
            styleMask: Self.overlayStyle,
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
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
            // Same reason as the pill: a notice not on screen is built fresh.
            if let old = noticePanel, !old.isVisible || !old.isOnActiveSpace {
                Self.retire(old)
                noticePanel = nil
                noticeLabel = nil
            }
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
            styleMask: Self.overlayStyle,
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
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
            styleMask: Self.overlayStyle,
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
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
