import Foundation

// Bounded live updates for long holds (design-reference/LONG-HOLD-SPEC.md A).
//
// A hold is split into a settled part, transcribed once as pieces, and an unsettled tail. Live
// updates and the release pass send only the tail, so a request never grows with the hold.

/// Pure audio analysis for choosing where to cut a long tail.
enum HoldAudio {
    static let sampleRate = 16000
    /// 20 ms analysis frame.
    static let frameSamples = 320
    /// A settled piece is at least this long (300 frames).
    static let minChunk = 6.0
    /// The newest audio is never settled (150 frames).
    static let keepTail = 3.0
    /// 0.30 s: a real pause (pass 1).
    static let minPauseFrames = 15
    /// 0.10 s: a short dip (pass 2, forced only).
    static let minDipFrames = 5
    /// 0.10 s window for pass 3 (forced only).
    static let quietWindowFrames = 5
    /// Absolute floor of the pause threshold (Int16 RMS).
    static let silenceFloorRMS: Float = 100
    /// Pause threshold = max(floor, 0.15 * p90 frame RMS of the search window).
    static let silenceRelative: Float = 0.15
    /// A piece with no 20 ms frame at or above this is silent and is not sent.
    static let speechGateRMS: Float = 300

    /// RMS of each whole 20 ms frame (trailing partial frame dropped). Int16 units.
    static func frameRMS(_ s: ArraySlice<Int16>) -> [Float] {
        let count = s.count / frameSamples
        var out: [Float] = []
        out.reserveCapacity(count)
        var index = s.startIndex
        for _ in 0..<count {
            out.append(rms(s[index..<(index + frameSamples)]))
            index += frameSamples
        }
        return out
    }

    private static func rms(_ s: ArraySlice<Int16>) -> Float {
        guard !s.isEmpty else { return 0 }
        var sum: Double = 0
        for sample in s { let v = Double(sample); sum += v * v }
        return Float((sum / Double(s.count)).squareRoot())
    }

    /// True when no frame has RMS >= speechGateRMS. Empty -> true. A piece shorter than one frame
    /// counts as one frame.
    static func isSilent(_ s: ArraySlice<Int16>) -> Bool {
        if s.isEmpty { return true }
        if s.count < frameSamples { return rms(s) < speechGateRMS }
        return !frameRMS(s).contains { $0 >= speechGateRMS }
    }

    /// Where to cut the tail, as a sample offset into `tail` (a multiple of frameSamples), or nil
    /// for "not now". `force` is true once the tail is long enough that a cut is made anyway.
    static func findCut(_ tail: ArraySlice<Int16>, force: Bool) -> Int? {
        findCutWithReason(tail, force: force)?.offset
    }

    static func findCutWithReason(_ tail: ArraySlice<Int16>, force: Bool) -> (offset: Int, reason: String)? {
        let rms = frameRMS(tail)
        let n = rms.count
        let lo = Int(minChunk * Double(sampleRate)) / frameSamples
        let hi = n - Int(keepTail * Double(sampleRate)) / frameSamples
        guard hi > lo else { return nil }

        let window = Array(rms[lo..<hi])
        let sorted = window.sorted()
        let p90 = sorted[Int(Double(window.count - 1) * 0.9)]
        let threshold = max(silenceFloorRMS, silenceRelative * p90)

        // Maximal runs of quiet frames, clipped to the window.
        var runs: [(start: Int, length: Int)] = []
        var runStart: Int?
        for frame in lo..<hi {
            if rms[frame] < threshold {
                if runStart == nil { runStart = frame }
            } else if let start = runStart {
                runs.append((start, frame - start))
                runStart = nil
            }
        }
        if let start = runStart { runs.append((start, hi - start)) }

        if let run = runs.last(where: { $0.length >= minPauseFrames }) {
            return ((run.start + run.length / 2) * frameSamples, "cut at a pause")
        }
        guard force else { return nil }
        if let run = runs.last(where: { $0.length >= minDipFrames }) {
            return ((run.start + run.length / 2) * frameSamples, "cut at a short dip")
        }
        if hi - lo < quietWindowFrames {
            return ((lo + (hi - lo) / 2) * frameSamples, "cut at the quietest point")
        }
        var best = Float.greatestFiniteMagnitude
        var bestStart = lo
        for k in lo...(hi - quietWindowFrames) {
            var sum: Float = 0
            for i in k..<(k + quietWindowFrames) { sum += rms[i] }
            let mean = sum / Float(quietWindowFrames)
            if mean <= best { best = mean; bestStart = k }
        }
        return ((bestStart + 2) * frameSamples, "cut at the quietest point")
    }
}

