import Foundation

/// The Home page's year calendar: the 12 months ending with this one, a block
/// per month with its days under the weekday columns, so a day's place is a
/// date you can read. Pure values, so --streamtest can check it without
/// drawing anything.
enum ActivityGrid {
    /// Between month blocks, both directions.
    static let blockGap: CGFloat = 20
    /// The gap between tiles, as a share of the tile.
    static let gapRatio: CGFloat = 0.18
    static let minCell: CGFloat = 16
    static let maxCell: CGFloat = 26
    static let monthLabelHeight: CGFloat = 20
    /// The corner radius, as a share of the tile.
    static let radiusRatio: CGFloat = 0.2
    /// The card's side padding, so the minimum window width can be checked.
    static let cardPadding: CGFloat = 20

    /// Brand opacity for levels 1...4; level 0 is a faint ink.
    static let levelOpacity: [Double] = [0.35, 0.55, 0.78, 1.0]

    /// The first day of each of the 12 months ending with today's, oldest first.
    static func months(today: Date, calendar: Calendar) -> [Date] {
        guard let thisMonth = calendar.dateInterval(of: .month, for: today)?.start else { return [] }
        return (0..<12).reversed().compactMap { calendar.date(byAdding: .month, value: -$0, to: thisMonth) }
    }

    /// How many days of data the calendar needs: the first day of the first
    /// month up to today, both included.
    static func dayCount(today: Date, calendar: Calendar) -> Int {
        guard let first = months(today: today, calendar: calendar).first else { return 0 }
        let span = calendar.dateComponents([.day], from: first, to: calendar.startOfDay(for: today)).day ?? 0
        return span + 1
    }

    /// How many blocks fit a row of `width`, and the tile side that fills it.
    static func blocksPerRow(width: CGFloat) -> (perRow: Int, cell: CGFloat) {
        func cell(_ k: Int) -> CGFloat {
            let blockW = (width - CGFloat(k - 1) * blockGap) / CGFloat(k)
            return blockW / (7 + 6 * gapRatio)
        }
        let k = [4, 3, 2].first { cell($0) >= minCell } ?? 2
        return (k, min(cell(k), maxCell))
    }

    /// The 42 slots of a month's block (6 weeks of 7), by the calendar's first
    /// weekday: the month's days in place, nil where the slot is another month's.
    static func slots(month: Date, calendar: Calendar) -> [Date?] {
        guard let start = calendar.dateInterval(of: .month, for: month)?.start,
              let count = calendar.range(of: .day, in: .month, for: start)?.count else { return [Date?](repeating: nil, count: 42) }
        let weekday = calendar.component(.weekday, from: start)
        let lead = (weekday - calendar.firstWeekday + 7) % 7
        return (0..<42).map { slot in
            let day = slot - lead
            return (0..<count).contains(day) ? calendar.date(byAdding: .day, value: day, to: start) : nil
        }
    }

    static func blockWidth(cell: CGFloat) -> CGFloat { 7 * cell + 6 * cell * gapRatio }
    static func blockHeight(cell: CGFloat) -> CGFloat { monthLabelHeight + 6 * cell + 5 * cell * gapRatio }

    /// The height the 12 blocks need at `width`.
    static func height(width: CGFloat) -> CGFloat {
        let layout = blocksPerRow(width: width)
        let rows = (12 + layout.perRow - 1) / layout.perRow
        return CGFloat(rows) * blockHeight(cell: layout.cell) + CGFloat(rows - 1) * blockGap
    }

    /// 0 for no words, else four steps relative to the busiest day shown.
    static func level(words: Int, peak: Int) -> Int {
        guard words > 0 else { return 0 }
        let share = Double(words) / Double(max(peak, 1))
        return min(4, Int((share * 4).rounded(.up)))
    }

    /// A level per day, in order. Days with no entry, including every day
    /// before the first use, are level 0. `words` is keyed by the start of each day.
    static func levels(days: [Date], words: [Date: Int]) -> [Int] {
        var peak = 1
        for day in days { peak = max(peak, words[day] ?? 0) }
        return days.map { level(words: words[$0] ?? 0, peak: peak) }
    }
}
