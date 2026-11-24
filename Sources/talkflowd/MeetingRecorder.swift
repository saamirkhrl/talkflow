import AppKit
import AVFoundation
import CaptureRing
import CoreAudio
import Foundation

// The real meeting capture: the microphone (AVAudioEngine) and the sound this Mac plays (a Core Audio process tap,
// SystemAudioTap.swift) written as two 16 kHz WAVs on one shared clock.
//
// Threading:
// - main: the MeetingRecorder API, CaptureSession.levels(), ComputerAudioWatch, meter smoothing. Never a Core Audio
//   control call; never waits on the HAL except the bounded wait in shutdown().
// - MeetingRecorder.controlQueue (serial, shared by all sessions): every AVAudioEngine and HAL create, start, stop
//   and destroy, listener add and remove, SystemAudioTap and MicTrack state. It may block: a pending permission
//   prompt stalled HAL calls for 30-60 s in the capture spike.
// - the tap's listener queue: Core Audio property listener blocks, which only hop to controlQueue.
// - the IOProc thread (real time): IOContext.process only.
// - the system consumer Thread: ring reading, Resampler, the system TrackSink.
// - micQueue (per session): the mic TrackSink. The AVAudioEngine tap thread converts and hands chunks to it.
// - watchQueue (1 s timer): disk check, write-failure check, mic stall restart, the othersPlaying refresh trigger.
// - probeQueue: othersPlaying() HAL reads, kept off watchQueue because they may stall during a prompt.
// All shared mutable state lives in one SharedCounters; the IOProc never touches it.

private func log(_ s: String) { print("talkflowd: capture: \(s)") }

/// Why a meeting recording never disturbs dictation's Recorder: each AVAudioEngine is its own Core Audio client of
/// the input device and the HAL hands every client its own copy of the input. Neither engine turns on voice
/// processing (it changes the shared device's gain and ducks other audio, so it is never used here), neither changes
/// the device's sample rate or format (both tap at the hardware format and convert in software), and the
/// computer-audio side only adds a private aggregate device (invisible to other apps, never the default) over a
/// process tap that leaves talkflow's own process out. Every meeting control call runs on controlQueue, so a stalled
/// permission prompt never blocks the main thread that dictation's hotkey runs on. Measured in the capture spike:
/// talkflowd --rectest passed twice (2.99 s of 3.00 s each) while the spike recorded the microphone and the tap, and
/// the spike's mic track had no gap at those moments; --capturetest with --rectest repeats that check.
final class MeetingRecorder: MeetingCapture {
    static let controlQueue = DispatchQueue(label: "talkflow.capture.control", qos: .userInitiated)
    let includeMic: Bool
    private var session: CaptureSession?
    private var cachedMicName = ""

    init(includeMic: Bool = true) { self.includeMic = includeMic }

    var unavailableReason: String? {
        guard #available(macOS 14.2, *) else { return NotesLogic.unsupportedMessage(ProcessInfo.processInfo.operatingSystemVersion) }
        guard includeMic else { return nil }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {   // reading the status never prompts
        case .denied, .restricted:
            return "talkflow isn't allowed to use the microphone. Turn it on in System Settings > Privacy & Security > Microphone, then try again."
        default:
            break
        }
        if AVCaptureDevice.default(for: .audio) == nil { return "No microphone is connected. Connect one, then try again." }
        return nil
    }

    var microphoneName: String {
        session != nil ? cachedMicName : (includeMic ? AVCaptureDevice.default(for: .audio)?.localizedName ?? "" : "")
    }

    var isRecording: Bool { session != nil }

    func start(into folder: URL) throws {
        guard session == nil else { throw NotesError(message: "A meeting is already recording.") }
        if let reason = unavailableReason { throw NotesError(message: reason) }
        guard DiskRule.canStart(free: DiskRule.freeBytes(at: folder)) else {
            throw NotesError(message: "Your Mac is almost out of disk space. Free up some space, then try again.")
        }
        cachedMicName = includeMic ? AVCaptureDevice.default(for: .audio)?.localizedName ?? "" : ""
        let s = try CaptureSession(folder: folder, includeMic: includeMic)
        s.begin()
        session = s
        log("recording started (microphone \(includeMic ? "on" : "off"))")
    }

