import AppKit
import Foundation

/// `--enginereplay`: the live engine's idle stop and cold start, on a private server (LONG-HOLD-SPEC.md C2).
///
/// `--enginereplay <binary> <model> <port> <idleSeconds> <wav> <out.json> [launchd <label> <plist>]`
/// Never touches port 8178 or the real LaunchAgent; refuses both. No mic, no permissions.
enum EngineReplay {
    private static var steps: [[String: Any]] = []
    private static var allPassed = true
    private static let started = Date()

    private static func elapsed() -> Double { (Date().timeIntervalSince(started) * 100).rounded() / 100 }
    private static func rounded(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }

    private static func record(_ name: String, _ pass: Bool, _ detail: [String: Any] = [:]) {
        var row = detail
        row["step"] = name
        row["pass"] = pass
        row["t"] = elapsed()
        steps.append(row)
        if !pass { allPassed = false }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("enginereplay: \(message)\n".utf8))
        print("enginereplay: \(message)")
        exit(2)
    }

    /// 16 kHz mono Int16 samples of a WAV file, or nil.
    private static func samples(ofWav data: Data) -> [Int16]? {
        let bytes = [UInt8](data)
        guard bytes.count > 44, String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF" else { return nil }
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        var index = 12
        var format: (channels: Int, rate: Int, bits: Int, code: Int)?
        while index + 8 <= bytes.count {
            let id = String(decoding: bytes[index..<index + 4], as: UTF8.self)
            let size = u32(index + 4)
            let body = index + 8
            if id == "fmt ", body + 16 <= bytes.count {
                format = (u16(body + 2), u32(body + 4), u16(body + 14), u16(body))
            } else if id == "data" {
                guard let f = format, f.channels == 1, f.rate == 16000, f.bits == 16, f.code == 1 else { return nil }
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
            index = body + size + (size & 1)
        }
        return nil
    }

    static func run(_ args: [String]) -> Never {
        guard args.count >= 6, let port = Int(args[2]), let idle = Double(args[3]), idle > 0 else {
            fail("usage: --enginereplay <binary> <model> <port> <idleSeconds> <wav> <out.json> [launchd <label> <plist>]")
        }
        let binary = args[0], model = args[1], wavPath = args[4], outPath = args[5]
        guard port != SpeechEngine.port, port != FinalPassEngine.port else { fail("refusing port \(port)") }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: wavPath)), let all = samples(ofWav: data), all.count >= 16000 else {
            fail("\(wavPath) is not a 16 kHz mono 16-bit WAV of at least one second")
        }

        var launchdLabel: String?
        let backend: EngineBackend
        if args.count >= 9, args[6] == "launchd" {
            let label = args[7]
            guard label != SpeechEngine.agentLabel else { fail("refusing the real engine's label") }
            let plistURL = URL(fileURLWithPath: args[8])
            let log = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("talkflow-enginereplay-\(port).log").path
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": SpeechEngine.agentArguments(binary: binary, model: model, port: port),
                "RunAtLoad": false,
                "KeepAlive": false,
                "StandardOutPath": log,
                "StandardErrorPath": log
            ]
            guard let plistData = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
                  (try? plistData.write(to: plistURL, options: .atomic)) != nil else { fail("could not write \(plistURL.path)") }
            // A leftover of an earlier run of this harness, under this label only.
            _ = SpeechEngine.runCapturing("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
            launchdLabel = label
            backend = LaunchAgentBackend(label: label, plistURL: plistURL, port: port)
        } else {
            backend = ProcessBackend(binary: binary, model: model, port: port)
        }

        let engine = LiveEngine(backend: backend, idleTimeout: idle)
        let clip8 = Recorder.wav(from: Array(all.prefix(16000 * 8)), sampleRate: 16000)
        let clip3 = Recorder.wav(from: Array(all.prefix(16000 * 3)), sampleRate: 16000)
        let url = URL(string: "http://127.0.0.1:\(port)/inference")!

        func main<T>(_ body: () -> T) -> T { DispatchQueue.main.sync(execute: body) }
        func state() -> EngineLifecycle.State { main { engine.state } }
        func waitFor(_ timeout: TimeInterval, _ cond: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if cond() { return true }
                Thread.sleep(forTimeInterval: 0.005)
            }
            return cond()
        }
        /// Waits for ready through the gate (as a hold does), then sends the clip once. Returns the latency.
        func transcribe(_ clip: Data) -> (ok: Bool, latency: Double, text: String) {
            let readyBox = DispatchSemaphore(value: 0)
            var ready = false
            DispatchQueue.main.async { engine.whenReady(timeout: 15) { ready = $0; readyBox.signal() } }
            readyBox.wait()
            guard ready else { return (false, 0, "") }
            let done = DispatchSemaphore(value: 0)
            var result: Transcriber.Result?
            Transcriber.transcribe(wav: clip, serverURL: url, timeout: 30) { result = $0; done.signal() }
            done.wait()
            return (result != nil, rounded(result?.elapsed ?? 0), result?.text ?? "")
        }
        func acquire() -> EngineLease { main { engine.acquire("enginereplay") } }
        func release(_ lease: EngineLease) { main { lease.end() } }

        let scenario = Thread {
            var summary: [String: Any] = ["idle_seconds": idle, "backend": launchdLabel == nil ? "process" : "launchd"]

            main { engine.launch() }
            _ = waitFor(10) { state() != .unknown }

            // 1. Cold key-down on a stopped engine.
            let stoppedAtStart = !backend.isResponding() && !backend.isRunning()
            record("1a engine stopped before the first hold", stoppedAtStart && state() == .stopped, ["state": "\(state())"])
            let down = Date()
            let lease1 = acquire()
            let readyOK = waitFor(40) { state() == .ready }
            let coldStart = rounded(Date().timeIntervalSince(down))
            record("1b cold start to ready", readyOK, ["cold_start_to_ready_s": coldStart])
            summary["cold_start_to_ready_s"] = coldStart
            let first = transcribe(clip8)
            record("1c first transcription (single request instead of HoldSession)", first.ok,
                   ["latency_s": first.latency, "audio_s": 8.0, "chars": first.text.count])
            summary["first_transcription_latency_s"] = first.latency
            release(lease1)
            let released = Date()

            // 2. Idle stop.
            let stopped = waitFor(idle + 10) { state() == .stopped }
            let idleStop = rounded(Date().timeIntervalSince(released))
            let silent = !backend.isResponding() && !backend.isRunning()
            record("2 idle stop", stopped && silent && idleStop >= idle - 0.5,
                   ["idle_stop_s": idleStop, "port_silent_and_not_running": silent])
            summary["idle_stop_s"] = idleStop

            // 3. Key-down while stopping.
            let lease2 = acquire()
            let again = waitFor(40) { state() == .ready }
            record("3a cold start again from stopped", again, [:])
            release(lease2)
            let caught = waitFor(idle + 10) { state() == .stopping }
            let lease3 = acquire()
            let restarted = waitFor(40) { state() == .ready }
            let second = transcribe(clip3)
            record("3b acquire while stopping ends ready and a 3 s hold transcribes", caught && restarted && second.ok,
                   ["caught_stopping": caught, "ended_ready": restarted, "latency_s": second.latency])
            summary["restart_while_stopping"] = caught && restarted && second.ok
            summary["restart_while_stopping_latency_s"] = second.latency
            release(lease3)

            // 4. Wake after the idle time has run out in sleep.
            _ = waitFor(5) { state() == .ready }
            main {
                engine.testBackdateLastUse(by: idle + 5)
                engine.testWake()
            }
            let woke = waitFor(15) { state() == .stopped }
            let wakeSilent = !backend.isResponding() && !backend.isRunning()
            record("4 wake with an expired idle time stops it", woke && wakeSilent, ["port_silent_and_not_running": wakeSilent])
            summary["wake_stops"] = woke && wakeSilent

            // 5. Clean up.
            backend.stop()
            if !waitFor(3, { !backend.isRunning() }) { backend.kill(); _ = waitFor(1) { !backend.isRunning() } }
            if let label = launchdLabel {
                _ = SpeechEngine.runCapturing("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
                let gone = SpeechEngine.runCapturing("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"]).status != 0
                record("5a label booted out", gone, [:])
            }
            let clean = !backend.isResponding()
            record("5b nothing answers on the port", clean, [:])

            summary["all_passed"] = allPassed
            summary["steps"] = steps
            if let json = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]) {
                try? json.write(to: URL(fileURLWithPath: outPath))
            }
            exit(allPassed ? 0 : 1)
        }
        scenario.start()
        dispatchMain()
    }
}
