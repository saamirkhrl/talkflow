import Foundation
import CaptureRing

/// The capture building blocks (ring, WAV writer and repair, gap rule, sink, timeline fit, resampler, verdict
/// rules), checked by `--notestest` on synthetic data only. Files live in one temporary folder that is removed at
/// the end. No microphone, no Core Audio, nothing from a real recording.
enum CaptureChecks {
    static func run(_ report: (Bool, String, String) -> Void) {
        func check(_ ok: Bool, _ label: String, _ detail: String = "") { report(ok, label, detail) }
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("talkflow-capturechecks-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var fileCounter = 0
        func tmp(_ ext: String = "wav") -> URL {
            fileCounter += 1
            return dir.appendingPathComponent("f\(fileCounter).\(ext)")
        }
        func bytes(_ u: URL) -> Data { (try? Data(contentsOf: u)) ?? Data() }
        func sine(_ count: Int, from start: Int = 0) -> [Int16] {
            (0..<count).map { Int16((8000 * sin(2 * Double.pi * 440 * Double(start + $0) / 16000)).rounded()) }
        }

        // MARK: Ring

        func writeChunk(_ r: OpaquePointer, _ payload: [Float]) -> Bool {
            var h = cap_chunk_header(hostTime: 1, nowHost: 2, sampleTime: 3, rate: 48000, frames: UInt32(payload.count),
                                     nonZero: 4, peak: 0.5, flags: 7)
            return withUnsafeBytes(of: &h) { hb in
                payload.withUnsafeBytes { pb in
                    cap_ring_write2(r, hb.baseAddress, hb.count, pb.baseAddress, pb.count)
                }
            } == 1
        }
        func readChunk(_ r: OpaquePointer) -> (cap_chunk_header, [Float])? {
            var h = cap_chunk_header()
            let okH = withUnsafeMutableBytes(of: &h) { cap_ring_read(r, $0.baseAddress, $0.count) } == 1
            guard okH else { return nil }
            var p = [Float](repeating: 0, count: Int(h.frames))
            let okP = p.withUnsafeMutableBytes { cap_ring_read(r, $0.baseAddress, $0.count) } == 1
            return okP ? (h, p) : nil
        }
        let headerSize = MemoryLayout<cap_chunk_header>.size

        if let r = cap_ring_create(4096) {
            let sizes = [10, 20, 30]
            var okW = true
            for n in sizes { okW = writeChunk(r, (0..<n).map { Float($0) * 0.5 }) && okW }
            var okR = okW
            for n in sizes {
                if let (h, p) = readChunk(r) {
                    okR = okR && Int(h.frames) == n && p == (0..<n).map { Float($0) * 0.5 }
                } else { okR = false }
            }
            check(okR, "K1 ring returns three chunks in order, header and payload intact", "")
            cap_ring_destroy(r)
        } else { check(false, "K1 ring returns three chunks in order, header and payload intact", "create failed") }

        if let r = cap_ring_create(4096) {
            let payload = [Float](repeating: 1, count: 250)       // 1000 bytes
            var first = -1
            for i in 0..<20 where !writeChunk(r, payload) { first = i; break }
            let droppedAtFirst = cap_ring_dropped(r)
            let readable = Int(cap_ring_readable(r))
            let tooSmall = cap_ring_create(3000) == nil
            check(first > 0 && droppedAtFirst == 1 && readable % (headerSize + 1000) == 0 && tooSmall,
                  "K2 full ring drops whole chunks and counts them; non power of two is refused",
                  "first=\(first) dropped=\(droppedAtFirst) readable=\(readable) tooSmall=\(tooSmall)")
            cap_ring_destroy(r)
        } else { check(false, "K2 full ring drops whole chunks and counts them; non power of two is refused", "create failed") }

        if let r = cap_ring_create(4096) {
            var ok = true
            for round in 0..<200 {
                let payload = [Float](repeating: Float(round), count: 250)
                ok = writeChunk(r, payload) && ok
                if let (h, p) = readChunk(r) {
                    ok = ok && Int(h.frames) == 250 && p.allSatisfy { $0 == Float(round) }
                } else { ok = false }
            }
            check(ok && cap_ring_dropped(r) == 0, "K3 200 chunks across wraparound arrive intact, none dropped", "dropped=\(cap_ring_dropped(r))")
            cap_ring_destroy(r)
        } else { check(false, "K3 200 chunks across wraparound arrive intact, none dropped", "create failed") }

        // MARK: StreamingWav

        do {
            var clock = 0.0
            let url = tmp()
            let w = try StreamingWav(url: url, now: { clock })
            for i in 0..<1600 { w.append(sine(100, from: i * 100)); clock += 0.001 }
            let n = w.finish()
            let info = WavInfo.read(url)
            check(n == 160_000 && info?.fileBytes == 320_044 && info?.headerMatchesFile == true
                  && info?.declaredDataBytes == 320_000 && info?.riffSize == 320_036 && info?.sampleRate == 16000
                  && info?.channels == 1 && info?.bits == 16 && info?.formatTag == 1,
                  "W1 1600 appends give a 320044 byte file with a matching header", "n=\(n) info=\(String(describing: info))")
        } catch { check(false, "W1 1600 appends give a 320044 byte file with a matching header", "\(type(of: error))") }

        do {
            var clock = 0.0
            let url = tmp()
            let w = try StreamingWav(url: url, now: { clock })
            w.append(sine(16000))
            let before = WavInfo.read(url)?.declaredDataBytes
            clock = 1.0
            w.append(sine(16000))
            let after = WavInfo.read(url)?.declaredDataBytes
            check(before == 0 && after == 64000, "W2 header is patched after a second, not before", "before=\(String(describing: before)) after=\(String(describing: after))")
            w.finish()
        } catch { check(false, "W2 header is patched after a second, not before", "\(type(of: error))") }

        do {
            let url = tmp()
            let w = try StreamingWav(url: url)
            w.appendSilence(4800)
            let n = w.finish()
            let s = WavSamples.read(url)
            check(n == 4800 && s.count == 4800 && s.allSatisfy { $0 == 0 }, "W3 appendSilence writes zeros", "n=\(n) count=\(s.count)")
        } catch { check(false, "W3 appendSilence writes zeros", "\(type(of: error))") }

        do {
            let url = tmp()
            let w = try StreamingWav(url: url)
            w.append(sine(1000))
            let n1 = w.finish()
            let size1 = bytes(url).count
            let appended = w.append(sine(10))
            let n2 = w.finish()
            check(!appended && w.samplesWritten == 1000 && bytes(url).count == size1 && n1 == n2,
                  "W4 nothing is written after finish, and finish is repeatable", "appended=\(appended) n1=\(n1) n2=\(n2)")
        } catch { check(false, "W4 nothing is written after finish, and finish is repeatable", "\(type(of: error))") }

        // MARK: WavRepair

        /// A file as a killed process leaves it: audio on disk, header still declaring 0.
        func crashedCopy(samples: Int, to dest: URL) throws {
            let src = tmp()
            let w = try StreamingWav(url: src, now: { 0 })
            w.append(sine(samples))
            try fm.copyItem(at: src, to: dest)
            w.finish()
        }

        do {
            let crashed = tmp()
            try crashedCopy(samples: 51200, to: crashed)
            let declared = WavInfo.read(crashed)?.declaredDataBytes
            let r = try WavRepair.repair(crashed)
            check(declared == 0 && r == WavRepair.Result(oldDeclared: 0, newDeclared: 102_400, truncatedOddByte: false, changed: true)
                  && WavInfo.read(crashed)?.headerMatchesFile == true,
                  "R1 a killed recording is repaired to its real length", "declared=\(String(describing: declared)) r=\(r)")
        } catch { check(false, "R1 a killed recording is repaired to its real length", "\(type(of: error))") }

        do {
            let url = tmp()
            var d = Recorder.wav(from: [], sampleRate: 16000)
            d.append(Data(repeating: 1, count: 3201))
            try d.write(to: url)
            let r = try WavRepair.repair(url)
            check(r.truncatedOddByte && r.newDeclared == 3200 && bytes(url).count == 3244,
                  "R2 a trailing odd byte is cut off", "r=\(r) size=\(bytes(url).count)")
        } catch { check(false, "R2 a trailing odd byte is cut off", "\(type(of: error))") }

        do {
            let url = tmp()
            let w = try StreamingWav(url: url)
            w.append(sine(4000))
            w.finish()
            let before = bytes(url)
            let r = try WavRepair.repair(url)
            check(!r.changed && bytes(url) == before, "R3 a correct file is left byte for byte as it was", "r=\(r)")
        } catch { check(false, "R3 a correct file is left byte for byte as it was", "\(type(of: error))") }

        do {
            let url = tmp()
            try Data("hello, not audio".utf8).write(to: url)
            let before = bytes(url)
            var threw = false
            do { _ = try WavRepair.repair(url) } catch { threw = true }
            check(threw && bytes(url) == before, "R4 a file that is not a recording makes repair throw and stays unchanged")
        } catch { check(false, "R4 a file that is not a recording makes repair throw and stays unchanged", "\(type(of: error))") }

        do {
            let url = tmp()
            try Recorder.wav(from: [Int16](repeating: 0, count: 500), sampleRate: 16000).prefix(44).write(to: url)
            let r = try WavRepair.repair(url)
            check(r.oldDeclared == 1000 && r.newDeclared == 0 && r.changed && WavInfo.read(url)?.headerMatchesFile == true,
                  "R5 a header-only file declaring audio is repaired to zero", "r=\(r)")
        } catch { check(false, "R5 a header-only file declaring audio is repaired to zero", "\(type(of: error))") }

        do {
            let folder = dir.appendingPathComponent("repairall")
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let you = folder.appendingPathComponent(CaptureFolder.mic)
            let others = folder.appendingPathComponent(CaptureFolder.system)
            try crashedCopy(samples: 20000, to: you)
            let w = try StreamingWav(url: others)
            w.append(sine(8000))
            w.finish()
            try Data("{}".utf8).write(to: folder.appendingPathComponent(CaptureFolder.session))
            let n = WavRepair.repairAll(in: folder)
            check(n == 1 && WavInfo.read(you)?.headerMatchesFile == true && WavInfo.read(others)?.headerMatchesFile == true,
                  "R6 repairAll fixes only the broken wav and ignores other files", "n=\(n)")
        } catch { check(false, "R6 repairAll fixes only the broken wav and ignores other files", "\(type(of: error))") }

        // MARK: GapRule

        func near(_ a: GapRule.Action, segment s: Double) -> Bool {
            if case .segment(let g) = a { return abs(g - s) < 1e-9 }
            return false
        }
        check(GapRule.decide(previousStart: nil, previousDuration: 0, chunkStart: 5, breakPending: false) == .none,
              "G1 the first chunk is never a gap")
        check(GapRule.decide(previousStart: 10.0, previousDuration: 0.1, chunkStart: 10.13, breakPending: false) == .none,
              "G2 a 30 ms gap is ignored")
        // Inputs chosen so the gap is exactly the double 0.05: 10.15 - (10.0 + 0.1) is 0.05 plus rounding noise.
        let g3 = GapRule.decide(previousStart: 0.0, previousDuration: 0.0, chunkStart: 0.05, breakPending: false)
        check(g3 == .none, "G3 a gap of exactly 50 ms is ignored", "\(g3)")
        let g4 = GapRule.decide(previousStart: 10.0, previousDuration: 0.1, chunkStart: 10.4, breakPending: false)
        check(g4 == .pad(4800), "G4 a 300 ms gap is padded with 4800 samples", "\(g4)")
        let g5 = GapRule.decide(previousStart: 10.0, previousDuration: 0.1, chunkStart: 15.1, breakPending: false)
        check(g5 == .pad(80000), "G5 a gap of exactly 5 s is still padded", "\(g5)")
        let g6 = GapRule.decide(previousStart: 10.0, previousDuration: 0.1, chunkStart: 17.1, breakPending: false)
        check(near(g6, segment: 7.0), "G6 a 7 s gap is a segment break", "\(g6)")
        let g7 = GapRule.decide(previousStart: 10.0, previousDuration: 0.1, chunkStart: 10.09, breakPending: false)
        check(g7 == .none, "G7 a negative gap is ignored", "\(g7)")
        let g8 = GapRule.decide(previousStart: 10.0, previousDuration: 0.1, chunkStart: 10.3, breakPending: true)
        check(near(g8, segment: 0.2), "G8 a pending break makes a segment even for a short gap", "\(g8)")

        // MARK: TrackSink

        func lines(_ url: URL) -> [[String: Any]] {
            (String(data: bytes(url), encoding: .utf8) ?? "").split(separator: "\n").compactMap {
                (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
            }
        }

        do {
            let wav = tmp(), tl = tmp("jsonl")
            let timeline = try TrackTimeline(url: tl)
            let sink = TrackSink(writer: try StreamingWav(url: wav), timeline: timeline)
            let hosts = [100.0, 100.1, 100.2, 100.6]
            for (i, h) in hosts.enumerated() {
                sink.push([Int16](repeating: Int16(i + 1), count: 1600), hostSeconds: h, nativeFrames: 4800, nativeRate: 48000)
            }
            let idx = sink.index
            sink.writer.finish()
            timeline.close()
            let s = WavSamples.read(wav)
            let expected = [Int16](repeating: 1, count: 1600) + [Int16](repeating: 2, count: 1600) + [Int16](repeating: 3, count: 1600)
                + [Int16](repeating: 0, count: 4800) + [Int16](repeating: 4, count: 1600)
            let gaps = lines(tl).filter { $0["k"] as? String == "gap" }
            check(idx == 4 * 1600 + 4800 && s == expected && gaps.count == 1 && (gaps[0]["pad"] as? Int) == 4800,
                  "T1 a 300 ms gap becomes 4800 zero samples and one gap line", "idx=\(idx) samples=\(s.count) gaps=\(gaps.count)")
        } catch { check(false, "T1 a 300 ms gap becomes 4800 zero samples and one gap line", "\(type(of: error))") }

        do {
            let wav = tmp(), tl = tmp("jsonl")
            let timeline = try TrackTimeline(url: tl)
            let sink = TrackSink(writer: try StreamingWav(url: wav), timeline: timeline)
            sink.push([Int16](repeating: 1, count: 1600), hostSeconds: 199.9, nativeFrames: 4800, nativeRate: 48000)
            sink.markBreak()
            sink.push([Int16](repeating: 2, count: 1600), hostSeconds: 200.0, nativeFrames: 4800, nativeRate: 48000)
            let idx = sink.index
            sink.writer.finish()
            timeline.close()
            let segs = lines(tl).filter { $0["k"] as? String == "segment" }
            check(segs.count == 1 && idx == 3200, "T2 a marked break writes one segment line and pads nothing", "segs=\(segs.count) idx=\(idx)")
        } catch { check(false, "T2 a marked break writes one segment line and pads nothing", "\(type(of: error))") }

        do {
            let wav = tmp(), tl = tmp("jsonl")
            let timeline = try TrackTimeline(url: tl)
            let sink = TrackSink(writer: try StreamingWav(url: wav), timeline: timeline)
            for i in 0..<100 {
                sink.push([Int16](repeating: 1, count: 1600), hostSeconds: 300 + Double(i) * 0.1, nativeFrames: 4800, nativeRate: 48000)
            }
            sink.writer.finish()
            timeline.close()
            let n = lines(tl).filter { $0["k"] as? String == "chunk" }.count
            check(abs(n - 10) <= 1, "T3 the timeline gets about one chunk line per second of audio", "chunk lines=\(n)")
        } catch { check(false, "T3 the timeline gets about one chunk line per second of audio", "\(type(of: error))") }

        // MARK: TimelineFit

        let pts1 = (0..<100).map { TimelinePoint(idx: Int64($0) * 16000, host: 1000 + Double($0) * 1.000002) }
        if let f = TimelineFit.fit(pts1) {
            check(abs(f.b - 1.000002) < 1e-9 && abs(f.a - 1000) < 1e-6 && f.maxResidual < 1e-6,
                  "F1 a straight timeline fits exactly", "a=\(f.a) b=\(f.b) res=\(f.maxResidual)")
        } else { check(false, "F1 a straight timeline fits exactly", "nil") }
        // A plain loop: the closure form of this was slow to type-check, and CI's older compiler gives up on such.
        var pts2: [TimelinePoint] = []
        for i in 0..<100 {
            let jitter: Double = i % 2 == 0 ? 0.0004 : -0.0004
            let host: Double = 1000 + Double(i) * 1.000002 + jitter
            pts2.append(TimelinePoint(idx: Int64(i) * 16000, host: host))
        }
        if let f = TimelineFit.fit(pts2) {
            check(f.maxResidual <= 0.0005 + 1e-9 && abs(f.b - 1.000002) < 1e-5,
                  "F2 jitter of 0.4 ms leaves the slope and a residual of about 0.4 ms", "b=\(f.b) res=\(f.maxResidual)")
        } else { check(false, "F2 jitter of 0.4 ms leaves the slope and a residual of about 0.4 ms", "nil") }
        if let f = TimelineFit.fit([TimelinePoint(idx: 32000, host: 50)]) {
            check(f.b == 1 && f.a == 48, "F3 one point gives slope 1 through that point", "a=\(f.a) b=\(f.b)")
        } else { check(false, "F3 one point gives slope 1 through that point", "nil") }
        let ref = LineFit(a: 100, b: 1, maxResidual: 0, count: 2)
        let trackA = LineFit(a: 100.25, b: 1, maxResidual: 0, count: 2)
        let trackB = LineFit(a: 100.25, b: 1.00001, maxResidual: 0, count: 2)
        let oA = TimelineFit.offset(of: trackA, on: ref), oB = TimelineFit.offset(of: trackB, on: ref)
        check(abs(oA - 0.25) < 1e-9 && abs(oB - 0.25) < 1e-6, "F4 the offset of one track on another", "oA=\(oA) oB=\(oB)")
        let jsonl = """
        {"k":"chunk","idx":0,"host":10.0}
        {"k":"chunk","idx":16000,"host":11.0}
        {"k":"chunk","idx":32000,"host":12.0}
        {"k":"gap","idx":32000,"gapSec":0.3,"pad":4800}
        {"k":"event","what":"route","host":12.5,"idx":36800}
        {"k":"segment","idx":36800,"gapSec":9.0}
        {"k":"chunk","idx":36800,"host":30.0}
        {"k":"chunk","idx":52800,"host":31.0}
        {oops
        """
        let segs = TimelineFit.segments(jsonl: jsonl)
        check(segs.map { $0.count } == [3, 2], "F5 chunk lines are split into segments, malformed lines skipped", "\(segs.map { $0.count })")

        // MARK: Resampler

        func feed(_ rs: Resampler, rate: Double, seconds: Double, amplitude: Float, chunk: Int = 512) -> [Int16] {
            let total = Int(rate * seconds)
            let wave = (0..<total).map { amplitude * Float(sin(2 * Double.pi * 440 * Double($0) / rate)) }
            var out: [Int16] = []
            var i = 0
            while i < total {
                let n = min(chunk, total - i)
                wave.withUnsafeBufferPointer { out += rs.convert($0.baseAddress! + i, count: n) }
                i += n
            }
            return out
        }
        if let rs = Resampler(inputRate: 48000) {
            let out = feed(rs, rate: 48000, seconds: 10, amplitude: 0.5)
            var crossings = 0
            for i in 1..<max(out.count, 1) where out[i - 1] < 0 && out[i] >= 0 { crossings += 1 }
            let peak = out.map { abs(Int($0)) }.max() ?? 0
            check(abs(out.count - 160_000) <= 64 && abs(crossings - 4400) <= 10
                  && Double(peak) > 0.45 * 32767 && Double(peak) < 0.55 * 32767,
                  "P1 48 kHz sine becomes 16 kHz with the right length, pitch and level",
                  "count=\(out.count) crossings=\(crossings) peak=\(peak)")
            let rz = Resampler(inputRate: 48000)!
            let zeros = [Float](repeating: 0, count: 48000)
            let z = zeros.withUnsafeBufferPointer { rz.convert($0.baseAddress!, count: 48000) }
            check(z.allSatisfy { $0 == 0 } && abs(z.count - 16000) <= 64, "P2 silence stays exactly zero", "count=\(z.count)")
        } else {
            check(false, "P1 48 kHz sine becomes 16 kHz with the right length, pitch and level", "no resampler")
            check(false, "P2 silence stays exactly zero", "no resampler")
        }
        if let rs = Resampler(inputRate: 44100) {
            let out = feed(rs, rate: 44100, seconds: 1, amplitude: 0.5)
            check(abs(out.count - 16000) <= 64, "P3 44.1 kHz input gives about 16000 samples a second", "count=\(out.count)")
        } else { check(false, "P3 44.1 kHz input gives about 16000 samples a second", "no resampler") }
        check(Resampler(inputRate: 0) == nil, "P4 a rate of 0 gives no resampler")

        // MARK: ComputerAudioWatch

        func watch(_ steps: [(Int, Bool, Int)]) -> ComputerAudioStatus {
            var w = ComputerAudioWatch()
            for (count, playing, nonZero) in steps {
                for _ in 0..<count { w.update(audioSeconds: 0.1, nonZeroSamples: nonZero, othersPlaying: playing) }
            }
            return w.status(startCompleted: true, sinceStartRequested: 10, sinceStartCompleted: 10, callbacks: 200)
        }
        let fresh = ComputerAudioWatch()
        check(fresh.status(startCompleted: false, sinceStartRequested: 0.5, sinceStartCompleted: 0, callbacks: 0) == .starting,
              "C1 start not finished after 0.5 s is still starting")
        check(fresh.status(startCompleted: false, sinceStartRequested: 1.5, sinceStartCompleted: 0, callbacks: 0) == .waitingForPermission,
              "C2 start not finished after 1.5 s is waiting for permission")
        check(fresh.status(startCompleted: true, sinceStartRequested: 1, sinceStartCompleted: 0.5, callbacks: 0) == .starting,
              "C3 no callbacks 0.5 s after start is still starting")
        check(fresh.status(startCompleted: true, sinceStartRequested: 2, sinceStartCompleted: 1.2, callbacks: 0) == .notAuthorised,
              "C4 no callbacks 1.2 s after start is not authorised")
        check(watch([(20, false, 0)]) == .starting, "C5 2 s of zeros is too early to say")
        check(watch([(35, false, 0)]) == .nothingPlaying, "C6 3.5 s of zeros with nothing playing is nothing playing")
        check(watch([(35, true, 0)]) == .notArriving, "C7 3.5 s of zeros while another app plays is not arriving")
        check(watch([(20, true, 0), (20, false, 0), (20, true, 0)]) == .nothingPlaying,
              "C8 a pause in playback resets the run of zeros")
        check(watch([(1, true, 5), (100, true, 0)]) == .receiving, "C9 real audio once means receiving for good")
        let all: [ComputerAudioStatus] = [.starting, .waitingForPermission, .receiving, .nothingPlaying, .notArriving, .notAuthorised]
        check(all.map { ComputerAudioWatch.noComputerAudio($0) } == [false, false, false, false, true, true],
              "C10 only notArriving and notAuthorised count as no computer audio")

        // MARK: OutputRoute

        func cls(_ t: String, _ ds: String?, _ input: Bool = false) -> OutputRoute {
            OutputRoute.classify(transport: OutputRoute.fourCC(t), dataSource: ds.map { OutputRoute.fourCC($0) }, hasInput: input)
        }
        check(cls("bltn", "hdpn") == .headphones, "O1 built-in with the headphone jack is headphones")
        check(cls("bltn", "ispk") == .speakers, "O2 built-in speakers are speakers")
        check(cls("bltn", nil) == .speakers, "O3 built-in with no data source is speakers")
        check(cls("blue", nil, true) == .headphones, "O4 Bluetooth with a microphone is headphones")
        check(cls("blue", nil, false) == .unknown, "O5 Bluetooth without a microphone is unknown")
        check(cls("hdmi", nil) == .speakers, "O6 HDMI is speakers")
        check(cls("usb ", nil) == .unknown, "O7 USB is unknown")

        let rr: [([OutputRoute], Bool, Bool)] = [([.speakers], true, true), ([.headphones], true, false), ([.unknown], true, true),
                                                 ([], true, false), ([.speakers], false, false),
                                                 ([.speakers, .headphones], true, false), ([.headphones, .speakers], true, true)]
        check(rr.allSatisfy { OutputRoute.echoHandlingActive(routes: $0.0, hasMic: $0.1) == $0.2 },
              "ROUTE1 echo handling shows only with a microphone and a current route that is not headphones")
        let ht: [([OutputRoute], Bool)] = [([], false), ([.headphones], true), ([.headphones, .speakers], false), ([.unknown], false)]
        check(ht.allSatisfy { OutputRoute.headphonesThroughout($0.0) == $0.1 },
              "ROUTE2 the echo stage is skipped only when the whole recording was on headphones")

        // MARK: DiskRule, MeterScale, session.json

        check(DiskRule.canStart(free: nil) && !DiskRule.canStart(free: 299_999_999) && DiskRule.canStart(free: 300_000_000)
              && !DiskRule.mustStop(free: nil) && DiskRule.mustStop(free: 149_999_999) && !DiskRule.mustStop(free: 150_000_000),
              "D1 disk thresholds: start at 300 MB, stop below 150 MB, unknown is fine")
        let m1 = [MeterScale.value(peak: 1.0), MeterScale.value(peak: 0.001), MeterScale.value(peak: 0.0316228),
                  MeterScale.value(peak: 0), MeterScale.value(peak: 2.0)]
        check(m1[0] == 1 && abs(m1[1]) < 1e-7 && abs(m1[2] - 0.5) < 0.001 && m1[3] == 0 && m1[4] == 1,
              "M1 meter maps -60..0 dBFS to 0..1 and clamps", "\(m1)")

        do {
            let info = CaptureSessionInfo(started: Date(timeIntervalSince1970: 1_700_000_000), hostStart: 12345.678,
                                          routes: [.init(atSeconds: 0, route: .speakers), .init(atSeconds: 61.5, route: .headphones)],
                                          systemAudioMode: "device", micSamples: 16000, systemSamples: 15990,
                                          finalComputerAudio: ComputerAudioStatus.receiving.rawValue)
            try info.write(to: dir)
            check(CaptureSessionInfo.read(from: dir) == info, "J1 session.json reads back equal to what was written")
        } catch { check(false, "J1 session.json reads back equal to what was written", "\(type(of: error))") }

        // MARK: CaptureSettle

        final class FakeWriter: SettlingWriter {
            let settles: Bool
            var abandoned = false
            init(settles: Bool) { self.settles = settles }
            func waitSettled(timeout: Double) -> Bool {
                if !settles { Thread.sleep(forTimeInterval: timeout) }
                return settles
            }
            func abandon() { abandoned = true }
        }
        func folderURL() -> URL { fm.temporaryDirectory.appendingPathComponent("capsettle-\(UUID().uuidString)", isDirectory: true) }
        let sf0 = folderURL()
        check(CaptureSettle.waitForSystemTrack(folder: sf0, timeout: 0.05) == .settled, "SET1 no registered writer is settled")
        let sf1 = folderURL(), w1 = FakeWriter(settles: true)
        CaptureSettle.register(folder: sf1, writer: w1)
        check(CaptureSettle.waitForSystemTrack(folder: sf1, timeout: 0.05) == .settled && !w1.abandoned,
              "SET2 a writer that settles is settled and left alone")
        let sf2 = folderURL(), w2 = FakeWriter(settles: false)
        CaptureSettle.register(folder: sf2, writer: w2)
        check(CaptureSettle.waitForSystemTrack(folder: sf2, timeout: 0.05) == .abandoned && w2.abandoned,
              "SET3 a writer that never settles is abandoned")
        check(CaptureSettle.waitForSystemTrack(folder: sf2, timeout: 0.05) == .settled,
              "SET4 a second wait on the same folder finds nothing")

        try? fm.removeItem(at: dir)
        check(!fm.fileExists(atPath: dir.path), "Z1 the capture checks leave no folder behind")
    }
}
