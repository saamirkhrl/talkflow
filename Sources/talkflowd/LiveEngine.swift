import AppKit
import Foundation

/// What a hold needs from the live engine (port 8178). See design-reference/LONG-HOLD-SPEC.md B3.
protocol EngineGate: AnyObject {
    var isReady: Bool { get }
    func whenReady(timeout: TimeInterval, _ done: @escaping (Bool) -> Void)
    func requestFailed()
}

/// One user of the live engine. `end()` is idempotent.
final class EngineLease {
    private var onEnd: (() -> Void)?
    init(_ end: @escaping () -> Void) { onEnd = end }
    func end() {
        let end = onEnd
        onEnd = nil
        end?()
    }
}

/// The live engine's life cycle as a pure reducer (LONG-HOLD-SPEC.md B2): it starts when a hold needs it and
/// stops after `idleTimeout` seconds with no hold. No clock, no process, no timer; `LiveEngine` runs the effects.
struct EngineLifecycle {
    enum State: Equatable { case unknown, starting, ready, stopping, stopped }
    enum Event: Equatable {
        case acquire, release
        case startFinished(up: Bool), stopFinished
        case idleTimerFired, wake
        case requestFailed, probeResult(responding: Bool)
        case agentReloaded
        case launchProbe(running: Bool, responding: Bool)
        case externallyStarted
    }
    enum Effect: Equatable { case start, stop, scheduleIdle(at: Date), cancelIdle, flushWaiters(Bool), probe }

    var state: State = .unknown
    var leases = 0
    var restartWanted = false
    var lastUse: Date
    var canStop: Bool
    var idleTimeout: TimeInterval = 120

    init(now: Date, canStop: Bool, idleTimeout: TimeInterval = 120) {
        self.lastUse = now
        self.canStop = canStop
        self.idleTimeout = idleTimeout
    }

    private var deadline: Date { lastUse.addingTimeInterval(idleTimeout) }

    private mutating func ensureStarted() -> [Effect] {
        switch state {
        case .unknown, .stopped:
            state = .starting
            return [.start]
        case .stopping:
            restartWanted = true
            return []
        case .starting, .ready:
            return []
        }
    }

    private func idleSchedule() -> [Effect] {
        if leases == 0 && canStop && (state == .ready || state == .starting) {
            return [.scheduleIdle(at: deadline)]
        }
        return []
    }

    /// Shared by the idle timer and a wake from sleep. The timer can fire a little early, so it is
    /// compared with half a second of slack, and re-armed when it is really not time yet.
    private mutating func idleCheck(now: Date) -> [Effect] {
        if leases == 0 && canStop && state == .ready {
            if now >= deadline.addingTimeInterval(-0.5) {
                state = .stopping
                return [.stop]
            }
            return [.scheduleIdle(at: deadline)]
        }
        if state == .starting { return idleSchedule() }
        return []
    }

    mutating func handle(_ event: Event, now: Date) -> [Effect] {
        switch event {
        case .acquire:
            leases += 1
            lastUse = now
            return [.cancelIdle] + ensureStarted()
        case .release:
            leases = max(0, leases - 1)
            lastUse = now
            return idleSchedule()
        case .startFinished(let up):
            guard state == .starting else { return [] }
            state = up ? .ready : .stopped
            return [.flushWaiters(up)] + (up ? idleSchedule() : [])
        case .stopFinished:
            state = .stopped
            if restartWanted || leases > 0 {
                restartWanted = false
                state = .starting
                return [.start]
            }
            return []
        case .idleTimerFired, .wake:
            return idleCheck(now: now)
        case .requestFailed:
            return state == .ready ? [.probe] : []
        case .probeResult(let responding):
            guard !responding, state == .ready else { return [] }
            state = .stopped
            if leases > 0 {
                state = .starting
                return [.start]
            }
            return []
        case .agentReloaded:
            state = .stopped
            restartWanted = false
            if leases > 0 {
                state = .starting
                return [.start]
            }
            return [.cancelIdle]
        case .launchProbe(let running, let responding):
            guard state == .unknown else { return [] }
            if responding {
                state = .ready
                lastUse = now
                return idleSchedule()
            }
            if running {
                state = .starting
                return [.start]
            }
            state = .stopped
            return []
        case .externallyStarted:
            if state == .stopping { return [] }
            state = .ready
            lastUse = now
            return [.flushWaiters(true)] + idleSchedule()
        }
    }
}

/// How the live engine is started and stopped. Every call blocks; `LiveEngine` calls them on its own queue.
protocol EngineBackend: AnyObject {
    /// Starts it if it is not running (idempotent).
    func start() throws
    /// SIGTERM.
    func stop()
    /// SIGKILL.
    func kill()
    func isRunning() -> Bool
    /// Any HTTP answer on the port.
    func isResponding() -> Bool
    var canStop: Bool { get }
}

