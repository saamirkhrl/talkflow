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

/// The four groups of the Settings page, which its jump links and
/// `DashboardController.show(_:anchor:)` scroll to.
enum SettingsGroup: String, CaseIterable, Hashable {
    case general, dictation, models, about

    var title: String {
        switch self {
        case .general: return "General"
        case .dictation: return "Dictation"
        case .models: return "Models and API keys"
        case .about: return "About"
        }
    }
}

/// The window's state: which section is showing, where Settings should
/// scroll, and what the sidebar and Home's status pill say. The pages'
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
    /// Set to scroll Settings to a group; the page clears it once done.
    @Published var settingsAnchor: SettingsGroup?
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
    /// False under `--windowpreview` and `--dashboardshot`: no update check
    /// or install is ever started from there.
    let updatesEnabled: Bool
    var checkSetup: () -> Bool = { false }
    /// Opens setup. Nil under the preview and snapshots: the pill is shown
    /// but does nothing.
    var openSetup: (() -> Void)?

    private var hotkeyObserver: NSObjectProtocol?

    init(settings: SettingsModel, updatesEnabled: Bool) {
        self.settings = settings
        self.updatesEnabled = updatesEnabled
        dashboard = DashboardModel()
        dictionary = DictionaryModel()
        section = AppSection(rawValue: Preferences.defaults.string(forKey: Self.sectionKey) ?? "") ?? .home
        hotkeyObserver = NotificationCenter.default.addObserver(forName: .hotkeyChanged, object: nil, queue: .main) { [weak self] _ in
            self?.hotkeyName = Preferences.hotkey.name
        }
    }

    deinit {
        if let hotkeyObserver { NotificationCenter.default.removeObserver(hotkeyObserver) }
    }

    func go(to section: AppSection, anchor: SettingsGroup? = nil) {
        self.section = section
        if let anchor { settingsAnchor = anchor }
    }

    /// When the window opens or becomes key: stats, settings and words may
    /// have changed while it was away.
    func refresh() {
        dashboard.refresh()
        settings.refresh()
        dictionary.refresh()
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
            Sidebar(model: model)
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
        case .notes: NotesPage()
        case .dictionary: DictionaryPage(model: model.dictionary, scrolls: !snapshot)
        case .settings: SettingsPage(window: model, model: model.settings, updater: Updater.shared, scrolls: !snapshot)
        }
    }
}

private struct Sidebar: View {
    @ObservedObject var model: AppWindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 26, height: 26)
                    .accessibilityHidden(true)
                Text("talkflow").font(AppFont.wordmark).foregroundColor(Palette.ink)
            }
            .padding(.horizontal, 8)
            VStack(spacing: 4) {
                ForEach(AppSection.allCases, id: \.self) { item($0) }
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text("Hold")
                    Text(model.hotkeyName)
                        .foregroundColor(Palette.ink)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Palette.ink.opacity(0.22), lineWidth: 1))
                    Text("to dictate")
                }
                .accessibilityElement(children: .combine)
                Text("Everything stays on this Mac.")
            }
            .font(AppFont.caption)
            .foregroundColor(Palette.muted)
            .padding(.horizontal, 8)
        }
        .padding(.top, AppMetrics.titlebar + 22)
        .padding(.horizontal, 14)
        .padding(.bottom, 18)
        .frame(width: AppMetrics.sidebarWidth, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.sidebar)
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
                if section == .notes { AppPill(text: "Soon", inverted: selected) }
            }
            .foregroundColor(selected ? Palette.window : Palette.ink)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Palette.ink : Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(section == .notes ? "Notes, coming soon" : section.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help("\(section.title) (Command-\(section.keyEquivalent))")
    }
}
