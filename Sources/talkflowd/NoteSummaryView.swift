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
    /// Times in a run are written as " (0:19, 0:27)" after the text, in muted punctuation.
    var parenthesized = false

    init(assistant: NoteAssistant, prefix: String? = nil, _ segments: [NotesAI.AnswerSegment],
         font: Font = AppFont.body, prefixFont: Font = AppFont.bodyMedium, parenthesized: Bool = false) {
        self.assistant = assistant
        self.prefix = prefix
        self.segments = segments
        self.font = font
        self.prefixFont = prefixFont
        self.parenthesized = parenthesized
    }

    private func run(_ s: String, _ color: Color) -> AttributedString {
        var out = AttributedString(s)
        out.font = font
        out.foregroundColor = color
        return out
    }

    private func cite(_ t: Double) -> AttributedString {
        var out = run(NotesLogic.timestamp(t), Palette.muted)
        out.underlineStyle = .single
        out.link = URL(string: "talkflow-cite://t/\(t)")
        return out
    }

    private var attributed: AttributedString {
        var out = AttributedString()
        if let prefix, !prefix.isEmpty {
            var lead = AttributedString(prefix)
            lead.font = prefixFont
            lead.foregroundColor = Palette.ink
            out += lead
        }
        var previousWasCite = false
        for segment in segments {
            switch segment {
            case .text(let s):
                if previousWasCite && parenthesized { out += run(")", Palette.muted) }
                out += run(s, Palette.ink)
                previousWasCite = false
            case .cite(let t):
                if previousWasCite {
                    out += parenthesized ? run(", ", Palette.muted) : run(", ", Palette.ink)
                } else if parenthesized {
                    out += run(" (", Palette.muted)
                }
                out += cite(t)
                previousWasCite = true
            }
        }
        if previousWasCite && parenthesized { out += run(")", Palette.muted) }
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
        return NotesDocumentView(assistant: assistant, meta: meta, summary: summary, writing: writing,
                                 onWriteAgain: { assistant.writeSummary(meta.id) })
    }
}

/// The meeting's written notes as a document: Summary, Decisions, Details, Suggested next steps, then Write again.
/// Shown with a key (with Write again) and without one (saved notes, read only).
struct NotesDocumentView: View {
    @ObservedObject var assistant: NoteAssistant
    let meta: NoteMeta
    /// Speaker references ("{{s2}}") already resolved to the current names, so a rename or Clear shows at once.
    let summary: NoteSummary
    var writing = false
    var onWriteAgain: (() -> Void)?

    init(assistant: NoteAssistant, meta: NoteMeta, summary: NoteSummary, writing: Bool = false,
         onWriteAgain: (() -> Void)? = nil) {
        _assistant = ObservedObject(wrappedValue: assistant)
        self.meta = meta
        self.summary = NotesDoc.resolving(summary, speakers: meta.speakers)
        self.writing = writing
        self.onWriteAgain = onWriteAgain
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            summarySection
            decisionsSection
            detailsSection
            stepsSection
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func docSection<C: View>(_ title: String, @ViewBuilder _ body: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(AppFont.docHeading)
                .foregroundColor(Palette.ink)
                .accessibilityAddTraits(.isHeader)
            body()
        }
    }

    private func statusTag(_ label: String) -> some View {
        Text(label)
            .font(AppFont.small)
            .foregroundColor(Palette.muted)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .overlay(Capsule().strokeBorder(Palette.ink.opacity(0.18), lineWidth: 1))
            .fixedSize()
    }

    private var summarySection: some View {
        docSection("Summary") {
            CitedText(assistant: assistant, [.text(summary.summary)] + summary.summaryTimes.map { .cite($0) },
                      parenthesized: true)
        }
    }

    @ViewBuilder
    private var decisionsSection: some View {
        let decisions = NotesDoc.decisions(summary)
        if !decisions.isEmpty {
            docSection("Decisions") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(decisions.enumerated()), id: \.offset) { _, p in
                        decisionRow(p)
                    }
                }
            }
        }
    }

    private func decisionRow(_ p: NoteSummary.Point) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            statusTag(DecisionStatus.of(p.status).label)
            CitedText(assistant: assistant, [.text(p.text), .cite(p.time)], parenthesized: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var detailsSection: some View {
        let details = NotesDoc.details(summary)
        if !details.isEmpty {
            docSection("Details") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(details.enumerated()), id: \.offset) { _, d in
                        detailRow(d)
                    }
                }
            }
        }
    }

    private func detailRow(_ d: NoteSummary.Detail) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\u{2022}")
                .font(AppFont.body)
                .foregroundColor(Palette.ink)
            CitedText(assistant: assistant, prefix: d.topic + ": ",
                      [.text(d.text)] + d.times.map { .cite($0) }, parenthesized: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var stepsSection: some View {
        docSection("Suggested next steps") {
            if summary.actionItems.isEmpty {
                Text("No suggested next steps.")
                    .font(AppFont.body)
                    .foregroundColor(Palette.muted)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(summary.actionItems.enumerated()), id: \.offset) { i, item in
                        stepRow(i, item)
                    }
                }
            }
        }
    }

    private func stepRow(_ index: Int, _ item: NoteSummary.ActionItem) -> some View {
        let owner = item.owner.isEmpty ? nil : NotesAI.ownerName(item.owner, speakers: meta.speakers) + ": "
        return HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(get: { item.done }, set: { assistant.setDone(index, $0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel("Done: \(item.task)")
            CitedText(assistant: assistant, prefix: owner, [.text(item.task), .cite(item.time)], parenthesized: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let onWriteAgain {
            Button("Write again", action: onWriteAgain)
                .buttonStyle(AppLinkButtonStyle())
                .disabled(writing)
                .help("Writes a new summary, sending the transcript again")
        }
    }
}
