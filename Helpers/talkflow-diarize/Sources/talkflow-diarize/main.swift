import AVFoundation
import FluidAudio
import Foundation

// talkflow-diarize: thin CLI over FluidAudio's offline diarizer
// (pyannote community-1 segmentation + WeSpeaker embeddings + VBx clustering).
// The library does the work; this file only parses flags, reports progress and
// post-processes segments as the contract describes.
//
// It is a separate executable (not linked into talkflowd) so the app stays small
// and universal, and so a crash or a memory spike in the models cannot take the
// dictation daemon down.
//
// Commands and exit codes (the app depends on these):
//   check    [--models-dir D]                 prints {"supported":..,"reason":..,"models_present":..}
//   prepare  --models-dir D                   downloads the models into D (the only command that uses the network)
//   run      --models-dir D --input F.wav     writes the speaker turns as JSON (to --output, or stdout)
//   exit 0 ok, 2 bad arguments, 3 models missing, 4 input unreadable,
//        5 failed, 6 unsupported Mac, 7 download failed
// Output never contains file paths: the app already knows which file it passed in.

let engineVersion = "0.18.4"
let repoFolder = Repo.diarizer.folderName  // "speaker-diarization"

enum Exit: Int32 {
    case ok = 0, badArgs = 2, modelsMissing = 3, inputUnreadable = 4
    case failed = 5, unsupported = 6, downloadFailed = 7
}

func die(_ code: Exit, _ message: String) -> Never {
    FileHandle.standardError.write(Data(("talkflow-diarize: " + message + "\n").utf8))
    exit(code.rawValue)
}

/// One JSON object on one line, on stdout or stderr. `run` keeps stdout for the result
/// (when no --output is given) and reports progress on stderr, so the two never mix.
func emit(_ object: [String: Any], toStderr: Bool = false) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
    let line = data + Data("\n".utf8)
    if toStderr {
        FileHandle.standardError.write(line)
    } else {
        FileHandle.standardOutput.write(line)
    }
}

/// JSON number with at most 3 decimals and no binary-float noise (11.63, not 11.630000000000001).
func dec3(_ x: Double) -> NSDecimalNumber { NSDecimalNumber(string: String(format: "%.3f", x)) }

// MARK: - Arguments

struct Args {
    var command = ""
    var modelsDir: String?
    var input: String?
    var output: String?
    var numSpeakers: Int?
    var minSpeakers: Int?
    var maxSpeakers: Int?
    var threshold: Double?
    var minTurn = 0.0
    var mergeGap = 0.0
}

func parseArgs(_ argv: [String]) -> Args {
    var a = Args()
    var i = 1
    guard i < argv.count else { die(.badArgs, "missing command (prepare | run | check)") }
    a.command = argv[i]
    i += 1
    func value(_ flag: String) -> String {
        i += 1
        guard i < argv.count else { die(.badArgs, "\(flag) needs a value") }
        return argv[i]
    }
    func int(_ flag: String) -> Int {
        guard let n = Int(value(flag)), n > 0 else { die(.badArgs, "\(flag) needs a positive integer") }
        return n
    }
    func dbl(_ flag: String, min: Double = 0) -> Double {
        guard let d = Double(value(flag)), d.isFinite, d >= min else {
            die(.badArgs, "\(flag) needs a number >= \(min)")
        }
        return d
    }
    while i < argv.count {
        switch argv[i] {
        case "--models-dir": a.modelsDir = value("--models-dir")
        case "--input": a.input = value("--input")
        case "--output": a.output = value("--output")
        case "--num-speakers": a.numSpeakers = int("--num-speakers")
        case "--min-speakers": a.minSpeakers = int("--min-speakers")
        case "--max-speakers": a.maxSpeakers = int("--max-speakers")
        case "--threshold": a.threshold = dbl("--threshold")
        case "--min-turn": a.minTurn = dbl("--min-turn")
        case "--merge-gap": a.mergeGap = dbl("--merge-gap")
        default: die(.badArgs, "unknown argument \(argv[i])")
        }
        i += 1
    }
    return a
}

// MARK: - Support check

func supportReason() -> String? {
    #if !arch(arm64)
    return "Apple Silicon (arm64) required"
    #else
    let v = ProcessInfo.processInfo.operatingSystemVersion
    if v.majorVersion < 14 { return "macOS 14 or later required" }
    return nil
    #endif
}

