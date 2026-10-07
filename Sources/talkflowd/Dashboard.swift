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
        Updater.shared.checkIfStale()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// `--dashboardshot`: draws the dashboard with the real stats, both chart
    /// styles, light and dark, a tooltip showing, to PNGs in the temporary
    /// directory - so the layout can be checked without a screen. Read-only;
    /// the remembered chart style is put back.
    @MainActor
    static func renderSnapshots() -> [URL] {
        _ = NSApplication.shared // the header reads NSApp's icon
        let saved = UserDefaults.standard.string(forKey: "dashboardChart")
        defer { UserDefaults.standard.set(saved, forKey: "dashboardChart") }
        let model = DashboardModel()
        var written: [URL] = []
        for style in ChartStyle.allCases {
            model.chartStyle = style
            model.hovered = style == .grid ? model.days.count - 1 : DashboardModel.chartWeeks - 1
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                    let renderer = ImageRenderer(content: DashboardView(model: model)
                        .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light))
                    renderer.scale = 2
                    guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
                    let url = URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("talkflow-dashboard-\(style == .grid ? "grid" : "bars")-\(name).png")
                    try? png.write(to: url)
                    written.append(url)
                }
            }
        }
        // The Settings page's content, unscrolled, at the page's width. Its
        // switches, pickers and fields are AppKit views and render as
        // placeholders; the text and spacing are what this checks.
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                let renderer = ImageRenderer(content: SettingsView(model: model.settings, scrolls: false)
                    .frame(width: 504)
                    .padding(28)
                    .background(Color.paper)
                    .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light))
                renderer.scale = 2
                guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
                let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("talkflow-settings-\(name).png")
                try? png.write(to: url)
                written.append(url)
            }
        }
        return written
    }
}

enum ChartStyle: String, CaseIterable {
    case grid = "Grid"
    case bars = "Weekly bars"
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
    /// Grid or bars, remembered between launches.
    @Published var chartStyle = ChartStyle(rawValue: UserDefaults.standard.string(forKey: "dashboardChart") ?? "") ?? .grid {
        didSet { UserDefaults.standard.set(chartStyle.rawValue, forKey: "dashboardChart") }
    }
    /// The day (grid) or week (bars) under the pointer, for the tooltip.
    @Published var hovered: Int?

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
            VStack(alignment: .trailing, spacing: 8) {
                UpdateButton(updater: .shared)
                pageSwitch
            }
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

    // MARK: - Activity chart

    /// One cell of the grid: a 14pt tile plus the 4pt gap, which is part of
    /// the hover target so the pointer is never between tiles.
    private let cell: CGFloat = 18
    private let tile: CGFloat = 14
    /// Room for the weekday (grid) or value (bars) labels on the left.
    private let axisWidth: CGFloat = 30
    /// Room for the month labels.
    private let monthHeight: CGFloat = 16

    private var weeks: [[(date: Date, words: Int)]] {
        stride(from: 0, to: model.days.count, by: 7).map { Array(model.days[$0..<min($0 + 7, model.days.count)]) }
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Last \(DashboardModel.chartWeeks) weeks")
                    .font(.system(size: 12))
                    .foregroundColor(.graphite)
                Spacer()
                Menu {
                    ForEach(ChartStyle.allCases, id: \.self) { style in
                        Button(style.rawValue) {
                            model.hovered = nil
                            model.chartStyle = style
                        }
                    }
                } label: {
                    // Styled like the Dashboard / Settings switch.
                    HStack(spacing: 4) {
                        Text(model.chartStyle.rawValue)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .overlay(Capsule().stroke(Color.line, lineWidth: 1))
                    .contentShape(Capsule())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            switch model.chartStyle {
            case .grid: contributionGrid
            case .bars: weeklyBars
            }
        }
    }

    /// GitHub-style: a column per week, a row per weekday, darker for more
    /// words. Month names along the top, weekdays down the side, today
    /// outlined, and the day's count above the tile under the pointer.
    private var contributionGrid: some View {
        let peak = max(model.days.map(\.words).max() ?? 0, 1)
        let weeks = self.weeks
        let width = axisWidth + CGFloat(weeks.count) * cell
        let height = monthHeight + 7 * cell
        return ZStack(alignment: .topLeading) {
            ForEach(monthLabels(weeks), id: \.column) { label in
                Text(label.name)
                    .font(.system(size: 10))
                    .foregroundColor(.graphite)
                    .offset(x: axisWidth + CGFloat(label.column) * cell + 2, y: 0)
            }
            ForEach(weekdayLabels, id: \.row) { label in
                Text(label.name)
                    .font(.system(size: 10))
                    .foregroundColor(.graphite)
                    .offset(x: 0, y: monthHeight + CGFloat(label.row) * cell + 2)
            }
            ForEach(Array(model.days.enumerated()), id: \.offset) { index, day in
                let isToday = Calendar.current.isDateInToday(day.date)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.ink.opacity(shade(day.words, peak: peak)))
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.ink.opacity(isToday ? 1 : 0), lineWidth: 1.5))
                    .opacity(model.hovered == nil || model.hovered == index ? 1 : 0.55)
                    .frame(width: tile, height: tile)
                    .frame(width: cell, height: cell)
                    .contentShape(Rectangle())
                    .onHover { inside in hover(index, inside) }
                    .offset(x: axisWidth + CGFloat(index / 7) * cell, y: monthHeight + CGFloat(index % 7) * cell)
            }
            if let index = model.hovered, model.days.indices.contains(index) {
                let day = model.days[index]
                tooltip("\(dayName(day.date)): \(day.words.formatted()) \(day.words == 1 ? "word" : "words")",
                        x: axisWidth + CGFloat(index / 7) * cell + cell / 2, y: monthHeight + CGFloat(index % 7) * cell - 4,
                        width: width)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }

