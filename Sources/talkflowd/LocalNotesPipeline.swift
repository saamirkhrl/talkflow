import Foundation

// The after-Stop pipeline: echo cleanup, speaker turns, cutting, transcription with recovery, the transcript echo
// rule and assembly into pieces. Everything runs on this Mac. Logs hold counts, durations and categories only,
// never transcript text, prompts or names.

struct NotesJobConfig {
    var serverBinary: String?
    var model: URL
    var port: Int
    var speakerHelper: URL?
    var speakerModels: URL
    var prompt: String
    var language: String
    var englishRules: Bool
    /// True while a dictation hold or its final pass is under way: no new piece is started then (transcription
    /// spike RESULTS.md 4: a dictation during notes is 2.7x slower otherwise). Called from the job's thread.
    var shouldPause: () -> Bool
    /// Keep copies of the tracks for NotesDebugKeeper (the hidden notesKeepDebugData preference).
    var keepDebug = false
}

struct NotesJobStats {
    /// "headphones" | "noEcho" | "open" | "noAudio"
    var echoGate = "noAudio"
    var lagSamples: Double?
    var driftPPM: Double?
    /// "fluidaudio" | "none"
    var speakerEngine = "none"
    var speakerReason: String?
    var speakerCount = 0
    var piecesYou = 0
    var piecesOthers = 0
    var retries = 0
    var splits = 0
    var dropped = 0
    var inaudible = 0
    /// Seconds the near-end gate zeroed as echo only (0 when it was not applied). Not seconds of near-end speech.
    var nearEndZeroedSeconds = 0.0
    /// The recording's echo leakage (EchoResidue.leakage) in dB, and the frames it was measured on (10 ms each).
    var leakageDB: Double?
    var echoActiveSeconds = 0.0
    /// Speech regions of the microphone track and the residue rule's decision for each (empty when it did not run).
    var regions: [EchoRegionDecision] = []
    var residueDroppedSeconds = 0.0
    /// One record per transcribed piece, in the order sent.
    var pieceRecords: [NotesPieceRecord] = []
    /// "You" pieces whose whole text was a stock phrase on a quiet piece (PhantomRule).
    var phantoms = 0
    /// "You" pieces below PhantomRule.minSendLevelDB, not sent to the engine.
    var quietSkipped = 0
    /// The cleaned mic's residual-echo level in dBFS (nil when the gate was closed or too little echo to measure).
    var residualDB: Double?
    /// Whisper replies where the initial prompt was repeated and stripped.
    var promptEchoes = 0
    var ruleRemovedWords = 0
    var pausedSeconds = 0.0
    /// Keys: echo, speakers, cut, engine_start, transcribe, rule, total (seconds).
    var timings: [String: Double] = [:]
    var audioSeconds = 0.0
    var speechSeconds = 0.0
    /// True when the tracks were placed on the common time axis from their timelines.
    var aligned = false
    var alignBreaks = 0
    /// Seconds cut out of spans where neither track had audio (added back to the turn times).
    var alignRemovedSeconds = 0.0
    var micStartSeconds: Double?
    var systemStartSeconds: Double?
    var micDriftFitPPM: Double?
    var systemDriftFitPPM: Double?
}

enum NotesJobError: Error, Equatable {
    case unreadable, engineMissing, modelMissing, engineStart, engineStopped, cancelled
}

/// What happened to one transcribed piece: numbers only, never text.
struct NotesPieceRecord: Equatable {
    var track: String
    var start: Double
    var end: Double
    var speech: Double
    /// Mean energy of the samples sent, dBFS.
    var levelDB: Double
    /// Words kept after the guards.
    var words: Int
    /// Highest no-speech probability and lowest average log-probability over the reply's segments.
    var noSpeechProb: Double?
    var avgLogprob: Double?
    var promptEchoes: Int
    /// "kept" | "empty" | "phantom" | "quiet" (not sent)
    var outcome: String
    var seconds: Double
}

/// One transcription result per cut piece.
struct PieceResult: Equatable {
    /// "you" or "others"
    var track: String
    var start: Double
    var end: Double
    var segments: [TimedSegment]
}

/// Pure time estimates. Constants: transcription spike RESULTS.md section 6 (per-piece fit a + b * speech seconds,
/// and the rate per audio second) and the diarization spike RESULTS.md (speaker helper rate).
enum NotesEstimate {
    static let margin = 1.25
    static let speakerRate = 0.01
    static let transcribeRateTurbo = 0.071
    static let transcribeRateSmall = 0.033

