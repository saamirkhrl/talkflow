import Foundation

/// The NotesModel state machine end to end on a temporary store, with FakeCapture and a pipeline the test
/// finishes by hand, so every transition is checked without audio, timers or a window. Called from --notestest.
enum NotesModelChecks {
    static func run(_ report: (Bool, String, String) -> Void) {
        func check(_ ok: Bool, _ label: String, _ detail: String = "") { report(ok, label, detail) }
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("talkflow-notesmodel-\(UUID().uuidString)", isDirectory: true)
        let store = NoteStore(root: root)
        let os = OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)

        func newModel(_ capture: MeetingCapture, _ pipeline: NotesPipeline, _ rec: RecordingLog) -> NotesModel {
            let m = NotesModel(store: store, capture: capture, pipeline: pipeline, os: os)
            m.confirmDelete = { true }
            m.onRecordingChange = { rec.values.append($0) }
            return m
        }
        func state(_ id: String) -> NoteState? { store.meta(id)?.state }
        func audioGone(_ id: String) -> Bool {
            !store.hasAudio(id) && !fm.fileExists(atPath: store.audioFolder(for: id).path)
        }
        func phase(_ m: NotesModel) -> String { m.session.map { "\($0.phase)" } ?? "nil" }
        func writingPhase(_ m: NotesModel, _ p: WritingProgress) -> Bool { m.session?.phase == .writing(p) }

        let recA = RecordingLog()
        let cap = FakeCapture()
        let pipe = ManualPipeline()
        let model = newModel(cap, pipe, recA)

        // M1 start
        model.start()
        let id = model.session?.noteID ?? "none"
        check(model.isRecording && model.route == .session && model.problem == nil && recA.values == [true]
              && state(id) == .recording && store.hasAudio(id) && cap.isRecording
              && model.notes.map(\.id) == [id] && model.leftovers.isEmpty,
              "M1 start begins a recording", "rec=\(recA.values) state=\(String(describing: state(id))) notes=\(model.notes.count)")

        // M2 second start while recording
        model.start()
        check(model.problem == "A meeting is already recording." && store.list().count == 1,
              "M2 a second start while recording is refused", "problem=\(model.problem ?? "nil") count=\(store.list().count)")

        // M3 stop
        model.sessionTitle = "Weekly sync"
        model.stop()
        let saving = WritingProgress(step: .saving, fraction: 1, secondsLeft: nil)
        check(recA.values == [true, false] && !cap.isRecording && writingPhase(model, saving)
              && state(id) == .writing(.saving) && store.meta(id)?.title == "Weekly sync"
              && pipe.runs == 1 && pipe.lastFolder == store.audioFolder(for: id) && !model.isRecording,
              "M3 stop hands the audio to the pipeline", "rec=\(recA.values) phase=\(phase(model)) runs=\(pipe.runs)")

        // M4 progress
        let p1 = WritingProgress(step: .transcribing, fraction: 0.5, secondsLeft: 10)
        pipe.progress(p1)
        let okTranscribing = writingPhase(model, p1) && state(id) == .writing(.transcribing)
        pipe.progress(WritingProgress(step: .speakers, fraction: 0.2, secondsLeft: 4))
        check(okTranscribing && state(id) == .writing(.speakers),
              "M4 progress updates the session and the saved step", "state=\(String(describing: state(id)))")

        // M5 start while writing
        model.start()
        check(model.problem == "Notes for the last meeting are still being written." && store.list().count == 1,
              "M5 a start while writing is refused", "problem=\(model.problem ?? "nil") count=\(store.list().count)")

        // M6 success
        pipe.complete(.finished(pieces: SampleNotes.fakePieces, duration: 40))
        check(model.session == nil && state(id) == .ready
              && store.transcript(id)?.turns == NotesLogic.transcript(from: SampleNotes.fakePieces).turns
              && audioGone(id) && model.route == .detail(id) && store.meta(id)?.duration == 40
              && store.meta(id)?.speakers.map(\.key) == ["you", "s1", "s2"] && model.notes.map(\.id).contains(id),
              "M6 success saves the transcript, deletes the audio and opens the note",
              "state=\(String(describing: state(id))) route=\(model.route) audioGone=\(audioGone(id))")

