import SwiftUI

/// The Ask tab of a meeting: the conversation fills the height under the header in its own scroll view, and
/// under it one rounded question field, which is not in the scroll view and so never moves.
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
            inputBar
        }
        .frame(maxWidth: .infinity)
        .frame(height: scrolls ? nil : 440)
        .frame(maxHeight: scrolls ? .infinity : nil)
    }

    private var busy: Bool { assistant.asking != nil || assistant.pending != nil }

    private var draftEmpty: Bool {
        assistant.askDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSend: Bool { !busy && !draftEmpty }

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

    /// Pinned under the conversation, in the same column as the header.
    private var inputBar: some View {
        inputRow
            .frame(maxWidth: NoteDetailMetrics.maxWidth, alignment: .leading)
            .padding(.horizontal, AppMetrics.pageSide)
            .padding(.top, 10)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.window)
    }

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

    /// One rounded field with the send control inside its right end. Return sends.
    private var keyedInput: some View {
        HStack(spacing: 8) {
            TextField("Ask about this meeting", text: $assistant.askDraft)
                .textFieldStyle(.plain)
                .font(AppFont.body)
                .foregroundColor(Palette.ink)
                .disabled(busy)
                .onSubmit { if canSend { send() } }
                .accessibilityLabel("Ask about this meeting")
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(canSend ? Palette.window : Palette.muted)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(canSend ? Palette.ink : Palette.ink.opacity(0.08)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .pointerCursor()
            .accessibilityLabel("Send question")
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .frame(height: 40)
        .background(Capsule().fill(Palette.field))
        .overlay(Capsule().strokeBorder(Palette.ink.opacity(0.18), lineWidth: 1))
    }

    // MARK: Scrolling conversation

    private func conversationScroll(_ access: NotesAccess) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) { conversation(access) }
                    .frame(maxWidth: NoteDetailMetrics.maxWidth, alignment: .leading)
                    .padding(.horizontal, AppMetrics.pageSide)
                    .padding(.top, NoteDetailMetrics.bodyGap - NoteDetailMetrics.askClip)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, NoteDetailMetrics.askClip)
            .frame(maxHeight: .infinity)
            .onChange(of: lastID) { _ in scrollToLatest(proxy) }
            .onAppear { DispatchQueue.main.async { scrollToLatest(proxy) } }
        }
    }

    /// Brings the newest question to the top of the view (or as far as the content goes), so the question is
    /// never cut off and its answer reads down from it.
    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        guard let id = lastID else { return }
        proxy.scrollTo(id, anchor: .top)
    }

    // MARK: Conversation

    @ViewBuilder
    private func conversation(_ access: NotesAccess) -> some View {
        if lastID == nil {
            Text(emptyLine(access))
                .font(AppFont.body)
                .foregroundColor(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(Array(assistant.questions.enumerated()), id: \.offset) { index, entry in
            VStack(alignment: .leading, spacing: 14) {
                questionBubble(entry.question)
                answerText {
                    CitedText(assistant: assistant, NotesAI.parseAnswer(entry.answer, turns: turns).segments)
                }
            }
            .id("q\(index)")
        }
        if let q = assistant.asking {
            VStack(alignment: .leading, spacing: 14) {
                questionBubble(q)
                if assistant.partialAnswer.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Writing the answer...")
                            .font(AppFont.body)
                            .foregroundColor(Palette.muted)
                    }
                } else {
                    answerText {
                        CitedText(assistant: assistant, NotesAI.parseAnswer(assistant.partialAnswer, turns: turns).segments)
                    }
                }
            }
            .id("asking")
        }
        if let f = assistant.askFailure {
            VStack(alignment: .leading, spacing: 14) {
                questionBubble(f.question)
                failedNotice(f, access: access)
            }
            .id("failure")
        }
        if case .ask(let q) = assistant.pending {
            VStack(alignment: .leading, spacing: 14) {
                questionBubble(q)
                NotesConfirmCard(provider: access.provider, onSend: { assistant.confirmSend() },
                                 onCancel: { assistant.cancelPending() })
            }
            .id("pending")
        }
    }

    /// The only line on an empty Ask tab: where questions go, and (for a long meeting) that they cost more.
    private func emptyLine(_ access: NotesAccess) -> String {
        let hint = NotesAI.askCostHint(lines: NotesAI.transcriptLines(turns, speakers: meta.speakers))
        return [NotesAI.askFooter(access), hint].compactMap { $0 }.joined(separator: " ")
    }

    private func questionBubble(_ text: String) -> some View {
        BubbleWidth(fraction: 0.7, trailing: true) {
            Text(text)
                .font(AppFont.body)
                .foregroundColor(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.cardStroke, lineWidth: 1))
        }
    }

    /// An answer: plain text across the whole column, as the Summary tab reads. No bubble.
    private func answerText<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
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