    static func perPiece(turbo: Bool) -> (a: Double, b: Double) {
        turbo ? (1.31, 0.0117) : (0.31, 0.0219)
    }

    /// Seconds for the whole job, before the track is cut.
    static func beforeCut(_ duration: Double, turbo: Bool) -> Double {
        margin * (turbo ? transcribeRateTurbo : transcribeRateSmall) * duration + speakerRate * duration
    }

    /// Seconds left while transcribing; `observedRatio` scales the fitted cost by how this Mac really runs.
    static func transcribing(piecesLeft n: Int, speechLeft s: Double, turbo: Bool, observedRatio r: Double?) -> Double {
        let (a, b) = perPiece(turbo: turbo)
        return margin * (Double(n) * a + s * b) * min(max(r ?? 1, 0.5), 3)
    }

    /// Real time over fitted time, once 3 pieces are done; nil before.
    static func observedRatio(elapsed: Double, fittedDone: Double, piecesDone: Int) -> Double? {
        piecesDone >= 3 && fittedDone > 0 ? elapsed / fittedDone : nil
    }
}

final class NotesJob {
    private let config: NotesJobConfig
    private let lock = NSLock()
    private var cancelledFlag = false
    private var speakerRun: SpeakerRun?
    private var engine: NotesEngine?
    private var debugEnabled: Bool { config.keepDebug }
    /// File name -> samples of the intermediate tracks, filled only when config.keepDebug (read after run returns).
    private(set) var debugTracks: [String: [Int16]] = [:]

    init(config: NotesJobConfig) {
        self.config = config
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelledFlag
    }

    /// Any thread: sets a flag, cancels the speaker helper and stops the engine.
    func cancel() {
        lock.lock()
        cancelledFlag = true
        let run = speakerRun
        let running = engine
        lock.unlock()
        run?.cancel()
        running?.stop()
    }

    private func checkCancelled() throws {
        if isCancelled { throw NotesJobError.cancelled }
    }

    private struct Item {
        var track: String
        var piece: CutPiece
    }

