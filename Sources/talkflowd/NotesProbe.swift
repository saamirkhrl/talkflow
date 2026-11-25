import Foundation

/// `talkflowd --notesprobe <mic.wav> <system.wav> [--dump DIR]`: the notes pipeline's audio stages only (echo
/// stage, near-end gate, pause cutter) on two 16 kHz files, without the speech engine. Prints numbers only. With
/// --dump, the cleaned and gated microphone tracks are written to DIR for offline analysis. Plays nothing.
/// Results go to $TMPDIR/talkflow-notesprobe.log (stdout is the app log).
enum NotesProbe {
    private static let logURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("talkflow-notesprobe.log")

    private static func print(_ line: String) {
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }

    static func run(_ arguments: [String]) -> Never {
        try? FileManager.default.removeItem(at: logURL)
        guard let i = arguments.firstIndex(of: "--notesprobe"), i + 2 < arguments.count else {
            print("usage: --notesprobe <mic.wav> <system.wav> [--dump DIR]")
            exit(2)
        }
        let micURL = URL(fileURLWithPath: arguments[i + 1])
        let sysURL = URL(fileURLWithPath: arguments[i + 2])
        var dump: URL?
        if let d = arguments.firstIndex(of: "--dump"), d + 1 < arguments.count {
            dump = URL(fileURLWithPath: arguments[d + 1], isDirectory: true)
        }
        let mic = WavSamples.read(micURL)
        let sys = WavSamples.read(sysURL)
        if mic.isEmpty || sys.isEmpty {
            print("probe: could not read the files")
            exit(2)
        }
        let t0 = Date()
        let result = EchoStage.run(mic: mic, system: sys, headphones: false)
        let echoSeconds = Date().timeIntervalSince(t0)
        func f(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "-" }
        print("probe: echo bypass \(result.bypass.map { "\($0)" } ?? "none"), lag \(f(result.fit?.a)), \(f(echoSeconds)) s")
        var track = result.samples
        var minThr: Double?
        if result.bypass == nil {
            let residual = NearEndGate.residualLevel(raw: mic, cleaned: result.samples)
            minThr = residual.map { $0 + NearEndGate.residualMarginDB }
            let gated = NearEndGate.apply(raw: mic, cleaned: result.samples)
            track = gated.samples
            print("probe: residual \(f(residual)) dBFS, gate zeroed \(f(gated.zeroedSeconds)) s")
            if !arguments.contains("--no-residue") {
                let r = EchoResidue.apply(track: track, raw: mic, cleaned: result.samples, minThreshold: minThr)
                track = r.samples
                print("probe: leakage \(f(r.leakDB)) dB, residue dropped \(r.decisions.filter { !$0.kept }.count) of \(r.decisions.count) regions, \(f(r.droppedSeconds)) s")
                for d in r.decisions {
                    print(String(format: "probe: region %.2f-%.2f level %.1f above %@ %@", d.start, d.end, d.levelDB,
                                 f(d.aboveLeakDB), d.reason))
                }
            }
        }
        let sysDB = PauseCutter.frameDB(sys[...])
        let farActive = Double(sysDB.filter { $0 > -50 }.count) * PauseCutter.frameSeconds
        print("probe: far-end frames above -50 dBFS \(f(farActive)) s of \(f(Double(sys.count) / 16000)) s")
        let pieces = PauseCutter.cut(track, minThreshold: minThr)
        let speech = pieces.reduce(0) { $0 + $1.speech }
        print("probe: you pieces \(pieces.count), speech \(f(speech)) s, threshold floor \(f(minThr))")
        for p in pieces {
            print(String(format: "probe: piece %.2f-%.2f speech %.2f", p.start, p.end, p.speech))
        }
        if let dir = dump {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (name, samples) in [("clean.wav", result.samples), ("gated.wav", track)] {
                if let w = try? StreamingWav(url: dir.appendingPathComponent(name)) {
                    _ = w.append(samples)
                    w.finish()
                }
            }
            print("probe: wrote clean.wav and gated.wav")
        }
        exit(0)
    }
}
