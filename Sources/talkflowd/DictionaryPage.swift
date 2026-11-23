import SwiftUI

/// The words talkflow listens for. Read from and written to the settings
/// on this Mac only; nothing here touches the network.
final class DictionaryModel: ObservableObject {
    @Published private(set) var state: WordList.State
    @Published var draft = ""

    init() {
        state = Self.load()
    }

    var words: [String] { state.words }
    var canAdd: Bool { WordList.trimmed(draft) != nil }

    var countLabel: String {
        let count = state.words.count
        let words = count == 1 ? "1 word" : "\(count.formatted()) words"
        return count >= Vocabulary.limit ? "\(words), the most talkflow keeps. Adding one removes the oldest." : words
    }

    func source(of word: String) -> String { WordList.source(of: word, in: state) }

    func refresh() {
        let current = Self.load()
        if current != state { state = current }
    }

    /// Return in the field and the Add button.
    func add() {
        guard canAdd else { return }
        save(WordList.adding(draft, to: Self.load()))
        draft = ""
    }

    func remove(_ word: String) {
        save(WordList.removing(word, from: Self.load()))
    }

    /// Always from the stored list, which `Vocabulary.remember` may have
    /// changed since this page last read it.
    private static func load() -> WordList.State {
        WordList.State(words: Preferences.learnedWords,
                       added: Preferences.defaults.stringArray(forKey: WordList.addedKey) ?? [])
    }

    private func save(_ next: WordList.State) {
        Preferences.learnedWords = next.words
        Preferences.defaults.set(next.added, forKey: WordList.addedKey)
        state = next
    }
}

struct DictionaryPage: View {
    @ObservedObject var model: DictionaryModel
    var scrolls = true

    var body: some View {
        AppPage(maxWidth: 760, scrolls: scrolls) {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Dictionary")
                        .font(AppFont.pageTitle)
                        .foregroundColor(Palette.ink)
                    Text("Names and terms talkflow listens for. Words you fix after a dictation are added here on their own.")
                        .font(AppFont.body)
                        .foregroundColor(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                addRow
                list
            }
        }
    }

    private var addRow: some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Add a word")
                    .font(AppFont.caption)
                    .foregroundColor(Palette.muted)
                TextField("A name, product or term", text: $model.draft)
                    .textFieldStyle(.plain)
                    .font(AppFont.body)
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Palette.field))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.ink.opacity(0.28), lineWidth: 1))
                    .onSubmit { model.add() }
                    .accessibilityLabel("Add a word")
            }
            .frame(maxWidth: .infinity)
            Button("Add") { model.add() }
                .buttonStyle(AppPrimaryButtonStyle(height: 36))
                .disabled(!model.canAdd)
                .accessibilityHint("Adds the word to your Dictionary")
        }
    }

    private var list: some View {
        AppCard {
            if model.words.isEmpty {
                Text("No words yet. Words you fix after a dictation show up here.")
                    .font(AppFont.body)
                    .foregroundColor(Palette.muted)
                    .padding(.horizontal, AppMetrics.rowH)
                    .padding(.vertical, AppMetrics.rowV)
            } else {
                ForEach(model.words, id: \.self) { word in
                    row(word)
                    RowDivider()
                }
                Text(model.countLabel)
                    .font(AppFont.caption)
                    .foregroundColor(Palette.muted)
                    .padding(.horizontal, AppMetrics.rowH)
                    .padding(.vertical, 12)
            }
        }
    }

    private func row(_ word: String) -> some View {
        HStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(word)
                    .font(AppFont.bodyMedium)
                    .foregroundColor(Palette.ink)
                Text(model.source(of: word))
                    .font(AppFont.caption)
                    .foregroundColor(Palette.muted)
            }
            Spacer()
            Button {
                model.remove(word)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Palette.muted)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .accessibilityLabel("Remove \(word)")
            .help("Remove \(word)")
        }
        .padding(.leading, AppMetrics.rowH)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
    }
}