    /// Blocking; run off the main thread. `progress` is called on the job's thread.
    func run(mic micURL: URL, system sysURL: URL, headphones: Bool,
             progress: @escaping (WritingProgress) -> Void) throws -> (pieces: [SpeechPiece], duration: Double, stats: NotesJobStats) {
        let runStart = Date()
        var stats = NotesJobStats()
        func seconds(since t: Date) -> Double { Date().timeIntervalSince(t) }

        // 1. Read both tracks.
        let fm = FileManager.default
        guard fm.fileExists(atPath: micURL.path) || fm.fileExists(atPath: sysURL.path) else { throw NotesJobError.unreadable }
        // The timelines put both tracks on one clock; without them (or when nothing needs moving) the files are
        // read as they are, as before.
        let plan = TrackAlign.plan(mic: micURL, system: sysURL)
        let usedPlan: AlignPlan? = (plan != nil && plan!.isIdentity == false) ? plan : nil
        let micRaw: [Int16]
        let sys: [Int16]
        if let p = usedPlan {
            micRaw = fm.fileExists(atPath: micURL.path) ? WavSamples.readPlaced(micURL, p.mic, length: p.micLength) : []
            sys = fm.fileExists(atPath: sysURL.path) ? WavSamples.readPlaced(sysURL, p.system, length: p.systemLength) : []
            stats.aligned = true
            stats.alignBreaks = p.breaks.count
            var removed = 0.0
            for e in p.expansions { removed += e.add }
            stats.alignRemovedSeconds = removed
        } else {
            micRaw = WavSamples.read(micURL)
            sys = WavSamples.read(sysURL)
        }
        if let p = plan {
            stats.micStartSeconds = p.mic.first.map { Double($0.dst) / TrackAlign.rate }
            stats.systemStartSeconds = p.system.first.map { Double($0.dst) / TrackAlign.rate }
            stats.micDriftFitPPM = p.micDriftPPM
            stats.systemDriftFitPPM = p.systemDriftPPM
        }
        if debugEnabled && usedPlan != nil {
            debugTracks["you_aligned.wav"] = micRaw
            debugTracks["others_aligned.wav"] = sys
        }
        let expansions: [(at: Double, add: Double)] = usedPlan?.expansions ?? []
        let duration = Double(max(micRaw.count, sys.count)) / 16000
        // The time the caller sees is the true time since the recording started, removed breaks put back.
        let reportedDuration = TrackAlign.expand(duration, expansions)
        let turbo = NotesModelChoice.isTurbo(config.model)
        stats.audioSeconds = duration
        let before = NotesEstimate.beforeCut(duration, turbo: turbo)
        func speakersProgress(_ fraction: Double) {
            progress(WritingProgress(step: .speakers, fraction: fraction,
                                     secondsLeft: max(0, before - seconds(since: runStart))))
        }

        // 2.
        speakersProgress(0)
        try checkCancelled()

        // 3. Echo.
        let echoStart = Date()
        var mic = micRaw
        var micMinThreshold: Double?
        if !micRaw.isEmpty && !sys.isEmpty {
            let result = EchoStage.run(mic: micRaw, system: sys, headphones: headphones)
            mic = result.samples
            if result.bypass == nil {
                let residual = NearEndGate.residualLevel(raw: micRaw, cleaned: result.samples)
                stats.residualDB = residual
                micMinThreshold = residual.map { $0 + NearEndGate.residualMarginDB }
                let gated = NearEndGate.apply(raw: micRaw, cleaned: result.samples)
                stats.nearEndZeroedSeconds = gated.zeroedSeconds
                let residue = EchoResidue.apply(track: gated.samples, raw: micRaw, cleaned: result.samples,
                                                minThreshold: micMinThreshold)
                mic = residue.samples
                stats.leakageDB = residue.leakDB
                stats.echoActiveSeconds = residue.activeSeconds
                stats.regions = residue.decisions
                stats.residueDroppedSeconds = residue.droppedSeconds
                if debugEnabled {
                    debugTracks["you_cleaned.wav"] = result.samples
                    debugTracks["you_gated.wav"] = mic
                }
            }
            switch result.bypass {
            case .headphones?: stats.echoGate = "headphones"
            case .noEcho?: stats.echoGate = "noEcho"
            case nil: stats.echoGate = "open"
            }
            stats.lagSamples = result.fit?.a
            stats.driftPPM = result.fit.map { $0.b * 1e6 }
        } else {
            stats.echoGate = "noAudio"
        }
        stats.timings["echo"] = seconds(since: echoStart)
        speakersProgress(0.2)
        try checkCancelled()

        // 4. Speakers.
        let speakersStart = Date()
        let sysPlain = PauseCutter.cut(sys)
        var runs: [SpeakerSegment]?
        if sysPlain.isEmpty {
            stats.speakerReason = "silent"
        } else if let reason = SpeakerHelper.unavailableReason(binary: config.speakerHelper) {
            stats.speakerReason = reason
        } else if let binary = config.speakerHelper {
            let helperRun = SpeakerRun(binary: binary, modelsDir: config.speakerModels)
            lock.lock(); speakerRun = helperRun; let wasCancelled = cancelledFlag; lock.unlock()
            if wasCancelled { throw NotesJobError.cancelled }
            // The helper reads a file: when the track was moved, it gets an aligned copy (removed right after).
            var helperWav = sysURL
            var alignedCopy: URL?
            if usedPlan != nil {
                let url = sysURL.deletingLastPathComponent().appendingPathComponent(CaptureFolder.systemAligned)
                if Self.writeWav(sys, to: url) {
                    helperWav = url
                    alignedCopy = url
                }
            }
            defer { if let alignedCopy { try? fm.removeItem(at: alignedCopy) } }
            do {
                let turns = try helperRun.run(wav: helperWav, audioSeconds: Double(sys.count) / 16000, onPhase: { phase in
                    if phase == "diarizing" { speakersProgress(0.5) }
                })
                runs = SpeakerTurns.flatten(turns)
            } catch SpeakerError.cancelled {
                throw NotesJobError.cancelled
            } catch SpeakerError.modelsMissing {
                stats.speakerReason = "modelsMissing"
            } catch SpeakerError.unsupported {
                stats.speakerReason = "unsupported"
            } catch SpeakerError.failed(let code) {
                stats.speakerReason = "failed \(code)"
            } catch SpeakerError.timedOut {
                stats.speakerReason = "timedOut"
            } catch {
                stats.speakerReason = "failed"
            }
        }
        try checkCancelled()
        stats.speakerEngine = runs != nil ? "fluidaudio" : "none"
        stats.speakerCount = runs.map { Set($0.map { $0.speaker }).count } ?? 0
        stats.timings["speakers"] = seconds(since: speakersStart)
        speakersProgress(1)

        // 5. Cut. The computer-audio track is cut at the speaker changes, so a piece stays inside one turn.
        let cutStart = Date()
        let youPieces = PauseCutter.cut(mic, minThreshold: micMinThreshold)
        let othersPieces = runs != nil ? PauseCutter.cut(sys, forcedCuts: SpeakerTurns.forcedCuts(runs!)) : sysPlain
        let dbYou = PauseCutter.frameDB(mic[...])
        let dbOthers = PauseCutter.frameDB(sys[...])
        let thrYou = PauseCutter.threshold(frameDB: dbYou)
        let thrOthers = PauseCutter.threshold(frameDB: dbOthers)
        stats.piecesYou = youPieces.count
        stats.piecesOthers = othersPieces.count
        stats.timings["cut"] = seconds(since: cutStart)

        // 6. Transcribe.
        var results: [PieceResult] = []
        if youPieces.isEmpty && othersPieces.isEmpty {
            stats.timings["total"] = seconds(since: runStart)
            Self.log(stats)
            return ([], reportedDuration, stats)
        }
        guard let binary = config.serverBinary, fm.isExecutableFile(atPath: binary) else { throw NotesJobError.engineMissing }
        guard fm.fileExists(atPath: config.model.path) else { throw NotesJobError.modelMissing }
        let notesEngine = NotesEngine(binary: binary, model: config.model, port: config.port)
        let engineStart = Date()
        lock.lock(); engine = notesEngine; let cancelledBeforeStart = cancelledFlag; lock.unlock()
        if cancelledBeforeStart { throw NotesJobError.cancelled }
        do {
            try notesEngine.start()
        } catch {
            notesEngine.stop()
            throw isCancelled ? NotesJobError.cancelled : NotesJobError.engineStart
        }
        defer { notesEngine.stop() }
        stats.timings["engine_start"] = seconds(since: engineStart)

        let items = (youPieces.map { Item(track: "you", piece: $0) } + othersPieces.map { Item(track: "others", piece: $0) })
            .enumerated().sorted { a, b in
                if a.element.piece.start != b.element.piece.start { return a.element.piece.start < b.element.piece.start }
                if a.element.track != b.element.track { return a.element.track == "you" }
                return a.offset < b.offset
            }.map { $0.element }
        let totalSpeech = items.reduce(0) { $0 + $1.piece.speech }
        stats.speechSeconds = totalSpeech
        let fit = NotesEstimate.perPiece(turbo: turbo)

        var restartUsed = false
        /// One request with recovery: a dead engine is restarted once per job; any other failure waits a second
        /// and retries once; a second failure is the end of the job.
        func send(_ samples: ArraySlice<Int16>, seconds length: Double, temperature: Double?) throws -> [WhisperSegment] {
            let wav = WavData.make(samples)
            let timeout = max(30, 4 * length)
            func attempt() throws -> [WhisperSegment] {
                try notesEngine.transcribe(wav: wav, prompt: config.prompt, language: config.language,
                                           temperature: temperature, timeout: timeout)
            }
            do {
                return try attempt()
            } catch {
                if isCancelled { throw NotesJobError.cancelled }
                if !notesEngine.isRunning && !restartUsed {
                    restartUsed = true
                    do { try notesEngine.start() } catch {
                        throw isCancelled ? NotesJobError.cancelled : NotesJobError.engineStopped
                    }
                } else {
                    Thread.sleep(forTimeInterval: 1)
                }
                do {
                    return try attempt()
                } catch {
                    throw isCancelled ? NotesJobError.cancelled : NotesJobError.engineStopped
                }
            }
        }
        func slice(_ track: [Int16], _ start: Double, _ end: Double) -> ArraySlice<Int16> {
            let a = min(max(Int(start * 16000), 0), track.count)
            let b = min(max(Int(end * 16000), a), track.count)
            return track[a..<b]
        }

        let transcribeStart = Date()
        progress(WritingProgress(step: .transcribing, fraction: 0, secondsLeft:
            NotesEstimate.transcribing(piecesLeft: items.count, speechLeft: totalSpeech, turbo: turbo, observedRatio: nil)))
        var doneSpeech = 0.0
        var fittedDone = 0.0
        var piecesDone = 0
        var pausedInTranscribe = 0.0
        for item in items {
            try checkCancelled()
            let piece = item.piece
            // A dictation in progress goes first: no new piece starts while one is under way (at most 60 s per piece).
            var pausedForPiece = 0.0
            while config.shouldPause() && !isCancelled && pausedForPiece < 60 {
                Thread.sleep(forTimeInterval: 0.25)
                pausedForPiece += 0.25
            }
            stats.pausedSeconds += pausedForPiece
            pausedInTranscribe += pausedForPiece
            try checkCancelled()

            let track = item.track == "you" ? mic : sys
            let db = item.track == "you" ? dbYou : dbOthers
            let thr = item.track == "you" ? thrYou : thrOthers
            let length = piece.end - piece.start
            let pieceStart = Date()
            let sent = slice(track, piece.start, piece.end)
            let level = PhantomRule.levelDB(sent)
            if !PhantomRule.shouldSend(track: item.track, levelDB: level) {
                // Too quiet to be the user talking: not sent, so whisper cannot answer it with a stock phrase or the prompt.
                stats.quietSkipped += 1
                stats.pieceRecords.append(NotesPieceRecord(
                    track: item.track, start: piece.start, end: piece.end, speech: piece.speech, levelDB: level, words: 0,
                    noSpeechProb: nil, avgLogprob: nil, promptEchoes: 0, outcome: "quiet", seconds: 0))
                piecesDone += 1
                doneSpeech += piece.speech
                continue
            }
            let reply = try send(sent, seconds: length, temperature: nil)
            var piecePromptEchoes = 0
            func cleanReply(_ replySegments: [WhisperSegment], fromRetry: Bool) -> HallucinationGuard.Cleaned {
                var c = HallucinationGuard.clean(replySegments, fromRetry: fromRetry)
                let stripped = HallucinationGuard.stripPrompt(c.segments, prompt: config.prompt)
                let label = HallucinationGuard.stripPromptLabel(stripped.segments, prompt: config.prompt)
                c.segments = label.segments
                stats.promptEchoes += stripped.removed + label.removed
                piecePromptEchoes += stripped.removed + label.removed
                return c
            }
            let c0 = cleanReply(reply, fromRetry: false)
            var candidates = [c0]
            if HallucinationGuard.needsRetry(words: HallucinationGuard.wordCount(c0.segments), speech: piece.speech) {
                stats.retries += 1
                let c1 = cleanReply(
                    try send(slice(track, piece.start, piece.end), seconds: length, temperature: 0.4), fromRetry: true)
                candidates.append(c1)
                if HallucinationGuard.needsRetry(words: HallucinationGuard.wordCount(c1.segments), speech: piece.speech) {
                    stats.splits += 1
                    let s = PauseCutter.splitPoint(frameDB: db, threshold: thr ?? -40, start: piece.start, end: piece.end)
                    let first = try send(slice(track, piece.start, s), seconds: s - piece.start, temperature: nil)
                    var second = try send(slice(track, s, piece.end), seconds: piece.end - s, temperature: nil)
                    for k in second.indices {
                        second[k].start += s - piece.start
                        second[k].end += s - piece.start
                        for w in second[k].words.indices {
                            second[k].words[w].start += s - piece.start
                            second[k].words[w].end += s - piece.start
                        }
                    }
                    candidates.append(cleanReply(first + second, fromRetry: false))
                }
            }
            var chosen = candidates[HallucinationGuard.best(candidates)]
            stats.dropped += chosen.dropped
            stats.inaudible += chosen.inaudible
            let nsp = reply.compactMap { $0.noSpeechProb }.max()
            let logprob = reply.compactMap { $0.avgLogprob }.min()
            var outcome = "kept"
            if item.track == "you" && PhantomRule.isPhantom(chosen.segments, speech: piece.speech, levelDB: level) {
                chosen.segments = []
                stats.phantoms += 1
                outcome = "phantom"
            }
            let kept = HallucinationGuard.wordCount(chosen.segments)
            if kept == 0 && outcome == "kept" { outcome = "empty" }
            stats.pieceRecords.append(NotesPieceRecord(
                track: item.track, start: piece.start, end: piece.end, speech: piece.speech, levelDB: level, words: kept,
                noSpeechProb: nsp, avgLogprob: logprob, promptEchoes: piecePromptEchoes, outcome: outcome,
                seconds: seconds(since: pieceStart)))
            results.append(PieceResult(track: item.track, start: piece.start, end: piece.end,
                                       segments: Self.timed(chosen.segments, piece: piece)))

            piecesDone += 1
            doneSpeech += piece.speech
            fittedDone += fit.a + fit.b * piece.speech
            let elapsed = seconds(since: transcribeStart) - pausedInTranscribe
            let ratio = NotesEstimate.observedRatio(elapsed: elapsed, fittedDone: fittedDone, piecesDone: piecesDone)
            progress(WritingProgress(
                step: .transcribing, fraction: totalSpeech > 0 ? min(1, doneSpeech / totalSpeech) : 1,
                secondsLeft: NotesEstimate.transcribing(piecesLeft: items.count - piecesDone,
                                                        speechLeft: max(0, totalSpeech - doneSpeech),
                                                        turbo: turbo, observedRatio: ratio)))
        }
        stats.timings["transcribe"] = seconds(since: transcribeStart)

        // 7-8. Echo rule and assembly.
        let ruleStart = Date()
        let assembled = Self.assemble(results: results, runs: runs, englishRules: config.englishRules)
        stats.ruleRemovedWords = assembled.removedWords
        stats.timings["rule"] = seconds(since: ruleStart)
        stats.timings["total"] = seconds(since: runStart)
        Self.log(stats)
        return (Self.expandTimes(assembled.pieces, expansions), reportedDuration, stats)
    }