    func levels() -> CaptureLevels { session?.levels() ?? CaptureLevels() }

    func stop() -> Double {
        guard let s = session else { return 0 }
        session = nil
        return s.shutdown()
    }
}

// MARK: - Shared state

enum AutoStopReason: String { case diskFull, writeFailed }

struct CaptureCounters {
    var stopping = false
    var paused = false                 // asleep
    var startCompletedAt: Double?      // CaptureClock seconds when begin()'s control block finished
    var micGeneration = 0              // bumped on every mic (re)start/stop; a tap only counts while its own is current
    var micChunks = 0
    var micPeak: Float = 0             // since the last levels() poll
    var lastMicArrival: Double = 0     // CaptureClock seconds of the last mic buffer
    var lastMicRestart: Double = 0
    var micUnavailable = false         // the microphone could not (re)start
    var micSamples: Int64 = 0
    var sysChunks = 0
    var sysSecondsDelta = 0.0          // since the last poll
    var sysNonZeroDelta = 0            // since the last poll
    var sysPeak: Float = 0             // since the last poll
    var sysSamples: Int64 = 0
    var systemAudioFailed = false      // creating the tap/aggregate failed (a real error: without permission every call still succeeds)
    var othersPlaying = false
    var probeBusy = false
    var writeFailure: Int32?           // first errno from either writer
    var autoStopped: AutoStopReason?
    var routes: [CaptureSessionInfo.RouteEntry] = []
    var systemAudioMode: String?
    var lastStatus: ComputerAudioStatus = .starting
}

/// System-track writers that missed their stop deadline, by recording folder. The pipeline waits on one before
/// reading (off the main thread), so shutdown never blocks the main thread longer than today.
enum CaptureSettle {
    enum Result: Equatable { case settled, abandoned }
    private static let lock = NSLock()
    private static var writers: [String: SettlingWriter] = [:]

    static func register(folder: URL, writer: SettlingWriter) {
        lock.lock()
        writers[folder.standardizedFileURL.path] = writer
        lock.unlock()
    }

    /// The 10 s default is on top of the 1 s stop deadline: a writer that has not finished a last 10 ms drain by
    /// then is stuck, so it is fenced off and the track is read as it is.
    static func waitForSystemTrack(folder: URL, timeout: Double = 10) -> Result {
        lock.lock()
        let writer = writers.removeValue(forKey: folder.standardizedFileURL.path)
        lock.unlock()
        guard let writer else { return .settled }
        if writer.waitSettled(timeout: timeout) { return .settled }
        writer.abandon()
        return .abandoned
    }
}

final class SharedCounters {
    private let lock = NSLock()
    private var c = CaptureCounters()

    @discardableResult
    func with<T>(_ body: (inout CaptureCounters) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&c)
    }
}

/// Owns the C ring; destroyed only when the last holder (session, consumer, or an IOContext still referenced by an
/// IOProc whose stop got stuck) lets go, so the real-time thread can never write into freed memory.
final class RingBox {
    let ptr: OpaquePointer
    init?(bytes: Int) {
        guard let p = cap_ring_create(bytes) else { return nil }
        ptr = p
    }
    deinit { cap_ring_destroy(ptr) }
}

// MARK: - Microphone track

/// The microphone through its own AVAudioEngine. The engine's lifecycle runs on MeetingRecorder.controlQueue.
final class MicTrack {
    private let sink: TrackSink
    private let micQueue: DispatchQueue
    private let counters: SharedCounters
    private var engine: AVAudioEngine?
    private var observer: NSObjectProtocol?

    init(sink: TrackSink, micQueue: DispatchQueue, counters: SharedCounters) {
        self.sink = sink
        self.micQueue = micQueue
        self.counters = counters
    }

