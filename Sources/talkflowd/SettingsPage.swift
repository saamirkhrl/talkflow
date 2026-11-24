import AppKit
import SwiftUI

/// The Settings page's state. An ObservableObject rather than `@State`,
/// which is a macro in this SDK and needs Xcode's macro plugins to build.
final class SettingsModel: ObservableObject {
    @Published var typeWhileSpeaking = Preferences.typeWhileSpeaking {
        didSet { Preferences.typeWhileSpeaking = typeWhileSpeaking }
    }
    @Published var accurateFinalPass = Preferences.accurateFinalPass {
        didSet {
            Preferences.accurateFinalPass = accurateFinalPass
            environment.accurateFinalPassChanged(accurateFinalPass)
        }
    }
    @Published var aiPolish = Preferences.aiPolish {
        didSet { Preferences.aiPolish = aiPolish }
    }
    let polishAvailable = Polish.isAvailable
    @Published var aiCorrections = Preferences.aiCorrections { didSet { Preferences.aiCorrections = aiCorrections } }
    var correctionsAvailable: Bool { polishAvailable || (useClaude && hasAnthropicKey) }
    /// Whether AI corrections would run on Claude rather than on this Mac: only
    /// without Apple Intelligence, with Claude punctuation on (Dictation.correct
    /// picks `.claude` when `CorrectionModel.isAvailable` is false). The words
    /// then go to Anthropic in a second, billed request, so the switch says so.
    var correctionsUseClaude: Bool { !polishAvailable && useClaude && hasAnthropicKey }

    @Published var writingStyle = Preferences.writingStyle {
        didSet { if Preferences.writingStyle != writingStyle { Preferences.writingStyle = writingStyle } }
    }
    /// Takes effect from the next hold; the live model follows once it is
    /// downloaded (`LiveModel`).
    @Published var language = Preferences.language {
        didSet {
            guard Preferences.language != language else { return }
            Preferences.language = language
            environment.languageChanged()
        }
    }
    /// The multilingual model's download, as `LiveModel` reports it.
    @Published var liveModelProgress = LiveModel.progress
    @Published var liveModelFailure = LiveModel.failure
    @Published var useOpenAI = Preferences.useOpenAITranscription {
        didSet { Preferences.useOpenAITranscription = useOpenAI }
    }
    @Published var useClaude = Preferences.useClaudePunctuation {
        didSet { Preferences.useClaudePunctuation = useClaude }
    }
    @Published var claudeModel = Preferences.claudeModel {
        didSet { Preferences.claudeModel = claudeModel }
    }
    /// "Use my key for meeting notes". Off until the user flips it: saving a key
    /// does not turn it on, because sending a transcript away is its own decision.
    @Published var useKeyForNotes = Preferences.notesUseKey {
        didSet {
            Preferences.notesUseKey = useKeyForNotes
            // Lets a running summary or question stop now, not only refuse its next send.
            NotificationCenter.default.post(name: NotesAccess.changed, object: nil)
        }
    }
    @Published var notesAnthropicModel = SettingsModel.storedNotesModel(Preferences.notesAnthropicModel, .anthropic) {
        didSet { Preferences.notesAnthropicModel = notesAnthropicModel.rawValue }
    }
    @Published var notesOpenAIModel = SettingsModel.storedNotesModel(Preferences.notesOpenAIModel, .openAI) {
        didSet { Preferences.notesOpenAIModel = notesOpenAIModel.rawValue }
    }
    /// Anthropic when that key is saved, otherwise OpenAI (the same rule as NotesAccess.resolve).
    var notesProvider: NotesProvider? { hasAnthropicKey ? .anthropic : (hasOpenAIKey ? .openAI : nil) }

    /// The stored model id when it belongs to this provider, else that provider's default.
    static func storedNotesModel(_ id: String?, _ p: NotesProvider) -> NotesAIModel {
        if let id, let m = NotesAIModel(rawValue: id), m.provider == p { return m }
        return NotesAIModel.defaultModel(for: p)
    }

