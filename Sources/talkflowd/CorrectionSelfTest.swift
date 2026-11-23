import Foundation

/// `talkflowd --correctiontest [dev|heldout|all|check] [text|span]` - measures the
/// model step for spoken corrections (`CorrectionModel`) on synthetic sentences.
///
/// Every case is a raw transcript, rendered with the rules first (`Dictation.render`)
/// the way a release is, so the model only ever sees what it would see in use. A
/// positive must have a marker left by the rules and an expected text that is a pure
/// deletion of the rules' output; one that does not is reported and left out of every
/// count, since it would measure the test, not the model. A negative without a marker
/// never reaches the model in the app, so it is not called here either.
///
/// `check` runs those preconditions only, with no model, and exits 0. The other sets
/// call the on-device model directly, with a 15 s cap rather than the real budget, so
/// slow answers are still measured; `over_budget` says how many the real budget would
/// have dropped. The first call of the process is the cold one and is not prewarmed.
///
/// Synthetic sentences only, so unlike the app's log this one may hold them. Results
/// go to `$TMPDIR/talkflow-correctiontest.log` as well as stdout.
enum CorrectionSelfTest {
    struct Case { let id: String; let raw: String; let expected: String? }

    static let positives: [Case] = [
        Case(id: "P01", raw: "I think we should use Postgres. Actually, you know what, SQLite is fine for this.", expected: "SQLite is fine for this."),
        Case(id: "P02", raw: "Let's take the train to Boston. Actually, no, driving will be faster.", expected: "Driving will be faster."),
        Case(id: "P03", raw: "Can you send me the slides? Wait, no, just put them in the shared folder.", expected: "Just put them in the shared folder."),
        Case(id: "P04", raw: "We should hire two more engineers. Sorry, I mean one engineer and one designer.", expected: "One engineer and one designer."),
        Case(id: "P05", raw: "I was going to write the tests first, actually, let me fix the bug and then write the tests.", expected: "Let me fix the bug and then write the tests."),
        Case(id: "P06", raw: "Tell the team the release is on Monday. No, actually, let's say it slipped to next week.", expected: "Let's say it slipped to next week."),
        Case(id: "P07", raw: "My flight lands at noon. Oh wait, it's the evening flight, so I land at eight.", expected: "It's the evening flight, so I land at eight."),
        Case(id: "P08", raw: "Put the meeting in the big conference room. Actually, let's just do it over video.", expected: "Let's just do it over video."),
        Case(id: "P09", raw: "I'll pick up pizza for dinner. Wait, no, let's order Thai instead.", expected: "Let's order Thai instead."),
        Case(id: "P10", raw: "The report is due Thursday, sorry, I mean the draft is due Thursday and the final is due Friday.", expected: "The draft is due Thursday and the final is due Friday."),
        Case(id: "P11", raw: "Use the blue logo on the homepage. Actually, you know what, the black one looks better there.", expected: "The black one looks better there."),
        Case(id: "P12", raw: "Let's ship it tonight. Wait, no, we should wait for the security review.", expected: "We should wait for the security review."),
        Case(id: "P13", raw: "I'll call you after lunch. Actually, I'll just send you an email instead.", expected: "I'll just send you an email instead."),
        Case(id: "P14", raw: "Send the invoice to Mark. Sorry, no, it goes to accounting now, not Mark.", expected: "It goes to accounting now, not Mark."),
        Case(id: "P15", raw: "We need the numbers by Friday, wait, no, the board meeting moved, so we need them tomorrow.", expected: "The board meeting moved, so we need them tomorrow."),
        Case(id: "P16", raw: "I want the header to be bigger. Actually, I mean, can we make the whole page wider instead?", expected: "Can we make the whole page wider instead?"),
        Case(id: "P17", raw: "Let's meet at the coffee shop. No wait, it's closed on Sundays, let's do the library.", expected: "It's closed on Sundays, let's do the library."),
        Case(id: "P18", raw: "Order fifty units for the launch. Actually, let's start smaller and see how it sells.", expected: "Let's start smaller and see how it sells."),
        Case(id: "P19", raw: "I'm going to rewrite the parser, actually no, I'll patch the existing one for now.", expected: "I'll patch the existing one for now."),
        Case(id: "P20", raw: "Please add Jessica to the thread. Wait, actually, she's out this week, add her manager instead.", expected: "She's out this week, add her manager instead."),
        Case(id: "P21", raw: "The demo should focus on search. Actually, no, onboarding is the bigger story.", expected: "Onboarding is the bigger story."),
        Case(id: "P22", raw: "We can store the files in S3. Actually, wait, the client wants everything on their own servers.", expected: "The client wants everything on their own servers."),
        Case(id: "P23", raw: "Move the standup to nine thirty. No, actually, let's cancel it this week.", expected: "Let's cancel it this week."),
        Case(id: "P24", raw: "I was thinking we could, I mean, maybe we just skip the offsite this year.", expected: "Maybe we just skip the offsite this year."),
        Case(id: "P25", raw: "Let's paint the office green. Actually, you know what, white is safer.", expected: "White is safer."),
        Case(id: "P26", raw: "I'll present the roadmap first. Actually, no, Priya should go first since she has to leave early.", expected: "Priya should go first since she has to leave early."),
        Case(id: "P27", raw: "Let's use React for the dashboard. Wait, actually, the team knows Vue better, so let's go with Vue.", expected: "The team knows Vue better, so let's go with Vue."),
        Case(id: "P28", raw: "Ask legal to review the contract today. Sorry, I mean ask them tomorrow, they're out today.", expected: "Ask them tomorrow, they're out today."),
        Case(id: "P29", raw: "We could launch with a big announcement. Actually, I think a quiet beta makes more sense.", expected: "I think a quiet beta makes more sense."),
        Case(id: "P30", raw: "Can you make the font smaller, no wait, actually the spacing is the problem, not the font.", expected: "The spacing is the problem, not the font."),
        Case(id: "P31", raw: "Let's put it on the blog. Actually, you know what? The newsletter is better.", expected: "The newsletter is better."),
        Case(id: "P32", raw: "Let's put it on the blog. Actually, you know what! The newsletter is better.", expected: "The newsletter is better."),
        Case(id: "P33", raw: "Let's put it on the blog. Actually, you know what. The newsletter is better.", expected: "The newsletter is better."),
    ]

