import Foundation
import Darwin

// The recording's files: two growing 16 kHz mono WAVs (you / others), their timeline sidecars and session.json.
// Everything here is plain synchronous file work; each StreamingWav is used by one thread or queue only.

/// File names inside a note's audio folder.
enum CaptureFolder {
    static let mic = "you.wav"
    static let system = "others.wav"
    static let micTimeline = "you.timeline.jsonl"
    static let systemTimeline = "others.timeline.jsonl"
    static let session = "session.json"
    /// Temporary copy of others.wav on the common time axis, for the speaker helper; removed right after.
    static let systemAligned = "others.aligned.wav"
}

private func le32(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
private func le16(_ v: UInt16) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }

/// Writes the 44-byte header (same layout as Recorder.wav) with the given data size.
private func canonicalHeader(dataBytes: UInt32) -> [UInt8] {
    var h = [UInt8]()
    h += Array("RIFF".utf8); h += le32(36 &+ dataBytes)
    h += Array("WAVE".utf8); h += Array("fmt ".utf8)
    h += le32(16)                                   // PCM header length
    h += le16(1)                                    // format: PCM
    h += le16(1)                                    // channels
    h += le32(16000)                                // sample rate
    h += le32(32000)                                // byte rate
    h += le16(2)                                    // block align
    h += le16(16)                                   // bits per sample
    h += Array("data".utf8); h += le32(dataBytes)
    return h
}

private func fullWrite(_ fd: Int32, _ base: UnsafeRawPointer, _ count: Int) -> (written: Int, error: Int32?) {
    var done = 0
    while done < count {
        let n = Darwin.write(fd, base + done, count - done)
        if n < 0 {
            if errno == EINTR { continue }
            return (done, errno)
        }
        if n == 0 { return (done, EIO) }
        done += n
    }
    return (done, nil)
}

private func fullPwrite(_ fd: Int32, _ bytes: [UInt8], at offset: Int) -> Bool {
    var done = 0
    while done < bytes.count {
        let n = bytes.withUnsafeBytes { Darwin.pwrite(fd, $0.baseAddress! + done, bytes.count - done, off_t(offset + done)) }
        if n < 0 {
            if errno == EINTR { continue }
            return false
        }
        if n == 0 { return false }
        done += n
    }
    return true
}

/// A WAV that is written while it grows. The header is rewritten with the real length at most once a second, so a
/// crash or kill leaves a file whose header is at most ~1 s short and that WavRepair makes exact again.
final class StreamingWav {
    static let sampleRate = 16000
    static let headerBytes = 44
    /// capture spike, 2026-11-23: header patched at most every 1.0 s with pwrite; SIGKILL after 3.3 s left 3.1 s
    /// declared, and repair recovered all of it.
    static let patchInterval: Double = 1.0
    /// capture spike, 2026-11-23: the page cache survives a process death but not power loss, so fsync every ~10 s.
    static let syncInterval: Double = 10.0

    let url: URL
    private(set) var samplesWritten: Int64 = 0
    /// errno of the first failed write; once set nothing more is written.
    private(set) var failure: Int32?
    private(set) var isFinished = false

    private let fd: Int32
    private var dataBytes: Int64 = 0
    private let now: () -> Double
    private var lastPatch: Double
    private var lastSync: Double
    private var zeros: [Int16]?

    init(url: URL, now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) throws {
        // Owner only: a meeting recording is private audio.
        let fd = open(url.path, O_RDWR | O_CREAT | O_TRUNC, 0o600)
        if fd < 0 { throw NotesError(message: "talkflow couldn't create the recording file.") }
        let header = canonicalHeader(dataBytes: 0)
        let r = header.withUnsafeBytes { fullWrite(fd, $0.baseAddress!, header.count) }
        if r.error != nil {
            close(fd)
            throw NotesError(message: "talkflow couldn't create the recording file.")
        }
        self.url = url
        self.fd = fd
        self.now = now
        let t = now()
        self.lastPatch = t
        self.lastSync = t
    }

    deinit { finish() }

    @discardableResult
    func append(_ samples: [Int16]) -> Bool {
        samples.withUnsafeBufferPointer { append($0) }
    }

    @discardableResult
    func append(_ samples: UnsafeBufferPointer<Int16>) -> Bool {
        if isFinished || failure != nil { return false }
        if samples.isEmpty { return true }
        let bytes = samples.count * 2
        // 37 hours: the WAV size fields are 32 bits.
        if dataBytes + Int64(bytes) > Int64(UInt32.max) - 36 {
            failure = EFBIG
            return false
        }
        let r = fullWrite(fd, UnsafeRawPointer(samples.baseAddress!), bytes)
        dataBytes += Int64(r.written)
        if let e = r.error {
            failure = e
            return false
        }
        samplesWritten += Int64(samples.count)
        if now() - lastPatch >= Self.patchInterval { patch() }
        if now() - lastSync >= Self.syncInterval {
            fsync(fd)
            lastSync = now()
        }
        return true
    }