    /// The keys held to dictate. Takes effect from the next hold.
    @Published var hotkey = Preferences.hotkey {
        didSet { if Preferences.hotkey != hotkey { Preferences.hotkey = hotkey } }
    }
    /// Waiting for the user to press the keys for a new shortcut.
    @Published var recordingHotkey = false
    @Published var hasOpenAIKey: Bool
    @Published var hasAnthropicKey: Bool
    @Published var openAIDraft = ""
    @Published var anthropicDraft = ""
    /// What happened the last time a key was saved, per provider: nil while
    /// nothing has, otherwise (is it an error, message).
    @Published var keyStatus: [String: (error: Bool, text: String)] = [:]
    @Published var checking: Set<String> = []
    /// The step the uninstaller is on, once the user has confirmed it.
    @Published var uninstallStep: String?

    let environment: SettingsEnvironment
    private var styleObserver: NSObjectProtocol?
    private var finalPassObserver: NSObjectProtocol?
    private var liveModelObserver: NSObjectProtocol?

    init(environment: SettingsEnvironment = .live) {
        self.environment = environment
        hasOpenAIKey = environment.hasKey(.openAI)
        hasAnthropicKey = environment.hasKey(.anthropic)
        // Turned off by talkflow itself when the large model proves too slow.
        finalPassObserver = NotificationCenter.default.addObserver(forName: .accurateFinalPassChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.accurateFinalPass != Preferences.accurateFinalPass else { return }
            self.accurateFinalPass = Preferences.accurateFinalPass
        }
        // The menu bar menu can change the style while this page is open.
        styleObserver = NotificationCenter.default.addObserver(forName: .writingStyleChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.writingStyle != Preferences.writingStyle else { return }
            self.writingStyle = Preferences.writingStyle
        }
        liveModelObserver = NotificationCenter.default.addObserver(forName: .liveModelChanged, object: nil, queue: .main) { [weak self] _ in
            self?.liveModelProgress = LiveModel.progress
            self?.liveModelFailure = LiveModel.failure
        }
    }

    func refresh() {
        writingStyle = Preferences.writingStyle
        hotkey = Preferences.hotkey
        // Setup can change it too.
        language = Preferences.language
    }

    /// The presets, plus the current shortcut when it was recorded.
    var hotkeyChoices: [HotkeySpec] {
        HotkeySpec.presets.contains(hotkey) ? HotkeySpec.presets : HotkeySpec.presets + [hotkey]
    }

    /// Recording needs the key listener, which runs once setup has the permissions.
    var canRecordHotkey: Bool { HotkeyMonitor.shared.isRunning }

    func recordHotkey() {
        recordingHotkey = true
        HotkeyMonitor.shared.record { [weak self] spec in
            guard let self else { return }
            self.recordingHotkey = false
            if let spec { self.hotkey = spec }
        }
    }

    func cancelHotkeyRecording() {
        guard recordingHotkey else { return }
        HotkeyMonitor.shared.cancelRecording()
    }

    /// The models this Mac will actually use for the next dictation, given
    /// the settings and what is installed. The large model is loaded only
    /// while dictating, so it counts once it is downloaded.
    var modelsInUse: [(role: String, model: String)] {
        let live = SpeechEngine.liveModelPath == SpeechEngine.multilingualModelPath ? "Whisper small (multilingual), on this Mac" : "Whisper small.en, on this Mac"
        let local = FinalPassEngine.modelIsComplete && accurateFinalPass ? "Whisper large-v3-turbo, on this Mac" : live
        let final = useOpenAI && hasOpenAIKey ? "OpenAI \(CloudTranscriber.model), your key" : local
        let punctuation: String
        if useClaude && hasAnthropicKey { punctuation = "\(claudeModel.title), your key" }
        else if aiPolish && polishAvailable { punctuation = "Apple Intelligence, on this Mac" }
        else { punctuation = "Built-in rules only" }
        let corrections: String
        if !aiCorrections { corrections = "Built-in rules only" }
        else if polishAvailable { corrections = "Apple Intelligence, on this Mac" }
        else if correctionsUseClaude { corrections = "\(CorrectionModel.claudeModelTitle), your key" }
        else { corrections = "Built-in rules only" }
        let notes: String
        if useKeyForNotes, let provider = notesProvider {
            let picked = provider == .anthropic ? notesAnthropicModel : notesOpenAIModel
            notes = "\(picked.shortTitle), your key"
        } else { notes = "Transcript only, on this Mac" }
        return [("Live caption", live), ("Final text", final), ("Punctuation", punctuation), ("Corrections", corrections), ("Meeting notes", notes)]
    }

