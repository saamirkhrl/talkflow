import AppKit
import SwiftUI

enum AppSection: String, CaseIterable {
    case home, notes, dictionary, settings

    var title: String {
        switch self {
        case .home: return "Home"
        case .notes: return "Notes"
        case .dictionary: return "Dictionary"
        case .settings: return "Settings"
        }
    }

    /// SF Symbols that exist on macOS 13.
    var symbol: String {
        switch self {
        case .home: return "house"
        case .notes: return "doc.text"
        case .dictionary: return "book.closed"
        case .settings: return "gearshape"
        }
    }

    /// Cmd+1 to Cmd+4, in sidebar order.
    var keyEquivalent: String { String((AppSection.allCases.firstIndex(of: self) ?? 0) + 1) }
}

/// The Settings pages, in the order of the row at the top of Settings. `DashboardController.show(_:anchor:)`
/// and the Notes "Add a key" button open one.
enum SettingsGroup: String, CaseIterable, Hashable {
    case general, dictation, models, apiKeys, notes, about

    var title: String {
        switch self {
        case .general: return "General"
        case .dictation: return "Dictation"
        case .models: return "Models"
        case .apiKeys: return "API keys"
        case .notes: return "Meeting notes"
        case .about: return "About"
        }
    }
}

/// The window's state: which section and which Settings page is showing, and what the sidebar and Home's status pill say. The pages'
/// own state lives in their models.
final class AppWindowModel: ObservableObject {
    /// The last section shown, so the window reopens where the user left
    /// it. Not in `UserData.settingKeys`: it is where the window was, not a
    /// choice worth restoring on a reinstall, and every switch would
    /// rewrite settings.json.
    static let sectionKey = "appWindowSection"

    @Published var section: AppSection {
        didSet { Preferences.defaults.set(section.rawValue, forKey: Self.sectionKey) }
    }
    static let settingsGroupKey = "settingsGroup"

    /// The Settings page showing, remembered like `section` (and, like it, not in UserData.settingKeys).
    @Published var settingsGroup: SettingsGroup {
        didSet { Preferences.defaults.set(settingsGroup.rawValue, forKey: Self.settingsGroupKey) }
    }
    /// Whether setup has anything left to do (same test as the menu bar's
    /// "Finish setup..."). Re-read by `refresh`.
    @Published var setupNeeded = false
    @Published private(set) var hotkeyName = Preferences.hotkey.name
    /// Only for `--dashboardshot`, to draw the update banner and About row
    /// in a state the real updater cannot be put in. Views show
    /// `updateOverride ?? updater.state`.
    @Published var updateOverride: Updater.State?

    let dashboard: DashboardModel
    let settings: SettingsModel
    let dictionary: DictionaryModel
    /// The Notes section. Owned by AppDelegate in the live app (a recording outlives the window).
    let notes: NotesModel
    /// False under `--windowpreview` and `--dashboardshot`: no update check
    /// or install is ever started from there.
    let updatesEnabled: Bool
    var checkSetup: () -> Bool = { false }
    /// Opens setup. Nil under the preview and snapshots: the pill is shown
    /// but does nothing.
    var openSetup: (() -> Void)?

    private var hotkeyObserver: NSObjectProtocol?

    init(settings: SettingsModel, updatesEnabled: Bool, notes: NotesModel) {
        self.settings = settings
        self.notes = notes
        self.updatesEnabled = updatesEnabled
        dashboard = DashboardModel()
        dictionary = DictionaryModel()
        section = AppSection(rawValue: Preferences.defaults.string(forKey: Self.sectionKey) ?? "") ?? .home
        settingsGroup = SettingsGroup(rawValue: Preferences.defaults.string(forKey: Self.settingsGroupKey) ?? "") ?? .general
        hotkeyObserver = NotificationCenter.default.addObserver(forName: .hotkeyChanged, object: nil, queue: .main) { [weak self] _ in
            self?.hotkeyName = Preferences.hotkey.name
        }
        notes.openKeySettings = { [weak self] in self?.go(to: .settings, anchor: .apiKeys) }
    }

    deinit {
        if let hotkeyObserver { NotificationCenter.default.removeObserver(hotkeyObserver) }
    }

    func go(to section: AppSection, anchor: SettingsGroup? = nil) {
        // Notes again from Notes: back to the list, as a sidebar click does on the web.
        if section == .notes && self.section == .notes { notes.backToList() }
        self.section = section
        if let anchor { settingsGroup = anchor }
    }

