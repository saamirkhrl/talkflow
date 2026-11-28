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
        model.dashboard.hovered = model.dashboard.days.count - 1
        shoot(1, "home", .home, fullHeight: true)

        // Home at the window's default and smallest sizes, laid out and scrolling as in the app.
        model.dashboard.hovered = nil
        model.section = .home
        for (sizeName, size) in [("default", AppMetrics.defaultSize), ("min", AppMetrics.minSize)] {
            for (look, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let url = folder.appendingPathComponent("02-home-\(sizeName)-\(look).png")
                if renderLive(model, appearance: appearance, size: size, to: url) { written.append(url) }
                let bottom = folder.appendingPathComponent("03-home-\(sizeName)-\(look)-bottom.png")
                if renderLive(model, appearance: appearance, size: size, scroll: .bottom, to: bottom) { written.append(bottom) }
            }
        }
        model.dashboard.hoveredBar = 20
        shoot(8, "home-bar-hover", .home, fullHeight: true)
        model.dashboard.hoveredBar = nil

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
        // Select mode with two meetings ticked.
        model.notes.beginSelecting(with: model.notes.notes.first?.id)
        if model.notes.notes.count > 1 { model.notes.toggleSelected(model.notes.notes[1].id) }
        shoot(8, "notes-select", .notes, fullHeight: true)
        model.notes.endSelecting()
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
        // The council meeting: auto-named speakers.
        n.stage(route: .detail(council)); n.detailTab = .transcript
        shoot(30, "note-speakers-auto", .notes, fullHeight: true)
        // The title being edited.
        n.stage(route: .detail(launch)); n.detailTab = .summary
        n.editingTitle = true
        n.titleDraft = "Launch planning"
        shoot(32, "note-title-edit", .notes, fullHeight: true)
        n.editingTitle = false
        n.titleDraft = ""
        // The meeting page at the window's default and smallest sizes, laid out and scrolling as in the app.
        func shootLive(_ name: String, scroll: LiveScroll = .top) {
            model.section = .notes
            for (sizeName, size) in [("default", AppMetrics.defaultSize), ("min", AppMetrics.minSize)] {
                for (look, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    let url = folder.appendingPathComponent("50-\(name)-\(sizeName)-\(look).png")
                    if renderLive(model, appearance: appearance, size: size, scroll: scroll, to: url) { written.append(url) }
                }
            }
        }
        n.stage(route: .detail(launch)); n.detailTab = .summary
        shootLive("detail-summary")
        // The document after editing: the sample's ticked and unticked to-dos, and an empty last block with the
        // caret (its placeholder); then the slash menu open on a "/" block under the summary paragraph. Written
        // to the preview sandbox's note only, and removed after.
        if let sum = n.store.summary(launch), let meta = n.store.meta(launch) {
            let base = NoteDocument.converting(sum, speakers: meta.speakers)
            let basedOn = sum.written.timeIntervalSince1970
            try? n.store.save(NoteDocument(basedOn: basedOn, blocks: base + [NoteDocument.Block(.paragraph)]), for: launch)
            n.stage(route: .detail(launch)); n.detailTab = .summary
            NoteDocumentEditor.snapshotStage = DocEditorStage(focusBlock: base.count, slash: false)
            shootLive("detail-summary-edited", scroll: .bottom)
            var slashBlocks = base
            slashBlocks.insert(NoteDocument.Block(.paragraph, [NoteDocument.Span("/")]), at: 2)
            try? n.store.save(NoteDocument(basedOn: basedOn, blocks: slashBlocks), for: launch)
            n.stage(route: .detail(launch)); n.detailTab = .summary
            NoteDocumentEditor.snapshotStage = DocEditorStage(focusBlock: 2, slash: true)
            shootLive("detail-summary-slash")
            NoteDocumentEditor.snapshotStage = nil
            try? FileManager.default.removeItem(at: n.store.folder(for: launch).appendingPathComponent("document.json"))
            n.stage(route: .detail(launch))
        }
        n.stage(route: .detail(robotics)); n.detailTab = .ask
        shootLive("detail-ask-empty")
        // The two made-up answers, then a long one.
        var asked = NotesAISamples.questions(now: Date())
        if let last = asked.entries.last {
            asked.entries.append(NoteQuestions.Entry(
                question: "What is still open before launch, and who has each part?",
                answer: """
                Three things are still open before launch.

                First, the demo video. Everyone agreed the current one undersells the app, and a new cut waits on the Settings page being final [27]. Nobody gave a date for that yet.

                Second, the launch post. It leads with the privacy angle [36], Maya drafts it tonight and sends it round for edits [48], and the screenshots for launch day come from Speaker 2 [75].

                Third, the follow-up. There is a check-in on Thursday to see where things stand [92]; anything not settled by then moves to the week after.

                - Demo video: waiting on Settings [27]
                - Launch post: drafting tonight [48]
                - Check-in: Thursday [92]
                """,
                citations: [27, 36, 48, 75, 92], asked: Date(), provider: last.provider, model: last.model))
        }
        try? n.store.save(asked, for: launch)
        n.stage(route: .detail(launch)); n.detailTab = .ask
        shootLive("detail-ask")
        n.detailTab = .transcript
        shootLive("detail-transcript")
        shootLive("detail-transcript-scrolled", scroll: .middle)
        try? n.store.save(NotesAISamples.questions(now: Date()), for: launch)
        n.stage(route: .detail(launch))
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
            // Lets the document editor report its height (it does so a moment after it is made).
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
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

    /// Where a live render's tab is scrolled to.
    enum LiveScroll { case top, middle, bottom }

    /// The tallest scroll view whose content is taller than it: the tab's content.
    @MainActor
    private static func tabScrollView(in root: NSView) -> NSScrollView? {
        var best: NSScrollView?
        var bestHeight: CGFloat = 0
        func walk(_ v: NSView) {
            if let sv = v as? NSScrollView, let doc = sv.documentView,
               doc.frame.height > sv.contentView.bounds.height + 1, doc.frame.height > bestHeight {
                best = sv
                bestHeight = doc.frame.height
            }
            v.subviews.forEach(walk)
        }
        walk(root)
        return best
    }

    /// The window at a fixed size, laid out as in the app (pages scroll), for the meeting page's tabs.
    @MainActor
    private static func renderLive(_ model: AppWindowModel, appearance: NSAppearance.Name, size: NSSize,
                                   scroll: LiveScroll = .top, to url: URL) -> Bool {
        guard let look = NSAppearance(named: appearance) else { return false }
        let root = AppShellView(model: model, snapshot: false)
            .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
            .frame(width: size.width, height: size.height)
        let host = NSHostingView(rootView: root)
        host.appearance = look
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = look
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        // Lets the Ask tab's scroll to the newest question run, as it does a moment after the page opens.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        if scroll != .top {
            if let sv = tabScrollView(in: host), let doc = sv.documentView {
                let maxY = max(0, doc.frame.height - sv.contentView.bounds.height)
                let y = scroll == .middle ? (maxY * 0.5).rounded() : maxY
                sv.contentView.scroll(to: NSPoint(x: 0, y: doc.isFlipped ? y : maxY - y))
                sv.reflectScrolledClipView(sv.contentView)
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                host.layoutSubtreeIfNeeded()
            } else {
                print("talkflowd: snapshot: no scroll view to scroll in \(url.lastPathComponent)")
            }
        }
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        rep.size = size
        look.performAsCurrentDrawingAppearance {
            host.cacheDisplay(in: host.bounds, to: rep)
        }
        window.contentView = nil
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }
}
