import Foundation

/// The Home page's activity grid, as GitHub draws contributions: a year of
/// weeks, a column per week and a row per weekday, oldest on the left and the
/// current week (with today) on the right. Pure values, so --streamtest can
/// check it without drawing anything.
enum ActivityGrid {
    /// A year: the current week plus the 52 before it.
    static let weeks = 53
    /// Room for the Mon / Wed / Fri labels on the left.
    static let axisWidth: CGFloat = 30
    /// Room for the month labels above the grid.
    static let monthHeight: CGFloat = 16
    static let minCell: CGFloat = 8
    static let maxCell: CGFloat = 16
    /// The gap between tiles, as a share of the tile.
    static let gapRatio: CGFloat = 0.18
    /// The corner radius, as a share of the tile.
    static let radiusRatio: CGFloat = 0.2
    /// The activity card's side padding, so the minimum window width can be checked.
    static let cardPadding: CGFloat = 20
    /// Space kept between two month labels; closer than this, the later one is skipped.
    static let labelGap: CGFloat = 4

    /// Ink opacity per level: empty, then four steps up to full ink.
    static let levelOpacity: [Double] = [0.12, 0.30, 0.50, 0.72, 1.0]

    struct MonthLabel: Equatable {
        let column: Int
        let x: CGFloat
        let name: String
    }

    struct Layout {
        /// 53 columns of days, oldest first; the last stops at today.
        let columns: [[Date]]
        let cell: CGFloat
        let gap: CGFloat
        /// Space before the weekday labels, when the cell is at its largest
        /// and the grid is centred in a wider card.
        let inset: CGFloat
        /// The width laid out for (the card's content width).
        let width: CGFloat
        let months: [MonthLabel]

        var pitch: CGFloat { cell + gap }
        var radius: CGFloat { cell * ActivityGrid.radiusRatio }
        /// The x of the first column.
        var left: CGFloat { inset + ActivityGrid.axisWidth }
        /// Weekday labels plus the 53 columns.
        var gridWidth: CGFloat { ActivityGrid.gridWidth(cell: cell) }
        var height: CGFloat { ActivityGrid.height(cell: cell) }

        func x(column: Int) -> CGFloat { left + CGFloat(column) * pitch }
        func y(row: Int) -> CGFloat { ActivityGrid.monthHeight + CGFloat(row) * pitch }
    }

    /// The whole layout for `width` points of card content.
    static func layout(today: Date, calendar: Calendar, width: CGFloat) -> Layout {
        let cell = cellSize(width: width)
        let gap = cell * gapRatio
        let inset = max(0, (width - gridWidth(cell: cell)) / 2)
        let cols = columns(today: today, calendar: calendar)
        let left = inset + axisWidth
        let right = inset + gridWidth(cell: cell)
        let months = monthLabels(columns: cols, calendar: calendar, left: left, pitch: cell + gap, right: right)
        return Layout(columns: cols, cell: cell, gap: gap, inset: inset, width: width, months: months)
    }

    /// The tile side that fills `width` with the gutter and 53 columns, clamped.
    static func cellSize(width: CGFloat) -> CGFloat {
        let n = CGFloat(weeks)
        let units = n + (n - 1) * gapRatio
        let fit = (width - axisWidth) / units
        return min(max(fit, minCell), maxCell)
    }

    static func gridWidth(cell: CGFloat) -> CGFloat {
        let n = CGFloat(weeks)
        return axisWidth + n * cell + (n - 1) * cell * gapRatio
    }

    static func height(cell: CGFloat) -> CGFloat {
        monthHeight + 7 * cell + 6 * cell * gapRatio
    }

    /// The height the grid needs at `width`.
    static func height(width: CGFloat) -> CGFloat {
        height(cell: cellSize(width: width))
    }

    /// The first day of the week holding `date`, by the calendar's first weekday.
    static func weekStart(_ date: Date, calendar: Calendar) -> Date {
        let day = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: day)
        let since = (weekday - calendar.firstWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: -since, to: day) ?? day
    }

    /// 53 columns of whole days. The first starts 52 weeks before the current
    /// week's start; the last runs from this week's start to today, so days
    /// after today are left out rather than drawn.
    static func columns(today: Date, calendar: Calendar) -> [[Date]] {
        let end = calendar.startOfDay(for: today)
        let thisWeek = weekStart(today, calendar: calendar)
        guard let first = calendar.date(byAdding: .day, value: -7 * (weeks - 1), to: thisWeek) else { return [] }
        return (0..<weeks).map { column in
            (0..<7).compactMap { row -> Date? in
                let offset = column * 7 + row
                guard let day = calendar.date(byAdding: .day, value: offset, to: first) else { return nil }
                return day <= end ? day : nil
            }
        }
    }

    /// The month's short name over the first column holding its 1st. A name
    /// is shown once: when a month comes round again at the right, the older
    /// one at the left is dropped. A label too close to the one before it is
    /// skipped, and the last one is kept inside the grid's right edge.
    static func monthLabels(columns: [[Date]], calendar: Calendar, left: CGFloat, pitch: CGFloat, right: CGFloat) -> [MonthLabel] {
        var found: [MonthLabel] = []
        for (column, days) in columns.enumerated() {
            guard let first = days.first(where: { calendar.component(.day, from: $0) == 1 }) else { continue }
            let month = calendar.component(.month, from: first)
            let name = calendar.shortMonthSymbols[month - 1]
            let x = min(left + CGFloat(column) * pitch, right - labelWidth(name))
            found.append(MonthLabel(column: column, x: x, name: name))
        }
        let unique = found.enumerated().filter { index, label in
            !found[(index + 1)...].contains { $0.name == label.name }
        }.map(\.element)
        var labels: [MonthLabel] = []
        for label in unique {
            if let last = labels.last {
                let lastEnd = last.x + labelWidth(last.name) + labelGap
                if label.x < lastEnd { continue }
            }
            labels.append(label)
        }
        return labels
    }

    /// About how wide a 10 pt label is.
    static func labelWidth(_ name: String) -> CGFloat {
        CGFloat(name.count) * 6 + 2
    }

    /// Unchanged from the old grid: 0 for no words, else four steps relative
    /// to the busiest day shown.
    static func level(words: Int, peak: Int) -> Int {
        guard words > 0 else { return 0 }
        let share = Double(words) / Double(max(peak, 1))
        return min(4, Int((share * 4).rounded(.up)))
    }

    /// A level per drawn day. Days with no entry, including every day before
    /// the first use, are level 0. `words` is keyed by the start of each day.
    static func levels(columns: [[Date]], words: [Date: Int]) -> [[Int]] {
        var peak = 1
        for days in columns {
            for day in days { peak = max(peak, words[day] ?? 0) }
        }
        return columns.map { days in
            days.map { level(words: words[$0] ?? 0, peak: peak) }
        }
    }
}
