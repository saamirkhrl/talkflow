import Foundation

// --notespipeline <mic.wav> <system.wav> [--out FILE] [--headphones|--speakers] [--model PATH] [--server PATH]
//   [--helper PATH] [--speaker-models DIR] [--port N] [--language CODE] [--no-speakers] [--check]
// Runs the whole after-Stop pipeline on two WAV files and writes the transcript as JSON. Output on stdout is
// numbers and categories only, never text. The run takes the shared bench lock. Exits 0 on success.
// Because main.swift sends stdout to the app log, every line is also appended to
// $TMPDIR/talkflow-notespipeline.log, like the other harnesses.

private var benchLockPath: UnsafeMutablePointer<CChar>?

enum NotesPipelineHarness {
    private static let logURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("talkflow-notespipeline.log")

    private static func say(_ line: String) {
        print("notespipeline: \(line)")
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }

    private struct Options {
        var mic = ""
        var system = ""
        var out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("talkflow-notespipeline.json").path
        var headphones = false
        var model: String?
        var server: String?
        var helper: String?
        var speakerModels: String?
        var port = NotesEngine.testPort
        var language = "en"
        var noSpeakers = false
        var check = false
    }

    private static func parse(_ args: [String]) -> Options? {
        var o = Options()
        var positional: [String] = []
        var i = 0
        func value() -> String? {
            i += 1
            return i < args.count ? args[i] : nil
        }
        while i < args.count {
            switch args[i] {
            case "--out": guard let v = value() else { return nil }; o.out = v
            case "--headphones": o.headphones = true
            case "--speakers": o.headphones = false
            case "--model": guard let v = value() else { return nil }; o.model = v
            case "--server": guard let v = value() else { return nil }; o.server = v
            case "--helper": guard let v = value() else { return nil }; o.helper = v
            case "--speaker-models": guard let v = value() else { return nil }; o.speakerModels = v
            case "--port": guard let v = value(), let n = Int(v) else { return nil }; o.port = n
            case "--language": guard let v = value() else { return nil }; o.language = v
            case "--no-speakers": o.noSpeakers = true
            case "--check": o.check = true
            default:
                if args[i].hasPrefix("--") { return nil }
                positional.append(args[i])
            }
            i += 1
        }
        guard positional.count == 2 else { return nil }
        o.mic = positional[0]
        o.system = positional[1]
        return o
    }

    static func run(_ args: [String]) {
        guard let options = parse(args) else {
            say("usage: --notespipeline <mic.wav> <system.wav> [--out FILE] [--headphones|--speakers] [--model PATH] [--server PATH] [--helper PATH] [--speaker-models DIR] [--port N] [--language CODE] [--no-speakers] [--check]")
            exit(2)
        }
        let locked = takeBenchLock()
        let code = execute(options)
        if locked { releaseBenchLock() }
        exit(code)
    }

    // MARK: - Bench lock

