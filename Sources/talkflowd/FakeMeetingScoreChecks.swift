import Foundation

/// Checks for FMScorer, called from --notestest. The expected values came from the fixture's score.py; F20-F22
/// run score.py itself when the fixture and a python3 are on this machine. Details hold numbers and names only,
/// never transcript text.
enum ScorerChecks {
    private struct Expect {
        var mapping: [(String, String?)]
        var voices: Int
        var substantive: Int
        var persons: [String]
        var wer: [(String, Double?, Int, Int, Int, Int, Int)]
        var overall: Double?
        var edits: Int
        var n: Int
        var ws: (Double, Int, Int, Int)
        var per: [(String, Int, Int)]
        var unattributed: Int
        var echo: (Int, Int, Int, Double?, Double?)
        var inaud: (Int, Int, Bool)
    }

    private static func close(_ a: Double?, _ b: Double?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return abs(x - y) <= 1e-4
        default: return false
        }
    }

    /// Names of the fields that differ from the expectation (empty = all match).
    private static func diff(_ s: FMScore, _ e: Expect) -> [String] {
        var bad: [String] = []
        if s.mapping.count != e.mapping.count
            || !zip(s.mapping, e.mapping).allSatisfy({ $0.label == $1.0 && $0.mappedTo == $1.1 }) { bad.append("mapping") }
        if s.voicesFoundSystem != e.voices { bad.append("voices") }
        if s.voicesFoundSystemSubstantive != e.substantive { bad.append("substantive") }
        if s.persons != e.persons { bad.append("persons") }
        for (p, w, sub, del, ins, n, hits) in e.wer {
            guard let v = s.wer[p] else {
                bad.append("wer.\(p)")
                continue
            }
            if !close(v.wer, w) { bad.append("wer.\(p).wer") }
            if v.s != sub { bad.append("wer.\(p).S") }
            if v.d != del { bad.append("wer.\(p).D") }
            if v.i != ins { bad.append("wer.\(p).I") }
            if v.n != n { bad.append("wer.\(p).N") }
            if v.hits != hits { bad.append("wer.\(p).hits") }
        }
        if !close(s.werOverall, e.overall) { bad.append("overall") }
        if s.werOverallEdits != e.edits { bad.append("edits") }
        if s.werOverallN != e.n { bad.append("N") }
        if !close(s.wrongShare, e.ws.0) { bad.append("ws.share") }
        if s.wrongCorrect != e.ws.1 { bad.append("ws.correct") }
        if s.wrongWrong != e.ws.2 { bad.append("ws.wrong") }
        if s.wrongUnattributed != e.ws.3 { bad.append("ws.unattributed") }
        for (p, c, w) in e.per {
            guard let v = s.wrongPerPerson[p] else {
                bad.append("per.\(p)")
                continue
            }
            if v.correct != c || v.wrong != w { bad.append("per.\(p)") }
        }
        if s.unattributedWords != e.unattributed { bad.append("unattributedWords") }
        if s.echoLeakWords != e.echo.0 { bad.append("echo.leak") }
        if s.echoLeakMatched != e.echo.1 { bad.append("echo.matched") }
        if s.farEndWords != e.echo.2 { bad.append("echo.farEnd") }
        if !close(s.echoLeakRate, e.echo.3) { bad.append("echo.rate") }
        if !close(s.samirKeep, e.echo.4) { bad.append("echo.keep") }
        if s.inaudibleWindows != e.inaud.0 { bad.append("inaud.windows") }
        if s.inventedWords != e.inaud.1 { bad.append("inaud.invented") }
        if s.markerPresent != e.inaud.2 { bad.append("inaud.marker") }
        return bad
    }

    private static func u(_ id: String, _ speaker: String, _ start: Double, _ end: Double, _ text: String,
                          _ flags: [String] = []) -> FMUtterance {
        FMUtterance(id: id, speaker: speaker, start: start, end: end, text: text, flags: flags)
    }

    private static func t(_ speaker: String, _ start: Double, _ end: Double, _ text: String) -> FMTurn {
        FMTurn(speaker: speaker, start: start, end: end, text: text)
    }

    private static let truthT: [FMUtterance] = [
        u("u1", "samir", 0.0, 4.0, "Okay, let's start. We have 3 items."),
        u("u2", "bob", 4.5, 9.0, "The beta had 4,200 sign-ups, about 60% rode."),
        u("u3", "emily", 8.5, 10.0, "Wow.", ["backchannel", "overlapped"]),
        u("u4", "jason", 11.0, 14.0, "garbled words here", ["inaudible"]),
        u("u5", "emily", 15.0, 19.0, "I'll send the contract by the 2nd \u{2014} okay?"),
        u("u6", "samir", 19.5, 22.0, "Mm-hm, alright.", ["backchannel"]),
        u("u7", "bob", 22.5, 26.0, "Price is $49 [laughs] (annual) for the 21st year."),
    ]

    private static let c3Turns: [FMTurn] = [
        t("You", 0.0, 4.0, "okay lets start we have three items"),
        t("You", 5.0, 7.0, "beta had"),
        t("spk_a", 4.5, 9.0, "The beta had four thousand two hundred sign ups about sixty percent rode today"),
        t("spk_b", 15.0, 19.0, "I will send contract by the second okay"),
        t("spk_a", 19.0, 27.0, "mm hm price is forty nine dollars for the twenty first year"),
        t("spk_c", 30.0, 31.0, "hello there"),
    ]

    private static let persons = ["samir", "bob", "emily", "jason"]
    private static let zeroWer: [(String, Double?, Int, Int, Int, Int, Int)] = [
        ("samir", 0, 0, 0, 0, 7, 7), ("bob", 0, 0, 0, 0, 23, 23), ("emily", 0, 0, 0, 0, 8, 8),
        ("jason", 0.0, 0, 0, 0, 0, 0),
    ]
    private static let zeroPer: [(String, Int, Int)] = [("samir", 11, 0), ("bob", 23, 0), ("emily", 9, 0), ("jason", 0, 0)]

    static func run(_ report: (Bool, String, String) -> Void) {
        // MARK: normalise

        let norm: [(String, String, String)] = [
            ("FM1", "Okay, let's start. We have 3 items.", "okay let's start we have three items"),
            ("FM2", "The beta had 4,200 sign-ups, about 60% rode.",
             "the beta had four thousand two hundred sign ups about sixty percent rode"),
            ("FM3", "I'll send the contract by the 2nd \u{2014} okay?", "i'll send the contract by the second okay"),
            ("FM4", "Mm-hm, alright.", "mm hm all right"),
            ("FM5", "Price is $49 [laughs] (annual) for the 21st year.",
             "price is forty nine dollars for the twenty first year"),
            ("FM6", "Um, OK so 1,000,000 or 1000000th 'quoted' it's 3.5% of $12,000 - uh 101st 12th 40th 0 007",
             "okay so 1000000 or 1000000th quoted it's three five percent of twelve thousand dollars one hundred first twelfth fortieth zero seven"),
            ("FM7", "", ""),
        ]
        for (label, input, expected) in norm {
            let got = FMScorer.normalise(input)
            report(got.joined(separator: " ") == expected && (expected.isEmpty ? got.isEmpty : true),
                   "\(label) normalise", "words=\(got.count)")
        }

        // MARK: scoring cases

        let perfect = FMScorer.perfectTurns(truthT)
        let c1 = FMScorer.score(turns: perfect, truth: truthT, mic: "speakers")
        let expectedLabels = ["You", "Speaker 1", "Speaker 3", "Speaker 3", "You", "Speaker 1"]
        let c1Expect = Expect(
            mapping: [("Speaker 1", "bob"), ("Speaker 3", "emily")], voices: 2, substantive: 2, persons: persons,
            wer: zeroWer, overall: 0.0, edits: 0, n: 38, ws: (0.0, 43, 0, 0), per: zeroPer, unattributed: 0,
            echo: (0, 0, 32, 0.0, 1.0), inaud: (1, 0, false))
        var bad = diff(c1, c1Expect)
        if perfect.map({ $0.speaker }) != expectedLabels { bad.append("labels") }
        report(bad.isEmpty, "FM10 perfect transcript scores clean", "turns=\(perfect.count) bad=\(bad.joined(separator: ","))")

        var c2Turns = perfect
        c2Turns.append(t("Speaker 5", 11.0, 14.0, "the provider takes a cut"))
        var c2Expect = c1Expect
        c2Expect.mapping.append(("Speaker 5", "jason"))
        c2Expect.voices = 3
        c2Expect.ws = (0.0, 43, 0, 5)
        c2Expect.inaud = (1, 5, false)
        bad = diff(FMScorer.score(turns: c2Turns, truth: truthT, mic: "speakers"), c2Expect)
        report(bad.isEmpty, "FM11 invented words in the inaudible window", "bad=\(bad.joined(separator: ","))")

        var c2bTurns = perfect
        c2bTurns.append(t("Speaker 5", 11.0, 14.0, "[inaudible]"))
        var c2bExpect = c2Expect
        c2bExpect.ws = (0.0, 43, 0, 0)
        c2bExpect.inaud = (1, 0, true)
        bad = diff(FMScorer.score(turns: c2bTurns, truth: truthT, mic: "speakers"), c2bExpect)
        report(bad.isEmpty, "FM12 inaudible marker counts as a marker", "bad=\(bad.joined(separator: ","))")

        let c3Expect = Expect(
            mapping: [("spk_a", "bob"), ("spk_b", "emily"), ("spk_c", nil)], voices: 3, substantive: 1,
            persons: persons,
            wer: [("samir", 0.4286, 1, 0, 2, 7, 6), ("bob", 0.1304, 0, 0, 3, 23, 23), ("emily", 0.375, 3, 0, 0, 8, 5),
                  ("jason", 0.0, 0, 0, 0, 0, 0)],
            overall: 0.2368, edits: 9, n: 38, ws: (0.1667, 35, 7, 1),
            per: [("samir", 7, 2), ("bob", 20, 5), ("emily", 8, 0), ("jason", 0, 0)], unattributed: 2,
            echo: (2, 2, 32, 0.0625, 0.8571), inaud: (1, 0, false))
        bad = diff(FMScorer.score(turns: c3Turns, truth: truthT, mic: "speakers"), c3Expect)
        report(bad.isEmpty, "FM13 errors case", "bad=\(bad.joined(separator: ","))")

        var c4Turns = perfect
        c4Turns.append(t("Speaker 5", 13.0, 15.5, "foo bar baz qux"))
        var c4Expect = c1Expect
        c4Expect.mapping.append(("Speaker 5", "jason"))
        c4Expect.voices = 3
        c4Expect.wer[3] = ("jason", nil, 0, 0, 2, 0, 0)
        c4Expect.overall = 0.0526
        c4Expect.edits = 2
        c4Expect.ws = (0.0227, 43, 1, 3)
        c4Expect.per[3] = ("jason", 0, 1)
        c4Expect.inaud = (1, 2, false)
        bad = diff(FMScorer.score(turns: c4Turns, truth: truthT, mic: "speakers"), c4Expect)
        report(bad.isEmpty, "FM14 words spoken by an unheard-of voice", "bad=\(bad.joined(separator: ","))")

        // MARK: levenshtein, cardinal, ordinal

        let l1 = FMScorer.levenshtein(["a", "b", "c", "d"], ["a", "x", "c", "d", "e"])
        let l2 = FMScorer.levenshtein([], ["a"])
        let l3 = FMScorer.levenshtein(["a", "b"], [])
        report(l1 == (1, 0, 1, 3) && l2 == (0, 0, 1, 0) && l3 == (0, 2, 0, 0), "FM15 levenshtein",
               "\(l1) \(l2) \(l3)")

        let cardOK = FMScorer.cardinal(0) == "zero" && FMScorer.cardinal(105) == "one hundred five"
            && FMScorer.cardinal(999_999) == "nine hundred ninety nine thousand nine hundred ninety nine"
        let ordOK = FMScorer.ordinal(3) == "third" && FMScorer.ordinal(20) == "twentieth"
            && FMScorer.ordinal(112) == "one hundred twelfth"
        report(cardOK && ordOK, "FM16 cardinal and ordinal words", "cardinal=\(cardOK) ordinal=\(ordOK)")

        pythonChecks(report)
    }

    // MARK: Cross-check against the real score.py

    private static func pythonChecks(_ report: (Bool, String, String) -> Void) {
        let fm = FileManager.default
        let fixture = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/talkflow/test-fixtures/fakemeeting")
        let truthURL = fixture.appendingPathComponent("truth.json")
        let scorePy = fixture.appendingPathComponent("score.py")
        guard fm.fileExists(atPath: truthURL.path) else {
            report(true, "FM20 python cross-check skipped (no fixture)", "")
            return
        }
        guard let python = FMPython.find(), fm.fileExists(atPath: scorePy.path) else {
            report(true, "FM20 python cross-check skipped (no python3)", "")
            return
        }
        guard let truth = try? FMTruth.load(truthURL) else {
            report(false, "FM20 python cross-check", "truth did not load")
            return
        }

        // F20: the perfect transcript scores clean here and the same in python.
        let perfect = FMScorer.perfectTurns(truth.utterances)
        let s20 = FMScorer.score(turns: perfect, truth: truth.utterances, mic: "speakers")
        let clean = s20.wer.values.allSatisfy { $0.wer == 0 } && s20.inventedWords == 0 && s20.wrongWrong == 0
        if let py = FMPython.run(python: python, scorePy: scorePy, truthJSON: truthURL, turns: perfect, mic: "speakers") {
            let d = FMPython.compare(s20, py)
            report(clean && d.isEmpty, "FM20 perfect transcript matches score.py",
                   "turns=\(perfect.count) clean=\(clean) mismatches=\(d.joined(separator: ","))")
        } else {
            report(false, "FM20 perfect transcript matches score.py", "score.py did not run")
        }

        // F21: a deterministic, damaged transcript.
        var syn: [FMTurn] = []
        for (k, turn) in perfect.enumerated() {
            var x = turn
            if k % 9 == 4 {
                var words = x.text.components(separatedBy: " ")
                if !words.isEmpty { words.removeLast() }
                x.text = words.joined(separator: " ")
            }
            if k % 13 == 6 && x.speaker != "You" { x.speaker = "Speaker 2" }
            syn.append(x)
            if k % 17 == 3 && turn.speaker != "You" {
                let first3 = turn.text.components(separatedBy: " ").prefix(3).joined(separator: " ")
                syn.append(FMTurn(speaker: "You", start: turn.start, end: turn.end, text: first3))
            }
        }
        if let inaud = truth.utterances.first(where: { $0.flags.contains("inaudible") }) {
            syn.append(FMTurn(speaker: "Speaker 5", start: inaud.start, end: inaud.end, text: "the provider takes a cut"))
        }
        syn.append(FMTurn(speaker: "Speaker 99", start: truth.duration + 1, end: truth.duration + 2, text: "trailing words"))
        let s21 = FMScorer.score(turns: syn, truth: truth.utterances, mic: "speakers")
        let shape = s21.inventedWords >= 5 && s21.unattributedWords >= 2 && s21.wer.values.contains { ($0.wer ?? 0) > 0 }
        if let py = FMPython.run(python: python, scorePy: scorePy, truthJSON: truthURL, turns: syn, mic: "speakers") {
            let d = FMPython.compare(s21, py)
            report(shape && d.isEmpty, "FM21 damaged transcript matches score.py",
                   "turns=\(syn.count) invented=\(s21.inventedWords) unattributed=\(s21.unattributedWords) shape=\(shape) mismatches=\(d.joined(separator: ","))")
        } else {
            report(false, "FM21 damaged transcript matches score.py", "score.py did not run")
        }

        // F22: the mini truth, written to a temporary truth.json.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("talkflow-fmchecks-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let miniURL = dir.appendingPathComponent("truth.json")
        let utts: [[String: Any]] = truthT.map {
            ["id": $0.id, "speaker": $0.speaker, "start": $0.start, "end": $0.end, "text": $0.text, "flags": $0.flags]
        }
        let mini: [String: Any] = ["schema_version": FMTruth.schema, "duration_sec": 26, "utterances": utts]
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil,
              let data = try? JSONSerialization.data(withJSONObject: mini),
              (try? data.write(to: miniURL)) != nil else {
            report(false, "FM22 mini truth matches score.py", "temp truth not written")
            return
        }
        let s22 = FMScorer.score(turns: c3Turns, truth: truthT, mic: "speakers")
        if let py = FMPython.run(python: python, scorePy: scorePy, truthJSON: miniURL, turns: c3Turns, mic: "speakers") {
            let d = FMPython.compare(s22, py)
            report(d.isEmpty, "FM22 mini truth matches score.py", "mismatches=\(d.joined(separator: ","))")
        } else {
            report(false, "FM22 mini truth matches score.py", "score.py did not run")
        }
    }
}
