import Foundation

// The --fakemeeting test mode scores the note taker's transcript against the fixture's truth.json. This is a
// faithful port of the fixture's score.py (transcript part only) so the app can score without Python, and
// --notestest proves the port against score.py itself. Keep the two in step: if score.py changes, so must this.

struct FMUtterance: Equatable {
    var id: String
    var speaker: String
    var start: Double
    var end: Double
    var text: String
    var flags: [String]
}

struct FMTruth {
    static let schema = "fakemeeting-truth/1"
    var utterances: [FMUtterance]
    var duration: Double

    /// Throws a plain sentence when the file is missing, unreadable, not JSON, of another schema, or has no
    /// "utterances" array.
    static func load(_ url: URL) throws -> FMTruth {
        guard let data = try? Data(contentsOf: url) else {
            throw NotesError(message: "The truth file could not be read.")
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw NotesError(message: "The truth file is not valid JSON.")
        }
        guard (root["schema_version"] as? String) == schema else {
            throw NotesError(message: "The truth file has an unexpected schema version.")
        }
        guard let raw = root["utterances"] as? [[String: Any]] else {
            throw NotesError(message: "The truth file has no utterances.")
        }
        var out: [FMUtterance] = []
        for r in raw {
            guard let speaker = r["speaker"] as? String,
                  let start = (r["start"] as? NSNumber)?.doubleValue,
                  let end = (r["end"] as? NSNumber)?.doubleValue else {
                throw NotesError(message: "The truth file has an utterance without a speaker or times.")
            }
            out.append(FMUtterance(id: (r["id"] as? String) ?? "", speaker: speaker, start: start, end: end,
                                   text: (r["text"] as? String) ?? "", flags: (r["flags"] as? [String]) ?? []))
        }
        return FMTruth(utterances: out, duration: (root["duration_sec"] as? NSNumber)?.doubleValue ?? 0)
    }
}

struct FMTurn: Equatable {
    var speaker: String
    var start: Double
    var end: Double
    var text: String
}

struct FMWER: Equatable {
    var wer: Double?
    var s: Int
    var d: Int
    var i: Int
    var n: Int
    var hits: Int
}

struct FMSpeakerCount: Equatable {
    var correct: Int
    var wrong: Int
    var share: Double
}

struct FMScore {
    var mapping: [(label: String, mappedTo: String?)]
    var voicesFoundSystem: Int
    var voicesFoundSystemSubstantive: Int
    var persons: [String]
    var wer: [String: FMWER]
    var werOverall: Double?
    var werOverallEdits: Int
    var werOverallN: Int
    var wrongShare: Double
    var wrongCorrect: Int
    var wrongWrong: Int
    var wrongUnattributed: Int
    var wrongPerPerson: [String: FMSpeakerCount]
    var unattributedWords: Int
    var echoLeakWords: Int
    var echoLeakMatched: Int
    var farEndWords: Int
    var echoLeakRate: Double?
    var samirKeep: Double?
    var inaudibleWindows: Int
    var inventedWords: Int
    var markerPresent: Bool
}

