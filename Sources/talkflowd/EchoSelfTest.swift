import Foundation

/// Path of the held bench lock for the signal handlers (C callbacks cannot capture).
private var echoBenchLockPath: UnsafeMutablePointer<CChar>?

/// `talkflowd --echotest [folder] [--words [--model PATH] [--server PATH] [--port N] [--only a,b]]`: the echo
/// stage on the digital fixtures (mic.wav, sys.wav, near.wav, meta.json per subfolder). Prints numbers only.
/// Results also go to $TMPDIR/talkflow-echotest.log. With --words the real notes pipeline then runs on each
/// fixture and the You words are scored for far-end leak and near-end keep (scoring as the echo spike's score.py).
enum EchoSelfTest {
    private static var failures = 0

    private static let logURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("talkflow-echotest.log")

    private static func report(_ line: String) {
        print(line)
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }

    private static func check(_ condition: Bool, _ label: String, _ detail: String = "") {
        report((condition ? "ok   " : "FAIL ") + label + (condition || detail.isEmpty ? "" : " -> " + detail))
        if !condition { failures += 1 }
    }

    /// ERLE over the 20 ms frames whose (mic - near) RMS is above -50 dBFS:
    /// 10 log10(sum (mic-near)^2 / sum (out-near)^2). The residual still holds the mic noise floor, so this
    /// reads lower than the spike's echo-only numbers.
    private static func erle(mic: [Int16], near: [Int16], out: [Int16]) -> Double? {
        let n = min(mic.count, min(near.count, out.count))
        let frame = 320
        let gate = EchoStage.silent
        var num = 0.0, den = 0.0
        for f in 0..<(n / frame) {
            var e0 = 0.0, e1 = 0.0
            for i in (f * frame)..<((f + 1) * frame) {
                let a = (Double(mic[i]) - Double(near[i])) / 32768.0
                let b = (Double(out[i]) - Double(near[i])) / 32768.0
                e0 += a * a
                e1 += b * b
            }
            if (e0 / Double(frame)).squareRoot() > gate {
                num += e0
                den += e1
            }
        }
        if num == 0 { return nil }
        return 10 * log10(num / max(den, 1e-30))
    }

    static func run(folder: String?) -> Never {
        try? FileManager.default.removeItem(at: logURL)
        let defaultFolder = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/talkflow/test-fixtures/echo/digital")
        let path = (folder.flatMap { $0.hasPrefix("--") ? nil : $0 }) ?? defaultFolder
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            report("echotest: no fixtures at \(path), skipped")
            exit(0)
        }
        report("--- echotest ---")
        report("name gate a drift_ppm inliers/windows erle_db bitexact stage_s")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted()
        for name in names {
            let dir = URL(fileURLWithPath: path).appendingPathComponent(name)
            let mic = dir.appendingPathComponent("mic.wav"), sys = dir.appendingPathComponent("sys.wav")
            let nearURL = dir.appendingPathComponent("near.wav"), metaURL = dir.appendingPathComponent("meta.json")
            let fm = FileManager.default
            guard [mic, sys, nearURL, metaURL].allSatisfy({ fm.fileExists(atPath: $0.path) }),
                  let metaData = try? Data(contentsOf: metaURL),
                  let meta = (try? JSONSerialization.jsonObject(with: metaData)) as? [String: Any] else { continue }
            let headphones = (meta["route"] as? String) == "headphones"
            let delayMs = (meta["delay_ms"] as? NSNumber)?.doubleValue
            let micS = WavSamples.read(mic), sysS = WavSamples.read(sys), nearS = WavSamples.read(nearURL)

            let t0 = Date()
            let result = EchoStage.run(mic: micS, system: sysS, headphones: headphones)
            let secs = Date().timeIntervalSince(t0)

            let gate = result.bypass?.rawValue ?? "open"
            let exact = result.samples == micS
            let e = erle(mic: micS, near: nearS, out: result.samples)
            let a = result.fit?.a
            let ppm = (result.fit?.b).map { $0 * 1e6 }
            report(String(format: "%@ %@ a=%@ drift=%@ in=%@ erle=%@ exact=%@ t=%.2f",
                          name, gate,
                          a.map { String(format: "%.1f", $0) } ?? "-",
                          ppm.map { String(format: "%.1f", $0) } ?? "-",
                          result.fit.map { "\($0.inliers)/\($0.windows)" } ?? "-",
                          e.map { String(format: "%.1f", $0) } ?? "-",
                          exact ? "yes" : "no", secs))

            if name == "hp" {
                check(result.bypass == .headphones && exact, "EchoTest hp is bypassed and bit-exact", "\(gate) exact=\(exact)")
            }
            let isDigital = name.hasPrefix("pe_") || name.hasPrefix("dt_") || name.hasPrefix("hard_")
            if isDigital, let delayMs {
                let expected = delayMs * 16
                // With drift, a is the line's intercept at sample 0 (window lags scatter by a few samples), so it gets +-8.
                let slack = name.hasPrefix("hard_drift_") ? 8.0 : 1.0
                check(result.bypass == nil && a != nil && abs(a! - expected) <= slack,
                      "EchoTest \(name) gate open, a within delay_ms*16 +-\(Int(slack))", "gate \(gate) a \(a.map { String($0) } ?? "-") expected \(expected)")
                let drift = ppm ?? 0
                if name.hasPrefix("hard_drift_") {
                    check(drift >= 90 && drift <= 110, "EchoTest \(name) drift within 90..110 ppm", "\(drift)")
                } else {
                    check(drift == 0, "EchoTest \(name) drift is 0", "\(drift)")
                }
            }
            if name == "pe_12_60" {
                check((e ?? -99) >= 20, "EchoTest pe_12_60 ERLE >= 20 dB", "\(e.map { String($0) } ?? "-")")
            }
            if name == "dt_6_60" {
                check((e ?? -99) >= 12, "EchoTest dt_6_60 ERLE >= 12 dB", "\(e.map { String($0) } ?? "-")")
            }
        }
        let args = Array(CommandLine.arguments.dropFirst())
        if args.contains("--words") {
            wordsRun(path: path, names: names, args: args)
        }
        report(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Word level (--words)

    private static let stop: Set<String> = Set("""
        the a an and of to in is it that i we you for on with as was be at by this our or not but have had all
        so are from his her my me no she he they them its their there one what which when were would been if
        """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))

