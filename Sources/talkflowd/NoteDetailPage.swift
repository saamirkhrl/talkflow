import AppKit
import SwiftUI

/// Spacing and widths of a meeting's page, shared by its three tabs so switching tabs moves nothing.
enum NoteDetailMetrics {
    /// The text column, on every tab.
    static let maxWidth: CGFloat = 780
    /// From the bottom of the title bar to the back row; centres the back row on the sidebar's wordmark.
    static let top: CGFloat = 18
    /// Back row to the title.
    static let titleGap: CGFloat = 8
    /// Title to the date line.
    static let dateGap: CGFloat = 3
    /// Date line (or a notice under it) to the tabs.
    static let tabsGap: CGFloat = 16
    /// Tabs to the first line of a tab's content.
    static let bodyGap: CGFloat = 20
    /// On the Ask tab, the part of `bodyGap` above the conversation's scroll view; the rest is inside it.
    static let askClip: CGFloat = 8
    /// The transcript's speaker and time column.
    static let speakerColumn: CGFloat = 112
    /// Between transcript turns.
    static let turnSpacing: CGFloat = 16
}

/// One meeting: a compact header (back, Copy and Delete; the title and date; the tabs), then Summary, Ask or Transcript. Ask is its own page:
/// the header stays and the conversation fills the rest of the window, with the input pinned under it. Without a
/// key the Summary tab shows saved notes read only, or how to add a key; a time in the notes or in an answer
/// jumps to its row in the transcript.
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
        // One reader around both layouts, so a citation clicked on the Ask page can scroll the transcript that
        // replaces it.
        ScrollViewReader { proxy in
            Group {
                if model.detailTab == .ask, let meta = model.detailMeta {
                    askLayout(meta)
                } else {
                    page
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

    private var page: some View {
        AppPage(maxWidth: NoteDetailMetrics.maxWidth, scrolls: scrolls, top: AppMetrics.titlebar + NoteDetailMetrics.top) {
            VStack(alignment: .leading, spacing: 0) {
                if let meta = model.detailMeta {
                    headerBlock(meta)
                    tabBody(meta)
                        .padding(.top, NoteDetailMetrics.bodyGap)
                } else {
                    topRow(nil)
                }
            }
        }
    }

    /// The Ask tab: the header as on every tab, but not inside a scroll view, so the Ask page gets the height that
    /// is left and scrolls only its conversation.
    private func askLayout(_ meta: NoteMeta) -> some View {
        VStack(spacing: 0) {
            headerBlock(meta)
                .frame(maxWidth: NoteDetailMetrics.maxWidth, alignment: .leading)
                .padding(.top, AppMetrics.titlebar + NoteDetailMetrics.top)
                .padding(.horizontal, AppMetrics.pageSide)
                .frame(maxWidth: .infinity, alignment: .leading)
            NoteAskPage(model: model, assistant: assistant, meta: meta, turns: turns, scrolls: scrolls)
        }
        .frame(maxHeight: scrolls ? .infinity : nil, alignment: .top)
    }

    private func scroll(_ proxy: ScrollViewProxy, to turn: Int) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            proxy.scrollTo(turn, anchor: .center)
        } else {
            withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(turn, anchor: .center) }
        }
    }

    private func headerBlock(_ meta: NoteMeta) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            topRow(meta)
            titleView(meta)
                .padding(.top, NoteDetailMetrics.titleGap)
            Text(headerLine(meta))
                .font(AppFont.caption)
                .foregroundColor(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, NoteDetailMetrics.dateGap)
            if let problem = model.problem {
                Text(problem)
                    .font(AppFont.caption)
                    .foregroundColor(Palette.warn)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
            if case .failed(let f) = meta.state {
                failedNotice(meta, f)
                    .padding(.top, 14)
            }
            AppSegmented(label: "View", options: NoteTab.allCases, title: { $0.rawValue }, selection: $model.detailTab)
                .padding(.top, NoteDetailMetrics.tabsGap)
        }
    }

    /// The first row: back to the list on the left, Copy and Delete on the right.
    private func topRow(_ meta: NoteMeta?) -> some View {
        HStack(spacing: 2) {
            AppBackLink(title: "Notes") { model.backToList() }
            Spacer(minLength: 12)
            if let meta {
                copyButton(meta)
                Button("Delete") { model.askAndDelete(meta.id) }
                    .buttonStyle(AppQuietButtonStyle())
                    .help("Deletes this note from this Mac")
                    .padding(.trailing, -10)
            }
        }
    }

    @ViewBuilder
    private func tabBody(_ meta: NoteMeta) -> some View {
        switch model.detailTab {
        case .transcript:
            transcript(meta)
        case .summary:
            summaryTab(meta)
        case .ask:
            EmptyView()
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

    @ViewBuilder
    private func titleView(_ meta: NoteMeta) -> some View {
        let title = NotesLogic.displayTitle(meta)
        if model.editingTitle {
            HStack(spacing: 10) {
                TextField("Untitled meeting", text: $model.titleDraft)
                    .textFieldStyle(.plain)
                    .font(AppFont.noteTitle)
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
                    .font(AppFont.noteTitle)
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
        .buttonStyle(AppQuietButtonStyle())
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
            LazyVStack(alignment: .leading, spacing: NoteDetailMetrics.turnSpacing) {
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

    private func turnRow(_ t: TranscriptTurn, _ meta: NoteMeta) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text(NotesLogic.displayName(t.speaker, in: meta.speakers))
                    .font(AppFont.bodyMedium)
                    .foregroundColor(Palette.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(NotesLogic.timestamp(t.start))
                    .font(AppFont.caption)
                    .foregroundColor(Palette.muted)
            }
            .frame(width: NoteDetailMetrics.speakerColumn, alignment: .leading)
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
