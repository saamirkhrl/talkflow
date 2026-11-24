import SwiftUI

/// Notes: the list of meetings, the meeting being recorded or written, and one meeting. Which one shows is the
/// model's route, so the menu bar's Stop and a closed window never lose the place.
struct NotesPage: View {
    @ObservedObject var model: NotesModel
    var scrolls = true

    var body: some View {
        switch model.route {
        case .session where model.session != nil: NoteSessionPage(model: model, scrolls: scrolls)
        case .detail: NoteDetailPage(model: model, scrolls: scrolls)
        default: NotesListPage(model: model, scrolls: scrolls)
        }
    }
}

private struct NotesListPage: View {
    @ObservedObject var model: NotesModel
    let scrolls: Bool

    var body: some View {
        let now = Date()
        AppPage(maxWidth: 820, scrolls: scrolls) {
            VStack(alignment: .leading, spacing: 24) {
                header
                if let problem = model.problem {
                    Text(problem)
                        .font(AppFont.caption)
                        .foregroundColor(Palette.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
                availabilityNotice
                ForEach(model.leftovers, id: \.id) { m in leftoverNotice(m, now: now) }
                if !model.keyInUse { keyBanner }
                meetings(now: now)
                Text("Notes are saved in your talkflow folder on this Mac. The audio is deleted as soon as the transcript is ready.")
                    .font(AppFont.caption)
                    .foregroundColor(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Header

    private var dot: some View {
        Circle().fill(Palette.recordOnFill).frame(width: 10, height: 10).accessibilityHidden(true)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Notes").font(AppFont.pageTitle).foregroundColor(Palette.ink)
                Text("Record a meeting and get the transcript, with who said what.")
                    .font(AppFont.body)
                    .foregroundColor(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if model.supportsRecording { actionButton }
        }
    }

    @ViewBuilder private var actionButton: some View {
        switch model.session?.phase {
        case .recording(let levels)?:
            Button { model.showSession() } label: {
                HStack(spacing: 10) {
                    dot
                    Text("Recording " + NotesLogic.timestamp(levels.elapsed)).monospacedDigit()
                }
            }
            .buttonStyle(AppCapsuleButtonStyle())
            .help("Back to the meeting being recorded")
        case .writing?:
            Button { model.showSession() } label: { Text("Writing notes...") }
                .buttonStyle(AppCapsuleButtonStyle())
                .help("See how the notes are coming along")
        case nil:
            Button { model.start() } label: {
                HStack(spacing: 10) {
                    dot
                    Text("Start recording")
                }
            }
            .buttonStyle(AppCapsuleButtonStyle())
            .disabled(!model.canStart)
            .help(model.startBlockedReason ?? "Records your microphone and the sound this Mac plays. Everything stays on this Mac.")
        }
    }

    // MARK: - Notices

    private func noticeText(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(AppFont.bodyMedium).foregroundColor(Palette.ink)
            Text(body)
                .font(AppFont.caption)
                .foregroundColor(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var availabilityNotice: some View {
        if !model.supportsRecording {
            AppNotice {
                noticeText("Recording needs macOS 14.2 or later", model.unsupportedMessage)
                Spacer(minLength: 0)
            }
        } else if model.session == nil, let reason = model.capture.unavailableReason {
            AppNotice {
                noticeText("Recording isn't available", reason)
                Spacer(minLength: 0)
            }
        }
    }

    private func leftoverNotice(_ m: NoteMeta, now: Date) -> some View {
        AppNotice {
            noticeText("A recording was interrupted",
                       "talkflow stopped while recording \(NotesLogic.displayTitle(m)), \(NotesLogic.dateLabel(m.started, now: now, calendar: .current)). Finish the notes from what was saved, or delete it.")
            Spacer(minLength: 12)
            Button("Finish notes") { model.finishLeftover(m.id) }
                .buttonStyle(AppPrimaryButtonStyle())
                .disabled(model.session != nil)
            Button("Delete...") { model.askAndDelete(m.id) }
                .buttonStyle(AppSecondaryButtonStyle())
        }
    }

    private var keyBanner: some View {
        AppNotice {
            noticeText("Summaries and questions need your API key",
                       "Transcripts are made on this Mac. Add an Anthropic or OpenAI key and talkflow can also write a summary and action items, and answer questions about a meeting.")
            Spacer(minLength: 12)
            Button("Add a key") { model.openKeySettings?() }
                .buttonStyle(AppSecondaryButtonStyle())
        }
    }

    // MARK: - Meetings

    @ViewBuilder private func meetings(now: Date) -> some View {
        let groups = NotesLogic.grouped(model.notes, now: now, calendar: .current)
        if groups.isEmpty {
            AppCard {
                // Only point at Start recording where there is one (macOS 14.2 and later).
                Text(model.supportsRecording
                     ? "No meetings yet. Click Start recording before a meeting and its transcript shows up here."
                     : "No meetings yet.")
                    .font(AppFont.body)
                    .foregroundColor(Palette.muted)
                    .padding(.horizontal, AppMetrics.rowH)
                    .padding(.vertical, AppMetrics.rowV)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            ForEach(groups, id: \.title) { g in
                VStack(alignment: .leading, spacing: 10) {
                    Text(g.title.uppercased())
                        .font(AppFont.groupLabel)
                        .tracking(0.72)
                        .foregroundColor(Palette.muted)
                        .accessibilityAddTraits(.isHeader)
                    AppCard {
                        ForEach(Array(g.notes.enumerated()), id: \.element.id) { i, m in
                            if i > 0 { RowDivider() }
                            row(m, now: now)
                        }
                    }
                }
            }
        }
    }

    private func row(_ m: NoteMeta, now: Date) -> some View {
        let title = NotesLogic.displayTitle(m)
        let date = NotesLogic.dateLabel(m.started, now: now, calendar: .current)
        let detail = NotesLogic.rowDetail(m)
        let detailColor: Color
        switch m.state {
        case .failed: detailColor = Palette.warn
        case .recording: detailColor = Palette.record
        default: detailColor = Palette.muted
        }
        return Button { model.open(m.id) } label: {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(AppFont.bodyMedium).foregroundColor(Palette.ink).lineLimit(1)
                    Text(date).font(AppFont.caption).foregroundColor(Palette.muted)
                }
                Spacer(minLength: 16)
                Text(detail).font(AppFont.caption).foregroundColor(detailColor)
            }
            .padding(.horizontal, AppMetrics.rowH)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityLabel("\(title), \(date), \(detail)")
    }
}
