import AppKit
import Foundation

/// The whole dictation pipeline.
///
/// Audio is captured while the key is held. Every ~0.7s the buffer so far is
/// transcribed and formatted, and whatever part of it has stopped changing is
/// appended to the focused text field, so the words appear where you are typing
/// as you say them. On release the final transcript is rendered the same way and
/// the field is brought in line with it in one pass.
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
/// There is no LLM anywhere in this path. Both local models that were tried
/// rewrote the user's words instead of editing them and were rejected by their
/// own safety check on every real transcript; removing them took ~0.3-3s out of
/// the round trip and removed the only component that could invent text.
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

        Transcriber.transcribe(wav: wav, serverURL: transcribeURL) { [weak self] result in
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
                let final = Self.render(result.text, leadingSpace: self.leadingSpace, structure: true)
                print("talkflowd: transcribed in \(String(format: "%.2f", result.elapsed))s: \(result.text)")
                self.syncField(to: final)
                if !self.field.typedText.isEmpty {
                    StatsStore.shared.recordSession(text: self.field.typedText, durationSeconds: duration)
                }
                self.dismiss()
            }
        }
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
    static func render(_ transcript: String, leadingSpace: String, structure: Bool) -> String {
        let tidied = Cleanup.tidy(transcript)
        let withCommands = TextCommands.applyAll(tidied)
        let structured = structure ? StructurePolish.apply(to: withCommands) : withCommands
        // Capitalisation runs last, once the paragraph breaks are actually in the
        // string. Run earlier and the body after "Dear Sarah,\n\n" keeps whatever
        // case whisper gave it - which is how "can you please" and "best Samir"
        // ended up lowercase at the start of their paragraphs.
        let cased = TextCommands.capitalizeAfterSentenceEnds(structured)
        return cased.isEmpty ? "" : leadingSpace + cased
    }

    // MARK: - Screen

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
        print("talkflowd: wrote via \(outcome.rawValue) into \(app) [-\(edit.deleting) +\(edit.inserting.count)]")
    }

    private func dismiss() {
        statusBar.setState(.idle)
        overlay.hide()
    }

    // MARK: - Live preview

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
    /// `snapshotWAV()` is deliberately called with no `lastSeconds` limit.
    /// StreamCommit compares this transcript against the previous one word by
    /// word, so it has to be a transcript of the same thing every time -
    /// transcribing only the recent audio would shift every index against what
    /// is already committed. 60s of speech transcribes in ~1.5s, so the whole
    /// buffer is affordable for a hold of any realistic length.
    private func tickPreview() {
        guard isRecording, !previewInFlight, recorder.durationSeconds >= 0.5 else { return }
        previewInFlight = true

        Transcriber.transcribe(wav: recorder.snapshotWAV(), serverURL: transcribeURL, timeout: 5) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.previewInFlight = false
                guard self.isRecording, let result, !Transcriber.isPlaceholder(result.text) else { return }
                // A discarded tick (no speech, or a failed request) must leave
                // the committer untouched, or the next transcript would be
                // compared against nothing and half of it would commit at once.
                let rendered = Self.render(result.text, leadingSpace: self.leadingSpace, structure: false)
                guard let settled = self.stream.advance(rendered) else { return }
                self.streamField(to: settled)
            }
        }
    }
}
