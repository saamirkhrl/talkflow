import Foundation

// Bounded live updates (LONG-HOLD-SPEC.md A9), run from `--streamtest`. Pure.
enum LongHoldChecks {
    private static func count(_ seconds: Double) -> Int { Int((seconds * 16000).rounded()) }
    private static func tone(_ seconds: Double, _ amp: Int16) -> [Int16] {
        (0..<count(seconds)).map { $0 % 2 == 0 ? amp : -amp }
    }
    private static func speech(_ seconds: Double) -> [Int16] { tone(seconds, 3000) }
    private static func silence(_ seconds: Double) -> [Int16] { [Int16](repeating: 0, count: count(seconds)) }

    static func run(_ report: (Bool, String, String) -> Void) {
        func check(_ ok: Bool, _ label: String, _ detail: String = "") { report(ok, label, detail) }
        func cut(_ s: [Int16], force: Bool) -> (offset: Int, reason: String)? {
            HoldAudio.findCutWithReason(s[...], force: force)
        }
        func show(_ c: (offset: Int, reason: String)?) -> String { c.map { "\($0.offset) \($0.reason)" } ?? "nil" }

        // LH1-LH8: where to cut.
        let lh1 = speech(7) + silence(0.5) + speech(3.5) + silence(0.4) + speech(4.6)
        let c1 = cut(lh1, force: false)
        check(c1?.offset == 179200 && c1?.reason == "cut at a pause", "LH1 cut at the later pause", show(c1))

        let lh2 = speech(14) + silence(0.5) + speech(1.5)
        check(cut(lh2, force: false) == nil, "LH2 no pause in the window, not forced -> nil", show(cut(lh2, force: false)))
        let c3 = cut(lh2, force: true)
        check(c3?.offset == 207040 && c3?.reason == "cut at the quietest point", "LH3 forced cut at the quietest point", show(c3))

        let lh4 = speech(7) + silence(0.12) + speech(2.88) + silence(0.12) + speech(10.88) + silence(0.3) + speech(1.7)
        let c4 = cut(lh4, force: true)
        check(c4?.offset == 160960 && c4?.reason == "cut at a short dip", "LH4 forced cut at the latest short dip", show(c4))
        check(cut(lh4, force: false) == nil, "LH5 a short dip is not enough when not forced", show(cut(lh4, force: false)))

        let lh6 = speech(12) + tone(0.1, 1000) + speech(10.9)
        let c6 = cut(lh6, force: true)
        check(c6?.offset == 192640, "LH6 a quiet-ish tone is found by the quietest window", show(c6))

        let lh7 = silence(23)
        let c7 = cut(lh7, force: false)
        check(c7?.offset == 208000, "LH7 all silence cuts in the middle of the window", show(c7))

        let lh8 = speech(9)
        check(cut(lh8, force: true) == nil, "LH8 the search window is empty even when forced", show(cut(lh8, force: true)))

        // LH9-LH10: frame analysis.
        let s9a = silence(2)
        let s9b = silence(1) + speech(0.02) + silence(1)
        let s9c = tone(2, 200)
        let s9d: [Int16] = []
        check(HoldAudio.isSilent(s9a[...]) && !HoldAudio.isSilent(s9b[...]) && HoldAudio.isSilent(s9c[...]) && HoldAudio.isSilent(s9d[...]),
              "LH9 isSilent: silence, one speech frame, a quiet tone, empty",
              "\(HoldAudio.isSilent(s9a[...])) \(HoldAudio.isSilent(s9b[...])) \(HoldAudio.isSilent(s9c[...])) \(HoldAudio.isSilent(s9d[...]))")
        let rms10 = HoldAudio.frameRMS(speech(0.05)[...])
        check(rms10.count == 2 && rms10.allSatisfy { abs($0 - 3000) < 0.5 }, "LH10 frameRMS of 800 samples is two frames of 3000", "\(rms10)")

        // LH11-LH15: the settled text.
        let t11 = HoldTranscript()
        check(t11.joined(tail: "Hello world.") == "Hello world." && t11.prompt(base: "P.") == "P." && !t11.hasFrozen,
              "LH11 an empty transcript passes the tail and prompt through")

        var t12 = HoldTranscript()
        t12.settle(through: 224000, text: "We shipped the build.")
        let j12a = t12.joined(tail: "and it works.")
        let j12b = t12.joined(tail: "It works.")
        let j12c = t12.joined(tail: "")
        let j12d = t12.joined(tail: "[BLANK_AUDIO]")
        check(j12a == "We shipped the build and it works." && j12b == "We shipped the build. It works."
              && j12c == "We shipped the build." && j12d == "We shipped the build." && t12.settledSamples == 224000,
              "LH12 the seam drops a cut period before a lowercase word", "\(j12a) | \(j12b) | \(j12c) | \(j12d)")
        t12.settle(through: 300000, text: "")
        check(t12.frozenRaw == "We shipped the build." && t12.chunks.count == 2 && t12.settledSamples == 300000,
              "LH13 a silent piece adds a chunk and no text", "\(t12.frozenRaw) \(t12.chunks.count) \(t12.settledSamples)")

        let words30 = (1...30).map { "w\($0)" }
        var t14 = HoldTranscript()
        t14.settle(through: 1, text: words30.joined(separator: " "))
        let expect14 = "B. " + (11...30).map { "w\($0)" }.joined(separator: " ")
        check(t14.prompt(base: "B.") == expect14, "LH14 the prompt carries the last 20 words", t14.prompt(base: "B."))

        let ten = "abcdefghij"
        var t15 = HoldTranscript()
        t15.settle(through: 1, text: Array(repeating: ten, count: 20).joined(separator: " "))
        let expect15 = "B. " + Array(repeating: ten, count: 14).joined(separator: " ")
        check(t15.prompt(base: "B.") == expect15, "LH15 the carry is trimmed to 160 characters by whole words", t15.prompt(base: "B."))

        // LH16-LH21: re-anchoring the commit point.
        func setup(_ hypothesis: String, expecting committed: String, _ label: String, _ check: (Bool, String, String) -> Void) -> StreamCommit {
            let s = StreamCommit()
            _ = s.advance(hypothesis)
            _ = s.advance(hypothesis)
            check(s.committed == committed, "\(label) setup reaches the stated committed text", s.committed)
            return s
        }

        let s16 = setup("Hello there. How are you", expecting: "Hello there. How are", "LH16", check)
        let r16 = s16.rebase(onto: "Hello there. How are you doing today")
        _ = s16.advance("Hello there. How are you doing today and")
        check(r16 && s16.committed == "Hello there. How are you doing today", "LH16 rebase keeps the commit point and the next commit continues", "\(r16) \(s16.committed)")

        let s17 = setup("I will see you to morrow at noon", expecting: "I will see you to morrow at", "LH17", check)
        let r17 = s17.rebase(onto: "I will see you tomorrow at noon for lunch")
        _ = s17.advance("I will see you tomorrow at noon for lunch today")
        check(r17 && s17.committed == "I will see you to morrow at noon for lunch", "LH17 a merged word does not repeat the word before it", "\(r17) \(s17.committed)")

        let s18 = setup("Call me any time soon", expecting: "Call me any time", "LH18", check)
        let r18 = s18.rebase(onto: "Call me anytime tomorrow please")
        _ = s18.advance("Call me anytime tomorrow please now")
        check(r18 && s18.committed == "Call me any time tomorrow please", "LH18 a split word is re-anchored by content", "\(r18) \(s18.committed)")

        let s19 = setup("one two three four five six", expecting: "one two three four five", "LH19", check)
        let r19a = s19.rebase(onto: "one two three")
        let r19b = s19.rebase(onto: "one two three four five six")
        _ = s19.advance("one two three four five six seven")
        check(!r19a && r19b && s19.committed == "one two three four five six", "LH19 an unconfirmed rebase waits for the next hypothesis", "\(r19a) \(r19b) \(s19.committed)")

        let s20a = StreamCommit()
        let r20a = s20a.rebase(onto: "anything here")
        let s20b = setup("one two three four five six", expecting: "one two three four five", "LH20", check)
        let r20b = s20b.rebase(onto: "one two three", force: true)
        check(r20a && s20a.committed.isEmpty && r20b, "LH20 nothing committed rebases at once; force accepts the best guess", "\(r20a) \(r20b)")

        let s21 = setup("a b c d", expecting: "a b c", "LH21", check)
        let r21 = s21.rebase(onto: "a b x c d")
        _ = s21.advance("a b x c d e")
        check(r21 && s21.committed == "a b c d", "LH21 an inserted word before the commit point is skipped", "\(r21) \(s21.committed)")

        // LH22: thresholds.
        check(HoldSession.settleSearchAfter == 15 && HoldSession.forceCutAfter == 22
              && Int(14.99 * 16000) < Int(HoldSession.settleSearchAfter * 16000),
              "LH22 a tail under 15 s never searches for a cut")

        releaseWithoutCaller(check)
    }