enum FMScorer {
    private static let ones = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                               "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen",
                               "eighteen", "nineteen"]
    private static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
    private static let ordIrreg = ["one": "first", "two": "second", "three": "third", "five": "fifth",
                                   "eight": "eighth", "nine": "ninth", "twelve": "twelfth"]
    // Written as escapes so the source stays plain ASCII.
    private static let dashes = ["\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}", "\u{2015}", "\u{2212}", "-"]
    private static let equiv: [String: [String]] = [
        "ok": ["okay"], "alright": ["all", "right"], "mhm": ["mm", "hm"], "mmhmm": ["mm", "hm"],
        "mmhm": ["mm", "hm"], "hmm": ["mm", "hm"],
    ]
    private static let fillers: Set<String> = ["uh", "um", "er", "ah"]

    private static let reBrackets = try! NSRegularExpression(pattern: "\\[[^\\]]*\\]")
    private static let reParens = try! NSRegularExpression(pattern: "\\([^)]*\\)")
    private static let reThousands = try! NSRegularExpression(pattern: "(?<=\\d),(?=\\d)")
    private static let reDollars = try! NSRegularExpression(pattern: "\\$\\s*(\\d+(?:\\.\\d+)?)")
    private static let rePercent = try! NSRegularExpression(pattern: "(\\d+(?:\\.\\d+)?)\\s*%")
    private static let reToken = try! NSRegularExpression(pattern: "[a-z0-9']+")
    private static let reOrdinal = try! NSRegularExpression(pattern: "^(\\d+)(st|nd|rd|th)$")

    private static func sub(_ re: NSRegularExpression, _ s: String, _ template: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length),
                                    withTemplate: template)
    }

    static func cardinal(_ n: Int) -> String {
        if n < 20 { return ones[n] }
        if n < 100 {
            let t = n / 10, o = n % 10
            return tens[t] + (o == 0 ? "" : " " + ones[o])
        }
        if n < 1000 {
            let h = n / 100, r = n % 100
            return ones[h] + " hundred" + (r == 0 ? "" : " " + cardinal(r))
        }
        let th = n / 1000, r = n % 1000
        return cardinal(th) + " thousand" + (r == 0 ? "" : " " + cardinal(r))
    }

    static func ordinal(_ n: Int) -> String {
        var words = cardinal(n).components(separatedBy: " ")
        var last = words[words.count - 1]
        if let irregular = ordIrreg[last] {
            last = irregular
        } else if last.hasSuffix("y") {
            last = String(last.dropLast()) + "ieth"
        } else {
            last += "th"
        }
        words[words.count - 1] = last
        return words.joined(separator: " ")
    }

    static func normalise(_ text: String) -> [String] {
        var t = text.lowercased()
        for d in dashes { t = t.replacingOccurrences(of: d, with: " ") }
        t = sub(reBrackets, t, " ")
        t = sub(reParens, t, " ")
        t = sub(reThousands, t, "")
        t = sub(reDollars, t, " $1 dollars ")
        t = sub(rePercent, t, " $1 percent ")
        let ns = t as NSString
        var out: [String] = []
        for m in reToken.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
            var tok = Substring(ns.substring(with: m.range))
            while tok.first == "'" { tok = tok.dropFirst() }
            while tok.last == "'" { tok = tok.dropLast() }
            if tok.isEmpty { continue }
            let s = String(tok)
            let sns = s as NSString
            if let om = reOrdinal.firstMatch(in: s, range: NSRange(location: 0, length: sns.length)),
               let num = Int(sns.substring(with: om.range(at: 1))), num <= 999_999 {
                out.append(contentsOf: ordinal(num).components(separatedBy: " "))
                continue
            }
            if s.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let num = Int(s), num <= 999_999 {
                out.append(contentsOf: cardinal(num).components(separatedBy: " "))
                continue
            }
            if let e = equiv[s] {
                out.append(contentsOf: e)
                continue
            }
            if fillers.contains(s) { continue }
            out.append(s)
        }
        return out
    }

    static func levenshtein(_ ref: [String], _ hyp: [String]) -> (s: Int, d: Int, i: Int, hits: Int) {
        let n = ref.count, m = hyp.count
        let w = m + 1
        var dp = [Int](repeating: 0, count: (n + 1) * w)
        if n > 0 { for i in 1...n { dp[i * w] = i } }
        if m > 0 { for j in 1...m { dp[j] = j } }
        if n > 0 && m > 0 {
            for i in 1...n {
                let ri = ref[i - 1]
                for j in 1...m {
                    let cost = ri == hyp[j - 1] ? 0 : 1
                    let a = dp[(i - 1) * w + j - 1] + cost
                    let b = dp[(i - 1) * w + j] + 1
                    let c = dp[i * w + j - 1] + 1
                    dp[i * w + j] = (a <= b && a <= c) ? a : (b <= c ? b : c)
                }
            }
        }
        var i = n, j = m
        var s = 0, d = 0, ins = 0, hits = 0
        while i > 0 || j > 0 {
            if i > 0 && j > 0 {
                let same = ref[i - 1] == hyp[j - 1]
                if dp[i * w + j] == dp[(i - 1) * w + j - 1] + (same ? 0 : 1) {
                    if same { hits += 1 } else { s += 1 }
                    i -= 1
                    j -= 1
                    continue
                }
            }
            if i > 0 && dp[i * w + j] == dp[(i - 1) * w + j] + 1 {
                d += 1
                i -= 1
            } else {
                ins += 1
                j -= 1
            }
        }
        return (s, d, ins, hits)
    }

    static func personOrder(_ utts: [FMUtterance]) -> [String] {
        var seen: [String] = []
        for u in utts where !seen.contains(u.speaker) { seen.append(u.speaker) }
        if let idx = seen.firstIndex(of: "samir") {
            seen.remove(at: idx)
            seen.insert("samir", at: 0)
        }
        return seen
    }

    // Python's sort is stable; the original index is the last tie break so equal keys keep input order.
    private static func stableSorted<T>(_ a: [T], _ key: (T) -> (Double, Double)) -> [T] {
        a.enumerated().sorted { l, r in
            let kl = key(l.element), kr = key(r.element)
            if kl.0 != kr.0 { return kl.0 < kr.0 }
            if kl.1 != kr.1 { return kl.1 < kr.1 }
            return l.offset < r.offset
        }.map { $0.element }
    }

    private static func overlap(_ a0: Double, _ a1: Double, _ b0: Double, _ b1: Double) -> Double {
        max(0.0, min(a1, b1) - max(a0, b0))
    }

    private struct HypWord {
        var w: String
        var mid: Double
        var label: String
        var mapped: String?
    }

    private static func timedWords(_ text: String, _ start: Double, _ end: Double) -> [(String, Double)] {
        let ws = normalise(text)
        let n = ws.count
        if n == 0 { return [] }
        let step = (end - start) / Double(n)
        return ws.enumerated().map { ($0.element, start + (Double($0.offset) + 0.5) * step) }
    }

    private static func ratio(_ a: Int, _ b: Int) -> Double? { b > 0 ? Double(a) / Double(b) : nil }

    static func score(turns turnsIn: [FMTurn], truth: [FMUtterance], mic: String) -> FMScore {
        let utts = stableSorted(truth) { ($0.start, $0.end) }
        let turns = stableSorted(turnsIn) { ($0.start, $0.end) }
        let persons = personOrder(utts)
        let personsNoSamir = persons.filter { $0 != "samir" }

        // Speaker mapping
        var labels: [String] = []
        for t in turns where !labels.contains(t.speaker) { labels.append(t.speaker) }
        var mapping: [String: String] = [:]
        var table: [(label: String, mappedTo: String?)] = []
        for label in labels {
            if label == "You" {
                mapping[label] = "samir"
                continue
            }
            var ov: [String: Double] = [:]
            for p in personsNoSamir { ov[p] = 0.0 }
            for t in turns where t.speaker == label {
                for u in utts {
                    if u.speaker == "samir" || ov[u.speaker] == nil { continue }
                    ov[u.speaker, default: 0] += overlap(t.start, t.end, u.start, u.end)
                }
            }
            var best: String?
            var bestV = 0.0
            for p in personsNoSamir {
                if let v = ov[p], v > bestV {
                    best = p
                    bestV = v
                }
            }
            if let b = best { mapping[label] = b }
            table.append((label, best))
        }
        var sysLabels: [String: Double] = [:]
        for t in turns where t.speaker != "You" { sysLabels[t.speaker, default: 0] += t.end - t.start }

        // Inaudible windows
        let inaud = utts.filter { $0.flags.contains("inaudible") }
        let windows = inaud.map { ($0.start - 0.3, $0.end + 0.3) }
        func inWindow(_ x: Double) -> Bool { windows.contains { $0.0 <= x && x <= $0.1 } }

        // Hypothesis words
        var hyp: [HypWord] = []
        for t in turns {
            for (w, mid) in timedWords(t.text, t.start, t.end) {
                hyp.append(HypWord(w: w, mid: mid, label: t.speaker, mapped: mapping[t.speaker]))
            }
        }

        // WER
        var wer: [String: FMWER] = [:]
        var totEdits = 0, totN = 0
        var samirHitsN: (Int, Int)?
        for p in persons {
            let backchannels = utts.filter { $0.speaker == p && $0.flags.contains("backchannel") }
            var ref: [String] = []
            for u in utts where u.speaker == p && !u.flags.contains("backchannel") && !u.flags.contains("inaudible") {
                ref.append(contentsOf: normalise(u.text))
            }
            var h: [String] = []
            for x in hyp {
                if x.mapped != p || inWindow(x.mid) { continue }
                if backchannels.contains(where: { $0.start <= x.mid && x.mid <= $0.end }) { continue }
                h.append(x.w)
            }
            let (s, d, i, hits) = levenshtein(ref, h)
            let n = ref.count
            let w: Double? = n > 0 ? Double(s + d + i) / Double(n) : (h.isEmpty ? 0.0 : nil)
            wer[p] = FMWER(wer: w, s: s, d: d, i: i, n: n, hits: hits)
            totEdits += s + d + i
            totN += n
            if p == "samir" { samirHitsN = (hits, n) }
        }

        // Wrong-speaker share
        var ws: [String: (c: Int, w: Int)] = [:]
        for p in persons { ws[p] = (0, 0) }
        var unattributed = 0
        let cand = utts.filter { !$0.flags.contains("inaudible") }
        for x in hyp {
            guard let mapped = x.mapped else { continue }
            let cover = cand.filter { $0.start - 0.25 <= x.mid && x.mid <= $0.end + 0.25 }
            if cover.isEmpty {
                unattributed += 1
                continue
            }
            var cur = ws[mapped] ?? (0, 0)
            if cover.contains(where: { $0.speaker == mapped }) { cur.c += 1 } else { cur.w += 1 }
            ws[mapped] = cur
        }
        var per: [String: FMSpeakerCount] = [:]
        var tc = 0, tw = 0
        for (p, v) in ws {
            tc += v.c
            tw += v.w
            per[p] = FMSpeakerCount(correct: v.c, wrong: v.w,
                                    share: (v.c + v.w) > 0 ? Double(v.w) / Double(v.c + v.w) : 0.0)
        }

        // Echo (uses the raw label "You", not the mapped speaker)
        let samirSpans = utts.filter { $0.speaker == "samir" }.map { ($0.start - 0.3, $0.end + 0.3) }
        let others = utts.filter { $0.speaker != "samir" }
            .map { ($0.start - 0.5, $0.end + 0.5, Set(normalise($0.text))) }
        var leak = 0, matched = 0
        for x in hyp where x.label == "You" {
            if samirSpans.contains(where: { $0.0 <= x.mid && x.mid <= $0.1 }) { continue }
            leak += 1
            if others.contains(where: { $0.0 <= x.mid && x.mid <= $0.1 && $0.2.contains(x.w) }) { matched += 1 }
        }
        var farEnd = 0
        for u in utts where u.speaker != "samir" && !u.flags.contains("inaudible") {
            farEnd += normalise(u.text).count
        }

        // Inaudible verdict
        let invented = hyp.filter { inWindow($0.mid) }.count
        var marker = false
        for t in turns where windows.contains(where: { overlap(t.start, t.end, $0.0, $0.1) > 0 }) {
            let low = t.text.lowercased()
            if low.contains("inaudible") || low.contains("unintelligible") { marker = true }
        }

        return FMScore(
            mapping: table,
            voicesFoundSystem: sysLabels.count,
            voicesFoundSystemSubstantive: sysLabels.values.filter { $0 >= 5.0 }.count,
            persons: persons,
            wer: wer,
            werOverall: ratio(totEdits, totN),
            werOverallEdits: totEdits,
            werOverallN: totN,
            wrongShare: (tc + tw) > 0 ? Double(tw) / Double(tc + tw) : 0.0,
            wrongCorrect: tc,
            wrongWrong: tw,
            wrongUnattributed: unattributed,
            wrongPerPerson: per,
            unattributedWords: hyp.filter { $0.mapped == nil }.count,
            echoLeakWords: leak,
            echoLeakMatched: matched,
            farEndWords: farEnd,
            echoLeakRate: ratio(matched, farEnd),
            samirKeep: samirHitsN.flatMap { ratio($0.0, $0.1) },
            inaudibleWindows: windows.count,
            inventedWords: invented,
            markerPresent: marker)
    }

    static func perfectTurns(_ truth: [FMUtterance]) -> [FMTurn] {
        let utts = stableSorted(truth) { ($0.start, $0.end) }
        var nums = ["bob": 1, "dave": 2, "emily": 3, "lucia": 4, "jason": 5]
        var next = 6
        var turns: [FMTurn] = []
        for u in utts where !u.flags.contains("inaudible") {
            let label: String
            if u.speaker == "samir" {
                label = "You"
            } else {
                if nums[u.speaker] == nil {
                    nums[u.speaker] = next
                    next += 1
                }
                label = "Speaker \(nums[u.speaker]!)"
            }
            turns.append(FMTurn(speaker: label, start: u.start, end: u.end, text: u.text))
        }
        return turns
    }
}

