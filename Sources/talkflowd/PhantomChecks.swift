import Foundation

/// Self-test checks for the echo residue rule, the phantom rule, the prompt label strip, the silent-user scoring and
/// the debug keeper, run from --notestest. Deterministic (seeded generator); nothing here starts the speech engine.
enum PhantomChecks {
    private struct LCG {
        var s: UInt64
        mutating func next() -> UInt64 {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return s
        }
        mutating func int(_ amp: Int) -> Int16 {
            let r = Int((next() >> 33) % UInt64(2 * amp + 1))
            return Int16(r - amp)
        }
    }

    private static let sr = 16000

    static func run(_ check: (Bool, String, String) -> Void) {
        runEchoResidue(check)
        runPhantom(check)
        runPromptLabel(check)
        runSilent(check)
        runKeeper(check)
    }

    private static func near(_ a: Double?, _ b: Double, _ tol: Double) -> Bool {
        guard let a else { return false }
        return abs(a - b) <= tol
    }

    private static func rep(_ v: Double, _ n: Int) -> [Double] {
        [Double](repeating: v, count: n)
    }

    // MARK: Echo residue

    private static func runEchoResidue(_ check: (Bool, String, String) -> Void) {
        let c1: [Double] = rep(1e2, 100) + rep(1e5, 200)
        let e1: [Double] = rep(1e2, 100) + rep(1e6, 200)
        let l1 = EchoResidue.leakage(clean: c1, echo: e1)
        let l1ok = near(l1?.leakDB, -10.0, 1e-9) && l1?.activeFrames == 200
        check(l1ok, "ER2 1 leakage -10 dB on 200 active frames", "got \(String(describing: l1))")

        let c2: [Double] = rep(1e2, 100) + rep(1e5, 99)
        let e2: [Double] = rep(1e2, 100) + rep(1e6, 99)
        let l2 = EchoResidue.leakage(clean: c2, echo: e2)
        check(l2 == nil, "ER2 2 too little echo gives nil", "got \(String(describing: l2))")

        let d3 = EchoResidue.decide(clean: rep(1e5, 10), echo: rep(1e6, 10), a: 0, b: 10, leakDB: -10, echoActive: 1e4)
        let ok3 = !d3.kept && d3.reason == "echo residue" && near(d3.aboveLeakDB, 0.0, 1e-9)
            && near(d3.start, 0.0, 1e-9) && near(d3.end, 0.1, 1e-9)
        check(ok3, "ER2 3 decide echo residue", "got \(d3)")

        let d4 = EchoResidue.decide(clean: rep(1e7, 10), echo: rep(1e6, 10), a: 0, b: 10, leakDB: -10, echoActive: 1e4)
        let ok4 = d4.kept && d4.reason == "near-end" && near(d4.aboveLeakDB, 20.0, 1e-9)
        check(ok4, "ER2 4 decide near-end", "got \(d4)")

        let d5 = EchoResidue.decide(clean: rep(1e6, 10), echo: rep(1e6, 10), a: 0, b: 10, leakDB: -10, echoActive: 1e4)
        let ok5 = near(d5.aboveLeakDB, 10.0, 1e-9) && d5.kept
        check(ok5, "ER2 5 exactly marginDB keeps", "got \(d5)")

        let d6 = EchoResidue.decide(clean: rep(1e6, 10), echo: rep(1e2, 10), a: 0, b: 10, leakDB: -10, echoActive: 1e4)
        let ok6 = d6.kept && d6.reason == "no echo" && d6.aboveLeakDB == nil
        check(ok6, "ER2 6 no echo keeps", "got \(d6)")

        runEndToEnd(check)
    }

