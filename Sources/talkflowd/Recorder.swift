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
    private let engine = AVAudioEngine()
    private let sampleRate: Double = 16000

    /// Guards `samples`, which the audio tap appends to on a realtime thread
    /// while the main thread reads snapshots of it for the live preview.
    private let lock = NSLock()
    private var samples: [Int16] = []

    /// Fires on a background thread with each buffer's RMS level (roughly 0...1)
    /// so the overlay can animate in step with the speaker's voice.
    var onLevel: ((Float) -> Void)?

    func start() throws {
        lock.lock(); samples = []; lock.unlock()

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
            self.samples.append(contentsOf: chunk)
            self.lock.unlock()
        }

        engine.prepare()
        try engine.start()
    }

    /// Everything captured so far, as a valid WAV. Safe to call mid-recording -
    /// that's what drives the live preview.
    ///
    /// `lastSeconds` trims to the most recent audio. The preview re-transcribes
    /// from scratch each tick, so on a long hold the whole-buffer cost grows
    /// without bound and preview requests start queueing ahead of the final
    /// transcription. The pill only shows the newest words anyway.
    func snapshotWAV(lastSeconds: TimeInterval? = nil) -> Data {
        lock.lock()
        var copy = samples
        lock.unlock()
        if let lastSeconds {
            let keep = Int(lastSeconds * sampleRate)
            if copy.count > keep { copy = Array(copy.suffix(keep)) }
        }
        return Self.wav(from: copy, sampleRate: Int(sampleRate))
    }

    var durationSeconds: TimeInterval {
        lock.lock()
        let count = samples.count
        lock.unlock()
        return Double(count) / sampleRate
    }

    /// Stops capture and returns the complete recording as a WAV.
    @discardableResult
    func stop() -> Data {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        return snapshotWAV()
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
