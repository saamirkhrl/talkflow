import AppKit
import Foundation

/// The whole dictation pipeline.
///
/// Audio is captured while the key is held. Every ~0.7s the buffer so far is
/// transcribed and formatted and shown in the overlay caption, so you see your
/// words as you say them. On release the final transcript is rendered once,
/// fully corrected, and inserted into the focused field in one write. Nothing
/// is typed and then deleted, so there is no flicker and no correction that is
/// too long to deliver - every correction is free, because none of it has been
/// on screen yet. That is what makes it feel smooth, and it is the default.
///
/// With "type while speaking" on (Settings), the original behaviour runs
/// instead: whatever part of the transcript has stopped changing is appended
/// to the field as you speak, and the field is brought in line with the final
/// transcript at release. Everything below about the live path describes that
/// mode.
///
/// The live path is append-only, and that is the central design decision here.
/// It used to type each new transcript in full, diffing it against the screen
/// and rewriting whatever whisper had revised since the last tick - which is
/// most of the time, because whisper revises freely as more audio arrives. The
/// user saw text highlight, delete and retype on nearly every update, with words
/// mangled when a rewrite landed badly. `StreamCommit` fixes that upstream by
/// only releasing words that two consecutive transcripts agree on, so the only
/// edit a live tick can produce is an append. Corrections are deferred to the
/// single reconciliation pass at release.
///
/// Everything on screen is produced by `syncField`, which is the only thing here
/// allowed to touch the user's document. It knows exactly what this hold has
/// typed (`typedText`) and only ever rewrites the tail of that - it cannot
/// delete a character it did not put there. That property is what makes live
/// typing safe; an earlier design tracked the screen only approximately, and a
/// mismatch between what it thought it had typed and what was really there
/// destroyed a whole dictation.
///
/// No language model writes text in this path. Both local models that were
/// tried rewrote the user's words instead of editing them and were rejected by
/// their own safety check on every real transcript; removing them took ~0.3-3s
/// out of the round trip and removed the only component that could invent
/// text. The optional AI punctuation pass (`Polish`, off by default) does not
/// change that: the model only suggests, and only its punctuation, casing and
/// line breaks around words it left alone are ever used.
final class Dictation {
    private let recorder = Recorder()
    private let overlay: OverlayController
    private let statusBar: StatusBar

    private let transcribeURL = URL(string: "http://127.0.0.1:8178/inference")!
    private let minDuration: TimeInterval = 0.3

    private var isRecording = false
    private var startedAt: Date?
    private var targetAppPID: pid_t?

    /// Owns everything written to the user's document. See FieldSync.
    private let field = FieldSync()
    /// Decides which words are settled enough to type. See StreamCommit.
    private let stream = StreamCommit()
    /// The last thing the live path put on screen. Every later live update has
    /// to extend it, or it is refused - see `streamField`.
    private var lastStreamed = ""
    /// Set when the user moves to a different app mid-hold. Latching, because
    /// coming back does not make it safe to write again - see `syncField`.
    private var focusLeft = false
    /// Set once at the start of a hold and then fixed: changing it later would
    /// shift the whole string and force a rewrite from position zero.
    private var leadingSpace = ""
    /// `Preferences.typeWhileSpeaking`, fixed for the length of a hold.
    private var liveTyping = false
    /// `Preferences.writingStyle`, fixed for the length of a hold, so the live
    /// text and the release pass are written the same way.
    private var style: WritingStyle = .formal
    /// What was on screen when the key went down (see `ScreenContext`), once
    /// the background read finishes. Nil until then; everything that uses it
    /// works without it.
    private var context: ScreenContext.Snapshot?
    /// Counts holds, so a slow context read cannot land in a later one.
    private var holdNumber = 0
    /// The last dictation inserted, and where, for `Vocabulary`.
    private var lastInsert: (text: String, bundleID: String?)?

    private var previewTimer: DispatchSourceTimer?
    private var previewInFlight = false
    private let previewInterval: TimeInterval = 0.7

    init(overlay: OverlayController, statusBar: StatusBar) {
        self.overlay = overlay
        self.statusBar = statusBar
        recorder.onLevel = { [weak self] level in self?.overlay.pushLevel(level) }
    }

