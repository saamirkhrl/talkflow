import Foundation

/// One speech region of the echo-cancelled microphone track and what the residue rule decided about it.
struct EchoRegionDecision: Equatable {
    var start: Double          // seconds
    var end: Double
    /// Mean energy of the cleaned track over the region, dBFS.
    var levelDB: Double
    /// 10*log10(sum cleaned energy / sum echo-estimate energy) over the region minus the recording's leakage, dB.
    /// nil when the canceller estimated no echo there (the far end was silent).
    var aboveLeakDB: Double?
    var kept: Bool
    /// "near-end" | "no echo" | "echo residue"
    var reason: String
}

/// Drops the microphone's speech regions that are what the echo canceller left behind of the far end.
///
/// After the canceller, cleaned = raw - echoEstimate. Where only the far end speaks, the cleaned track is residue whose
/// energy follows the estimate: cleaned/estimate stays near this recording's leakage L (the median of that ratio
/// over the frames where the estimate is clearly active, a recording-wide constant). Where the user speaks, their voice
/// adds energy the estimate does not predict, so the ratio rises far above L. A region is dropped when its
/// energy-weighted ratio is less than `marginDB` above L.
///
/// Measured on the fake meeting (25 November 2026, `--notesprobe`, tools/build_silent.py): user pieces on
/// mic_speakers.wav sit 50.8 to 68.9 dB above L; residue pieces with the user silent sit -3.6 to +5.7 dB above L on
/// mic_speakers_silent.wav (L = -3.8 dB, the canceller barely works) and -0.0 to +4.9 dB on
/// mic_speakers_silent_quiet.wav (L = -9.8 dB). Margin 10 dB: 4.3 dB over the worst residue, and a user talking over
/// the far end at the same level as its echo still clears it unless the canceller removes under 5 dB.
/// Pure; no I/O.
enum EchoResidue {
    static let frame = 160                     // 10 ms at 16 kHz, the cutter's frame
    /// Echo-estimate frames this far above the estimate's own 5th percentile count as far-end active.
    static let activeAboveFloorDB = 15.0
    /// Fewer active frames than this (1 s): too little echo to measure the leakage, nothing is dropped.
    static let minActiveFrames = 100
    static let marginDB = 10.0
    /// Energy floor per frame (Int16 scale, mean square), so silence never divides by zero.
    static let energyFloor = 1e-6

    /// Mean square of each whole 10 ms frame (Int16 scale). `minus`, when given, is subtracted sample by sample first.
    static func frameEnergy(_ x: [Int16], minus y: [Int16]? = nil) -> [Double] {
        let n = x.count / frame
        var out = [Double](repeating: energyFloor, count: n)
        for f in 0..<n {
            var acc = 0.0
            for k in (f * frame)..<((f + 1) * frame) {
                var v = Double(x[k])
                if let y, k < y.count { v -= Double(y[k]) }
                acc += v * v
            }
            out[f] = max(acc / Double(frame), energyFloor)
        }
        return out
    }

    static func dB(_ energy: Double) -> Double {
        10 * log10(max(energy, energyFloor) / (32768.0 * 32768.0))
    }

    /// The recording's leakage L in dB: median of dB(clean) - dB(echo) over the frames whose echo estimate is at least
    /// activeAboveFloorDB above its 5th percentile. nil when fewer than minActiveFrames frames qualify.
    static func leakage(clean: [Double], echo: [Double]) -> (leakDB: Double, activeFrames: Int)? {
        let n = min(clean.count, echo.count)
        if n == 0 { return nil }
        let echoDB = echo[0..<n].map(dB)
        let sorted = echoDB.sorted()
        let floorDB = sorted[Int((Double(n - 1) * 0.05).rounded())]
        var ratios: [Double] = []
        for f in 0..<n where echoDB[f] >= floorDB + activeAboveFloorDB {
            ratios.append(dB(clean[f]) - echoDB[f])
        }
        if ratios.count < minActiveFrames { return nil }
        ratios.sort()
        return (ratios[ratios.count / 2], ratios.count)
    }

    /// The decision for frames a..<b. `echoActive` is the threshold (energy) above which an echo frame counts.
    static func decide(clean: [Double], echo: [Double], a: Int, b: Int, leakDB: Double, echoActive: Double) -> EchoRegionDecision {
        var sumC = 0.0
        var sumE = 0.0
        var anyActive = false
        for f in a..<b {
            sumC += clean[f]
            sumE += echo[f]
            if echo[f] >= echoActive { anyActive = true }
        }
        let count = Double(max(b - a, 1))
        let level = dB(sumC / count)
        let start = Double(a) * 0.01
        let end = Double(b) * 0.01
        if !anyActive {
            return EchoRegionDecision(start: start, end: end, levelDB: level, aboveLeakDB: nil, kept: true, reason: "no echo")
        }
        let above = 10 * log10(sumC / sumE) - leakDB
        let kept = above >= marginDB
        return EchoRegionDecision(start: start, end: end, levelDB: level, aboveLeakDB: above, kept: kept,
                                  reason: kept ? "near-end" : "echo residue")
    }

    /// `track` (the gated microphone) with every echo-residue region set to zero, the decision for every speech region
    /// the cutter would see (same threshold rule, `minThreshold` as the pipeline passes it), and the leakage.
    /// Unchanged (no decisions) when the leakage cannot be measured.
    static func apply(track: [Int16], raw: [Int16], cleaned: [Int16], minThreshold: Double?)
        -> (samples: [Int16], decisions: [EchoRegionDecision], leakDB: Double?, activeSeconds: Double, droppedSeconds: Double) {
        let clean = frameEnergy(cleaned)
        let echo = frameEnergy(raw, minus: cleaned)
        guard let leak = leakage(clean: clean, echo: echo) else { return (track, [], nil, 0, 0) }
        let echoDB = echo.map(dB).sorted()
        let floorDB = echoDB.isEmpty ? -100 : echoDB[Int((Double(echoDB.count - 1) * 0.05).rounded())]
        let echoActive = pow(10, (floorDB + activeAboveFloorDB) / 10) * 32768.0 * 32768.0
        let regions = PauseCutter.speechRegions(track, minThreshold: minThreshold)
        var out = track
        var decisions: [EchoRegionDecision] = []
        var dropped = 0
        let frames = min(clean.count, echo.count)
        for (s, e) in regions {
            let a = min(s, frames)
            let b = min(e, frames)
            if b <= a { continue }
            let d = decide(clean: clean, echo: echo, a: a, b: b, leakDB: leak.leakDB, echoActive: echoActive)
            decisions.append(d)
            if !d.kept {
                let lo = s * frame
                let hi = min(e * frame, out.count)
                for k in lo..<hi { out[k] = 0 }
                dropped += hi - lo
            }
        }
        return (out, decisions, leak.leakDB, Double(leak.activeFrames) * 0.01, Double(dropped) / 16000)
    }
}