        // M7 failure keeps audio
        model.start()
        let id2 = model.session?.noteID ?? "none"
        model.stop()
        let fail2 = NoteFailure(step: .transcribing, message: "The speech engine stopped.", retry: .notes)
        pipe.complete(.failed(fail2))
        check(model.session == nil && state(id2) == .failed(fail2) && store.hasAudio(id2)
              && model.route == .detail(id2) && pipe.runs == 2,
              "M7 a failure keeps the audio and opens the note", "state=\(String(describing: state(id2))) runs=\(pipe.runs)")

        // M8 retry
        model.retry(id2)
        let okRetry = pipe.runs == 3 && model.route == .session && state(id2) == .writing(.saving)
            && model.session?.noteID == id2
        pipe.complete(.finished(pieces: SampleNotes.fakePieces, duration: 0))
        check(okRetry && state(id2) == .ready && audioGone(id2) && model.route == .detail(id2),
              "M8 retry writes the notes again from the kept audio",
              "runs=\(pipe.runs) state=\(String(describing: state(id2))) route=\(model.route)")

        // M9 failure with the audio already gone downgrades the retry
        model.start()
        let id3 = model.session?.noteID ?? "none"
        model.stop()
        store.deleteAudio(id3)
        pipe.complete(.failed(NoteFailure(step: .speakers, message: "x", retry: .notes)))
        let okDowngrade = state(id3) == .failed(NoteFailure(step: .speakers, message: "x", retry: .none))
        model.retry(id3)
        check(okDowngrade && pipe.runs == 4 && model.session == nil,
              "M9 a failure with no audio left cannot be retried", "runs=\(pipe.runs) session=\(phase(model))")

        // M10 delete
        let routeBeforeDelete = model.route
        model.delete(id3)
        check(routeBeforeDelete == .detail(id3) && store.meta(id3) == nil && !fm.fileExists(atPath: store.folder(for: id3).path)
              && model.route == .list && model.problem == nil,
              "M10 delete removes the note and leaves its screen", "before=\(routeBeforeDelete) route=\(model.route)")

        // M11 delete asks first
        model.confirmDelete = { false }
        model.askAndDelete(id2)
        check(store.meta(id2) != nil, "M11 delete asks first and keeps the note on No", "exists=\(store.meta(id2) != nil)")
        model.confirmDelete = { true }

        // M12 no delete while recording
        model.start()
        let id4 = model.session?.noteID ?? "none"
        model.delete(id4)
        let okNoDelete = model.problem == "Stop the recording before deleting it." && store.meta(id4) != nil
        model.stop()
        pipe.complete(.finished(pieces: [], duration: 0))
        check(okNoDelete && state(id4) == .ready && store.transcript(id4)?.turns.isEmpty == true,
              "M12 a recording cannot be deleted; an empty meeting still finishes",
              "problem=\(model.problem ?? "nil") state=\(String(describing: state(id4)))")

        // M13 recording stops by itself
        model.start()
        let id5 = model.session?.noteID ?? "none"
        var stopped = CaptureLevels(elapsed: 1)
        stopped.problem = "Your Mac is almost out of disk space."
        stopped.stoppedByItself = true
        cap.fixed = stopped
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        var isWriting = false
        if case .writing? = model.session?.phase { isWriting = true }
        let okSelf = isWriting && model.problem == "Your Mac is almost out of disk space." && recA.values.last == false
        cap.fixed = nil
        pipe.complete(.finished(pieces: SampleNotes.fakePieces, duration: 0))
        check(okSelf && state(id5) == .ready,
              "M13 a recording that stops by itself still becomes notes and keeps the reason",
              "phase=\(isWriting) problem=\(model.problem ?? "nil") state=\(String(describing: state(id5)))")

        // M14 start fails
        let modelT = newModel(ThrowingCapture(), ManualPipeline(), RecordingLog())
        let before = store.list().count
        modelT.start()
        check(modelT.problem == "The microphone is busy." && store.list().count == before && modelT.session == nil,
              "M14 a capture that cannot start leaves no note behind",
              "problem=\(modelT.problem ?? "nil") before=\(before) after=\(store.list().count)")

