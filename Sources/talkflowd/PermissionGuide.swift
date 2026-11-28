import AppKit
import SwiftUI

// The floating guide that sits beside System Settings while someone grants a
// permission: "Drag talkflow into the list" (with the app icon to drag) or
// "Switch talkflow on". It never takes focus and shows only while System
// Settings is the frontmost app.

// MARK: - Placement (pure)

enum GuidePlacement {
    static let gap: CGFloat = 12          // between System Settings and the panel
    static let topInset: CGFloat = 60     // below System Settings' toolbar
    static let insideInset: CGFloat = 16  // when it has to sit inside the window
    static let minWindow = CGSize(width: 300, height: 200)

    /// CG window bounds (top-left origin, primary screen) -> Cocoa (bottom-left origin).
    static func cocoaRect(cg: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: cg.minX, y: primaryHeight - cg.maxY, width: cg.width, height: cg.height)
    }

    /// settings: System Settings frame (Cocoa). screen: visibleFrame of the screen holding it.
    /// panel: panel size.
    static func origin(settings: CGRect, screen: CGRect, panel: CGSize) -> CGPoint {
        var y = settings.maxY - panel.height - topInset
        var x = settings.maxX + gap                                   // right of the window
        if x + panel.width > screen.maxX {
            x = settings.minX - gap - panel.width                     // left of the window
            if x < screen.minX {                                      // no room either side: inside, bottom-right
                x = settings.maxX - panel.width - insideInset
                y = settings.minY + insideInset
            }
        }
        x = min(max(x, screen.minX), screen.maxX - panel.width)
        y = min(max(y, screen.minY), screen.maxY - panel.height)
        return CGPoint(x: x, y: y)
    }

    /// From CGWindowListCopyWindowInfo entries: the first (front-most) window owned by pid, layer 0,
    /// width >= minWindow.width and height >= minWindow.height. Bounds as CG rect, or nil.
    static func pickSettingsWindow(_ infos: [[String: Any]], pid: Int32) -> CGRect? {
        for info in infos {
            guard let owner = intValue(info[kCGWindowOwnerPID as String]), owner == Int(pid) else { continue }
            guard let layer = intValue(info[kCGWindowLayer as String]), layer == 0 else { continue }
            let raw = info[kCGWindowBounds as String]
            let rect: CGRect?
            if let dict = raw as? [String: Any] {
                rect = CGRect(dictionaryRepresentation: dict as CFDictionary)
            } else if let dict = raw as? NSDictionary {
                rect = CGRect(dictionaryRepresentation: dict as CFDictionary)
            } else {
                rect = nil
            }
            guard let bounds = rect else { continue }
            if bounds.width >= minWindow.width && bounds.height >= minWindow.height { return bounds }
        }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let v = value as? Int { return v }
        if let v = value as? Int32 { return Int(v) }
        if let v = value as? NSNumber { return v.intValue }
        return nil
    }
}

// MARK: - Controller

final class PermissionGuide {
    static let shared = PermissionGuide()

    static let settingsBundleID = "com.apple.systempreferences"
    static let findTimeout: TimeInterval = 4.0     // System Settings usually shows in 1-2 s
    static let tick: TimeInterval = 0.1
    static let panelSize = CGSize(width: 280, height: 84)

    private var panel: NSPanel?
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var request: GuideRequest?
    private var outcome: ((GuideOutcome) -> Void)?
    private var startedAt = Date()
    private var reported = false

    private init() {}

    func show(_ request: GuideRequest, outcome: @escaping (GuideOutcome) -> Void) {
        hide()   // any previous one, silently: no outcome for it
        self.request = request
        self.outcome = outcome
        startedAt = Date()
        reported = false

        let panel = makePanel(for: request)
        self.panel = panel

        let timer = Timer(timeInterval: Self.tick, repeats: true) { [weak self] _ in self?.update() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.update() }

        update()
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        panel?.orderOut(nil)
        panel = nil
        request = nil
        outcome = nil
    }