    /// 20 s at 16 kHz. Echo burst [2 s, burstEnd s), then a near-end burst at [12 s, 14 s).
    private static func signals(burstEnd: Int) -> (raw: [Int16], cleaned: [Int16]) {
        let total = 20 * sr
        var lcg = LCG(s: 7)
        var n = [Int16](repeating: 0, count: total)
        for k in 0..<total { n[k] = lcg.int(10) }
        var raw = n
        var cleaned = n
        let echoLo = 2 * sr
        let echoHi = burstEnd
        for k in echoLo..<echoHi {
            let e = Int(lcg.int(3000))
            raw[k] = Int16(Int(n[k]) + e)
            cleaned[k] = Int16(Int(n[k]) + e / 3)
        }
        for k in (12 * sr)..<(14 * sr) {
            let u = Int(lcg.int(3000))
            let v = Int16(Int(n[k]) + u)
            raw[k] = v
            cleaned[k] = v
        }
        return (raw, cleaned)
    }

    private static func runEndToEnd(_ check: (Bool, String, String) -> Void) {
        let s = signals(burstEnd: 8 * sr)
        let r = EchoResidue.apply(track: s.cleaned, raw: s.raw, cleaned: s.cleaned, minThreshold: nil)
        let leakOK = near(r.leakDB, -6.02, 0.3)
        check(leakOK, "ER2 7a end to end leakage near -6.02 dB", "got \(String(describing: r.leakDB))")
        check(r.decisions.count == 2, "ER2 7b two decisions", "got \(r.decisions.count)")
        if r.decisions.count == 2 {
            let d0 = r.decisions[0]
            let ok0 = near(d0.start, 2.0, 0.02) && near(d0.end, 8.0, 0.02) && !d0.kept
                && d0.reason == "echo residue" && near(d0.aboveLeakDB, 0.0, 1.0)
            check(ok0, "ER2 7c decision 0 is the dropped echo residue", "got \(d0)")
            let d1 = r.decisions[1]
            let ok1 = near(d1.start, 12.0, 0.02) && near(d1.end, 14.0, 0.02) && d1.kept && d1.reason == "no echo"
            check(ok1, "ER2 7d decision 1 is the kept near-end speech", "got \(d1)")
        } else {
            check(false, "ER2 7c decision 0 is the dropped echo residue", "missing")
            check(false, "ER2 7d decision 1 is the kept near-end speech", "missing")
        }
        check(near(r.droppedSeconds, 6.0, 0.03), "ER2 7e dropped about 6 s", "got \(r.droppedSeconds)")
        let lo = Int(2.02 * 16000)
        let hi = Int(7.98 * 16000)
        var zeros = r.samples.count == s.cleaned.count
        if zeros {
            for k in lo..<hi where r.samples[k] != 0 { zeros = false; break }
        }
        check(zeros, "ER2 7f dropped region is all zeros", "a sample in the region is not 0")
        var same = zeros
        if same {
            for k in (12 * sr)..<(14 * sr) where r.samples[k] != s.cleaned[k] { same = false; break }
        }
        check(same, "ER2 7g near-end region is untouched", "a sample differs from cleaned")

        let t = signals(burstEnd: 2 * sr + sr / 2)
        let r8 = EchoResidue.apply(track: t.cleaned, raw: t.raw, cleaned: t.cleaned, minThreshold: nil)
        let ok8 = r8.decisions.isEmpty && r8.leakDB == nil && r8.samples == t.cleaned
        check(ok8, "ER2 8 too little echo changes nothing", "decisions \(r8.decisions.count), leak \(String(describing: r8.leakDB))")
    }

    // MARK: Phantom rule

    private static func seg(_ text: String) -> WhisperSegment {
        WhisperSegment(start: 0, end: 1, text: text, words: [], avgLogprob: nil, noSpeechProb: nil)
    }