/// Report lines in the same layout as score.py's format_report (transcript part only). Plain ASCII.
enum FMReport {
    private static func r4(_ x: Double?) -> String {
        guard let x else { return "None" }
        return "\((x * 10000).rounded() / 10000)"
    }

    private static func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }

    static func lines(_ s: FMScore) -> [String] {
        var out: [String] = []
        out.append("== Speaker mapping ==")
        out.append("  You -> samir")
        for m in s.mapping { out.append("  \(m.label) -> \(m.mappedTo ?? "None")") }
        out.append("  voices_found_system = \(s.voicesFoundSystem) (substantive >= 5 s: \(s.voicesFoundSystemSubstantive), expected 5)")
        out.append("")
        out.append("== WER per person (content) ==")
        for p in s.persons {
            guard let v = s.wer[p] else { continue }
            out.append("  \(pad(p, 6)) WER \(r4(v.wer))  S=\(v.s) D=\(v.d) I=\(v.i) N=\(v.n) hits=\(v.hits)")
        }
        out.append("  overall WER \(r4(s.werOverall))  (\(s.werOverallEdits) edits / \(s.werOverallN) words)")
        out.append("")
        out.append("== Wrong-speaker share ==")
        out.append("  overall \(r4(s.wrongShare))  (correct \(s.wrongCorrect), wrong \(s.wrongWrong), unattributed \(s.wrongUnattributed))")
        for p in s.persons {
            guard let v = s.wrongPerPerson[p] else { continue }
            out.append("  \(pad(p, 6)) share \(r4(v.share))  (correct \(v.correct), wrong \(v.wrong))")
        }
        out.append("")
        out.append("== Echo ==")
        out.append("  echo_leak_words=\(s.echoLeakWords) echo_leak_matched=\(s.echoLeakMatched) far_end_words=\(s.farEndWords) echo_leak_rate=\(r4(s.echoLeakRate)) samir_keep=\(r4(s.samirKeep))")
        out.append("")
        out.append("== Inaudible ==")
        let verdict = s.inventedWords == 0 ? "PASS" : "FAIL (\(s.inventedWords) invented)"
        out.append("  windows=\(s.inaudibleWindows) invented_words=\(s.inventedWords) marker_present=\(s.markerPresent ? "True" : "False") verdict: \(verdict)")
        return out
    }
}