    /// Checks the key with the provider, and keeps it only if it works.
    func saveKey(_ provider: APIKeys.Provider) {
        let draft = (provider == .openAI ? openAIDraft : anthropicDraft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else { return }
        checking.insert(provider.rawValue)
        keyStatus[provider.rawValue] = nil
        environment.validateKey(provider, draft) { error in
            DispatchQueue.main.async {
                self.checking.remove(provider.rawValue)
                if let error {
                    self.keyStatus[provider.rawValue] = (true, error)
                    return
                }
                guard self.environment.saveKey(draft, provider) else {
                    self.keyStatus[provider.rawValue] = (true, "Could not save the key to the Keychain")
                    return
                }
                self.keyStatus[provider.rawValue] = (false, self.environment.isPreview ? "Saved for this preview only. Not in your Keychain." : "Saved.")
                if provider == .openAI { self.openAIDraft = ""; self.hasOpenAIKey = true; self.useOpenAI = true }
                else { self.anthropicDraft = ""; self.hasAnthropicKey = true; self.useClaude = true }
            }
        }
    }

    func removeKey(_ provider: APIKeys.Provider) {
        environment.removeKey(provider)
        keyStatus[provider.rawValue] = (false, "Key removed.")
        if provider == .openAI { hasOpenAIKey = false; useOpenAI = false }
        else {
            hasAnthropicKey = false; useClaude = false
            // Without Apple Intelligence, corrections ran only through Claude. Left on, a
            // key added later (which turns Claude punctuation back on) would quietly start
            // sending the words to Anthropic for corrections again.
            if !polishAvailable { aiCorrections = false }
        }
        NotificationCenter.default.post(name: NotesAccess.changed, object: nil)
    }

    func uninstall() {
        guard let run = environment.uninstall else { return }
        run { [weak self] step in self?.uninstallStep = step }
    }

    /// Whether this environment offers uninstalling (not in a preview).
    var canUninstall: Bool { environment.uninstall != nil }

    /// The "Try again" link after a failed model download.
    func retryLiveModel() { environment.languageChanged() }

    func revealData() { NSWorkspace.shared.activateFileViewerSelecting([UserData.directory]) }
}

/// The Settings page: how dictation is written, in four groups of rows.
/// Every setting takes effect from the next hold. Each row is a title and
/// its control, with a line under the title saying what it does, then
/// another for anything the user must know before changing it (a download,
/// a missing requirement). Side effects all go through `model.environment`.
struct SettingsPage: View {
    @ObservedObject var window: AppWindowModel
    @ObservedObject var model: SettingsModel
    @ObservedObject var updater: Updater
    var scrolls = true