        // M15 capture unavailable
        cap.unavailableReason = "No microphone is connected."
        let beforeUnavailable = store.list().count
        model.start()
        check(model.problem == "No microphone is connected." && store.list().count == beforeUnavailable,
              "M15 an unavailable capture is explained and starts nothing", "problem=\(model.problem ?? "nil")")
        cap.unavailableReason = nil

        // M16 quit while recording leaves a leftover
        model.start()
        let id6 = model.session?.noteID ?? "none"
        model.appWillTerminate()
        check(state(id6) == .recording && !cap.isRecording && store.hasAudio(id6),
              "M16 quitting while recording keeps the note as a leftover", "state=\(String(describing: state(id6)))")

        // M17 leftover found at the next launch
        let pipeB = ManualPipeline()
        let modelB = newModel(FakeCapture(), pipeB, RecordingLog())
        modelB.refresh()
        check(modelB.leftovers.map(\.id) == [id6] && !modelB.notes.map(\.id).contains(id6),
              "M17 the next launch finds the leftover and keeps it off the list",
              "leftovers=\(modelB.leftovers.count) notes=\(modelB.notes.count)")

        // M18 Finish notes
        var repaired: [URL] = []
        modelB.repairAudio = { repaired.append($0) }
        modelB.finishLeftover(id6)
        let okFinish = repaired == [store.audioFolder(for: id6)] && pipeB.runs == 1 && modelB.route == .session
            && state(id6) == .writing(.saving)
        pipeB.complete(.finished(pieces: SampleNotes.fakePieces, duration: 12))
        check(okFinish && state(id6) == .ready && audioGone(id6) && modelB.leftovers.isEmpty
              && modelB.notes.map(\.id).contains(id6),
              "M18 Finish notes repairs the audio, runs the pipeline and completes",
              "runs=\(pipeB.runs) repaired=\(repaired.count) state=\(String(describing: state(id6)))")

        // M19 leftover that already has its transcript
        var detailOK = false
        var idT = "none"
        do {
            var m = try store.create(title: "", started: Date())
            idT = m.id
            m.state = .writing(.finishing)
            try store.save(m)
            try store.save(Transcript(turns: [TranscriptTurn(speaker: "you", start: 0, end: 1, text: "Hi")]), for: m.id)
            try Data().write(to: store.audioFolder(for: m.id).appendingPathComponent("you.wav"))
            detailOK = true
        } catch {}
        modelB.refresh()
        modelB.finishLeftover(idT)
        check(detailOK && pipeB.runs == 1 && state(idT) == .ready && audioGone(idT)
              && store.meta(idT)?.speakers.map(\.key) == ["you"] && modelB.route == .detail(idT),
              "M19 a leftover that already has its transcript is only settled",
              "setup=\(detailOK) runs=\(pipeB.runs) state=\(String(describing: state(idT)))")

        // M20 leftover with no audio
        var idN = "none"
        var setupN = false
        do {
            var m = try store.create(title: "", started: Date())
            idN = m.id
            m.state = .recording
            try store.save(m)
            setupN = true
        } catch {}
        modelB.refresh()
        modelB.finishLeftover(idN)
        check(setupN && state(idN) == .failed(NoteFailure(step: .saving, message: "No audio was saved for this meeting.", retry: .none))
              && pipeB.runs == 1,
              "M20 a leftover with no audio fails in plain words", "state=\(String(describing: state(idN))) runs=\(pipeB.runs)")

        // M21 a ready note never keeps audio
        var idR = "none"
        var setupR = false
        do {
            var m = try store.create(title: "", started: Date())
            idR = m.id
            m.state = .ready
            try store.save(m)
            try Data().write(to: store.audioFolder(for: m.id).appendingPathComponent("others.wav"))
            setupR = true
        } catch {}
        let hadAudio = store.hasAudio(idR)
        modelB.refresh()
        check(setupR && hadAudio && !store.hasAudio(idR),
              "M21 refresh removes audio left on a ready note", "had=\(hadAudio) now=\(store.hasAudio(idR))")