    func start() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw NotesError(message: "No microphone is available.") }
        guard let out = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: format, to: out) else {
            throw NotesError(message: "talkflow couldn't use the microphone.")
        }
        let gen = counters.with { c -> Int in
            c.micGeneration += 1
            return c.micGeneration
        }
        let sink = self.sink, micQueue = self.micQueue, counters = self.counters, rate = format.sampleRate
        // 4800 frames = 100 ms at 48 kHz (capture spike: 100.00 ms median cadence on the built-in mic).
        input.installTap(onBus: 0, bufferSize: 4800, format: format) { buffer, when in
            // AVAudioEngine calls taps on its own thread, not the HAL's real-time IO thread, so converting, allocating and
            // a short lock are fine here (dictation's Recorder does the same).
            let arrival = CaptureClock.nowSeconds()
            let start = when.isHostTimeValid ? CaptureClock.seconds(when.hostTime) : arrival
            let frames = Int(buffer.frameLength)
            var peak: Float = 0
            if let data = buffer.floatChannelData {
                for c in 0..<Int(buffer.format.channelCount) {
                    for i in 0..<frames {
                        let a = data[c][i].magnitude
                        if a > peak { peak = a }
                    }
                }
            }
            var pcm: [Int16] = []
            let capacity = AVAudioFrameCount(Double(frames) * 16000 / rate) + 32
            if let outBuf = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: capacity) {
                var error: NSError?
                var supplied = false
                converter.convert(to: outBuf, error: &error) { _, status in
                    // Handing the same buffer over twice makes the converter emit it twice (see Recorder).
                    if supplied {
                        status.pointee = .noDataNow
                        return nil
                    }
                    supplied = true
                    status.pointee = .haveData
                    return buffer
                }
                if error == nil, let d = outBuf.int16ChannelData, outBuf.frameLength > 0 {
                    pcm = Array(UnsafeBufferPointer(start: d[0], count: Int(outBuf.frameLength)))
                }
            }
            let current = counters.with { c -> Bool in
                guard c.micGeneration == gen, !c.stopping else { return false }
                c.micChunks += 1
                c.micPeak = max(c.micPeak, peak)
                c.lastMicArrival = arrival
                return true
            }
            guard current else { return }
            micQueue.async {
                guard !sink.writer.isFinished else { return }
                let ok = sink.push(pcm, hostSeconds: start, nativeFrames: frames, nativeRate: rate)
                let written = sink.writer.samplesWritten
                let failure = sink.writer.failure
                counters.with { c in
                    c.micSamples = written
                    if !ok && c.writeFailure == nil { c.writeFailure = failure ?? EIO }
                }
            }
        }
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                          queue: nil) { [weak self] _ in
            MeetingRecorder.controlQueue.async { self?.restart(reason: "mic-changed") }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            if let o = observer { NotificationCenter.default.removeObserver(o) }
            observer = nil
            throw NotesError(message: "talkflow couldn't use the microphone.")
        }
        self.engine = engine
    }

    func stop() {
        if let o = observer { NotificationCenter.default.removeObserver(o) }
        observer = nil
        guard let engine else { return }
        self.engine = nil
        counters.with { $0.micGeneration += 1 }   // late buffers from this engine are ignored
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// The gap is padded by the TrackSink (same sink; up to 5 s) or becomes a segment.
    func restart(reason: String) {
        guard !counters.with({ $0.stopping || $0.paused }) else { return }
        stop()
        counters.with { $0.lastMicRestart = CaptureClock.nowSeconds() }
        let sink = self.sink
        micQueue.async { sink.event(reason, hostSeconds: CaptureClock.nowSeconds()) }
        do {
            try start()
            counters.with { $0.micUnavailable = false }
        } catch {
            counters.with { $0.micUnavailable = true }
            log("microphone unavailable after \(reason)")
        }
    }

    func pauseForSleep() {
        stop()
        // After stop() returns no more tap buffers arrive, and the serial queue keeps order.
        let sink = self.sink
        micQueue.async { sink.markBreak() }
    }

    func resumeAfterSleep() {
        do {
            try start()
            counters.with { $0.micUnavailable = false }
        } catch {
            counters.with { $0.micUnavailable = true }
        }
        // So the stall check does not fire at once.
        counters.with { $0.lastMicArrival = CaptureClock.nowSeconds() }
    }
}

