import Foundation
import Accelerate

// The offline echo canceller for the note taker's "you" track: it removes what the speakers played
// (the system track) from the microphone track, after the meeting. Algorithm and constants are
// from the echo spike, RESULTS.md section 6.1 (reference: spikes/echo/aec.py). Samples are Int16 at
// 16 kHz; every threshold is on the [-1, 1) scale (Int16 / 32768). All FFT work is in Double.

/// One delay window: where it sits (sample), the lag GCC-PHAT found (samples) and how sharp the peak was.
struct DelayWindow: Equatable {
    var center: Double   // samples
    var lag: Double      // samples
    var ratio: Double    // peak / median
}

/// The fitted delay line: lag(n) = a + b * n samples.
struct DelayFit: Equatable {
    var a: Double
    var b: Double
    var inliers: Int
    var windows: Int
}

enum EchoBypass: String {
    case headphones
    case noEcho
}

struct EchoResult {
    var samples: [Int16]
    var fit: DelayFit?
    var bypass: EchoBypass?
}

/// Complex FFT in place on split Double arrays (vDSP_fft_zipD, radix 2). One setup for the process.
/// Forward is unscaled; inverse divides by N.
enum EchoFFT {
    private static let setup: FFTSetupD = vDSP_create_fftsetupD(20, FFTRadix(kFFTRadix2))!

    static func transform(_ re: inout [Double], _ im: inout [Double], inverse: Bool) {
        let n = re.count
        precondition(n == im.count && n >= 2 && n & (n - 1) == 0 && n <= (1 << 20))
        let log2n = vDSP_Length(n.trailingZeroBitCount)
        let direction = inverse ? FFTDirection(kFFTDirection_Inverse) : FFTDirection(kFFTDirection_Forward)
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPDoubleSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zipD(setup, &split, 1, log2n, direction)
                if inverse {
                    var scale = 1.0 / Double(n)
                    vDSP_vsmulD(rp.baseAddress!, 1, &scale, rp.baseAddress!, 1, vDSP_Length(n))
                    vDSP_vsmulD(ip.baseAddress!, 1, &scale, ip.baseAddress!, 1, vDSP_Length(n))
                }
            }
        }
    }

    static func nextPow2(_ n: Int) -> Int {
        var p = 1
        while p < n { p <<= 1 }
        return p
    }
}

enum EchoStage {
    // Constants from echo spike RESULTS.md 6.1.
    static let fs = 16000
    /// echo spike RESULTS.md 6.1: delay windows 8 s long so a window holds whole sentences, 4 s hop.
    static let win = 8 * fs
    static let hop = 4 * fs
    /// echo spike RESULTS.md 6.1: search -50 ms .. +500 ms; measured delays were 20-120 ms.
    static let maxLag = fs / 2
    static let neg = fs / 20
    /// echo spike RESULTS.md 6.1: -50 dBFS, a window or frame counts as far-end active above this RMS.
    static let silent = pow(10.0, -50.0 / 20.0)
    /// echo spike RESULTS.md 6.1: random GCC-PHAT lags fall within +-4 samples of a line with p about 1e-3 per window.
    static let tol = 4.0
    /// echo spike RESULTS.md 6.1: real clocks are within about 100 ppm.
    static let maxSlope = 300e-6
    static let top = 60
    /// echo spike RESULTS.md 6.1: digital echo gives 14/14 .. 21/21 windows on one line; chance agreement of 30% is negligible.
    static let minFrac = 0.3
    static let minInliers = 3
    /// echo spike RESULTS.md 6.1: drift fits were 102.5 / 103.5 ppm for a true 100 ppm and 0 everywhere else.
    static let zeroSlope = 20e-6
    /// echo spike RESULTS.md 6.1: 20 ms pre-delay kept in the filter, so a PHAT peak on a strong reflection cannot make the path non-causal.
    static let margin = 320
    /// echo spike RESULTS.md 6.1: NFFT 16384 / L 8192 (512 ms of path after the margin) covers the RT60 0.6 s tail below -30 dB.
    static let nfft = 16384
    static let pathLen = 8192
    static let hopW = nfft / 4
    static let regFactor = 1e-3
    /// echo spike RESULTS.md 6.1: 30 s segments beat 10-15 s ones on ERLE and double-talk residual; 5 s crossfade overlap.
    static let seg = 30 * fs
    static let ovl = 5 * fs

