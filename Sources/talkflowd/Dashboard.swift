import AppKit
import SwiftUI

/// Stats window styled like the site's dashboard mock: paper and ink, serif
/// numerals, hairline tiles. All from StatsStore (local JSON, never leaves the Mac).
final class DashboardController: NSWindowController {
    private let model = DashboardModel()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        window.contentView = NSHostingView(rootView: DashboardView(model: model))
    }

    func show() {
        model.refresh()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

enum DashboardPage: String, CaseIterable {
    case dashboard = "Dashboard"
    case settings = "Settings"
}

/// Splits minutes into the two largest whole units, e.g. 879 -> 14 h 39 min,
/// 4000 -> 2 d 18 h. Units: min, h, d, wk, mo (30 d), yr (365 d).
func timeSavedParts(minutes: Int) -> [(value: String, unit: String)] {
    let units: [(name: String, minutes: Int)] = [
        ("yr", 365 * 24 * 60), ("mo", 30 * 24 * 60), ("wk", 7 * 24 * 60),
        ("d", 24 * 60), ("h", 60), ("min", 1)
    ]
    var remaining = max(minutes, 0)
    var parts: [(value: String, unit: String)] = []
    for unit in units where remaining >= unit.minutes {
        parts.append((String(remaining / unit.minutes), unit.name))
        remaining %= unit.minutes
        if parts.count == 2 { break }
    }
    return parts.isEmpty ? [("0", "min")] : parts
}

final class DashboardModel: ObservableObject {
    @Published var snapshot = StatsStore.shared.snapshot()
    @Published var days = StatsStore.shared.recentDays(DashboardModel.chartDays)
    @Published var page: DashboardPage = .dashboard
    let settings = SettingsModel()

    static let chartWeeks = 26

    /// Enough days to fill `chartWeeks` columns, the last one running up to today,
    /// so the first day always lands on the first row of its column.
    static var chartDays: Int {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: Date())
        let sinceWeekStart = (weekday - calendar.firstWeekday + 7) % 7
        return (chartWeeks - 1) * 7 + sinceWeekStart + 1
    }

    func refresh() {
        settings.refresh()
        snapshot = StatsStore.shared.snapshot()
        days = StatsStore.shared.recentDays(DashboardModel.chartDays)
    }
}

private extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }

    static let paper = Color(light: 0xF5F5F3, dark: 0x1F1E22)
    static let ink = Color(light: 0x1F1E22, dark: 0xF5F5F3)
    static let graphite = Color(light: 0x5F5E66, dark: 0xA9A8AF)
    static let line = Color.ink.opacity(0.12)
}

private struct DashboardView: View {
    @ObservedObject var model: DashboardModel

    private var s: StatsStore.Snapshot { model.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            switch model.page {
            case .dashboard:
                hero
                grid
                chart
            case .settings:
                SettingsView(model: model.settings)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 40)
        .padding(.bottom, 24)
        .frame(width: 560, height: 620)
        .background(Color.paper)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 40, height: 40)
            Text("talkflow")
                .font(.system(size: 28, weight: .regular, design: .serif))
            Spacer()
            pageSwitch
        }
        .foregroundColor(.ink)
    }

    private var pageSwitch: some View {
        HStack(spacing: 2) {
            ForEach(DashboardPage.allCases, id: \.self) { page in
                let selected = model.page == page
                Button {
                    model.page = page
                } label: {
                    Text(page.rawValue)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .foregroundColor(selected ? Color.paper : Color.ink)
                        .background(Capsule().fill(selected ? Color.ink : Color.clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .overlay(Capsule().stroke(Color.line, lineWidth: 1))
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Total words dictated")
                .font(.system(size: 13))
                .foregroundColor(.graphite)
            Text(s.totalWords.formatted())
                .font(.system(size: 68, weight: .regular, design: .serif))
                .monospacedDigit()
                .foregroundColor(.ink)
            Text("about \((s.totalWords / 500).formatted()) pages of typing, spoken instead")
                .font(.system(size: 12))
                .foregroundColor(.graphite)
        }
    }

    private var grid: some View {
        let tiles: [(String, [(value: String, unit: String)])] = [
            ("Words today", [(s.todayWords.formatted(), "")]),
            ("Speed", [("\(s.averageWPM)", "wpm")]),
            ("Day streak", [("\(s.dayStreak)", s.dayStreak == 1 ? "day" : "days")]),
            ("Time saved", timeSavedParts(minutes: s.estimatedMinutesSaved)),
            ("Dictations", [(s.totalSessions.formatted(), "")])
        ]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 3), spacing: 0) {
            ForEach(tiles, id: \.0) { tile in
                VStack(alignment: .leading, spacing: 6) {
                    Text(tile.0)
                        .font(.system(size: 12))
                        .foregroundColor(.graphite)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        ForEach(Array(tile.1.enumerated()), id: \.offset) { _, part in
                            Text(part.value)
                                .font(.system(size: 30, weight: .regular, design: .serif))
                                .monospacedDigit()
                            if !part.unit.isEmpty {
                                Text(part.unit)
                                    .font(.system(size: 12))
                                    .foregroundColor(.graphite)
                                    .padding(.trailing, 2)
                            }
                        }
                    }
                    .foregroundColor(.ink)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .overlay(Rectangle().stroke(Color.line, lineWidth: 0.5))
            }
        }
        .overlay(Rectangle().stroke(Color.line, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.line, lineWidth: 1))
    }

    private var chart: some View {
        let peak = max(model.days.map(\.words).max() ?? 0, 1)
        let columns = stride(from: 0, to: model.days.count, by: 7).map {
            Array(model.days[$0..<min($0 + 7, model.days.count)].enumerated())
        }
        return VStack(alignment: .leading, spacing: 10) {
            Text("Last \(DashboardModel.chartWeeks) weeks")
                .font(.system(size: 12))
                .foregroundColor(.graphite)
            HStack(alignment: .top, spacing: 4) {
                ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                    VStack(spacing: 4) {
                        ForEach(column, id: \.offset) { _, day in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.ink.opacity(shade(day.words, peak: peak)))
                                .frame(width: 15, height: 15)
                                .help("\(day.date.formatted(.dateTime.month().day())): \(day.words) words")
                        }
                    }
                }
            }
        }
    }

    /// Empty days stay faint; the rest step up in four shades relative to the busiest day.
    private func shade(_ words: Int, peak: Int) -> Double {
        guard words > 0 else { return 0.07 }
        let level = min(4, Int((Double(words) / Double(peak) * 4).rounded(.up)))
        return 0.15 + 0.85 * Double(level) / 4
    }
}

