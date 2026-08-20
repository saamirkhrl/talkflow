import AVFoundation
import Foundation

/// `talkflowd --rectest [seconds]` - captures live mic audio through the real
/// Recorder, checks the WAV it produces, and transcribes it.
///
/// Recorder is the piece everything else depends on and the piece that was
/// silently broken the longest: for its entire history it wrote WAVs whose
/// `data` chunk length was never filled in, so every transcription read zero
/// samples and came back "[BLANK_AUDIO]". Nothing in the app noticed, because a
/// well-formed request for an empty recording looks exactly like silence. This
/// exercises the real capture path and asserts on the bytes.
enum RecordSelfTest {
    static func run(seconds: Double) -> Never {
        let recorder = Recorder()
        var peakLevel: Float = 0
        recorder.onLevel = { peakLevel = max(peakLevel, $0) }

        do {
            try recorder.start()
        } catch {
            report("FAIL could not start capture: \(error.localizedDescription)")
            exit(1)
        }
        report("recording \(seconds)s from the default input...")
        Thread.sleep(forTimeInterval: seconds)
        let wav = recorder.stop()

        var failures = 0
        func check(_ condition: Bool, _ label: String, _ detail: String = "") {
            report((condition ? "ok   " : "FAIL ") + label + (detail.isEmpty ? "" : " -> " + detail))
            if !condition { failures += 1 }
        }

        let bytes = [UInt8](wav)
        func u32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
        }

        check(bytes.count > 44, "produced audio beyond the header", "\(bytes.count) bytes")
        guard bytes.count > 44 else { exit(1) }

        let declaredData = u32(40)
        let actualData = UInt32(bytes.count - 44)
        check(String(bytes: bytes[36..<40], encoding: .ascii) == "data", "data chunk marker")
        check(declaredData == actualData, "data chunk length is filled in", "declared \(declaredData), actual \(actualData)")
        check(u32(4) == UInt32(bytes.count - 8), "RIFF length is filled in")

        let expectedSamples = Int(seconds * 16000)
        let actualSamples = Int(actualData) / 2
        let ratio = Double(actualSamples) / Double(expectedSamples)
        check(ratio > 0.8 && ratio < 1.2, "captured about the right amount of audio",
              String(format: "%.2fs of %.2fs requested", Double(actualSamples) / 16000, seconds))

        // Silence would still be a valid WAV, so confirm the samples aren't all
        // zero - that would mean the tap ran but wrote nothing real.
        var nonZero = 0
        var index = 44
        while index + 1 < bytes.count {
            if bytes[index] != 0 || bytes[index + 1] != 0 { nonZero += 1 }
            index += 2
        }
        check(nonZero > actualSamples / 10, "samples contain real signal",
              "\(nonZero)/\(actualSamples) non-zero, peak level \(String(format: "%.3f", peakLevel))")

        // Every assertion above runs on the bytes in memory, so the file is not
        // needed to verify anything - it exists only for a human to listen to
        // when the microphone itself is the suspect. That is rare, and leaving a
        // recording of the user in $TMPDIR after every run is not the default
        // worth having. Opt in with TALKFLOW_KEEP_TEST_AUDIO=1.
        if ProcessInfo.processInfo.environment["TALKFLOW_KEEP_TEST_AUDIO"] == "1" {
            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("talkflow-rectest.wav")
            try? wav.write(to: url)
            report("wrote \(url.path)")
        } else {
            report("audio not written to disk (TALKFLOW_KEEP_TEST_AUDIO=1 to keep it)")
        }

        let done = DispatchSemaphore(value: 0)
        Transcriber.transcribe(wav: wav, serverURL: URL(string: "http://127.0.0.1:8178/inference")!) { result in
            if let result {
                // Same rule as the live path: the log records the shape, not the
                // words. See Dictation.logTranscripts.
                let detail = Dictation.logTranscripts ? ": \(result.text)" : ""
                report("transcribed \(Dictation.shape(of: result.text)) in \(String(format: "%.2f", result.elapsed))s\(detail)")
            } else {
                report("FAIL transcription request failed")
                failures += 1
            }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 30)

        report(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
        exit(failures == 0 ? 0 : 1)
    }

    /// stdout is redirected into the app log at launch, so results go to a file
    /// the caller can actually read.
    private static func report(_ line: String) {
        print("talkflowd: [rectest] \(line)")
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("talkflow-rectest.log")
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
