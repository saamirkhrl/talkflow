import SwiftUI

/// The Ask tab of a meeting: the conversation in its own scroll view, and under it the input, which is not in
/// the scroll view and so never moves while the conversation scrolls.
struct NoteAskPage: View {
    @ObservedObject var model: NotesModel
    @ObservedObject var assistant: NoteAssistant
    let meta: NoteMeta
    let turns: [TranscriptTurn]
    /// True in the live window (fills the height left under the header); false in snapshots (a fixed height).
    let scrolls: Bool

    var body: some View {
        VStack(spacing: 0) {
            if model.keyInUse, let access = assistant.currentAccess {
                conversationScroll(access)
            } else {
                Spacer(minLength: 0)
            }
            Rectangle().fill(Palette.hairline).frame(height: 1)
            VStack(alignment: .leading, spacing: 8) {
                inputRow
                if model.keyInUse, let access = assistant.currentAccess { footnotes(access) }
            }
            .frame(maxWidth: 780, alignment: .leading)
            .padding(.horizontal, AppMetrics.pageSide)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.window)
        }
        .frame(maxWidth: .infinity)
        .frame(height: scrolls ? nil : 440)
        .frame(maxHeight: scrolls ? .infinity : nil)
    }

    private var busy: Bool { assistant.asking != nil || assistant.pending != nil }

    private var draftEmpty: Bool {
        assistant.askDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() { assistant.ask() }

    /// The id of the newest message, which the conversation scrolls to.
    private var lastID: String? {
        if case .ask? = assistant.pending { return "pending" }
        if assistant.askFailure != nil { return "failure" }
        if assistant.asking != nil { return "asking" }
        if assistant.questions.isEmpty { return nil }
        return "q\(assistant.questions.count - 1)"
    }

    // MARK: Input

    @ViewBuilder
    private var inputRow: some View {
        if model.keyInUse {
            keyedInput
        } else {
            HStack(spacing: 10) {
                Text("Add an API key to ask about this meeting.")
                    .font(AppFont.body)
                    .foregroundColor(Palette.muted)
                Spacer(minLength: 12)
                Button("Open Settings") { model.openKeySettings?() }
                    .buttonStyle(AppSecondaryButtonStyle())
            }
        }
    }

    private var keyedInput: some View {
        HStack(alignment: .center, spacing: 10) {
            TextField("Ask about this meeting", text: $assistant.askDraft)
                .textFieldStyle(.plain)
                .font(AppFont.body)
                .foregroundColor(Palette.ink)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 8).fill(Palette.field))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.ink.opacity(0.28), lineWidth: 1))
                .disabled(busy)
                .onSubmit { if !busy && !draftEmpty { send() } }
                .accessibilityLabel("Ask about this meeting")
            Button("Ask") { send() }
                .buttonStyle(AppPrimaryButtonStyle(height: 36))
                .disabled(busy || draftEmpty)
        }
    }

    private func footnotes(_ access: NotesAccess) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(NotesAI.askFooter(access))
                .font(AppFont.caption)
                .foregroundColor(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            // Computed once per body, the same way the client builds the transcript it sends.
            if let hint = NotesAI.askCostHint(lines: NotesAI.transcriptLines(turns, speakers: meta.speakers)) {
                Text(hint)
                    .font(AppFont.caption)
                    .foregroundColor(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Scrolling conversation

    private func conversationScroll(_ access: NotesAccess) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) { conversation(access) }
                    .frame(maxWidth: 780, alignment: .leading)
                    .padding(.horizontal, AppMetrics.pageSide)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: lastID) { _ in scrollToBottom(proxy) }
            .onChange(of: assistant.partialAnswer) { _ in scrollToBottom(proxy) }
            .onAppear { DispatchQueue.main.async { scrollToBottom(proxy) } }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let id = lastID else { return }
        proxy.scrollTo(id, anchor: .bottom)
    }

    // MARK: Conversation

    @ViewBuilder
    private func conversation(_ access: NotesAccess) -> some View {
        ForEach(Array(assistant.questions.enumerated()), id: \.offset) { index, entry in
            VStack(alignment: .leading, spacing: 12) {
                questionBubble(entry.question)
                VStack(alignment: .leading, spacing: 6) {
                    answerBubble {
                        CitedText(assistant: assistant, NotesAI.parseAnswer(entry.answer, turns: turns).segments)
                    }
                    Text(NotesAI.disclosure(provider: entry.provider, modelID: entry.model))
                        .font(AppFont.caption)
                        .foregroundColor(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .id("q\(index)")
        }
        if let q = assistant.asking {
            VStack(alignment: .leading, spacing: 12) {
                questionBubble(q)
                answerBubble {
                    if assistant.partialAnswer.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Writing the answer...")
                                .font(AppFont.body)
                                .foregroundColor(Palette.muted)
                        }
                    } else {
                        CitedText(assistant: assistant, NotesAI.parseAnswer(assistant.partialAnswer, turns: turns).segments)
                    }
                }
            }
            .id("asking")
        }
        if let f = assistant.askFailure {
            VStack(alignment: .leading, spacing: 12) {
                questionBubble(f.question)
                failedNotice(f, access: access)
            }
            .id("failure")
        }
        if case .ask(let q) = assistant.pending {
            VStack(alignment: .leading, spacing: 12) {
                questionBubble(q)
                NotesConfirmCard(provider: access.provider, onSend: { assistant.confirmSend() },
                                 onCancel: { assistant.cancelPending() })
            }
            .id("pending")
        }
    }

    private func questionBubble(_ text: String) -> some View {
        BubbleWidth(fraction: 0.8, trailing: true) {
            Text(text)
                .font(AppFont.body)
                .foregroundColor(Palette.window)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 14).fill(Palette.ink))
        }
    }

    private func answerBubble<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        BubbleWidth(fraction: 0.9, trailing: false) {
            content()
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 14).fill(Palette.card))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.cardStroke, lineWidth: 1))
        }
    }

    private func failedNotice(_ f: NoteAssistant.AskFailure, access: NotesAccess) -> some View {
        AppNotice {
            VStack(alignment: .leading, spacing: 2) {
                Text("This question couldn't be answered")
                    .font(AppFont.bodyMedium)
                    .foregroundColor(Palette.ink)
                Text(f.error.message(access.provider, model: access.model))
                    .font(AppFont.caption)
                    .foregroundColor(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Button("Try again") { assistant.retryAsk() }
                    .buttonStyle(AppPrimaryButtonStyle())
                    .disabled(f.retryAt.map { context.date < $0 } ?? false)
            }
        }
    }
}

/// Lets a chat bubble take the width its text needs, up to a share of the row, and sits it at one edge (the
/// question on the right, the answer on the left). SwiftUI has no "at most 80 percent" modifier on macOS 13.
private struct BubbleWidth<Content: View>: View {
    let fraction: CGFloat
    let trailing: Bool
    let content: Content

    init(fraction: CGFloat, trailing: Bool, @ViewBuilder content: () -> Content) {
        self.fraction = fraction
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        BubbleLayout(fraction: fraction, trailing: trailing) { content }
    }
}

private struct BubbleLayout: Layout {
    var fraction: CGFloat
    var trailing: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let width = proposal.width ?? child.sizeThatFits(.unspecified).width
        let size = child.sizeThatFits(ProposedViewSize(width: width * fraction, height: nil))
        return CGSize(width: width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let size = child.sizeThatFits(ProposedViewSize(width: bounds.width * fraction, height: nil))
        let x = trailing ? bounds.maxX - size.width : bounds.minX
        child.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                    proposal: ProposedViewSize(width: size.width, height: size.height))
    }
}
