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
        model.dashboard.hovered = DashboardModel.barWeeks - 1
        shoot(2, "home-bars", .home, fullHeight: true)

        model.dashboard.hovered = nil
        model.updateOverride = update
        shoot(3, "home-update", .home, fullHeight: true)

        model.updateOverride = nil
        model.setupNeeded = true
        shoot(4, "home-setup", .home, fullHeight: true)
        model.setupNeeded = false

        // A made-up council meeting, with an auto title and auto names, beside the launch samples.
        let council = SampleNotes.seedCouncil(into: model.notes.store) ?? ""
        model.notes.refresh()
        shoot(5, "notes", .notes, fullHeight: true)
        shoot(6, "dictionary", .dictionary, fullHeight: true)

        Preferences.learnedWords = []
        model.dictionary.refresh()
        shoot(7, "dictionary-empty", .dictionary, fullHeight: true)
        Preferences.learnedWords = SampleData.words
        model.dictionary.refresh()

        // Every Settings page, with no key saved.
        for (i, g) in SettingsGroup.allCases.enumerated() {
            model.settingsGroup = g
            shoot(30 + i, "settings-\(g.rawValue)", .settings, fullHeight: true)
        }

        // API keys with one key saved and the other being added (and refused), then About with an update waiting.
        model.settings.hasAnthropicKey = true
        model.settings.useClaude = true
        model.settings.keySuffix["anthropic"] = "7Q2x"
        model.settings.keyStatus["openai"] = (true, "That key was not accepted.")
        model.settings.editingKey = "openai"
        model.settingsGroup = .apiKeys
        shoot(36, "settings-keys", .settings, fullHeight: true)
        model.settings.editingKey = nil
        model.settings.keyStatus["openai"] = nil
        model.updateOverride = update
        model.settingsGroup = .about
        shoot(38, "settings-about-update", .settings, fullHeight: true)
        model.updateOverride = nil
        model.settings.hasAnthropicKey = false
        model.settings.useClaude = false
        model.settings.keySuffix = [:]
        model.settingsGroup = .general

        // Notes: every screen, from the made-up meetings NotesModel.preview() seeded. `stage` sets each state
        // without timers or a microphone.
        let n = model.notes
        func noteID(_ title: String) -> String { n.notes.first { $0.title == title }?.id ?? "" }
        let launch = noteID("Launch planning")
        let failed = noteID("Customer call")
        let robotics = noteID("Robotics team sync")
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
        n.detailTab = .transcript
        shoot(13, "note-detail", .notes, fullHeight: true)
        n.renamingKey = "s2"
        n.renameDraft = "Sam"
        shoot(14, "note-rename", .notes, fullHeight: true)
        n.cancelRename()
        // A note with no summary, on the Summary tab, no key.
        n.stage(route: .detail(robotics))
        n.detailTab = .summary
        shoot(15, "note-summary-off", .notes, fullHeight: true)
        n.stage(route: .detail(launch))
        n.detailTab = .ask
        shoot(16, "note-ask-off", .notes, fullHeight: true)
        n.stage(route: .detail(failed))
        shoot(17, "note-failed", .notes, fullHeight: true)
        // Summary and Ask with a key in use, from the made-up summary and answers NotesModel.preview() seeded and canned states.
        // The access is resolved with a key in memory; nothing is sent anywhere.
        let a = n.assistant
        a.access = { NotesAccess.resolve(hasAnthropic: { true }, hasOpenAI: { false }, anthropicModel: nil, openAIModel: nil) }
        n.stage(route: .detail(launch)); n.detailTab = .summary
        shoot(21, "note-summary", .notes, fullHeight: true)
        a.stageSummaryPhase(.writing(step: 2, total: 3), for: launch)
        shoot(22, "note-summary-writing", .notes, fullHeight: true)
        a.stageSummaryPhase(.failed(.rateLimited(retryAfter: 30), retryAt: Date().addingTimeInterval(30)), for: launch)
        shoot(23, "note-summary-failed", .notes, fullHeight: true)
        a.stageSummaryPhase(.idle, for: launch); a.stagePending(.summary(launch))
        shoot(24, "note-summary-confirm", .notes, fullHeight: true)
        a.stagePending(nil); n.detailTab = .ask
        shoot(25, "note-ask", .notes, fullHeight: true)
        a.stageAsk(asking: "Who is sending the screenshots?", partial: "Speaker 2 is lining up the screenshots for launch day [75] and keeping them", failure: nil)
        shoot(26, "note-ask-streaming", .notes, fullHeight: true)
        a.stageAsk(asking: nil, partial: "", failure: NoteAssistant.AskFailure(question: "Who is sending the screenshots?", error: .offline, retryAt: nil))
        shoot(27, "note-ask-failed", .notes, fullHeight: true)
        a.stageAsk(asking: nil, partial: "", failure: nil); n.detailTab = .transcript; a.stageHighlight(3)
        shoot(29, "note-cited-row", .notes, fullHeight: true)
        a.stageHighlight(nil)
        // The council meeting: auto-named speakers, then the one being renamed.
        n.stage(route: .detail(council)); n.detailTab = .transcript
        shoot(30, "note-speakers-auto", .notes, fullHeight: true)
        n.renamingKey = "s1"
        n.renameDraft = "Councilmember Lee"
        shoot(31, "note-rename-suggested", .notes, fullHeight: true)
        n.cancelRename()
        // The title being edited.
        n.stage(route: .detail(launch)); n.detailTab = .summary
        n.editingTitle = true
        n.titleDraft = "Launch planning"
        shoot(32, "note-title-edit", .notes, fullHeight: true)
        n.editingTitle = false
        n.titleDraft = ""
        a.access = { nil }
        // A meeting still marked as recording, as if talkflow had quit during it.
        let left = try? n.store.create(title: "Weekly planning", started: Date().addingTimeInterval(-3 * 3600))
        n.stage(route: .list)
        n.refresh()
        shoot(18, "notes-leftover", .notes, fullHeight: true)
        if let left { try? n.store.delete(left.id) }
        for note in n.store.list() { try? n.store.delete(note.id) }
        n.refresh()
        shoot(19, "notes-empty", .notes, fullHeight: true)
        n.downloads.stage(model: .absent, speakers: .absent, declined: false)
        shoot(21, "notes-downloads", .notes, fullHeight: true)
        n.downloads.stage(model: .downloading(0.42), speakers: .done, declined: false)
        shoot(22, "notes-downloading", .notes, fullHeight: true)
        n.downloads.stage(model: .done, speakers: .done, declined: false)
        n.supportsRecording = false
        n.unsupportedMessage = NotesLogic.unsupportedMessage(OperatingSystemVersion(majorVersion: 13, minorVersion: 6, patchVersion: 0))
        shoot(20, "notes-unsupported", .notes, fullHeight: true)

        model.settings.hasAnthropicKey = true
        model.settingsGroup = .notes
        shoot(37, "settings-notes-key", .settings, fullHeight: true)
        model.settings.hasAnthropicKey = false
        model.settingsGroup = .general

        return written
    }

    @MainActor
    private static func render(_ model: AppWindowModel, appearance: NSAppearance.Name, fullHeight: Bool, to url: URL) -> Bool {
        guard let look = NSAppearance(named: appearance) else { return false }
        let width = AppMetrics.defaultSize.width
        let root = AppShellView(model: model, snapshot: true)
            .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
            // Fixed to the window's width, so the height it asks for counts text at its wrapped lines.
            .frame(width: width)
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