        // M22 quit while writing
        modelB.start()
        let idW = modelB.session?.noteID ?? "none"
        modelB.stop()
        modelB.appWillTerminate()
        check(pipeB.cancels >= 1 && state(idW) == .writing(.saving),
              "M22 quitting while writing cancels the pipeline and keeps the note for Finish notes",
              "cancels=\(pipeB.cancels) state=\(String(describing: state(idW)))")

        // M23 a failed audio deletion is shown, kept and retried. The store's remover fails while `blocked` is set.
        final class Blocker { var on = true }
        let blocker = Blocker()
        var blockedStore = NoteStore(root: root)
        blockedStore.removeItem = { url in
            if blocker.on { throw NotesError(message: "not allowed") }
            try FileManager.default.removeItem(at: url)
        }
        let pipeD = ManualPipeline()
        let modelD = NotesModel(store: blockedStore, capture: FakeCapture(), pipeline: pipeD, os: os)
        modelD.confirmDelete = { true }
        modelD.start()
        let idD = modelD.session?.noteID ?? "none"
        modelD.stop()
        pipeD.complete(.finished(pieces: SampleNotes.fakePieces, duration: 5))
        var deleteFailure: NoteFailure?
        if case .failed(let f)? = state(idD) { deleteFailure = f }
        check(deleteFailure?.retry == .deleteAudio && deleteFailure?.step == .finishing && modelD.session == nil
              && store.transcript(idD) != nil && store.hasAudio(idD),
              "audio delete fails: the note is failed with retry deleteAudio, the transcript is saved and the audio is kept",
              "state=\(String(describing: state(idD))) audio=\(store.hasAudio(idD))")

        modelD.retry(idD)
        var stillFailed = false
        if case .failed(let f)? = state(idD) { stillFailed = f.retry == .deleteAudio }
        check(stillFailed && store.hasAudio(idD) && modelD.problem == "talkflow still couldn't delete the audio. Try again, or delete the note.",
              "audio delete fails: a retry that still cannot delete says so and keeps the note failed",
              "problem=\(modelD.problem ?? "nil") state=\(String(describing: state(idD)))")

        blocker.on = false
        modelD.retry(idD)
        check(state(idD) == .ready && !store.hasAudio(idD) && store.transcript(idD) != nil && modelD.problem == nil,
              "audio delete fails: once deleting works, retry deletes the audio and the note is ready",
              "state=\(String(describing: state(idD))) audio=\(store.hasAudio(idD))")

