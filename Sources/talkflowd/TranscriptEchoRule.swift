import Foundation

struct TimedWord: Equatable { var text: String; var start: Double; var end: Double }

struct TimedSegment: Equatable {
    var start: Double
    var end: Double
    var text: String
    var words: [TimedWord]   // empty = no word times: spread words uniformly over the segment, as rule.py does
}

/// Transcript-level echo cleanup: removes from the "You" transcript the words that are the system track's speech
/// leaking into the microphone. Pure logic. Port of the echo spike's rule.py (spec: echo spike RESULTS.md 6.2).
/// Safety property: nothing is ever removed where the system track has no words near the user's words.
enum TranscriptEchoRule {
    /// echo spike RESULTS.md 6.2: PAD 1.0 s covers the 20-120 ms acoustic delay plus whisper word-time jitter.
    static let pad = 1.0
    /// echo spike RESULTS.md 6.2: You segments closer than this (gap < 1.0 s) form one group.
    static let groupGap = 1.0
    /// echo spike RESULTS.md 6.2: groups over 400 tokens are split at the largest gap (bounds the LCS table).
    static let maxGroupTokens = 400
    /// echo spike RESULTS.md 6.2: a run needs >= 3 matched tokens (0 user words removed on 15 double-talk fixtures).
    static let minRun = 3
    /// echo spike RESULTS.md 6.2: a whole group of at most 2 tokens may go when all are matched.
    static let shortMax = 2
    /// echo spike RESULTS.md 6.2: fuzzy match only when both tokens have >= 5 chars (catches "seben" for "seven").
    static let fuzzyMinLength = 5
    /// echo spike RESULTS.md 6.2: stopwords never make a run on their own.
    static let stop: Set<String> = [
        "the", "a", "an", "and", "of", "to", "in", "is", "it", "that", "i", "we", "you", "for",
        "on", "with", "as", "was", "be", "at", "by", "this", "our", "or", "not", "but", "have",
        "had", "all", "so", "are", "from", "his", "her", "my", "me", "no", "she", "he", "they",
        "them", "its", "their", "there", "one", "what", "which", "when", "were", "would", "been",
        "if",
    ]

    private struct Token {
        var text: [UInt8]       // normalised, ASCII a-z0-9 only
        var string: String
        var start: Double
        var end: Double
        var seg: Int
        var widx: Int
        var removed = false
    }

