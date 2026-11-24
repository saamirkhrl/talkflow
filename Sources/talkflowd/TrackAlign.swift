import Foundation

// Puts the two recorded tracks on one time axis before the after-Stop pipeline runs. The capture timelines
// (CaptureLogic.swift) say, for chunks of each file, which host time the sample at that index belongs to. A track
// that started late (computer audio began 12 s after the microphone) or that has a sleep break inside it is
// otherwise read as if both files started together, and every turn time and the echo stage's lag go wrong.
// All pure: the checks run it on synthetic points; the only file work is reading the sidecars in plan(mic:system:).

/// Copy src[src..<src+count] to out[dst...].
struct TrackPlacement: Equatable {
    var src: Int
    var count: Int
    var dst: Int
}

struct AlignPlan: Equatable {
    var mic: [TrackPlacement]
    var system: [TrackPlacement]
    /// Aligned length in samples, on the compressed axis.
    var micLength: Int
    var systemLength: Int
    /// (at: compressed-axis seconds, add: seconds removed there); sorted by `at`.
    var expansions: [(at: Double, add: Double)]
    /// Breaks on the true common axis, (start, end) seconds, either track (for logs only).
    var breaks: [(start: Double, end: Double)]
    var micDriftPPM: Double?
    var systemDriftPPM: Double?
    /// True when every placement is src == dst and there are no expansions.
    var isIdentity: Bool

    static func == (a: AlignPlan, b: AlignPlan) -> Bool {
        if a.mic != b.mic || a.system != b.system { return false }
        if a.micLength != b.micLength || a.systemLength != b.systemLength { return false }
        if a.micDriftPPM != b.micDriftPPM || a.systemDriftPPM != b.systemDriftPPM { return false }
        if a.isIdentity != b.isIdentity { return false }
        if a.expansions.count != b.expansions.count || a.breaks.count != b.breaks.count { return false }
        for i in a.expansions.indices {
            if a.expansions[i].at != b.expansions[i].at || a.expansions[i].add != b.expansions[i].add { return false }
        }
        for i in a.breaks.indices {
            if a.breaks[i].start != b.breaks[i].start || a.breaks[i].end != b.breaks[i].end { return false }
        }
        return true
    }
}

enum TrackAlign {
    static let rate = 16000.0
    /// A span where neither track has audio and that is longer than GapRule.padMax (5 s) is shortened to 2 s: more
    /// than the 2 s pause that PauseCutter always cuts at, so the cut still happens there, and never hours of zeros
    /// in memory after a sleep. The removed seconds are added back to every output time at the end.
    static let keptBreakSeconds = 2.0
    /// A segment that would start more than 1 s before the recording's start is not believed (the timeline is
    /// untrusted and the tracks are read as they are today); smaller negatives are trimmed from the start.
    static let maxLeadSeconds = 1.0
    // Offsets only, no drift stretching. Per segment the offset is the MEDIAN over its points of
    // (host - idx / 16000). The capture spike measured -8.3..+2.1 ppm real drift (at most 60 ms over 2 h, inside the
    // echo stage's own lag/drift fit with max lag 0.5 s, and the transcript rule's 1.0 s pad), while straight-line
    // fits over 10-20 s read hundreds of ppm from converter jitter (mic residuals up to 8.9 ms). A median offset is
    // immune to that jitter. The fitted drift per track is only logged.

    private static func median(_ values: [Double]) -> Double {
        let s = values.sorted()
        let n = s.count
        if n == 0 { return 0 }
        if n % 2 == 1 { return s[n / 2] }
        return (s[n / 2 - 1] + s[n / 2]) / 2
    }

