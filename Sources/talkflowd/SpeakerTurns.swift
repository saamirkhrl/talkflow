import Foundation

/// One stretch of one speaker's voice, in seconds from the start of the recording.
struct SpeakerSegment: Equatable {
    var speaker: String
    var start: Double
    var end: Double
}

/// Pure rules for turning the speaker helper's turns (which may overlap) into runs the
/// transcriber can cut at.
enum SpeakerTurns {
    /// Non-overlapping, time-ordered runs from possibly overlapping helper turns.
    /// Where several speakers talk at once, the person already holding the floor keeps it, so a
    /// "yeah" over someone does not split their turn.
    static func flatten(_ segments: [SpeakerSegment]) -> [SpeakerSegment] {
        let segs = segments.filter { $0.end > $0.start }
        guard !segs.isEmpty else { return [] }
        let bounds = Array(Set(segs.flatMap { [$0.start, $0.end] })).sorted()
        guard bounds.count >= 2 else { return [] }

        // One label per elementary interval; nil is a gap.
        var pieces: [(start: Double, end: Double, label: String)] = []
        var previous: String?
        for i in 0..<(bounds.count - 1) {
            let t0 = bounds[i]
            let t1 = bounds[i + 1]
            let active = segs.filter { $0.start <= t0 && $0.end >= t1 }
            var label: String?
            if active.count == 1 {
                label = active[0].speaker
            } else if active.count > 1 {
                if let previous, active.contains(where: { $0.speaker == previous }) {
                    label = previous
                } else {
                    let best = active.min { a, b in
                        let la = a.end - a.start
                        let lb = b.end - b.start
                        if la != lb { return la > lb }
                        if a.start != b.start { return a.start < b.start }
                        return a.speaker < b.speaker
                    }
                    label = best?.speaker
                }
            }
            previous = label
            guard let label else { continue }
            if let last = pieces.last, last.label == label, last.end == t0 {
                pieces[pieces.count - 1].end = t1
            } else {
                pieces.append((t0, t1, label))
            }
        }
        return pieces.map { SpeakerSegment(speaker: $0.label, start: $0.start, end: $0.end) }
    }

    /// Times where the speaker changes: touching runs give the boundary, runs separated by a gap
    /// give the middle of the gap. Neighbours with the same speaker give no cut.
    static func forcedCuts(_ runs: [SpeakerSegment]) -> [Double] {
        let sorted = runs.sorted { $0.start < $1.start }
        var cuts: [Double] = []
        for i in 1..<max(sorted.count, 1) {
            let a = sorted[i - 1]
            let b = sorted[i]
            guard a.speaker != b.speaker else { continue }
            let gap = b.start - a.end
            cuts.append(gap <= 1e-9 ? a.end : a.end + gap / 2)
        }
        return cuts
    }

    /// The speaker for a stretch: most overlap with the runs; with no overlap, the run nearest in
    /// time (ties go to the earlier run); nil when there are no runs.
    static func speaker(start: Double, end: Double, runs: [SpeakerSegment]) -> String? {
        guard !runs.isEmpty else { return nil }
        let sorted = runs.sorted { $0.start < $1.start }
        var overlap: [String: Double] = [:]
        var order: [String] = []
        for r in sorted {
            let o = min(end, r.end) - max(start, r.start)
            if o > 0 {
                if overlap[r.speaker] == nil { order.append(r.speaker) }
                overlap[r.speaker, default: 0] += o
            }
        }
        if let best = order.max(by: { (overlap[$0] ?? 0) < (overlap[$1] ?? 0) }) {
            // max(by:) keeps the last of equal values; prefer the earliest speaker on a tie.
            let top = overlap[best] ?? 0
            return order.first { (overlap[$0] ?? 0) == top }
        }
        var nearest = sorted[0]
        var nearestGap = Double.infinity
        for r in sorted {
            let gap = max(0, r.start - end, start - r.end)
            if gap < nearestGap {
                nearestGap = gap
                nearest = r
            }
        }
        return nearest.speaker
    }
}
