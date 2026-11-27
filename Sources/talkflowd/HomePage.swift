import AppKit
import SwiftUI

enum ChartStyle: String, CaseIterable {
    case grid = "Grid"
    case bars = "Weekly bars"
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
    /// Grid or bars, remembered between launches.
    @Published var chartStyle = ChartStyle(rawValue: Preferences.defaults.string(forKey: "dashboardChart") ?? "") ?? .grid {
        didSet { Preferences.defaults.set(chartStyle.rawValue, forKey: "dashboardChart") }
    }
    /// The day (grid) or week (bars) under the pointer, for the tooltip.
    @Published var hovered: Int?

    /// The weekly bars keep their half year; the grid shows a year.
    static let barWeeks = 26

    /// Enough days to fill the grid's year of columns, the last one running up
    /// to today, so the first day always lands on the first row of its column.
    static var chartDays: Int { days(weeks: ActivityGrid.weeks) }

    /// The days the weekly bars cover (the last `barWeeks` columns).
    static var barDays: Int { days(weeks: barWeeks) }

    private static func days(weeks: Int) -> Int {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: Date())
        let sinceWeekStart = (weekday - calendar.firstWeekday + 7) % 7
        return (weeks - 1) * 7 + sinceWeekStart + 1
    }

    func refresh() {
        snapshot = StatsStore.shared.snapshot()
        days = StatsStore.shared.recentDays(DashboardModel.chartDays)
    }
}

/// Home: the totals and the activity chart. The chart is moved verbatim from
/// the old dashboard.
struct HomePage: View {
    @ObservedObject var window: AppWindowModel
    @ObservedObject var model: DashboardModel
    @ObservedObject var updater: Updater
    var scrolls = true

    private var s: StatsStore.Snapshot { model.snapshot }

    var body: some View {
        AppPage(maxWidth: 880, scrolls: scrolls) {
            VStack(alignment: .leading, spacing: 28) {
                if showsBanner { updateBanner }
                header
                totals
                activity
            }
        }
    }

    // MARK: - Update banner

    /// The snapshots set `updateOverride` to draw states the real updater
    /// cannot be put in.
    private var updateState: Updater.State { window.updateOverride ?? updater.state }

    private var showsBanner: Bool {
        switch updateState {
        case .available, .downloading, .installing: return true
        default: return false
        }
    }