    /// When the window opens or becomes key: stats, settings and words may
    /// have changed while it was away.
    func refresh() {
        dashboard.refresh()
        settings.refresh()
        dictionary.refresh()
        notes.refresh()
        setupNeeded = checkSetup()
        hotkeyName = Preferences.hotkey.name
    }
}

/// The window's content: the sidebar, a hairline, and the current page.
struct AppShellView: View {
    @ObservedObject var model: AppWindowModel
    /// For `--dashboardshot`: pages at natural height, no scroll views.
    var snapshot = false

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model, updater: Updater.shared)
            Rectangle().fill(Palette.edge).frame(width: 1)
            page.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Palette.window)
        .frame(minWidth: snapshot ? nil : AppMetrics.minSize.width,
               minHeight: snapshot ? nil : AppMetrics.minSize.height)
        .ignoresSafeArea()
    }

    @ViewBuilder private var page: some View {
        switch model.section {
        case .home: HomePage(window: model, model: model.dashboard, updater: Updater.shared, scrolls: !snapshot)
        case .notes: NotesPage(model: model.notes, scrolls: !snapshot)
        case .dictionary: DictionaryPage(model: model.dictionary, scrolls: !snapshot)
        case .settings: SettingsPage(window: model, model: model.settings, updater: Updater.shared, scrolls: !snapshot)
        }
    }
}

private struct Sidebar: View {
    @ObservedObject var model: AppWindowModel
    @ObservedObject var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 10) {
                AppLogo()
                Text("talkflow").font(AppFont.wordmark).foregroundColor(Palette.ink)
            }
            .padding(.horizontal, 8)
            VStack(spacing: 4) {
                ForEach(AppSection.allCases, id: \.self) { item($0) }
            }
            Spacer(minLength: 0)
            footer.padding(.horizontal, 8)
        }
        .padding(.top, AppMetrics.titlebar + 22)
        .padding(.horizontal, 14)
        .padding(.bottom, 18)
        .frame(width: AppMetrics.sidebarWidth, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.sidebar)
    }

    /// The running version and the one update control, so both are in
    /// reach from every section. Same states as Settings > About > Updates.
    @ViewBuilder private var footer: some View {
        let state = model.updateOverride ?? updater.state
        let live = model.updatesEnabled && model.updateOverride == nil
        let preview = "Not available in a preview."
        VStack(alignment: .leading, spacing: 8) {
            Group {
                switch state {
                case .idle, .checking: Text("Version \(Updater.currentVersion)")
                case .upToDate: Text("Version \(Updater.currentVersion). Up to date.")
                case .available(let release): Text("Version \(Updater.currentVersion). \(release.version) is available.")
                case .downloading: Text("Downloading update...")
                case .installing: Text("Installing...")
                case .failed(let message):
                    Text("Version \(Updater.currentVersion). ").foregroundColor(Palette.muted)
                        + Text(message).foregroundColor(Palette.warn)
                }
            }
            .font(AppFont.caption)
            .foregroundColor(Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
            switch state {
            case .idle, .upToDate:
                Button("Check for updates") { updater.check() }
                    .buttonStyle(AppSecondaryButtonStyle())
                    .disabled(!live)
                    .help(live ? "" : preview)
            case .checking:
                Button("Checking...") {}
                    .buttonStyle(AppSecondaryButtonStyle())
                    .disabled(true)
            case .available(let release):
                UpdateInstallButton(release: release, enabled: live) { updater.install() }
            case .downloading, .installing:
                EmptyView()
            case .failed:
                Button("Retry") { updater.check() }
                    .buttonStyle(AppSecondaryButtonStyle())
                    .disabled(!live)
                    .help(live ? "" : preview)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func item(_ section: AppSection) -> some View {
        let selected = model.section == section
        return Button {
            model.go(to: section)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: section.symbol)
                    .font(.system(size: 15))
                    .frame(width: 18, height: 18)
                Text(section.title)
                    .font(.system(size: 14, weight: selected ? .medium : .regular))
                Spacer(minLength: 0)
            }
            .foregroundColor(selected ? Palette.window : Palette.ink)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Palette.ink : Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help("\(section.title) (Command-\(section.keyEquivalent))")
    }
}
