import Foundation

/// The echo stage's DSP on synthetic signals, run from --notestest. Deterministic (seeded generator).
/// The measured value of each check is in its label, so a passing run still shows the numbers.
enum EchoChecks {
    private struct RNG {
        var state: UInt64
        mutating func next() -> UInt64 {   // splitmix64
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        /// Uniform in [-1, 1).
        mutating func uniform() -> Double { Double(next() >> 11) / 9_007_199_254_740_992.0 * 2 - 1 }
    }

    /// "Noise-like speech": the sum of 4 uniforms, scaled to an exact RMS.
    private static func noiseLike(_ n: Int, rms: Double, _ rng: inout RNG) -> [Double] {
        var x = [Double](repeating: 0, count: n)
        var e = 0.0
        for i in 0..<n {
            let v = rng.uniform() + rng.uniform() + rng.uniform() + rng.uniform()
            x[i] = v
            e += v * v
        }
        let scale = e > 0 ? rms / (e / Double(n)).squareRoot() : 0
        for i in 0..<n { x[i] *= scale }
        return x
    }

    private static func toInt16(_ x: [Double]) -> [Int16] {
        x.map { Int16(max(-32768.0, min(32767.0, ($0 * 32768.0).rounded()))) }
    }

    private static func f(_ v: Double, _ digits: Int = 1) -> String { String(format: "%.\(digits)f", v) }

    private static func delayed(_ x: [Double], by d: Int, gain: Double) -> [Double] {
        var y = [Double](repeating: 0, count: x.count)
        for i in d..<x.count { y[i] = gain * x[i - d] }
        return y
    }

    private static func room(_ x: [Double], taps: [(Int, Double)]) -> [Double] {
        var y = [Double](repeating: 0, count: x.count)
        for (d, g) in taps {
            for i in d..<x.count { y[i] += g * x[i - d] }
        }
        return y
    }

    private static func erle(echo: [Double], residual: [Double], from: Int) -> Double {
        var num = 0.0, den = 0.0
        for i in from..<echo.count {
            num += echo[i] * echo[i]
            den += residual[i] * residual[i]
        }
        return 10 * log10(num / max(den, 1e-30))
    }

