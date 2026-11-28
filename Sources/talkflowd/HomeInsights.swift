import Foundation

/// The words Home says about your numbers: the greeting, a usual day, and a
/// milestone line. Pure values, so --streamtest can check them.
enum HomeInsights {
    /// "Good morning" from 5, "Good afternoon" from 12, "Good evening" from 17,
    /// "Working late" from 22 to 5.
    static func greeting(hour: Int) -> String {
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Working late"
        }
    }

    /// The median words of the days with words among the 30 calendar days
    /// before `today` (today excluded); nil with fewer than 3 such days.
    static func usual(days: [(date: Date, words: Int)], today: Date, calendar: Calendar) -> Int? {
        let end = calendar.startOfDay(for: today)
        let counts = days.compactMap { day -> Int? in
            guard day.words > 0 else { return nil }
            let ago = calendar.dateComponents([.day], from: calendar.startOfDay(for: day.date), to: end).day ?? 0
            return (1...30).contains(ago) ? day.words : nil
        }.sorted()
        guard counts.count >= 3 else { return nil }
        let mid = counts.count / 2
        return counts.count % 2 == 1 ? counts[mid] : (counts[mid - 1] + counts[mid]) / 2
    }

    /// Today against a usual day; nil when there is no usual day to compare to.
    static func todayRatio(today: Int, usual: Int?) -> Double? {
        guard let usual, usual != 0 else { return nil }
        return Double(today) / Double(usual)
    }

    /// One line under the total, picked by `day` from what holds for `total`:
    /// the next round number, a number of novels, a number of pages.
    static func milestone(total: Int, day: Int) -> String? {
        guard total > 0 else { return nil }
        var candidates: [String] = []
        let step = total < 10_000 ? 1_000 : total < 100_000 ? 10_000 : total < 1_000_000 ? 25_000 : 100_000
        let next = (total / step + 1) * step
        candidates.append("\(grouped(next - total)) words to \(grouped(next)).")
        if total >= 45_000 {
            let n = (Double(total) / 90_000 * 10).rounded() / 10
            if n == 1 {
                candidates.append("That's about 1 novel.")
            } else {
                var text = String(format: "%.1f", n)
                if text.hasSuffix(".0") { text.removeLast(2) }
                candidates.append("That's about \(text) novels.")
            }
        }
        if total >= 500 {
            let pages = Int((Double(total) / 500).rounded())
            candidates.append("About \(grouped(pages)) pages, typed for you.")
        }
        return candidates[((day % candidates.count) + candidates.count) % candidates.count]
    }

    /// Days since 1970-01-01 in `calendar`; stable within a day.
    static func dayNumber(_ date: Date, calendar: Calendar) -> Int {
        let epoch = calendar.startOfDay(for: Date(timeIntervalSince1970: 0))
        return calendar.dateComponents([.day], from: epoch, to: calendar.startOfDay(for: date)).day ?? 0
    }

    /// 113507 -> "113,507", whatever the user's locale.
    static func grouped(_ value: Int) -> String {
        let digits = String(abs(value))
        var out = ""
        for (i, ch) in digits.reversed().enumerated() {
            if i > 0 && i % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return (value < 0 ? "-" : "") + String(out.reversed())
    }
}