    static let negatives: [Case] = [
        Case(id: "N01", raw: "That sounds good. Actually, I have one more question about the budget.", expected: nil),
        Case(id: "N02", raw: "I can't join the call, sorry. I'll catch up from the notes.", expected: nil),
        Case(id: "N03", raw: "Thanks for the update. Wait, let me check the calendar before I confirm.", expected: nil),
        Case(id: "N04", raw: "Is the build green? No, I don't think so, the tests are still running.", expected: nil),
        Case(id: "N05", raw: "I read your proposal. Actually, that sounds great.", expected: nil),
        Case(id: "N06", raw: "Hi everyone. Sorry, I was late. Let's begin.", expected: nil),
        Case(id: "N07", raw: "Honestly, I mean it, this is the best quarter we've had.", expected: nil),
        Case(id: "N08", raw: "The new design is clean. I mean, the colors are a bit loud, but overall I like it.", expected: nil),
        Case(id: "N09", raw: "We shipped the fix yesterday. Actually, it went out a day early.", expected: nil),
        Case(id: "N10", raw: "She said no, actually, which surprised everyone.", expected: nil),
        Case(id: "N11", raw: "Let me know if you need anything. Sorry for the short notice.", expected: nil),
        Case(id: "N12", raw: "The meeting went long, sorry about that. Here are the action items.", expected: nil),
        Case(id: "N13", raw: "Wait times are down this quarter. Actually, they're the lowest they've been all year.", expected: nil),
        Case(id: "N14", raw: "I don't know, I mean, it depends on the budget.", expected: nil),
        Case(id: "N15", raw: "Great work on the launch. Actually, can you share the slides with the board?", expected: nil),
        Case(id: "N16", raw: "Please don't wait, start the meeting without me.", expected: nil),
        Case(id: "N17", raw: "No worries at all. Sorry again for the mix-up with the invoice.", expected: nil),
        Case(id: "N18", raw: "I checked the logs. Actually, the error only happens on the staging server.", expected: nil)
    ]

    /// How long one call may take in the harness. Not the app's budget: slow
    /// answers are measured, then counted against `CorrectionModel.budget`.
    static let cap: TimeInterval = 15

    private static let logURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("talkflow-correctiontest.log")

    private static func report(_ line: String) {
        print(line)
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }

    /// Held-out: every case whose index within its own list is 2 mod 3.
    private static func isHeldOut(_ index: Int) -> Bool { index % 3 == 2 }

    private static func render(_ raw: String) -> String {
        Dictation.render(raw, leadingSpace: "", structure: true)
    }

    private static func pct(_ n: Int, of total: Int) -> Int {
        total == 0 ? 0 : Int((Double(n) / Double(total) * 100).rounded())
    }

    private static func seconds(_ t: TimeInterval) -> String { String(format: "%.2f", t) }