/// The settled part of a hold: raw small.en text of each settled piece, never changed again.
struct HoldTranscript {
    private(set) var settledSamples = 0
    /// Raw text of each settled piece ("" when silent).
    private(set) var chunks: [String] = []

    var frozenRaw: String { Self.joined(chunks) }
    var hasFrozen: Bool { !frozenRaw.isEmpty }

    /// Appends the piece that ends at `end`. A placeholder (whisper narrating silence) is stored as "".
    mutating func settle(through end: Int, text: String) {
        precondition(end > settledSamples, "a settle must move forward")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        chunks.append(Transcriber.isPlaceholder(trimmed) ? "" : trimmed)
        settledSamples = end
    }

    /// The hypothesis for the whole hold: settled text plus the tail's text.
    func joined(tail: String) -> String {
        Self.join(frozen: frozenRaw, tail: tail)
    }

    /// The base prompt plus the last words of the settled text, so whisper keeps its spelling and
    /// style across a seam. Unchanged when nothing has settled (a short hold is today's path).
    func prompt(base: String) -> String {
        Self.prompt(base: base, frozen: frozenRaw)
    }

    /// Raw texts joined like `frozenRaw`; used for the large-model settled text too.
    static func joined(_ texts: [String]) -> String {
        Transcriber.joinSegments(texts.filter { !$0.isEmpty }.joined(separator: "\n"))
    }

    static func join(frozen: String, tail: String) -> String {
        let tail = Transcriber.isPlaceholder(tail) ? "" : tail
        if frozen.isEmpty { return tail }
        if tail.isEmpty { return frozen }
        return Transcriber.joinSegments(frozen + "\n" + tail)
    }

    static func prompt(base: String, frozen: String) -> String {
        guard !frozen.isEmpty else { return base }
        var words = frozen.split(whereSeparator: { $0.isWhitespace }).suffix(HoldSession.carryWords).map(String.init)
        var carry = words.joined(separator: " ")
        while carry.count > HoldSession.carryMaxChars, !words.isEmpty {
            words.removeFirst()
            carry = words.joined(separator: " ")
        }
        return base + " " + carry
    }
}

/// What a hold session reads its audio from: the recorder in the app, a file in the harness.
protocol HoldAudioSource: AnyObject {
    var sampleCount: Int { get }
    func samples(from start: Int, to end: Int) -> [Int16]
}

/// One hold's transcription: live updates over the tail, settle requests for finished pieces, and
/// the release pass. Main thread only.
final class HoldSession {
    // Timing and carry constants (LONG-HOLD-SPEC.md A2); the audio ones are in HoldAudio.
    static let sampleRate = 16000
    /// Start looking for a cut once the tail is this long.
    static let settleSearchAfter = 15.0
    /// From here a cut is made even without a real pause.
    static let forceCutAfter = 22.0
    /// Last words of the settled text appended to the prompt.
    static let carryWords = 20
    /// The carry is trimmed from the front, whole words, until it is at most this long.
    static let carryMaxChars = 160
    /// Live tick and settle timeout. Only catches a hung server; a request is not abandoned in
    /// normal operation, so nothing queues behind an abandoned one.
    static let liveTimeout: TimeInterval = 10
    /// After a live/settle request times out, none is sent for this long.
    static let liveCooldown: TimeInterval = 10
    /// small.en final-tail request.
    static let finalTimeout: TimeInterval = 20
    /// Release waits this long for the live engine to be ready (cold start).
    static let finalEngineWait: TimeInterval = 15
    /// At release, how long to wait for a large-model chunk already in flight.
    static let largeChunkWait: TimeInterval = 2

    struct Config {
        var smallURL: URL
        var largeURL: URL? = nil
        var language: DictationLanguage = .english
    }
    enum RequestKind: String { case tick, settle, final, largeChunk, largeFinal, smallFallback }
    struct RequestLog { let kind: RequestKind; let audioSeconds: Double; let latency: Double; let ok: Bool }
    enum FinalRoute { case small, large }

    typealias Transcribe = (_ wav: Data, _ url: URL, _ timeout: TimeInterval, _ prompt: String,
                            _ language: DictationLanguage, _ done: @escaping (Transcriber.Result?) -> Void) -> Void

    static let liveTranscribe: Transcribe = { wav, url, timeout, prompt, language, done in
        Transcriber.transcribe(wav: wav, serverURL: url, timeout: timeout, prompt: prompt, language: language, completion: done)
    }

