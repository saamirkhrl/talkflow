import Foundation

/// `talkflowd --echotest [folder]`: the echo stage on the digital fixtures (mic.wav, sys.wav, near.wav,
/// meta.json per subfolder). Prints numbers only. Results also go to $TMPDIR/talkflow-echotest.log.
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
        report(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
        exit(failures == 0 ? 0 : 1)
    }
}