    /// np.hanning(nfft): 0.5 - 0.5 cos(2 pi m / (N - 1)).
    private static let hann: [Double] = (0..<nfft).map { 0.5 - 0.5 * cos(2.0 * Double.pi * Double($0) / Double(nfft - 1)) }

    // MARK: - Entry point

    /// Headphones or no coherent echo: the input array itself comes back (bit-exact).
    static func run(mic: [Int16], system: [Int16], headphones: Bool) -> EchoResult {
        if headphones { return EchoResult(samples: mic, fit: nil, bypass: .headphones) }
        guard let fit = fitDelay(delayTrack(mic: mic, ref: system)) else {
            return EchoResult(samples: mic, fit: nil, bypass: .noEcho)
        }
        return EchoResult(samples: cancel(mic: mic, system: system, fit: fit), fit: fit, bypass: nil)
    }

    // MARK: - Delay estimation (GCC-PHAT per window)

    static func delayTrack(mic: [Int16], ref: [Int16]) -> [DelayWindow] {
        let n = mic.count
        guard n > 0 else { return [] }
        let starts: [Int] = n > win ? Array(stride(from: 0, to: n - win + 1, by: hop)) : [0]
        var out: [DelayWindow] = []
        for s in starts {
            let len = min(win, n - s)
            let lf = EchoFFT.nextPow2(len + maxLag + 1)
            var xr = [Double](repeating: 0, count: lf)
            var xi = [Double](repeating: 0, count: lf)
            var energy = 0.0
            for i in 0..<len {
                let idx = s + i
                let v = idx < ref.count ? Double(ref[idx]) / 32768.0 : 0
                xr[i] = v
                energy += v * v
            }
            if (energy / Double(len) + 1e-20).squareRoot() < silent { continue }
            var yr = [Double](repeating: 0, count: lf)
            var yi = [Double](repeating: 0, count: lf)
            for i in 0..<len { yr[i] = Double(mic[s + i]) / 32768.0 }
            EchoFFT.transform(&xr, &xi, inverse: false)
            EchoFFT.transform(&yr, &yi, inverse: false)
            // G = Y * conj(X), then PHAT: G / (|G| + 1e-12). Reuse xr/xi for G.
            for k in 0..<lf {
                let gr = yr[k] * xr[k] + yi[k] * xi[k]
                let gi = yi[k] * xr[k] - yr[k] * xi[k]
                let mag = (gr * gr + gi * gi).squareRoot() + 1e-12
                xr[k] = gr / mag
                xi[k] = gi / mag
            }
            EchoFFT.transform(&xr, &xi, inverse: true)
            // lags -neg ..< 0 are cc[lf-neg ..< lf], lags 0...maxLag are cc[0...maxLag]
            var seg = [Double]()
            seg.reserveCapacity(neg + maxLag + 1)
            seg.append(contentsOf: xr[(lf - neg)..<lf])
            seg.append(contentsOf: xr[0...maxLag])
            var k = 0
            var peak = seg[0]
            for i in 1..<seg.count where seg[i] > peak {
                peak = seg[i]
                k = i
            }
            let med = median(seg.map { abs($0) })
            out.append(DelayWindow(center: Double(s + len / 2), lag: Double(k - neg), ratio: peak / (med + 1e-12)))
        }
        return out
    }

    private static func median(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        let m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }

    // MARK: - Robust line fit (RANSAC over pairs of the most confident windows)

    static func fitDelay(_ track: [DelayWindow]) -> DelayFit? {
        let act = track.count
        if act < 3 { return nil }
        let t = track.map { $0.center }
        let l = track.map { $0.lag }
        // TOP by ratio descending (ties: lower index first)
        let idx = Array(track.indices.sorted {
            track[$0].ratio != track[$1].ratio ? track[$0].ratio > track[$1].ratio : $0 < $1
        }.prefix(top))
        var bestCount = 0
        var bestA = 0.0, bestB = 0.0
        var found = false
        for ii in 0..<idx.count {
            for jj in (ii + 1)..<max(idx.count, ii + 1) {
                let i = idx[ii], j = idx[jj]
                if t[i] == t[j] { continue }
                let b = (l[j] - l[i]) / (t[j] - t[i])
                if abs(b) > maxSlope { continue }
                let a = l[i] - b * t[i]
                var c = 0
                for k in 0..<act where abs(l[k] - (a + b * t[k])) <= tol { c += 1 }
                if !found || c > bestCount {
                    found = true
                    bestCount = c
                    bestA = a
                    bestB = b
                }
            }
        }
        if !found { return nil }
        if bestCount < max(minInliers, Int((minFrac * Double(act)).rounded(.up))) { return nil }
        var it: [Double] = [], il: [Double] = []
        for k in 0..<act where abs(l[k] - (bestA + bestB * t[k])) <= tol {
            it.append(t[k])
            il.append(l[k])
        }
        let c = Double(it.count)
        let tm = it.reduce(0, +) / c
        let lm = il.reduce(0, +) / c
        var sxx = 0.0, sxy = 0.0
        for k in 0..<it.count {
            sxx += (it[k] - tm) * (it[k] - tm)
            sxy += (it[k] - tm) * (il[k] - lm)
        }
        var b = sxx > 0 ? sxy / sxx : 0
        var a = lm - b * tm
        if abs(b) < zeroSlope {
            a = median(il).rounded(.toNearestOrEven)
            b = 0
        }
        return DelayFit(a: a, b: b, inliers: it.count, windows: act)
    }