    /// Called on main with the raw joined hypothesis after each successful live update.
    /// `afterSettle` is true for the first hypothesis after a settle was applied (caller rebases).
    var onHypothesis: ((_ raw: String, _ afterSettle: Bool) -> Void)?
    /// Every request, for logs and the harness.
    var onRequest: ((RequestLog) -> Void)?
    /// A piece was settled: its length in seconds and how the cut was chosen. For the harness.
    var onSettle: ((_ pieceSeconds: Double, _ reason: String) -> Void)?
    /// Large-model hooks (FinalPassEngine in the app; stubs in the harness).
    var largeReady: () -> Bool = { false }
    var largePassStarted: () -> Void = {}
    var largePassEnded: () -> Void = {}
    /// Feeds the slow-pass counter (FinalPassSpeed in the app; a no-op in the harness, which must
    /// not touch Preferences). `elapsed` is nil for a pass that ran out of time.
    var recordPassSpeed: (_ elapsed: TimeInterval?, _ audioSeconds: TimeInterval) -> Void = { elapsed, seconds in
        FinalPassSpeed.record(elapsed: elapsed, audioSeconds: seconds)
    }

    private let source: HoldAudioSource
    private let config: Config
    private let engine: EngineGate
    private let basePrompt: () -> String
    private let transcribe: Transcribe

    private var transcript = HoldTranscript()
    private var inFlight = false
    private var cooldownUntil: Date?
    private var pendingAfterSettle = false
    private var finished = false
    private var generation = 0

    private struct LaneEntry {
        var small: String
        var large: String?
        var audio: [Int16]?
    }
    /// Index-aligned with `transcript.chunks`.
    private var lane: [LaneEntry] = []
    private var largeInFlight: Int?
    private var largeWaiter: (() -> Void)?

    /// Copied by `freeze()`.
    private var frozenTail: [Int16]?
    private var frozenTranscript: HoldTranscript?

    init(source: HoldAudioSource, config: Config, engine: EngineGate,
         prompt: @escaping () -> String,
         transcribe: @escaping Transcribe = HoldSession.liveTranscribe) {
        self.source = source
        self.config = config
        self.engine = engine
        self.basePrompt = prompt
        self.transcribe = transcribe
    }

    // MARK: - Live updates

    func tick() {
        guard !finished, !inFlight, engine.isReady else { return }
        if let until = cooldownUntil, Date() < until { return }
        guard source.sampleCount >= 8000 else { return }
        pumpLarge()

        let rate = Double(Self.sampleRate)
        let total = source.sampleCount
        let start = transcript.settledSamples
        let tailLen = total - start

        if Double(tailLen) >= Self.settleSearchAfter * rate {
            let tail = source.samples(from: start, to: total)
            if let cut = HoldAudio.findCutWithReason(tail[...], force: Double(tailLen) >= Self.forceCutAfter * rate), cut.offset > 0 {
                let piece = Array(tail[0..<cut.offset])
                let end = start + cut.offset
                let seconds = Double(piece.count) / rate
                if HoldAudio.isSilent(piece[...]) {
                    transcript.settle(through: end, text: "")
                    lane.append(LaneEntry(small: "", large: nil, audio: nil))
                    logSettle(piece: seconds, tail: Double(tailLen) / rate, reason: "silence")
                    // No words moved, so nothing to rebase: carry on with this tick's update.
                } else {
                    sendSettle(piece: piece, end: end, tailSeconds: Double(tailLen) / rate, reason: cut.reason)
                    return
                }
            }
        }

        sendTick(total: total)
    }

