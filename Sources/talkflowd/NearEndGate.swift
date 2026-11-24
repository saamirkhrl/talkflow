import Foundation

/// Silences the frames of the echo-cancelled microphone track where the canceller removed (almost) everything,
/// so the residual echo never reaches the pause cutter or whisper. Pure; no allocation beyond the output array
/// and the per-frame flags.
enum NearEndGate {
    /// A 10 ms frame is "echo only" when the canceller removed at least this much from it. Why 10 dB: on the echo
    /// fixtures the canceller removes 16.5 dB or more from pure echo (echo spike --echotest pe_30_* 16.5..17.5 dB,
    /// pe_12_* 24.7..27.5), while a frame where the user speaks loses less than 10 dB unless the echo at the mic is
    /// about 10 dB louder than the user's own voice (then the user's word may be lost: the known limit).
    static let removedDB = 10.0
    static let frame = 160            // 10 ms at 16 kHz, the cutter's frame

    /// Returns `cleaned` with every echo-only frame set to zero, and the seconds zeroed. A frame's dB is
    /// 20*log10(max(rms, 1e-3) / 32768) on the Int16 scale (the cutter's formula). echoOnly[f] = dbRaw[f] - dbClean[f]
    /// >= removedDB. Smoothing: frame f is zeroed when at least 3 of the 5 frames f-2...f+2 (those that exist) are echo
    /// only. The trailing partial frame follows the last whole frame. Lengths: n = cleaned.count; raw samples past its
    /// end count as 0.
    static func apply(raw: [Int16], cleaned: [Int16]) -> (samples: [Int16], zeroedSeconds: Double) {
        let n = cleaned.count
        let frames = n / frame
        if frames == 0 { return (cleaned, 0) }

        func db(_ x: [Int16], _ f: Int) -> Double {
            var acc = 0
            let base = f * frame
            for k in base..<(base + frame) where k < x.count {
                let v = Int(x[k])
                acc += v * v
            }
            let rms = (Double(acc) / Double(frame)).squareRoot()
            return 20.0 * log10(max(rms, 1e-3) / 32768.0)
        }

        var echoOnly = [Bool](repeating: false, count: frames)
        for f in 0..<frames {
            echoOnly[f] = db(raw, f) - db(cleaned, f) >= removedDB
        }

        var out = cleaned
        var zeroedFrames = 0
        var lastZeroed = false
        for f in 0..<frames {
            var count = 0
            for g in max(0, f - 2)...min(frames - 1, f + 2) where echoOnly[g] { count += 1 }
            lastZeroed = count >= 3
            if lastZeroed {
                zeroedFrames += 1
                for k in (f * frame)..<((f + 1) * frame) { out[k] = 0 }
            }
        }
        var zeroedSamples = zeroedFrames * frame
        if lastZeroed && n > frames * frame {
            for k in (frames * frame)..<n { out[k] = 0 }
            zeroedSamples += n - frames * frame
        }
        return (out, Double(zeroedSamples) / 16000.0)
    }
}