    // MARK: - Aligned reference, computed on the fly

    /// out[n] = ref(n - (a + b*n - margin)), linear interpolation, zero outside. Plain integer shift when b == 0 and a is an integer.
    private static func alignedSlice(system: [Int16], n: Int, fit: DelayFit, lo: Int, hi: Int) -> [Double] {
        var out = [Double](repeating: 0, count: hi - lo)
        let avail = min(n, system.count)
        if fit.b == 0 && fit.a == fit.a.rounded() {
            let d = Int(fit.a) - margin
            for i in lo..<hi {
                let j = i - d
                if j >= 0 && j < avail { out[i - lo] = Double(system[j]) / 32768.0 }
            }
            return out
        }
        for i in lo..<hi {
            let src = Double(i) - (fit.a + fit.b * Double(i) - Double(margin))
            if src < 0 || src > Double(n - 1) { continue }
            let i0 = Int(src.rounded(.down))
            let frac = src - Double(i0)
            let r0 = i0 < avail ? Double(system[i0]) / 32768.0 : 0
            let r1 = i0 + 1 < avail ? Double(system[i0 + 1]) / 32768.0 : 0
            out[i - lo] = r0 + frac * (r1 - r0)
        }
        return out
    }

    // MARK: - Wiener echo path

    /// Echo path estimate from the whole span: near-end speech is uncorrelated with the reference, so it averages out
    /// of the cross-spectrum and no double-talk detector is needed. Returns h[0..<pathLen].
    static func wienerPath(mic: [Double], ref: [Double]) -> [Double] {
        let n = nfft
        var sxx = [Double](repeating: 0, count: n)
        var sxyR = [Double](repeating: 0, count: n)
        var sxyI = [Double](repeating: 0, count: n)
        var xr = [Double](repeating: 0, count: n), xi = [Double](repeating: 0, count: n)
        var yr = [Double](repeating: 0, count: n), yi = [Double](repeating: 0, count: n)
        var frames = 0
        var s = 0
        while s + n <= mic.count {
            defer { s += hopW }
            var energy = 0.0
            for i in 0..<n { energy += ref[s + i] * ref[s + i] }
            if (energy / Double(n) + 1e-20).squareRoot() < silent { continue }
            for i in 0..<n {
                xr[i] = hann[i] * ref[s + i]
                yr[i] = hann[i] * mic[s + i]
                xi[i] = 0
                yi[i] = 0
            }
            EchoFFT.transform(&xr, &xi, inverse: false)
            EchoFFT.transform(&yr, &yi, inverse: false)
            for k in 0..<n {
                sxx[k] += xr[k] * xr[k] + xi[k] * xi[k]
                sxyR[k] += yr[k] * xr[k] + yi[k] * xi[k]
                sxyI[k] += yi[k] * xr[k] - yr[k] * xi[k]
            }
            frames += 1
        }
        if frames == 0 { return [Double](repeating: 0, count: pathLen) }
        var meanSxx = 0.0
        for k in 0...(n / 2) { meanSxx += sxx[k] }
        meanSxx /= Double(n / 2 + 1)
        let reg = regFactor * meanSxx + 1e-12
        for k in 0..<n {
            let d = sxx[k] + reg
            xr[k] = sxyR[k] / d
            xi[k] = sxyI[k] / d
        }
        EchoFFT.transform(&xr, &xi, inverse: true)
        var h = Array(xr[0..<pathLen])
        // taper the last 10% with the second half of np.hanning(2 * taper)
        let taper = Int(0.1 * Double(pathLen))
        let m = 2 * taper
        for i in 0..<taper {
            h[pathLen - taper + i] *= 0.5 - 0.5 * cos(2.0 * Double.pi * Double(taper + i) / Double(m - 1))
        }
        return h
    }

