import AppKit
import SwiftUI

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
    /// The calendar day under the pointer (its place in `days`), for the tooltip.
    @Published var hovered: Int?
    /// The bar under the pointer in the last 30 days (0 is the oldest).
    @Published var hoveredBar: Int?

    /// From the first day of the calendar's first month up to today.
    static var chartDays: Int { ActivityGrid.dayCount(today: Date(), calendar: Calendar.current) }

    func refresh() {
        snapshot = StatsStore.shared.snapshot()
        days = StatsStore.shared.recentDays(DashboardModel.chartDays)
    }
}

/// Home: a greeting, the totals, today against a usual day, the last 30 days
/// and the year calendar.
struct HomePage: View {
    @ObservedObject var window: AppWindowModel
    @ObservedObject var model: DashboardModel
    @ObservedObject var updater: Updater
    var scrolls = true
    @Environment(\.colorScheme) private var colorScheme

    private var s: StatsStore.Snapshot { model.snapshot }

    var body: some View {
        AppPage(maxWidth: 880, scrolls: scrolls) {
            VStack(alignment: .leading, spacing: 28) {
                if showsBanner { updateBanner }
                header
                totals
                todayAndRecent
                yearCard
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
            Text(HomeInsights.greeting(hour: Calendar.current.component(.hour, from: Date())))
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
            pill(dot: Palette.brand, text: "Ready. Hold \(window.hotkeyName) anywhere to dictate.")
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
        let calendar = Calendar.current
        let line = HomeInsights.milestone(total: s.totalWords, day: HomeInsights.dayNumber(Date(), calendar: calendar))
        return VStack(alignment: .leading, spacing: 0) {
            Text("Total words dictated")
                .font(.system(size: 13))
                .foregroundColor(Palette.muted)
            Text(s.totalWords.formatted())
                .font(AppFont.hero)
                .monospacedDigit()
                .foregroundColor(Palette.ink)
            if let line {
                Text(line)
                    .font(AppFont.bodyMedium)
                    .foregroundColor(Palette.brand)
                    .padding(.top, 2)
            }
        }
        // A soft glow behind the number: a background, so it never changes the layout.
        .background(alignment: .leading) {
            RadialGradient(colors: [Palette.brand.opacity(colorScheme == .dark ? 0.22 : 0.14), .clear],
                           center: .center, startRadius: 0, endRadius: 110)
                // A 220 pt circle stretched to 420 x 220, so the glow fades out inside its frame instead of being cut by it.
                .frame(width: 220, height: 220)
                .scaleEffect(x: 420.0 / 220.0, y: 1)
                .offset(x: 0, y: -10)
                .blur(radius: 30)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var grid: some View {
        // One row, so no tile is left empty.
        let tiles: [(String, String, Color, [(value: String, unit: String)])] = [
            ("Today", "text.bubble.fill", Palette.brand, [(s.todayWords.formatted(), "words")]),
            ("Speed", "speedometer", Palette.brand, [("\(s.averageWPM)", "wpm")]),
            ("Streak", "flame.fill", Palette.coral, [("\(s.dayStreak)", s.dayStreak == 1 ? "day" : "days")]),
            ("Time saved", "clock.fill", Palette.brand, timeSavedParts(minutes: s.estimatedMinutesSaved))
        ]
        return HStack(spacing: 12) {
            ForEach(tiles, id: \.0) { tile in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: tile.1)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(tile.2)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(tile.2.opacity(0.16)))
                            .accessibilityHidden(true)
                        Text(tile.0)
                            .font(AppFont.caption)
                            .foregroundColor(Palette.muted)
                    }
                    // "16 h 48 min" when it fits the tile, else "16 h".
                    ViewThatFits(in: .horizontal) {
                        value(tile.3)
                        value(Array(tile.3.prefix(1)))
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

    // MARK: - Today and the last 30 days

    private var todayAndRecent: some View {
        ThirdSplit(spacing: 16) {
            todayCard
            recentCard
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) { content() }
            .padding(.horizontal, ActivityGrid.cardPadding)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: AppMetrics.cardRadius).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: AppMetrics.cardRadius).stroke(Palette.cardStroke, lineWidth: 1))
    }

    /// Today's words against a usual day: a ring, or just the count until
    /// there are enough days to know what usual is.
    private var todayCard: some View {
        let calendar = Calendar.current
        let usual = HomeInsights.usual(days: model.days, today: model.days.last?.date ?? Date(), calendar: calendar)
        let ratio = HomeInsights.todayRatio(today: s.todayWords, usual: usual)
        let words = s.todayWords.formatted()
        return card {
            Text("Today")
                .font(AppFont.bodyMedium)
                .foregroundColor(Palette.ink)
            if let ratio, let usual {
                let percent = Int((ratio * 100).rounded())
                VStack(spacing: 10) {
                    ZStack {
                        Circle().stroke(Palette.ink.opacity(0.08), lineWidth: 10)
                        if ratio > 0 {
                            Circle()
                                .trim(from: 0, to: min(ratio, 1))
                                .stroke(ratio >= 1 ? Palette.coral : Palette.brand,
                                        style: StrokeStyle(lineWidth: 10, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                        }
                        Text("\(percent)%")
                            .font(AppFont.stat)
                            .monospacedDigit()
                            .foregroundColor(Palette.ink)
                    }
                    .frame(width: 96, height: 96)
                    Text("Usual day: \(HomeInsights.grouped(usual)) words")
                        .font(AppFont.caption)
                        .foregroundColor(Palette.muted)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Today: \(words) words, \(percent) percent of a usual day.")
            } else {
                VStack(spacing: 10) {
                    Text(words)
                        .font(AppFont.stat)
                        .monospacedDigit()
                        .foregroundColor(Palette.ink)
                    Text("Your usual shows after a few days.")
                        .font(AppFont.caption)
                        .foregroundColor(Palette.muted)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Today: \(words) words.")
            }
        }
    }

    private var recentCard: some View {
        let recent = Array(model.days.suffix(30))
        return card {
            Text("Last 30 days")
                .font(AppFont.bodyMedium)
                .foregroundColor(Palette.ink)
            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { proxy in
                    bars(recent, width: proxy.size.width)
                }
                .frame(height: 120)
                HStack {
                    Text((recent.first?.date ?? Date()).formatted(.dateTime.month(.abbreviated).day()))
                    Spacer()
                    Text("Today")
                }
                .font(AppFont.small)
                .foregroundColor(Palette.muted)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Words dictated per day, last 30 days. Today: \(s.todayWords.formatted()) words.")
        }
    }

    /// One bar per day, oldest left, today coral. The gap between bars is part
    /// of the hover target so the pointer is never between bars.
    private func bars(_ days: [(date: Date, words: Int)], width: CGFloat) -> some View {
        let chartHeight: CGFloat = 120
        let count = max(days.count, 1)
        let barWidth = width / (CGFloat(count) + CGFloat(count - 1) * 0.3)
        let pitch = barWidth * 1.3
        let peak = max(days.map(\.words).max() ?? 0, 1)
        func barHeight(_ words: Int) -> CGFloat {
            words > 0 ? max(3, CGFloat(words) / CGFloat(peak) * chartHeight) : 3
        }
        return ZStack(alignment: .topLeading) {
            ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                let isToday = index == days.count - 1
                let color = day.words == 0 ? Palette.ink.opacity(0.08) : (isToday ? Palette.coral : Palette.brand)
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    TopRoundedBar(radius: 3)
                        .fill(color)
                        .frame(width: barWidth, height: barHeight(day.words))
                }
                .frame(width: index == days.count - 1 ? barWidth : pitch, height: chartHeight, alignment: .bottomLeading)
                .opacity(model.hoveredBar == nil || model.hoveredBar == index ? 1 : 0.55)
                .contentShape(Rectangle())
                .onHover { inside in
                    if inside { model.hoveredBar = index } else if model.hoveredBar == index { model.hoveredBar = nil }
                }
                .offset(x: CGFloat(index) * pitch)
            }
            if let index = model.hoveredBar, days.indices.contains(index) {
                let day = days[index]
                tooltip(wordsLine(day.date, day.words),
                        x: CGFloat(index) * pitch + barWidth / 2, y: chartHeight - barHeight(day.words) - 4, width: width)
            }
        }
        .frame(width: width, height: chartHeight, alignment: .topLeading)
    }

    // MARK: - This year

    private var yearCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("This year")
                .font(AppFont.bodyMedium)
                .foregroundColor(Palette.ink)
            ActivityGridFrame {
                GeometryReader { proxy in
                    calendarBody(width: proxy.size.width)
                }
            }
            legend
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Words dictated per day this year. Today: \(s.todayWords.formatted()) words.")
        .padding(.horizontal, ActivityGrid.cardPadding)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: AppMetrics.cardRadius).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: AppMetrics.cardRadius).stroke(Palette.cardStroke, lineWidth: 1))
    }