    private final class ArraySource: HoldAudioSource {
        let all: [Int16]
        init(_ all: [Int16]) { self.all = all }
        var sampleCount: Int { all.count }
        func samples(from start: Int, to end: Int) -> [Int16] {
            let lo = max(0, min(start, all.count)), hi = max(lo, min(end, all.count))
            return Array(all[lo..<hi])
        }
    }

    private final class ReadyEngine: EngineGate {
        var isReady: Bool { true }
        func whenReady(timeout: TimeInterval, _ done: @escaping (Bool) -> Void) { done(true) }
        func requestFailed() {}
    }

    /// LH23-LH24: Dictation drops its reference to the session the moment the key comes up, then waits
    /// for `finish`. The release must still answer (it used to capture the session weakly, return
    /// without answering, and leave the pill on screen), and the session must be freed afterwards.
    /// Main thread: spins the main run loop for the async hops.
    private static func releaseWithoutCaller(_ check: (Bool, String, String) -> Void) {
        var answer: String??
        weak var released: HoldSession?
        let transcribe: HoldSession.Transcribe = { _, _, _, _, _, done in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                done(Transcriber.Result(text: "hello there", elapsed: 0.01))
            }
        }
        do {
            let session = HoldSession(source: ArraySource(speech(3)),
                                      config: .init(smallURL: URL(string: "http://127.0.0.1:9/inference")!),
                                      engine: ReadyEngine(), prompt: { "" }, transcribe: transcribe)
            released = session
            session.freeze()
            session.finish(route: .small) { result, _ in answer = .some(result?.text) }
        }
        let deadline = Date().addingTimeInterval(3)
        while answer == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        let text = answer.flatMap { $0 } ?? ""
        check(text.contains("hello there"), "LH23 the release answers after the caller lets go of the session",
              String(describing: answer))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        check(released == nil, "LH24 the session is freed once it has answered", released == nil ? "" : "still alive")
    }
}
