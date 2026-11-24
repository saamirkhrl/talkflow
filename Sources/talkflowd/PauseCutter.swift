import Foundation

/// One piece of a track, cut at pauses, to be sent to the transcriber as one request.
struct CutPiece: Equatable {
    var start: Double      // seconds, includes padding
    var end: Double
    var speech: Double     // seconds of speech frames inside (speech_s)
    var hardStart: Bool    // this piece starts at a hard or forced-inside cut (join to the previous with a plain space)
    var hardEnd: Bool
}

/// Energy-based pause cutter: splits one whole 16 kHz mono track into pieces of at most 28 s at its pauses, so each
/// piece fits whisper's 30 s window. Pure logic, no I/O. Port of the reference cutter.py (`cut()`), whose self-test is
/// mirrored in NotesPipelineChecks.
enum PauseCutter {
    // Constants, each with the measurement that fixed it (transcription spike RESULTS.md section 2).
    /// transcription spike RESULTS.md 2: 10 ms frames resolve 0.3 s pauses; 360k frames per hour is trivial.
    static let frameSeconds = 0.010
    /// transcription spike RESULTS.md 2: 5th percentile of frame dBFS = noise floor (-60.4 on a -60 dBFS bed).
    static let noisePercentile = 5.0
    /// transcription spike RESULTS.md 2: threshold = floor + 10 dB; sweeps of 6..12 dB gave identical pieces.
    static let aboveFloorDB = 10.0
    /// transcription spike RESULTS.md 2: threshold clamp low end, dBFS.
    static let thresholdMinDB = -70.0
    /// transcription spike RESULTS.md 2: threshold clamp high end, dBFS (a noisy room finds fewer pauses, loses nothing).
    static let thresholdMaxDB = -40.0
    /// transcription spike RESULTS.md 2: frames at or below this are digital zero and ignored for the floor.
    static let digitalSilenceDB = -100.0
    /// transcription spike RESULTS.md 2: word gaps are <= 0.12 s, sentence and turn gaps >= 0.35 s, so close < 0.30 s.
    static let minPauseSeconds = 0.30
    /// transcription spike RESULTS.md 2: drops clicks; "Yes." (~0.4 s) survives.
    static let minSpeechSeconds = 0.12
    /// transcription spike RESULTS.md 2: whisper's window is 30 s, 2 s margin; longest piece on the hour was 27.89 s.
    static let maxPieceSeconds = 28.0
    /// transcription spike RESULTS.md 2: fewer, longer requests are faster; hour -> 167 pieces, mean 19.8 s.
    static let minTargetSeconds = 14.0
    /// transcription spike RESULTS.md 2: keeps word onsets and tails; never more than half the neighbouring pause.
    static let padSeconds = 0.20
    /// transcription spike RESULTS.md 2: pauses of 2 s or more are always cut, so silence is never sent.
    static let longPauseSeconds = 2.0
    /// transcription spike RESULTS.md 2: hard cuts search the last 3 s before the limit (40 s monologue -> cut at 27.09 s).
    static let hardSearchSeconds = 3.0
    /// transcription spike RESULTS.md 2: 5-frame (50 ms) centred moving average of dBFS for the hard-cut minimum.
    static let smoothFrames = 5

    private enum Kind { case pause, forced, forcedIn, hard }

    // MARK: Frame analysis

    /// dBFS of each 10 ms frame, the same formula cut() uses (trailing partial frame dropped).
    static func frameDB(_ samples: ArraySlice<Int16>, sampleRate: Int = 16000) -> [Double] {
        let frame = max(1, Int((frameSeconds * Double(sampleRate)).rounded(.toNearestOrEven)))
        let n = samples.count / frame
        if n == 0 { return [] }
        var out = [Double](repeating: 0, count: n)
        samples.withUnsafeBufferPointer { p in
            var base = 0
            for f in 0..<n {
                // Exact Int sum of squares: a frame of 160 samples cannot overflow Int64 (160 * 2^30).
                var acc = 0
                for k in base..<(base + frame) {
                    let v = Int(p[k])
                    acc += v * v
                }
                base += frame
                let rms = (Double(acc) / Double(frame)).squareRoot()
                out[f] = 20.0 * log10(max(rms, 1e-3) / 32768.0)
            }
        }
        return out
    }

    /// floor + 10 dB clamped to [-70, -40], from frames > -100 dBFS; nil when there are none.
    static func threshold(frameDB db: [Double]) -> Double? {
        var valid = db.filter { $0 > digitalSilenceDB }
        if valid.isEmpty { return nil }
        valid.sort()
        // numpy.percentile default: linear interpolation between order statistics.
        let pos = Double(valid.count - 1) * noisePercentile / 100.0
        let lo = Int(pos.rounded(.down))
        let hi = min(lo + 1, valid.count - 1)
        let floorDB = valid[lo] + (valid[hi] - valid[lo]) * (pos - Double(lo))
        return min(max(floorDB + aboveFloorDB, thresholdMinDB), thresholdMaxDB)
    }