    /// Pure: maps turn times from the compressed axis back to true seconds since the recording started.
    static func expandTimes(_ pieces: [SpeechPiece], _ expansions: [(at: Double, add: Double)]) -> [SpeechPiece] {
        if expansions.isEmpty { return pieces }
        var out: [SpeechPiece] = []
        for p in pieces {
            var q = p
            q.start = TrackAlign.expand(p.start, expansions)
            q.end = TrackAlign.expand(p.end, expansions)
            out.append(q)
        }
        return out
    }

    /// Writes samples as a 16 kHz mono WAV in slices; false when the file could not be written.
    private static func writeWav(_ samples: [Int16], to url: URL) -> Bool {
        guard !samples.isEmpty, let writer = try? StreamingWav(url: url) else { return false }
        var ok = true
        samples.withUnsafeBufferPointer { all in
            // 160000 samples = 10 s per slice.
            let slice = 160_000
            var at = 0
            while at < all.count && ok {
                let n = min(slice, all.count - at)
                ok = writer.append(UnsafeBufferPointer(rebasing: all[at..<at + n]))
                at += n
            }
        }
        writer.finish()
        if !ok { try? FileManager.default.removeItem(at: url) }
        return ok
    }

    /// Whisper segments (relative to the piece) as absolute-time segments, clamped into the piece. When no
    /// timestamps came back (start and end both 0) on a piece longer than 0.5 s, the segment gets the whole piece.
    static func timed(_ segments: [WhisperSegment], piece: CutPiece) -> [TimedSegment] {
        func clamp(_ t: Double) -> Double { min(max(t, piece.start), piece.end) }
        func timedOne(_ segment: WhisperSegment) -> TimedSegment {
            if segment.start == 0 && segment.end == 0 && piece.end - piece.start > 0.5 {
                return TimedSegment(start: piece.start, end: piece.end, text: segment.text,
                                    words: segment.words.map {
                                        TimedWord(text: $0.text, start: clamp($0.start + piece.start), end: clamp($0.end + piece.start))
                                    })
            }
            return TimedSegment(
                start: clamp(segment.start + piece.start), end: clamp(segment.end + piece.start), text: segment.text,
                words: segment.words.map {
                    TimedWord(text: $0.text, start: clamp($0.start + piece.start), end: clamp($0.end + piece.start))
                })
        }
        return segments.map { segment in
            var t = timedOne(segment)
            // Whisper stretches a segment to the end of its 30 s window, so the turn appeared to run over the
            // silence or noise after it: the word times say when the speech really ended.
            if let first = t.words.first, let last = t.words.last, last.end > first.start {
                t.start = first.start
                t.end = last.end
            }
            return t
        }
    }

