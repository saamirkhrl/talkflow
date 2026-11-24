import Foundation

/// One whisper segment of a notes piece. Times are seconds relative to the piece.
struct WhisperSegment: Equatable {
    var start: Double
    var end: Double
    var text: String
    /// Merged from whisper's tokens, relative to the piece. Empty = no word times.
    var words: [TimedWord]
    var avgLogprob: Double?
    var noSpeechProb: Double?
}

enum NotesModelChoice {
    /// large-v3-turbo-q5_0 when it is complete on disk, else the live engine's model.
    static func model() -> URL {
        FinalPassEngine.modelIsComplete ? FinalPassEngine.modelPath : SpeechEngine.liveModelPath
    }

    static func isTurbo(_ model: URL) -> Bool {
        model.lastPathComponent.contains("large-v3-turbo")
    }
}

/// A private whisper-server for the note taker, so the live engine (8178) and the final pass (8179) are never
/// touched or kept busy. Transcription spike RESULTS.md 7: 8192 is free in the app.
final class NotesEngine {
    static let defaultPort = 8192
    /// The port the test modes (--notespipeline, --fakemeeting) use. They never share the app's port or its command
    /// line, so neither one's leftover cleanup can end the other's server.
    static let testPort = 8193

    private let binary: String
    private let model: URL
    private let port: Int
    private let lock = NSLock()
    private var process: Process?

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    init(binary: String, model: URL, port: Int = NotesEngine.defaultPort) {
        self.binary = binary
        self.model = model
        self.port = port
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return process?.isRunning ?? false
    }

    private var baseURL: String { "http://127.0.0.1:\(port)" }