    /// One bar per week, on the same 26 weeks: easier to compare totals than
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
            Rectangle().fill(Color.line).frame(width: width - axisWidth, height: 0.5).offset(x: axisWidth, y: plotTop)
            Rectangle().fill(Color.line).frame(width: width - axisWidth, height: 1).offset(x: axisWidth, y: baseline)
            Text(compact(peak)).font(.system(size: 10)).foregroundColor(.graphite).offset(x: 0, y: plotTop - 6)
            Text("0").font(.system(size: 10)).foregroundColor(.graphite).offset(x: 0, y: baseline - 7)
            ForEach(Array(totals.enumerated()), id: \.offset) { index, total in
                let barHeight = total == 0 ? 0 : max(2, plotHeight * CGFloat(total) / CGFloat(peak))
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    TopRoundedBar(radius: 3)
                        .fill(Color.ink.opacity(model.hovered == nil || model.hovered == index ? 0.8 : 0.3))
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
                    .foregroundColor(.graphite)
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
            .foregroundColor(.paper)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.ink))
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

    /// Empty days stay faint; the rest step up in four shades relative to the busiest day.
    private func shade(_ words: Int, peak: Int) -> Double {
        guard words > 0 else { return 0.07 }
        let level = min(4, Int((Double(words) / Double(peak) * 4).rounded(.up)))
        return 0.15 + 0.85 * Double(level) / 4
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

    @Published var writingStyle = Preferences.writingStyle {
        didSet { if Preferences.writingStyle != writingStyle { Preferences.writingStyle = writingStyle } }
    }
    @Published var useOpenAI = Preferences.useOpenAITranscription {
        didSet { Preferences.useOpenAITranscription = useOpenAI }
    }
    @Published var useClaude = Preferences.useClaudePunctuation {
        didSet { Preferences.useClaudePunctuation = useClaude }
    }
    @Published var claudeModel = Preferences.claudeModel {
        didSet { Preferences.claudeModel = claudeModel }
    }
    @Published var hasOpenAIKey = APIKeys.hasKey(.openAI)
    @Published var hasAnthropicKey = APIKeys.hasKey(.anthropic)
    @Published var openAIDraft = ""
    @Published var anthropicDraft = ""
    /// What happened the last time a key was saved, per provider: nil while
    /// nothing has, otherwise (is it an error, message).
    @Published var keyStatus: [String: (error: Bool, text: String)] = [:]
    @Published var checking: Set<String> = []
    /// The step the uninstaller is on, once the user has confirmed it.
    @Published var uninstallStep: String?

    private var styleObserver: NSObjectProtocol?

    init() {
        // The menu bar menu can change the style while this page is open.
        styleObserver = NotificationCenter.default.addObserver(forName: .writingStyleChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.writingStyle != Preferences.writingStyle else { return }
            self.writingStyle = Preferences.writingStyle
        }
    }

    func refresh() {
        learned = Preferences.learnedWords
        writingStyle = Preferences.writingStyle
    }

    /// The models this Mac will actually use for the next dictation, given
    /// the settings and what is installed and answering.
    var modelsInUse: [(role: String, model: String)] {
        let local = FinalPassEngine.isReady && accurateFinalPass ? "Whisper large-v3-turbo, on this Mac" : "Whisper small.en, on this Mac"
        let final = useOpenAI && hasOpenAIKey ? "OpenAI \(CloudTranscriber.model), your key" : local
        let punctuation: String
        if useClaude && hasAnthropicKey { punctuation = "\(claudeModel.title), your key" }
        else if aiPolish && polishAvailable { punctuation = "Apple on-device model" }
        else { punctuation = "Built-in rules only" }
        return [("Live caption", "Whisper small.en, on this Mac"), ("Final text", final), ("Punctuation", punctuation)]
    }

    /// Checks the key with the provider, and keeps it only if it works.
    func saveKey(_ provider: APIKeys.Provider) {
        let draft = (provider == .openAI ? openAIDraft : anthropicDraft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else { return }
        checking.insert(provider.rawValue)
        keyStatus[provider.rawValue] = nil
        let validate = provider == .openAI ? CloudTranscriber.validate : ClaudePolish.validate
        validate(draft) { error in
            DispatchQueue.main.async {
                self.checking.remove(provider.rawValue)
                if let error {
                    self.keyStatus[provider.rawValue] = (true, error)
                    return
                }
                guard APIKeys.save(draft, for: provider) else {
                    self.keyStatus[provider.rawValue] = (true, "Could not save the key to the Keychain")
                    return
                }
                self.keyStatus[provider.rawValue] = (false, "Key works and is saved in your Keychain.")
                if provider == .openAI { self.openAIDraft = ""; self.hasOpenAIKey = true; self.useOpenAI = true }
                else { self.anthropicDraft = ""; self.hasAnthropicKey = true; self.useClaude = true }
            }
        }
    }

    func removeKey(_ provider: APIKeys.Provider) {
        APIKeys.remove(provider)
        keyStatus[provider.rawValue] = (false, "Key removed.")
        if provider == .openAI { hasOpenAIKey = false; useOpenAI = false }
        else { hasAnthropicKey = false; useClaude = false }
    }

    func forget(_ word: String) {
        Vocabulary.forget(word)
        refresh()
    }

    func uninstall() {
        Uninstaller.confirmAndRun { [weak self] step in self?.uninstallStep = step }
    }
}

/// The Settings page: how dictation is written, and the words it has learned.
/// Every setting takes effect from the next hold.
private struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    /// Off only for `--dashboardshot`: ImageRenderer draws a ScrollView's
    /// contents blank.
    var scrolls = true

    var body: some View {
        if scrolls { ScrollView { content } } else { content }
    }

    private var content: some View {
            VStack(alignment: .leading, spacing: 18) {
                styleChoice
                modelsInUse
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
                apiKeys
                learnedWords
                yourData
                uninstall
            }
            .padding(.vertical, 4)
    }

    private var yourData: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your data").font(.system(size: 14, weight: .medium)).foregroundColor(.ink)
                Text("Your stats, settings and learned words are kept in \(UserData.directory.path). Uninstalling keeps this folder, so installing again picks up where you left off.")
                    .font(.system(size: 12)).foregroundColor(.graphite).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([UserData.directory]) }
        }
    }

    private var uninstall: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Uninstall talkflow").font(.system(size: 14, weight: .medium)).foregroundColor(.ink)
                Text(model.uninstallStep ?? "Removes the app, the speech engine and models, saved API keys, logs and permissions. Keeps your data folder.")
                    .font(.system(size: 12)).foregroundColor(.graphite).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(model.uninstallStep == nil ? "Uninstall..." : "Uninstalling...") { model.uninstall() }
                .disabled(model.uninstallStep != nil)
        }
        .padding(.top, 6)
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

    private var styleChoice: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Writing style").font(.system(size: 14, weight: .medium)).foregroundColor(.ink)
                Text(model.writingStyle.detail + " Also in the menu bar menu.")
                    .font(.system(size: 12)).foregroundColor(.graphite).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Picker("", selection: $model.writingStyle) {
                ForEach(WritingStyle.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    private var modelsInUse: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Models in use").font(.system(size: 14, weight: .medium)).foregroundColor(.ink)
            ForEach(model.modelsInUse, id: \.role) { row in
                HStack(spacing: 8) {
                    Text(row.role).font(.system(size: 12)).foregroundColor(.graphite).frame(width: 90, alignment: .leading)
                    Text(row.model).font(.system(size: 12, weight: .medium)).foregroundColor(.ink)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.line, lineWidth: 1))
    }

    private var apiKeys: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your own API keys").font(.system(size: 14, weight: .medium)).foregroundColor(.ink)
                Text("Optional. Kept in your Keychain. With a key, the final text is sent to that provider and billed to you. If a request fails, the error shows above the pill and this Mac takes over.")
                    .font(.system(size: 12)).foregroundColor(.graphite).fixedSize(horizontal: false, vertical: true)
            }
            keyRow(.openAI, placeholder: "sk-...", draft: $model.openAIDraft, saved: model.hasOpenAIKey)
            toggle("Use my OpenAI key for transcription",
                   detail: "\(CloudTranscriber.model) transcribes the final text. The live caption stays on this Mac.",
                   isOn: $model.useOpenAI)
                .disabled(!model.hasOpenAIKey)
            keyRow(.anthropic, placeholder: "sk-ant-...", draft: $model.anthropicDraft, saved: model.hasAnthropicKey)
            toggle("Use my Anthropic key for punctuation",
                   detail: "Claude fixes punctuation and line breaks in place of Apple's model, and never changes your words. Anthropic has no speech-to-text, so transcription stays with whisper or OpenAI.",
                   isOn: $model.useClaude)
                .disabled(!model.hasAnthropicKey)
            if model.useClaude && model.hasAnthropicKey {
                HStack {
                    Text("Claude model").font(.system(size: 12)).foregroundColor(.graphite)
                    Spacer()
                    Picker("", selection: $model.claudeModel) {
                        ForEach(ClaudePolish.Model.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
    }

    private func keyRow(_ provider: APIKeys.Provider, placeholder: String, draft: Binding<String>, saved: Bool) -> some View {
        let busy = model.checking.contains(provider.rawValue)
        let status = model.keyStatus[provider.rawValue]
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(provider.name).font(.system(size: 12, weight: .medium)).foregroundColor(.ink).frame(width: 70, alignment: .leading)
                SecureField(saved ? "Saved - paste a new key to replace it" : placeholder, text: draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit { model.saveKey(provider) }
                Button(busy ? "Checking..." : "Use key") { model.saveKey(provider) }
                    .disabled(busy || draft.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
                if saved {
                    Button("Remove") { model.removeKey(provider) }
                }
            }
            if let status {
                Text(status.text)
                    .font(.system(size: 11))
                    .foregroundColor(status.error ? .red : .graphite)
                    .padding(.leading, 78)
            }
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

/// Above the page switch: the version, and whether a newer one is on GitHub.
private struct UpdateButton: View {
    @ObservedObject var updater: Updater

    var body: some View {
        HStack(spacing: 6) {
            switch updater.state {
            case .idle:
                version
                link("Check for updates") { updater.check() }
            case .checking:
                version
                Text("Checking...").foregroundColor(.graphite)
            case .upToDate:
                version
                link("Up to date") { updater.check() }
            case .available(let release):
                Button {
                    updater.install()
                } label: {
                    Text("Update to \(release.version)")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .foregroundColor(.paper)
                        .background(Capsule().fill(Color.ink))
                }
                .buttonStyle(.plain)
                .help(Updater.keepsPermissions
                      ? "Downloads \(release.version), installs it and restarts talkflow. Permissions carry over."
                      : "Downloads \(release.version), installs it and restarts talkflow. macOS will ask for the microphone and Accessibility permissions again.")
            case .downloading:
                Text("Downloading update...").foregroundColor(.graphite)
            case .installing:
                Text("Installing...").foregroundColor(.graphite)
            case .failed(let message):
                Text(message).foregroundColor(.red).lineLimit(1).truncationMode(.tail).frame(maxWidth: 200, alignment: .trailing).help(message)
                link("Retry") { updater.check() }
            }
        }
        .font(.system(size: 11))
    }

    private var version: some View {
        Text("v\(Updater.currentVersion)").foregroundColor(.graphite).monospacedDigit()
    }

    private func link(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).underline().foregroundColor(.ink)
        }
        .buttonStyle(.plain)
    }
}
