import Foundation

/// `talkflowd --diarizetest [--helper <path>] [--models <dir>]`: runs the speaker helper on the
/// diarization spike's fixtures and reports the diarization error rate, speakers found and wall
/// time. Skips with one line when the fixtures or the helper are absent. Numbers only; results in
/// $TMPDIR/talkflow-diarizetest.log.
enum DiarizeSelfTest {
    private static let logURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("talkflow-diarizetest.log")

    private static func report(_ line: String) {
        print("talkflowd: [diarizetest] \(line)")
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }

    /// Spike results (pyannote.metrics, FluidAudio defaults without merge-gap) and truth speaker counts.
    private static let fixtures: [(name: String, spikeDER: Double, speakers: Int)] = [
        ("f2", 0.0014, 2), ("f3", 0.0080, 3), ("f5", 0.0191, 5), ("fakemeeting", 0.0608, 5),
    ]

    static func run(arguments: [String]) -> Never {
        try? FileManager.default.removeItem(at: logURL)
        report("--- diarizetest ---")
        let code = execute(arguments: arguments)
        exit(code)
    }

    private static func value(of flag: String, in arguments: [String]) -> String? {
        guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    private static func execute(arguments: [String]) -> Int32 {
        let fm = FileManager.default
        let support = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/talkflow/test-fixtures", isDirectory: true)
        let spike = support.appendingPathComponent("spikes/diarization", isDirectory: true)
        let fixtureRoot = spike.appendingPathComponent("fixtures", isDirectory: true)

        let helper: URL
        if let h = value(of: "--helper", in: arguments) {
            helper = URL(fileURLWithPath: h)
        } else if let b = SpeakerHelper.bundledBinary() {
            helper = b
        } else {
            helper = URL(fileURLWithPath: fm.currentDirectoryPath)
                .appendingPathComponent("Helpers/talkflow-diarize/.build/release/talkflow-diarize")
        }
        guard fm.isExecutableFile(atPath: helper.path) else {
            report("diarizetest: helper not found, skipped")
            return 0
        }
        guard fm.fileExists(atPath: fixtureRoot.path) else {
            report("diarizetest: fixtures folder not found, skipped")
            return 0
        }
        let models: URL
        if let m = value(of: "--models", in: arguments) {
            models = URL(fileURLWithPath: m, isDirectory: true)
        } else {
            let spikeModels = spike.appendingPathComponent("models/fluidaudio", isDirectory: true)
            models = fm.fileExists(atPath: spikeModels.path) ? spikeModels : SpeakerHelper.modelsFolder
        }

        // Timed runs share the machine with other benchmarks: take the shared lock.
        let lockPath = support.appendingPathComponent(".bench.lock").path
        let deadline = Date().addingTimeInterval(20 * 60)
        var held = false
        while !held {
            if mkdir(lockPath, 0o755) == 0 {
                held = true
            } else if Date() >= deadline {
                report("diarizetest: bench lock still held after 20 minutes, giving up")
                return 1
            } else {
                report("diarizetest: waiting for the bench lock")
                Thread.sleep(forTimeInterval: 10)
            }
        }
        defer { rmdir(lockPath) }

        var failures = 0
        func check(_ ok: Bool, _ label: String, _ detail: String) {
            report((ok ? "ok   " : "FAIL ") + label + (ok ? "" : " -> " + detail))
            if !ok { failures += 1 }
        }

        for fx in fixtures {
            let dir = fixtureRoot.appendingPathComponent(fx.name, isDirectory: true)
            let wav = dir.appendingPathComponent("system.wav")
            guard fm.fileExists(atPath: wav.path), let truth = loadTruth(dir.appendingPathComponent("truth.json")) else {
                report("diarizetest: \(fx.name) fixture not found, skipped")
                continue
            }
            let seconds = truth.map { $0.end }.max() ?? 0
            let started = Date()
            do {
                let turns = try SpeakerRun(binary: helper, modelsDir: models).run(wav: wav, audioSeconds: seconds)
                let wall = Date().timeIntervalSince(started)
                let flat = SpeakerTurns.flatten(turns)
                let rawDER = der(truth: truth, hyp: turns)
                let flatDER = der(truth: truth, hyp: flat)
                let found = Set(turns.map { $0.speaker }).count
                let wanted = Set(truth.map { $0.speaker }).count
                report(String(format: "%@: raw DER %.2f%%, flattened DER %.2f%%, speakers %d/%d, %d turns, %d runs, wall %.1f s (spike %.2f%%)",
                              fx.name, rawDER * 100, flatDER * 100, found, wanted, turns.count, flat.count, wall, fx.spikeDER * 100))
                check(found == wanted, "\(fx.name) speakers found equal truth", "\(found) of \(wanted)")
                check(rawDER <= fx.spikeDER + 0.015, "\(fx.name) raw DER within 1.5 points of the spike",
                      String(format: "%.2f%% vs %.2f%%", rawDER * 100, fx.spikeDER * 100))
            } catch {
                check(false, "\(fx.name) helper run", "\(error)")
            }
        }
        report(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
        return failures == 0 ? 0 : 1
    }

    private static func loadTruth(_ url: URL) -> [SpeakerSegment]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let segments = object["segments"] as? [[String: Any]] else { return nil }
        return segments.compactMap {
            guard let speaker = $0["speaker"] as? String,
                  let start = ($0["start"] as? NSNumber)?.doubleValue,
                  let end = ($0["end"] as? NSNumber)?.doubleValue else { return nil }
            return SpeakerSegment(speaker: speaker, start: start, end: end)
        }
    }

    /// Diarization error rate on 10 ms frames, overlapped speech scored. Frames whose centre lies
    /// within `collar` seconds of a truth segment start or end are skipped. Hypothesis labels are
    /// mapped one to one onto truth labels to maximise co-active frames.
    static func der(truth: [SpeakerSegment], hyp: [SpeakerSegment], collar: Double = 0.25) -> Double {
        let step = 0.01
        let truthT = truth.filter { $0.end > $0.start }
        let hypT = hyp.filter { $0.end > $0.start }
        let total = max(truthT.map { $0.end }.max() ?? 0, hypT.map { $0.end }.max() ?? 0)
        let frames = Int((total / step).rounded(.up))
        guard frames > 0 else { return 0 }

        let truthLabels = Array(Set(truthT.map { $0.speaker })).sorted()
        let hypLabels = Array(Set(hypT.map { $0.speaker })).sorted()
        let tIndex = Dictionary(uniqueKeysWithValues: truthLabels.enumerated().map { ($1, $0) })
        let hIndex = Dictionary(uniqueKeysWithValues: hypLabels.enumerated().map { ($1, $0) })

        func activity(_ segs: [SpeakerSegment], _ index: [String: Int]) -> [[Int]] {
            var out = [[Int]](repeating: [], count: frames)
            for s in segs {
                let label = index[s.speaker] ?? 0
                // frame i has centre (i + 0.5) * step; active when start <= centre < end
                let first = max(0, Int((s.start / step - 0.5).rounded(.up)))
                let last = min(frames - 1, Int((s.end / step - 0.5).rounded(.up)) - 1)
                if first <= last {
                    for i in first...last where !out[i].contains(label) { out[i].append(label) }
                }
            }
            return out
        }
        let tAct = activity(truthT, tIndex)
        let hAct = activity(hypT, hIndex)

        var skipped = [Bool](repeating: false, count: frames)
        if collar > 0 {
            for s in truthT {
                for b in [s.start, s.end] {
                    let first = max(0, Int(((b - collar) / step - 0.5).rounded(.up)))
                    let last = min(frames - 1, Int(((b + collar) / step - 0.5).rounded(.down)))
                    if first <= last { for i in first...last { skipped[i] = true } }
                }
            }
        }

        var co = [[Int]](repeating: [Int](repeating: 0, count: max(truthLabels.count, 1)), count: max(hypLabels.count, 1))
        for i in 0..<frames where !skipped[i] {
            for h in hAct[i] { for t in tAct[i] { co[h][t] += 1 } }
        }
        let mapping = bestMapping(co, hypCount: hypLabels.count, truthCount: truthLabels.count)

        var errors = 0
        var reference = 0
        for i in 0..<frames where !skipped[i] {
            let nT = tAct[i].count
            let nH = hAct[i].count
            let correct = hAct[i].reduce(0) { acc, h in
                if let t = mapping[h], tAct[i].contains(t) { return acc + 1 }
                return acc
            }
            errors += max(0, nT - nH) + max(0, nH - nT) + (min(nT, nH) - correct)
            reference += nT
        }
        return reference == 0 ? 0 : Double(errors) / Double(reference)
    }

    /// hyp index -> truth index; exhaustive over one-to-one assignments, greedy beyond 8 labels.
    private static func bestMapping(_ co: [[Int]], hypCount: Int, truthCount: Int) -> [Int: Int] {
        guard hypCount > 0, truthCount > 0 else { return [:] }
        if hypCount > 8 || truthCount > 8 {
            var pairs: [(h: Int, t: Int, n: Int)] = []
            for h in 0..<hypCount { for t in 0..<truthCount { pairs.append((h, t, co[h][t])) } }
            pairs.sort { $0.n > $1.n }
            var usedH = Set<Int>(), usedT = Set<Int>()
            var out: [Int: Int] = [:]
            for p in pairs where p.n > 0 && !usedH.contains(p.h) && !usedT.contains(p.t) {
                out[p.h] = p.t
                usedH.insert(p.h)
                usedT.insert(p.t)
            }
            return out
        }
        var best = 0
        var bestMap: [Int: Int] = [:]
        var current: [Int: Int] = [:]
        var usedT = Set<Int>()
        func search(_ h: Int, _ score: Int) {
            if h == hypCount {
                if score > best { best = score; bestMap = current }
                return
            }
            search(h + 1, score)  // leave this hypothesis label unmapped
            for t in 0..<truthCount where !usedT.contains(t) {
                usedT.insert(t)
                current[h] = t
                search(h + 1, score + co[h][t])
                current[h] = nil
                usedT.remove(t)
            }
        }
        search(0, 0)
        return bestMap
    }
}