    var body: some View {
        ScrollViewReader { proxy in
            AppPage(maxWidth: 760, scrolls: scrolls) {
                VStack(alignment: .leading, spacing: 26) {
                    Text("Settings").font(AppFont.pageTitle).foregroundColor(Palette.ink)
                    jumpLinks(proxy)
                    group(.general) {
                        shortcutRow
                        RowDivider()
                        languageRow
                        RowDivider()
                        styleRow
                    }
                    group(.dictation) {
                        // Experimental and off by default: the binding reads off while
                        // no model is available, so the switch never looks on when it
                        // cannot run.
                        // Says where the words go: on this Mac, or to Anthropic with the user's key, and which Claude model.
                        toggleRow("AI corrections (experimental)",
                                  help: "When you change your mind mid-sentence, tries to remove the words you took back. Never adds or changes a word, but can sometimes remove one you meant."
                                      + (model.polishAvailable ? " Runs on this Mac with Apple Intelligence."
                                         : model.correctionsUseClaude ? " Uses \(CorrectionModel.claudeModelTitle) with your Anthropic key, whichever model punctuation uses: your words are sent to Anthropic and billed to your account."
                                         : " Needs Apple Intelligence."),
                                  isOn: Binding(get: { model.aiCorrections && model.correctionsAvailable },
                                                set: { model.aiCorrections = $0 }))
                            .disabled(!model.correctionsAvailable)
                        RowDivider()
                        toggleRow("Type while speaking",
                                  help: "Type words as you speak instead of when you let go.",
                                  isOn: $model.typeWhileSpeaking)
                        RowDivider()
                        toggleRow("Accurate final pass",
                                  help: "More accurate, a little slower. Uses about 800 MB more memory while you dictate."
                                      + (FinalPassEngine.modelIsComplete ? "" : " Downloads 574 MB once."),
                                  isOn: $model.accurateFinalPass)
                        RowDivider()
                        toggleRow("AI punctuation",
                                  help: "Apple Intelligence fixes punctuation on this Mac. Never changes your words."
                                      + (model.polishAvailable ? "" : " Needs Apple Intelligence."),
                                  isOn: $model.aiPolish)
                            .disabled(!model.polishAvailable)
                    }
                    group(.models) {
                        modelsInUseRow
                        RowDivider()
                        jobHeader("Transcription", detail: "Turns your voice into words.")
                        keyRow(.openAI, placeholder: "sk-...", draft: $model.openAIDraft, saved: model.hasOpenAIKey)
                        RowDivider()
                        toggleRow("Use my OpenAI key for transcription", medium: false,
                                  help: "Audio for the final text goes to OpenAI. Billed to your account.",
                                  isOn: $model.useOpenAI)
                            .disabled(!model.hasOpenAIKey)
                        RowDivider()
                        jobHeader("Punctuation", detail: "Adds commas, periods and capitals. Never changes your words.")
                        keyRow(.anthropic, placeholder: "sk-ant-...", draft: $model.anthropicDraft, saved: model.hasAnthropicKey)
                        RowDivider()
                        toggleRow("Use my Anthropic key for punctuation", medium: false,
                                  help: "Claude does this in place of AI punctuation. Billed to your account." + (!model.polishAvailable && model.aiCorrections ? " With AI corrections on, \(CorrectionModel.claudeModelTitle) also does those, in a second billed request." : ""),
                                  isOn: $model.useClaude)
                            .disabled(!model.hasAnthropicKey)
                        if model.useClaude && model.hasAnthropicKey {
                            RowDivider()
                            claudeModelRow
                        }
                        RowDivider()
                        jobHeader("Meeting notes", detail: "Writes a summary and action items for each meeting, and answers questions about it. Uses the Anthropic key above if there is one, otherwise the OpenAI key.")
                        toggleRow("Use my key for meeting notes", medium: false, help: notesHelp, isOn: $model.useKeyForNotes)
                            .disabled(model.notesProvider == nil)
                        if model.useKeyForNotes, let provider = model.notesProvider {
                            RowDivider()
                            notesModelRow(provider)
                        }
                    }
                    group(.about) {
                        updatesRow
                        RowDivider()
                        dataRow
                        RowDivider()
                        uninstallRow
                    }
                }
            }
            // Opened on a group (the update notice opens About). Published
            // values arrive on subscribe too, so this also covers opening
            // straight onto Settings. Async: the first layout must exist.
            .onReceive(window.$settingsAnchor) { anchor in
                guard let anchor else { return }
                DispatchQueue.main.async {
                    scroll(proxy, to: anchor)
                    window.settingsAnchor = nil
                }
            }
        }
        .onDisappear { model.cancelHotkeyRecording() }
    }

