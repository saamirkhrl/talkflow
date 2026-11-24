import Foundation

/// Track alignment (TrackAlign, WavSamples.readPlaced, NotesJob.expandTimes), run from --notestest. Synthetic
/// timelines only. Expressions are kept small on purpose: CI's older compiler gives up on long literals.
enum TrackAlignChecks {
    private typealias TP = TrackPlacement
    private typealias Expansion = (at: Double, add: Double)

    private static let hostStart = 1000.0

    private static func P(_ i: Int64, _ h: Double) -> TimelinePoint { TimelinePoint(idx: i, host: h) }

    private static func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

    private static func sameExpansions(_ got: [Expansion], _ want: [Expansion]) -> Bool {
        if got.count != want.count { return false }
        for i in got.indices {
            if !near(got[i].at, want[i].at) || !near(got[i].add, want[i].add) { return false }
        }
        return true
    }

    private static func show(_ e: [Expansion]) -> String {
        var parts: [String] = []
        for x in e { parts.append("(\(x.at), \(x.add))") }
        return "[" + parts.joined(separator: ", ") + "]"
    }

    private static func plan(_ mic: [[TimelinePoint]]?, _ micLength: Int,
                             _ sys: [[TimelinePoint]]?, _ sysLength: Int) -> AlignPlan? {
        TrackAlign.plan(micSegments: mic, micLength: micLength, systemSegments: sys, systemLength: sysLength,
                        hostStart: hostStart)
    }

    private static func pointsEvery(_ step: Int64, to last: Int64, hostBase: Double) -> [TimelinePoint] {
        var out: [TimelinePoint] = []
        var i: Int64 = 0
        while i <= last {
            out.append(P(i, hostBase + Double(i) / 16000.0))
            i += step
        }
        return out
    }