    /// Placements of one track on the TRUE common axis (before compression). nil when untrusted.
    static func place(segments: [[TimelinePoint]], trackLength: Int, hostStart: Double) -> [TrackPlacement]? {
        if segments.isEmpty { return nil }
        for pts in segments where pts.isEmpty { return nil }
        var out: [TrackPlacement] = []
        var end = 0
        for k in segments.indices {
            let pts = segments[k]
            let idx0 = Int(pts[0].idx)
            let srcStart = k == 0 ? 0 : idx0
            var srcEnd = k + 1 < segments.count ? Int(segments[k + 1][0].idx) : trackLength
            srcEnd = min(srcEnd, trackLength)
            var offsets: [Double] = []
            for p in pts { offsets.append(p.host - Double(p.idx) / rate) }
            let offset = median(offsets)
            let dstStartSeconds = offset - hostStart + Double(srcStart) / rate
            if dstStartSeconds < -maxLeadSeconds { return nil }
            var dst = Int((dstStartSeconds * rate).rounded())
            var src = srcStart
            var count = srcEnd - srcStart
            if dst < end {
                // The earlier audio wins; this also trims a small negative start (end starts at 0).
                let cut = end - dst
                src += cut
                count -= cut
                dst = end
            }
            if count <= 0 { continue }
            out.append(TrackPlacement(src: src, count: count, dst: dst))
            end = dst + count
        }
        return out.isEmpty ? nil : out
    }

    private static func breaksOf(_ placements: [TrackPlacement]) -> [(start: Double, end: Double)] {
        var out: [(start: Double, end: Double)] = []
        let minGap = Int(GapRule.padMin * rate)
        if placements.count < 2 { return out }
        for i in 1..<placements.count {
            let prevEnd = placements[i - 1].dst + placements[i - 1].count
            if placements[i].dst - prevEnd > minGap {
                out.append((start: Double(prevEnd) / rate, end: Double(placements[i].dst) / rate))
            }
        }
        return out
    }

    private static func driftPPM(_ segments: [[TimelinePoint]]) -> Double? {
        var longest: [TimelinePoint] = []
        for s in segments where s.count > longest.count { longest = s }
        if longest.count < 2 { return nil }
        guard let f = TimelineFit.fit(longest) else { return nil }
        return (f.b - 1) * 1e6
    }

    /// Full plan; nil when either timeline is missing/empty or either track is untrusted.
    static func plan(micSegments: [[TimelinePoint]]?, micLength: Int,
                     systemSegments: [[TimelinePoint]]?, systemLength: Int, hostStart: Double?) -> AlignPlan? {
        guard let ms = micSegments, let ss = systemSegments else { return nil }
        // A track with no audio at all (microphone off, or no computer audio arrived) has no timeline points; the
        // other track is still placed, so a late-starting system track keeps its true times when it is alone.
        let micEmpty = ms.isEmpty && micLength == 0
        let sysEmpty = ss.isEmpty && systemLength == 0
        if micEmpty && sysEmpty { return nil }
        if (!micEmpty && (ms.isEmpty || ms[0].isEmpty)) || (!sysEmpty && (ss.isEmpty || ss[0].isEmpty)) { return nil }
        var firstHosts: [Double] = []
        if !micEmpty { firstHosts.append(ms[0][0].host) }
        if !sysEmpty { firstHosts.append(ss[0][0].host) }
        let h = hostStart ?? (firstHosts.min() ?? 0)
        var mp: [TrackPlacement] = []
        var sp: [TrackPlacement] = []
        if !micEmpty {
            guard let placed = place(segments: ms, trackLength: micLength, hostStart: h) else { return nil }
            mp = placed
        }
        if !sysEmpty {
            guard let placed = place(segments: ss, trackLength: systemLength, hostStart: h) else { return nil }
            sp = placed
        }

        var breaks = breaksOf(mp)
        breaks.append(contentsOf: breaksOf(sp))
        breaks.sort { $0.start < $1.start }

        // Covered intervals of both tracks, merged.
        var spans: [(a: Int, b: Int)] = []
        for p in mp { spans.append((a: p.dst, b: p.dst + p.count)) }
        for p in sp { spans.append((a: p.dst, b: p.dst + p.count)) }
        spans.sort { $0.a < $1.a }
        var merged: [(a: Int, b: Int)] = []
        for s in spans {
            if let last = merged.last, s.a <= last.b {
                merged[merged.count - 1].b = max(last.b, s.b)
            } else {
                merged.append(s)
            }
        }

        // Joint holes: between merged intervals, and from 0 to the first one (both tracks started late).
        let keep = Int(keptBreakSeconds * rate)
        let limit = Int(GapRule.padMax * rate)
        var removals: [(start: Int, end: Int)] = []
        var cursor = 0
        for m in merged {
            if m.a - cursor > limit { removals.append((start: cursor + keep, end: m.a)) }
            cursor = max(cursor, m.b)
        }

        func shifted(_ list: [TrackPlacement]) -> [TrackPlacement] {
            var out: [TrackPlacement] = []
            for p in list {
                var removed = 0
                for r in removals where r.end <= p.dst { removed += r.end - r.start }
                out.append(TrackPlacement(src: p.src, count: p.count, dst: p.dst - removed))
            }
            return out
        }
        mp = shifted(mp)
        sp = shifted(sp)

        var expansions: [(at: Double, add: Double)] = []
        var removedBefore = 0
        for r in removals {
            let length = r.end - r.start
            expansions.append((at: Double(r.start - removedBefore) / rate, add: Double(length) / rate))
            removedBefore += length
        }

        var micLength = 0
        for p in mp { micLength = max(micLength, p.dst + p.count) }
        var systemLength = 0
        for p in sp { systemLength = max(systemLength, p.dst + p.count) }

        var identity = expansions.isEmpty
        for p in mp where p.src != p.dst { identity = false }
        for p in sp where p.src != p.dst { identity = false }

        return AlignPlan(mic: mp, system: sp, micLength: micLength, systemLength: systemLength,
                         expansions: expansions, breaks: breaks,
                         micDriftPPM: driftPPM(ms), systemDriftPPM: driftPPM(ss), isIdentity: identity)
    }

