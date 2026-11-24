import Foundation

enum SpeakerError: Error, Equatable {
    case unsupported, modelsMissing, failed(Int32), cancelled, timedOut
}

/// The speaker helper (Contents/Helpers/talkflow-diarize): where it lives, whether it can run
/// here, and how its output is read. The helper's contract is in Helpers/talkflow-diarize.
enum SpeakerHelper {
    /// Diarization spike RESULTS.md: the FluidAudio default, the right speaker count on all four fixtures.
    static let threshold = 0.6
    /// Same file: fewer cuts for the transcriber, cosmetic for the error rate.
    static let mergeGap = 0.5

    /// Contents/Helpers/talkflow-diarize inside the running app, if executable; nil otherwise
    /// (dev builds, command line runs).
    static func bundledBinary() -> URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/talkflow-diarize")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// <talkflow models folder>/diarization (the helper keeps its files in a speaker-diarization
    /// subfolder there).
    static var modelsFolder: URL {
        SpeechEngine.modelPath.deletingLastPathComponent().appendingPathComponent("diarization", isDirectory: true)
    }

    /// nil when the helper can be tried; else a short category for logs: "intel", "macos13", "missing".
    static func unavailableReason(binary: URL?) -> String? {
        #if !arch(arm64)
        return "intel"
        #else
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 14 { return "macos13" }
        guard let binary, FileManager.default.isExecutableFile(atPath: binary.path) else { return "missing" }
        return nil
        #endif
    }

    /// Arguments that download the models (the only command that uses the network). Nothing calls
    /// this yet; a later settings screen will.
    static func prepareArguments(modelsDir: URL) -> [String] {
        ["prepare", "--models-dir", modelsDir.path]
    }

    /// The turns of a helper result (schema 1); nil when it is not one.
    static func parseRun(_ data: Data) -> [SpeakerSegment]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["schema"] as? Int) == 1,
              let turns = object["turns"] as? [[String: Any]] else { return nil }
        var out: [SpeakerSegment] = []
        for t in turns {
            guard let speaker = t["speaker"] as? String,
                  let start = (t["start"] as? NSNumber)?.doubleValue,
                  let end = (t["end"] as? NSNumber)?.doubleValue,
                  start.isFinite, end.isFinite else { return nil }
            out.append(SpeakerSegment(speaker: speaker, start: start, end: end))
        }
        return out
    }

    /// The phase of a helper progress line on stderr; nil for anything else (the library also
    /// prints plain "[Profiling]" lines).
    static func parseProgress(_ line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["event"] as? String) == "progress",
              let phase = object["phase"] as? String else { return nil }
        return phase
    }
}

/// One helper run as a child process. `run` blocks; `cancel` may be called from any thread and
/// terminates the child.
final class SpeakerRun: @unchecked Sendable {
    private let binary: URL
    private let modelsDir: URL
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    init(binary: URL, modelsDir: URL) {
        self.binary = binary
        self.modelsDir = modelsDir
    }

    /// Runs the helper on a wav file and returns its turns as given (overlapping allowed).
    /// Exit 3 is `.modelsMissing`, 6 `.unsupported`, any other non-zero `.failed(code)`; a run
    /// longer than max(120, 0.5 * audio seconds) is terminated and is `.timedOut`.
    func run(wav: URL, audioSeconds: Double, onPhase: @escaping (String) -> Void = { _ in }) throws -> [SpeakerSegment] {
        let output = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("talkflow-speakers-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }

        let p = Process()
        p.executableURL = binary
        p.arguments = ["run", "--models-dir", modelsDir.path, "--input", wav.path, "--output", output.path,
                       "--threshold", "\(SpeakerHelper.threshold)", "--merge-gap", "\(SpeakerHelper.mergeGap)"]
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice

        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }

        let pending = LineBuffer(onLine: { line in
            if let phase = SpeakerHelper.parseProgress(line) { onPhase(phase) }
        })
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                pending.append(data)
            }
        }

        lock.lock()
        if cancelled {
            lock.unlock()
            throw SpeakerError.cancelled
        }
        do {
            try p.run()
        } catch {
            lock.unlock()
            errPipe.fileHandleForReading.readabilityHandler = nil
            print("talkflowd: speakers: could not start the helper")
            throw SpeakerError.failed(-1)
        }
        process = p
        lock.unlock()

        let started = Date()
        let limit = max(120.0, 0.5 * audioSeconds)
        var timedOut = false
        if done.wait(timeout: .now() + limit) == .timedOut {
            timedOut = true
            p.terminate()
            if done.wait(timeout: .now() + 5) == .timedOut { kill(p.processIdentifier, SIGKILL); done.wait() }
        }
        errPipe.fileHandleForReading.readabilityHandler = nil
        if let rest = try? errPipe.fileHandleForReading.readToEnd(), !rest.isEmpty { pending.append(rest) }
        pending.flush()

        lock.lock()
        process = nil
        let wasCancelled = cancelled
        lock.unlock()

        let seconds = Date().timeIntervalSince(started)
        let status = p.terminationStatus
        if wasCancelled {
            print("talkflowd: speakers: cancelled after \(String(format: "%.1f", seconds)) s")
            throw SpeakerError.cancelled
        }
        if timedOut {
            print("talkflowd: speakers: timed out after \(String(format: "%.0f", seconds)) s")
            throw SpeakerError.timedOut
        }
        guard status == 0 else {
            print("talkflowd: speakers: helper exit \(status) after \(String(format: "%.1f", seconds)) s")
            switch status {
            case 3: throw SpeakerError.modelsMissing
            case 6: throw SpeakerError.unsupported
            default: throw SpeakerError.failed(status)
            }
        }
        guard let data = try? Data(contentsOf: output), let turns = SpeakerHelper.parseRun(data) else {
            print("talkflowd: speakers: helper output unreadable")
            throw SpeakerError.failed(0)
        }
        print("talkflowd: speakers: \(turns.count) turns in \(String(format: "%.1f", seconds)) s")
        return turns
    }

    /// Terminates the helper if it is running; a run not yet started will not start.
    func cancel() {
        lock.lock()
        cancelled = true
        let p = process
        lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }
}

/// Splits a stream of stderr bytes into lines.
private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let onLine: (String) -> Void

    init(onLine: @escaping (String) -> Void) { self.onLine = onLine }

    func append(_ data: Data) {
        var lines: [String] = []
        lock.lock()
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            lines.append(String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        lock.unlock()
        lines.forEach(onLine)
    }

    func flush() {
        lock.lock()
        let rest = buffer
        buffer = Data()
        lock.unlock()
        if !rest.isEmpty { onLine(String(decoding: rest, as: UTF8.self)) }
    }
}