    /// Zeros in pieces of at most one second, from one buffer allocated once.
    @discardableResult
    func appendSilence(_ count: Int) -> Bool {
        if count <= 0 { return !(isFinished || failure != nil) }
        if zeros == nil { zeros = [Int16](repeating: 0, count: 16000) }
        var left = count
        var ok = true
        while left > 0 {
            let n = min(left, 16000)
            let piece = zeros!.withUnsafeBufferPointer { UnsafeBufferPointer(rebasing: $0[0..<n]) }
            if !append(piece) { ok = false; break }
            left -= n
        }
        return ok
    }

    private func patch() {
        // An odd trailing byte (partial write) is never declared.
        let data = UInt32(dataBytes & ~1)
        _ = fullPwrite(fd, le32(36 &+ data), at: 4)
        _ = fullPwrite(fd, le32(data), at: 40)
        lastPatch = now()
    }

    @discardableResult
    func finish() -> Int64 {
        if isFinished { return samplesWritten }
        patch()
        fsync(fd)
        close(fd)
        isFinished = true
        return samplesWritten
    }
}

// MARK: - Reading (checks, --capturetest)

struct WavInfo: Equatable {
    var markersOK: Bool
    var declaredDataBytes: UInt32
    var riffSize: UInt32
    var fileBytes: Int
    var sampleRate: UInt32
    var channels: UInt16
    var bits: UInt16
    var formatTag: UInt16
    /// markersOK && declared == fileBytes - 44 && riff == declared + 36
    var headerMatchesFile: Bool

    /// Reads only the 44-byte header and the file size, never the audio.
    static func read(_ url: URL) -> WavInfo? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let size = try? h.seekToEnd(), size >= 44 else { return nil }
        try? h.seek(toOffset: 0)
        guard let d = try? h.read(upToCount: 44), d.count == 44 else { return nil }
        let b = [UInt8](d)
        func u32(_ o: Int) -> UInt32 { UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24 }
        func u16(_ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o + 1]) << 8 }
        func tag(_ o: Int) -> String { String(decoding: b[o..<o + 4], as: UTF8.self) }
        let ok = tag(0) == "RIFF" && tag(8) == "WAVE" && tag(12) == "fmt " && tag(36) == "data"
        let fileBytes = Int(size)
        let declared = u32(40), riff = u32(4)
        return WavInfo(markersOK: ok, declaredDataBytes: declared, riffSize: riff, fileBytes: fileBytes,
                       sampleRate: u32(24), channels: u16(22), bits: u16(34), formatTag: u16(20),
                       headerMatchesFile: ok && Int(declared) == fileBytes - 44 && riff == declared &+ 36)
    }
}

enum WavSamples {
    /// All samples after byte 44, little-endian. For tests only: it reads the whole file.
    static func read(_ url: URL) -> [Int16] {
        guard let d = try? Data(contentsOf: url), d.count > 44 else { return [] }
        let b = [UInt8](d)
        let n = (b.count - 44) / 2
        var out = [Int16](repeating: 0, count: n)
        for i in 0..<n {
            out[i] = Int16(bitPattern: UInt16(b[44 + 2 * i]) | UInt16(b[45 + 2 * i]) << 8)
        }
        return out
    }

    /// Reads a 16-bit mono WAV straight into its aligned place, 1 MB at a time: one output buffer, no whole-file copy
    /// (a two-hour track is 230 MB). Bytes past the end of the file read as silence.
    static func readPlaced(_ url: URL, _ placements: [TrackPlacement], length: Int) -> [Int16] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        var out = [Int16](repeating: 0, count: max(length, 0))
        // 1 MB of audio per read.
        let chunkSamples = 524_288
        out.withUnsafeMutableBufferPointer { buffer in
            for p in placements {
                var done = 0
                let wanted = min(p.count, length - p.dst)
                if wanted <= 0 || p.src < 0 || p.dst < 0 { continue }
                do { try handle.seek(toOffset: UInt64(44 + 2 * p.src)) } catch { continue }
                while done < wanted {
                    let n = min(chunkSamples, wanted - done)
                    guard let data = try? handle.read(upToCount: n * 2), !data.isEmpty else { break }
                    let got = data.count / 2
                    if got == 0 { break }
                    data.withUnsafeBytes { raw in
                        let bytes = raw.bindMemory(to: UInt8.self)
                        for i in 0..<got {
                            let lo = UInt16(bytes[2 * i])
                            let hi = UInt16(bytes[2 * i + 1]) << 8
                            buffer[p.dst + done + i] = Int16(bitPattern: lo | hi)
                        }
                    }
                    done += got
                    if data.count < n * 2 { break }
                }
            }
        }
        return out
    }
}

