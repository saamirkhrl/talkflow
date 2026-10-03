import AppKit
import SwiftUI

/// Stats window styled like the site's dashboard mock: paper and ink, serif
/// numerals, hairline tiles. All from StatsStore (local JSON, never leaves the Mac).
final class DashboardController: NSWindowController {
    private let model = DashboardModel()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
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
    @Published var days = StatsStore.shared.recentDays(14)
    @Published var page: DashboardPage = .dashboard

    func refresh() {
        snapshot = StatsStore.shared.snapshot()
        days = StatsStore.shared.recentDays(14)
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
                Text("Time saved compares your speaking time with typing the same words at 40 wpm. Stays on your Mac.")
                    .font(.system(size: 11))
                    .foregroundColor(.graphite)
            case .settings:
                Spacer()
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 40)
        .padding(.bottom, 24)
        .frame(width: 560, height: 600)
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
        return VStack(alignment: .leading, spacing: 10) {
            Text("Last 14 days")
                .font(.system(size: 12))
                .foregroundColor(.graphite)
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(Array(model.days.enumerated()), id: \.offset) { index, day in
                    let isToday = index == model.days.count - 1
                    RoundedRectangle(cornerRadius: 3)
                        .fill(isToday ? Color.ink : Color.ink.opacity(0.18))
                        .frame(height: max(4, 70 * CGFloat(day.words) / CGFloat(peak)))
                        .frame(maxWidth: .infinity)
                        .help("\(day.date.formatted(.dateTime.month().day())): \(day.words) words")
                }
            }
            .frame(height: 70, alignment: .bottom)
        }
    }
}
