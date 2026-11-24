import AppKit
import SwiftUI

/// One meeting: header with Copy and Delete, then Transcript, Summary and Ask. With "Use my key for meeting
/// notes" off, Summary and Ask only say how to turn it on; with it on they show the summary and the questions
/// (NoteSummaryView, NoteAskView), and a time in either jumps to its row in the transcript.
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
            if model.keyInUse {
                NoteSummaryView(assistant: assistant, meta: meta, turns: turns)
            } else {
                offCard(title: "Summaries are off",
                        body: "Turn on 'Use my key for meeting notes' in Settings > Models and API keys and talkflow writes a summary, action items and decisions for each meeting. The transcript is sent to your provider to write them; the audio never leaves this Mac.")
            }
        case .ask:
            if model.keyInUse {
                NoteAskView(assistant: assistant, meta: meta, turns: turns)
            } else {
                offCard(title: "Questions are off",
                        body: "Turn on 'Use my key for meeting notes' in Settings > Models and API keys to ask questions about this meeting. Each question sends the transcript to your provider; the audio never leaves this Mac.")
            }
        }
    }

    private var turns: [TranscriptTurn] { model.detailTranscript?.turns ?? [] }

    // MARK: Header

    private func headerLine(_ meta: NoteMeta) -> String {
        let speakerNames = meta.speakers.map { NotesLogic.displayName($0.key, in: meta.speakers) }.joined(separator: ", ")
        let parts: [String?] = [
            NotesLogic.dateLabel(meta.started, now: Date(), calendar: .current),
            meta.duration > 0 ? NotesLogic.durationText(meta.duration) : nil,
            meta.speakers.isEmpty ? nil : speakerNames
        ]
        return parts.compactMap { $0 }.joined(separator: " \u{00B7} ")
    }

    private func header(_ meta: NoteMeta) -> some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(NotesLogic.displayTitle(meta))
                    .font(AppFont.pageTitle)
                    .foregroundColor(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(headerLine(meta))
                    .font(AppFont.caption)
                    .foregroundColor(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                Button(model.justCopied ? "Copied" : "Copy") { model.copy(meta.id) }
                    .buttonStyle(AppSecondaryButtonStyle())
                    .disabled(turns.isEmpty)
                    .help("Copies the transcript with speakers and times")
                Button("Delete...") { model.askAndDelete(meta.id) }
                    .buttonStyle(AppSecondaryButtonStyle())
                    .help("Deletes this note from this Mac")
            }
        }
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
            VStack(alignment: .leading, spacing: 18) {
                speakersRow(meta)
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(turns.enumerated()), id: \.offset) { index, t in
                        turnRow(t, meta)
                            .background(highlight(index))
                            .id(index)
                    }
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
        HStack(spacing: 8) {
            Text("Speakers:")
                .font(AppFont.caption)
                .foregroundColor(Palette.muted)
            ForEach(meta.speakers, id: \.key) { s in
                chip(s, meta)
            }
        }
    }

    @ViewBuilder
    private func chip(_ s: NoteSpeaker, _ meta: NoteMeta) -> some View {
        let name = NotesLogic.displayName(s.key, in: meta.speakers)
        if s.key == NotesLogic.youKey {
            Text("You")
                .font(AppFont.caption)
                .foregroundColor(Palette.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .overlay(Capsule().strokeBorder(Palette.ink.opacity(0.22), lineWidth: 1))
        } else if model.renamingKey == s.key {
            HStack(spacing: 8) {
                TextField(NotesLogic.defaultName(s.key), text: $model.renameDraft)
                    .textFieldStyle(.plain)
                    .font(AppFont.caption)
                    .padding(.horizontal, 12)
                    .frame(width: 160, height: 28)
                    .background(Capsule().fill(Palette.field))
                    .overlay(Capsule().strokeBorder(Palette.ink.opacity(0.28), lineWidth: 1))
                    .onSubmit { model.commitRename() }
                    .accessibilityLabel("New name for \(name)")
                Button("Save") { model.commitRename() }
                    .buttonStyle(AppLinkButtonStyle())
                Button("Cancel") { model.cancelRename() }
                    .buttonStyle(AppLinkButtonStyle())
            }
        } else {
            Button { model.beginRename(s.key) } label: {
                Text("\(name) \u{00B7} Rename")
                    .font(AppFont.caption)
                    .foregroundColor(Palette.ink)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 28)
                    .overlay(Capsule().strokeBorder(Palette.ink.opacity(0.22), lineWidth: 1))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .accessibilityLabel("Rename \(name)")
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
            .frame(width: 96, alignment: .leading)
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
