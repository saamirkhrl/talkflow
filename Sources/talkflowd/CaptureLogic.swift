import Foundation
import AVFoundation
import Darwin

// The pure parts of meeting capture: clock, gap rule, per-track sink, timeline fit, resampler, and the small
// verdict rules. No Core Audio in here, so all of it is checked by --notestest on synthetic data.

// MARK: - Clock

/// The one clock both tracks share. AVAudioTime.hostTime (mic) and AudioTimeStamp.mHostTime (IOProc) are both
/// mach_absolute_time ticks, so a chunk from either track can be placed on the same time axis.
enum CaptureClock {
    private static let timebase: mach_timebase_info_data_t = {
        var t = mach_timebase_info_data_t()
        mach_timebase_info(&t)
        return t
    }()
    static func now() -> UInt64 { mach_absolute_time() }
    static func seconds(_ ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1e9
    }
    static func nowSeconds() -> Double { seconds(now()) }
}

// MARK: - Gaps

enum GapRule {
    /// capture spike, 2026-11-23: a chunk more than 50 ms after (previous start + previous duration) is a gap; up to
    /// 5 s it is filled with silence (route change rebuild measured 87.7 ms) so the file stays on the wall clock;
    /// longer gaps (sleep) are a segment break, never an hour of zeros. Chunk-to-chunk, so slow clock drift never
    /// inserts fake gaps.
    static let padMin = 0.050
    static let padMax = 5.0
    enum Action: Equatable { case none, pad(Int), segment(Double) }

    static func decide(previousStart: Double?, previousDuration: Double, chunkStart: Double, breakPending: Bool) -> Action {
        guard let previousStart else { return .none }
        let gap = chunkStart - (previousStart + previousDuration)
        if breakPending { return .segment(max(gap, 0)) }
        if gap > padMax { return .segment(gap) }
        if gap > padMin { return .pad(Int((gap * 16000).rounded())) }
        return .none
    }
}

// MARK: - Timeline sidecar

/// One JSON object per line, written by the same thread that writes the track's audio.
final class TrackTimeline {
    private var handle: FileHandle?

    init(url: URL) throws {
        // Owner only, like the audio it describes.
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let h = try? FileHandle(forWritingTo: url) else {
            throw NotesError(message: "talkflow couldn't create the recording file.")
        }
        handle = h
    }

    func write(_ obj: [String: Any]) {
        guard let handle, var data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        try? handle.write(contentsOf: data)
    }

    func close() {
        guard let h = handle else { return }
        try? h.synchronize()
        try? h.close()
        handle = nil
    }

    deinit { close() }
}

// MARK: - Track sink

/// Everything one track does with a chunk, on one thread: fill a gap, log the timeline, write the audio.
final class TrackSink {
    let writer: StreamingWav
    let timeline: TrackTimeline?
    /// 16 kHz output samples so far, padding included.
    private(set) var index: Int64 = 0
    private var previousStart: Double?
    private var previousDuration = 0.0
    private var breakPending = false
    private var lastLoggedIndex: Int64 = -1
    /// capture spike, 2026-11-23: one timeline line per ~1 s, not per callback (~340k lines an hour).
    static let timelineEvery: Int64 = 16000

    init(writer: StreamingWav, timeline: TrackTimeline?) {
        self.writer = writer
        self.timeline = timeline
    }

    /// Sleep: the next chunk starts a new segment and nothing is padded.
    func markBreak() { breakPending = true }

    @discardableResult
    func push(_ samples: [Int16], hostSeconds: Double, nativeFrames: Int, nativeRate: Double) -> Bool {
        var ok = true
        var force = false
        let action = GapRule.decide(previousStart: previousStart, previousDuration: previousDuration,
                                    chunkStart: hostSeconds, breakPending: breakPending)
        breakPending = false
        switch action {
        case .none:
            break
        case .pad(let n):
            if !writer.appendSilence(n) { ok = false }
            let gap = hostSeconds - ((previousStart ?? hostSeconds) + previousDuration)
            timeline?.write(["k": "gap", "idx": index, "gapSec": gap, "pad": n])
            index += Int64(n)
            force = true
        case .segment(let g):
            timeline?.write(["k": "segment", "idx": index, "gapSec": g])
            force = true
        }
        previousStart = hostSeconds
        previousDuration = nativeRate > 0 ? Double(nativeFrames) / nativeRate : 0
        if force || lastLoggedIndex < 0 || index - lastLoggedIndex >= Self.timelineEvery {
            timeline?.write(["k": "chunk", "idx": index, "host": hostSeconds])
            lastLoggedIndex = index
        }
        if !samples.isEmpty, !writer.append(samples) { ok = false }
        index += Int64(samples.count)
        return ok
    }

