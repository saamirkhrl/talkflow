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

final class DashboardModel: ObservableObject {
    @Published var snapshot = StatsStore.shared.snapshot()
    @Published var days = StatsStore.shared.recentDays(14)

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
            hero
            grid
            chart
            Text("Time saved compares your speaking time with typing the same words at 40 wpm. Stays on your Mac.")
                .font(.system(size: 11))
                .foregroundColor(.graphite)
        }
        .padding(.horizontal, 28)
        .padding(.top, 40)
        .padding(.bottom, 24)
        .frame(width: 560, height: 600)
        .background(Color.paper)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 26, height: 26)
            Text("Your dictation stats")
                .font(.system(size: 15, weight: .medium))
            Spacer()
            if s.dayStreak > 0 {
                Text("\(s.dayStreak) day streak")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .overlay(Capsule().stroke(Color.line, lineWidth: 1))
            }
        }
        .foregroundColor(.ink)
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
        let tiles: [(String, String, String)] = [
            ("Words today", s.todayWords.formatted(), ""),
            ("Speed", "\(s.averageWPM)", "wpm"),
            ("Day streak", "\(s.dayStreak)", s.dayStreak == 1 ? "day" : "days"),
            ("Time saved", "\(s.estimatedMinutesSaved)", "min"),
            ("Dictations", s.totalSessions.formatted(), "")
        ]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 3), spacing: 0) {
            ForEach(tiles, id: \.0) { tile in
                VStack(alignment: .leading, spacing: 6) {
                    Text(tile.0)
                        .font(.system(size: 12))
                        .foregroundColor(.graphite)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(tile.1)
                            .font(.system(size: 30, weight: .regular, design: .serif))
                            .monospacedDigit()
                        if !tile.2.isEmpty {
                            Text(tile.2)
                                .font(.system(size: 12))
                                .foregroundColor(.graphite)
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