    private func makePanel(for request: GuideRequest) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovableByWindowBackground = false
        let view = GuidePanelView(request: request, appName: OnboardingEnvironment.live.appName)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: Self.panelSize)
        panel.contentView = host
        return panel
    }

    private func update() {
        guard let panel, request != nil else { return }

        let pid = NSRunningApplication
            .runningApplications(withBundleIdentifier: Self.settingsBundleID).first?.processIdentifier
        let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                               kCGNullWindowID) as? [[String: Any]] ?? []
        let cg = pid.flatMap { GuidePlacement.pickSettingsWindow(infos, pid: $0) }

        guard let cg else {
            panel.orderOut(nil)
            if !reported && Date().timeIntervalSince(startedAt) >= Self.findTimeout {
                reported = true
                let callback = outcome
                hide()
                callback?(.notFound)
            }
            return
        }

        guard let primary = NSScreen.screens.first else { return }
        let frame = GuidePlacement.cocoaRect(cg: cg, primaryHeight: primary.frame.height)
        let screen = NSScreen.screens.max { area($0.frame, frame) < area($1.frame, frame) }
        let best = (screen.map { area($0.frame, frame) > 0 } ?? false) ? screen : NSScreen.main
        let visible = (best ?? primary).visibleFrame
        panel.setFrameOrigin(GuidePlacement.origin(settings: frame, screen: visible, panel: Self.panelSize))

        let frontIsSettings = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.settingsBundleID
        if frontIsSettings {
            panel.orderFrontRegardless()   // never makes it key
            if !reported {
                reported = true
                outcome?(.shown)
            }
        } else {
            panel.orderOut(nil)
        }
    }

    private func area(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let r = a.intersection(b)
        return r.isNull ? 0 : r.width * r.height
    }
}

// MARK: - Panel content

struct GuidePanelView: View {
    let request: GuideRequest
    let appName: String
    /// True when rendered into a still image: the drag icon becomes a plain image.
    var snapshot: Bool = false

    init(request: GuideRequest, appName: String, snapshot: Bool = false) {
        self.request = request
        self.appName = appName
        self.snapshot = snapshot
    }

    private static var appIcon: NSImage {
        // A bare `.build` binary has no bundle icon; use the app icon then.
        let icon = Bundle.main.bundleURL.pathExtension == "app"
            ? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath) : (NSApp?.applicationIconImage ?? NSImage())
        icon.size = NSSize(width: 44, height: 44)
        return icon
    }

    private var line: String {
        switch request.mode {
        case .drag: return "Drag \(appName) into the list."
        case .switchOn: return "Switch \(appName) on."
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            if request.mode == .drag && !snapshot {
                AppDragIcon().frame(width: 44, height: 44)
            } else {
                Image(nsImage: Self.appIcon).resizable().frame(width: 44, height: 44)
            }
            Text(line)
                .font(AppFont.bodyMedium)
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: PermissionGuide.panelSize.width, height: PermissionGuide.panelSize.height, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppMetrics.cardRadius, style: .continuous).fill(Palette.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppMetrics.cardRadius, style: .continuous).stroke(Palette.cardStroke)
        )
    }
}

// MARK: - Drag source

struct AppDragIcon: NSViewRepresentable {
    func makeNSView(context: Context) -> AppDragSource { AppDragSource(frame: NSRect(x: 0, y: 0, width: 44, height: 44)) }
    func updateNSView(_ nsView: AppDragSource, context: Context) {}
}

final class AppDragSource: NSView, NSDraggingSource {
    private let icon: NSImage = {
        let image = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        image.size = NSSize(width: 44, height: 44)
        return image
    }()
    private var dragStarted = false

    override var intrinsicContentSize: NSSize { NSSize(width: 44, height: 44) }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        icon.draw(in: bounds)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        dragStarted = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragStarted else { return }
        dragStarted = true
        let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
        item.setDraggingFrame(bounds, contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy   // never .move or .generic: a drop on Finder must not move the app
    }
}