    private static func runPhantom(_ check: (Bool, String, String) -> Void) {
        let stock: [String] = ["Thank you.", "- Yeah.", "Thank you. Thank you.", "Okay, thank you.", "I'm sorry.",
                               "Shhh.", "Beep.", "I\u{2019}m sorry.", "THANK YOU!"]
        var bad: [String] = []
        for t in stock where !PhantomRule.isStock(t) { bad.append(t) }
        check(bad.isEmpty, "PH 1 stock phrases are stock", "not stock: \(bad)")

        let notStock: [String] = ["Thank you for the update.", "", "Yes, let's do it.", "...", "We ship Friday."]
        var bad2: [String] = []
        for t in notStock where PhantomRule.isStock(t) { bad2.append(t) }
        check(bad2.isEmpty, "PH 2 other text is not stock", "stock: \(bad2)")

        let ty = [seg("Thank you.")]
        let p1 = PhantomRule.isPhantom(ty, speech: 0.6, levelDB: -55)
        check(p1, "PH 3a short quiet thank you is phantom", "got \(p1)")
        let p2 = PhantomRule.isPhantom(ty, speech: 0.6, levelDB: -30)
        check(!p2, "PH 3b loud thank you stays", "got \(p2)")
        let p3 = PhantomRule.isPhantom(ty, speech: 2.0, levelDB: -55)
        check(!p3, "PH 3c long thank you stays", "got \(p3)")
        let p4 = PhantomRule.isPhantom(ty, speech: 0.6, levelDB: -45.0)
        check(!p4, "PH 3d level -45.0 stays", "got \(p4)")
        let p5 = PhantomRule.isPhantom(ty, speech: 0.6, levelDB: -45.01)
        check(p5, "PH 3e level -45.01 is phantom", "got \(p5)")
        let p6 = PhantomRule.isPhantom(ty, speech: 1.5, levelDB: -55)
        check(p6, "PH 3f speech 1.5 is phantom", "got \(p6)")
        let p7 = PhantomRule.isPhantom(ty, speech: 1.51, levelDB: -55)
        check(!p7, "PH 3g speech 1.51 stays", "got \(p7)")
        let p8 = PhantomRule.isPhantom([seg("We ship Friday.")], speech: 0.6, levelDB: -55)
        check(!p8, "PH 3h real sentence stays", "got \(p8)")
        let none: [WhisperSegment] = []
        let p9 = PhantomRule.isPhantom(none, speech: 0.6, levelDB: -55)
        check(!p9, "PH 3i no segments stays", "got \(p9)")

        let empty: [Int16] = []
        let l1 = PhantomRule.levelDB(empty[...])
        check(l1 == -120, "PH 4a empty level is -120", "got \(l1)")
        let loud = [Int16](repeating: 16384, count: 100)
        let l2 = PhantomRule.levelDB(loud[...])
        check(abs(l2 + 6.0206) < 0.001, "PH 4b half scale is -6.0206 dB", "got \(l2)")
        let zero = [Int16](repeating: 0, count: 10)
        let l3 = PhantomRule.levelDB(zero[...])
        check(abs(l3 + 150.31) < 0.01, "PH 4c zeros are -150.31 dB", "got \(l3)")

        let s1 = PhantomRule.shouldSend(track: "you", levelDB: -60.0)
        let s2 = PhantomRule.shouldSend(track: "you", levelDB: -60.01)
        let s3 = PhantomRule.shouldSend(track: "others", levelDB: -90)
        check(s1 && !s2 && s3, "PH 5 a you piece under -60 dBFS is not sent, others always are", "got \(s1) \(s2) \(s3)")
    }

    // MARK: Prompt label

    private static let prompt = "I'm Pat, and I use talkflow, a dictation app. Names and words here: Quillmere, Tarrowby, Port Ellery."

    private static func joined(_ segs: [WhisperSegment]) -> String {
        segs.map { $0.text }.joined(separator: " ")
    }