    // MARK: - Layout pieces

    private func scroll(_ proxy: ScrollViewProxy, to group: SettingsGroup) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            proxy.scrollTo(group, anchor: .top)
        } else {
            withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(group, anchor: .top) }
        }
    }

    private func jumpLinks(_ proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 8) {
            ForEach(SettingsGroup.allCases, id: \.self) { group in
                Button(group.title) { scroll(proxy, to: group) }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .font(AppFont.control)
                    .foregroundColor(Palette.ink)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 32)
                    .overlay(Capsule().strokeBorder(Palette.ink.opacity(0.16), lineWidth: 1))
                    .contentShape(Capsule())
                    .accessibilityHint("Scrolls to \(group.title)")
            }
        }
    }

    private func group<Content: View>(_ group: SettingsGroup, @ViewBuilder rows: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(group.title.uppercased())
                .font(AppFont.groupLabel)
                .tracking(0.72)
                .foregroundColor(Palette.muted)
                .accessibilityAddTraits(.isHeader)
            AppCard { rows() }
        }
        .id(group)
    }

    /// `medium: false` gives the regular weight used by the key-switch rows,
    /// whose titles sit under the heavier key fields.
    private func title(_ text: String, medium: Bool = true) -> some View {
        Text(text).font(medium ? AppFont.bodyMedium : AppFont.body).foregroundColor(Palette.ink)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(AppFont.caption).foregroundColor(Palette.muted).fixedSize(horizontal: false, vertical: true)
    }

    /// One row: the title and its lines on the left, the control on the right.
    private func row<Lines: View, Control: View>(_ text: String, medium: Bool = true, @ViewBuilder lines: () -> Lines, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                title(text, medium: medium)
                lines()
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.horizontal, AppMetrics.rowH)
        .padding(.vertical, AppMetrics.rowV)
    }

    /// One switch row: the title, a line saying what the switch does (`help`,
    /// also the tooltip), which already carries any note the user must read
    /// before flipping it (a download, a missing requirement).
    private func toggleRow(_ text: String, medium: Bool = true, help: String, isOn: Binding<Bool>) -> some View {
        row(text, medium: medium, lines: { note(help) }, control: {
            Toggle(text, isOn: isOn).toggleStyle(AppToggleStyle())
        })
        .help(help)
    }

    // MARK: - General

    private var shortcutRow: some View {
        row("Shortcut", lines: {
            note("Hold these keys, speak, let go.")
            if model.recordingHotkey {
                note("Hold the new keys, then let go. Esc cancels.")
            } else if model.hotkey.usesFn && Permissions.fnKeyHasSystemAction {
                Button("Globe key opens emoji? Set it to Do Nothing") { Permissions.openKeyboardSettings() }
                    .buttonStyle(AppLinkButtonStyle())
                    .help("In Keyboard settings, set \"Press the globe key to\" to \"Do Nothing\".")
            }
        }, control: {
            if model.recordingHotkey {
                Button("Cancel") { model.cancelHotkeyRecording() }
                    .buttonStyle(AppSecondaryButtonStyle())
            } else {
                HStack(spacing: 10) {
                    Picker("", selection: $model.hotkey) {
                        ForEach(model.hotkeyChoices, id: \.self) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .help("Hold \(model.hotkey.name), speak, let go.")
                    .accessibilityLabel("Shortcut")
                    Button("Record...") { model.recordHotkey() }
                        .buttonStyle(AppSecondaryButtonStyle())
                        .disabled(!model.canRecordHotkey)
                        .help(model.canRecordHotkey
                              ? "Hold any keys (Fn, Control, Option, Shift or Command) to use them instead."
                              : "Finish setup first.")
                }
            }
        })
    }

    private var languageRow: some View {
        row("Language", lines: {
            note(model.language.detail)
            if let progress = model.liveModelProgress {
                note("Downloading the speech model for this language, \(Int(progress * 100))%.")
            } else if model.language.needsMultilingualModel, !SpeechEngine.multilingualModelIsComplete {
                if let failure = model.liveModelFailure {
                    note("Download failed: \(failure)")
                    Button("Try again") { model.retryLiveModel() }
                        .buttonStyle(AppLinkButtonStyle())
                } else {
                    note("Downloads 190 MB once.")
                }
            }
            note(DictationLanguage.moreComing)
        }, control: {
            AppSegmented(label: "Language", options: DictationLanguage.allCases, title: { $0.title }, selection: $model.language)
                .help(model.language.detail)
        })
    }

    private var styleRow: some View {
        row("Writing style", lines: {
            note(styleNote(model.writingStyle))
        }, control: {
            AppSegmented(label: "Writing style", options: WritingStyle.allCases, title: { $0.title }, selection: $model.writingStyle)
                .help(styleNote(model.writingStyle))
        })
    }

    /// The mockup's "Formal: capitals and full stops." form.
    private func styleNote(_ style: WritingStyle) -> String {
        "\(style.title): \(style.detail.prefix(1).lowercased())\(style.detail.dropFirst())"
    }

    // MARK: - Models and API keys

    private var modelsInUseRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.modelsInUse, id: \.role) { item in
                HStack(spacing: 8) {
                    Text(item.role).font(AppFont.caption).foregroundColor(Palette.muted).frame(width: 90, alignment: .leading)
                    Text(item.model).font(.system(size: 12, weight: .medium)).foregroundColor(Palette.ink)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .padding(.horizontal, AppMetrics.rowH)
        .padding(.vertical, AppMetrics.rowV)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Heads the key and switch for one job, so it is clear each key does a
    /// different one: OpenAI's turns speech into words, Anthropic's punctuates
    /// them (and, on a Mac without Apple Intelligence, also does AI corrections
    /// when that is on). The third, meeting notes, uses whichever key is saved.
    private func jobHeader(_ name: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(AppFont.bodyMedium).foregroundColor(Palette.ink)
            note(detail)
        }
        .padding(.horizontal, AppMetrics.rowH)
        .padding(.top, AppMetrics.rowV)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The key stays a real SecureField so Cmd+V pastes through the Edit menu.
    private func keyRow(_ provider: APIKeys.Provider, placeholder: String, draft: Binding<String>, saved: Bool) -> some View {
        let busy = model.checking.contains(provider.rawValue)
        let status = model.keyStatus[provider.rawValue]
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(provider.name).font(.system(size: 12, weight: .medium)).foregroundColor(Palette.ink).frame(width: 70, alignment: .leading)
                SecureField(saved ? "Saved" : placeholder, text: draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .frame(height: AppMetrics.controlHeight)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Palette.field))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.ink.opacity(0.28), lineWidth: 1))
                    .onSubmit { model.saveKey(provider) }
                    .help("Optional. Stored in your Keychain.")
                    .accessibilityLabel("\(provider.name) API key")
                Button(busy ? "Checking..." : "Use key") { model.saveKey(provider) }
                    .buttonStyle(AppSecondaryButtonStyle())
                    .disabled(busy || draft.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
                if saved {
                    Button("Remove") { model.removeKey(provider) }
                        .buttonStyle(AppSecondaryButtonStyle())
                }
            }
            if let status {
                Text(status.text)
                    .font(AppFont.small)
                    .foregroundColor(status.error ? Palette.warn : Palette.muted)
                    .padding(.leading, 78)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var claudeModelRow: some View {
        row("Claude model", lines: { EmptyView() }, control: {
            Picker("", selection: $model.claudeModel) {
                ForEach(ClaudePolish.Model.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Claude model")
        })
    }

    private var notesHelp: String {
        guard let p = model.notesProvider else { return "Add an Anthropic or OpenAI key above to turn this on." }
        return "Each summary and question sends the meeting's transcript to \(p.name), billed to your account. The audio never leaves this Mac."
    }

    private func notesModelRow(_ p: NotesProvider) -> some View {
        let selection = Binding<NotesAIModel>(
            get: { p == .anthropic ? model.notesAnthropicModel : model.notesOpenAIModel },
            set: { if p == .anthropic { model.notesAnthropicModel = $0 } else { model.notesOpenAIModel = $0 } })
        return row("Notes model", lines: { EmptyView() }, control: {
            Picker("", selection: selection) {
                ForEach(NotesAIModel.models(for: p), id: \.self) { Text($0.pickerTitle).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Model for meeting notes")
        })
    }

    // MARK: - About

    private var updatesRow: some View {
        let state = window.updateOverride ?? updater.state
        let v = Updater.currentVersion
        let live = window.updatesEnabled && window.updateOverride == nil
        let preview = "Not available in a preview."
        return row("Updates", lines: {
            switch state {
            case .idle, .upToDate, .available, .checking, .failed:
                versionLine(state, version: v)
            case .downloading:
                note("Downloading update...")
            case .installing:
                note("Installing...")
            }
        }, control: {
            switch state {
            case .idle, .upToDate:
                Button("Check for updates") { updater.check() }
                    .buttonStyle(AppSecondaryButtonStyle())
                    .disabled(!live)
                    .help(live ? "" : preview)
            case .checking:
                Button("Checking...") {}
                    .buttonStyle(AppSecondaryButtonStyle())
                    .disabled(true)
                    .help(live ? "" : preview)
            case .available(let release):
                UpdateInstallButton(release: release, enabled: live) { updater.install() }
            case .downloading, .installing:
                EmptyView()
            case .failed:
                Button("Retry") { updater.check() }
                    .buttonStyle(AppSecondaryButtonStyle())
                    .disabled(!live)
                    .help(live ? "" : preview)
            }
        })
    }

    /// The version line; a failure shows its message in the warning colour.
    @ViewBuilder
    private func versionLine(_ state: Updater.State, version v: String) -> some View {
        switch state {
        case .idle: note("Version \(v).")
        case .checking: note("Version \(v). Checking...")
        case .upToDate: note("Version \(v). You're up to date.")
        case .available(let release): note("Version \(v). \(release.version) is available.")
        case .failed(let message):
            (Text("Version \(v). ").foregroundColor(Palette.muted) + Text(message).foregroundColor(Palette.warn))
                .font(AppFont.caption)
                .fixedSize(horizontal: false, vertical: true)
        case .downloading, .installing: EmptyView()
        }
    }

    private var dataRow: some View {
        row("Your data", lines: {
            note("Stats, settings and meeting notes live in one folder on this Mac. Meeting audio is deleted as soon as its transcript is ready.")
        }, control: {
            Button("Show in Finder") { model.revealData() }
                .buttonStyle(AppSecondaryButtonStyle())
                .help("Stats, settings, learned words and meeting notes. Kept if you uninstall.")
        })
    }

    private var uninstallRow: some View {
        row("Uninstall talkflow", lines: {
            note("Removes the app, speech models and permissions. Your data folder is kept.")
            if let step = model.uninstallStep { note(step) }
        }, control: {
            Button(model.uninstallStep == nil ? "Uninstall..." : "Uninstalling...") { model.uninstall() }
                .buttonStyle(AppSecondaryButtonStyle())
                .disabled(model.uninstallStep != nil || !model.canUninstall)
                .help(model.canUninstall
                      ? "Removes talkflow, its speech models, keys and logs. Your data stays."
                      : "Not available in a preview.")
        })
    }
}