    func event(_ what: String, hostSeconds: Double) {
        timeline?.write(["k": "event", "what": what, "host": hostSeconds, "idx": index])
    }
}

// MARK: - Timeline fit

struct TimelinePoint: Equatable { var idx: Int64; var host: Double }

/// host = a + b * idx / 16000
struct LineFit: Equatable { var a: Double; var b: Double; var maxResidual: Double; var count: Int }

enum TimelineFit {
    /// Least squares through (idx/16000, host). capture spike, 2026-11-23: residuals under 0.4 ms (system) and
    /// 8.9 ms (mic), drift -2.8..+2.1 ppm, so one straight line per segment is enough.
    static func fit(_ points: [TimelinePoint]) -> LineFit? {
        if points.isEmpty { return nil }
        let xs = points.map { Double($0.idx) / 16000 }
        let ys = points.map { $0.host }
        let n = Double(points.count)
        let xm = xs.reduce(0, +) / n
        let ym = ys.reduce(0, +) / n
        var sxx = 0.0, sxy = 0.0
        for i in 0..<points.count {
            sxx += (xs[i] - xm) * (xs[i] - xm)
            sxy += (xs[i] - xm) * (ys[i] - ym)
        }
        let b = sxx == 0 ? 1 : sxy / sxx
        let a = ym - b * xm
        var maxRes = 0.0
        for i in 0..<points.count { maxRes = max(maxRes, abs(ys[i] - (a + b * xs[i]))) }
        return LineFit(a: a, b: b, maxResidual: maxRes, count: points.count)
    }

    static func hostTime(_ f: LineFit, index: Int64) -> Double { f.a + f.b * Double(index) / 16000 }

    /// Track seconds at a host time.
    static func seconds(_ f: LineFit, atHost host: Double) -> Double { (host - f.a) / f.b }

    /// Where sample 0 of `track` falls on `reference`'s time axis, in seconds.
    static func offset(of track: LineFit, on reference: LineFit) -> Double {
        seconds(reference, atHost: hostTime(track, index: 0))
    }

    /// Chunk points of a timeline file, split into segments at "segment" lines. Malformed lines are skipped.
    static func segments(jsonl: String) -> [[TimelinePoint]] {
        var out: [[TimelinePoint]] = []
        var current: [TimelinePoint] = []
        for line in jsonl.split(separator: "\n") {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let kind = obj["k"] as? String else { continue }
            if kind == "chunk" {
                if let i = obj["idx"] as? NSNumber, let h = obj["host"] as? NSNumber {
                    current.append(TimelinePoint(idx: i.int64Value, host: h.doubleValue))
                }
            } else if kind == "segment" {
                if !current.isEmpty { out.append(current) }
                current = []
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}

// MARK: - Resampler

/// Mono Float32 at any rate to 16 kHz Int16. It allocates, so it is NOT for the IOProc thread: it runs on the
/// thread that drains the ring.
final class Resampler {
    let inputRate: Double
    private let converter: AVAudioConverter
    private let inFormat: AVAudioFormat
    private let outFormat: AVAudioFormat

    init?(inputRate: Double) {
        guard inputRate > 0,
              let inF = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false),
              let outF = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let conv = AVAudioConverter(from: inF, to: outF) else { return nil }
        self.inputRate = inputRate
        inFormat = inF
        outFormat = outF
        converter = conv
    }

    /// The converter keeps its state across calls: successive calls are one continuous stream.
    func convert(_ p: UnsafePointer<Float>, count n: Int) -> [Int16] {
        guard n > 0,
              let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(n)),
              let dst = input.floatChannelData?[0] else { return [] }
        memcpy(dst, p, n * MemoryLayout<Float>.size)
        input.frameLength = AVAudioFrameCount(n)
        let capacity = AVAudioFrameCount(Double(n) * 16000 / inputRate) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return [] }

        var error: NSError?
        var supplied = false
        converter.convert(to: output, error: &error) { _, outStatus in
            // Handing the same buffer over twice makes the converter emit the audio a second time.
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }
        guard error == nil, let ch = output.int16ChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(output.frameLength)))
    }
}

