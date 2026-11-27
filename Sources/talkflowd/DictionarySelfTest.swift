import Foundation

/// `talkflowd --dictionarytest`: the Dictionary page's word rules, on plain
/// values. Touches no UserDefaults, so it can run anywhere.
enum DictionarySelfTest {
    private static var failures = 0
    private typealias S = WordList.State

    static func run() -> Never {
        // Start clean, so a passing run can't be read out of a previous one's
        // leftovers.
        try? FileManager.default.removeItem(at: logURL)
        report("--- dictionarytest ---")

        let numbered = (1...50).map { "w\($0)" }

        let c1 = WordList.adding("Siobhan", to: S(words: [], added: []))
        check(c1 == S(words: ["Siobhan"], added: ["Siobhan"]), "1 adding to an empty list", "\(c1)")

        let c2 = WordList.adding("Kharel", to: S(words: ["Siobhan"], added: []))
        check(c2.words == ["Kharel", "Siobhan"] && c2.added == ["Kharel"], "2 new word goes on top", "\(c2)")

        let c3 = WordList.adding("  Vercel \n", to: S(words: [], added: []))
        check(c3.words == ["Vercel"], "3 spaces and newline trimmed", "\(c3.words)")

        let c4 = WordList.adding("\u{00A0}Zo\u{00EB}\u{00A0}", to: S(words: [], added: []))
        check(c4.words == ["Zo\u{00EB}"], "4 no-break spaces trimmed, accent kept", "\(c4.words)")

        let c5 = WordList.adding("New York", to: S(words: [], added: []))
        check(c5.words == ["New York"], "5 inner space kept", "\(c5.words)")

        let s = S(words: ["a"], added: ["a"])
        let c6 = WordList.adding("", to: s)
        check(c6 == s, "6 empty is ignored", "\(c6)")

        let c7 = WordList.adding("   \n\t", to: s)
        check(c7 == s, "7 whitespace only is ignored", "\(c7)")

        let c8 = WordList.adding("samir", to: S(words: ["talkflow", "Samir", "Vercel"], added: []))
        check(c8.words == ["samir", "talkflow", "Vercel"] && c8.added == ["samir"],
              "8 other case replaces, typed spelling kept, on top", "\(c8)")

        let c9 = WordList.adding("Samir", to: S(words: ["A1", "Samir"], added: ["Samir"]))
        check(c9.words == ["Samir", "A1"] && c9.added == ["Samir"], "9 existing word moves to top, no duplicate", "\(c9)")

        let c10 = WordList.adding("new", to: S(words: numbered, added: []))
        check(c10.words.count == 50 && c10.words.first == "new" && c10.words.last == "w49" && !c10.words.contains("w50"),
              "10 at the limit the oldest goes", "count \(c10.words.count) first \(c10.words.first ?? "nil") last \(c10.words.last ?? "nil")")

        let c11 = WordList.adding("W50", to: S(words: numbered, added: []))
        check(c11.words.count == 50 && c11.words.first == "W50" && !c11.words.contains("w50") && c11.words.last == "w49",
              "11 at the limit a re-cased word is not a new one but still cut", "count \(c11.words.count) first \(c11.words.first ?? "nil") last \(c11.words.last ?? "nil")")

        let c12 = WordList.adding("c", to: S(words: ["a", "b"], added: []), limit: 2)
        check(c12.words == ["c", "a"], "12 custom limit", "\(c12.words)")

        let c13 = WordList.adding("c", to: S(words: ["a", "b"], added: ["b"]), limit: 2)
        check(c13.words == ["c", "a"] && c13.added == ["c"], "13 a cut word leaves the added list", "\(c13)")

        check(Vocabulary.limit == 50 && c10.words.count == 50, "14 default limit is Vocabulary.limit (50)", "\(Vocabulary.limit)")

        let c15 = WordList.removing("Samir", from: S(words: ["talkflow", "Samir"], added: ["Samir"]))
        check(c15 == S(words: ["talkflow"], added: []), "15 removing drops it from both lists", "\(c15)")

        let c16 = WordList.removing("SAMIR", from: S(words: ["Samir"], added: []))
        check(c16.words == [], "16 removing ignores case", "\(c16.words)")

        let c17 = WordList.removing("x", from: s)
        check(c17 == s, "17 removing an unknown word changes nothing", "\(c17)")

        let labelled = S(words: ["Kharel", "talkflow"], added: ["Kharel"])
        check(WordList.isAddedByUser("kharel", in: labelled), "18 added-by-you ignores case")
        check(!WordList.isAddedByUser("talkflow", in: labelled), "19 a learned word is not added by you")

        let c20 = WordList.source(of: "talkflow", in: S(words: ["talkflow"], added: []))
        check(c20 == "Learned from a fix", "20 old data reads Learned from a fix", c20)

        let c21 = WordList.source(of: "Kharel", in: S(words: ["Kharel"], added: ["Kharel"]))
        check(c21 == "Added by you", "21 hand-added reads Added by you", c21)

        let c22 = WordList.pruned(["a", "z"], to: ["A", "b"])
        check(c22 == ["a"], "22 pruned keeps only words still listed", "\(c22)")

        let t1 = WordList.trimmed(" x ")
        let t2 = WordList.trimmed(" ")
        check(t1 == "x" && t2 == nil, "23 trimmed", "\(String(describing: t1)), \(String(describing: t2))")

        check(UserData.settingKeys.contains(WordList.addedKey) && UserData.settingKeys.contains("learnedWords"),
              "24 both word lists are in the settings backup")

        report(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
        exit(failures == 0 ? 0 : 1)
    }

    private static func check(_ condition: Bool, _ label: String, _ detail: String = "") {
        report((condition ? "ok   " : "FAIL ") + label + (condition || detail.isEmpty ? "" : " -> " + detail))
        if !condition { failures += 1 }
    }

    private static let logURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("talkflow-dictionarytest.log")

    /// stdout goes to the app log; also written next to the other self-test
    /// results so the caller can read it directly.
    private static func report(_ line: String) {
        print("talkflowd: [dictionarytest] \(line)")
        let url = logURL
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
