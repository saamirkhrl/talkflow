import Foundation

/// The after-Stop pipeline's pure rules (pause cutter, transcript echo rule), run from --notestest.
/// Cutter cases mirror the transcription spike's cutter.py self-test (T1..T11); rule cases mirror the echo spike's
/// selftest_rule.py (T1..T18). All signals are synthetic and deterministic.
enum NotesPipelineChecks {
    static func run(_ check: (Bool, String, String) -> Void) {
        runCutter(check)
        runSplitPoint(check)
        runEchoRule(check)
    }

    // MARK: Synthetic signals

    /// Small deterministic PRNG (SplitMix64) so the signals are identical on every run and every machine.
    private struct Rng {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        /// Uniform in (0, 1].
        mutating func unit() -> Double { (Double(next() >> 11) + 1.0) / 9_007_199_254_740_992.0 }
        mutating func uniform(_ a: Double, _ b: Double) -> Double { a + (b - a) * unit() }
        /// Gaussian by Box-Muller.
        mutating func gauss() -> Double { (-2 * log(unit())).squareRoot() * cos(2 * Double.pi * unit()) }
    }

    private static let sr = 16000

    /// Gaussian noise bed at -60 dBFS RMS, as in the reference self-test.
    private static func noise(_ seconds: Double) -> [Double] {
        var rng = Rng(state: 11)
        let sigma = 32768.0 * pow(10.0, -60.0 / 20.0)
        return (0..<Int((seconds * Double(sr)).rounded())).map { _ in sigma * rng.gauss() }
    }

    /// Adds a 300 Hz sine burst of the given RMS level (dBFS) over [t0, t1).
    private static func burst(_ sig: inout [Double], _ t0: Double, _ t1: Double, _ level: Double = -20) {
        let a = Int((t0 * Double(sr)).rounded()), b = min(Int((t1 * Double(sr)).rounded()), sig.count)
        let amp = 32768.0 * pow(10.0, level / 20.0) * 2.0.squareRoot()
        for k in a..<b { sig[k] += amp * sin(2 * Double.pi * 300 * Double(k) / Double(sr)) }
    }

    private static func toInt16(_ sig: [Double]) -> [Int16] {
        sig.map { Int16(max(-32768, min(32767, $0.rounded(.toNearestOrEven)))) }
    }

    private static func signal(_ seconds: Double, _ bursts: [(Double, Double)], level: Double = -20) -> [Int16] {
        var s = noise(seconds)
        for (a, b) in bursts { burst(&s, a, b, level) }
        return toInt16(s)
    }

    // MARK: Cutter

    private static func show(_ pieces: [CutPiece]) -> String {
        "[" + pieces.map { String(format: "(%.3f, %.3f, speech %.3f)", $0.start, $0.end, $0.speech) }.joined(separator: ", ") + "]"
    }

    private static func matches(_ pieces: [CutPiece], _ expect: [(Double, Double)], tol: Double = 0.011) -> Bool {
        guard pieces.count == expect.count else { return false }
        for (p, e) in zip(pieces, expect) where abs(p.start - e.0) > tol || abs(p.end - e.1) > tol { return false }
        return true
    }