    /// Speech regions as [start, end) frame pairs after closing short pauses and dropping short blips.
    /// Exposed (internal) so the self-test can check "every speech frame lands in exactly one piece".
    static func speechRegions(_ samples: [Int16], sampleRate: Int = 16000) -> [(Int, Int)] {
        analyze(frameDB(samples[...], sampleRate: sampleRate)).regions
    }

    private static func runs(_ mask: [Bool], value: Bool) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        let n = mask.count
        var i = 0
        while i < n {
            if mask[i] == value {
                var j = i
                while j < n && mask[j] == value { j += 1 }
                out.append((i, j))
                i = j
            } else {
                i += 1
            }
        }
        return out
    }

    private static func analyze(_ db: [Double], minThreshold: Double? = nil) -> (regions: [(Int, Int)], thr: Double?) {
        guard var thr = threshold(frameDB: db) else { return ([], nil) }
        if let m = minThreshold { thr = max(thr, m) }
        var speech = db.map { $0 > thr }
        let n = speech.count
        let minPauseF = Int((minPauseSeconds / frameSeconds).rounded(.toNearestOrEven))
        // Close pauses with speech on both sides (the leading and trailing silence stay open).
        for (s, e) in runs(speech, value: false) where s > 0 && e < n && (e - s) < minPauseF {
            for k in s..<e { speech[k] = true }
        }
        let minSpeechF = Int((minSpeechSeconds / frameSeconds).rounded(.toNearestOrEven))
        for (s, e) in runs(speech, value: true) where (e - s) < minSpeechF {
            for k in s..<e { speech[k] = false }
        }
        return (runs(speech, value: true), thr)
    }

    // MARK: Cut

    /// Cut one whole track into pieces. `forcedCuts` are times in seconds (speaker turn changes) that must be a piece
    /// boundary: inside speech they split the region, inside a pause they pin the boundary there. `minThreshold`
    /// (dBFS), when given, is a floor under the computed threshold: threshold = max(computed, minThreshold). The notes
    /// pipeline passes the measured residual-echo level plus a margin for the echo-cancelled microphone track.
    static func cut(_ samples: [Int16], sampleRate: Int = 16000, forcedCuts: [Double] = [],
                    minThreshold: Double? = nil) -> [CutPiece] {
        let fs = frameSeconds
        let db = frameDB(samples[...], sampleRate: sampleRate)
        let base = analyze(db, minThreshold: minThreshold).regions
        if base.isEmpty { return [] }
        let nframes = db.count

        var regS = base.map { $0.0 }
        var regE = base.map { $0.1 }
        // kinds[i] is the boundary kind between region i and i+1; cuts[i] is the forced cut frame of a forced pause.
        var kinds = [Kind](repeating: .pause, count: base.count - 1)
        var cuts = [Int?](repeating: nil, count: base.count - 1)

        // 7. forced cuts. Python round() is half-to-even, so use the same rule.
        for t in forcedCuts.sorted() {
            let c = Int((t / fs).rounded(.toNearestOrEven))
            var done = false
            for i in 0..<regS.count where regS[i] < c && c < regE[i] {
                let e = regE[i]
                regE[i] = c
                regS.insert(c, at: i + 1)
                regE.insert(e, at: i + 1)
                kinds.insert(.forcedIn, at: i)
                cuts.insert(nil, at: i)
                done = true
                break
            }
            if done { continue }
            if regS.count >= 2 {
                for i in 0..<(regS.count - 1) where regE[i] <= c && c <= regS[i + 1] {
                    // Reference breaks at the first matching gap even when it is not a plain pause.
                    if kinds[i] == .pause {
                        kinds[i] = .forced
                        cuts[i] = c
                    }
                    break
                }
            }
        }

        // 8. hard splits of regions longer than the limit, at the quietest 50 ms of the last 3 s before it.
        let maxF = Int(((maxPieceSeconds - 2 * padSeconds) / fs).rounded(.toNearestOrEven))
        let search = Int((hardSearchSeconds / fs).rounded(.toNearestOrEven))
        let k5 = smoothFrames
        // Centred moving average with zero padding, as numpy.convolve(mode="same") does.
        func smoothed(_ i: Int) -> Double {
            var acc = 0.0
            for j in (i - k5 / 2)...(i + k5 / 2) where j >= 0 && j < nframes { acc += db[j] * (1.0 / Double(k5)) }
            return acc
        }
        var i = 0
        while i < regS.count {
            let s = regS[i], e = regE[i]
            if e - s > maxF {
                let lo = s + maxF - search
                let hi = s + maxF
                var bestIdx = lo
                var bestVal = Double.infinity
                for j in lo..<hi {
                    let v = smoothed(j)
                    if v < bestVal { bestVal = v; bestIdx = j }
                }
                regE[i] = bestIdx
                regS.insert(bestIdx, at: i + 1)
                regE.insert(e, at: i + 1)
                kinds.insert(.hard, at: i)
                cuts.insert(nil, at: i)
            } else {
                i += 1
            }
        }

        let n = regS.count
        let pad = Int((padSeconds / fs).rounded(.toNearestOrEven))
        func gap(_ i: Int) -> Int { regS[i + 1] - regE[i] }

        // 9. padding: none across hard or forced-inside cuts, at most half the pause, never across a forced cut.
        var before = [Int](repeating: 0, count: n)
        var after = [Int](repeating: 0, count: n)
        for i in 0..<n {
            if i == 0 {
                before[i] = min(pad, regS[0])
            } else {
                let kd = kinds[i - 1]
                if kd == .hard || kd == .forcedIn {
                    before[i] = 0
                } else {
                    var v = min(pad, gap(i - 1) / 2)
                    if kd == .forced, let c = cuts[i - 1] { v = min(v, regS[i] - c) }
                    before[i] = v
                }
            }
            if i == n - 1 {
                after[i] = min(pad, nframes - regE[i])
            } else {
                let kd = kinds[i]
                if kd == .hard || kd == .forcedIn {
                    after[i] = 0
                } else {
                    var v = min(pad, gap(i) / 2)
                    if kd == .forced, let c = cuts[i] { v = min(v, c - regE[i]) }
                    after[i] = v
                }
            }
        }
        func span(_ i: Int, _ k: Int) -> Int { (regE[k] + after[k]) - (regS[i] - before[i]) }

        // 10. greedy grouping toward >= 14 s pieces, never over 28 s, never across a pause of 2 s or more.
        let longF = Int((longPauseSeconds / fs).rounded(.toNearestOrEven))
        let maxPieceF = Int((maxPieceSeconds / fs).rounded(.toNearestOrEven))
        let minTargetF = Int((minTargetSeconds / fs).rounded(.toNearestOrEven))
        func r3(_ x: Double) -> Double { (x * 1000).rounded(.toNearestOrEven) / 1000 }
        var pieces: [CutPiece] = []
        var start = 0
        while start < n {
            var k = start
            var cands = [start]
            while k + 1 < n && kinds[k] == .pause && gap(k) < longF && span(start, k + 1) <= maxPieceF {
                k += 1
                cands.append(k)
            }
            var end = k
            if k + 1 < n && kinds[k] == .pause && gap(k) < longF {
                // Stopped only because the next region would exceed the 28 s limit.
                let good = cands.filter { span(start, $0) >= minTargetF }
                if good.isEmpty {
                    end = cands[cands.count - 1]
                } else {
                    var best = good[0]
                    for c in good where gap(c) >= gap(best) { best = c }  // ties go to the later candidate
                    end = best
                }
            }
            var speechF = 0
            for j in start...end { speechF += regE[j] - regS[j] }
            pieces.append(CutPiece(
                start: r3(Double(regS[start] - before[start]) * fs),
                end: r3(Double(regE[end] + after[end]) * fs),
                speech: r3(Double(speechF) * fs),
                // The reference flags only "hard"; the API contract also joins forced-inside cuts with a plain space.
                hardStart: start > 0 && (kinds[start - 1] == .hard || kinds[start - 1] == .forcedIn),
                hardEnd: end < n - 1 && (kinds[end] == .hard || kinds[end] == .forcedIn)))
            start = end + 1
        }
        return pieces
    }

    // MARK: Retry split

    /// Where to split one piece for a retry: the middle of the longest run of frames below `threshold`
    /// lying strictly inside (start, end) (run must not touch either edge); when there is none, the frame
    /// with the minimum 5-frame centred moving average of dB inside the middle 60% of the piece. Returns seconds.
    static func splitPoint(frameDB db: [Double], threshold: Double, start: Double, end: Double) -> Double {
        let fs = frameSeconds
        let n = db.count
        let a = min(max(Int((start / fs).rounded(.toNearestOrEven)), 0), n)
        let b = min(max(Int((end / fs).rounded(.toNearestOrEven)), a), n)
        var bestLen = 0
        var bestMid = 0.0
        var i = a
        while i < b {
            if db[i] < threshold {
                var j = i
                while j < b && db[j] < threshold { j += 1 }
                // A run that starts at the first frame or reaches the last frame touches an edge: skip it.
                if i > a && j < b && (j - i) > bestLen {
                    bestLen = j - i
                    bestMid = Double(i + j) / 2.0 * fs
                }
                i = j
            } else {
                i += 1
            }
        }
        if bestLen > 0 { return bestMid }

        // No inner quiet run: the quietest smoothed frame in the middle 60% of the piece.
        let len = b - a
        var lo = a + Int((0.2 * Double(len)).rounded(.up))
        var hi = a + Int((0.8 * Double(len)).rounded(.down))
        if n == 0 { return (start + end) / 2 }
        lo = min(max(lo, 0), n - 1)
        hi = min(max(hi, lo), n - 1)
        var bestIdx = lo
        var bestVal = Double.infinity
        for j in lo...hi {
            var acc = 0.0
            var cnt = 0
            for q in max(0, j - 2)...min(n - 1, j + 2) { acc += db[q]; cnt += 1 }
            let v = acc / Double(cnt)
            if v < bestVal { bestVal = v; bestIdx = j }
        }
        return Double(bestIdx) * fs
    }
}