    private func levelFill(_ level: Int) -> Color {
        level == 0 ? Palette.ink.opacity(0.08) : Palette.brand.opacity(ActivityGrid.levelOpacity[level - 1])
    }

    /// The calendar's own five fills, so the key matches the tiles.
    private var legend: some View {
        HStack(spacing: 6) {
            Text("Less")
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 3)
                    .fill(levelFill(level))
                    .frame(width: 12, height: 12)
            }
            Text("More")
        }
        .font(AppFont.small)
        .foregroundColor(Palette.muted)
    }

    /// One drawn day: `index` is its place in `model.days`, the key `hovered` uses.
    private struct CalendarDay {
        let index: Int
        let x: CGFloat
        let y: CGFloat
        let date: Date
        let level: Int
    }

    private func monthName(_ month: Date, withYear: Bool) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.dateFormat = withYear ? "MMM yyyy" : "MMM"
        return formatter.string(from: month)
    }

    /// The 12 month blocks in rows of `perRow`, a month's days under its
    /// name, today outlined, and the day's count above the tile under the pointer.
    private func calendarBody(width: CGFloat) -> some View {
        let calendar = Calendar.current
        let todayDate = model.days.last?.date ?? Date()
        let today = calendar.startOfDay(for: todayDate)
        let months = ActivityGrid.months(today: todayDate, calendar: calendar)
        let first = months.first ?? today
        let (perRow, cell) = ActivityGrid.blocksPerRow(width: width)
        let pitch = cell * (1 + ActivityGrid.gapRatio)
        var words: [Date: Int] = [:]
        for day in model.days { words[calendar.startOfDay(for: day.date), default: 0] += day.words }

        let slotsByMonth = months.map { ActivityGrid.slots(month: $0, calendar: calendar) }
        let shown = slotsByMonth.flatMap { $0 }.compactMap { $0 }.filter { $0 <= today }
        let levels = ActivityGrid.levels(days: shown, words: words)
        var levelOf: [Date: Int] = [:]
        for (day, level) in zip(shown, levels) { levelOf[day] = level }

        var days: [CalendarDay] = []
        for (block, slots) in slotsByMonth.enumerated() {
            let originX = CGFloat(block % perRow) * (ActivityGrid.blockWidth(cell: cell) + ActivityGrid.blockGap)
            let originY = CGFloat(block / perRow) * (ActivityGrid.blockHeight(cell: cell) + ActivityGrid.blockGap)
            for (slot, date) in slots.enumerated() {
                guard let date, date <= today else { continue }
                days.append(CalendarDay(
                    index: calendar.dateComponents([.day], from: first, to: date).day ?? 0,
                    x: originX + CGFloat(slot % 7) * pitch,
                    y: originY + ActivityGrid.monthLabelHeight + CGFloat(slot / 7) * pitch,
                    date: date, level: levelOf[date] ?? 0))
            }
        }
        let radius = cell * ActivityGrid.radiusRatio
        return ZStack(alignment: .topLeading) {
            ForEach(Array(months.enumerated()), id: \.offset) { block, month in
                Text(monthName(month, withYear: block == 0 || calendar.component(.month, from: month) == 1))
                    .font(AppFont.caption)
                    .foregroundColor(Palette.muted)
                    .fixedSize()
                    .frame(height: ActivityGrid.monthLabelHeight, alignment: .topLeading)
                    .offset(x: CGFloat(block % perRow) * (ActivityGrid.blockWidth(cell: cell) + ActivityGrid.blockGap),
                            y: CGFloat(block / perRow) * (ActivityGrid.blockHeight(cell: cell) + ActivityGrid.blockGap))
            }
            ForEach(days, id: \.index) { day in
                let shape = RoundedRectangle(cornerRadius: radius)
                shape
                    .fill(levelFill(day.level))
                    .overlay(shape.stroke(Palette.coral, lineWidth: day.date == today ? 2 : 0))
                    .opacity(model.hovered == nil || model.hovered == day.index ? 1 : 0.55)
                    .frame(width: cell, height: cell)
                    .frame(width: pitch, height: pitch, alignment: .topLeading)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { model.hovered = day.index } else if model.hovered == day.index { model.hovered = nil }
                    }
                    .offset(x: day.x, y: day.y)
            }
            if let index = model.hovered, let day = days.first(where: { $0.index == index }) {
                tooltip(wordsLine(day.date, words[day.date] ?? 0), x: day.x + cell / 2, y: day.y - 4, width: width)
            }
        }
        .frame(width: width, height: ActivityGrid.height(width: width), alignment: .topLeading)
    }

    // MARK: - Tooltip

    private func wordsLine(_ date: Date, _ count: Int) -> String {
        "\(dayName(date)): \(count.formatted()) \(count == 1 ? "word" : "words")"
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
}

/// Takes the width it is offered and asks for the height the year calendar
/// needs at that width, so the blocks can size their tiles to fill the card.
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

/// Two cards side by side, the first a third of the row (less half the
/// spacing) and the second the rest, both as tall as the taller one.
private struct ThirdSplit: Layout {
    let spacing: CGFloat

    private func widths(_ total: CGFloat) -> (CGFloat, CGFloat) {
        let first = ((total - spacing) / 3).rounded(.down)
        return (first, total - spacing - first)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        var total = proposal.width ?? 600
        if !total.isFinite { total = 600 }
        let (a, b) = widths(total)
        let height = max(subviews[0].sizeThatFits(ProposedViewSize(width: a, height: nil)).height,
                         subviews[1].sizeThatFits(ProposedViewSize(width: b, height: nil)).height)
        return CGSize(width: total, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let (a, b) = widths(bounds.width)
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: a, height: bounds.height))
        subviews[1].place(at: CGPoint(x: bounds.minX + a + spacing, y: bounds.minY),
                          proposal: ProposedViewSize(width: b, height: bounds.height))
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