// MARK: - One recording

final class CaptureSession {
    static let ringBytes = 1 << 22        // 4 MB, about 21 s of 48 kHz mono chunks (capture spike: 0 overruns)
    static let micFirstBufferWait = 1.0   // capture spike: first mic buffer after 118 ms
    static let controlStopTimeout = 1.5   // a pending prompt stalled AudioDeviceStop for over 60 s (capture spike)
    static let consumerStopTimeout = 1.0
    static let micStallAfter = 2.0        // the mic delivers every 100 ms; 20 missed buffers means it stopped
    static let micRetryEvery = 5.0
    static let diskCheckEvery = 5         // watchdog ticks (1 s each)

    let folder: URL
    let hostStart: Double
    let wallStart: Date
    private let counters = SharedCounters()
    private let micQueue = DispatchQueue(label: "talkflow.capture.mic")
    private let watchQueue = DispatchQueue(label: "talkflow.capture.watch")
    private let probeQueue = DispatchQueue(label: "talkflow.capture.probe")
    private let micSink: TrackSink
    private let sysSink: TrackSink
    private let mic: MicTrack?
    private let ring: RingBox
    private let consumer: SystemConsumer
    private var tap: AnyObject?            // SystemAudioTap; controlQueue only
    private var watchdog: DispatchSourceTimer?
    private var ticks = 0                  // watchQueue only
    private var sleepObservers: [NSObjectProtocol] = []
    private var watch = ComputerAudioWatch()   // main only
    private var youShown = 0.0, othersShown = 0.0   // main only
    private let shutdownLock = NSLock()
    private var result: Double?            // under shutdownLock

    init(folder: URL, includeMic: Bool) throws {
        self.folder = folder
        hostStart = CaptureClock.nowSeconds()
        wallStart = Date()
        let micWav = try StreamingWav(url: folder.appendingPathComponent(CaptureFolder.mic))
        let sysWav = try StreamingWav(url: folder.appendingPathComponent(CaptureFolder.system))
        let micTimeline = try TrackTimeline(url: folder.appendingPathComponent(CaptureFolder.micTimeline))
        let sysTimeline = try TrackTimeline(url: folder.appendingPathComponent(CaptureFolder.systemTimeline))
        micSink = TrackSink(writer: micWav, timeline: micTimeline)
        sysSink = TrackSink(writer: sysWav, timeline: sysTimeline)
        guard let ring = RingBox(bytes: Self.ringBytes) else { throw NotesError(message: "talkflow couldn't start recording.") }
        self.ring = ring
        consumer = SystemConsumer(ring: ring, sink: sysSink, counters: counters)
        mic = includeMic ? MicTrack(sink: micSink, micQueue: micQueue, counters: counters) : nil
        // Rewritten at stop with the routes and sample counts.
        try? CaptureSessionInfo(started: wallStart, hostStart: hostStart, routes: [], systemAudioMode: nil).write(to: folder)
    }