    static func run(_ check: (Bool, String, String) -> Void) {
        let fs = 16000
        var rng = RNG(state: 0x7A1F_10E5_C0DE_2026)

        // E0 FFT and convolution against their direct forms.
        var re = (0..<4096).map { _ in rng.uniform() }
        var im = (0..<4096).map { _ in rng.uniform() }
        let re0 = re, im0 = im
        EchoFFT.transform(&re, &im, inverse: false)
        EchoFFT.transform(&re, &im, inverse: true)
        var fftErr = 0.0
        for i in 0..<4096 { fftErr = max(fftErr, abs(re[i] - re0[i]), abs(im[i] - im0[i])) }
        check(fftErr < 1e-9, "EC E0 FFT round trip, 4096 points (max error \(String(format: "%.2e", fftErr)))", "\(fftErr)")

        let ca = (0..<100).map { _ in rng.uniform() }
        let cb = (0..<37).map { _ in rng.uniform() }
        var direct = [Double](repeating: 0, count: 136)
        for i in 0..<100 { for j in 0..<37 { direct[i + j] += ca[i] * cb[j] } }
        let fast = EchoStage.convolve(ca, cb, count: 136)
        var convErr = 0.0
        for i in 0..<136 { convErr = max(convErr, abs(fast[i] - direct[i])) }
        let short = EchoStage.convolve(ca, cb, count: 50)
        for i in 0..<50 { convErr = max(convErr, abs(short[i] - direct[i])) }
        check(convErr < 1e-9 && short.count == 50, "EC E0 FFT convolution equals direct (max error \(String(format: "%.2e", convErr)))", "\(convErr)")

        // E1 pure delay: 0.25 * ref delayed by 960 samples + noise.
        let n30 = 30 * fs
        let ref1 = noiseLike(n30, rms: 0.05, &rng)
        let noise1 = noiseLike(n30, rms: 1e-3, &rng)
        var mic1 = delayed(ref1, by: 960, gain: 0.25)
        for i in 0..<n30 { mic1[i] += noise1[i] }
        let refI1 = toInt16(ref1), micI1 = toInt16(mic1)
        let fit1 = EchoStage.fitDelay(EchoStage.delayTrack(mic: micI1, ref: refI1))
        check(fit1 != nil && abs(fit1!.a - 960) <= 1 && fit1!.b == 0 && fit1!.inliers == fit1!.windows,
              "EC E1 pure 960-sample delay is found, no drift, all windows on the line (a \(f(fit1?.a ?? -1)), b*1e6 \(f((fit1?.b ?? -1) * 1e6)), \(fit1?.inliers ?? -1)/\(fit1?.windows ?? -1))",
              "\(String(describing: fit1))")

        // E2 drift: lag(n) = 960 + 100e-6 * n.
        let n60 = 60 * fs
        // Own generator: the fitted slope of white noise scatters about +-10 ppm with the realisation (the numpy
        // reference does too: 93..110.5 over 8 seeds), so the seed is fixed here, not tuned per run, and the band is
        // 85..115 ppm (the spike's own +-10 ppm was met on its fixtures: 102.5 / 103.5 ppm, also here in --echotest).
        var rng2 = RNG(state: 0x2E02_0D21_F700_0003)
        let ref2 = noiseLike(n60, rms: 0.05, &rng2)
        let noise2 = noiseLike(n60, rms: 1e-3, &rng2)
        var mic2 = [Double](repeating: 0, count: n60)
        for i in 0..<n60 {
            let src = Double(i) - (960 + 100e-6 * Double(i))
            var v = 0.0
            if src >= 0 {
                let i0 = Int(src)
                let fr = src - Double(i0)
                v = ref2[i0] + fr * (ref2[min(i0 + 1, n60 - 1)] - ref2[i0])
            }
            mic2[i] = 0.25 * v + noise2[i]
        }
        let fit2 = EchoStage.fitDelay(EchoStage.delayTrack(mic: toInt16(mic2), ref: toInt16(ref2)))
        let ppm2 = (fit2?.b ?? 0) * 1e6
        check(fit2 != nil && ppm2 >= 85 && ppm2 <= 115,
              "EC E2 +100 ppm drift is fitted within 85..115 ppm (\(f(ppm2)) ppm, \(fit2?.inliers ?? -1)/\(fit2?.windows ?? -1))",
              "\(String(describing: fit2))")

        // E3 independent signals: gate closed, bit-exact bypass.
        let ref3 = toInt16(noiseLike(n30, rms: 0.05, &rng))
        let mic3 = toInt16(noiseLike(n30, rms: 0.05, &rng))
        let fit3 = EchoStage.fitDelay(EchoStage.delayTrack(mic: mic3, ref: ref3))
        let res3 = EchoStage.run(mic: mic3, system: ref3, headphones: false)
        check(fit3 == nil && res3.bypass == .noEcho && res3.fit == nil && res3.samples == mic3,
              "EC E3 independent signals: no fit, noEcho bypass, samples identical", "\(String(describing: fit3))")

        // E4 headphones.
        let res4 = EchoStage.run(mic: micI1, system: refI1, headphones: true)
        check(res4.bypass == .headphones && res4.samples == micI1, "EC E4 headphones: bypass, samples identical", "\(String(describing: res4.bypass))")

        // E5 room echo, segmented path (40 s > SEG + OVL).
        let n40 = 40 * fs
        let ref5 = noiseLike(n40, rms: 0.05, &rng)
        let echo5 = room(ref5, taps: [(960, 0.4), (1040, 0.25), (1400, -0.12), (2400, 0.05)])
        let noise5 = noiseLike(n40, rms: pow(10, -4.5), &rng)
        var mic5 = echo5
        for i in 0..<n40 { mic5[i] += noise5[i] }
        let refI5 = toInt16(ref5)
        let res5 = EchoStage.run(mic: toInt16(mic5), system: refI5, headphones: false)
        var resid5 = [Double](repeating: 0, count: n40)
        for i in 0..<n40 { resid5[i] = Double(res5.samples[i]) / 32768.0 - noise5[i] }
        let erle5 = res5.samples.count == n40 ? erle(echo: echo5, residual: resid5, from: 2 * fs) : -99
        check(res5.bypass == nil && erle5 >= 25,
              "EC E5 room echo cancelled by >= 25 dB (ERLE \(f(erle5)) dB, a \(f(res5.fit?.a ?? -1)), b*1e6 \(f((res5.fit?.b ?? -1) * 1e6)))",
              "erle \(erle5)")

        // E6 the same with near-end speech gated 2 s on / 2 s off.
        var near6 = noiseLike(n40, rms: 0.05, &rng)
        for i in 0..<n40 where (i / (2 * fs)) % 2 == 1 { near6[i] = 0 }
        var mic6 = mic5
        for i in 0..<n40 { mic6[i] += near6[i] }
        let res6 = EchoStage.run(mic: toInt16(mic6), system: refI5, headphones: false)
        var resid6 = [Double](repeating: 0, count: n40)
        for i in 0..<n40 { resid6[i] = Double(res6.samples[i]) / 32768.0 - near6[i] - noise5[i] }
        let erle6 = res6.samples.count == n40 ? erle(echo: echo5, residual: resid6, from: 2 * fs) : -99
        check(res6.bypass == nil && erle6 >= 15,
              "EC E6 echo under double talk cancelled by >= 15 dB (ERLE \(f(erle6)) dB)", "erle \(erle6)")

        // E7 5 s signal: too short for a fit, gate closed.
        let n5 = 5 * fs
        let res7 = EchoStage.run(mic: Array(micI1[0..<n5]), system: Array(refI1[0..<n5]), headphones: false)
        check(res7.bypass == .noEcho && res7.samples == Array(micI1[0..<n5]), "EC E7 5 s input: gate closed, samples identical", "\(String(describing: res7.bypass))")

        // G1-G5 the near-end gate: frames the canceller emptied are zeroed, frames with speech are not.
        var rngG = RNG(state: 0x6A7E_0001_2026_1123)
        let rawG = toInt16(noiseLike(2 * fs, rms: 0.05, &rngG))
        func scaled(_ x: [Int16], _ gain: Double, upTo: Int = Int.max) -> [Int16] {
            x.enumerated().map { $0.offset < upTo ? Int16((Double($0.element) * gain).rounded()) : $0.element }
        }
        let g1 = NearEndGate.apply(raw: rawG, cleaned: scaled(rawG, 0.01))
        check(g1.samples.allSatisfy { $0 == 0 } && abs(g1.zeroedSeconds - 2.0) <= 0.01,
              "EC G1 echo only (-40 dB) is zeroed whole (\(f(g1.zeroedSeconds, 2)) s)", "\(g1.zeroedSeconds)")
        let g2 = NearEndGate.apply(raw: rawG, cleaned: rawG)
        check(g2.samples == rawG && g2.zeroedSeconds == 0, "EC G2 nothing removed: unchanged", "\(g2.zeroedSeconds)")
        let cleanedG3 = scaled(rawG, 0.01, upTo: fs)
        let g3 = NearEndGate.apply(raw: rawG, cleaned: cleanedG3)
        check(g3.samples[0..<(fs - 320)].allSatisfy { $0 == 0 } && Array(g3.samples[(fs + 320)...]) == Array(cleanedG3[(fs + 320)...]),
              "EC G3 echo then speech: the first second is zeroed, the speech kept (\(f(g3.zeroedSeconds, 2)) s)", "\(g3.zeroedSeconds)")
        let g4 = NearEndGate.apply(raw: rawG, cleaned: scaled(rawG, 0.5))
        check(g4.samples == scaled(rawG, 0.5) && g4.zeroedSeconds == 0, "EC G4 -6 dB removed: unchanged", "\(g4.zeroedSeconds)")
        let silence = [Int16](repeating: 0, count: 2 * fs)
        let g5 = NearEndGate.apply(raw: silence, cleaned: silence)
        check(g5.samples == silence && g5.zeroedSeconds == 0, "EC G5 digital silence: unchanged", "\(g5.zeroedSeconds)")
    }
}