    private func sendSettle(piece: [Int16], end: Int, tailSeconds: Double, reason: String) {
        inFlight = true
        let gen = generation
        let startedAt = Date()
        let seconds = Double(piece.count) / Double(Self.sampleRate)
        let wav = Recorder.wav(from: piece, sampleRate: Self.sampleRate)
        let prompt = transcript.prompt(base: basePrompt())
        transcribe(wav, config.smallURL, Self.liveTimeout, prompt, config.language) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = false
                let latency = Date().timeIntervalSince(startedAt)
                self.onRequest?(RequestLog(kind: .settle, audioSeconds: seconds, latency: latency, ok: result != nil))
                guard gen == self.generation else { return }
                guard let result else {
                    self.engine.requestFailed()
                    if latency >= Self.liveTimeout - 0.5 { self.cooldownUntil = Date().addingTimeInterval(Self.liveCooldown) }
                    return
                }
                self.transcript.settle(through: end, text: result.text)
                self.lane.append(LaneEntry(small: self.transcript.chunks.last ?? "", large: nil,
                                           audio: self.config.largeURL != nil ? piece : nil))
                self.pendingAfterSettle = true
                self.logSettle(piece: seconds, tail: tailSeconds, reason: reason)
                self.pumpLarge()
            }
        }
    }

    private func logSettle(piece: Double, tail: Double, reason: String) {
        print("talkflowd: settled \(String(format: "%.1f", piece))s of a \(String(format: "%.1f", tail))s tail (\(reason))")
        onSettle?(piece, reason)
    }

    private func sendTick(total: Int) {
        let start = transcript.settledSamples
        let tail = source.samples(from: start, to: total)
        if transcript.hasFrozen && HoldAudio.isSilent(tail[...]) {
            emit(transcript.joined(tail: ""))
            return
        }
        inFlight = true
        let gen = generation
        let startedAt = Date()
        let seconds = Double(tail.count) / Double(Self.sampleRate)
        let wav = Recorder.wav(from: tail, sampleRate: Self.sampleRate)
        let prompt = transcript.prompt(base: basePrompt())
        transcribe(wav, config.smallURL, Self.liveTimeout, prompt, config.language) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = false
                let latency = Date().timeIntervalSince(startedAt)
                self.onRequest?(RequestLog(kind: .tick, audioSeconds: seconds, latency: latency, ok: result != nil))
                guard gen == self.generation else { return }
                guard let result else {
                    self.engine.requestFailed()
                    if latency >= Self.liveTimeout - 0.5 { self.cooldownUntil = Date().addingTimeInterval(Self.liveCooldown) }
                    return
                }
                let text = Transcriber.isPlaceholder(result.text) ? "" : result.text
                // A no-speech tick leaves the committer alone (today's rule).
                if text.isEmpty && !self.transcript.hasFrozen { return }
                self.emit(self.transcript.joined(tail: text))
            }
        }
    }

    private func emit(_ raw: String) {
        let after = pendingAfterSettle
        pendingAfterSettle = false
        onHypothesis?(raw, after)
    }

    // MARK: - Large-model lane

    /// Sends the next settled piece to the large model, one at a time, in the background.
    private func pumpLarge() {
        guard let url = config.largeURL, largeInFlight == nil, !finished, largeReady() else { return }
        guard let i = lane.firstIndex(where: { $0.large == nil && $0.audio != nil && !$0.small.isEmpty }),
              let audio = lane[i].audio else { return }
        largeInFlight = i
        largePassStarted()
        let seen = HoldTranscript.joined(lane[0..<i].map { $0.large ?? $0.small })
        let prompt = HoldTranscript.prompt(base: basePrompt(), frozen: seen)
        let startedAt = Date()
        let seconds = Double(audio.count) / Double(Self.sampleRate)
        let wav = Recorder.wav(from: audio, sampleRate: Self.sampleRate)
        transcribe(wav, url, FinalPassSpeed.timeout, prompt, config.language) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.largePassEnded()
                self.onRequest?(RequestLog(kind: .largeChunk, audioSeconds: seconds,
                                           latency: Date().timeIntervalSince(startedAt), ok: result != nil))
                // Not generation-gated: a finished session still wants it.
                self.largeInFlight = nil
                if let result, !Transcriber.isPlaceholder(result.text) {
                    self.lane[i].large = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                // A failure falls back to the small text and is never retried.
                self.lane[i].audio = nil
                if self.finished {
                    let waiter = self.largeWaiter
                    self.largeWaiter = nil
                    waiter?()
                } else {
                    self.pumpLarge()
                }
            }
        }
    }

    private func dropQueuedLargeWork() {
        for i in lane.indices where i != largeInFlight { lane[i].audio = nil }
    }

    /// Runs `then` once the in-flight large chunk is done, or after `largeChunkWait`.
    private func waitForLargeChunk(then: @escaping () -> Void) {
        guard largeInFlight != nil else { then(); return }
        var done = false
        let once = {
            if !done { done = true; then() }
        }
        largeWaiter = once
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.largeChunkWait) { [weak self] in
            self?.largeWaiter = nil
            once()
        }
    }

    // MARK: - Release

    /// Stops live work and copies what the release pass needs. Idempotent. Call it the moment the
    /// hold ends: `finish(route:completion:)` may run later (it can wait on the final-pass model),
    /// by which time a new hold may have reset the recorder.
    func freeze() {
        guard frozenTail == nil else { return }
        finished = true
        generation += 1
        dropQueuedLargeWork()
        frozenTail = source.samples(from: transcript.settledSamples, to: source.sampleCount)
        frozenTranscript = transcript
    }

    func finish(route: FinalRoute, completion: @escaping (Transcriber.Result?, _ usedLarge: Bool) -> Void) {
        freeze()
        let tail = frozenTail ?? []
        let frozen = frozenTranscript ?? transcript
        engine.whenReady(timeout: Self.finalEngineWait) { [weak self] ready in
            DispatchQueue.main.async {
                guard let self else { return }
                guard ready else {
                    completion(frozen.hasFrozen ? Transcriber.Result(text: frozen.frozenRaw, elapsed: 0) : nil, false)
                    return
                }
                self.release(route: route, tail: tail, frozen: frozen, completion: completion)
            }
        }
    }

    private func release(route: FinalRoute, tail: [Int16], frozen: HoldTranscript,
                         completion: @escaping (Transcriber.Result?, Bool) -> Void) {
        let rate = Double(Self.sampleRate)
        let tailSeconds = Double(tail.count) / rate
        let useLarge = route == .large && config.largeURL != nil

        if frozen.hasFrozen && HoldAudio.isSilent(tail[...]) {
            if useLarge {
                waitForLargeChunk { [self] in
                    let text = HoldTranscript.joined(lane.map { $0.large ?? $0.small })
                    completion(Transcriber.Result(text: text, elapsed: 0, segments: frozen.chunks.filter { !$0.isEmpty }.count),
                               lane.contains { $0.large != nil })
                }
            } else {
                completion(Transcriber.Result(text: frozen.frozenRaw, elapsed: 0, segments: frozen.chunks.filter { !$0.isEmpty }.count), false)
            }
            return
        }

        let wav = Recorder.wav(from: tail, sampleRate: Self.sampleRate)
        let segmentsBefore = frozen.chunks.filter { !$0.isEmpty }.count

        func small(kind: RequestKind, frozenText: String, fallbackOnFail: String?, usedLarge: Bool) {
            let prompt = HoldTranscript.prompt(base: basePrompt(), frozen: frozenText)
            let startedAt = Date()
            transcribe(wav, config.smallURL, Self.finalTimeout, prompt, config.language) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.onRequest?(RequestLog(kind: kind, audioSeconds: tailSeconds,
                                               latency: Date().timeIntervalSince(startedAt), ok: result != nil))
                    guard let result else {
                        if let fallbackOnFail, !fallbackOnFail.isEmpty {
                            completion(Transcriber.Result(text: fallbackOnFail, elapsed: 0, segments: segmentsBefore), false)
                        } else {
                            completion(nil, false)
                        }
                        return
                    }
                    completion(Transcriber.Result(text: HoldTranscript.join(frozen: frozenText, tail: result.text),
                                                  elapsed: result.elapsed, segments: segmentsBefore + result.segments), usedLarge)
                }
            }
        }

        guard useLarge, let largeURL = config.largeURL else {
            small(kind: .final, frozenText: frozen.frozenRaw, fallbackOnFail: frozen.frozenRaw, usedLarge: false)
            return
        }

        let seen = HoldTranscript.joined(lane.map { $0.large ?? $0.small })
        let prompt = HoldTranscript.prompt(base: basePrompt(), frozen: seen)
        largePassStarted()
        let startedAt = Date()
        transcribe(wav, largeURL, FinalPassSpeed.timeout, prompt, config.language) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.largePassEnded()
                let latency = Date().timeIntervalSince(startedAt)
                self.onRequest?(RequestLog(kind: .largeFinal, audioSeconds: tailSeconds, latency: latency, ok: result != nil))
                if let result {
                    self.recordPassSpeed(result.elapsed, tailSeconds)
                } else if latency >= FinalPassSpeed.timeout - 0.5 {
                    // Ran out of time, as opposed to being refused or failing at once.
                    self.recordPassSpeed(nil, tailSeconds)
                }
                self.waitForLargeChunk {
                    let frozenLarge = HoldTranscript.joined(self.lane.map { $0.large ?? $0.small })
                    if let result {
                        completion(Transcriber.Result(text: HoldTranscript.join(frozen: frozenLarge, tail: result.text),
                                                      elapsed: result.elapsed, segments: segmentsBefore + result.segments), true)
                    } else {
                        small(kind: .smallFallback, frozenText: frozenLarge, fallbackOnFail: frozenLarge, usedLarge: false)
                    }
                }
            }
        }
    }

    func cancel() {
        finished = true
        generation += 1
        dropQueuedLargeWork()
    }
}