    private static func words(_ segments: [TimedSegment]) -> Int {
        segments.reduce(0) { $0 + $1.text.split(whereSeparator: { $0.isWhitespace }).count }
    }

    /// Pure: the transcript echo rule over both tracks, then one piece per result. Meeting text is not dictation,
    /// so only Cleanup.tidy (filler words and the first capital) is applied; no self-correction, list formatting,
    /// email structure or writing style.
    static func assemble(results: [PieceResult], runs: [SpeakerSegment]?, englishRules: Bool) -> (pieces: [SpeechPiece], removedWords: Int) {
        var you: [TimedSegment] = []
        var system: [TimedSegment] = []
        for r in results {
            if r.track == "you" { you += r.segments } else { system += r.segments }
        }
        let kept = TranscriptEchoRule.apply(you: you, system: system)
        let removedWords = words(you) - words(kept)

        // Each kept segment goes back to the "you" result that contains its midpoint, else the nearest one.
        let youIndexes = results.indices.filter { results[$0].track == "you" }
        var keptByResult: [Int: [TimedSegment]] = [:]
        for segment in kept {
            let mid = (segment.start + segment.end) / 2
            var target: Int?
            var nearest = Double.infinity
            for i in youIndexes {
                let r = results[i]
                if mid >= r.start && mid <= r.end { target = i; break }
                let distance = mid < r.start ? r.start - mid : mid - r.end
                if distance < nearest { nearest = distance; target = i }
            }
            if let target { keptByResult[target, default: []].append(segment) }
        }

        var pieces: [SpeechPiece] = []
        for (i, r) in results.enumerated() {
            let segments = r.track == "you" ? (keptByResult[i] ?? []) : r.segments
            guard let first = segments.first, let last = segments.last else { continue }
            let joined = segments.map { $0.text }.joined(separator: " ")
                .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            let text = Cleanup.tidy(joined, english: englishRules)
            if text.isEmpty { continue }
            let speaker: String
            if r.track == "you" {
                speaker = NotesLogic.youKey
            } else if let runs, !runs.isEmpty,
                      let found = SpeakerTurns.speaker(start: r.start, end: r.end, runs: runs) {
                speaker = found
            } else {
                speaker = NotesLogic.everyoneKey
            }
            pieces.append(SpeechPiece(speaker: speaker, start: first.start, end: max(last.end, first.start), text: text))
        }
        return (pieces, removedWords)
    }