    /// score.py norm_text: lowercase, hyphens and em dashes split words, only a-z 0-9 and apostrophes kept
    /// (apostrophes dropped).
    private static func normWords(_ text: String) -> [String] {
        var out: [String] = []
        for tok in text.split(whereSeparator: { $0.isWhitespace }) {
            var w = ""
            for ch in tok.lowercased() {
                if ch == "-" || ch == "\u{2014}" { w.append(" "); continue }
                if let a = ch.asciiValue, (a >= 97 && a <= 122) || (a >= 48 && a <= 57) { w.append(ch) }
            }
            out.append(contentsOf: w.split(separator: " ").map(String.init))
        }
        return out
    }

    private static func lcs(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty || b.isEmpty { return 0 }
        var prev = [Int](repeating: 0, count: b.count + 1)
        for x in a {
            var cur = [Int](repeating: 0, count: b.count + 1)
            for j in 0..<b.count {
                cur[j + 1] = x == b[j] ? prev[j] + 1 : max(prev[j + 1], cur[j])
            }
            prev = cur
        }
        return prev[b.count]
    }

    private static func lockURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/talkflow/test-fixtures/.bench.lock")
    }

    /// mkdir is the lock; retried every 10 s. Without a fixtures folder the run goes ahead without it.
    private static func takeLock() -> Bool {
        let path = lockURL().path
        var waited = 0
        while true {
            if mkdir(path, 0o755) == 0 {
                echoBenchLockPath = strdup(path)
                for sig in [SIGINT, SIGTERM, SIGHUP] {
                    signal(sig) { s in
                        if let p = echoBenchLockPath { rmdir(p) }
                        _exit(128 + s)
                    }
                }
                if waited > 0 { report("bench lock taken after \(waited) s") }
                return true
            }
            if errno != EEXIST {
                report("bench lock not available (errno \(errno)); running without it")
                return false
            }
            if waited == 0 { report("waiting for the bench lock") }
            sleep(10)
            waited += 10
        }
    }

    private static func releaseLock() {
        if let p = echoBenchLockPath { rmdir(p) }
    }

    private struct WordScore {
        var leakNum = 0, leakDen = 0
        var keepNum = 0, keepDen = 0
    }

    /// score.py's leak and keep. `youWords` are the normalised You words. Keep here is against the reference
    /// text, not whisper's transcript of the clean near track, so whisper's own misrecognitions lower it.
    private static func score(you: [String], near: String, far: String) -> WordScore {
        let farWords = normWords(far), nearWords = normWords(near)
        let farSet = Set(farWords), nearSet = Set(nearWords)
        let f = farSet.subtracting(nearSet).subtracting(stop)
        let n = nearSet.subtracting(farSet).subtracting(stop)
        var r = WordScore()
        let ff = farWords.filter { f.contains($0) }
        r.leakDen = ff.count
        if !ff.isEmpty { r.leakNum = lcs(you.filter { f.contains($0) }, ff) }
        let nn = nearWords.filter { n.contains($0) }
        r.keepDen = nn.count
        if !nn.isEmpty { r.keepNum = lcs(you.filter { n.contains($0) }, nn) }
        return r
    }

    private static func pct(_ num: Int, _ den: Int) -> String {
        den == 0 ? "0.0" : String(format: "%.1f", 100.0 * Double(num) / Double(den))
    }

    private static func wordsRun(path: String, names: [String], args: [String]) {
        func option(_ key: String) -> String? {
            guard let i = args.firstIndex(of: key), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let only = option("--only").map { Set($0.split(separator: ",").map(String.init)) }
        let port = option("--port").flatMap { Int($0) } ?? 8194
        let fm = FileManager.default
        let model = option("--model").map { URL(fileURLWithPath: $0) } ?? NotesModelChoice.model()
        let server = option("--server") ?? SpeechEngine.serverBinary()
        let config = NotesJobConfig(
            serverBinary: server, model: model, port: port, speakerHelper: nil,
            speakerModels: SpeakerHelper.modelsFolder, prompt: "", language: "en",
            englishRules: true, shouldPause: { false })

        let locked = takeLock()
        defer { if locked { releaseLock() } }
        report("--- echotest words (real notes pipeline, no diarization) ---")
        report("keep is against the reference near text, so whisper's own misrecognitions lower it (the spike compared to whisper's clean-near transcript)")
        report("name leak% keep% you_words seconds")

        var groups: [String: WordScore] = [:]
        var keepGroup = WordScore()
        var hpLeak: Double?
        var hpKeep: String?
        for name in names where only == nil || only!.contains(name) {
            let dir = URL(fileURLWithPath: path).appendingPathComponent(name)
            let mic = dir.appendingPathComponent("mic.wav"), sys = dir.appendingPathComponent("sys.wav")
            guard fm.fileExists(atPath: mic.path), fm.fileExists(atPath: sys.path),
                  let metaData = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
                  let meta = (try? JSONSerialization.jsonObject(with: metaData)) as? [String: Any] else { continue }
            let headphones = (meta["route"] as? String) == "headphones"

            final class Box: @unchecked Sendable {
                var pieces: [SpeechPiece]?
                var error: Error?
            }
            let box = Box()
            let done = DispatchSemaphore(value: 0)
            let t0 = Date()
            let thread = Thread {
                do {
                    box.pieces = try NotesJob(config: config).run(mic: mic, system: sys, headphones: headphones, progress: { _ in }).pieces
                } catch {
                    box.error = error
                }
                done.signal()
            }
            thread.stackSize = 16 << 20
            thread.start()
            done.wait()
            let secs = Date().timeIntervalSince(t0)
            guard let pieces = box.pieces else {
                report("FAIL EchoTest words \(name) pipeline failed -> \(box.error.map { "\($0)" } ?? "unknown")")
                failures += 1
                continue
            }
            let you = normWords(pieces.filter { $0.speaker == "you" }.map(\.text).joined(separator: " "))
            let sc = score(you: you, near: meta["near_text"] as? String ?? "", far: meta["far_text"] as? String ?? "")
            let isDT = name.hasPrefix("dt_") || name.hasSuffix("_dt") || name == "hp"
            report(String(format: "%@ leak=%@ keep=%@ you=%d t=%.1f", name, pct(sc.leakNum, sc.leakDen),
                          isDT ? pct(sc.keepNum, sc.keepDen) : "-", you.count, secs))

            let group = name.hasPrefix("pe_") ? "pe" : name.hasPrefix("dt_") ? "dt"
                : name.hasPrefix("hard_") ? "hard" : name.hasPrefix("acoustic_") ? "acoustic" : nil
            if let group {
                var g = groups[group] ?? WordScore()
                g.leakNum += sc.leakNum
                g.leakDen += sc.leakDen
                groups[group] = g
            }
            if name.hasPrefix("dt_") || name.hasPrefix("hard_") && name.hasSuffix("_dt") || name == "acoustic_dt" {
                keepGroup.keepNum += sc.keepNum
                keepGroup.keepDen += sc.keepDen
            }
            if name == "hp" {
                hpLeak = sc.leakDen == 0 ? 0 : Double(sc.leakNum) / Double(sc.leakDen)
                hpKeep = pct(sc.keepNum, sc.keepDen)
            }
        }
        for (group, label) in [("pe", "pe_* (12)"), ("dt", "dt_* (12)"), ("hard", "hard_* (4)"), ("acoustic", "acoustic_* (2)")] {
            if let g = groups[group] { report("group \(label) leak \(pct(g.leakNum, g.leakDen))% (\(g.leakNum)/\(g.leakDen))") }
        }
        if keepGroup.keepDen > 0 {
            report("group keep dt_* + hard_*_dt + acoustic_dt \(pct(keepGroup.keepNum, keepGroup.keepDen))% (\(keepGroup.keepNum)/\(keepGroup.keepDen)), against reference text")
        }
        for group in ["pe", "dt"] {
            if let g = groups[group] {
                let leak = g.leakDen == 0 ? 0 : Double(g.leakNum) / Double(g.leakDen)
                check(leak <= 0.02, "EchoTest words \(group)_* leak <= 2%", pct(g.leakNum, g.leakDen) + "%")
            }
        }
        if let hpLeak {
            check(hpLeak == 0, "EchoTest words hp leak is 0", "\(hpLeak)")
            report("hp keep \(hpKeep ?? "-")%")
        }
    }
}
