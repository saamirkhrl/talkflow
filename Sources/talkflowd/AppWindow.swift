import AppKit
import SwiftUI

/// Who needs the Dock icon. talkflow is a menu bar app (LSUIElement); it is
/// a regular app only while one of its windows is open, so the window can be
/// found again with Cmd-Tab or the Dock. Setup and the app window can both
/// be open, so the icon goes only when neither wants it. Never switched
/// mid-dictation: going back to accessory deactivates talkflow and hands
/// the focus to another app while keystrokes may still be landing, so the
/// change waits for the dictation to end.
@MainActor
enum DockIcon {
    enum Reason: Hashable { case setup, appWindow }

    private static var reasons: Set<Reason> = []
    /// Set by AppDelegate: whether a dictation is recording or still writing.
    static var isDictating: () -> Bool = { false }

    static func require(_ reason: Reason) {
        reasons.insert(reason)
        apply()
    }

    static func release(_ reason: Reason) {
        reasons.remove(reason)
        apply()
    }

    /// The menu bar icon went back to idle: apply whatever waited.
    static func dictationEnded() {
        apply()
    }

    private static func apply() {
        guard !isDictating() else { return }
        let wanted: NSApplication.ActivationPolicy = reasons.isEmpty ? .accessory : .regular
        if NSApp.activationPolicy() != wanted { NSApp.setActivationPolicy(wanted) }
    }
}

/// The app window: a sidebar with Home, Notes, Dictionary and Settings. Named
/// for the dashboard it replaced, so its call sites stay the same. Closing it
/// only hides it; talkflow keeps running in the menu bar.
final class DashboardController: NSWindowController, NSWindowDelegate {
    enum Mode {
        case live
        /// `--windowpreview`: throwaway settings, no Dock bookkeeping, no
        /// update checks, closing quits.
        case preview
    }

    static let frameName = "talkflowAppWindow"
    let model: AppWindowModel
    private let mode: Mode
    private var keyObserver: NSObjectProtocol?
    var onClose: (() -> Void)?

    var setupNeeded: () -> Bool {
        get { model.checkSetup }
        set { model.checkSetup = newValue }
    }

    var openSetup: (() -> Void)? {
        get { model.openSetup }
        set { model.openSetup = newValue }
    }

    /// The live app passes AppDelegate's model so a recording outlives the window.
    init(mode: Mode = .live, notes: NotesModel? = nil) {
        self.mode = mode
        let settings = SettingsModel(environment: mode == .live ? .live : .preview())
        let notesModel = notes ?? (mode == .live ? NotesModel.live() : NotesModel.preview())
        model = AppWindowModel(settings: settings, updatesEnabled: mode == .live, notes: notesModel)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: AppMetrics.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "talkflow"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentMinSize = AppMetrics.minSize
        // Comes to whichever Space the user is on, as setup does.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenNone]
        let host = NSHostingView(rootView: AppShellView(model: model))
        // Only the minimum comes from SwiftUI, so the window stays freely resizable.
        host.sizingOptions = [.minSize]
        window.contentView = host
        super.init(window: window)
        window.delegate = self
        if mode == .live {
            if !window.setFrameUsingName(Self.frameName) { window.center() }
            window.setFrameAutosaveName(Self.frameName)
        } else {
            // The preview never writes the window frame anywhere.
            window.center()
        }
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { [weak self] _ in self?.model.refresh() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
    }

    /// Opens the window on `section` (else where it was left), or brings it
    /// forward. During a dictation it is only put on screen, not made key and
    /// not activated, so the dictation's keystrokes keep going to the app the
    /// user is in; the Dock icon follows once the dictation ends.
    func show(_ section: AppSection? = nil, anchor: SettingsGroup? = nil) {
        MainMenu.install(for: self)
        if let section { model.go(to: section, anchor: anchor) }
        model.refresh()
        guard let window else { return }
        if mode == .live {
            Updater.shared.checkIfStale()
            DockIcon.require(.appWindow)
            if DockIcon.isDictating() {
                window.orderFrontRegardless()
                return
            }
        } else if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.unhide(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openSettings(_ sender: Any?) {
        show(.settings)
    }

    @objc func goToSection(_ sender: NSMenuItem) {
        guard AppSection.allCases.indices.contains(sender.tag) else { return }
        show(AppSection.allCases[sender.tag])
    }

    func windowWillClose(_ notification: Notification) {
        model.settings.cancelHotkeyRecording()
        if mode == .live { DockIcon.release(.appWindow) }
        onClose?()
    }
}

/// The hidden Edit menu. A menu bar app has no menus of its own, and text
/// fields only get Cmd+X/C/V/A and undo through a main menu's key
/// equivalents, so this is what makes pasting an API key work. Shared by
/// AppDelegate, MainMenu and --pastetest so the test checks the real one.
/// Not @MainActor: AppDelegate is not, and MainActor.assumeIsolated needs
/// macOS 14. It only touches NSApp, always from the main thread.
enum EditMenu {
    static func item() -> NSMenuItem {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        return editItem
    }

    /// Puts the Edit menu in the main menu if it is not there yet.
    static func install() {
        let main = NSApp.mainMenu ?? NSMenu()
        if main.items.isEmpty {
            main.addItem(NSMenuItem(title: "talkflow", action: nil, keyEquivalent: ""))
        }
        if main.item(withTitle: "Edit") == nil { main.addItem(item()) }
        NSApp.mainMenu = main
    }
}

/// The menus a regular app needs while the window is open: Settings (Cmd+,),
/// Hide, Quit, the sections (Cmd+1 to Cmd+4), Close (Cmd+W) and Minimize.
/// The Edit menu (Cmd+V into the key fields) comes from EditMenu.
@MainActor
enum MainMenu {
    private static var installed = false

    static func install(for controller: DashboardController) {
        guard !installed else { return }
        installed = true
        let main = NSApp.mainMenu ?? NSMenu()

        let appItem: NSMenuItem
        if let first = main.items.first {
            appItem = first
        } else {
            appItem = NSMenuItem(title: "talkflow", action: nil, keyEquivalent: "")
            main.addItem(appItem)
        }
        let app = NSMenu(title: "talkflow")
        let settings = NSMenuItem(title: "Settings...", action: #selector(DashboardController.openSettings(_:)), keyEquivalent: ",")
        settings.target = controller
        app.addItem(settings)
        app.addItem(.separator())
        app.addItem(withTitle: "Hide talkflow", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit talkflow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app

        // Only the preview gets here without AppDelegate's Edit menu.
        if main.item(withTitle: "Edit") == nil {
            main.addItem(EditMenu.item())
        }

        let go = NSMenu(title: "Go")
        for (index, section) in AppSection.allCases.enumerated() {
            let item = NSMenuItem(title: section.title, action: #selector(DashboardController.goToSection(_:)), keyEquivalent: section.keyEquivalent)
            item.target = controller
            item.tag = index
            go.addItem(item)
        }
        let goItem = NSMenuItem(title: "Go", action: nil, keyEquivalent: "")
        goItem.submenu = go
        main.addItem(goItem)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.windowsMenu = window

        NSApp.mainMenu = main
    }
}