    private static func runPromptLabel(_ check: (Bool, String, String) -> Void) {
        let r1 = HallucinationGuard.stripPromptLabel([seg("Names and words: Quillmere.")], prompt: prompt)
        check(r1.segments.isEmpty && r1.removed == 1, "PL 1 label and one word go", "got \(r1)")

        let r2 = HallucinationGuard.stripPromptLabel([seg("Thank you. Names and words: Tarrowby.")], prompt: prompt)
        check(joined(r2.segments) == "Thank you." && r2.segments.count == 1 && r2.removed == 1,
              "PL 2 text before the label stays", "got \(r2)")

        let rep3 = "Names and words: Quillmere. Names and words: Quillmere. Names and words: Quillmere."
        let r3 = HallucinationGuard.stripPromptLabel([seg(rep3)], prompt: prompt)
        check(r3.segments.isEmpty && r3.removed == 1, "PL 3 repeated labels all go", "got \(r3)")

        let t4 = "Names and words here: Quillmere, Tarrowby, Port Ellery. Let's start."
        let r4 = HallucinationGuard.stripPromptLabel([seg(t4)], prompt: prompt)
        check(joined(r4.segments) == "Let's start.", "PL 4 whole label list goes, text after stays", "got \(r4)")

        let plain = "I'm Pat, and I use talkflow, a dictation app."
        let in5 = seg("Names and words: Quillmere.")
        let r5 = HallucinationGuard.stripPromptLabel([in5], prompt: plain)
        check(r5.segments == [in5] && r5.removed == 0, "PL 5 prompt without label changes nothing", "got \(r5)")

        let in6 = seg("We need names and words for the glossary")
        let r6 = HallucinationGuard.stripPromptLabel([in6], prompt: prompt)
        check(r6.segments == [in6] && r6.removed == 0, "PL 6 user's own words stay", "got \(r6)")

        let de = "Ich nutze talkflow, eine Diktier-App. Namen und W\u{00F6}rter hier: Quillmere."
        let r7 = HallucinationGuard.stripPromptLabel([seg("Namen und W\u{00F6}rter: Quillmere.")], prompt: de)
        check(r7.segments.isEmpty && r7.removed == 1, "PL 7 German label goes", "got \(r7)")

        let word = TimedWord(text: "Okay.", start: 0, end: 0.3)
        let in8 = WhisperSegment(start: 0, end: 1, text: "Okay. Names and words: Quillmere.", words: [word],
                                 avgLogprob: nil, noSpeechProb: nil)
        let r8 = HallucinationGuard.stripPromptLabel([in8], prompt: prompt)
        let ok8 = r8.segments.count == 1 && r8.segments[0].text == "Okay." && r8.segments[0].words.isEmpty
        check(ok8, "PL 8 changed segment drops its word times", "got \(r8)")
    }

    // MARK: Silent-user scoring

    private static func runSilent(_ check: (Bool, String, String) -> Void) {
        let t1: [FMTurn] = [FMTurn(speaker: "You", start: 0, end: 1, text: "Thank you."),
                            FMTurn(speaker: "S1", start: 1, end: 2, text: "hello there"),
                            FMTurn(speaker: "You", start: 2, end: 3, text: "- Yeah.")]
        let y = FMSilent.youWords(t1)
        check(y.words == 3 && y.turns == 2, "SU 1 youWords counts words and turns", "got \(y)")

        let t2: [FMTurn] = [FMTurn(speaker: "S1", start: 0, end: 1, text: "Names and words: Quillmere."),
                            FMTurn(speaker: "You", start: 1, end: 2, text: "and I use talkflow, a dictation app"),
                            FMTurn(speaker: "S1", start: 2, end: 3, text: "plain words here")]
        let h = FMSilent.promptHits(t2, prompt: prompt)
        check(h == 2, "SU 2 promptHits counts label and run", "got \(h)")

        let f1 = FMSilent.failures(youWords: 5, promptHits: 0)
        let f2 = FMSilent.failures(youWords: 6, promptHits: 0)
        let f3 = FMSilent.failures(youWords: 0, promptHits: 1)
        let f4 = FMSilent.failures(youWords: 6, promptHits: 2)
        let ok3 = f1.isEmpty && f2.count == 1 && f3.count == 1 && f4.count == 2
        check(ok3, "SU 3 failures lines", "got \(f1.count) \(f2.count) \(f3.count) \(f4.count)")
    }

    // MARK: Debug keeper