        // M24 to M28 select and delete several notes, on their own store
        do {
            let root2 = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("talkflow-notesmodel-multi-\(UUID().uuidString)", isDirectory: true)
            let store2 = NoteStore(root: root2)
            func makeReady(_ title: String, _ offset: Double) -> String {
                guard var m = try? store2.create(title: title, started: Date(timeIntervalSince1970: 1_700_000_000 + offset))
                else { return "none" }
                m.state = .ready
                try? store2.save(m)
                return m.id
            }
            func fresh(_ pipe: ManualPipeline) -> (NotesModel, Counter) {
                let m = NotesModel(store: store2, capture: FakeCapture(), pipeline: pipe, os: os)
                let c = Counter()
                m.confirmDeleteMany = { n in c.asked.append(n); return c.answer }
                m.refresh()
                return (m, c)
            }
            let idA = makeReady("A", 0), idB = makeReady("B", 10), idC = makeReady("C", 20)
            let (mm, cnt) = fresh(ManualPipeline())
            let threeOK = Set(mm.notes.map(\.id)) == [idA, idB, idC]

            // M24 delete the ticked notes
            mm.beginSelecting(with: idA)
            mm.toggleSelected(idC)
            let ticked = mm.selected == [idA, idC] && mm.selecting
            cnt.answer = true
            mm.askAndDeleteSelected()
            check(threeOK && ticked && mm.notes.map(\.id) == [idB] && !mm.selecting && mm.selected.isEmpty
                  && cnt.asked == [2] && store2.meta(idA) == nil && store2.meta(idC) == nil && mm.problem == nil,
                  "M24 deleting the ticked notes asks once with the count, removes them and leaves select mode",
                  "notes=\(mm.notes.count) selecting=\(mm.selecting) asked=\(cnt.asked)")

            // M25 cancel keeps everything
            let idA2 = makeReady("A", 30), idC2 = makeReady("C", 40)
            mm.refresh()
            mm.beginSelecting()
            mm.toggleSelected(idA2)
            mm.toggleSelected(idC2)
            cnt.answer = false
            mm.askAndDeleteSelected()
            check(mm.notes.count == 3 && mm.selecting && mm.selected == [idA2, idC2],
                  "M25 cancelling the confirmation changes nothing and keeps the selection",
                  "notes=\(mm.notes.count) selecting=\(mm.selecting) selected=\(mm.selected.count)")

            // M26 refresh drops a selected note that is gone
            try? FileManager.default.removeItem(at: store2.folder(for: idA2))
            mm.refresh()
            check(mm.selected == [idC2] && mm.notes.count == 2,
                  "M26 refresh drops a selected note that no longer exists", "selected=\(mm.selected.count)")
            mm.endSelecting()

            // M27 the note being recorded cannot be selected or deleted
            let pipeS = ManualPipeline()
            let (ms, cntS) = fresh(pipeS)
            ms.start()
            let live = ms.session?.noteID ?? "none"
            ms.beginSelecting(with: live)
            let emptyStart = ms.selected.isEmpty
            ms.toggleSelected(live)
            let emptyToggle = ms.selected.isEmpty
            ms.selected = Set(ms.notes.map(\.id))
            let allCount = ms.selected.count
            let notesBefore = ms.notes.count
            cntS.answer = true
            ms.askAndDeleteSelected()
            check(!ms.canDelete(live) && emptyStart && emptyToggle && allCount == notesBefore && allCount >= 2
                  && cntS.asked == [allCount - 1] && store2.meta(live) != nil && ms.notes.map(\.id) == [live],
                  "M27 a recording cannot be ticked, and a delete of everything leaves it alone",
                  "asked=\(cntS.asked) notes=\(ms.notes.count)")
            ms.stop()
            pipeS.complete(.finished(pieces: [], duration: 0))

            // M28 deleting the open note leaves its screen
            let idD2 = makeReady("D", 50)
            ms.refresh()
            ms.route = .detail(idD2)
            ms.deleteMany([idD2])
            check(ms.route == .list && store2.meta(idD2) == nil,
                  "M28 deleting the open note returns to the list", "route=\(ms.route)")
            try? fm.removeItem(at: root2)
        }

        // M99 clean up
        try? fm.removeItem(at: root)
        check(!fm.fileExists(atPath: root.path), "M99 temporary notes folder removed", root.lastPathComponent)
    }
}

/// The counts a fake "delete several?" confirmation was asked with, and its answer.
private final class Counter {
    var asked: [Int] = []
    var answer = true
}

/// Collects the onRecordingChange calls of one model.
private final class RecordingLog {
    var values: [Bool] = []
}

/// Test double: remembers the callbacks so the check decides when, and how, writing ends.
private final class ManualPipeline: NotesPipeline {
    private(set) var runs = 0
    private(set) var cancels = 0
    private(set) var lastFolder: URL?
    private var progressFn: ((WritingProgress) -> Void)?
    private var completionFn: ((PipelineOutcome) -> Void)?

    func run(audioFolder: URL, progress: @escaping (WritingProgress) -> Void,
             completion: @escaping (PipelineOutcome) -> Void) {
        runs += 1
        lastFolder = audioFolder
        progressFn = progress
        completionFn = completion
    }

    func cancel() {
        cancels += 1
        progressFn = nil
        completionFn = nil
    }

    func progress(_ p: WritingProgress) { progressFn?(p) }

    /// Calls the stored completion once, then drops both callbacks, as a real pipeline completes exactly once.
    func complete(_ o: PipelineOutcome) {
        let f = completionFn
        progressFn = nil
        completionFn = nil
        f?(o)
    }
}

/// Test double: recording can't start (the capture throws).
private final class ThrowingCapture: MeetingCapture {
    var unavailableReason: String? { nil }
    var microphoneName: String { "" }
    var isRecording: Bool { false }
    func start(into folder: URL) throws { throw NotesError(message: "The microphone is busy.") }
    func levels() -> CaptureLevels { CaptureLevels() }
    func stop() -> Double { 0 }
}