    /// The "You" segments with echo of the system track removed. Unchanged segments come back identical
    /// (==, including words); segments with everything removed are dropped; partly kept segments get
    /// text = kept raw words joined by single spaces, start/end = first/last kept word, words = the kept words.
    static func apply(you: [TimedSegment], system: [TimedSegment]) -> [TimedSegment] {
        var sysTokens = tokens(system).0
        // Stable by start (Python's sort is stable; Swift's is not guaranteed to be).
        sysTokens = sysTokens.enumerated().sorted {
            $0.element.start != $1.element.start ? $0.element.start < $1.element.start : $0.offset < $1.offset
        }.map { $0.element }

        let tokenised = tokens(you)
        var youTokens = tokenised.0
        let raws = tokenised.1
        var segTokens = [[Int]](repeating: [], count: you.count)   // indexes into youTokens
        for (ti, t) in youTokens.enumerated() { segTokens[t.seg].append(ti) }
        let tokCounts = segTokens.map { $0.count }

        let order = you.indices.sorted {
            you[$0].start != you[$1].start ? you[$0].start < you[$1].start : $0 < $1
        }
        var groups: [[Int]] = []
        var cur: [Int] = []
        for i in order {
            if let last = cur.last, (you[i].start - you[last].end) < groupGap {
                cur.append(i)
            } else {
                if !cur.isEmpty { groups.append(cur) }
                cur = [i]
            }
        }
        if !cur.isEmpty { groups.append(cur) }
        var finalGroups: [[Int]] = []
        for g in groups { finalGroups.append(contentsOf: splitGroup(g, you, tokCounts)) }

        for g in finalGroups {
            var y: [Int] = []   // indexes into youTokens
            for si in g { y.append(contentsOf: segTokens[si]) }
            let n = y.count
            if n == 0 { continue }
            let gs = youTokens[y[0]].start
            let ge = youTokens[y[n - 1]].end
            let window = sysTokens.filter { $0.start <= ge + pad && $0.end >= gs - pad }
            // Never remove anything where the system track is silent.
            if window.isEmpty { continue }
            let m = window.count

            func isMatch(_ i: Int, _ j: Int) -> Bool {
                let a = youTokens[y[i]], b = window[j]
                if !(b.start <= a.end + pad && b.end >= a.start - pad) { return false }
                return same(a.text, b.text)
            }

            // LCS over (You tokens, system tokens) restricted to time-compatible, text-equal-or-fuzzy pairs.
            let w = m + 1
            var dp = [Int32](repeating: 0, count: (n + 1) * w)
            var mt = [Bool](repeating: false, count: n * m)
            for i in 1...n {
                for j in 1...m {
                    let up = dp[(i - 1) * w + j], left = dp[i * w + j - 1]
                    var best = up >= left ? up : left
                    if isMatch(i - 1, j - 1) {
                        mt[(i - 1) * m + j - 1] = true
                        if dp[(i - 1) * w + j - 1] + 1 > best { best = dp[(i - 1) * w + j - 1] + 1 }
                    }
                    dp[i * w + j] = best
                }
            }
            var matched = [Bool](repeating: false, count: n)
            var i = n, j = m
            while i > 0 && j > 0 {
                if mt[(i - 1) * m + j - 1] && dp[i * w + j] == dp[(i - 1) * w + j - 1] + 1 {
                    matched[i - 1] = true
                    i -= 1
                    j -= 1
                } else if dp[(i - 1) * w + j] >= dp[i * w + j - 1] {
                    i -= 1
                } else {
                    j -= 1
                }
            }

            // A single unmatched token between two matched ones (e.g. a mishearing) joins the run.
            var bridged = [Bool](repeating: false, count: n)
            if n > 2 {
                for k in 1..<(n - 1) where !matched[k] && matched[k - 1] && matched[k + 1] { bridged[k] = true }
            }

            var removed = [Bool](repeating: false, count: n)
            var anyRun = false
            var k = 0
            while k < n {
                if matched[k] || bridged[k] {
                    var e = k
                    while e + 1 < n && (matched[e + 1] || bridged[e + 1]) { e += 1 }
                    var matchedCount = 0
                    var nonStop = false
                    for x in k...e where matched[x] {
                        matchedCount += 1
                        if !stop.contains(youTokens[y[x]].string) { nonStop = true }
                    }
                    if matchedCount >= minRun && nonStop {
                        for x in k...e { removed[x] = true }
                        anyRun = true
                    }
                    k = e + 1
                } else {
                    k += 1
                }
            }

            if n <= shortMax && !matched.contains(false) && y.contains(where: {
                !stop.contains(youTokens[$0].string) && youTokens[$0].text.count >= 4
            }) {
                for x in 0..<n { removed[x] = true }
            }

            if anyRun {
                let rest = (0..<n).filter { !removed[$0] }
                if rest.allSatisfy({ stop.contains(youTokens[y[$0]].string) }) {
                    for x in rest { removed[x] = true }
                }
            }
            for x in 0..<n where removed[x] { youTokens[y[x]].removed = true }
        }

        // Map back to raw words: a word goes iff all its tokens went; punctuation-only words follow a neighbour.
        var wordToks: [Int: [Int]] = [:]   // key seg * 1_000_000 + widx -> token indexes
        for (ti, t) in youTokens.enumerated() { wordToks[t.seg * 1_000_000 + t.widx, default: []].append(ti) }

        var out: [TimedSegment] = []
        for (si, seg) in you.enumerated() {
            let rw = raws[si]
            let nw = rw.count
            var wrem = [Bool](repeating: false, count: nw)
            var hasTok = [Bool](repeating: false, count: nw)
            for wi in 0..<nw {
                if let ts = wordToks[si * 1_000_000 + wi] {
                    hasTok[wi] = true
                    wrem[wi] = ts.allSatisfy { youTokens[$0].removed }
                }
            }
            for wi in 0..<nw where !hasTok[wi] {
                var anchor: Int?
                var b = wi - 1
                while b >= 0 { if hasTok[b] { anchor = b; break }; b -= 1 }
                if anchor == nil {
                    b = wi + 1
                    while b < nw { if hasTok[b] { anchor = b; break }; b += 1 }
                }
                if let a = anchor, wrem[a] { wrem[wi] = true }
            }
            if !wrem.contains(true) {
                out.append(seg)
                continue
            }
            let kept = (0..<nw).filter { !wrem[$0] }.map { rw[$0] }
            if let first = kept.first, let last = kept.last {
                out.append(TimedSegment(start: first.start, end: last.end,
                                        text: kept.map { $0.text }.joined(separator: " "), words: kept))
            }
        }
        return out
    }

