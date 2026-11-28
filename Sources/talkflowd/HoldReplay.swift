import Foundation

/// `--holdreplay <wav> <holdSeconds> <port> <out.json> [<largePort>]`: replays a WAV through
/// HoldSession against a whisper-server the caller started (LONG-HOLD-SPEC.md C1).
///
/// Audio is revealed in real time, as the mic would. Reads no Preferences, Keychain or mic and
/// never uses port 8178.
enum HoldReplay {
    /// The WAV's samples, revealed as wall-clock time passes.
    private final class FileAudioSource: HoldAudioSource {
        let all: [Int16]
        let startedAt = Date()
        init(all: [Int16]) { self.all = all }
        var sampleCount: Int {
            min(all.count, Int(Date().timeIntervalSince(startedAt) * 16000))
        }
        func samples(from start: Int, to end: Int) -> [Int16] {
            let low = max(0, min(start, sampleCount))
            let high = max(0, min(end, sampleCount))
            return high > low ? Array(all[low..<high]) : []
        }
    }

    private final class AlwaysReadyGate: EngineGate {
        var isReady: Bool { true }
        func whenReady(timeout: TimeInterval, _ done: @escaping (Bool) -> Void) { done(true) }
        func requestFailed() {}
    }

    // Held for the life of the process, which ends in dispatchMain().
    private static var session: HoldSession?
    private static var timer: DispatchSourceTimer?

    private static func fail(_ message: String) -> Never {
        print("holdreplay: \(message)")
        exit(2)
    }

    static func run(_ args: [String]) -> Never {
        guard args.count >= 4, let hold = Double(args[1]), hold > 0, let port = Int(args[2]) else {
            fail("usage: --holdreplay <wav> <holdSeconds> <port> <out.json> [<largePort>]")
        }
        let wavPath = args[0]
        let outPath = args[3]
        let largePort = args.count >= 5 ? Int(args[4]) : nil
        guard port != 8178, largePort != 8178 else { fail("port 8178 is the app's live engine and is never used here") }
        guard let samples = readSamples(path: wavPath) else { exit(2) }

        let source = FileAudioSource(all: samples)
        var config = HoldSession.Config(smallURL: URL(string: "http://127.0.0.1:\(port)/inference")!)
        if let largePort { config.largeURL = URL(string: "http://127.0.0.1:\(largePort)/inference") }
        let session = HoldSession(source: source, config: config, engine: AlwaysReadyGate(),
                                  prompt: { Transcriber.vocabularyPrompt })
        session.largeReady = { largePort != nil }
        // The slow-pass counter would read and write Preferences.
        session.recordPassSpeed = { _, _ in }
        self.session = session

        let startedAt = source.startedAt
        func elapsed() -> Double { Date().timeIntervalSince(startedAt) }

        var requests: [[String: Any]] = []
        var settles: [[String: Any]] = []
        var hypotheses = 0
        session.onRequest = { log in
            requests.append([
                "kind": log.kind.rawValue,
                "audio_s": round3(log.audioSeconds),
                "latency_s": round3(log.latency),
                "ok": log.ok,
                "t": round3(max(0, elapsed() - log.latency)),
            ])
        }
        session.onSettle = { _, reason in settles.append(["at_s": round3(elapsed()), "reason": reason]) }
        session.onHypothesis = { _, _ in hypotheses += 1 }

        let ticker = DispatchSource.makeTimerSource(queue: .main)
        ticker.schedule(deadline: .now() + 0.7, repeating: 0.7)
        ticker.setEventHandler { session.tick() }
        timer = ticker
        ticker.resume()

        DispatchQueue.main.asyncAfter(deadline: .now() + hold) {
            ticker.cancel()
            timer = nil
            let finishStart = Date()
            session.finish(route: largePort == nil ? .small : .large) { result, usedLarge in
                let latency = Date().timeIntervalSince(finishStart)
                let text = result?.text ?? ""
                let report: [String: Any] = [
                    "hold": hold,
                    "requests": requests,
                    "hypotheses": hypotheses,
                    "final": [
                        "latency_s": round3(latency),
                        "ok": result != nil,
                        "text": text,
                        "used_large": usedLarge,
                    ] as [String: Any],
                    "settles": settles,
                ]
                do {
                    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    try data.write(to: URL(fileURLWithPath: outPath))
                } catch {
                    fail("could not write \(outPath): \(error.localizedDescription)")
                }
                let ticks = requests.filter { $0["kind"] as? String == "tick" }
                let maxTick = ticks.compactMap { $0["latency_s"] as? Double }.max() ?? 0
                print("holdreplay: \(ticks.count) ticks, \(settles.count) settles, max tick latency \(round3(maxTick))s, final \(round3(latency))s ok=\(result != nil), \(text.count) chars")
                exit(0)
            }
        }
        dispatchMain()
    }

    private static func round3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }

    /// 16 kHz mono 16-bit PCM only; anything else fails clearly.
    private static func readSamples(path: String) -> [Int16]? {
        guard let data = FileManager.default.contents(atPath: path) else {
            print("holdreplay: cannot read \(path)")
            return nil
        }
        let bytes = [UInt8](data)
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        guard bytes.count >= 12, String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: bytes[8..<12], as: UTF8.self) == "WAVE" else {
            print("holdreplay: \(path) is not a RIFF/WAVE file")
            return nil
        }
        var offset = 12
        var formatOK = false
        while offset + 8 <= bytes.count {
            let id = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
            let size = u32(offset + 4)
            let body = offset + 8
            if id == "fmt " && body + 16 <= bytes.count {
                let format = u16(body), channels = u16(body + 2), rate = u32(body + 4), bits = u16(body + 14)
                guard format == 1, channels == 1, rate == 16000, bits == 16 else {
                    print("holdreplay: need 16 kHz mono 16-bit PCM, got format \(format), \(channels) ch, \(rate) Hz, \(bits) bit")
                    return nil
                }
                formatOK = true
            } else if id == "data" {
                guard formatOK else { print("holdreplay: data chunk before fmt chunk"); return nil }
                let end = min(bytes.count, body + size)
                var out: [Int16] = []
                out.reserveCapacity((end - body) / 2)
                var i = body
                while i + 1 < end {
                    out.append(Int16(bitPattern: UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8))
                    i += 2
                }
                return out
            }
            offset = body + size + (size & 1)
        }
        print("holdreplay: no data chunk in \(path)")
        return nil
    }
}
