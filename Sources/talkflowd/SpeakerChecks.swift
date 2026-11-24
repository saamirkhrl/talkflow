import Foundation

/// Telling voices apart: flattening speaker turns, forced cuts, piece speakers, helper output parsing, run from --notestest.
enum SpeakerChecks {
    private static func s(_ speaker: String, _ start: Double, _ end: Double) -> SpeakerSegment {
        SpeakerSegment(speaker: speaker, start: start, end: end)
    }

    static func run(_ check: (Bool, String, String) -> Void) {
        let f1in = [s("A", 0, 5), s("B", 5, 9)]
        let f1 = SpeakerTurns.flatten(f1in)
        let f1c = SpeakerTurns.forcedCuts(f1)
        check(f1 == [s("A", 0, 5), s("B", 5, 9)] && f1c == [5.0], "SP-F1 touching turns, one cut", "\(f1) \(f1c)")

        let f2 = SpeakerTurns.flatten([s("A", 0, 10), s("B", 4, 4.6)])
        check(f2 == [s("A", 0, 10)] && SpeakerTurns.forcedCuts(f2).isEmpty,
              "SP-F2 a backchannel stays inside the holder's run", "\(f2)")

        let f3 = SpeakerTurns.flatten([s("A", 0, 6), s("B", 5, 10)])
        check(f3 == [s("A", 0, 6), s("B", 6, 10)] && SpeakerTurns.forcedCuts(f3) == [6.0],
              "SP-F3 an overlap goes to the one holding the floor", "\(f3)")

        let f4 = SpeakerTurns.flatten([s("A", 0, 4), s("B", 5, 8)])
        check(SpeakerTurns.forcedCuts(f4) == [4.5], "SP-F4 a gap is cut in the middle", "\(SpeakerTurns.forcedCuts(f4))")

        let f5 = SpeakerTurns.flatten([s("A", 0, 4), s("A", 5, 8)])
        check(f5 == [s("A", 0, 4), s("A", 5, 8)] && SpeakerTurns.forcedCuts(f5).isEmpty,
              "SP-F5 same speaker across a gap, no cut", "\(f5)")

        let f6 = SpeakerTurns.flatten([s("A", 0, 3), s("B", 2, 8), s("C", 2.5, 4)])
        check(f6 == [s("A", 0, 3), s("B", 3, 8)] && SpeakerTurns.forcedCuts(f6) == [3.0],
              "SP-F6 three-way overlap", "\(f6)")

        let runs = [s("A", 0, 5), s("B", 5, 9)]
        let f7a = SpeakerTurns.speaker(start: 4, end: 7, runs: runs)
        let f7b = SpeakerTurns.speaker(start: 9.5, end: 10, runs: runs)
        let f7c = SpeakerTurns.speaker(start: -1, end: -0.5, runs: runs)
        let f7d = SpeakerTurns.speaker(start: 1, end: 2, runs: [])
        check(f7a == "B" && f7b == "B" && f7c == "A" && f7d == nil,
              "SP-F7 speaker of a stretch", "\(String(describing: f7a)) \(String(describing: f7b)) \(String(describing: f7c)) \(String(describing: f7d))")

        let f8 = SpeakerTurns.flatten(Array(f1in.reversed()))
        check(f8 == f1 && SpeakerTurns.forcedCuts(f8) == f1c, "SP-F8 input order does not matter", "\(f8)")

        let f9 = SpeakerTurns.flatten([s("A", 0, 5), s("B", 3, 3), s("B", 5, 9)])
        check(f9 == [s("A", 0, 5), s("B", 5, 9)], "SP-F9 a zero-length segment is ignored", "\(f9)")

        let json = Data("""
        {"schema":1,"engine":"fluidaudio","turns":[{"speaker":"S1","start":0.5,"end":3.25},{"speaker":"S2","start":3.5,"end":6}]}
        """.utf8)
        let f10 = SpeakerHelper.parseRun(json)
        check(f10 == [s("S1", 0.5, 3.25), s("S2", 3.5, 6)] && SpeakerHelper.parseRun(Data("nope".utf8)) == nil
              && SpeakerHelper.parseRun(Data("{\"schema\":2,\"turns\":[]}".utf8)) == nil,
              "SP-F10 helper output is parsed, garbage is not", "\(String(describing: f10))")

        let f11a = SpeakerHelper.parseProgress("{\"event\":\"progress\",\"phase\":\"diarizing\"}")
        let f11b = SpeakerHelper.parseProgress("[Profiling] x")
        check(f11a == "diarizing" && f11b == nil, "SP-F11 progress lines", "\(String(describing: f11a)) \(String(describing: f11b))")

        let truth = [s("A", 0, 10), s("B", 10, 20)]
        let d1 = DiarizeSelfTest.der(truth: truth, hyp: truth, collar: 0)
        let d2 = DiarizeSelfTest.der(truth: truth, hyp: [s("X", 0, 10), s("Y", 10, 20)], collar: 0)
        let d3 = DiarizeSelfTest.der(truth: truth, hyp: [s("A", 0, 10)], collar: 0)
        check(abs(d1) < 1e-9 && abs(d2) < 1e-9 && abs(d3 - 0.5) < 1e-9, "SP-F12 error rate",
              "identical \(d1) renamed \(d2) missing one \(d3)")
    }
}
