import SwiftUI

/// Text with times that jump to the transcript row they point at. One helper for the summary, the action items
/// and the answers, so a citation looks and behaves the same everywhere. The times are links with a private
/// scheme, caught by `openURL` and sent to the assistant; nothing is ever opened outside the app.
struct CitedText: View {
    let assistant: NoteAssistant
    var prefix: String?
    let segments: [NotesAI.AnswerSegment]
    var font: Font = AppFont.body
    var prefixFont: Font = AppFont.bodyMedium

    init(assistant: NoteAssistant, prefix: String? = nil, _ segments: [NotesAI.AnswerSegment],
         font: Font = AppFont.body, prefixFont: Font = AppFont.bodyMedium) {
        self.assistant = assistant
        self.prefix = prefix
        self.segments = segments
        self.font = font
        self.prefixFont = prefixFont
    }

    private var attributed: AttributedString {
        var out = AttributedString()
        if let prefix, !prefix.isEmpty {
            var run = AttributedString(prefix)
            run.font = prefixFont
            run.foregroundColor = Palette.ink
            out += run
        }
        var previousWasCite = false
        for segment in segments {
            switch segment {
            case .text(let s):
                var run = AttributedString(s)
                run.font = font
                run.foregroundColor = Palette.ink
                out += run
                previousWasCite = false
            case .cite(let t):
                if previousWasCite {
                    var comma = AttributedString(", ")
                    comma.font = font
                    comma.foregroundColor = Palette.ink
                    out += comma
                }
                var run = AttributedString(NotesLogic.timestamp(t))
                run.font = font
                run.foregroundColor = Palette.muted
                run.underlineStyle = .single
                run.link = URL(string: "talkflow-cite://t/\(t)")
                out += run
                previousWasCite = true
            }
        }
        return out
    }

    var body: some View {
        Text(attributed)
            .tint(Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == "talkflow-cite", let t = Double(url.lastPathComponent) {
                    assistant.jump(to: t)
                    return .handled
                }
                return .systemAction
            })
    }
}

/// The one-time "send this transcript?" card, for a summary or a question.
struct NotesConfirmCard: View {
    let provider: NotesProvider
    let onSend: () -> Void
    let onCancel: () -> Void

    var body: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 6) {
                Text(NotesAI.confirmTitle(provider))
                    .font(AppFont.bodyMedium)
                    .foregroundColor(Palette.ink)
                Text(NotesAI.confirmBody(provider))
                    .font(AppFont.caption)
                    .foregroundColor(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Send to \(provider.name)", action: onSend)
                        .buttonStyle(AppPrimaryButtonStyle())
                    Button("Not now", action: onCancel)
                        .buttonStyle(AppSecondaryButtonStyle())
                }
                .padding(.top, 6)
            }
            .padding(.horizontal, AppMetrics.rowH)
            .padding(.vertical, AppMetrics.rowV)
        }
    }
}

/// A section heading as the mockup draws it: small, uppercase, spaced, muted.
struct NoteSectionHeading: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(AppFont.groupLabel)
            .tracking(0.72)
            .foregroundColor(Palette.muted)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The Summary tab with a key in use: confirmation, writing, failure, the summary, or the empty state.
struct NoteSummaryView: View {
    @ObservedObject var assistant: NoteAssistant
    let meta: NoteMeta
    let turns: [TranscriptTurn]

    var body: some View {
        if let access = assistant.currentAccess {
            VStack(alignment: .leading, spacing: 22) {
                states(access)
            }
        }
    }

