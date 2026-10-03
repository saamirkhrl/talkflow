import AppKit

/// A simple stats window: total words, average WPM, today's words, day streak,
/// estimated time saved. All from StatsStore (local JSON, never leaves the Mac).
final class DashboardController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "talkflow Dashboard"
        window.center()
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.contentView = buildContentView()
    }

    func show() {
        refresh()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var valueLabels: [String: NSTextField] = [:]

    private func buildContentView() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 320))

        let title = NSTextField(labelWithString: "Your dictation stats")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.frame = NSRect(x: 24, y: 270, width: 312, height: 24)
        container.addSubview(title)

        let rows: [(key: String, label: String)] = [
            ("totalWords", "Total words dictated"),
            ("averageWPM", "Average words per minute"),
            ("todayWords", "Words dictated today"),
            ("dayStreak", "Day streak"),
            ("timeSaved", "Estimated time saved"),
            ("totalSessions", "Total dictations")
        ]

        var y: CGFloat = 226
        for row in rows {
            let label = NSTextField(labelWithString: row.label)
            label.textColor = .secondaryLabelColor
            label.frame = NSRect(x: 24, y: y, width: 220, height: 20)
            container.addSubview(label)

            let value = NSTextField(labelWithString: "-")
            value.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
            value.alignment = .right
            value.frame = NSRect(x: 244, y: y, width: 92, height: 20)
            container.addSubview(value)
            valueLabels[row.key] = value

            y -= 30
        }

        return container
    }

    private func refresh() {
        let snapshot = StatsStore.shared.snapshot()
        valueLabels["totalWords"]?.stringValue = "\(snapshot.totalWords)"
        valueLabels["averageWPM"]?.stringValue = "\(snapshot.averageWPM) wpm"
        valueLabels["todayWords"]?.stringValue = "\(snapshot.todayWords)"
        valueLabels["dayStreak"]?.stringValue = "\(snapshot.dayStreak) day\(snapshot.dayStreak == 1 ? "" : "s")"
        valueLabels["timeSaved"]?.stringValue = "\(snapshot.estimatedMinutesSaved) min"
        valueLabels["totalSessions"]?.stringValue = "\(snapshot.totalSessions)"
    }
}