    /// True common-axis seconds for a compressed-axis time.
    static func expand(_ t: Double, _ expansions: [(at: Double, add: Double)]) -> Double {
        var out = t
        for e in expansions where e.at <= t { out += e.add }
        return out
    }

    /// Pure: apply placements to an in-memory track (used by the checks and as the reference for the file reader).
    static func apply(_ src: [Int16], _ placements: [TrackPlacement], length: Int) -> [Int16] {
        var out = [Int16](repeating: 0, count: max(length, 0))
        for p in placements {
            let n = min(p.count, src.count - p.src, length - p.dst)
            if n <= 0 { continue }
            for i in 0..<n { out[p.dst + i] = src[p.src + i] }
        }
        return out
    }

    /// Reads the plan from a capture folder: nil unless micURL/sysURL are named CaptureFolder.mic / .system in the
    /// same folder AND both timeline files exist. hostStart from session.json, else min(first host of both tracks).
    /// Track lengths from the WAV file sizes: (fileBytes - 44) / 2.
    static func plan(mic micURL: URL, system sysURL: URL) -> AlignPlan? {
        let folder = micURL.deletingLastPathComponent()
        guard micURL.lastPathComponent == CaptureFolder.mic, sysURL.lastPathComponent == CaptureFolder.system,
              sysURL.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL else { return nil }
        let micTimeline = folder.appendingPathComponent(CaptureFolder.micTimeline)
        let sysTimeline = folder.appendingPathComponent(CaptureFolder.systemTimeline)
        guard let micText = try? String(contentsOf: micTimeline, encoding: .utf8),
              let sysText = try? String(contentsOf: sysTimeline, encoding: .utf8),
              let micInfo = WavInfo.read(micURL), let sysInfo = WavInfo.read(sysURL) else { return nil }
        let micSegments = TimelineFit.segments(jsonl: micText)
        let sysSegments = TimelineFit.segments(jsonl: sysText)
        let start = CaptureSessionInfo.read(from: folder)?.hostStart
        return plan(micSegments: micSegments, micLength: (micInfo.fileBytes - 44) / 2,
                    systemSegments: sysSegments, systemLength: (sysInfo.fileBytes - 44) / 2, hostStart: start)
    }
}