    private static func log(_ s: NotesJobStats) {
        func f(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "-" }
        print("talkflowd: notes: echo gate \(s.echoGate), lag \(f(s.lagSamples)) samples, drift \(f(s.driftPPM)) ppm, echo_only_zeroed_seconds \(f(s.nearEndZeroedSeconds)), residual \(f(s.residualDB)) dBFS, \(f(s.timings["echo"])) s")
        let droppedRegions = s.regions.filter { !$0.kept }.count
        print("talkflowd: notes: echo residue: leakage \(f(s.leakageDB)) dB over \(f(s.echoActiveSeconds)) s of echo, regions dropped \(droppedRegions) of \(s.regions.count) (\(f(s.residueDroppedSeconds)) s)")
        print("talkflowd: notes: speakers engine \(s.speakerEngine), count \(s.speakerCount), reason \(s.speakerReason ?? "-"), \(f(s.timings["speakers"])) s")
        print("talkflowd: notes: pieces you \(s.piecesYou), others \(s.piecesOthers), cut \(f(s.timings["cut"])) s, audio \(f(s.audioSeconds)) s, speech \(f(s.speechSeconds)) s")
        print("talkflowd: notes: retries \(s.retries), splits \(s.splits), dropped \(s.dropped), prompt echoes \(s.promptEchoes), phantoms \(s.phantoms), quiet skipped \(s.quietSkipped), inaudible \(s.inaudible), paused \(f(s.pausedSeconds)) s")
        print("talkflowd: notes: align \(s.aligned ? "yes" : "no"), you starts \(f(s.micStartSeconds)) s, others starts \(f(s.systemStartSeconds)) s, breaks \(s.alignBreaks), removed \(f(s.alignRemovedSeconds)) s, drift fit you \(f(s.micDriftFitPPM)) others \(f(s.systemDriftFitPPM)) ppm")
        print("talkflowd: notes: engine start \(f(s.timings["engine_start"])) s, transcribe \(f(s.timings["transcribe"])) s, rule removed \(s.ruleRemovedWords) words, \(f(s.timings["rule"])) s, total \(f(s.timings["total"])) s")
    }
}