    @ViewBuilder
    private func states(_ access: NotesAccess) -> some View {
        let phase = assistant.phase(for: meta.id)
        if turns.isEmpty {
            Text("There's no transcript to summarise yet.")
                .font(AppFont.body)
                .foregroundColor(Palette.muted)
        } else if assistant.pending == .summary(meta.id) {
            NotesConfirmCard(provider: access.provider, onSend: { assistant.confirmSend() },
                             onCancel: { assistant.cancelPending() })
        } else if case .writing(let step, let total) = phase {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(writingText(step: step, total: total, access: access))
                    .font(AppFont.body)
                    .foregroundColor(Palette.muted)
            }
        } else {
            if case .failed(let error, let retryAt) = phase {
                failedNotice(error, retryAt: retryAt, access: access)
            }
            if let summary = assistant.summary {
                content(summary, access: access)
            } else if case .failed = phase {
                EmptyView()
            } else {
                empty(access)
            }
        }
    }

    private func writingText(step: Int, total: Int, access: NotesAccess) -> String {
        let m = access.model.shortTitle
        if total == 1 { return "Writing the summary with \(m)..." }
        if step <= total { return "Writing the summary with \(m): part \(step) of \(total)..." }
        return "Writing the summary with \(m): putting the \(total) parts together..."
    }

    private func failedNotice(_ error: NotesAIError, retryAt: Date?, access: NotesAccess) -> some View {
        AppNotice {
            VStack(alignment: .leading, spacing: 2) {
                Text("The summary couldn't be written")
                    .font(AppFont.bodyMedium)
                    .foregroundColor(Palette.ink)
                Text(error.message(access.provider, model: access.model))
                    .font(AppFont.caption)
                    .foregroundColor(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Text("The transcript is saved.")
                    .font(AppFont.caption)
                    .foregroundColor(Palette.muted)
            }
            Spacer(minLength: 12)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Button("Try again") { assistant.writeSummary(meta.id) }
                    .buttonStyle(AppPrimaryButtonStyle())
                    .disabled(retryAt.map { context.date < $0 } ?? false)
            }
        }
    }

    private func empty(_ access: NotesAccess) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("No summary for this meeting yet.")
                .font(AppFont.body)
                .foregroundColor(Palette.muted)
            Button("Write summary") { assistant.writeSummary(meta.id) }
                .buttonStyle(AppPrimaryButtonStyle())
            Text("Sends this transcript to \(access.provider.name) with your key. The audio never leaves this Mac.")
                .font(AppFont.caption)
                .foregroundColor(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: The summary

    private func content(_ summary: NoteSummary, access: NotesAccess) -> some View {
        let writing: Bool = {
            if case .writing = assistant.phase(for: meta.id) { return true }
            return false
        }()
        return VStack(alignment: .leading, spacing: 22) {
            section("Summary") {
                CitedText(assistant: assistant, [.text(summary.summary + " ")] + summary.summaryTimes.map { .cite($0) })
            }
            section("Action items") {
                if summary.actionItems.isEmpty {
                    Text("No action items.")
                        .font(AppFont.body)
                        .foregroundColor(Palette.muted)
                } else {
                    AppCard {
                        ForEach(Array(summary.actionItems.enumerated()), id: \.offset) { i, item in
                            if i > 0 { RowDivider() }
                            actionRow(i, item)
                        }
                    }
                }
            }
            if !summary.decisions.isEmpty {
                section("Decisions") { bullets(summary.decisions) }
            }
            if !summary.openQuestions.isEmpty {
                section("Open questions") { bullets(summary.openQuestions) }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(NotesAI.disclosure(provider: summary.provider, modelID: summary.model))
                    .font(AppFont.caption)
                    .foregroundColor(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Write again") { assistant.writeSummary(meta.id) }
                    .buttonStyle(AppLinkButtonStyle())
                    .disabled(writing)
                    .help("Writes a new summary, sending the transcript again")
            }
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ body: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            NoteSectionHeading(title)
            body()
        }
    }

    private func actionRow(_ index: Int, _ item: NoteSummary.ActionItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: Binding(get: { item.done }, set: { assistant.setDone(index, $0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel("Done: \(item.task)")
            CitedText(assistant: assistant, prefix: NotesAI.ownerName(item.owner, speakers: meta.speakers) + ": ",
                      [.text(item.task + " "), .cite(item.time)])
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 44, alignment: .top)
    }

    private func bullets(_ points: [NoteSummary.Point]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(points.enumerated()), id: \.offset) { _, p in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\u{2022}")
                        .font(AppFont.body)
                        .foregroundColor(Palette.ink)
                    CitedText(assistant: assistant, [.text(p.text + " "), .cite(p.time)])
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