    // MARK: Helpers

    /// One raw word into 0..many tokens: lowercase, "-" and em dash become spaces, keep [a-z0-9'] only,
    /// drop apostrophes, split on spaces.
    static func normalise(_ word: String) -> [String] {
        var result: [String] = []
        var cur = ""
        for u in word.lowercased().unicodeScalars {
            switch u {
            case "-", "\u{2014}", " ":
                if !cur.isEmpty { result.append(cur); cur = "" }
            case "a"..."z", "0"..."9":
                cur.unicodeScalars.append(u)
            default:
                break   // apostrophes and every other character are dropped
            }
        }
        if !cur.isEmpty { result.append(cur) }
        return result
    }

    /// Raw words of a segment, with synthesised uniform times when the segment has no word times.
    private static func rawWords(_ seg: TimedSegment) -> [TimedWord] {
        if !seg.words.isEmpty { return seg.words }
        let toks = seg.text.split(whereSeparator: { $0.isWhitespace })
        let n = Double(toks.count)
        if toks.isEmpty { return [] }
        return toks.enumerated().map { k, t in
            TimedWord(text: String(t),
                      start: seg.start + Double(k) * (seg.end - seg.start) / n,
                      end: seg.start + Double(k + 1) * (seg.end - seg.start) / n)
        }
    }

    private static func tokens(_ segs: [TimedSegment]) -> ([Token], [[TimedWord]]) {
        var toks: [Token] = []
        var raws: [[TimedWord]] = []
        for (si, seg) in segs.enumerated() {
            let rw = rawWords(seg)
            raws.append(rw)
            for (wi, w) in rw.enumerated() {
                for t in normalise(w.text) {
                    toks.append(Token(text: Array(t.utf8), string: t, start: w.start, end: w.end, seg: si, widx: wi))
                }
            }
        }
        return (toks, raws)
    }

    private static func splitGroup(_ idxs: [Int], _ you: [TimedSegment], _ counts: [Int]) -> [[Int]] {
        let total = idxs.reduce(0) { $0 + counts[$1] }
        if total <= maxGroupTokens || idxs.count < 2 { return [idxs] }
        var bestK = 1
        var bestGap: Double?
        for k in 1..<idxs.count {
            let gap = you[idxs[k]].start - you[idxs[k - 1]].end
            if bestGap == nil || gap > bestGap! { bestGap = gap; bestK = k }
        }
        return splitGroup(Array(idxs[..<bestK]), you, counts) + splitGroup(Array(idxs[bestK...]), you, counts)
    }

    /// Equal, or both at least 5 characters and one edit apart.
    private static func same(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        if a == b { return true }
        return a.count >= fuzzyMinLength && b.count >= fuzzyMinLength && levenshteinAtMostOne(a, b)
    }

    private static func levenshteinAtMostOne(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        if abs(a.count - b.count) > 1 { return false }
        if a.count == b.count {
            var diff = 0
            for k in 0..<a.count where a[k] != b[k] {
                diff += 1
                if diff > 1 { return false }
            }
            return true
        }
        let (s, l) = a.count < b.count ? (a, b) : (b, a)   // l is s with one character inserted
        var i = 0
        while i < s.count && s[i] == l[i] { i += 1 }
        return Array(s[i...]) == Array(l[(i + 1)...])
    }
}