    private static func runPlans(_ check: (Bool, String, String) -> Void) {
        // TA1 late system start, 12.4 s.
        let micA: [[TimelinePoint]] = [[P(0, 1000.0), P(16000, 1001.0), P(32000, 1002.0)]]
        let sysA: [[TimelinePoint]] = [[P(0, 1012.4), P(16000, 1013.4)]]
        let p1 = plan(micA, 48000, sysA, 32000)
        let want1: [Expansion] = [(at: 5.0, add: 7.4)]
        check(p1?.mic == [TP(src: 0, count: 48000, dst: 0)] && p1?.micLength == 48000,
              "TA1 late system start: mic stays", "got \(String(describing: p1?.mic)) \(String(describing: p1?.micLength))")
        check(p1?.system == [TP(src: 0, count: 32000, dst: 80000)] && p1?.systemLength == 112000,
              "TA1 late system start: system moves behind a shortened break",
              "got \(String(describing: p1?.system)) \(String(describing: p1?.systemLength))")
        check(sameExpansions(p1?.expansions ?? [], want1) && p1?.isIdentity == false,
              "TA1 late system start: one expansion of 7.4 s at 5.0 s", "got \(show(p1?.expansions ?? []))")
        let e4 = TrackAlign.expand(4.0, p1?.expansions ?? [])
        let e6 = TrackAlign.expand(6.0, p1?.expansions ?? [])
        check(near(e4, 4.0) && near(e6, 13.4), "TA1 expand before and after the break", "got \(e4), \(e6) vs 4.0, 13.4")

        // TA1b the mic covers the late start, nothing is removed.
        let p1b = plan(micA, 400000, sysA, 32000)
        check(p1b?.system == [TP(src: 0, count: 32000, dst: 198400)] && p1b?.expansions.isEmpty == true,
              "TA1b mic covers the late start: no removal", "got \(String(describing: p1b?.system))")

        // TA2 9 s break in the mic.
        let micB: [[TimelinePoint]] = [[P(0, 1000.0), P(16000, 1001.0)], [P(32000, 1011.0), P(48000, 1012.0)]]
        let sysB: [[TimelinePoint]] = [pointsEvery(16000, to: 192000, hostBase: 1000.0)]
        let p2 = plan(micB, 64000, sysB, 208000)
        let wantMic2: [TP] = [TP(src: 0, count: 32000, dst: 0), TP(src: 32000, count: 32000, dst: 176000)]
        check(p2?.mic == wantMic2 && p2?.micLength == 208000, "TA2 mic break: second segment placed 9 s later",
              "got \(String(describing: p2?.mic)) \(String(describing: p2?.micLength))")
        check(p2?.system == [TP(src: 0, count: 208000, dst: 0)] && p2?.expansions.isEmpty == true,
              "TA2 mic break: system covers it, nothing removed", "got \(String(describing: p2?.system))")
        let b2 = p2?.breaks ?? []
        check(b2.count == 1 && near(b2.first?.start ?? -1, 2.0) && near(b2.first?.end ?? -1, 11.0)
              && p2?.isIdentity == false, "TA2 mic break: one break from 2 s to 11 s", "got \(b2)")

        // TA3 both: break in the mic, late start in the system.
        let p3 = plan(micB, 64000, sysA, 32000)
        let wantMic3: [TP] = [TP(src: 0, count: 32000, dst: 0), TP(src: 32000, count: 32000, dst: 64000)]
        let want3: [Expansion] = [(at: 4.0, add: 7.0)]
        check(p3?.mic == wantMic3 && p3?.system == [TP(src: 0, count: 32000, dst: 86400)],
              "TA3 both: placements after the joint removal", "got \(String(describing: p3?.mic)) \(String(describing: p3?.system))")
        check(sameExpansions(p3?.expansions ?? [], want3), "TA3 both: one expansion of 7 s at 4 s", "got \(show(p3?.expansions ?? []))")
        let e3a = TrackAlign.expand(3.0, p3?.expansions ?? [])
        let e3b = TrackAlign.expand(5.0, p3?.expansions ?? [])
        check(near(e3a, 3.0) && near(e3b, 12.0), "TA3 both: expand", "got \(e3a), \(e3b) vs 3.0, 12.0")
        check(p3?.micLength == 96000 && p3?.systemLength == 118400, "TA3 both: lengths",
              "got \(String(describing: p3?.micLength)) \(String(describing: p3?.systemLength)) vs 96000 118400")

        // TA4 the system starts first.
        let micC: [[TimelinePoint]] = [[P(0, 1000.3)]]
        let sysC: [[TimelinePoint]] = [[P(0, 1000.1)]]
        let p4 = plan(micC, 16000, sysC, 16000)
        check(p4?.mic == [TP(src: 0, count: 16000, dst: 4800)] && p4?.system == [TP(src: 0, count: 16000, dst: 1600)]
              && p4?.expansions.isEmpty == true, "TA4 system starts first", "got \(String(describing: p4?.mic)) \(String(describing: p4?.system))")
        let sysD: [[TimelinePoint]] = [[P(0, 999.8)]]
        let p4b = plan(micC, 16000, sysD, 16000)
        check(p4b?.system == [TP(src: 3200, count: 12800, dst: 0)], "TA4b a start 0.2 s before the recording is trimmed",
              "got \(String(describing: p4b?.system))")

        // TA5 no timelines.
        let empty: [[TimelinePoint]] = []
        check(plan(nil, 16000, sysC, 16000) == nil, "TA5 no mic timeline gives no plan", "expected nil")
        check(plan(empty, 16000, sysC, 16000) == nil, "TA5 empty mic timeline gives no plan", "expected nil")
        check(plan(micC, 16000, nil, 16000) == nil, "TA5 no system timeline gives no plan", "expected nil")
        let same: [[TimelinePoint]] = [[P(0, 1000.0), P(16000, 1001.0)]]
        let p5 = plan(same, 32000, same, 32000)
        check(p5?.isIdentity == true, "TA5b both tracks on the recording start are an identity", "got \(String(describing: p5?.isIdentity))")
        // TA5c microphone off (no points, no samples): the late system track is still placed; the leading 12.4 s
        // with no audio at all keeps 2 s and the rest goes into the expansions.
        let lateSys: [[TimelinePoint]] = [[P(0, 1012.4)]]
        let p5c = plan(empty, 0, lateSys, 32000)
        check(p5c?.system == [TP(src: 0, count: 32000, dst: 32000)], "TA5c mic off: system placed after a 2 s lead", "got \(String(describing: p5c?.system))")
        let e5c: [(at: Double, add: Double)] = p5c?.expansions ?? []
        let e5cOK = e5c.count == 1 && abs(e5c[0].at - 2.0) < 1e-9 && abs(e5c[0].add - 10.4) < 1e-9
        check(e5cOK, "TA5c mic off: 10.4 s removed at 2.0 s", "got \(e5c)")

        // TA6 jitter in the points does not move the placement.
        let sysJ: [[TimelinePoint]] = [[P(0, 1012.400), P(16000, 1013.405), P(32000, 1014.398),
                                        P(48000, 1015.401), P(64000, 1016.400)]]
        let micJ: [[TimelinePoint]] = [[P(0, 1000.0)]]
        let p6 = plan(micJ, 400000, sysJ, 80000)
        check(p6?.system == [TP(src: 0, count: 80000, dst: 198400)], "TA6 jitter: median offset", "got \(String(describing: p6?.system))")

        // TA7 overlap: the earlier audio wins.
        let micO: [[TimelinePoint]] = [[P(0, 1000.0)], [P(32000, 1001.5)]]
        let sysO: [[TimelinePoint]] = [[P(0, 1000.0)]]
        let p7 = plan(micO, 48000, sysO, 48000)
        let wantMic7: [TP] = [TP(src: 0, count: 32000, dst: 0), TP(src: 40000, count: 8000, dst: 32000)]
        check(p7?.mic == wantMic7, "TA7 overlap trims the start of the later segment", "got \(String(describing: p7?.mic))")

        // TA8 untrusted.
        let sysU: [[TimelinePoint]] = [[P(0, 900.0)]]
        check(TrackAlign.place(segments: sysU, trackLength: 16000, hostStart: hostStart) == nil,
              "TA8 a start 100 s before the recording is not trusted", "expected nil")
        check(plan(micC, 16000, sysU, 16000) == nil, "TA8 an untrusted track gives no plan", "expected nil")
    }