    func begin() {
        guard !isRecording else { return }
        isRecording = true
        startedAt = Date()
        field.reset()
        stream.reset()
        lastStreamed = ""
        focusLeft = false
        liveTyping = Preferences.typeWhileSpeaking
        style = Preferences.writingStyle
        targetAppPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        statusBar.setState(.recording)
        overlay.show()

        do {
            try recorder.start()
            // After start(): asking the focused app about its caret is an
            // Accessibility round-trip that can take a quarter second, and
            // anything done before the mic is live is speech that gets lost.
            leadingSpace = CursorContext.needsSeparatorBeforeInsertion() ? " " : ""
            startPreviewLoop()
            readContext()
            if Preferences.aiPolish, !Self.claudePolishes, !liveTyping {
                DispatchQueue.global(qos: .userInitiated).async { Polish.prewarm() }
            }
        } catch {
            print("talkflowd: could not start recording: \(error.localizedDescription)")
            isRecording = false
            statusBar.setState(.idle)
            overlay.hide()
        }
        print("talkflowd: recording started")
    }

    func finish() {
        guard isRecording else { return }
        isRecording = false
        stopPreviewLoop()

        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        startedAt = nil
        let wav = recorder.stop()

        guard duration >= minDuration else {
            print("talkflowd: hold was \(String(format: "%.2f", duration))s, discarding as an accidental tap")
            dismiss()
            return
        }

        statusBar.setState(.processing)

        transcribeFinal(wav: wav) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let result, !Transcriber.isPlaceholder(result.text) else {
                    if result != nil { print("talkflowd: no speech in \(String(format: "%.1f", duration))s of audio") }
                    self.dismiss()
                    return
                }
                // The one and only correction pass of the whole hold. Everything
                // the live path held back is added here, and anything agreement
                // committed wrongly is repaired here - this is the single edit
                // allowed to delete. Paragraph breaks are decided here too, on
                // the complete text, where inserting one costs one rewrite
                // rather than one per tick.
                var final = Self.render(result.text, leadingSpace: self.leadingSpace, structure: true, style: self.style)
                var verbatim = Self.render(result.text, leadingSpace: self.leadingSpace, structure: true, corrections: false, style: self.style)
                let detail = Self.logTranscripts ? ": \(result.text)" : ""
                print("talkflowd: transcribed \(Self.shape(of: result.text, segments: result.segments)) in \(String(format: "%.2f", result.elapsed))s\(detail)")

                // Fitted to where it lands. The casing change is skipped while
                // typing live: the first word is already on screen, and
                // recasing it would rewrite the whole dictation.
                let context = self.context
                if !self.liveTyping, ScreenContext.continuesSentence(after: context?.textBeforeCaret) {
                    final = ScreenContext.lowercasingStart(final, names: context?.names ?? [])
                }
                if ScreenContext.isChat(bundleID: context?.bundleID ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier) {
                    final = ScreenContext.chatStyled(final)
                    verbatim = ScreenContext.chatStyled(verbatim)
                }

                // The punctuation pass may put capitals back, so the style is
                // applied again to whatever it returns.
                let style = self.style
                let names = context?.names ?? []
                if !self.liveTyping, Self.claudePolishes {
                    ClaudePolish.run(final, names: names) { polished, error in
                        if let error { self.overlay.showError(error) }
                        self.deliver(style.apply(polished), verbatim: verbatim, duration: duration)
                    }
                } else if !self.liveTyping, Preferences.aiPolish {
                    Polish.run(final, names: names) { polished in
                        self.deliver(style.apply(polished), verbatim: verbatim, duration: duration)
                    }
                } else {
                    self.deliver(final, verbatim: verbatim, duration: duration)
                }
            }
        }
    }

    /// Writes the final text and closes the hold.
    private func deliver(_ final: String, verbatim: String, duration: TimeInterval) {
        reconcile(to: final, verbatim: verbatim)
        if !field.typedText.isEmpty {
            StatsStore.shared.recordSession(text: field.typedText, durationSeconds: duration)
            lastInsert = (field.typedText, NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
            scheduleVocabularyCheck()
        } else if !liveTyping, !final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Nothing was typed while speaking, so a write refused at release
            // (focus moved to another app mid-hold) would lose the whole
            // dictation. It goes on the clipboard instead.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(final.trimmingCharacters(in: .whitespaces), forType: .string)
            print("talkflowd: could not write the dictation, put it on the clipboard instead")
        }
        // A new hold started while this one was still finishing: what was just
        // written belongs to the old hold, and the new one must start from an
        // empty record or its insert would be aligned against this text.
        if isRecording, !liveTyping { field.reset() }
        // The pill goes now - the user has stopped speaking and there is
        // nothing left to visualise - but a long keystroke insert takes a
        // moment to finish landing. Stay in `.processing` until it is out, or
        // the menu bar says idle while the text is still arriving.
        overlay.hide()
        LiveType.whenDrained {
            DispatchQueue.main.async { self.statusBar.setState(.idle) }
        }
    }

    // MARK: - Context

    /// The prompt for this hold's transcriptions: names on screen and words
    /// the user has taught it, on top of the fixed vocabulary sentence.
    private var prompt: String {
        ScreenContext.prompt(names: context?.names ?? [], learned: Preferences.learnedWords)
    }

    /// Reads the screen in the background. The first live tick is 0.7s away,
    /// so the names are normally in the prompt from the first transcription.
    /// Also the second look at the last dictation, for `Vocabulary`.
    private func readContext() {
        holdNumber += 1
        context = nil
        let hold = holdNumber
        DispatchQueue.global(qos: .userInitiated).async {
            let snapshot = ScreenContext.capture()
            DispatchQueue.main.async {
                guard self.holdNumber == hold else { return }
                self.context = snapshot
                self.learn(from: snapshot)
            }
        }
    }

    /// Looks at the field again a little after a dictation, when the user has
    /// had time to fix a word in it, without waiting for the next hold.
    private func scheduleVocabularyCheck() {
        let hold = holdNumber
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            guard self.holdNumber == hold, !self.isRecording else { return }
            DispatchQueue.global(qos: .utility).async {
                let snapshot = ScreenContext.capture()
                DispatchQueue.main.async { self.learn(from: snapshot) }
            }
        }
    }

    private func learn(from snapshot: ScreenContext.Snapshot) {
        guard let last = lastInsert, last.bundleID == snapshot.bundleID, let text = snapshot.fieldText else { return }
        Vocabulary.remember(Vocabulary.fixes(inserted: last.text, fieldText: text))
    }

    /// The final transcript: the large model when it is set up and answering
    /// (see `FinalPassEngine`), small.en otherwise or if the large one fails.
    /// A failed large-model request costs one retry on the fast server, never
    /// the dictation.
    private func transcribeFinal(wav: Data, completion: @escaping (Transcriber.Result?) -> Void) {
        let prompt = self.prompt
        guard Preferences.useOpenAITranscription else {
            transcribeLocally(wav: wav, prompt: prompt, completion: completion)
            return
        }
        // With the user's own OpenAI key. Any failure is shown above the pill
        // and the dictation is transcribed on this Mac instead - a bad key or
        // a dropped connection never costs the user what they said.
        CloudTranscriber.transcribe(wav: wav, prompt: prompt) { [weak self] outcome in
            switch outcome {
            case .success(let result):
                print("talkflowd: final pass via OpenAI \(CloudTranscriber.model) in \(String(format: "%.2f", result.elapsed))s")
                completion(result)
            case .failure(let failure):
                self?.overlay.showError(failure.message + ", used this Mac instead")
                guard let self else { completion(nil); return }
                self.transcribeLocally(wav: wav, prompt: prompt, completion: completion)
            }
        }
    }

    /// Whether this hold's punctuation pass goes to Claude.
    static var claudePolishes: Bool {
        Preferences.useClaudePunctuation && APIKeys.hasKey(.anthropic)
    }

    private func transcribeLocally(wav: Data, prompt: String, completion: @escaping (Transcriber.Result?) -> Void) {
        let small = transcribeURL
        guard Preferences.accurateFinalPass, FinalPassEngine.isReady else {
            Transcriber.transcribe(wav: wav, serverURL: small, prompt: prompt, completion: completion)
            return
        }
        Transcriber.transcribe(wav: wav, serverURL: FinalPassEngine.inferenceURL, timeout: 8, prompt: prompt) { result in
            if let result {
                print("talkflowd: final pass via large-v3-turbo")
                FinalPassSpeed.record(elapsed: result.elapsed, audioSeconds: FinalPassSpeed.seconds(ofWav: wav))
                completion(result)
                return
            }
            print("talkflowd: final-pass model did not answer, falling back to small.en")
            Transcriber.transcribe(wav: wav, serverURL: small, prompt: prompt, completion: completion)
        }
    }

    /// The log used to carry every transcript verbatim, which made it a plaintext
    /// record of everything the user has ever dictated, sitting in
    /// `~/Library/Logs/talkflow/talkflow.log` indefinitely. The numbers are what
    /// diagnosis actually needs - a lost release pass shows up as a character
    /// count that does not match the edit that followed it - so those stay and
    /// the words do not.
    ///
    /// Set `talkflow_LOG_TRANSCRIPTS=1` in the LaunchAgent to put the text back
    /// while chasing a bug that needs it.
    static let logTranscripts = ProcessInfo.processInfo.environment["talkflow_LOG_TRANSCRIPTS"] == "1"

    /// Size and structure of a transcript, with none of its content.
    static func shape(of text: String, segments: Int = 1) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        return "\(text.count) chars / \(words) words" + (segments > 1 ? " / \(segments) segments" : "")
    }

    /// Ends a hold without inserting anything further. Whatever is already on
    /// screen stays - it is the user's text now.
    func abandon() {
        guard isRecording else { return }
        isRecording = false
        stopPreviewLoop()
        _ = recorder.stop()
        dismiss()
    }

    /// Transcript -> what should be on screen. Deterministic and cheap, so the
    /// live preview and the final pass run the identical function; that keeps the
    /// two in agreement and makes the last update a small diff rather than a
    /// wholesale rewrite.
    /// `structure` is off for live updates. The email greeting and sign-off
    /// matches flicker in and out as words arrive, so a break decided mid-hold
    /// moves; it is decided once, at the end, when the whole text is known.
    /// A spoken "new paragraph" is different and stays live - it lands at the
    /// tail, where an append can carry it, with nothing after it to disturb.
    ///
    /// `corrections` (default: same as `structure`) collapses spoken
    /// self-corrections, stutters and hedges - see `SelfCorrection`. Never live:
    /// a correction deletes words that are already on screen, and a live update
    /// may only append. The release pass renders with it off as well, as the
    /// fallback when the corrected text costs too much to deliver.
    static func render(_ transcript: String, leadingSpace: String, structure: Bool, corrections: Bool? = nil, style: WritingStyle = .formal) -> String {
        let tidied = Cleanup.tidy(transcript)
        let commanded = TextCommands.applyAll(tidied)
        let withCommands = (corrections ?? structure) ? SelfCorrection.apply(to: commanded) : commanded
        // Live: only the greeting break, which is final as soon as it is typed.
        // Release: sign-off, then lists. The email pass goes first so the list
        // pass sees the greeting and sign-off as their own paragraphs and never
        // swallows the sign-off into the last item.
        let structured = structure
            ? ListFormat.apply(to: StructurePolish.punctuateSignOff(StructurePolish.apply(to: withCommands)))
            : StructurePolish.apply(to: withCommands, signOff: false)
        // Capitalisation runs last, once the paragraph breaks are actually in the
        // string. Run earlier and the body after "Dear Sarah,\n\n" keeps whatever
        // case whisper gave it - which is how "can you please" and "best Samir"
        // ended up lowercase at the start of their paragraphs.
        let cased = style.apply(TextCommands.capitalizeAfterSentenceEnds(structured))
        return cased.isEmpty ? "" : leadingSpace + cased
    }

    // MARK: - Screen

    /// How many key events a destructive rewrite may cost before it is refused.
    ///
    /// A keystroke rewrite deletes text the user can see and then retypes it, and
    /// nothing in the pipeline can prove the retype arrived. When it doesn't, the
    /// user is left with the start of their dictation, a hole, and the tail -
    /// which is the bug this number exists to stop. The larger the burst, the
    /// likelier a drop, so past a point the correction is not worth what it
    /// risks: the words already on screen are the user's words, and whisper's
    /// second opinion on punctuation is not worth losing them for.
    ///
    /// 160 events is roughly a 60-character rewrite plus its retype, and it is
    /// deliberately conservative. The real ceiling for Terminal and the Electron
    /// apps has never been measured - `--stresstest` measures it. Raise this when
    /// there is a number, not before.
    private static let correctionEventBudget = 160

    /// The release pass, split by risk.
    ///
    /// Adding the words the live path held back is a pure append. It has never
    /// been on screen, so no write path can destroy anything by delivering it
    /// badly, and it always runs.
    ///
    /// Correcting words that are already on screen is the opposite: it deletes
    /// text the user is looking at and retypes it. Via Accessibility that is one
    /// atomic, verified call and size is irrelevant. Via keystrokes it is one
    /// droppable event per character, so it runs only while it is small enough to
    /// trust.
    ///
    /// `verbatim` is the same render without `SelfCorrection`. A spoken
    /// correction deletes words, which shifts every later word index, and the
    /// append is word-aligned with what the live path typed - which never had
    /// corrections applied. Aligned to `final`, "Friday, wait no," going missing
    /// would make the append skip three words. So the append is aligned to
    /// `verbatim`, and `verbatim` is also the fallback when the corrected text
    /// costs more than can be delivered.
    private func reconcile(to final: String, verbatim: String) {
        // Corrections entirely in the tail that was never shown (and any short
        // hold, where nothing was shown): the corrected text is itself a pure
        // append, so the false start never reaches the screen at all.
        if final.hasPrefix(field.typedText) {
            if final != field.typedText { syncField(to: final) }
            return
        }

        if let appended = FieldSync.appendOnlyTarget(current: field.typedText, final: verbatim),
           appended != field.typedText {
            syncField(to: appended)
        }

        let plan = Self.correctionTarget(screen: field.typedText, corrected: final, verbatim: verbatim, via: field.lastOutcome)
        if let note = plan.note { print("talkflowd: \(note)") }
        if let target = plan.target { syncField(to: target) }
    }

    /// Which text the correction half of the release pass should write, if any.
    /// The corrected render when it can be delivered; otherwise the uncorrected
    /// one, so a self-correction too far back to afford does not also cost the
    /// user the sign-off break or a repaired word near the end; otherwise
    /// nothing, and the words on screen stay as they are. Pure, so
    /// `--streamtest` pins it.
    static func correctionTarget(screen: String, corrected: String, verbatim: String, via outcome: FieldSync.Outcome) -> (target: String?, note: String?) {
        guard screen != corrected else { return (nil, nil) }
        let full = FieldSync.edit(from: screen, to: corrected)
        if correctionIsAffordable(deleting: full.deleting, inserting: full.inserting, via: outcome) { return (corrected, nil) }

        let fullCost = "-\(full.deleting) +\(full.inserting.count) = \(eventCost(deleting: full.deleting, inserting: full.inserting)) keystroke events"
        guard corrected != verbatim else {
            return (nil, "refused the correction pass, \(fullCost) is more than can be delivered reliably; the dictation stays as it was spoken")
        }
        guard screen != verbatim else {
            return (nil, "skipped a self-correction, \(fullCost) is more than can be delivered reliably; the false start stays")
        }
        let rest = FieldSync.edit(from: screen, to: verbatim)
        if correctionIsAffordable(deleting: rest.deleting, inserting: rest.inserting, via: outcome) {
            return (verbatim, "skipped a self-correction, \(fullCost) is more than can be delivered reliably; applied the rest of the release pass")
        }
        return (nil, "refused the correction pass including a self-correction, \(fullCost) is more than can be delivered reliably; the dictation stays as it was spoken")
    }

    /// What a rewrite costs in key events: one per deleted character, one per
    /// chunk of the replacement.
    static func eventCost(deleting: Int, inserting: String) -> Int {
        deleting + LiveType.chunked(inserting).count
    }

    /// Whether the correction half of the release pass is worth what it risks.
    /// Pure, so the rule is pinned by `--streamtest` rather than left to a
    /// comment - it is the rule that decides whether a dictation can be lost.
    static func correctionIsAffordable(deleting: Int, inserting: String, via outcome: FieldSync.Outcome) -> Bool {
        // One atomic call that reads back what it replaced. Length is irrelevant
        // and there is nothing to drop.
        if outcome == .accessibility { return true }
        return eventCost(deleting: deleting, inserting: inserting) <= correctionEventBudget
    }

    /// The only way the live path is allowed to write. Refuses anything that is
    /// not a pure extension of what it last put on screen.
    ///
    /// StreamCommit already guarantees this by construction; the guard is here
    /// so that the guarantee does not depend on that being true. FieldSync will
    /// happily delete back to the first differing character, so a single bug
    /// upstream would put the flashing, mangling rewrites straight back. Nothing
    /// mid-hold may ever delete.
    private func streamField(to desired: String) {
        guard desired.hasPrefix(lastStreamed) else {
            print("talkflowd: refused a live update that was not an append")
            return
        }
        lastStreamed = desired
        syncField(to: desired)
    }

    /// Brings the focused field in line with `desired`.
    private func syncField(to desired: String) {
        guard !focusLeft else { return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetAppPID else {
            // Focus moved. Stop writing for the rest of this hold, including the
            // pass at release.
            //
            // This used to forget what had been typed and carry on. If focus
            // came back, `typedText` was empty, so the next update looked like a
            // first insertion and retyped the whole dictation at wherever the
            // caret now was - the text duplicated. That was survivable while
            // most apps took the atomic Accessibility path; now that every app
            // measured takes the keystroke path, it would be hundreds of key
            // events into a document at an unknown position. Whatever is already
            // on screen stays, and the words spoken from here on are lost, which
            // is the failure worth having.
            focusLeft = true
            let now = NSWorkspace.shared.frontmostApplication?.localizedName ?? "another app"
            print("talkflowd: focus left the target app for \(now), stopped writing for this hold")
            field.reset()
            return
        }
        let before = field.typedText
        let edit = FieldSync.edit(from: before, to: desired)
        let outcome = field.sync(to: desired)
        // Logged on every write, not only on failure. When the app looked
        // completely dead in Slack, Discord and Terminal the log could not say
        // which path had been taken or whether one had been taken at all, and
        // the whole question is which apps accept which kind of write.
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
        if case let .refused(reason) = outcome {
            print("talkflowd: refused to rewrite \(app) [-\(edit.deleting) +\(edit.inserting.count)], \(reason); the field keeps what it has")
            return
        }
        print("talkflowd: wrote via \(outcome.rawValue) into \(app) [-\(edit.deleting) +\(edit.inserting.count)]")
    }

    private func dismiss() {
        statusBar.setState(.idle)
        overlay.hide()
    }

    // MARK: - Live preview

    /// The caption's solid and dimmed halves. Whisper can revise words that
    /// already settled; when the newest transcript no longer starts with them,
    /// all of it is shown dimmed rather than showing words it has taken back.
    /// Pure, for `--streamtest`.
    static func captionParts(committed: String, rendered: String) -> (settled: String, pending: String) {
        let trimmed = rendered.drop(while: \.isWhitespace)
        let settled = committed.drop(while: \.isWhitespace)
        guard trimmed.hasPrefix(settled) else { return ("", String(trimmed)) }
        return (String(settled), String(trimmed.dropFirst(settled.count)))
    }

    private func startPreviewLoop() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + previewInterval, repeating: previewInterval)
        timer.setEventHandler { [weak self] in self?.tickPreview() }
        previewTimer = timer
        timer.resume()
    }

    private func stopPreviewLoop() {
        previewTimer?.cancel()
        previewTimer = nil
    }

    /// Only one request is ever in flight: each one re-transcribes the whole
    /// buffer, so a queue of them would be stale by the time it drained and would
    /// also delay the final pass behind it.
    ///
    /// `snapshotWAV()` always covers the whole recording, and `Recorder` offers no
    /// way to ask for less. StreamCommit compares this transcript against the
    /// previous one word by word, so it has to be a transcript of the same thing
    /// every time - transcribing only the recent audio would shift every index
    /// against what is already committed.
    private func tickPreview() {
        guard isRecording, !previewInFlight, recorder.durationSeconds >= 0.5 else { return }
        previewInFlight = true

        Transcriber.transcribe(wav: recorder.snapshotWAV(), serverURL: transcribeURL, timeout: 5, prompt: prompt) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.previewInFlight = false
                guard self.isRecording, let result, !Transcriber.isPlaceholder(result.text) else { return }
                // A discarded tick (no speech, or a failed request) must leave
                // the committer untouched, or the next transcript would be
                // compared against nothing and half of it would commit at once.
                let rendered = Self.render(result.text, leadingSpace: self.leadingSpace, structure: false, style: self.style)
                guard self.liveTyping else {
                    // Caption only. StreamCommit still runs, to tell the words
                    // that have settled from the ones whisper may revise.
                    _ = self.stream.advance(rendered)
                    let (settled, pending) = Self.captionParts(committed: self.stream.committed, rendered: rendered)
                    self.overlay.showCaption(settled: settled, pending: pending)
                    return
                }
                guard let settled = self.stream.advance(rendered) else { return }
                self.streamField(to: settled)
            }
        }
    }
}