// MARK: - Repair

/// Makes the leftovers of a crash or kill playable again.
enum WavRepair {
    struct Result: Equatable {
        var oldDeclared: UInt32
        var newDeclared: UInt32
        var truncatedOddByte: Bool
        var changed: Bool
    }

    /// capture spike, 2026-11-23: if RIFF@0, WAVE@8, "fmt "@12, fmt length 16 @16 and "data"@36 are in place, the
    /// data is everything after byte 44. A trailing odd byte is cut off, then offsets 4 and 40 are patched.
    static func repair(_ url: URL) throws -> Result {
        let notOurs = NotesError(message: "Not a talkflow recording.")
        let fd = open(url.path, O_RDWR)
        if fd < 0 { throw NotesError(message: "talkflow couldn't open the recording file.") }
        defer { close(fd) }

        var head = [UInt8](repeating: 0, count: 44)
        let got = head.withUnsafeMutableBytes { Darwin.pread(fd, $0.baseAddress!, 44, 0) }
        guard got == 44 else { throw notOurs }
        func u32(_ o: Int) -> UInt32 { UInt32(head[o]) | UInt32(head[o + 1]) << 8 | UInt32(head[o + 2]) << 16 | UInt32(head[o + 3]) << 24 }
        func tag(_ o: Int) -> String { String(decoding: head[o..<o + 4], as: UTF8.self) }
        guard tag(0) == "RIFF", tag(8) == "WAVE", tag(12) == "fmt ", u32(16) == 16, tag(36) == "data" else { throw notOurs }

        var st = stat()
        guard fstat(fd, &st) == 0 else { throw notOurs }
        var payload = Int(st.st_size) - 44
        var truncated = false
        if payload % 2 != 0 {
            guard ftruncate(fd, st.st_size - 1) == 0 else { throw NotesError(message: "talkflow couldn't repair the recording file.") }
            truncated = true
            payload -= 1
        }
        let oldDeclared = u32(40), oldRiff = u32(4)
        let newDeclared = UInt32(min(payload, Int(UInt32.max - 36)) & ~1)
        let changed = truncated || oldDeclared != newDeclared || oldRiff != newDeclared + 36
        if changed {
            guard fullPwrite(fd, le32(newDeclared + 36), at: 4), fullPwrite(fd, le32(newDeclared), at: 40) else {
                throw NotesError(message: "talkflow couldn't repair the recording file.")
            }
        }
        fsync(fd)
        return Result(oldDeclared: oldDeclared, newDeclared: newDeclared, truncatedOddByte: truncated, changed: changed)
    }

    /// Repairs every visible .wav directly in the folder; returns how many needed it. Failures are skipped and the
    /// file is left as it is. Nothing is logged: file names belong to a private recording.
    @discardableResult
    static func repairAll(in folder: URL) -> Int {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])) ?? []
        var fixed = 0
        for u in items where u.pathExtension.lowercased() == "wav" {
            if let r = try? repair(u), r.changed { fixed += 1 }
        }
        return fixed
    }
}

// MARK: - session.json

/// The recording's metadata, next to its audio.
struct CaptureSessionInfo: Codable, Equatable {
    struct RouteEntry: Codable, Equatable {
        var atSeconds: Double
        var route: OutputRoute
    }

    var schemaVersion = 1
    /// Wall clock at start.
    var started: Date
    /// CaptureClock seconds at start: both timelines use this clock.
    var hostStart: Double
    var sampleRate = 16000
    /// Output route at start and after every change (for the echo stage).
    var routes: [RouteEntry]
    /// "device" (output device as the aggregate's main sub-device) or "tapOnly".
    var systemAudioMode: String?
    /// Filled at stop.
    var micSamples: Int64 = 0
    var systemSamples: Int64 = 0
    /// ComputerAudioStatus raw value at stop.
    var finalComputerAudio: String?

    func write(to folder: URL) throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        try enc.encode(self).write(to: folder.appendingPathComponent(CaptureFolder.session), options: .atomic)
    }

    static func read(from folder: URL) -> CaptureSessionInfo? {
        guard let d = try? Data(contentsOf: folder.appendingPathComponent(CaptureFolder.session)) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(CaptureSessionInfo.self, from: d)
    }
}