    /// Words of `rules` that are not in `delivered`, in order.
    private static func wordsLost(rules: String, delivered: String) -> String {
        let kept = SelfCorrection.tokenize(delivered).map(\.norm)
        var index = 0
        var lost: [String] = []
        for token in SelfCorrection.tokenize(rules) {
            if index < kept.count, kept[index] == token.norm { index += 1 } else { lost.append(token.word) }
        }
        return lost.joined(separator: " ")
    }

    static func run(_ arguments: [String]) -> Never {
        try? FileManager.default.removeItem(at: logURL)
        var set = "dev"
        var mode = CorrectionModel.mode
        for argument in arguments {
            if ["dev", "heldout", "all", "check"].contains(argument) { set = argument }
            else if let parsed = CorrectionModel.Mode(rawValue: argument) { mode = parsed }
        }
        CorrectionModel.mode = mode

        if set == "check" { check() }

        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *), CorrectionModel.isAvailable else {
            report("mode: \(mode.rawValue)   set: \(set)   model available: no")
            exit(2)
        }
        Task {
            await measure(set: set, mode: mode)
            exit(0)
        }
        dispatchMain()
        #else
        report("mode: \(mode.rawValue)   set: \(set)   model available: no")
        exit(2)
        #endif
    }

    /// Steps 1-3 for every case, with no model: the preconditions, the rules'
    /// output, and whether a marker is left in each negative.
    private static func check() -> Never {
        report("--- correctiontest check (no model) ---")
        var bad = 0
        for testCase in positives {
            let rules = render(testCase.raw)
            let marker = SelfCorrection.hasMarker(in: rules)
            let expected = testCase.expected ?? ""
            let ok = marker && expected != rules && SelfCorrection.isDeletionOnly(original: rules, result: expected)
            if ok { report("\(testCase.id) ok marker=y rules=\(rules)") }
            else { bad += 1; report("\(testCase.id) PRECONDITION FAIL marker=\(marker ? "y" : "n") rules=\(rules)") }
        }
        for testCase in negatives {
            let rules = render(testCase.raw)
            report("\(testCase.id) marker=\(SelfCorrection.hasMarker(in: rules) ? "y" : "n") rules=\(rules)")
        }
        report("precondition_fail=\(bad)")
        exit(0)
    }

    #if canImport(FoundationModels)
    /// One model call with the harness cap. Returns the reply or the failure
    /// category, and the seconds it took.
    @available(macOS 26.0, *)
    private static func timedAsk(_ text: String, mode: CorrectionModel.Mode) async -> (reply: String?, failure: String?, elapsed: TimeInterval) {
        let t0 = Date()
        let outcome: (String?, String?) = await withTaskGroup(of: (String?, String?).self) { group in
            group.addTask {
                do { return (try await CorrectionModel.ask(text, mode: mode), nil) }
                catch { return (nil, CorrectionModel.category(of: error)) }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(cap * 1_000_000_000))
                return (nil, "timed out after \(Int(cap))s")
            }
            let first = await group.next() ?? (nil, "error")
            group.cancelAll()
            return first
        }
        return (outcome.0, outcome.1, Date().timeIntervalSince(t0))
    }

    @available(macOS 26.0, *)
    private static func measure(set: String, mode: CorrectionModel.Mode) async {
        report("--- correctiontest \(set) \(mode.rawValue) ---")
        var calls = 0
        var coldElapsed: TimeInterval?
        var warm: [TimeInterval] = []
        var overBudget = 0
        var rejections: [String: Int] = [:]

        var pRun = 0, pHit = 0, pUnchanged = 0, pRejected = 0, pWrong = 0, pTimeout = 0, pFailed = 0, pPre = 0
        var nRun = 0, nMarker = 0, nChanged = 0, nSaved = 0

        /// One model call, with the cold/warm bookkeeping of step 5.
        func call(_ rules: String) async -> (reply: String?, failure: String?, elapsed: TimeInterval, cold: Bool) {
            let result = await timedAsk(rules, mode: mode)
            let cold = calls == 0
            calls += 1
            if cold {
                coldElapsed = result.elapsed
                CorrectionModel.prewarm()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            } else {
                warm.append(result.elapsed)
            }
            if result.elapsed > CorrectionModel.budget { overBudget += 1 }
            return (result.reply, result.failure, result.elapsed, cold)
        }

        func entries(_ list: [Case]) -> [(Int, Case)] {
            list.enumerated().filter { index, _ in
                set == "all" || (set == "heldout" ? isHeldOut(index) : !isHeldOut(index))
            }.map { ($0.offset, $0.element) }
        }
        func label(_ index: Int) -> String { isHeldOut(index) ? "held" : "dev " }
        func tag(_ elapsed: TimeInterval, _ cold: Bool) -> String { "\(seconds(elapsed))s \(cold ? "cold" : "warm")" }
        func note(_ verdict: CorrectionModel.Verdict) {
            if case .rejected(let reason) = verdict { rejections[reason.rawValue, default: 0] += 1 }
        }

        for (index, testCase) in entries(positives) {
            let rules = render(testCase.raw)
            let expected = testCase.expected ?? ""
            let marker = SelfCorrection.hasMarker(in: rules)
            guard marker, expected != rules, SelfCorrection.isDeletionOnly(original: rules, result: expected) else {
                pPre += 1
                report("\(testCase.id) PRECONDITION FAIL marker=\(marker ? "y" : "n") rules=\(rules)")
                continue
            }
            pRun += 1
            let answer = await call(rules)
            let prefix = "\(testCase.id) \(label(index)) \(tag(answer.elapsed, answer.cold))"
            guard let reply = answer.reply else {
                pFailed += 1
                report("\(prefix) FAILED(\(answer.failure ?? "error")) | rules: \(rules)")
                continue
            }
            let verdict = CorrectionModel.evaluate(original: rules, reply: reply, mode: mode)
            note(verdict)
            let over = answer.elapsed > CorrectionModel.budget
            let delivered: String
            if !over, case .applied(let text) = verdict { delivered = text } else { delivered = rules }
            let outcome: String
            switch verdict {
            case .applied(let text): outcome = text == expected ? "hit" : "wrong"
            case .unchanged: outcome = "unchanged"
            case .rejected(let reason): outcome = "rejected(\(reason.rawValue))"
            }
            let status: String
            if over {
                pTimeout += 1
                status = "MISS-TIMEOUT(would be \(outcome))"
            } else {
                switch verdict {
                case .applied(let text):
                    if text == expected { pHit += 1; status = "HIT" } else { pWrong += 1; status = "MISS-WRONG" }
                case .unchanged: pUnchanged += 1; status = "MISS-UNCHANGED"
                case .rejected(let reason): pRejected += 1; status = "MISS-REJECTED(\(reason.rawValue))"
                }
            }
            report("\(prefix) \(status) | rules: \(rules) | reply: \(reply) | got: \(delivered)")
        }

        for (index, testCase) in entries(negatives) {
            let rules = render(testCase.raw)
            nRun += 1
            guard SelfCorrection.hasMarker(in: rules) else {
                report("\(testCase.id) no marker (model not called)")
                continue
            }
            nMarker += 1
            let answer = await call(rules)
            let prefix = "\(testCase.id) \(label(index)) \(tag(answer.elapsed, answer.cold))"
            guard let reply = answer.reply else {
                report("\(prefix) FAILED(\(answer.failure ?? "error")) | rules: \(rules)")
                continue
            }
            let verdict = CorrectionModel.evaluate(original: rules, reply: reply, mode: mode)
            note(verdict)
            let over = answer.elapsed > CorrectionModel.budget
            let delivered: String
            if !over, case .applied(let text) = verdict { delivered = text } else { delivered = rules }
            let status: String
            if delivered != rules {
                nChanged += 1
                status = "CHANGED (lost: \(wordsLost(rules: rules, delivered: delivered)))"
            } else if case .rejected(let reason) = verdict {
                nSaved += 1
                status = "KEPT-REJECTED(\(reason.rawValue))"
            } else {
                status = over ? "KEPT (over budget)" : "KEPT"
            }
            report("\(prefix) \(status) | rules: \(rules) | reply: \(reply) | got: \(delivered)")
        }

        let sorted = warm.sorted()
        let median = sorted.isEmpty ? 0 : (sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2)
        let p95 = sorted.isEmpty ? 0 : sorted[max(0, Int((0.95 * Double(sorted.count)).rounded(.up)) - 1)]
        let rejectionTotal = rejections.values.reduce(0, +)
        let rejectionList = rejections.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")

        report("")
        report("mode: \(mode.rawValue)   set: \(set)   model available: yes")
        report("positives: run=\(pRun) hit=\(pHit) (\(pct(pHit, of: pRun))%) unchanged=\(pUnchanged) rejected=\(pRejected) wrong=\(pWrong) timeout=\(pTimeout) failed=\(pFailed) precondition_fail=\(pPre)")
        report("negatives: run=\(nRun) with_marker=\(nMarker) changed=\(nChanged) guard_saved=\(nSaved)")
        report("guard_rejections: \(rejectionTotal) (\(rejectionList))")
        report("latency: cold=\(coldElapsed.map(seconds) ?? "n/a") warm_median=\(seconds(median)) warm_p95=\(seconds(p95)) warm_max=\(seconds(sorted.last ?? 0)) over_budget=\(overBudget)/\(calls) budget=\(seconds(CorrectionModel.budget))")
    }
    #endif
}