    /// Failures are shown in Settings > About only, so the banner never
    /// turns into an error strip.
    private var updateBanner: some View {
        let state = updateState
        return HStack(spacing: 16) {
            Group {
                if case .available(let r) = state {
                    Text("talkflow \(r.version) is available")
                        .font(AppFont.bodyMedium)
                        .foregroundColor(Palette.ink)
                } else {
                    Text("Updating talkflow")
                        .font(AppFont.bodyMedium)
                        .foregroundColor(Palette.ink)
                }
            }
            Spacer()
            switch state {
            case .available(let r):
                UpdateInstallButton(release: r, enabled: window.updatesEnabled && window.updateOverride == nil) {
                    updater.install()
                }
            case .downloading:
                Text("Downloading update...")
                    .font(AppFont.control)
                    .foregroundColor(Palette.muted)
            case .installing:
                Text("Installing...")
                    .font(AppFont.control)
                    .foregroundColor(Palette.muted)
            default:
                EmptyView()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: AppMetrics.cardRadius).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: AppMetrics.cardRadius).stroke(Palette.cardStroke, lineWidth: 1))
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Home")
                .font(AppFont.pageTitle)
                .foregroundColor(Palette.ink)
            Spacer()
            statusPill
        }
    }

    /// Ready is plain text; when setup is unfinished the same pill becomes
    /// the way back into setup.
    @ViewBuilder private var statusPill: some View {
        if window.setupNeeded {
            Button {
                window.openSetup?()
            } label: {
                pill(dot: Palette.warn, text: "Setup isn't finished. Finish setup...")
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .disabled(window.openSetup == nil)
            .accessibilityLabel("Finish setup")
            .help("Opens setup.")
        } else {
            pill(dot: Palette.ink, text: "Ready. Hold \(window.hotkeyName) anywhere to dictate.")
        }
    }

    private func pill(dot: Color, text: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(dot).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(text)
                .font(AppFont.control)
                .foregroundColor(Palette.muted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .overlay(Capsule().strokeBorder(Palette.ink.opacity(0.14), lineWidth: 1))
        .contentShape(Capsule())
        // Never squeezed by the title beside it, which would clip the outline.
        .fixedSize()
    }

    // MARK: - Totals

    private var totals: some View {
        VStack(alignment: .leading, spacing: 18) {
            hero
            grid
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Total words dictated")
                .font(.system(size: 13))
                .foregroundColor(Palette.muted)
            Text(s.totalWords.formatted())
                .font(AppFont.hero)
                .monospacedDigit()
                .foregroundColor(Palette.ink)
        }
    }

    private var grid: some View {
        // One row, so no tile is left empty.
        let tiles: [(String, [(value: String, unit: String)])] = [
            ("Today", [(s.todayWords.formatted(), "words")]),
            ("Speed", [("\(s.averageWPM)", "wpm")]),
            ("Streak", [("\(s.dayStreak)", s.dayStreak == 1 ? "day" : "days")]),
            ("Time saved", timeSavedParts(minutes: s.estimatedMinutesSaved))
        ]
        return HStack(spacing: 12) {
            ForEach(tiles, id: \.0) { tile in
                VStack(alignment: .leading, spacing: 6) {
                    Text(tile.0)
                        .font(AppFont.caption)
                        .foregroundColor(Palette.muted)
                    // "16 h 48 min" when it fits the tile, else "16 h".
                    ViewThatFits(in: .horizontal) {
                        value(tile.1)
                        value(Array(tile.1.prefix(1)))
                    }
                    .foregroundColor(Palette.ink)
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .background(RoundedRectangle(cornerRadius: AppMetrics.cardRadius).fill(Palette.card))
                .overlay(RoundedRectangle(cornerRadius: AppMetrics.cardRadius).stroke(Palette.cardStroke, lineWidth: 1))
            }
        }
    }

    private func value(_ parts: [(value: String, unit: String)]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                Text(part.value)
                    .font(AppFont.stat)
                    .monospacedDigit()
                if !part.unit.isEmpty {
                    Text(part.unit)
                        .font(.system(size: 12))
                        .foregroundColor(Palette.muted)
                        .padding(.trailing, 2)
                }
            }
        }
        .fixedSize()
    }

    // MARK: - Activity chart

    /// One column of the weekly bars: a bar plus its gap, which is part of the
    /// hover target so the pointer is never between bars.
    private let cell: CGFloat = 18
    /// Room for the value labels on the left of the bars.
    private let axisWidth: CGFloat = 30
    /// Room for the month labels.
    private let monthHeight: CGFloat = 16

    /// The bars' weeks: the last `barWeeks` columns of the year.
    private var weeks: [[(date: Date, words: Int)]] {
        let all = stride(from: 0, to: model.days.count, by: 7).map { Array(model.days[$0..<min($0 + 7, model.days.count)]) }
        return Array(all.suffix(DashboardModel.barWeeks))
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text("Activity")
                    .font(AppFont.bodyMedium)
                    .foregroundColor(Palette.ink)
                Spacer()
                Menu {
                    ForEach(ChartStyle.allCases, id: \.self) { style in
                        Button(style.rawValue) {
                            model.hovered = nil
                            model.chartStyle = style
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(model.chartStyle.rawValue)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Palette.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .overlay(Capsule().strokeBorder(Palette.line, lineWidth: 1))
                    .contentShape(Capsule())
                }
                // The borderless menu style re-lays the label (chevron first, no capsule).
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            Group {
                switch model.chartStyle {
                case .grid: contributionGrid
                case .bars: weeklyBars
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Words dictated per day over the last \(model.chartStyle == .grid ? "year" : "\(DashboardModel.barWeeks) weeks"). Today: \(model.snapshot.todayWords.formatted()) words.")
            if model.chartStyle == .grid { legend }
        }
        .padding(.horizontal, ActivityGrid.cardPadding)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: AppMetrics.cardRadius).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: AppMetrics.cardRadius).stroke(Palette.cardStroke, lineWidth: 1))
    }

    /// The grid's own five shades, so the key matches the tiles.
    private var legend: some View {
        HStack(spacing: 6) {
            Text("Less")
            ForEach(ActivityGrid.levelOpacity, id: \.self) { opacity in
                RoundedRectangle(cornerRadius: 3)
                    .fill(Palette.ink.opacity(opacity))
                    .frame(width: 12, height: 12)
            }
            Text("More")
        }
        .font(AppFont.small)
        .foregroundColor(Palette.muted)
        .accessibilityHidden(true)
    }

    /// GitHub-style: a year of weeks, a column per week, a row per weekday,
    /// darker for more words, sized to fill the card. Month names along the
    /// top, weekdays down the side, today outlined, and the day's count above
    /// the tile under the pointer.
    private var contributionGrid: some View {
        ActivityGridFrame {
            GeometryReader { proxy in
                gridBody(width: proxy.size.width)
            }
        }
    }

    /// One drawn day: `index` is its place in `model.days` (column * 7 + row),
    /// the key `hovered` uses.
    private struct GridDay {
        let index: Int
        let column: Int
        let row: Int
        let date: Date
        let level: Int
    }

    private func gridDays(_ layout: ActivityGrid.Layout, words: [Date: Int]) -> [GridDay] {
        let levels = ActivityGrid.levels(columns: layout.columns, words: words)
        var out: [GridDay] = []
        for (column, days) in layout.columns.enumerated() {
            for (row, date) in days.enumerated() {
                out.append(GridDay(index: column * 7 + row, column: column, row: row, date: date, level: levels[column][row]))
            }
        }
        return out
    }

    private func gridBody(width: CGFloat) -> some View {
        let calendar = Calendar.current
        let today = model.days.last?.date ?? Date()
        let layout = ActivityGrid.layout(today: today, calendar: calendar, width: width)
        var words: [Date: Int] = [:]
        for day in model.days { words[calendar.startOfDay(for: day.date), default: 0] += day.words }
        let days = gridDays(layout, words: words)
        return ZStack(alignment: .topLeading) {
            ForEach(layout.months, id: \.column) { label in
                Text(label.name)
                    .font(.system(size: 10))
                    .foregroundColor(Palette.muted)
                    .fixedSize()
                    .offset(x: label.x, y: 0)
            }
            ForEach(weekdayLabels, id: \.row) { label in
                Text(label.name)
                    .font(.system(size: 10))
                    .foregroundColor(Palette.muted)
                    .fixedSize()
                    .frame(height: layout.cell)
                    .offset(x: layout.inset, y: layout.y(row: label.row))
            }
            ForEach(days, id: \.index) { day in
                gridTile(day, layout: layout)
            }
            if let index = model.hovered, let day = days.first(where: { $0.index == index }) {
                let count = words[day.date] ?? 0
                tooltip("\(dayName(day.date)): \(count.formatted()) \(count == 1 ? "word" : "words")",
                        x: layout.x(column: day.column) + layout.cell / 2, y: layout.y(row: day.row) - 4,
                        width: width)
            }
        }
        .frame(width: width, height: layout.height, alignment: .topLeading)
    }

    private func gridTile(_ day: GridDay, layout: ActivityGrid.Layout) -> some View {
        let isToday = Calendar.current.isDateInToday(day.date)
        let shape = RoundedRectangle(cornerRadius: layout.radius)
        return shape
            .fill(Palette.ink.opacity(ActivityGrid.levelOpacity[day.level]))
            .overlay(shape.stroke(Palette.ink.opacity(isToday ? 1 : 0), lineWidth: 1.5))
            .opacity(model.hovered == nil || model.hovered == day.index ? 1 : 0.55)
            .frame(width: layout.cell, height: layout.cell)
            .frame(width: layout.pitch, height: layout.pitch, alignment: .topLeading)
            .contentShape(Rectangle())
            .onHover { inside in hover(day.index, inside) }
            .offset(x: layout.x(column: day.column), y: layout.y(row: day.row))
    }

    /// One bar per week, on the last 26 weeks: easier to compare totals than
    /// shades. One series, so no legend; the axis shows 0 and the peak.
    private var weeklyBars: some View {
        let weeks = self.weeks
        let totals = weeks.map { $0.reduce(0) { $0 + $1.words } }
        let peak = max(totals.max() ?? 0, 1)
        let width = axisWidth + CGFloat(weeks.count) * cell
        let plotTop: CGFloat = 8, plotHeight = 7 * cell - plotTop
        let baseline = plotTop + plotHeight
        return ZStack(alignment: .topLeading) {
            // Recessive axis: a hairline at the peak and the baseline.
            Rectangle().fill(Palette.line).frame(width: width - axisWidth, height: 0.5).offset(x: axisWidth, y: plotTop)
            Rectangle().fill(Palette.line).frame(width: width - axisWidth, height: 1).offset(x: axisWidth, y: baseline)
            Text(compact(peak)).font(.system(size: 10)).foregroundColor(Palette.muted).offset(x: 0, y: plotTop - 6)
            Text("0").font(.system(size: 10)).foregroundColor(Palette.muted).offset(x: 0, y: baseline - 7)
            ForEach(Array(totals.enumerated()), id: \.offset) { index, total in
                let barHeight = total == 0 ? 0 : max(2, plotHeight * CGFloat(total) / CGFloat(peak))
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    TopRoundedBar(radius: 3)
                        .fill(Palette.ink.opacity(model.hovered == nil || model.hovered == index ? 0.8 : 0.3))
                        .frame(width: cell - 4, height: barHeight)
                }
                .frame(width: cell, height: plotHeight)
                .contentShape(Rectangle())
                .onHover { inside in hover(index, inside) }
                .offset(x: axisWidth + CGFloat(index) * cell, y: plotTop)
            }
            ForEach(monthLabels(weeks), id: \.column) { label in
                Text(label.name)
                    .font(.system(size: 10))
                    .foregroundColor(Palette.muted)
                    .offset(x: axisWidth + CGFloat(label.column) * cell, y: baseline + 3)
            }
            if let index = model.hovered, weeks.indices.contains(index), let first = weeks[index].first, let last = weeks[index].last {
                let barHeight = totals[index] == 0 ? 0 : max(2, plotHeight * CGFloat(totals[index]) / CGFloat(peak))
                tooltip("\(first.date.formatted(.dateTime.month(.abbreviated).day())) - \(last.date.formatted(.dateTime.month(.abbreviated).day())): \(totals[index].formatted()) words",
                        x: axisWidth + CGFloat(index) * cell + cell / 2, y: baseline - barHeight - 4, width: width)
            }
        }
        .frame(width: width, height: monthHeight + 7 * cell, alignment: .topLeading)
    }

    private func hover(_ index: Int, _ inside: Bool) {
        if inside { model.hovered = index } else if model.hovered == index { model.hovered = nil }
    }

    /// A dark label centred above (x, y), kept inside the chart's width.
    private func tooltip(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat) -> some View {
        let estimated = CGFloat(text.count) * 6.2 + 16
        let centre = min(max(x, estimated / 2), width - estimated / 2)
        return Text(text)
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .foregroundColor(Palette.window)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Palette.ink))
            .position(x: centre, y: max(10, y - 10))
            .allowsHitTesting(false)
    }

    /// "Today, Oct 3", "Yesterday, Oct 2", else "Thu, Oct 1".
    private func dayName(_ date: Date) -> String {
        let calendar = Calendar.current
        let monthDay = date.formatted(.dateTime.month(.abbreviated).day())
        if calendar.isDateInToday(date) { return "Today, \(monthDay)" }
        if calendar.isDateInYesterday(date) { return "Yesterday, \(monthDay)" }
        return date.formatted(.dateTime.weekday(.abbreviated)) + ", " + monthDay
    }

    /// The short month name over the first week that starts in it, skipped
    /// when the next one is too close to fit (the partial first month).
    private func monthLabels(_ weeks: [[(date: Date, words: Int)]]) -> [(column: Int, name: String)] {
        let calendar = Calendar.current
        var labels: [(column: Int, name: String)] = []
        var previousMonth = -1
        for (column, week) in weeks.enumerated() {
            guard let first = week.first else { continue }
            let month = calendar.component(.month, from: first.date)
            if month != previousMonth {
                labels.append((column, first.date.formatted(.dateTime.month(.abbreviated))))
                previousMonth = month
            }
        }
        if labels.count > 1, labels[1].column - labels[0].column < 3 { labels.removeFirst() }
        return labels
    }

    /// Mon, Wed and Fri, on whichever rows they fall for this locale's first
    /// weekday - as GitHub labels it.
    private var weekdayLabels: [(row: Int, name: String)] {
        let calendar = Calendar.current
        let symbols = calendar.shortWeekdaySymbols // Sunday first
        return (0..<7).compactMap { row in
            let weekday = (calendar.firstWeekday - 1 + row) % 7 // 0 = Sunday
            return [1, 3, 5].contains(weekday) ? (row, symbols[weekday]) : nil
        }
    }

    /// 4512 -> "4.5k".
    private func compact(_ value: Int) -> String {
        value >= 1000 ? String(format: "%.1fk", Double(value) / 1000) : String(value)
    }
}

/// Takes the width it is offered and asks for the height the activity grid
/// needs at that width, so the grid can size its tiles to fill the card.
private struct ActivityGridFrame: Layout {
    /// Used only when no width is offered (an ideal-size pass).
    private let fallbackWidth: CGFloat = 640

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        var width = proposal.width ?? fallbackWidth
        if !width.isFinite { width = fallbackWidth }
        return CGSize(width: width, height: ActivityGrid.height(width: width))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        }
    }
}

/// A bar rounded only at its data end, square on the baseline it stands on.
private struct TopRoundedBar: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.width / 2, rect.height)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