    /// Blocking; call off the main thread.
    func start(timeout: TimeInterval = 60) throws {
        killLeftover()
        if healthStatus() != nil {
            throw EngineError("Port \(port) is already in use by something else.")
        }
        let server = Process()
        server.executableURL = URL(fileURLWithPath: binary)
        server.arguments = ["-m", model.path, "--host", "127.0.0.1", "--port", String(port), "-nt"]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        lock.lock(); process = server; lock.unlock()

        let started = Date()
        while true {
            if !server.isRunning {
                lock.lock(); if process === server { process = nil }; lock.unlock()
                throw EngineError("The notes engine stopped while starting.")
            }
            if healthStatus() == 200 { break }
            if Date().timeIntervalSince(started) > timeout {
                stop()
                throw EngineError("The notes engine did not answer within \(Int(timeout))s.")
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        print("talkflowd: notes engine: ready on port \(port) in \(String(format: "%.2f", Date().timeIntervalSince(started)))s, model \(model.lastPathComponent)")
    }

    /// Idempotent, any thread.
    func stop() {
        lock.lock()
        let server = process
        process = nil
        lock.unlock()
        if let server, server.isRunning {
            server.terminate()
            let deadline = Date().addingTimeInterval(3)
            while server.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if server.isRunning { kill(server.processIdentifier, SIGKILL) }
        }
        killLeftover()
    }

    /// Ends a leftover of this exact server, matched by model path and port so nothing else is touched.
    private func killLeftover() {
        let killer = Process()
        killer.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        // Ends with " -nt" so port 8192 never matches 81920.
        killer.arguments = ["-f", "\(model.path) --host 127.0.0.1 --port \(port) -nt"]
        killer.standardOutput = FileHandle.nullDevice
        killer.standardError = FileHandle.nullDevice
        try? killer.run()
        killer.waitUntilExit()
    }

    /// The HTTP status of GET /health, or nil when nothing answers.
    private func healthStatus() -> Int? {
        var request = URLRequest(url: URL(string: "\(baseURL)/health")!)
        request.timeoutInterval = 0.5
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let box = ReplyBox()
        let done = DispatchSemaphore(value: 0)
        let task = Self.session.dataTask(with: request) { _, response, _ in
            box.status = (response as? HTTPURLResponse)?.statusCode
            done.signal()
        }
        task.resume()
        if done.wait(timeout: .now() + 2) == .timedOut { task.cancel(); return nil }
        return box.status
    }

    /// One request, blocking; call off the main thread.
    func transcribe(
        wav: Data, prompt: String, language: String, temperature: Double? = nil, timeout: TimeInterval
    ) throws -> [WhisperSegment] {
        let boundary = "talkflow-\(UUID().uuidString)"
        var body = Data()
        func append(_ string: String) { body.append(contentsOf: Array(string.utf8)) }
        func field(_ name: String, _ value: String) {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"piece.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        body.append(wav)
        append("\r\n")
        field("response_format", "verbose_json")
        field("no_timestamps", "false")
        field("no_language_probabilities", "true")
        field("language", language)
        if !prompt.isEmpty { field("prompt", prompt) }
        if let temperature {
            field("temperature", String(temperature))
            field("temperature_inc", "0")
        }
        append("--\(boundary)--\r\n")

        var request = URLRequest(url: URL(string: "\(baseURL)/inference")!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.httpBody = body

        let started = Date()
        let box = ReplyBox()
        let done = DispatchSemaphore(value: 0)
        let task = Self.session.dataTask(with: request) { data, response, error in
            box.data = data
            box.status = (response as? HTTPURLResponse)?.statusCode
            box.error = error
            done.signal()
        }
        task.resume()
        if done.wait(timeout: .now() + timeout + 5) == .timedOut {
            task.cancel()
            throw EngineError("The notes engine timed out after \(Int(timeout))s.")
        }
        let elapsed = String(format: "%.2f", Date().timeIntervalSince(started))
        if let error = box.error {
            throw EngineError("The notes engine request failed: \((error as? URLError).map { "URL error \($0.code.rawValue)" } ?? "error")")
        }
        guard box.status == 200 else {
            throw EngineError("The notes engine answered HTTP \(box.status ?? -1).")
        }
        guard let data = box.data, let segments = WhisperReply.parse(data) else {
            throw EngineError("The notes engine reply could not be read.")
        }
        print("talkflowd: notes engine: \(segments.count) segments from \(max(0, wav.count - 44) / 32000)s of audio in \(elapsed)s on port \(port)")
        return segments
    }
}

private final class ReplyBox: @unchecked Sendable {
    var data: Data?
    var status: Int?
    var error: Error?
}

enum WhisperReply {
    /// Parses verbose_json. whisper-server's "words" are tokens: a token starting with a space (or the first)
    /// begins a word, others append to the previous one. Nil when the JSON is not a reply with a segments array.
    static func parse(_ data: Data) -> [WhisperSegment]? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let raw = root["segments"] as? [[String: Any]] else { return nil }
        func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
        return raw.map { item in
            var segment = WhisperSegment(
                start: number(item["start"]) ?? 0, end: number(item["end"]) ?? 0,
                text: (item["text"] as? String) ?? "", words: [],
                avgLogprob: number(item["avg_logprob"]), noSpeechProb: number(item["no_speech_prob"]))
            guard let tokens = item["words"] as? [[String: Any]] else { return segment }
            var words: [TimedWord] = []
            var timed = true
            for token in tokens {
                guard let piece = token["word"] as? String else { continue }
                let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                guard let start = number(token["start"]), let end = number(token["end"]) else { timed = false; continue }
                if words.isEmpty || piece.hasPrefix(" ") {
                    words.append(TimedWord(text: trimmed, start: start, end: end))
                } else {
                    words[words.count - 1].text += trimmed
                    // A trailing "..." or "," token carries whisper's stretched end time (measured on the fake
                    // meeting: "and..." ran 8 s into the noise after it), so only tokens with letters or digits
                    // move the word's end.
                    if trimmed.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) {
                        words[words.count - 1].end = end
                    }
                }
            }
            // Tokens without times: the echo rule spreads the words uniformly instead.
            segment.words = timed ? words : []
            return segment
        }
    }
}

enum WavData {
    /// 16 kHz mono 16-bit PCM WAV with a 44-byte canonical header for the samples.
    static func make(_ samples: ArraySlice<Int16>, sampleRate: Int = 16000) -> Data {
        let dataSize = samples.count * 2
        var d = Data(capacity: 44 + dataSize)
        func u32(_ v: Int) { var x = UInt32(truncatingIfNeeded: v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { var x = UInt16(truncatingIfNeeded: v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataSize)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataSize)
        for s in samples { u16(Int(UInt16(bitPattern: s))) }
        return d
    }
}