func runCheck(_ a: Args) -> Never {
    let reason = supportReason()
    var report: [String: Any] = ["supported": reason == nil, "reason": reason ?? "ok"]
    // Only reported when asked about a folder, so a bare `check` stays a pure host check.
    if let dir = a.modelsDir { report["models_present"] = modelsPresent(dir) }
    emit(report)
    exit(reason == nil ? 0 : Exit.unsupported.rawValue)
}

// MARK: - Model presence

func repoURL(_ modelsDir: String) -> URL {
    URL(fileURLWithPath: modelsDir, isDirectory: true).appendingPathComponent(repoFolder, isDirectory: true)
}

func directorySize(_ url: URL) -> Int64 {
    guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
    else { return 0 }
    var total: Int64 = 0
    for case let f as URL in e {
        let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        if v?.isRegularFile == true { total += Int64(v?.fileSize ?? 0) }
    }
    return total
}

/// True when every required entry exists and no interrupted `.partial` download is left.
/// The library re-validates on load; this is the cheap pre-check.
func modelsPresent(_ modelsDir: String) -> Bool {
    let repo = repoURL(modelsDir)
    let fm = FileManager.default
    for name in ModelNames.OfflineDiarizer.requiredModels.sorted() {
        if !fm.fileExists(atPath: repo.appendingPathComponent(name).path) { return false }
    }
    if let e = fm.enumerator(at: repo, includingPropertiesForKeys: nil) {
        for case let f as URL in e where f.pathExtension == "partial" { return false }
    }
    return true
}

// MARK: - prepare

/// Keeps the fraction monotonic (the library loads two model groups, each restarting at 0)
/// and drops events that neither advance by 1% nor change the phase label.
final class ProgressState: @unchecked Sendable {
    private let lock = NSLock()
    private var maxFraction = 0.0
    private var lastEmitted = -1.0
    private var lastLabel = ""
    func next(_ f: Double, label: String) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        maxFraction = max(maxFraction, f)
        let phase = label.split(separator: " ").first.map(String.init) ?? label
        if maxFraction - lastEmitted < 0.01 && phase == lastLabel && maxFraction < 1 { return nil }
        lastEmitted = maxFraction
        lastLabel = phase
        return maxFraction
    }
}

func runPrepare(_ a: Args) async -> Never {
    guard let dir = a.modelsDir else { die(.badArgs, "prepare needs --models-dir") }
    if let r = supportReason() { die(.unsupported, r) }
    let dirURL = URL(fileURLWithPath: dir, isDirectory: true)
    if modelsPresent(dir) {
        emit(["event": "done", "models_dir": dir, "bytes": directorySize(repoURL(dir)), "cached": true])
        exit(0)
    }
    emit(["event": "progress", "fraction": 0.0, "file": "start"])
    let state = ProgressState()
    do {
        // Downloads from huggingface.co (FluidInference/speaker-diarization-coreml at the
        // pinned revision) into <dir>/speaker-diarization (repoFolder), then compiles/loads them.
        _ = try await OfflineDiarizerModels.load(
            from: dirURL,
            progressHandler: { p in
                let file: String
                switch p.phase {
                case .listing: file = "listing"
                case .downloading(let done, let total): file = "downloading \(done)/\(total)"
                case .compiling(let name): file = "compiling \(name)"
                }
                if let f = state.next(p.fractionCompleted, label: file) {
                    emit(["event": "progress", "fraction": f, "file": file])
                }
            })
    } catch {
        die(.downloadFailed, "model download failed: \(error.localizedDescription)")
    }
    emit(["event": "done", "models_dir": dir, "bytes": directorySize(repoURL(dir))])
    exit(0)
}

// MARK: - run

struct Seg {
    var raw: String
    var start: Double
    var end: Double
}

func postProcess(_ segs: [Seg], minTurn: Double, mergeGap: Double) -> [Seg] {
    // Drop turns shorter than minTurn, then sort by start time.
    let kept = segs.filter { $0.end - $0.start >= minTurn && $0.end > $0.start }
        .sorted { $0.start != $1.start ? $0.start < $1.start : $0.end < $1.end }
    // Merge consecutive segments of the same raw speaker when the gap is <= mergeGap.
    var merged: [Seg] = []
    for s in kept {
        if var last = merged.last, last.raw == s.raw, s.start - last.end <= mergeGap {
            last.end = max(last.end, s.end)
            merged[merged.count - 1] = last
        } else {
            merged.append(s)
        }
    }
    return merged
}