    private static func runApply(_ check: (Bool, String, String) -> Void) {
        let a = TrackAlign.apply([1, 2, 3, 4], [TP(src: 0, count: 2, dst: 1), TP(src: 2, count: 2, dst: 4)], length: 6)
        check(a == [0, 1, 2, 0, 3, 4], "TA9 apply places the pieces", "got \(a)")
        let b = TrackAlign.apply([1, 2], [TP(src: 0, count: 5, dst: 0)], length: 3)
        check(b == [1, 2, 0], "TA9 apply clamps to the source and the length", "got \(b)")
    }

    private static func writeWav(_ url: URL, _ samples: [Int16]) -> Bool {
        guard let w = try? StreamingWav(url: url) else { return false }
        let ok = w.append(samples)
        w.finish()
        return ok
    }

    private static func runFiles(_ check: (Bool, String, String) -> Void) {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("talkflow-ta-" + UUID().uuidString)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // TA10 readPlaced matches apply.
        var samples: [Int16] = []
        for i in 0..<40000 { samples.append(Int16(i % 30000)) }
        let wav = root.appendingPathComponent("t10.wav")
        let wrote = writeWav(wav, samples)
        let placements: [TP] = [TP(src: 0, count: 10000, dst: 5000), TP(src: 20000, count: 20000, dst: 20000)]
        let read = WavSamples.readPlaced(wav, placements, length: 45000)
        let expected = TrackAlign.apply(samples, placements, length: 45000)
        check(wrote && read == expected, "TA10 readPlaced matches apply",
              "wrote \(wrote), counts \(read.count) vs \(expected.count)")

        // TA12 plan from a folder.
        let folder = root.appendingPathComponent("rec")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let micURL = folder.appendingPathComponent(CaptureFolder.mic)
        let sysURL = folder.appendingPathComponent(CaptureFolder.system)
        var micSamples: [Int16] = []
        for i in 0..<48000 { micSamples.append(Int16(i % 1000)) }
        var sysSamples: [Int16] = []
        for i in 0..<32000 { sysSamples.append(Int16(i % 1000)) }
        let wroteBoth = writeWav(micURL, micSamples) && writeWav(sysURL, sysSamples)
        if let t = try? TrackTimeline(url: folder.appendingPathComponent(CaptureFolder.micTimeline)) {
            for (i, h) in [(0, 1000.0), (16000, 1001.0), (32000, 1002.0)] {
                t.write(["k": "chunk", "idx": Int64(i), "host": h])
            }
            t.close()
        }
        if let t = try? TrackTimeline(url: folder.appendingPathComponent(CaptureFolder.systemTimeline)) {
            for (i, h) in [(0, 1012.4), (16000, 1013.4)] {
                t.write(["k": "chunk", "idx": Int64(i), "host": h])
            }
            t.close()
        }
        let info = CaptureSessionInfo(started: Date(), hostStart: 1000, routes: [], systemAudioMode: nil)
        try? info.write(to: folder)
        let fp = TrackAlign.plan(mic: micURL, system: sysURL)
        check(wroteBoth && fp?.mic == [TP(src: 0, count: 48000, dst: 0)]
              && fp?.system == [TP(src: 0, count: 32000, dst: 80000)],
              "TA12 plan from a capture folder", "got \(String(describing: fp?.mic)) \(String(describing: fp?.system))")

        // Differently named WAVs are never aligned.
        let other = root.appendingPathComponent("other")
        try? fm.createDirectory(at: other, withIntermediateDirectories: true)
        let aURL = other.appendingPathComponent("a.wav")
        let bURL = other.appendingPathComponent("b.wav")
        _ = writeWav(aURL, micSamples)
        _ = writeWav(bURL, sysSamples)
        try? fm.copyItem(at: folder.appendingPathComponent(CaptureFolder.micTimeline),
                         to: other.appendingPathComponent(CaptureFolder.micTimeline))
        try? fm.copyItem(at: folder.appendingPathComponent(CaptureFolder.systemTimeline),
                         to: other.appendingPathComponent(CaptureFolder.systemTimeline))
        check(TrackAlign.plan(mic: aURL, system: bURL) == nil, "TA12 other file names give no plan", "expected nil")
    }

    private static func runTimes(_ check: (Bool, String, String) -> Void) {
        let pieces: [SpeechPiece] = [SpeechPiece(speaker: "you", start: 3.0, end: 4.5, text: "a"),
                                     SpeechPiece(speaker: "S1", start: 5.0, end: 6.0, text: "b")]
        let ex: [Expansion] = [(at: 4.0, add: 7.0)]
        let out = NotesJob.expandTimes(pieces, ex)
        var ok = out.count == 2
        if ok {
            ok = near(out[0].start, 3.0) && near(out[0].end, 11.5) && near(out[1].start, 12.0) && near(out[1].end, 13.0)
        }
        if ok { ok = out[0].speaker == "you" && out[1].text == "b" }
        check(ok, "TA11 expandTimes moves times past the break", "got \(out)")
    }

    static func run(_ check: (Bool, String, String) -> Void) {
        runPlans(check)
        runApply(check)
        runFiles(check)
        runTimes(check)
    }
}
