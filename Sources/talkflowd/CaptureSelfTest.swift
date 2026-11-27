import AVFoundation
import Foundation

/// `talkflowd --capturetest [seconds]`: records the microphone and this Mac's sound through the real MeetingRecorder
/// into a temporary folder, checks the files against the clock, reports levels, the timelines and the computer-audio
/// state, then deletes the audio. It never requests a permission: without the microphone permission it records the
/// computer audio only, and a missing System Audio Recording permission is a reported result, not a failure.
enum CaptureSelfTest {
    private static let logURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("talkflow-capturetest.log")

    static func run(seconds: Double) -> Never {
        try? FileManager.default.removeItem(at: logURL)
        var failures = 0
        func check(_ condition: Bool, _ label: String, _ detail: String = "") {
            report((condition ? "ok   " : "FAIL ") + label + (detail.isEmpty ? "" : " -> " + detail))
            if !condition { failures += 1 }
        }
        func finish() -> Never {
            report(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
            exit(failures == 0 ? 0 : 1)
        }

        report(String(format: "--- capturetest %g s ---", seconds))
        guard #available(macOS 14.2, *) else {
            report("SKIP computer audio needs macOS 14.2")
            report("ALL PASS")
            exit(0)
        }

        // Read only: asking for the status never shows a prompt.
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let micWord: String
        switch micStatus {
        case .authorized: micWord = "authorized"
        case .notDetermined: micWord = "notDetermined"
        case .denied: micWord = "denied"
        case .restricted: micWord = "restricted"
        @unknown default: micWord = "unknown"
        }
        report("microphone permission: \(micWord)")
        let includeMic = micStatus == .authorized
        if !includeMic { report("recording computer audio only (no microphone permission for this binary; nothing was requested)") }

        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("talkflow-capturetest-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            check(false, "temporary folder created", "\(type(of: error))")
            finish()
        }
        func cleanup() {
            try? FileManager.default.removeItem(at: folder)
            check(!FileManager.default.fileExists(atPath: folder.path), "audio deleted afterwards")
        }

        let rec = MeetingRecorder(includeMic: includeMic)
        let t0 = CaptureClock.nowSeconds()
        do {
            try rec.start(into: folder)
            check(true, "S1 recording starts")
        } catch {
            check(false, "S1 recording starts", "\(type(of: error))")
            cleanup()
            finish()
        }

        var maxYou = 0.0, maxOthers = 0.0
        var last = CaptureLevels()
        var transitions: [(Double, ComputerAudioStatus)] = []
        while CaptureClock.nowSeconds() - t0 < seconds {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let l = rec.levels()
            maxYou = max(maxYou, l.you)
            maxOthers = max(maxOthers, l.others)
            last = l
            if transitions.last?.1 != l.computerAudio { transitions.append((l.elapsed, l.computerAudio)) }
        }

        let s0 = CaptureClock.nowSeconds()
        let d = rec.stop()
        let stopTook = CaptureClock.nowSeconds() - s0
        let wall = s0 - t0
        check(stopTook < 3.0, "S2 stop returns within 3 s", String(format: "%.2f s", stopTook))
        report(String(format: "duration reported %.2f s, clock %.2f s", d, wall))
        report(String(format: "meters: you max %.2f, others max %.2f", maxYou, maxOthers))
        if let p = last.problem { report("problem shown: \(p)") }

        report("computer audio: " + transitions.map { String(format: "%@@%.1fs", $0.1.rawValue, $0.0) }.joined(separator: " -> "))

        // Each track: header, sample count against the clock, levels and timeline fit.
        func trackFit(_ timelineName: String, _ label: String) -> (fit: LineFit?, firstHost: Double?) {
            let text = (try? String(contentsOf: folder.appendingPathComponent(timelineName), encoding: .utf8)) ?? ""
            let segs = TimelineFit.segments(jsonl: text)
            if segs.isEmpty { report("\(label) timeline: 0 segments") }
            var first: LineFit?
            for (i, seg) in segs.enumerated() {
                guard let f = TimelineFit.fit(seg) else { continue }
                if first == nil { first = f }
                report(String(format: "%@ timeline: %d segments, segment %d: drift %+.1f ppm, max residual %.2f ms (%d points)",
                              label, segs.count, i + 1, (f.b - 1) * 1e6, f.maxResidual * 1000, f.count))
            }
            return (first, segs.first?.first?.host)
        }

        func levelsLine(_ url: URL, _ label: String) {
            let samples = WavSamples.read(url)
            var peak = 0
            var sum = 0.0
            for v in samples {
                let a = abs(Int(v))
                if a > peak { peak = a }
                sum += Double(v) * Double(v)
            }
            func db(_ x: Double) -> String { x > 0 ? String(format: "%.1f", 20 * log10(x)) : "-inf" }
            let rms = samples.isEmpty ? 0 : (sum / Double(samples.count)).squareRoot() / 32768
            report("\(label) levels: peak \(db(Double(peak) / 32768)) dBFS, RMS \(db(rms)) dBFS")
        }

        func samplesLine(_ samples: Int, expectedSeconds: Double, _ label: String) {
            let expected = expectedSeconds * 16000
            let deviation = expected > 0 ? (Double(samples) - expected) / expected : 1
            check(abs(deviation) < 0.03, label,
                  String(format: "%d samples = %.3f s vs %.3f s (%+.2f%%)", samples, Double(samples) / 16000, expectedSeconds, deviation * 100))
        }

        var youFit: LineFit?
        if includeMic {
            let url = folder.appendingPathComponent(CaptureFolder.mic)
            let (fit, firstHost) = trackFit(CaptureFolder.micTimeline, "you")
            youFit = fit
            if let info = WavInfo.read(url) {
                check(info.headerMatchesFile, "you header matches the file", "declared \(info.declaredDataBytes) bytes, file \(info.fileBytes - 44) bytes")
                let samples = (info.fileBytes - 44) / 2
                // The track starts with the mic's first buffer, after the engine has started, so (as for others) the
                // clock runs from the first chunk.
                let offset = firstHost.map { max(0, $0 - t0) } ?? 0
                report(String(format: "you first chunk %.3f s after start", offset))
                samplesLine(samples, expectedSeconds: wall - offset, "you samples match the clock")
            } else {
                check(false, "you header matches the file", "unreadable")
            }
            levelsLine(url, "you")
        }

        var othersFit: LineFit?
        do {
            let url = folder.appendingPathComponent(CaptureFolder.system)
            let (fit, firstHost) = trackFit(CaptureFolder.systemTimeline, "others")
            othersFit = fit
            if let info = WavInfo.read(url) {
                check(info.headerMatchesFile, "others header matches the file", "declared \(info.declaredDataBytes) bytes, file \(info.fileBytes - 44) bytes")
                let samples = (info.fileBytes - 44) / 2
                let ran: Set<ComputerAudioStatus> = [.receiving, .nothingPlaying, .notArriving]
                let callbacksRan = ran.contains(last.computerAudio) || samples > 0
                if callbacksRan {
                    // Counting starts when the tap starts, after the mic's first buffer, so the clock runs from the
                    // first system chunk.
                    let offset = firstHost.map { max(0, $0 - t0) } ?? 0
                    report(String(format: "others first chunk %.3f s after start", offset))
                    samplesLine(samples, expectedSeconds: wall - offset, "others samples match the clock")
                } else {
                    report("others: 0 samples (the tap delivered nothing)")
                    check(samples == 0, "others empty when nothing was delivered")
                }
            } else {
                check(false, "others header matches the file", "unreadable")
            }
            levelsLine(url, "others")
        }

        if let youFit, let othersFit {
            report(String(format: "others start %.1f ms after you", TimelineFit.offset(of: othersFit, on: youFit) * 1000))
        }

        let session = CaptureSessionInfo.read(from: folder)
        check(session != nil, "session.json written")
        if let session {
            let routes = session.routes.map { String(format: "%@@%.1fs", $0.route.rawValue, $0.atSeconds) }
            report("routes: \(routes.isEmpty ? "none" : routes.joined(separator: ", ")); mode \(session.systemAudioMode ?? "none")")
        }

        let state: String
        switch last.computerAudio {
        case .receiving: state = "ok"
        case .notAuthorised, .waitingForPermission: state = "not authorised"
        case .notArriving: state = "no computer audio"
        case .nothingPlaying: state = "nothing playing"
        case .starting: state = "undecided"
        }
        report("state: \(state)")

        cleanup()
        finish()
    }

    /// stdout is redirected into the app log at launch, so results also go to a file the caller can read.
    private static func report(_ line: String) {
        print("talkflowd: [capturetest] \(line)")
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }
}