func runDiarize(_ a: Args) async -> Never {
    guard let dir = a.modelsDir else { die(.badArgs, "run needs --models-dir") }
    guard let input = a.input else { die(.badArgs, "run needs --input") }
    if let n = a.numSpeakers, let lo = a.minSpeakers, n < lo { die(.badArgs, "--num-speakers < --min-speakers") }
    if let lo = a.minSpeakers, let hi = a.maxSpeakers, lo > hi { die(.badArgs, "--min-speakers > --max-speakers") }
    if let r = supportReason() { die(.unsupported, r) }
    guard modelsPresent(dir) else { die(.modelsMissing, "models missing in \(dir); run `prepare` first") }

    let inputURL = URL(fileURLWithPath: input)
    let duration: Double
    do {
        let f = try AVAudioFile(forReading: inputURL)
        duration = Double(f.length) / f.processingFormat.sampleRate
    } catch {
        die(.inputUnreadable, "cannot read \(input): \(error.localizedDescription)")
    }

    // Run mode never touches the network: a missing/corrupt cache throws instead of downloading.
    // Only `prepare` may download; a meeting recording must not trigger a surprise fetch.
    ModelHub.offlineMode = true

    var config = OfflineDiarizerConfig()
    if let t = a.threshold { config.clustering.threshold = t }
    config.clustering.numSpeakers = a.numSpeakers
    config.clustering.minSpeakers = a.minSpeakers
    config.clustering.maxSpeakers = a.maxSpeakers

    emit(["event": "progress", "phase": "loading"], toStderr: true)
    let t0 = Date()
    let manager = OfflineDiarizerManager(config: config)
    do {
        try await manager.prepareModels(directory: URL(fileURLWithPath: dir, isDirectory: true))
    } catch {
        die(.modelsMissing, "cannot load models from \(dir): \(error.localizedDescription)")
    }
    let loadS = Date().timeIntervalSince(t0)

    emit(["event": "progress", "phase": "diarizing"], toStderr: true)
    let t1 = Date()
    let result: DiarizationResult
    do {
        result = try await manager.process(inputURL)
    } catch OfflineDiarizationError.noSpeechDetected {
        result = DiarizationResult(segments: [])
    } catch {
        die(.failed, "diarization failed: \(error.localizedDescription)")
    }
    let processS = Date().timeIntervalSince(t1)

    let raw = result.segments.map {
        Seg(raw: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
    }
    let turns = postProcess(raw, minTurn: a.minTurn, mergeGap: a.mergeGap)

    // Renumber speakers S1, S2, ... by first appearance so ids are stable and readable,
    // and round times to milliseconds.
    var ids: [String: Int] = [:]
    var seconds: [Int: Double] = [:]
    var outTurns: [[String: Any]] = []
    for t in turns {
        let n = ids[t.raw] ?? { let k = ids.count + 1; ids[t.raw] = k; return k }()
        seconds[n, default: 0] += t.end - t.start
        outTurns.append(["speaker": "S\(n)", "start": dec3(t.start), "end": dec3(t.end)])
    }
    let speakers: [[String: Any]] = ids.values.sorted().map {
        ["id": "S\($0)", "label": "Speaker \($0)", "seconds": dec3(seconds[$0] ?? 0)]
    }

    func orNull(_ v: Any?) -> Any { v ?? NSNull() }
    let options: [String: Any] = [
        "num_speakers": orNull(a.numSpeakers),
        "min_speakers": orNull(a.minSpeakers),
        "max_speakers": orNull(a.maxSpeakers),
        "threshold": dec3(config.clustering.threshold),
        "min_turn": dec3(a.minTurn),
        "merge_gap": dec3(a.mergeGap),
        "unsupported": [String](),
    ]
    let out: [String: Any] = [
        "schema": 1,
        "engine": "fluidaudio",
        "engine_version": engineVersion,
        "duration": dec3(duration),
        "options": options,
        "speakers": speakers,
        "turns": outTurns,
        "timing": ["load_s": dec3(loadS), "process_s": dec3(processS)],
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) else {
        die(.failed, "could not encode result")
    }
    if let o = a.output {
        do { try data.write(to: URL(fileURLWithPath: o)) } catch { die(.failed, "cannot write \(o): \(error.localizedDescription)") }
    } else {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
    exit(0)
}

// MARK: - main

let parsed = parseArgs(CommandLine.arguments)
switch parsed.command {
case "check": runCheck(parsed)
case "prepare": await runPrepare(parsed)
case "run": await runDiarize(parsed)
default: die(.badArgs, "unknown command \(parsed.command) (prepare | run | check)")
}