    private static func runCutter(_ check: (Bool, String, String) -> Void) {
        func rec(_ ok: Bool, _ label: String, _ pieces: [CutPiece], _ expected: String) {
            check(ok, label, ok ? "" : "got \(show(pieces)), expected \(expected)")
        }

        var p = PauseCutter.cut(toInt16(noise(10)))
        rec(p.isEmpty, "PC T1 noise only gives no pieces", p, "[]")

        p = PauseCutter.cut([Int16](repeating: 0, count: 10 * sr))
        rec(p.isEmpty, "PC T1b digital zeros give no pieces", p, "[]")

        p = PauseCutter.cut(signal(5, [(1.0, 3.0)]))
        rec(matches(p, [(0.8, 3.2)]) && abs(p[0].speech - 2.0) < 0.011, "PC T2 single burst padded 0.2 s", p, "[(0.8, 3.2)] speech 2.0")

        let sigM1 = signal(5, [(1.0, 3.0)])
        p = PauseCutter.cut(sigM1, minThreshold: -10)
        rec(p.isEmpty, "PC M1 minThreshold -10 gives no pieces", p, "[]")
        p = PauseCutter.cut(sigM1, minThreshold: -50)
        rec(matches(p, [(0.8, 3.2)]) && abs(p[0].speech - 2.0) < 0.011, "PC M1 minThreshold -50 keeps the T2 piece", p, "[(0.8, 3.2)] speech 2.0")

        p = PauseCutter.cut(signal(5, [(1.0, 2.0), (2.2, 3.0)]))
        rec(matches(p, [(0.8, 3.2)]) && abs(p[0].speech - 2.0) < 0.011, "PC T3 0.2 s gap is closed", p, "[(0.8, 3.2)] speech 2.0")

        p = PauseCutter.cut(signal(10, [(5.00, 5.05)]))
        rec(p.isEmpty, "PC T4 50 ms blip is dropped", p, "[]")

        p = PauseCutter.cut(signal(15, [(1, 4), (10, 13)]))
        rec(matches(p, [(0.8, 4.2), (9.8, 13.2)]), "PC T5 pause over 2 s always cuts", p, "[(0.8, 4.2), (9.8, 13.2)]")

        let b6: [(Double, Double)] = (0..<10).map { m in (1 + 4.5 * Double(m), 5 + 4.5 * Double(m)) }
        p = PauseCutter.cut(signal(47, b6))
        rec(matches(p, [(0.8, 27.7), (27.8, 45.7)]), "PC T6 two pieces at the 28 s limit", p, "[(0.8, 27.7), (27.8, 45.7)]")

        var b7: [(Double, Double)] = []
        for m in 0..<10 {
            let off = m < 4 ? 0.0 : 0.5
            b7.append((1 + off + 4.5 * Double(m), 5 + off + 4.5 * Double(m)))
        }
        p = PauseCutter.cut(signal(48, b7))
        rec(matches(p, [(0.8, 18.7), (19.3, 46.2)]), "PC T7 splits at the longest gap", p, "[(0.8, 18.7), (19.3, 46.2)]")

        var s8 = noise(43)
        burst(&s8, 1.0, 27.00)
        burst(&s8, 27.03, 41.0)
        p = PauseCutter.cut(toInt16(s8))
        let ok8 = p.count == 2 && p[0].hardEnd && p[1].hardStart
            && abs(p[0].start - 0.8) <= 0.011 && abs(p[1].end - 41.2) <= 0.011
            && p[0].end >= 27.00 - 0.011 && p[0].end <= 27.02 + 0.011 && abs(p[0].end - p[1].start) <= 1e-9
        rec(ok8, "PC T8 hard split in a 40 s monologue", p, "2 pieces (0.8, c) hardEnd, (c, 41.2) hardStart, c in [27.00, 27.02]")

        let s9 = signal(10, [(1.0, 5.0), (5.5, 9.0)])
        p = PauseCutter.cut(s9, forcedCuts: [3.0])
        rec(matches(p, [(0.8, 3.0), (3.0, 9.2)]), "PC T9 forced cut inside speech", p, "[(0.8, 3.0), (3.0, 9.2)]")

        p = PauseCutter.cut(s9, forcedCuts: [5.1])
        rec(matches(p, [(0.8, 5.1), (5.3, 9.2)]), "PC T9b forced cut inside a pause", p, "[(0.8, 5.1), (5.3, 9.2)]")

        p = PauseCutter.cut(signal(5, [(1.0, 3.0)], level: -44))
        rec(matches(p, [(0.8, 3.2)]), "PC T10 quiet burst at -44 dBFS is found", p, "[(0.8, 3.2)]")

        p = PauseCutter.cut(signal(5, [(1.0, 3.0)], level: -54))
        rec(p.isEmpty, "PC T10b burst at -54 dBFS is below the threshold", p, "[]")

        // T11: random bursts and gaps plus one 45 s burst; invariants only (the generator is not Python's).
        var rng = Rng(state: 5)
        var segs: [(Double, Double, Double)] = []
        var t = 0.5
        while t < 580 {
            let t1 = t + rng.uniform(0.2, 12.0)
            segs.append((t, t1, rng.uniform(-40, -15)))
            t = t1 + rng.uniform(0.05, 4.0)
        }
        let mid = segs.count / 2
        segs[mid] = (segs[mid].0, segs[mid].0 + 45.0, -25.0)
        var fixed = Array(segs[...mid])
        t = segs[mid].1 + rng.uniform(0.05, 4.0)
        for (a, b, level) in segs[(mid + 1)...] {
            let d = b - a
            if t + d >= 599 { break }
            fixed.append((t, t + d, level))
            t += d + rng.uniform(0.05, 4.0)
        }
        var s11 = noise(600)
        for (a, b, level) in fixed { burst(&s11, a, b, level) }
        let x11 = toInt16(s11)
        let pieces11 = PauseCutter.cut(x11)
        let regions = PauseCutter.speechRegions(x11)
        var fails: [String] = []
        for pc in pieces11 where pc.end - pc.start > 28.0 + 1e-9 { fails.append("too long \(pc.start)-\(pc.end)") }
        for (a, b) in zip(pieces11, pieces11.dropFirst()) where !(a.start < a.end && a.end <= b.start + 1e-9) {
            fails.append("order/overlap \(a.start)-\(a.end) vs \(b.start)-\(b.end)")
        }
        var cover = [Int](repeating: 0, count: x11.count / 160)
        for pc in pieces11 {
            let a = Int((pc.start / 0.010).rounded(.toNearestOrEven)), b = min(Int((pc.end / 0.010).rounded(.toNearestOrEven)), cover.count)
            if a < b { for k in a..<b { cover[k] += 1 } }
        }
        for (s, e) in regions where !cover[s..<e].allSatisfy({ $0 == 1 }) { fails.append("region \(s),\(e) not in exactly one piece") }
        check(fails.isEmpty && !pieces11.isEmpty && !regions.isEmpty, "PC T11 invariants on 600 s of random speech",
              "pieces \(pieces11.count) regions \(regions.count) " + fails.prefix(3).joined(separator: "; "))
    }