// MARK: - The pipeline the app uses

final class LocalNotesPipeline: NotesPipeline {
    private let makeConfig: () -> NotesJobConfig

    /// Main thread only (run, cancel and the hops back to main).
    private final class RunToken {
        var cancelled = false
        let job: NotesJob
        init(job: NotesJob) { self.job = job }
    }
    private var token: RunToken?

    init(makeConfig: @escaping () -> NotesJobConfig = LocalNotesPipeline.liveConfig) {
        self.makeConfig = makeConfig
    }

    static func liveConfig() -> NotesJobConfig {
        NotesJobConfig(
            serverBinary: SpeechEngine.serverBinary(),
            model: NotesModelChoice.model(),
            port: NotesEngine.defaultPort,
            speakerHelper: SpeakerHelper.bundledBinary(),
            speakerModels: SpeakerHelper.modelsFolder,
            prompt: ScreenContext.prompt(names: [], learned: Preferences.learnedWords, language: Preferences.language),
            language: Preferences.language.whisperCode,
            englishRules: Preferences.language == .english,
            // The job's thread asks the main thread; the main thread never waits on the job, so this cannot deadlock.
            shouldPause: { DispatchQueue.main.sync { FinalPassEngine.holding || FinalPassEngine.passesInFlight > 0 } },
            keepDebug: NotesDebugKeeper.enabled)
    }