/// The real engine: the LaunchAgent, started on demand with `launchctl kickstart` and stopped with `kill SIGTERM`.
final class LaunchAgentBackend: EngineBackend {
    static let live = LaunchAgentBackend(label: SpeechEngine.agentLabel, plistURL: SpeechEngine.agentPlistURL, port: SpeechEngine.port)

    let label: String
    let plistURL: URL
    let port: Int
    private let domain = "gui/\(getuid())"
    private var target: String { "\(domain)/\(label)" }

    init(label: String, plistURL: URL, port: Int) {
        self.label = label
        self.plistURL = plistURL
        self.port = port
    }

    func start() throws {
        if SpeechEngine.runCapturing("/bin/launchctl", ["print", target]).status != 0 {
            let loaded = SpeechEngine.runCapturing("/bin/launchctl", ["bootstrap", domain, plistURL.path])
            if loaded.status != 0 && !FileManager.default.fileExists(atPath: plistURL.path) {
                throw EngineError("The speech engine is not set up.")
            }
        }
        _ = SpeechEngine.runCapturing("/bin/launchctl", ["kickstart", target])
    }

    func stop() { _ = SpeechEngine.runCapturing("/bin/launchctl", ["kill", "SIGTERM", target]) }
    func kill() { _ = SpeechEngine.runCapturing("/bin/launchctl", ["kill", "SIGKILL", target]) }

    func isRunning() -> Bool {
        SpeechEngine.runCapturing("/bin/launchctl", ["print", target]).output.contains("state = running")
    }

    func isResponding() -> Bool { SpeechEngine.isRespondingBlocking(port: port) }

    /// Stopping a job launchd keeps alive only makes launchd start it again, and a test copy must not stop the real
    /// install's engine. Read from the file each time (it is tiny), so a migration is noticed.
    var canStop: Bool {
        guard !SpeechEngine.isTestCopy else { return false }
        guard let data = try? Data(contentsOf: plistURL),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return false }
        guard let keepAlive = plist["KeepAlive"] else { return true }
        return (keepAlive as? Bool) == false
    }
}

/// A private server process, for `--enginereplay` only.
final class ProcessBackend: EngineBackend {
    let binary: String
    let model: String
    let port: Int
    private let lock = NSLock()
    private var process: Process?

    init(binary: String, model: String, port: Int) {
        self.binary = binary
        self.model = model
        self.port = port
    }

    func start() throws {
        lock.lock(); defer { lock.unlock() }
        if process?.isRunning == true { return }
        let server = Process()
        server.executableURL = URL(fileURLWithPath: binary)
        server.arguments = Array(SpeechEngine.agentArguments(binary: binary, model: model, port: port).dropFirst())
        let logURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("talkflow-enginereplay-\(port).log")
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        if let log = try? FileHandle(forWritingTo: logURL) {
            log.truncateFile(atOffset: 0)
            server.standardOutput = log
            server.standardError = log
        }
        try server.run()
        process = server
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        process?.terminate()
    }

    func kill() {
        lock.lock(); defer { lock.unlock() }
        if let pid = process?.processIdentifier, process?.isRunning == true { _ = Foundation.kill(pid, SIGKILL) }
    }

    func isRunning() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return process?.isRunning == true
    }

    func isResponding() -> Bool { SpeechEngine.isRespondingBlocking(port: port) }

    var canStop: Bool { true }
}

/// Runs the engine's life cycle (`EngineLifecycle`) against a backend: starts it for a hold, stops it after the idle
/// timeout. All state lives on the main thread; backend calls run on one serial queue. LONG-HOLD-SPEC.md B3.
final class LiveEngine: EngineGate {
    static let shared = LiveEngine(backend: LaunchAgentBackend.live, idleTimeout: 120)

    private let backend: EngineBackend
    private let log: (String) -> Void
    private let opsQueue = DispatchQueue(label: "talkflow.liveengine.ops", qos: .utility)
    private var lifecycle: EngineLifecycle
    /// Bumped by every start, stop and reload, so a start that finishes after something newer is dropped.
    private var generation = 0
    private var idleWork: DispatchWorkItem?
    private var waiters: [(id: UUID, done: (Bool) -> Void)] = []
    private var wakeObserver: NSObjectProtocol?

    init(backend: EngineBackend, idleTimeout: TimeInterval, log: @escaping (String) -> Void = { print($0) }) {
        self.backend = backend
        self.log = log
        self.lifecycle = EngineLifecycle(now: Date(), canStop: backend.canStop, idleTimeout: idleTimeout)
    }

    var state: EngineLifecycle.State { lifecycle.state }
    var isReady: Bool { state == .ready }