    private static func runSplitPoint(_ check: (Bool, String, String) -> Void) {
        func prep(_ bursts: [(Double, Double)], _ seconds: Double) -> ([Double], Double) {
            let db = PauseCutter.frameDB(signal(seconds, bursts)[...])
            return (db, PauseCutter.threshold(frameDB: db) ?? -50)
        }

        var (db, thr) = prep([(1.0, 4.0), (4.6, 8.0)], 9)
        var sp = PauseCutter.splitPoint(frameDB: db, threshold: thr, start: 0.8, end: 8.2)
        check(abs(sp - 4.30) <= 0.03, "PC split (a) cuts in the middle of the inner pause",
              String(format: "got %.3f, expected 4.30 +- 0.03", sp))

        (db, thr) = prep([(1.0, 9.0)], 10)
        sp = PauseCutter.splitPoint(frameDB: db, threshold: thr, start: 0.8, end: 9.2)
        check(sp >= 2.48 && sp <= 7.52, "PC split (b) no pause: quietest frame in the middle 60%",
              String(format: "got %.3f, expected within [2.48, 7.52]", sp))

        sp = PauseCutter.splitPoint(frameDB: db, threshold: -200, start: 0.8, end: 9.2)
        check(sp >= 2.48 && sp <= 7.52, "PC split (c) no frame below threshold still gives a point",
              String(format: "got %.3f, expected within [2.48, 7.52]", sp))
    }

    // MARK: Echo rule

    /// Word i gets the times [t0 + 0.3 i, t0 + 0.3 (i + 1)], like the reference self-test.
    private static func seg(_ text: String, _ t0: Double) -> TimedSegment {
        let ws = text.split(separator: " ").enumerated().map {
            TimedWord(text: String($1), start: t0 + 0.3 * Double($0), end: t0 + 0.3 * Double($0 + 1))
        }
        return TimedSegment(start: t0, end: t0 + 0.3 * Double(ws.count), text: text, words: ws)
    }