    func run(audioFolder: URL, progress: @escaping (WritingProgress) -> Void,
             completion: @escaping (PipelineOutcome) -> Void) {
        let config = makeConfig()
        let info = CaptureSessionInfo.read(from: audioFolder)
        let headphones = info.map { OutputRoute.headphonesThroughout($0.routes.map { $0.route }) } ?? false
        let micURL = audioFolder.appendingPathComponent(CaptureFolder.mic)
        let sysURL = audioFolder.appendingPathComponent(CaptureFolder.system)
        let job = NotesJob(config: config)
        let token = RunToken(job: job)
        self.token = token

        DispatchQueue.global(qos: .utility).async {
            // A system writer that missed its stop deadline may still be writing others.wav: wait for it here, off
            // the main thread, or fence it off so the file cannot change while it is read.
            if CaptureSettle.waitForSystemTrack(folder: audioFolder) == .abandoned {
                print("talkflowd: notes: system track writer did not finish; the track may be cut short")
            }
            let outcome: PipelineOutcome?
            do {
                let result = try job.run(mic: micURL, system: sysURL, headphones: headphones, progress: { p in
                    DispatchQueue.main.async { if !token.cancelled { progress(p) } }
                })
                // Before the completion: NotesModel deletes the audio as soon as the transcript is saved.
                if config.keepDebug {
                    NotesDebugKeeper.keep(audioFolder: audioFolder, stats: result.stats, tracks: job.debugTracks,
                                          turns: result.pieces.count, duration: result.duration)
                }
                outcome = .finished(pieces: result.pieces, duration: result.duration)
            } catch NotesJobError.cancelled {
                outcome = nil
            } catch let error as NotesJobError {
                outcome = .failed(Self.failure(error))
            } catch {
                outcome = .failed(Self.failure(nil))
            }
            DispatchQueue.main.async {
                guard let outcome, !token.cancelled else { return }
                completion(outcome)
            }
        }
    }

    func cancel() {
        guard let token else { return }
        token.cancelled = true
        token.job.cancel()
        self.token = nil
    }

    static func failure(_ error: NotesJobError?) -> NoteFailure {
        let message: String
        switch error {
        case .unreadable?: message = "talkflow couldn't read the recording."
        case .engineMissing?: message = "The speech engine is missing from this copy of talkflow. Reinstall talkflow, then try again."
        case .modelMissing?: message = "The speech model isn't on this Mac yet. Open talkflow's setup to download it, then try again."
        case .engineStart?: message = "The speech engine didn't start. Try again."
        case .engineStopped?: message = "The speech engine stopped answering. Try again."
        default: message = "Writing the notes stopped unexpectedly. Try again."
        }
        // NotesModel downgrades .notes to .none when the audio is gone.
        return NoteFailure(step: .transcribing, message: message, retry: .notes)
    }
}

// MARK: - Log privacy

enum NotesFlow {
    /// True when the log holds what was said: any 3 consecutive words of a turn appear consecutively in the log,
    /// or a turn of 20 or more characters appears verbatim. Words are lowercase [a-z0-9'].
    static func logLeaks(log: String, transcript: Transcript) -> Bool {
        func words(_ text: String) -> [String] {
            var out: [String] = []
            var current = ""
            for u in text.lowercased().unicodeScalars {
                switch u {
                case "a"..."z", "0"..."9", "'":
                    current.unicodeScalars.append(u)
                default:
                    if !current.isEmpty { out.append(current); current = "" }
                }
            }
            if !current.isEmpty { out.append(current) }
            return out
        }
        func trigrams(_ w: [String]) -> [String] {
            guard w.count >= 3 else { return [] }
            return (0..<(w.count - 2)).map { w[$0] + " " + w[$0 + 1] + " " + w[$0 + 2] }
        }
        let inLog = Set(trigrams(words(log)))
        for turn in transcript.turns {
            if turn.text.count >= 20 && log.contains(turn.text) { return true }
            if trigrams(words(turn.text)).contains(where: { inLog.contains($0) }) { return true }
        }
        return false
    }
}