    /// Main thread. Returns at once; the audio system starts on controlQueue.
    func begin() {
        consumer.start()
        let center = NSWorkspace.shared.notificationCenter
        sleepObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            counters.with { $0.paused = true }
            MeetingRecorder.controlQueue.async {
                if #available(macOS 14.2, *) { (self.tap as? SystemAudioTap)?.pause() }
                self.mic?.pauseForSleep()
            }
            log("asleep: recording paused")
        })
        sleepObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            // Mic first, then the tap, as at start.
            MeetingRecorder.controlQueue.async {
                self.mic?.resumeAfterSleep()
                if #available(macOS 14.2, *) { (self.tap as? SystemAudioTap)?.resume() }
                self.counters.with { $0.paused = false }
            }
            log("awake: recording resumed")
        })

        let timer = DispatchSource.makeTimerSource(queue: watchQueue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.watchTick() }
        watchdog = timer
        timer.resume()

        MeetingRecorder.controlQueue.async { [self] in
            guard !counters.with({ $0.stopping }) else { return }
            if let mic {
                do { try mic.start() } catch {
                    counters.with { $0.micUnavailable = true }
                    log("microphone could not start")
                }
                // capture spike trap 4: the mic starts first and its first buffer is awaited before the aggregate device
                // opens, so a Bluetooth headset settles in the right mode.
                let deadline = CaptureClock.nowSeconds() + Self.micFirstBufferWait
                while counters.with({ $0.micChunks == 0 && !$0.stopping && !$0.micUnavailable }) && CaptureClock.nowSeconds() < deadline {
                    usleep(10_000)
                }
            }
            guard !counters.with({ $0.stopping }) else { return }
            if #available(macOS 14.2, *) {
                let t = SystemAudioTap(ring: ring, consumer: consumer, counters: counters, hostStart: hostStart)
                tap = t
                do { try t.start() } catch { counters.with { $0.systemAudioFailed = true } }
            } else {
                counters.with { $0.systemAudioFailed = true }
            }
            counters.with { $0.startCompletedAt = CaptureClock.nowSeconds() }
        }
    }

    /// watchQueue, once a second.
    private func watchTick() {
        let now = CaptureClock.nowSeconds()
        let s = counters.with { $0 }   // a copy
        guard !s.stopping, s.autoStopped == nil else { return }
        if let e = s.writeFailure {
            autoStop([ENOSPC, EDQUOT, EFBIG].contains(e) ? .diskFull : .writeFailed)
            return
        }
        ticks += 1
        if ticks % Self.diskCheckEvery == 0, DiskRule.mustStop(free: DiskRule.freeBytes(at: folder)) {
            autoStop(.diskFull)
            return
        }
        if let mic, !s.paused, let started = s.startCompletedAt,
           now - max(s.lastMicArrival, started) > Self.micStallAfter, now - s.lastMicRestart > Self.micRetryEvery {
            counters.with { $0.lastMicRestart = now }
            MeetingRecorder.controlQueue.async { mic.restart(reason: "mic-stalled") }
        }
        if #available(macOS 14.0, *), !s.probeBusy {
            counters.with { $0.probeBusy = true }
            probeQueue.async { [counters] in
                let p = CA.othersPlaying()
                counters.with {
                    $0.othersPlaying = p
                    $0.probeBusy = false
                }
            }
        }
    }

    private func autoStop(_ r: AutoStopReason) {
        counters.with { if $0.autoStopped == nil { $0.autoStopped = r } }
        log("stopped by itself: \(r.rawValue)")
        _ = shutdown()
    }

    /// Main thread, about ten times a second.
    func levels() -> CaptureLevels {
        let now = CaptureClock.nowSeconds()
        let s = counters.with { c -> CaptureCounters in
            let copy = c
            c.micPeak = 0
            c.sysPeak = 0
            c.sysSecondsDelta = 0
            c.sysNonZeroDelta = 0
            return copy
        }
        watch.update(audioSeconds: s.sysSecondsDelta, nonZeroSamples: s.sysNonZeroDelta, othersPlaying: s.othersPlaying)
        let callbacks = s.sysChunks + Int(cap_ring_dropped(ring.ptr))
        var status = watch.status(startCompleted: s.startCompletedAt != nil, sinceStartRequested: now - hostStart,
                                  sinceStartCompleted: now - (s.startCompletedAt ?? now), callbacks: callbacks)
        if s.systemAudioFailed && status != .receiving { status = .starting }   // a real error, shown as `problem` instead of a permission hint
        if status != s.lastStatus {
            counters.with { $0.lastStatus = status }
            log("computer audio: \(status.rawValue)")
        }
        youShown = Self.smooth(youShown, MeterScale.value(peak: s.micPeak))
        othersShown = Self.smooth(othersShown, MeterScale.value(peak: s.sysPeak))
        // The pipeline's echo stage runs whenever the recording was not on headphones throughout (LocalNotesPipeline),
        // so the hint follows the current route.
        var l = CaptureLevels(elapsed: now - hostStart, you: mic == nil ? 0 : youShown, others: othersShown,
                              noComputerAudio: ComputerAudioWatch.noComputerAudio(status), echoHandlingActive: OutputRoute.echoHandlingActive(routes: s.routes.map { $0.route }, hasMic: mic != nil))
        l.computerAudio = status
        l.problem = problem(s, now: now)
        l.stoppedByItself = s.autoStopped != nil
        return l
    }

    /// Rises at once, falls over about 1.5 s at ten polls a second.
    static func smooth(_ shown: Double, _ target: Double) -> Double {
        target >= shown ? target : max(target, shown - 0.06)
    }

    private func problem(_ s: CaptureCounters, now: Double) -> String? {
        switch s.autoStopped {
        case .diskFull?:
            return "Your Mac is almost out of disk space, so talkflow stopped recording. What was recorded is kept."
        case .writeFailed?:
            return "talkflow couldn't keep writing the recording, so it stopped. What was recorded is kept."
        case nil:
            break
        }
        if mic != nil, !s.paused {
            var stalled = false
            if let started = s.startCompletedAt { stalled = now - max(s.lastMicArrival, started) > Self.micStallAfter }
            if s.micUnavailable || stalled {
                return "The microphone stopped. talkflow is still recording the sound from this Mac and picks the microphone up again when it's back."
            }
        }
        if s.systemAudioFailed {
            return "talkflow couldn't start recording the sound from this Mac. Your microphone is still being recorded."
        }
        return nil
    }

    /// Any thread; idempotent. Returns the seconds recorded.
    func shutdown() -> Double {
        shutdownLock.lock()
        defer { shutdownLock.unlock() }
        if let r = result { return r }
        counters.with { $0.stopping = true }
        watchdog?.cancel()
        watchdog = nil
        for o in sleepObservers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        sleepObservers = []
        // Every Core Audio stop runs on the control queue. A pending permission prompt stalled AudioDeviceStop for over
        // 60 s in the capture spike, so this waits a bounded time and then abandons a stuck stop: its objects stay with the
        // process (as Recorder does with a hung engine) and the files are closed anyway. The queue is serial, so a start
        // still in progress finishes first and is then torn down by this block.
        let stopped = DispatchSemaphore(value: 0)
        MeetingRecorder.controlQueue.async { [self] in
            if #available(macOS 14.2, *) { (tap as? SystemAudioTap)?.stop() }
            mic?.stop()
            stopped.signal()
        }
        if stopped.wait(timeout: .now() + Self.controlStopTimeout) != .success {
            log("audio system did not stop within \(Self.controlStopTimeout) s; closing the files without waiting")
        }
        if consumer.stop(timeout: Self.consumerStopTimeout) {
            sysSink.writer.finish()
            sysSink.timeline?.close()
        } else if consumer.handOver() {
            CaptureSettle.register(folder: folder, writer: consumer)
            log("system writer missed its stop deadline; it finishes the file itself and the notes wait for it")
        } else {
            // The thread ended between the timeout and the hand-over, so nobody else will finish the file.
            sysSink.writer.finish()
            sysSink.timeline?.close()
        }
        micQueue.sync {
            micSink.writer.finish()
            micSink.timeline?.close()
        }
        let s = counters.with { $0 }
        let micSamples = micSink.writer.samplesWritten, sysSamples = sysSink.writer.samplesWritten
        var info = CaptureSessionInfo(started: wallStart, hostStart: hostStart, routes: s.routes, systemAudioMode: s.systemAudioMode)
        info.micSamples = micSamples
        info.systemSamples = sysSamples
        info.finalComputerAudio = s.lastStatus.rawValue
        try? info.write(to: folder)
        let longest = max(micSamples, sysSamples)
        let duration = longest > 0 ? Double(longest) / 16000 : CaptureClock.nowSeconds() - hostStart
        log(String(format: "stopped: you %.1f s, others %.1f s, %ld system chunks, %llu dropped, computer audio %@",
                   Double(micSamples) / 16000, Double(sysSamples) / 16000, s.sysChunks, cap_ring_dropped(ring.ptr),
                   s.lastStatus.rawValue))
        result = duration
        return duration
    }
}