    /// Runs `body` on the main thread, now when already there.
    private func onMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread { body() } else { DispatchQueue.main.async(execute: body) }
    }

    /// A hold (or anything else that needs the engine) takes a lease; the engine starts if it is not up and is not
    /// stopped while a lease is out. Main thread.
    func acquire(_ reason: String) -> EngineLease {
        handle(.acquire)
        return EngineLease { [weak self] in
            self?.onMain { self?.handle(.release) }
        }
    }

    /// Answers `done(true)` when the engine is ready, `done(false)` when it is not by `timeout`. Callers hold a lease,
    /// which is what makes it start; this only waits. Main thread.
    func whenReady(timeout: TimeInterval, _ done: @escaping (Bool) -> Void) {
        if isReady {
            done(true)
            return
        }
        let id = UUID()
        waiters.append((id, done))
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, let index = self.waiters.firstIndex(where: { $0.id == id }) else { return }
            let waiter = self.waiters.remove(at: index)
            waiter.done(false)
        }
    }

    func requestFailed() { onMain { self.handle(.requestFailed) } }

    /// At launch: finds out whether the engine is already up (a Mac that was running it before this update, or a
    /// run of talkflow that crashed) so the idle timer covers it too.
    func launch() {
        opsQueue.async { [weak self] in
            guard let self else { return }
            let running = self.backend.isRunning()
            let responding = self.backend.isResponding()
            DispatchQueue.main.async { self.handle(.launchProbe(running: running, responding: responding)) }
        }
    }

    func agentReloaded() { onMain { self.handle(.agentReloaded) } }
    func externallyStarted() { onMain { self.handle(.externallyStarted) } }

    /// A sleeping Mac does not run the idle timer, but the clock moves on, so on wake the engine is stopped if
    /// its idle time has run out.
    func installWakeObserver() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.handle(.wake) }
    }

    /// On quit: SIGTERM and go, no waiting. Does nothing for an engine that launchd keeps alive.
    func stopForQuit() {
        if backend.canStop { backend.stop() }
    }

    /// For `--enginereplay` only: pretends the last use was `seconds` earlier.
    func testBackdateLastUse(by seconds: TimeInterval) {
        lifecycle.lastUse = lifecycle.lastUse.addingTimeInterval(-seconds)
    }

    /// For `--enginereplay` only: the wake path.
    func testWake() { handle(.wake) }

    /// Background threads only (never main): acquire, wait until ready (timeout), release. Returns ready.
    static func withEngineBlocking(_ engine: LiveEngine, reason: String, timeout: TimeInterval) -> Bool {
        var lease: EngineLease?
        DispatchQueue.main.sync { lease = engine.acquire(reason) }
        let semaphore = DispatchSemaphore(value: 0)
        var ready = false
        DispatchQueue.main.async {
            engine.whenReady(timeout: timeout) { ok in
                ready = ok
                semaphore.signal()
            }
        }
        semaphore.wait()
        DispatchQueue.main.async { lease?.end() }
        return ready
    }

    // MARK: - Running the reducer's effects

    private func handle(_ event: EngineLifecycle.Event) {
        lifecycle.canStop = backend.canStop
        let effects = lifecycle.handle(event, now: Date())
        for effect in effects { run(effect) }
    }

    private func run(_ effect: EngineLifecycle.Effect) {
        switch effect {
        case .start:
            generation += 1
            let mine = generation
            opsQueue.async { [weak self] in
                guard let self else { return }
                let started = Date()
                var up = false
                do {
                    try self.backend.start()
                    let deadline = started.addingTimeInterval(30)
                    while Date() < deadline {
                        if self.backend.isResponding() { up = true; break }
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                } catch {
                    self.log("talkflowd: speech engine could not start: \(error.localizedDescription)")
                }
                let took = String(format: "%.2f", Date().timeIntervalSince(started))
                self.log(up ? "talkflowd: speech engine ready in \(took)s" : "talkflowd: speech engine did not start (\(took)s)")
                DispatchQueue.main.async {
                    if self.generation == mine { self.handle(.startFinished(up: up)) }
                }
            }
        case .stop:
            generation += 1
            let idleFor = Int(Date().timeIntervalSince(lifecycle.lastUse))
            opsQueue.async { [weak self] in
                guard let self else { return }
                self.backend.stop()
                if !self.waitUntilStopped(seconds: 3) {
                    self.backend.kill()
                    _ = self.waitUntilStopped(seconds: 1)
                }
                self.log("talkflowd: speech engine stopped after \(idleFor)s idle")
                DispatchQueue.main.async { self.handle(.stopFinished) }
            }
        case .scheduleIdle(let at):
            idleWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.handle(.idleTimerFired) }
            idleWork = work
            DispatchQueue.main.asyncAfter(wallDeadline: .now() + max(0, at.timeIntervalSinceNow), execute: work)
        case .cancelIdle:
            idleWork?.cancel()
            idleWork = nil
        case .flushWaiters(let ok):
            let pending = waiters
            waiters = []
            for waiter in pending { waiter.done(ok) }
        case .probe:
            opsQueue.async { [weak self] in
                guard let self else { return }
                let responding = self.backend.isResponding()
                DispatchQueue.main.async { self.handle(.probeResult(responding: responding)) }
            }
        }
    }

    /// Polls `isRunning` every 0.05 s. Ops queue only.
    private func waitUntilStopped(seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if !backend.isRunning() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !backend.isRunning()
    }
}