    // MARK: - Convolution (overlap-add, FFT)

    /// The first `count` samples of x * h.
    static func convolve(_ x: [Double], _ h: [Double], count: Int) -> [Double] {
        var out = [Double](repeating: 0, count: max(count, 0))
        guard count > 0, !x.isEmpty, !h.isEmpty else { return out }
        let fftN = h.count <= 8193 ? 16384 : EchoFFT.nextPow2(2 * h.count)
        let block = fftN / 2
        var hr = [Double](repeating: 0, count: fftN)
        var hi = [Double](repeating: 0, count: fftN)
        for i in 0..<h.count { hr[i] = h[i] }
        EchoFFT.transform(&hr, &hi, inverse: false)
        var br = [Double](repeating: 0, count: fftN)
        var bi = [Double](repeating: 0, count: fftN)
        let xlen = min(x.count, count)
        var b = 0
        while b < xlen {
            let len = min(block, xlen - b)
            for i in 0..<fftN {
                br[i] = i < len ? x[b + i] : 0
                bi[i] = 0
            }
            EchoFFT.transform(&br, &bi, inverse: false)
            for k in 0..<fftN {
                let r = br[k] * hr[k] - bi[k] * hi[k]
                let im = br[k] * hi[k] + bi[k] * hr[k]
                br[k] = r
                bi[k] = im
            }
            EchoFFT.transform(&br, &bi, inverse: true)
            let upto = min(fftN, count - b)
            for j in 0..<upto { out[b + j] += br[j] }
            b += block
        }
        return out
    }

    // MARK: - Cancellation

    private static func toInt16(_ v: Double) -> Int16 {
        let r = (v * 32768.0).rounded()
        if r.isNaN { return 0 }
        return Int16(max(-32768.0, min(32767.0, r)))
    }

    private static func micSlice(_ mic: [Int16], _ lo: Int, _ hi: Int) -> [Double] {
        (lo..<hi).map { Double(mic[$0]) / 32768.0 }
    }

    static func cancel(mic: [Int16], system: [Int16], fit: DelayFit) -> [Int16] {
        let n = mic.count
        if n == 0 { return [] }
        if n <= seg + ovl {
            let m = micSlice(mic, 0, n)
            let r = alignedSlice(system: system, n: n, fit: fit, lo: 0, hi: n)
            let h = wienerPath(mic: m, ref: r)
            let c = convolve(r, h, count: n)
            return (0..<n).map { toInt16(m[$0] - c[$0]) }
        }
        var out = [Int16]()
        out.reserveCapacity(n)
        var acc = [Double](), wacc = [Double]()
        var accStart = 0
        var s = 0
        while s < n {
            let lo = max(0, s - ovl)
            let hi = min(n, s + seg + ovl)
            let isLast = s + seg >= n
            s += seg
            let m = micSlice(mic, lo, hi)
            let r = alignedSlice(system: system, n: n, fit: fit, lo: lo, hi: hi)
            let h = wienerPath(mic: m, ref: r)
            let c = convolve(r, h, count: hi - lo)
            let span = hi - lo
            let ramp = min(ovl, span)
            let need = hi - accStart
            if acc.count < need {
                acc.append(contentsOf: [Double](repeating: 0, count: need - acc.count))
                wacc.append(contentsOf: [Double](repeating: 0, count: need - wacc.count))
            }
            for i in 0..<span {
                var w = 1.0
                if lo > 0 && i < ramp { w = ramp > 1 ? Double(i) / Double(ramp - 1) : 0 }
                if hi < n {
                    let k = i - (span - ramp)
                    if k >= 0 { w = min(w, ramp > 1 ? 1.0 - Double(k) / Double(ramp - 1) : 1.0) }
                }
                let at = lo - accStart + i
                acc[at] += w * (m[i] - c[i])
                wacc[at] += w
            }
            let upTo = isLast ? n : max(0, s - ovl)
            let count = upTo - accStart
            if count > 0 {
                for j in 0..<count { out.append(toInt16(acc[j] / max(wacc[j], 1e-9))) }
                acc.removeFirst(count)
                wacc.removeFirst(count)
                accStart = upTo
            }
        }
        return out
    }
}
