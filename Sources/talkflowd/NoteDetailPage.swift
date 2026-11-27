import AppKit
import SwiftUI

/// One meeting: header with Copy and Delete, the speakers, then Summary and Transcript. The Ask bar (NoteAskBar)
/// is pinned under the page. Without a key the Summary tab shows saved notes read only, or how to add a key; a
/// time in the notes or in an answer jumps to its row in the transcript.
struct NoteDetailPage: View {
    @ObservedObject var model: NotesModel
    @ObservedObject private var assistant: NoteAssistant
    var scrolls = true

    init(model: NotesModel, scrolls: Bool = true) {
        self.model = model
        self.scrolls = scrolls
        _assistant = ObservedObject(wrappedValue: model.assistant)
    }

    var body: some View {
        VStack(spacing: 0) {
            // A snapshot has no scroll view: the page takes the height its content needs, so the bar sits under it.
            if scrolls { page } else { page.fixedSize(horizontal: false, vertical: true) }
            if !turns.isEmpty, let meta = model.detailMeta {
                NoteAskBar(model: model, assistant: assistant, meta: meta, turns: turns, scrolls: scrolls)
            }
        }
    }

    private var page: some View {
        ScrollViewReader { proxy in
            AppPage(maxWidth: 780, scrolls: scrolls) {
                VStack(alignment: .leading, spacing: 22) {
                    AppBackLink(title: "Notes") { model.backToList() }
                    if let meta = model.detailMeta {
                        content(meta)
                    }
                }
            }
            .onChange(of: assistant.jump) { jump in
                guard let jump else { return }
                model.detailTab = .transcript
                // Next turn: the transcript rows only exist once the tab has switched.
                DispatchQueue.main.async { scroll(proxy, to: jump.turn) }
            }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, to turn: Int) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            proxy.scrollTo(turn, anchor: .center)
        } else {
            withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(turn, anchor: .center) }
        }
    }

    @ViewBuilder
    private func content(_ meta: NoteMeta) -> some View {
        header(meta)
        if !meta.speakers.isEmpty {
            speakersRow(meta)
        }
        if let problem = model.problem {
            Text(problem)
                .font(AppFont.caption)
                .foregroundColor(Palette.warn)
        }
        if case .failed(let f) = meta.state {
            failedNotice(meta, f)
        }
        AppSegmented(label: "View", options: NoteTab.allCases, title: { $0.rawValue }, selection: $model.detailTab)
        switch model.detailTab {
        case .transcript:
            transcript(meta)
        case .summary:
            summaryTab(meta)
        }
    }

    @ViewBuilder
    private func summaryTab(_ meta: NoteMeta) -> some View {
        if model.keyInUse {
            NoteSummaryView(assistant: assistant, meta: meta, turns: turns)
        } else if let summary = assistant.summary {
            NotesDocumentView(assistant: assistant, meta: meta, summary: summary, writing: false, onWriteAgain: nil)
        } else {
            offCard(title: "Summaries need a key",
                    body: "Add an Anthropic or OpenAI key in Settings > API keys and talkflow writes a summary, action items and decisions for each meeting. The transcript is sent to your provider to write them; the audio never leaves this Mac.")
        }
    }

    private var turns: [TranscriptTurn] { model.detailTranscript?.turns ?? [] }

    // MARK: Header

    private func headerLine(_ meta: NoteMeta) -> String {
        let parts: [String?] = [
            NotesLogic.dateLabel(meta.started, now: Date(), calendar: .current),
            meta.duration > 0 ? NotesLogic.durationText(meta.duration) : nil
        ]
        return parts.compactMap { $0 }.joined(separator: " \u{00B7} ")
    }

    private func header(_ meta: NoteMeta) -> some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                titleView(meta)
                Text(headerLine(meta))
                    .font(AppFont.caption)
                    .foregroundColor(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                copyButton(meta)
                Button("Delete...") { model.askAndDelete(meta.id) }
                    .buttonStyle(AppSecondaryButtonStyle())
                    .help("Deletes this note from this Mac")
            }
        }
    }

    @ViewBuilder
    private func titleView(_ meta: NoteMeta) -> some View {
        let title = NotesLogic.displayTitle(meta)
        if model.editingTitle {
            HStack(spacing: 10) {
                TextField("Untitled meeting", text: $model.titleDraft)
                    .textFieldStyle(.plain)
                    .font(AppFont.pageTitle)
                    .foregroundColor(Palette.ink)
                    .padding(.horizontal, 10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Palette.field))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.ink.opacity(0.28), lineWidth: 1))
                    .padding(.leading, -10)
                    .onSubmit { model.commitTitle() }
                    .onExitCommand { model.cancelTitleEdit() }
                    .accessibilityLabel("Meeting title")
                Button("Save") { model.commitTitle() }
                    .buttonStyle(AppLinkButtonStyle())
                Button("Cancel") { model.cancelTitleEdit() }
                    .buttonStyle(AppLinkButtonStyle())
            }
        } else {
            Button { model.beginTitleEdit() } label: {
                Text(title)
                    .font(AppFont.pageTitle)
                    .foregroundColor(Palette.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Rename this meeting")
            .accessibilityLabel("Rename meeting, \(title)")
        }
    }

    @ViewBuilder
    private func copyButton(_ meta: NoteMeta) -> some View {
        let notes = model.detailTab == .summary && assistant.summary != nil
        Button(model.justCopied ? "Copied" : "Copy") {
            if notes { model.copyNotes(meta.id) } else { model.copy(meta.id) }
        }
        .buttonStyle(AppSecondaryButtonStyle())
        .disabled(model.detailTab == .summary ? assistant.summary == nil : turns.isEmpty)
        .help(notes ? "Copies the notes" : "Copies the transcript with speakers and times")
    }

    // MARK: Failure

    private func retryLine(_ kind: RetryKind) -> String {
        switch kind {
        case .notes: return "The audio is kept on this Mac so you can try again. Deleting the note deletes it too."
        case .summary: return "The transcript is saved."
        case .deleteAudio: return "The audio of this meeting is still on this Mac. Delete it again, or delete the note."
        case .none: return "There's nothing to try again from. Delete the note to remove it."
        }
    }

    private func failedNotice(_ meta: NoteMeta, _ f: NoteFailure) -> some View {
        AppNotice {
            VStack(alignment: .leading, spacing: 2) {
                Text("These notes couldn't be finished")
                    .font(AppFont.bodyMedium)
                    .foregroundColor(Palette.ink)
                Text(f.message)
                    .font(AppFont.caption)
                    .foregroundColor(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Text(retryLine(f.retry))
                    .font(AppFont.caption)
                    .foregroundColor(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if f.retry == .notes {
                Button("Try again") { model.retry(meta.id) }
                    .buttonStyle(AppPrimaryButtonStyle())
                    .disabled(model.session != nil)
            } else if f.retry == .deleteAudio {
                Button("Delete audio") { model.retry(meta.id) }
                    .buttonStyle(AppPrimaryButtonStyle())
                    .disabled(model.session != nil)
            }
        }
    }

    // MARK: Transcript

    @ViewBuilder
    private func transcript(_ meta: NoteMeta) -> some View {
        if turns.isEmpty {
            let isFailed: Bool = {
                if case .failed = meta.state { return true }
                return false
            }()
            Text(isFailed ? "No transcript was saved." : "No transcript yet.")
                .font(AppFont.body)
                .foregroundColor(Palette.muted)
        } else {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(Array(turns.enumerated()), id: \.offset) { index, t in
                    turnRow(t, meta)
                        .background(highlight(index))
                        .id(index)
                }
            }
        }
    }

    /// The row a citation jumped to: a faint tint a little wider than the text, so the text does not move.
    @ViewBuilder
    private func highlight(_ index: Int) -> some View {
        if assistant.highlightedTurn == index {
            RoundedRectangle(cornerRadius: 8)
                .fill(Palette.ink.opacity(0.06))
                .padding(-8)
        }
    }

    private func speakersRow(_ meta: NoteMeta) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(meta.speakers, id: \.key) { s in
                    chip(s, meta)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func chipLabel(_ name: String, auto: Bool) -> some View {
        Text(name)
            .font(AppFont.caption)
            .foregroundColor(Palette.ink)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .overlay(chipBorder(auto: auto))
            .contentShape(Capsule())
            .fixedSize()
    }

    @ViewBuilder
    private func chipBorder(auto: Bool) -> some View {
        if auto {
            Capsule().strokeBorder(Palette.ink.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        } else {
            Capsule().strokeBorder(Palette.ink.opacity(0.18), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func chip(_ s: NoteSpeaker, _ meta: NoteMeta) -> some View {
        let name = NotesLogic.displayName(s.key, in: meta.speakers)
        let auto = NotesDoc.nameSource(s) == .auto
        if s.key == NotesLogic.youKey {
            chipLabel(name, auto: false)
        } else if model.renamingKey == s.key {
            renameEditor(s, name: name, auto: auto)
        } else if auto {
            Button { model.beginRename(s.key) } label: { chipLabel(name, auto: true) }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Suggested from the meeting. Click to rename or clear.")
                .accessibilityLabel("\(name), suggested. Rename")
        } else {
            Button { model.beginRename(s.key) } label: { chipLabel(name, auto: false) }
                .buttonStyle(.plain)
                .pointerCursor()
                .accessibilityLabel("Rename \(name)")
        }
    }

    private func renameEditor(_ s: NoteSpeaker, name: String, auto: Bool) -> some View {
        HStack(spacing: 8) {
            TextField(NotesLogic.defaultName(s.key), text: $model.renameDraft)
                .textFieldStyle(.plain)
                .font(AppFont.caption)
                .padding(.horizontal, 12)
                .frame(width: 150, height: 26)
                .background(Capsule().fill(Palette.field))
                .overlay(Capsule().strokeBorder(Palette.ink.opacity(0.28), lineWidth: 1))
                .onSubmit { model.commitRename() }
                .onExitCommand { model.cancelRename() }
                .accessibilityLabel("New name for \(name)")
            Button("Save") { model.commitRename() }
                .buttonStyle(AppLinkButtonStyle())
            if auto {
                Button("Clear") { model.clearSuggestedName(s.key) }
                    .buttonStyle(AppLinkButtonStyle())
                    .help("Back to \(NotesLogic.defaultName(s.key))")
            }
            Button("Cancel") { model.cancelRename() }
                .buttonStyle(AppLinkButtonStyle())
        }
    }

    private func turnRow(_ t: TranscriptTurn, _ meta: NoteMeta) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(NotesLogic.displayName(t.speaker, in: meta.speakers))
                    .font(AppFont.speaker)
                    .foregroundColor(Palette.ink)
                Text(NotesLogic.timestamp(t.start))
                    .font(AppFont.caption)
                    .foregroundColor(Palette.muted)
            }
            .frame(width: 124, alignment: .leading)
            Text(t.text)
                .font(AppFont.body)
                .foregroundColor(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    // MARK: Summary and Ask

    private func offCard(title: String, body: String) -> some View {
        AppCard {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(AppFont.bodyMedium)
                    .foregroundColor(Palette.ink)
                Text(body)
                    .font(AppFont.caption)
                    .foregroundColor(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Settings") { model.openKeySettings?() }
                    .buttonStyle(AppSecondaryButtonStyle())
                    .padding(.top, 6)
            }
            .padding(.horizontal, AppMetrics.rowH)
            .padding(.vertical, AppMetrics.rowV)
        }
    }
}