    private static func runKeeper(_ check: (Bool, String, String) -> Void) {
        var stats = NotesJobStats()
        stats.regions = [EchoRegionDecision(start: 1, end: 2, levelDB: -40, aboveLeakDB: nil, kept: true, reason: "no echo")]
        stats.pieceRecords = [NotesPieceRecord(track: "you", start: 1, end: 2, speech: 0.5, levelDB: -50, words: 0,
                                               noSpeechProb: nil, avgLogprob: -0.5, promptEchoes: 0,
                                               outcome: "phantom", seconds: 1.1)]
        stats.phantoms = 1
        let json = NotesDebugKeeper.pipelineJSON(stats, turns: 3, duration: 60, noteID: "20261125-000000-abcd")
        check(JSONSerialization.isValidJSONObject(json), "DK 1a pipeline json is valid", "not a valid JSON object")
        let keys = ["echo", "speakers", "align", "counts", "timings", "regions", "pieces", "engine_memory_mb"]
        let missing = keys.filter { json[$0] == nil }
        check(missing.isEmpty, "DK 1b all keys present", "missing \(missing)")
        let regions = json["regions"] as? [[String: Any]]
        check(regions?.first?["above_leak_db"] is NSNull, "DK 1c nil above_leak_db is null", "got \(String(describing: regions?.first))")
        let pieces = json["pieces"] as? [[String: Any]]
        let p0 = pieces?.first
        let outcome = p0?["outcome"] as? String
        check(p0?["no_speech_prob"] is NSNull && outcome == "phantom", "DK 1d piece null and outcome", "got \(String(describing: p0))")
        let counts = json["counts"] as? [String: Any]
        check(counts?["phantoms"] as? Int == 1, "DK 1e phantom count", "got \(String(describing: counts?["phantoms"]))")

        let fm = FileManager.default
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("talkflow-dk-\(UUID().uuidString)", isDirectory: true)
        let audio = temp.appendingPathComponent("notes/20261125-000000-abcd/audio", isDirectory: true)
        try? fm.createDirectory(at: audio, withIntermediateDirectories: true)
        try? Data([1, 2, 3]).write(to: audio.appendingPathComponent("you.wav"))
        try? Data("{}".utf8).write(to: audio.appendingPathComponent("session.json"))
        let oldRoot = NotesDebugKeeper.root
        NotesDebugKeeper.root = temp.appendingPathComponent("runs", isDirectory: true)
        let tracks: [String: [Int16]] = ["you_gated.wav": [0, 1, 2]]
        let k1 = NotesDebugKeeper.keep(audioFolder: audio, stats: NotesJobStats(), tracks: tracks, turns: 0, duration: 1)
        let k2 = NotesDebugKeeper.keep(audioFolder: audio, stats: NotesJobStats(), tracks: tracks, turns: 0, duration: 1)
        NotesDebugKeeper.root = oldRoot

        check(k1?.lastPathComponent == "20261125-000000-abcd", "DK 2a first keep folder name", "got \(String(describing: k1?.lastPathComponent))")
        var names = Set<String>()
        if let k1 { names = Set((try? fm.contentsOfDirectory(atPath: k1.path)) ?? []) }
        let want: Set<String> = ["you.wav", "session.json", "you_gated.wav", "pipeline.json"]
        check(names == want, "DK 2b kept folder holds the expected files", "got \(names.sorted())")
        check(k2?.lastPathComponent == "20261125-000000-abcd-2", "DK 2c second keep gets -2", "got \(String(describing: k2?.lastPathComponent))")
        let stillThere = fm.fileExists(atPath: audio.appendingPathComponent("you.wav").path)
            && fm.fileExists(atPath: audio.appendingPathComponent("session.json").path)
        check(stillThere, "DK 2d audio folder files remain", "an audio file is gone")
        try? fm.removeItem(at: temp)
        check(!fm.fileExists(atPath: temp.path), "DK 2e temp folder removed", "still there")
    }
}
