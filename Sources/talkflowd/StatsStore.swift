import Foundation

/// Local, persisted usage stats - never leaves the machine. Updated once per
/// completed dictation (whichever path produced the final text: live-streamed or
/// the rare batch fallback).
final class StatsStore {
    static let shared = StatsStore()

    private struct Data: Codable {
        var totalWords: Int = 0
        var totalSessions: Int = 0
        var totalSpeakingSeconds: Double = 0
        /// "yyyy-MM-dd" -> word count that day, for the streak and today's count.
        var dailyWordCounts: [String: Int] = [:]
    }

    private var data = Data()
    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.samir.talkflow.stats")

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TalkFlow")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("stats.json")
        load()
    }

    private func load() {
        guard let raw = try? Foundation.Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(Data.self, from: raw) else { return }
        data = decoded
    }

    private func save() {
        guard let encoded = try? JSONEncoder().encode(data) else { return }
        try? encoded.write(to: fileURL, options: .atomic)
    }

    private static func dayKey(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    func recordSession(text: String, durationSeconds: Double) {
        let wordCount = text.split(whereSeparator: { $0.isWhitespace }).count
        guard wordCount > 0, durationSeconds > 0 else { return }

        queue.async { [self] in
            data.totalWords += wordCount
            data.totalSessions += 1
            data.totalSpeakingSeconds += durationSeconds
            let key = Self.dayKey()
            data.dailyWordCounts[key, default: 0] += wordCount
            save()
        }
    }

    struct Snapshot {
        let totalWords: Int
        let totalSessions: Int
        let averageWPM: Int
        let todayWords: Int
        let dayStreak: Int
        let estimatedMinutesSaved: Int
    }

    /// Synchronous snapshot for the dashboard - reads happen on the same serial
    /// queue as writes so this always reflects the latest saved state.
    func snapshot() -> Snapshot {
        queue.sync {
            let minutesSpeaking = data.totalSpeakingSeconds / 60
            let avgWPM = minutesSpeaking > 0 ? Int(Double(data.totalWords) / minutesSpeaking) : 0

            let today = data.dailyWordCounts[Self.dayKey()] ?? 0

            var streak = 0
            var cursor = Date()
            while true {
                let key = Self.dayKey(cursor)
                guard let words = data.dailyWordCounts[key], words > 0 else { break }
                streak += 1
                guard let previous = Calendar.current.date(byAdding: .day, value: -1, to: cursor) else { break }
                cursor = previous
            }

            // Time saved vs. typing at a typical ~40wpm, minus the time actually
            // spent talking (dictation isn't instant either).
            let typingMinutesEquivalent = Double(data.totalWords) / 40.0
            let saved = max(0, typingMinutesEquivalent - minutesSpeaking)

            return Snapshot(
                totalWords: data.totalWords,
                totalSessions: data.totalSessions,
                averageWPM: avgWPM,
                todayWords: today,
                dayStreak: streak,
                estimatedMinutesSaved: Int(saved)
            )
        }
    }
}