// MARK: - Computer-audio verdict

/// The "is computer audio arriving" verdict. macOS has no call that says whether System Audio Recording is
/// allowed, so it is read from what the tap delivers.
struct ComputerAudioWatch {
    /// capture spike, 2026-11-23: granted, IO always runs our own aggregate, so callbacks arrive every 10.67 ms;
    /// denied with the output idle, the IOProc was never called (run1 vs run6). So none within 1 s of a completed
    /// start = not authorised.
    static let noCallbacksAfter = 1.0
    /// capture spike recommendation: decide on exact zeros only after 3 s.
    static let zerosDecideAfter = 3.0

    /// Seconds of computer audio delivered, any content.
    private(set) var receivedSeconds = 0.0
    /// Continuous seconds of exact zeros while another app plays.
    private(set) var zeroSecondsWhileOthersPlay = 0.0
    private(set) var nonZeroEver = false

    mutating func update(audioSeconds: Double, nonZeroSamples: Int, othersPlaying: Bool) {
        receivedSeconds += audioSeconds
        if nonZeroSamples > 0 {
            nonZeroEver = true
            zeroSecondsWhileOthersPlay = 0
        } else if othersPlaying {
            zeroSecondsWhileOthersPlay += audioSeconds
        } else {
            zeroSecondsWhileOthersPlay = 0
        }
    }

    func status(startCompleted: Bool, sinceStartRequested: Double, sinceStartCompleted: Double, callbacks: Int) -> ComputerAudioStatus {
        if !startCompleted {
            return sinceStartRequested < Self.noCallbacksAfter ? .starting : .waitingForPermission
        }
        if callbacks == 0 {
            return sinceStartCompleted < Self.noCallbacksAfter ? .starting : .notAuthorised
        }
        if nonZeroEver { return .receiving }
        if zeroSecondsWhileOthersPlay >= Self.zerosDecideAfter { return .notArriving }
        if receivedSeconds >= Self.zerosDecideAfter { return .nothingPlaying }
        return .starting
    }

    static func noComputerAudio(_ s: ComputerAudioStatus) -> Bool {
        s == .notArriving || s == .notAuthorised
    }
}

// MARK: - Output route

enum OutputRoute: String, Codable {
    case headphones, speakers, unknown

    static func fourCC(_ s: String) -> UInt32 {
        s.utf8.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
    }

    /// The echo stage treats .unknown like speakers (the safe side).
    static func classify(transport: UInt32, dataSource: UInt32?, hasInput: Bool) -> OutputRoute {
        switch transport {
        case fourCC("bltn"):
            return dataSource == fourCC("hdpn") ? .headphones : .speakers
        case fourCC("blue"), fourCC("blea"):
            // A Bluetooth headset has a microphone; plain Bluetooth speakers do not.
            return hasInput ? .headphones : .unknown
        case fourCC("hdmi"), fourCC("dprt"), fourCC("airp"):
            return .speakers
        default:
            return .unknown
        }
    }
}

// MARK: - Disk

enum DiskRule {
    /// 16 kHz x 2 bytes = 32,000 bytes/s per track, so both tracks take 230.4 MB per hour.
    static let bytesPerHourBothTracks: Int64 = 230_400_000
    /// About 1 h 15 min of both tracks.
    static let minimumToStart: Int64 = 300_000_000
    /// Leaves room for the transcript and the system.
    static let stopBelow: Int64 = 150_000_000

    static func canStart(free: Int64?) -> Bool {
        guard let free else { return true }
        return free >= minimumToStart
    }

    static func mustStop(free: Int64?) -> Bool {
        guard let free else { return false }
        return free < stopBelow
    }

    static func freeBytes(at url: URL) -> Int64? {
        if let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let n = v.volumeAvailableCapacityForImportantUsage {
            return n
        }
        if let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
           let n = v.volumeAvailableCapacity {
            return Int64(n)
        }
        return nil
    }
}

// MARK: - Meter

enum MeterScale {
    /// -60 dBFS to 0 dBFS. capture spike, 2026-11-23: the quiet-room mic noise floor was about -70 dBFS (reads 0),
    /// speech peaks -20..-6 dBFS.
    static func value(peak: Float) -> Double {
        if peak <= 0 { return 0 }
        let db = 20 * log10(Double(peak))
        return min(max((db + 60) / 60, 0), 1)
    }
}
