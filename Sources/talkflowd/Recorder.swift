import AVFoundation
import Foundation

/// Captures mic input into memory as 16kHz mono 16-bit PCM and hands back a
/// complete, valid WAV on demand.
///
/// This used to write through AVAudioFile. AVAudioFile only finalises a WAV's
/// header when the object is deallocated, and the transcriber read the file the
/// instant recording stopped - before ARC had released it. Every recording came
/// out with `data` chunk size 0x00000000, so whisper read zero samples and
/// returned "[BLANK_AUDIO]" no matter what had been said. The audio bytes were
/// always there; only the four-byte length was missing. Buffering in memory and
/// writing the header ourselves makes the result deterministic - there is no
/// finalisation step that can be racing anything.
final class Recorder {
    /// Replaced after a stop that hung (see `stop()`); otherwise kept for the
    /// life of the app.
    private var engine = AVAudioEngine()
    private let sampleRate: Double = 16000

    /// How long `stop()` waits for CoreAudio before giving up on it.
    static let stopTimeout: TimeInterval = 0.5

    /// Guards `samples`, which the audio tap appends to on a realtime thread
    /// while the main thread reads snapshots of it for the live preview.
    private let lock = NSLock()
    private var samples: [Int16] = []
    /// Bumped by every start and stop, under `lock`. A tap only appends while
    /// its own start is current, so an engine abandoned by `stop()` can't
    /// leak audio into the next hold.
    private var generation = 0

    /// Fires on a background thread with each buffer's RMS level (roughly 0...1)
    /// so the overlay can animate in step with the speaker's voice.
    var onLevel: ((Float) -> Void)?

    func start() throws {
        lock.lock(); samples = []; generation += 1; let current = generation; lock.unlock()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw NSError(domain: "Recorder", code: 3, userInfo: [NSLocalizedDescriptionKey: "input device reports no sample rate"])
        }
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw NSError(domain: "Recorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "could not build audio converter"])
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }

            if let channel = buffer.floatChannelData?[0] {
                let frameCount = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<frameCount { sum += channel[i] * channel[i] }
                let rms = frameCount > 0 ? sqrtf(sum / Float(frameCount)) : 0
                self.onLevel?(min(1, rms * 8)) // speech RMS is quiet; scale for a visible range
            }

            let ratio = outputFormat.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

            var error: NSError?
            var supplied = false
            converter.convert(to: outBuffer, error: &error) { _, outStatus in
                // Handing the same buffer over twice makes the converter emit the
                // audio a second time, which stutters the transcript.
                if supplied {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                outStatus.pointee = .haveData
                return buffer
            }
            guard error == nil, let channelData = outBuffer.int16ChannelData else { return }

            let frames = Int(outBuffer.frameLength)
            guard frames > 0 else { return }
            let chunk = UnsafeBufferPointer(start: channelData[0], count: frames)
            self.lock.lock()
            if self.generation == current { self.samples.append(contentsOf: chunk) }
            self.lock.unlock()
        }

        engine.prepare()
        try engine.start()
    }

    /// Everything captured so far, as a valid WAV. Safe to call mid-recording -
    /// that's what drives the live preview.
    ///
    /// Live updates now send only the unsettled tail (see `HoldSession`, which reads
    /// `samples(from:to:)`); this is kept for callers that want the whole buffer.
    func snapshotWAV() -> Data {
        lock.lock()
        let copy = samples
        lock.unlock()
        return Self.wav(from: copy, sampleRate: Int(sampleRate))
    }

    /// How many 16 kHz samples have been captured so far.
    var sampleCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return samples.count
    }

    /// A copy of samples `start..<end`, both clamped to what has been captured.
    func samples(from start: Int, to end: Int) -> [Int16] {
        lock.lock()
        defer { lock.unlock() }
        let low = max(0, min(start, samples.count))
        let high = max(0, min(end, samples.count))
        guard high > low else { return [] }
        return Array(samples[low..<high])
    }

    var durationSeconds: TimeInterval {
        lock.lock()
        let count = samples.count
        lock.unlock()
        return Double(count) / sampleRate
    }

    /// Stops capture and returns the complete recording as a WAV.
    ///
    /// The engine is stopped off the main thread and waited on for at most
    /// `stopTimeout`. CoreAudio can hang in `AVAudioEngine.stop()` when it
    /// lands a few milliseconds after the input started (an accidental tap of
    /// the shortcut): one did for 15s. Called on the main thread, that froze
    /// the pill on screen and kept the event tap from running until macOS
    /// disabled it, losing the key-up. A hung engine is left to finish on its
    /// own and is released when it does; the next hold gets a new one.
    @discardableResult
    func stop() -> Data {
        let engine = self.engine
        let stopped = Self.finishes(within: Self.stopTimeout) {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        if !stopped {
            self.engine = AVAudioEngine()
            print("talkflowd: the microphone did not stop within \(Self.stopTimeout)s, finishing the hold without waiting; the next hold uses a new audio engine")
        }
        lock.lock()
        generation += 1
        let copy = samples
        lock.unlock()
        return Self.wav(from: copy, sampleRate: Int(sampleRate))
    }

    /// Runs `work` on a background queue and reports whether it finished
    /// within `timeout`. Work that overruns keeps running; nothing waits for it.
    static func finishes(within timeout: TimeInterval, _ work: @escaping () -> Void) -> Bool {
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            work()
            done.signal()
        }
        return done.wait(timeout: .now() + timeout) == .success
    }

    /// A canonical 44-byte RIFF/WAVE header followed by the samples. Every length
    /// field is computed from the data actually present.
    static func wav(from samples: [Int16], sampleRate: Int) -> Data {
        let bytesPerSample = 2
        let dataBytes = samples.count * bytesPerSample
        var data = Data(capacity: 44 + dataBytes)

        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        data.append(contentsOf: Array("RIFF".utf8))
        append32(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append32(16)                                        // PCM header length
        append16(1)                                         // format: PCM
        append16(1)                                         // channels
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * bytesPerSample))       // byte rate
        append16(UInt16(bytesPerSample))                    // block align
        append16(16)                                        // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append32(UInt32(dataBytes))
        samples.withUnsafeBufferPointer { data.append(UnsafeRawBufferPointer($0).bindMemory(to: UInt8.self)) }

        return data
    }
}

extension Recorder: HoldAudioSource {}
