import SwiftUI

/// The Ask tab with a key in use: the questions asked so far, the one being answered, and the input.
struct NoteAskView: View {
    @ObservedObject var assistant: NoteAssistant
    let meta: NoteMeta
    let turns: [TranscriptTurn]

    var body: some View {
        if let access = assistant.currentAccess {
            VStack(alignment: .leading, spacing: 18) {
                if turns.isEmpty {
                    Text("There's no transcript to ask about yet.")
                        .font(AppFont.body)
                        .foregroundColor(Palette.muted)
                } else {
                    conversation(access)
                    input
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
        }
    }

    private var busy: Bool { assistant.asking != nil || assistant.pending != nil }

    // MARK: Conversation

    @ViewBuilder
    private func conversation(_ access: NotesAccess) -> some View {
        ForEach(Array(assistant.questions.enumerated()), id: \.offset) { _, entry in
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
        if let q = assistant.asking {
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
        if let f = assistant.askFailure {
            questionBubble(f.question)
            failedNotice(f, access: access)
        }
        if case .ask(let q) = assistant.pending {
            questionBubble(q)
            NotesConfirmCard(provider: access.provider, onSend: { assistant.confirmSend() },
                             onCancel: { assistant.cancelPending() })
        }
        if assistant.questions.isEmpty && assistant.asking == nil && assistant.askFailure == nil && assistant.pending == nil {
            Text("No questions yet.")
                .font(AppFont.body)
                .foregroundColor(Palette.muted)
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

    // MARK: Input

    private var input: some View {
        let empty = assistant.askDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Ask about this meeting")
                    .font(AppFont.caption)
                    .foregroundColor(Palette.muted)
                TextField("What are my action items?", text: $assistant.askDraft)
                    .textFieldStyle(.plain)
                    .font(AppFont.body)
                    .foregroundColor(Palette.ink)
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Palette.field))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.ink.opacity(0.28), lineWidth: 1))
                    .disabled(busy)
                    .onSubmit { if !busy && !empty { assistant.ask() } }
                    .accessibilityLabel("Ask about this meeting")
            }
            Button("Ask") { assistant.ask() }
                .buttonStyle(AppPrimaryButtonStyle(height: 44))
                .disabled(busy || empty)
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
