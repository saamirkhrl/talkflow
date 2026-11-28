import Foundation

// The live engine's on-demand lifecycle (LONG-HOLD-SPEC.md B6), run from `--streamtest`. Pure.
enum LiveEngineChecks {
    private typealias L = EngineLifecycle

    private static func t(_ x: TimeInterval) -> Date { Date(timeIntervalSinceReferenceDate: x) }

    private static func fresh(canStop: Bool = true) -> L { L(now: t(0), canStop: canStop, idleTimeout: 120) }

    static func run(_ check: (Bool, String, String) -> Void) {
        // LE1-LE6: one hold, the idle stop, and a hold that arrives while it stops.
        var l = fresh()
        var e = l.handle(.acquire, now: t(0))
        check(l.state == .starting && e == [.cancelIdle, .start] && l.leases == 1,
              "LE1 acquire on an unknown engine starts it", "\(l.state) \(e) leases \(l.leases)")

        e = l.handle(.startFinished(up: true), now: t(0.65))
        check(l.state == .ready && e == [.flushWaiters(true)], "LE2 start finished: ready, waiters told", "\(l.state) \(e)")

        e = l.handle(.release, now: t(10))
        check(l.state == .ready && e == [.scheduleIdle(at: t(130))] && l.leases == 0,
              "LE3 release schedules the idle stop 120 s after the last use", "\(l.state) \(e) leases \(l.leases)")

        e = l.handle(.idleTimerFired, now: t(130))
        check(l.state == .stopping && e == [.stop], "LE4 idle timer at the deadline stops it", "\(l.state) \(e)")

        e = l.handle(.acquire, now: t(130.2))
        check(l.state == .stopping && e == [.cancelIdle] && l.restartWanted,
              "LE5 acquire while stopping asks for a restart", "\(l.state) \(e) restartWanted \(l.restartWanted)")

        e = l.handle(.stopFinished, now: t(130.5))
        check(l.state == .starting && e == [.start] && !l.restartWanted,
              "LE6 stop finished with a restart wanted starts again", "\(l.state) \(e) restartWanted \(l.restartWanted)")

        // LE7: a hold during the idle wait pushes the deadline out.
        l = fresh()
        _ = l.handle(.launchProbe(running: true, responding: true), now: t(0))
        _ = l.handle(.acquire, now: t(50))
        _ = l.handle(.release, now: t(60))
        e = l.handle(.idleTimerFired, now: t(120))
        check(l.state == .ready && e == [.scheduleIdle(at: t(180))],
              "LE7 a timer for an old deadline re-arms for the new one", "\(l.state) \(e)")

        // LE8: an engine that cannot be stopped is never stopped.
        l = fresh(canStop: false)
        e = l.handle(.launchProbe(running: true, responding: true), now: t(0))
        let e8 = l.handle(.idleTimerFired, now: t(500))
        check(e.isEmpty && e8.isEmpty && l.state == .ready,
              "LE8 canStop false: no idle timer, no stop", "\(e) \(e8) \(l.state)")

        // LE9: wake from sleep.
        l = fresh()
        _ = l.handle(.launchProbe(running: true, responding: true), now: t(0))
        let w1 = l.handle(.wake, now: t(60))
        let w1State = l.state
        let w2 = l.handle(.wake, now: t(500))
        check(w1 == [.scheduleIdle(at: t(120))] && w1State == .ready && l.state == .stopping && w2 == [.stop],
              "LE9 wake: early re-arms, past the deadline stops", "\(w1) \(w1State) \(w2) \(l.state)")

        // LE10: a start that fails, then another hold.
        l = fresh()
        _ = l.handle(.acquire, now: t(0))
        e = l.handle(.startFinished(up: false), now: t(1))
        let failedState = l.state
        let failedEffects = e
        e = l.handle(.acquire, now: t(2))
        check(failedState == .stopped && failedEffects == [.flushWaiters(false)] && l.state == .starting && e == [.cancelIdle, .start],
              "LE10 failed start: stopped, waiters told, the next acquire starts again", "\(failedState) \(failedEffects) \(l.state) \(e)")

        // LE11: the launch probe.
        l = fresh()
        e = l.handle(.launchProbe(running: false, responding: false), now: t(0))
        let stoppedState = l.state
        let stoppedEffects = e
        l = fresh()
        e = l.handle(.launchProbe(running: true, responding: false), now: t(0))
        check(stoppedState == .stopped && stoppedEffects.isEmpty && l.state == .starting && e == [.start],
              "LE11 launch probe: neither -> stopped, running but silent -> starting", "\(stoppedState) \(stoppedEffects) \(l.state) \(e)")

        // LE12: a failed request while a hold is out.
        l = fresh()
        _ = l.handle(.launchProbe(running: true, responding: true), now: t(0))
        _ = l.handle(.acquire, now: t(1))
        let p12 = l.handle(.requestFailed, now: t(2))
        e = l.handle(.probeResult(responding: false), now: t(2.5))
        check(p12 == [.probe] && l.state == .starting && e == [.start],
              "LE12 failed request, probe silent, lease out: start again", "\(p12) \(l.state) \(e)")

        // LE13: a failed request with no hold; a probe that answers.
        l = fresh()
        _ = l.handle(.launchProbe(running: true, responding: true), now: t(0))
        let p13 = l.handle(.requestFailed, now: t(1))
        e = l.handle(.probeResult(responding: false), now: t(1.5))
        let s13 = l.state
        let e13 = e
        l = fresh()
        _ = l.handle(.launchProbe(running: true, responding: true), now: t(0))
        e = l.handle(.probeResult(responding: true), now: t(1))
        check(p13 == [.probe] && s13 == .stopped && e13.isEmpty && l.state == .ready && e.isEmpty,
              "LE13 probe silent, no lease: stopped; probe answers: stays ready", "\(p13) \(s13) \(e13) \(l.state) \(e)")

        // LE14: the agent was reloaded.
        l = fresh()
        _ = l.handle(.launchProbe(running: true, responding: true), now: t(0))
        e = l.handle(.agentReloaded, now: t(1))
        let s14 = l.state
        let e14 = e
        l = fresh()
        _ = l.handle(.launchProbe(running: true, responding: true), now: t(0))
        _ = l.handle(.acquire, now: t(1))
        e = l.handle(.agentReloaded, now: t(2))
        check(s14 == .stopped && e14 == [.cancelIdle] && l.state == .starting && e == [.start],
              "LE14 agent reloaded: stopped, or started again when a lease is out", "\(s14) \(e14) \(l.state) \(e)")

        // LE15: a release nobody asked for.
        l = fresh()
        e = l.handle(.release, now: t(0))
        check(l.leases == 0 && e.isEmpty && l.state == .unknown, "LE15 release without a lease stays at zero", "leases \(l.leases) \(e) \(l.state)")

        // LE16: the setup step started it.
        l = fresh()
        _ = l.handle(.launchProbe(running: false, responding: false), now: t(0))
        e = l.handle(.externallyStarted, now: t(5))
        check(l.state == .ready && e == [.flushWaiters(true), .scheduleIdle(at: t(125))],
              "LE16 externally started: ready, idle timer from then", "\(l.state) \(e)")

        // LE17: a start result nobody is waiting for.
        l = fresh()
        e = l.handle(.startFinished(up: true), now: t(0))
        check(e.isEmpty && l.state == .unknown, "LE17 a stale start result is ignored", "\(e) \(l.state)")

        // LE18-LE20: the plist rewrite.
        let on = SpeechEngine.onDemand(["Label": "x", "KeepAlive": true, "RunAtLoad": true, "ProgramArguments": ["a"]])
        check(on?["KeepAlive"] as? Bool == false && on?["RunAtLoad"] as? Bool == false
              && on?["Label"] as? String == "x" && on?["ProgramArguments"] as? [String] == ["a"],
              "LE18 onDemand turns both off and keeps the rest", "\(String(describing: on))")

        let none1 = SpeechEngine.onDemand(["KeepAlive": false, "RunAtLoad": false])
        let none2 = SpeechEngine.onDemand(["Label": "x"])
        check(none1 == nil && none2 == nil, "LE19 onDemand leaves an on-demand plist alone", "\(String(describing: none1)) \(String(describing: none2))")

        let dict = SpeechEngine.onDemand(["KeepAlive": ["SuccessfulExit": false]])
        check(dict?["KeepAlive"] as? Bool == false && dict?["RunAtLoad"] == nil,
              "LE20 onDemand turns a KeepAlive dictionary off and adds no RunAtLoad", "\(String(describing: dict))")

        // LE21: a lease ends once.
        var count = 0
        let lease = EngineLease { count += 1 }
        lease.end()
        lease.end()
        check(count == 1, "LE21 a lease's end() runs its closure once", "count \(count)")
    }
}