/// The Settings page's state. An ObservableObject rather than `@State`,
/// which is a macro in this SDK and needs Xcode's macro plugins to build.
final class SettingsModel: ObservableObject {
    @Published var typeWhileSpeaking = Preferences.typeWhileSpeaking {
        didSet { Preferences.typeWhileSpeaking = typeWhileSpeaking }
    }
    @Published var accurateFinalPass = Preferences.accurateFinalPass {
        didSet {
            Preferences.accurateFinalPass = accurateFinalPass
            if accurateFinalPass { FinalPassEngine.start() } else { FinalPassEngine.stop() }
        }
    }
    @Published var aiPolish = Preferences.aiPolish {
        didSet { Preferences.aiPolish = aiPolish }
    }
    @Published var learned = Preferences.learnedWords
    let polishAvailable = Polish.isAvailable

    func refresh() { learned = Preferences.learnedWords }

    func forget(_ word: String) {
        Vocabulary.forget(word)
        refresh()
    }
}

/// The Settings page: how dictation is written, and the words it has learned.
/// Every setting takes effect from the next hold.
private struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                toggle("Type while speaking",
                       detail: "Off: your words show above the pill and go in once, corrected, when you let go of Fn. On: they are typed into the field as you speak.",
                       isOn: $model.typeWhileSpeaking)
                toggle("Accurate final pass",
                       detail: FinalPassEngine.modelIsComplete
                           ? "Transcribes the final text with the large model. More accurate, about 0.7s slower."
                           : "Transcribes the final text with the large model (downloads 574 MB once). More accurate, about 0.7s slower.",
                       isOn: $model.accurateFinalPass)
                toggle("AI punctuation",
                       detail: model.polishAvailable
                           ? "Apple's on-device model fixes punctuation and line breaks. It never changes your words. Adds 0.5 to 2s."
                           : "Needs Apple Intelligence, which is not available on this Mac.",
                       isOn: $model.aiPolish)
                    .disabled(!model.polishAvailable)
                learnedWords
            }
            .padding(.vertical, 4)
        }
    }

    private func toggle(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .medium)).foregroundColor(.ink)
                Text(detail).font(.system(size: 12)).foregroundColor(.graphite).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }

    private var learnedWords: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Learned words").font(.system(size: 14, weight: .medium)).foregroundColor(.ink)
            Text(model.learned.isEmpty
                 ? "When you fix a misheard word right after dictating, talkflow learns the spelling. Nothing learned yet."
                 : "Spellings learned from your fixes. Click one to remove it.")
                .font(.system(size: 12)).foregroundColor(.graphite).fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(model.learned, id: \.self) { word in
                    Button {
                        model.forget(word)
                    } label: {
                        Text(word + "  x")
                            .font(.system(size: 12))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .foregroundColor(.ink)
                            .overlay(Capsule().stroke(Color.line, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