/// Runs the fixture's score.py on a transcript and compares the integer results with the Swift port.
enum FMPython {
    /// Never /usr/bin/python3: on a Mac without developer tools it is a stub that opens an install prompt.
    static func find() -> String? {
        let candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3",
                          "/Library/Developer/CommandLineTools/usr/bin/python3",
                          "/Library/Frameworks/Python.framework/Versions/Current/bin/python3"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func run(python: String, scorePy: URL, truthJSON: URL, turns: [FMTurn], mic: String) -> [String: Any]? {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("talkflow-fmscore-\(UUID().uuidString)")
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { return nil }
        defer { try? fm.removeItem(at: dir) }
        let transcript = dir.appendingPathComponent("transcript.json")
        let outURL = dir.appendingPathComponent("out.json")
        let payload: [String: Any] = ["turns": turns.map {
            ["speaker": $0.speaker, "start": $0.start, "end": $0.end, "text": $0.text] as [String: Any]
        }]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              (try? data.write(to: transcript)) != nil else { return nil }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = ["-I", scorePy.path, transcript.path, "--truth", truthJSON.path, "--mic", mic,
                       "--json-out", outURL.path]
        // score.py prints transcript text, so neither stream may reach the app log.
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(60)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning {
            p.terminate()
            return nil
        }
        guard p.terminationStatus == 0, let out = try? Data(contentsOf: outURL) else { return nil }
        return (try? JSONSerialization.jsonObject(with: out)) as? [String: Any]
    }

    static func compare(_ s: FMScore, _ py: [String: Any]) -> [String] {
        var bad: [String] = []
        func int(_ v: Any?) -> Int? { (v as? NSNumber).map { $0.intValue } }
        func dbl(_ v: Any?) -> Double? { (v as? NSNumber).map { $0.doubleValue } }
        func isNull(_ v: Any?) -> Bool { v == nil || v is NSNull }
        func eq(_ name: String, _ a: Int, _ b: Any?) {
            if int(b) != a { bad.append("\(name) swift=\(a) python=\(int(b).map(String.init) ?? "null")") }
        }
        func near(_ name: String, _ a: Double?, _ b: Any?) {
            switch (a, isNull(b) ? nil : dbl(b)) {
            case (nil, nil): return
            case let (x?, y?) where abs(x - y) <= 1e-4: return
            default: bad.append("\(name) swift=\(a.map { "\($0)" } ?? "null") python=\(isNull(b) ? "null" : "\(dbl(b) ?? .nan)")")
            }
        }

        let pyWer = py["wer"] as? [String: Any] ?? [:]
        for p in s.persons {
            guard let v = s.wer[p], let r = pyWer[p] as? [String: Any] else {
                bad.append("wer person \(p) missing")
                continue
            }
            eq("wer.\(p).S", v.s, r["S"])
            eq("wer.\(p).D", v.d, r["D"])
            eq("wer.\(p).I", v.i, r["I"])
            eq("wer.\(p).N", v.n, r["N"])
            eq("wer.\(p).hits", v.hits, r["hits"])
            if (v.wer == nil) != isNull(r["wer"]) { bad.append("wer.\(p) null-ness differs") }
        }
        eq("wer_overall_edits", s.werOverallEdits, py["wer_overall_edits"])
        eq("wer_overall_N", s.werOverallN, py["wer_overall_N"])
        eq("voices_found_system", s.voicesFoundSystem, py["voices_found_system"])
        eq("voices_found_system_substantive", s.voicesFoundSystemSubstantive, py["voices_found_system_substantive"])

        let w = py["wrong_speaker"] as? [String: Any] ?? [:]
        eq("wrong_speaker.correct", s.wrongCorrect, w["correct"])
        eq("wrong_speaker.wrong", s.wrongWrong, w["wrong"])
        eq("wrong_speaker.unattributed", s.wrongUnattributed, w["unattributed"])
        let pyPer = w["per_person"] as? [String: Any] ?? [:]
        for p in s.persons {
            guard let v = s.wrongPerPerson[p], let r = pyPer[p] as? [String: Any] else {
                bad.append("wrong_speaker.per_person \(p) missing")
                continue
            }
            eq("wrong_speaker.\(p).correct", v.correct, r["correct"])
            eq("wrong_speaker.\(p).wrong", v.wrong, r["wrong"])
        }
        eq("unattributed_words", s.unattributedWords, py["unattributed_words"])

        let e = py["echo"] as? [String: Any] ?? [:]
        eq("echo_leak_words", s.echoLeakWords, e["echo_leak_words"])
        eq("echo_leak_matched", s.echoLeakMatched, e["echo_leak_matched"])
        eq("far_end_words", s.farEndWords, e["far_end_words"])
        near("samir_keep", s.samirKeep, e["samir_keep"])
        near("echo_leak_rate", s.echoLeakRate, e["echo_leak_rate"])

        let i = py["inaudible"] as? [String: Any] ?? [:]
        eq("inaudible.windows", s.inaudibleWindows, i["windows"])
        eq("inaudible.invented_words", s.inventedWords, i["invented_words"])
        if (i["marker_present"] as? Bool) != s.markerPresent { bad.append("inaudible.marker_present differs") }

        let table = py["speaker_mapping"] as? [String: Any] ?? [:]
        if table.count != s.mapping.count { bad.append("speaker_mapping count swift=\(s.mapping.count) python=\(table.count)") }
        for (idx, m) in s.mapping.enumerated() {
            let row = table[m.label] as? [String: Any]
            let theirs = row?["mapped_to"] as? String
            if theirs != m.mappedTo { bad.append("speaker_mapping[\(idx)] differs") }
        }
        return bad
    }
}