    private static func runEchoRule(_ check: (Bool, String, String) -> Void) {
        func rec(_ label: String, _ you: [TimedSegment], _ sys: [TimedSegment], _ expected: [String]) {
            let got = TranscriptEchoRule.apply(you: you, system: sys).map { $0.text }
            check(got == expected, label, "kept \(got), expected \(expected)")
        }
        func unchanged(_ label: String, _ you: [TimedSegment], _ sys: [TimedSegment]) {
            let got = TranscriptEchoRule.apply(you: you, system: sys)
            check(got == you, label, "kept \(got.map { $0.text }), expected the input unchanged")
        }
        let fourScore = "four score and seven years"

        unchanged("ER T1 no system speech leaves the user's words", [seg("I think we should ship it", 0)], [])
        rec("ER T2 removes a pure echo run", [seg("four score and seven years ago", 1.0)],
            [seg("Four score and seven years ago our fathers", 0.9)], [])
        unchanged("ER T3 same words far away in time are kept", [seg("four score and seven years ago", 1.0)],
                  [seg("four score and seven years ago", 10.0)])

        let t4 = TranscriptEchoRule.apply(you: [seg("alice was beginning four score and seven years to get tired", 0.0)],
                                          system: [seg("four score and seven years ago", 0.95)])
        check(t4.map { $0.text } == ["alice was beginning to get tired"] && t4.count == 1
              && abs(t4[0].start - 0.0) < 1e-9 && abs(t4[0].end - 3.3) < 1e-9,
              "ER T4 keeps the user's words around the echo",
              "got \(t4.map { "\($0.text) \($0.start)-\($0.end)" }), expected 'alice was beginning to get tired' 0.0-3.3")

        unchanged("ER T5 two matched stopwords are not a run", [seg("we the cat sat", 2.0)], [seg("we the people", 2.0)])
        rec("ER T6 short group of one matched word goes", [seg("Liberty.", 5.0)],
            [seg("conceived in liberty and dedicated", 4.5)], [])
        unchanged("ER T7 short group of stopwords stays", [seg("and the", 5.0)], [seg("and the people", 5.0)])
        rec("ER T8 fuzzy match catches a mishearing", [seg("four score and seben years", 1.0)], [seg(fourScore, 1.0)], [])
        rec("ER T9 bridges one unmatched token", [seg("four score and zzz seven years", 1.0)], [seg(fourScore, 1.0)], [])
        rec("ER T10 keeps a user word before the echo", [seg("yes four score and seven", 1.0)],
            [seg("four score and seven", 1.3)], ["yes"])
        rec("ER T10b drops a stopword left over after the echo", [seg("and four score and seven", 1.0)],
            [seg("four score and seven", 1.3)], [])
        rec("ER T11a echo 0.9 s late is inside the window", [seg(fourScore, 1.0)], [seg(fourScore, 1.9)], [])
        unchanged("ER T11b echo 1.6 s late is outside the window", [seg(fourScore, 1.0)], [seg(fourScore, 2.6)])
        rec("ER T12 only the echo group goes", [seg("hello there everyone", 0.0), seg(fourScore, 5.0)],
            [seg(fourScore, 5.05)], ["hello there everyone"])
        rec("ER T13 punctuation and hyphens are normalised", [seg("Four, score; AND seven-years", 1.0)],
            [seg(fourScore, 1.0)], [])
        rec("ER T14 neighbouring segments form one group", [seg("four score", 1.0), seg("and seven years", 1.7)],
            [seg(fourScore, 1.0)], [])
        rec("ER T15 segment without word times is spread uniformly",
            [TimedSegment(start: 1.0, end: 2.5, text: fourScore, words: [])], [seg(fourScore, 1.0)], [])
        unchanged("ER T16 unrelated system speech removes nothing", [seg("happy families are all alike", 3.0)],
                  [seg("call me ishmael some years ago", 3.0)])
        unchanged("ER T17 a run of stopwords only is kept", [seg("it was the thing", 1.0)], [seg("it was the best", 1.0)])

        let pairs: [([TimedSegment], [TimedSegment])] = [
            ([seg("I think we should ship it", 0)], []),
            ([seg("four score and seven years ago", 1.0)], [seg("four score and seven years ago", 10.0)]),
            ([seg("we the cat sat", 2.0)], [seg("we the people", 2.0)]),
            ([seg("happy families are all alike", 3.0)], [seg("call me ishmael some years ago", 3.0)]),
        ]
        let identical = pairs.allSatisfy { TranscriptEchoRule.apply(you: $0.0, system: $0.1) == $0.0 }
        check(identical, "ER T18 untouched segments come back identical", "T1, T3, T5, T16 outputs differ from their inputs")
    }
}