    private static var lockURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/talkflow/test-fixtures/.bench.lock")
    }

    /// mkdir is the lock; retried every 10 s. False when the lock's folder cannot exist at all (no fixtures
    /// folder), in which case the run goes ahead without it.
    private static func takeBenchLock() -> Bool {
        let path = lockURL.path
        var waited = 0
        while true {
            if mkdir(path, 0o755) == 0 {
                benchLockPath = strdup(path)
                // A killed run must not leave the lock behind.
                for sig in [SIGINT, SIGTERM, SIGHUP] {
                    signal(sig) { s in
                        if let p = benchLockPath { rmdir(p) }
                        _exit(128 + s)
                    }
                }
                if waited > 0 { say("bench lock taken after \(waited) s") }
                return true
            }
            if errno != EEXIST {
                say("bench lock not available (errno \(errno)); running without it")
                return false
            }
            if waited == 0 { say("waiting for the bench lock") }
            sleep(10)
            waited += 10
        }
    }

    private static func releaseBenchLock() {
        if let p = benchLockPath { rmdir(p) }
    }

    // MARK: - Run

    private static func execute(_ o: Options) -> Int32 {
        let fm = FileManager.default
        let cwd = fm.currentDirectoryPath
        let model = o.model.map { URL(fileURLWithPath: $0) } ?? NotesModelChoice.model()
        let server = o.server ?? SpeechEngine.serverBinary()
        var helper: URL?
        if let h = o.helper {
            helper = URL(fileURLWithPath: h)
        } else if let bundled = SpeakerHelper.bundledBinary() {
            helper = bundled
        } else {
            let dev = URL(fileURLWithPath: cwd).appendingPathComponent("Helpers/talkflow-diarize/.build/release/talkflow-diarize")
            if fm.isExecutableFile(atPath: dev.path) { helper = dev }
        }
        if o.noSpeakers { helper = nil }
        let language = DictationLanguage(rawValue: o.language) ?? .english
        let config = NotesJobConfig(
            serverBinary: server, model: model, port: o.port, speakerHelper: helper,
            speakerModels: o.speakerModels.map { URL(fileURLWithPath: $0) } ?? SpeakerHelper.modelsFolder,
            prompt: ScreenContext.prompt(names: [], learned: [], language: language),
            language: o.language, englishRules: language == .english, shouldPause: { false })
        let mic = URL(fileURLWithPath: o.mic)
        let system = URL(fileURLWithPath: o.system)
        guard fm.fileExists(atPath: mic.path) || fm.fileExists(atPath: system.path) else {
            say("failed: neither input file exists")
            return 1
        }
        return o.check ? runCheck(o, config: config, mic: mic, system: system)
                       : runPlain(o, config: config, mic: mic, system: system)
    }

    private static func megabytes(_ who: Int32) -> Double {
        var usage = rusage()
        getrusage(who, &usage)
        return Double(usage.ru_maxrss) / 1_048_576   // bytes on macOS
    }

    private static func turnsJSON(_ transcript: Transcript, speakers: [NoteSpeaker]) -> [[String: Any]] {
        transcript.turns.map {
            ["speaker": NotesLogic.displayName($0.speaker, in: speakers), "start": $0.start, "end": $0.end, "text": $0.text]
        }
    }

    private static func write(_ object: [String: Any], to path: String) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
    }

    private static func runPlain(_ o: Options, config: NotesJobConfig, mic: URL, system: URL) -> Int32 {
        final class Box: @unchecked Sendable {
            var result: (pieces: [SpeechPiece], duration: Double, stats: NotesJobStats)?
            var error: Error?
        }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        var printed: [String: Int] = [:]
        let printLock = NSLock()
        let started = Date()
        let thread = Thread {
            let job = NotesJob(config: config)
            do {
                box.result = try job.run(mic: mic, system: system, headphones: o.headphones, progress: { p in
                    let step = p.step.rawValue
                    let bucket = Int(min(max(p.fraction, 0), 1) * 20) * 5
                    printLock.lock()
                    let isNew = printed[step] != bucket
                    printed[step] = bucket
                    printLock.unlock()
                    if isNew { say("\(step) \(bucket)%") }
                })
            } catch {
                box.error = error
            }
            done.signal()
        }
        thread.stackSize = 16 << 20
        thread.start()
        done.wait()

        guard let result = box.result else {
            say("failed: \(box.error.map { "\($0)" } ?? "unknown")")
            return 1
        }
        let transcript = NotesLogic.transcript(from: result.pieces)
        let speakers = NotesLogic.speakers(for: transcript.turns, keeping: [])
        let stats = result.stats
        let total = stats.timings["total"] ?? Date().timeIntervalSince(started)
        let mainMB = megabytes(RUSAGE_SELF)
        let childMB = megabytes(RUSAGE_CHILDREN)
        var statsJSON: [String: Any] = [
            "echo_gate": stats.echoGate,
            "lag_samples": stats.lagSamples ?? NSNull(),
            "drift_ppm": stats.driftPPM ?? NSNull(),
            "speaker_engine": stats.speakerEngine,
            "speaker_reason": stats.speakerReason ?? NSNull(),
            "speaker_count": stats.speakerCount,
            "pieces_you": stats.piecesYou,
            "pieces_others": stats.piecesOthers,
            "retries": stats.retries,
            "splits": stats.splits,
            "near_end_gate_seconds": stats.nearEndZeroedSeconds,
            "residual_db": stats.residualDB ?? NSNull(),
            "prompt_echoes": stats.promptEchoes,
            "dropped": stats.dropped,
            "inaudible": stats.inaudible,
            "rule_removed_words": stats.ruleRemovedWords,
            "paused_seconds": stats.pausedSeconds,
            "audio_seconds": stats.audioSeconds,
            "speech_seconds": stats.speechSeconds,
        ]
        statsJSON["timings"] = stats.timings
        let output: [String: Any] = [
            "turns": turnsJSON(transcript, speakers: speakers),
            "audio_seconds": result.duration,
            "rtf": result.duration > 0 ? total / result.duration : 0,
            "timing": stats.timings,
            "peak_memory_mb": ["talkflowd": mainMB, "children_max": childMB],
            "stats": statsJSON,
            "model": config.model.lastPathComponent,
            "port": config.port,
        ]
        guard write(output, to: o.out) else {
            say("failed: could not write the output file")
            return 1
        }
        let names = speakers.map { NotesLogic.displayName($0.key, in: speakers) }.joined(separator: ", ")
        say("done: \(transcript.turns.count) turns, speakers \(speakers.count) (\(names)), audio \(String(format: "%.1f", result.duration)) s, rtf \(String(format: "%.3f", result.duration > 0 ? total / result.duration : 0))")
        say("gate \(stats.echoGate), speaker engine \(stats.speakerEngine) (\(stats.speakerCount)), pieces you \(stats.piecesYou) others \(stats.piecesOthers), retries \(stats.retries), splits \(stats.splits), dropped \(stats.dropped), inaudible \(stats.inaudible), rule removed \(stats.ruleRemovedWords) words")
        say("timing " + stats.timings.keys.sorted().map { "\($0) \(String(format: "%.2f", stats.timings[$0] ?? 0))" }.joined(separator: ", "))
        say("peak memory MB: talkflowd \(String(format: "%.0f", mainMB)), children max \(String(format: "%.0f", childMB))")
        say("wrote \(o.out)")
        return 0
    }

    // MARK: - --check: audio gone, log clean

    private static func runCheck(_ o: Options, config: NotesJobConfig, mic: URL, system: URL) -> Int32 {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("talkflow-notespipeline-check-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let store = NoteStore(root: root)
        guard let meta = try? store.create(title: "Check", started: Date()) else {
            say("FAIL could not create the temporary note")
            return 1
        }
        let id = meta.id
        let audio = store.audioFolder(for: id)
        do {
            if fm.fileExists(atPath: mic.path) {
                try fm.copyItem(at: mic, to: audio.appendingPathComponent(CaptureFolder.mic))
            }
            if fm.fileExists(atPath: system.path) {
                try fm.copyItem(at: system, to: audio.appendingPathComponent(CaptureFolder.system))
            }
            let info = CaptureSessionInfo(started: Date(), hostStart: 0,
                                          routes: [.init(atSeconds: 0, route: o.headphones ? .headphones : .speakers)])
            try info.write(to: audio)
        } catch {
            say("FAIL could not copy the audio")
            return 1
        }

        // stdout goes to a temp file while the pipeline runs, so the log can be checked for leaked text.
        let capture = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("talkflow-notespipeline-check-\(ProcessInfo.processInfo.processIdentifier).log")
        defer { try? fm.removeItem(at: capture) }
        fflush(stdout)
        let saved = dup(STDOUT_FILENO)
        let captureFD = open(capture.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        if captureFD >= 0 { dup2(captureFD, STDOUT_FILENO) }

        let model = NotesModel(store: store, capture: UnbuiltCapture(), pipeline: LocalNotesPipeline(makeConfig: { config }))
        model.finishLeftover(id)
        let deadline = Date().addingTimeInterval(30 * 60)
        func settled() -> Bool {
            switch store.meta(id)?.state {
            case .ready?, .failed?: return true
            default: return false
            }
        }
        while !settled() && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }

        fflush(stdout)
        if saved >= 0 { dup2(saved, STDOUT_FILENO); close(saved) }
        if captureFD >= 0 { close(captureFD) }
        let log = (try? String(contentsOf: capture, encoding: .utf8)) ?? ""

        var failures = 0
        func check(_ ok: Bool, _ label: String) {
            say((ok ? "ok   " : "FAIL ") + label)
            if !ok { failures += 1 }
        }
        let finalMeta = store.meta(id)
        let ready: Bool = { if case .ready? = finalMeta?.state { return true } else { return false } }()
        check(ready, "state is ready")
        var wavs = 0
        if let walker = fm.enumerator(atPath: store.folder(for: id).path) {
            for case let name as String in walker where (name as NSString).pathExtension.lowercased() == "wav" { wavs += 1 }
        }
        check(wavs == 0 && !store.hasAudio(id), "no .wav left and the audio folder is empty (\(wavs) found)")
        let transcript = store.transcript(id)
        check(!(transcript?.turns.isEmpty ?? true), "transcript has turns (\(transcript?.turns.count ?? 0))")
        check(!NotesFlow.logLeaks(log: log, transcript: transcript ?? Transcript(turns: [])), "the log holds no transcript text (\(log.split(separator: "\n").count) log lines)")

        if let transcript, let finalMeta {
            let output: [String: Any] = [
                "turns": turnsJSON(transcript, speakers: finalMeta.speakers),
                "audio_seconds": finalMeta.duration,
            ]
            if !write(output, to: o.out) { say("could not write the output file") }
        }
        say(failures == 0 ? "check: ALL PASS" : "check: \(failures) FAILURES")
        return failures == 0 ? 0 : 1
    }
}
