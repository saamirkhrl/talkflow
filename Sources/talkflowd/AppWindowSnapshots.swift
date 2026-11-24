import AppKit
import SwiftUI

extension DashboardController {
    /// `--dashboardshot [folder]`: draws every section of the window, light
    /// and dark, to PNGs, from sample stats and words in a throwaway sandbox,
    /// so the layout can be checked without a screen. Never reads or writes
    /// the user's settings, stats or keys.
    @MainActor
    static func renderSnapshots() -> [URL] {
        let arguments = CommandLine.arguments
        let folder = arguments.firstIndex(of: "--dashboardshot")
            .flatMap { arguments.dropFirst($0 + 1).first }
            .map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("talkflow-app-window")
        PreviewSandbox.enter()
        defer { PreviewSandbox.leave() }
        PreviewSandbox.useRepoIcon()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = AppWindowModel(settings: SettingsModel(environment: .preview()), updatesEnabled: false, notes: NotesModel.preview())
        model.refresh()
        let update = Updater.State.available(Updater.Release(
            version: "0.2.0", zipURL: URL(string: "https://example.invalid/talkflow.zip")!, pageURL: nil))
        var written: [URL] = []

        /// Draws the current state of `model` as `index-name-light/dark.png`.
        func shoot(_ index: Int, _ name: String, _ section: AppSection, fullHeight: Bool) {
            model.section = section
            for (look, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let url = folder.appendingPathComponent(String(format: "%02d-%@-%@.png", index, name, look))
                if render(model, appearance: appearance, fullHeight: fullHeight, to: url) { written.append(url) }
            }
        }

        // The state a shot sets is set after `refresh()` (it overwrites
        // `setupNeeded`) and put back before the next shot.
        model.dashboard.chartStyle = .grid
        model.dashboard.hovered = model.dashboard.days.count - 1
        shoot(1, "home", .home, fullHeight: true)

        model.dashboard.chartStyle = .bars
        model.dashboard.hovered = DashboardModel.chartWeeks - 1
        shoot(2, "home-bars", .home, fullHeight: true)

        model.dashboard.hovered = nil
        model.updateOverride = update
        shoot(3, "home-update", .home, fullHeight: true)

        model.updateOverride = nil
        model.setupNeeded = true
        shoot(4, "home-setup", .home, fullHeight: true)
        model.setupNeeded = false

        shoot(5, "notes", .notes, fullHeight: true)
        shoot(6, "dictionary", .dictionary, fullHeight: true)

        Preferences.learnedWords = []
        model.dictionary.refresh()
        shoot(7, "dictionary-empty", .dictionary, fullHeight: true)
        Preferences.learnedWords = SampleData.words
        model.dictionary.refresh()

        shoot(8, "settings", .settings, fullHeight: true)

        model.settings.hasAnthropicKey = true
        model.settings.useClaude = true
        model.settings.keyStatus["openai"] = (true, "That key was not accepted.")
        model.updateOverride = update
        shoot(9, "settings-keys", .settings, fullHeight: true)
        model.updateOverride = nil
        model.settings.keyStatus["openai"] = nil

        // Notes: every screen, from the made-up meetings NotesModel.preview() seeded. `stage` sets each state
        // without timers or a microphone.
        let n = model.notes
        func noteID(_ title: String) -> String { n.notes.first { $0.title == title }?.id ?? "" }
        let launch = noteID("Launch planning")
        let failed = noteID("Customer call")
        n.stage(route: .session, session: NotesSession(noteID: launch, phase: .recording(CaptureLevels(
            elapsed: 754, you: 0.62, others: 0.34, noComputerAudio: false, echoHandlingActive: true))), title: "Launch planning")
        shoot(10, "notes-recording", .notes, fullHeight: true)
        n.stage(route: .session, session: NotesSession(noteID: launch, phase: .recording(CaptureLevels(
            elapsed: 95, you: 0.4, others: 0, noComputerAudio: true, echoHandlingActive: false,
            computerAudio: .notArriving))))
        shoot(11, "notes-recording-quiet", .notes, fullHeight: true)
        n.stage(route: .session, session: NotesSession(noteID: launch, phase: .writing(WritingProgress(
            step: .transcribing, fraction: 0.8, secondsLeft: 110))), title: "Launch planning", duration: 2520)
        shoot(12, "notes-writing", .notes, fullHeight: true)
        n.stage(route: .detail(launch))
        shoot(13, "note-detail", .notes, fullHeight: true)
        n.renamingKey = "s2"
        n.renameDraft = "Sam"
        shoot(14, "note-rename", .notes, fullHeight: true)
        n.cancelRename()
        n.detailTab = .summary
        shoot(15, "note-summary-off", .notes, fullHeight: true)
        n.detailTab = .ask
        shoot(16, "note-ask-off", .notes, fullHeight: true)
        n.detailTab = .transcript
        n.stage(route: .detail(failed))
        shoot(17, "note-failed", .notes, fullHeight: true)
        // A meeting still marked as recording, as if talkflow had quit during it.
        let left = try? n.store.create(title: "Weekly planning", started: Date().addingTimeInterval(-3 * 3600))
        n.stage(route: .list)
        n.refresh()
        shoot(18, "notes-leftover", .notes, fullHeight: true)
        if let left { try? n.store.delete(left.id) }
        for note in n.store.list() { try? n.store.delete(note.id) }
        n.refresh()
        shoot(19, "notes-empty", .notes, fullHeight: true)
        n.supportsRecording = false
        n.unsupportedMessage = NotesLogic.unsupportedMessage(OperatingSystemVersion(majorVersion: 13, minorVersion: 6, patchVersion: 0))
        shoot(20, "notes-unsupported", .notes, fullHeight: true)

        return written
    }

    @MainActor
    private static func render(_ model: AppWindowModel, appearance: NSAppearance.Name, fullHeight: Bool, to url: URL) -> Bool {
        guard let look = NSAppearance(named: appearance) else { return false }
        let width = AppMetrics.defaultSize.width
        let root = AppShellView(model: model, snapshot: true)
            .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
        let host = NSHostingView(rootView: root)
        host.appearance = look
        var height = AppMetrics.defaultSize.height
        if fullHeight {
            host.frame = NSRect(x: 0, y: 0, width: width, height: height)
            host.layoutSubtreeIfNeeded()
            height = max(height, host.fittingSize.height)
        }
        // A real (off-screen) window, so AppKit controls (pickers, fields,
        // the chart's menu) draw for real instead of as placeholders.
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = look
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        // 2x, whatever screen (if any) the off-screen window is on.
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * 2), pixelsHigh: Int(height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        rep.size = NSSize(width: width, height: height)
        look.performAsCurrentDrawingAppearance {
            host.cacheDisplay(in: host.bounds, to: rep)
        }
        window.contentView = nil
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }
}
