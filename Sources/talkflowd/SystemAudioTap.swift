import AVFoundation
import CaptureRing
import CoreAudio
import Foundation

// The computer-audio track: a Core Audio process tap (everything this Mac plays except talkflow itself) inside a
// private aggregate device, whose IOProc writes into a lock-free ring that a normal thread drains to a 16 kHz WAV.
// Threading (see MeetingRecorder): every HAL call here runs on MeetingRecorder.controlQueue; the IOProc runs on a
// real-time thread and only touches its IOContext; the SystemConsumer thread is the only reader of the ring.

private func log(_ s: String) { print("talkflowd: capture: \(s)") }

// MARK: - IOProc context

/// Everything the IOProc touches. Created per IOProc; captured strongly by the IOProc block, so the HAL keeps it
/// (and the ring) alive until the IOProc is destroyed, even if a stuck stop means it never is.
final class IOContext {
    /// capture spike: the tap delivers 512 frames per callback (10.667 ms at 48 kHz); 32x headroom.
    static let maxFrames = 16384
    let ring: RingBox
    let rate: Double
    private let mono: UnsafeMutablePointer<Float>

    init(ring: RingBox, rate: Double) {
        self.ring = ring
        self.rate = rate
        mono = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxFrames)
        mono.initialize(repeating: 0, count: Self.maxFrames)
    }

    deinit { mono.deallocate() }

    /// Real-time thread. Downmixes to mono, counts exact-zero samples and the peak, and publishes one chunk.
    /// No locks, allocation, logging or dispatch: a dropped chunk (ring full) only bumps a C atomic counter.
    @inline(__always)
    func process(_ inNow: UnsafePointer<AudioTimeStamp>, _ inInputData: UnsafePointer<AudioBufferList>,
                 _ inInputTime: UnsafePointer<AudioTimeStamp>) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
        let buffers = abl.count
        guard buffers > 0 else { return }
        var frames = 0
        var nonZero: UInt32 = 0
        var peak: Float = 0
        if buffers == 1 {
            // Interleaved (the measured case: Float32 stereo interleaved).
            guard let d = abl[0].mData else { return }
            let ch = Swift.max(1, Int(abl[0].mNumberChannels))
            frames = Swift.min(Self.maxFrames, Int(abl[0].mDataByteSize) / (4 * ch))
            let p = d.assumingMemoryBound(to: Float.self)
            let scale = 1 / Float(ch)
            var i = 0
            while i < frames {
                var sum: Float = 0
                var c = 0
                while c < ch {
                    let v = p[i * ch + c]
                    if v.bitPattern != 0 { nonZero &+= 1 }
                    let a = v.magnitude
                    if a > peak { peak = a }
                    sum += v
                    c += 1
                }
                mono[i] = sum * scale
                i += 1
            }
        } else {
            // Non-interleaved: one mono buffer per channel.
            frames = Swift.min(Self.maxFrames, Int(abl[0].mDataByteSize) / 4)
            var i = 0
            while i < frames { mono[i] = 0; i += 1 }
            var b = 0
            while b < buffers {
                if let d = abl[b].mData {
                    let p = d.assumingMemoryBound(to: Float.self)
                    let n = Swift.min(frames, Int(abl[b].mDataByteSize) / 4)
                    var j = 0
                    while j < n {
                        let v = p[j]
                        if v.bitPattern != 0 { nonZero &+= 1 }
                        let a = v.magnitude
                        if a > peak { peak = a }
                        mono[j] += v
                        j += 1
                    }
                }
                b += 1
            }
            let scale = 1 / Float(buffers)
            i = 0
            while i < frames { mono[i] *= scale; i += 1 }
        }
        var h = cap_chunk_header()
        h.hostTime = inInputTime.pointee.mHostTime
        h.nowHost = inNow.pointee.mHostTime
        h.sampleTime = inInputTime.pointee.mSampleTime
        h.rate = rate
        h.frames = UInt32(frames)
        h.nonZero = nonZero
        h.peak = peak
        h.flags = inInputTime.pointee.mFlags.rawValue
        _ = cap_ring_write2(ring.ptr, &h, MemoryLayout<cap_chunk_header>.size, mono, frames * 4)
    }
}

// MARK: - Ring consumer

/// A system-track writer that missed its stop deadline: the notes pipeline waits for it, or fences it off.
protocol SettlingWriter: AnyObject {
    func waitSettled(timeout: Double) -> Bool
    func abandon()
}

/// The only reader of the ring and the only user of the system TrackSink.
final class SystemConsumer: SettlingWriter {
    private let ring: RingBox
    private let sink: TrackSink
    private let counters: SharedCounters
    private let scratch: UnsafeMutablePointer<Float>   // IOContext.maxFrames, consumer thread only
    private var resampler: Resampler?
    private let lock = NSLock()
    private var running = false
    private var breakAfter: Double?                    // CaptureClock seconds; the first chunk starting at or after it begins a new segment
    private var events: [(String, Double)] = []
    private let done = DispatchSemaphore(value: 0)
    private var started = false
    // Why a second lock: shutdown may give up waiting for this thread (stop timed out). `abandoned` lets the notes
    // pipeline fence the files off, so every sink write holds writeLock and checks it.
    private let writeLock = NSLock()
    private var abandoned = false                      // under lock; read by writers while they hold writeLock
    private var finishOnExit = false                   // under lock
    private var exited = false                         // under lock
    private let settled = DispatchSemaphore(value: 0)

    init(ring: RingBox, sink: TrackSink, counters: SharedCounters) {
        self.ring = ring
        self.sink = sink
        self.counters = counters
        scratch = UnsafeMutablePointer<Float>.allocate(capacity: IOContext.maxFrames)
        scratch.initialize(repeating: 0, count: IOContext.maxFrames)
    }

    deinit { scratch.deallocate() }

    func start() {
        lock.lock()
        running = true
        started = true
        lock.unlock()
        let t = Thread { [self] in loop() }
        t.name = "talkflow.capture.system"
        t.qualityOfService = .userInitiated
        t.start()
    }

    func markBreak(after host: Double) {
        lock.lock()
        breakAfter = host
        lock.unlock()
    }

    func event(_ what: String) {
        lock.lock()
        events.append((what, CaptureClock.nowSeconds()))
        lock.unlock()
    }

    /// Ends the thread after one last drain. False if it did not end in time (then the caller must not touch the sink).
    func stop(timeout: Double) -> Bool {
        lock.lock()
        let wasStarted = started
        running = false
        lock.unlock()
        if !wasStarted { return true }
        return done.wait(timeout: .now() + timeout) == .success
    }

    /// Called by shutdown after stop() timed out. True means this thread now finishes the file itself when it ends;
    /// false means it ended in between and the caller finishes the file.
    func handOver() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if exited { return false }
        finishOnExit = true
        return true
    }

    /// After it returns no write is in progress and none starts, so the file cannot change while it is read; the
    /// track may be cut short.
    /// A write stuck in the kernel would hold writeLock forever, so the wait for an in-flight write is bounded (2 s)
    /// and the pipeline thread can never hang here; the flag alone still stops every later write.
    func abandon() {
        lock.lock()
        abandoned = true
        lock.unlock()
        if writeLock.lock(before: Date().addingTimeInterval(2)) { writeLock.unlock() }
    }

    private var isAbandoned: Bool {
        lock.lock()
        defer { lock.unlock() }
        return abandoned
    }

    /// True once the thread has ended and finished the file. Re-signals so later calls see it settled too.
    func waitSettled(timeout: Double) -> Bool {
        let ok = settled.wait(timeout: .now() + timeout) == .success
        if ok { settled.signal() }
        return ok
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func loop() {
        // capture spike: draining every 10 ms had 0 overruns.
        while isRunning {
            drain()
            usleep(10_000)
        }
        drain()
        lock.lock()
        exited = true
        let fin = finishOnExit
        lock.unlock()
        if fin {
            writeLock.lock()
            if !isAbandoned {
                sink.writer.finish()
                sink.timeline?.close()
            }
            writeLock.unlock()
        }
        done.signal()
        settled.signal()
    }

    private func drain() {
        lock.lock()
        let pending = events
        events = []
        lock.unlock()
        for (what, host) in pending {
            writeLock.lock()
            if !isAbandoned { sink.event(what, hostSeconds: host) }
            writeLock.unlock()
        }

        let hsz = MemoryLayout<cap_chunk_header>.size
        var h = cap_chunk_header()
        var chunks = 0
        var seconds = 0.0
        var nonZero = 0
        var peak: Float = 0
        var failed = false
        while cap_ring_readable(ring.ptr) >= hsz {
            guard cap_ring_read(ring.ptr, &h, hsz) == 1 else { break }
            let n = Int(h.frames)
            guard n <= IOContext.maxFrames else { break }
            // The producer publishes header and payload in one store, so the payload is already there.
            if n > 0, cap_ring_read(ring.ptr, scratch, n * 4) != 1 { break }
            let nativeSeconds = h.rate > 0 ? Double(n) / h.rate : 0
            let start: Double
            if h.flags & AudioTimeStampFlags.hostTimeValid.rawValue != 0 {
                start = CaptureClock.seconds(h.hostTime)
            } else {
                start = CaptureClock.seconds(h.nowHost) - nativeSeconds
            }
            lock.lock()
            var breakNow = false
            if let b = breakAfter, start >= b {
                breakAfter = nil
                breakNow = true
            }
            lock.unlock()
            if breakNow {
                writeLock.lock()
                if !isAbandoned { sink.markBreak() }
                writeLock.unlock()
            }
            if resampler == nil || resampler!.inputRate != h.rate { resampler = Resampler(inputRate: h.rate) }
            let pcm = resampler?.convert(scratch, count: n) ?? []
            // The ring is still consumed when abandoned, so the producer never backs up.
            writeLock.lock()
            if !isAbandoned, !sink.writer.isFinished, !sink.push(pcm, hostSeconds: start, nativeFrames: n, nativeRate: h.rate) {
                failed = true
            }
            writeLock.unlock()
            chunks += 1
            seconds += nativeSeconds
            nonZero += Int(h.nonZero)
            peak = max(peak, h.peak)
        }
        if chunks > 0 || failed {
            let sink = self.sink
            counters.with { c in
                c.sysChunks += chunks
                c.sysSecondsDelta += seconds
                c.sysNonZeroDelta += nonZero
                c.sysPeak = max(c.sysPeak, peak)
                c.sysSamples = sink.writer.samplesWritten
                if failed && c.writeFailure == nil { c.writeFailure = sink.writer.failure ?? EIO }
            }
        }
    }
}

// MARK: - Process tap

/// The process tap and its private aggregate device. Every method runs on MeetingRecorder.controlQueue.
@available(macOS 14.2, *)
final class SystemAudioTap {
    private let ring: RingBox
    private let consumer: SystemConsumer
    private let counters: SharedCounters
    private let hostStart: Double
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private let tapUUID = UUID()
    private var tapRate = 0.0
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var outputDevice = AudioObjectID(kAudioObjectUnknown)
    private var outputUID: String?
    private var listeners: [CAListener] = []
    private var aliveListener: CAListener?
    private let listenerQueue = DispatchQueue(label: "talkflow.capture.listeners")
    private var active = false
    private var paused = false

    init(ring: RingBox, consumer: SystemConsumer, counters: SharedCounters, hostStart: Double) {
        self.ring = ring
        self.consumer = consumer
        self.counters = counters
        self.hostStart = hostStart
    }

    private static var startError: NotesError { NotesError(message: "talkflow couldn't start recording the sound from this Mac.") }

    func start() throws {
        let me = CA.processObject(pid: getpid())
        // A global tap minus our own process (the dictation sounds and nothing else of ours), private so other
        // apps never see it.
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: me == AudioObjectID(kAudioObjectUnknown) ? [] : [me])
        desc.uuid = tapUUID
        desc.name = "talkflow meeting"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted

        var newTap = AudioObjectID(kAudioObjectUnknown)
        let st = AudioHardwareCreateProcessTap(desc, &newTap)
        guard st == noErr, newTap != AudioObjectID(kAudioObjectUnknown) else {
            log("creating the process tap failed (status \(st))")
            throw Self.startError
        }
        tapID = newTap

        let (fst, fmt) = CA.get(tapID, kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
        guard fst == noErr, fmt.mFormatID == kAudioFormatLinearPCM, fmt.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              fmt.mBitsPerChannel == 32, fmt.mSampleRate > 0 else {
            log("unexpected tap format (status \(fst), \(fmt.mBitsPerChannel) bits, \(fmt.mSampleRate) Hz)")
            destroyTap()
            throw Self.startError
        }
        tapRate = fmt.mSampleRate
        log("tap format \(Int(fmt.mSampleRate)) Hz, \(fmt.mChannelsPerFrame) channels")

        do {
            try buildAggregateAndStart()
        } catch {
            destroyTap()
            throw error
        }

        active = true
        // Each handler body only hands the work to the control queue.
        if let l = CAListener.add(CA.system, kAudioHardwarePropertyDefaultOutputDevice, queue: listenerQueue, { [weak self] in
            MeetingRecorder.controlQueue.async { self?.defaultOutputChanged() }
        }) { listeners.append(l) }
        if let l = CAListener.add(tapID, kAudioTapPropertyFormat, queue: listenerQueue, { [weak self] in
            MeetingRecorder.controlQueue.async { self?.tapFormatChanged() }
        }) { listeners.append(l) }
    }

    private func buildAggregateAndStart() throws {
        let out = CA.defaultOutputDevice()
        guard out != AudioObjectID(kAudioObjectUnknown), let uid = CA.deviceUID(out) else {
            throw NotesError(message: "talkflow couldn't find this Mac's sound output.")
        }
        let hasInput = CA.channelCount(out, scope: kAudioObjectPropertyScopeInput) > 0
        // An output device that also records (AirPods, a USB headset) would add its own microphone to the aggregate's
        // input, mixing it into the computer-audio track, and could switch a Bluetooth headset into its low-quality call
        // mode. For those the aggregate holds only the tap. The spike proved only the device layout (built-in speakers as
        // the main sub-device); the tap-only layout is unproven on real hardware.
        let tapOnly = hasInput
        var dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "talkflow meeting",
            kAudioAggregateDeviceUIDKey: "talkflow-meeting-" + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: tapUUID.uuidString]],
        ]
        if !tapOnly {
            dict[kAudioAggregateDeviceMainSubDeviceKey] = uid
            dict[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: uid]]
        }

        var newAgg = AudioObjectID(kAudioObjectUnknown)
        let ast = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &newAgg)
        guard ast == noErr, newAgg != AudioObjectID(kAudioObjectUnknown) else {
            log("creating the aggregate device failed (status \(ast))")
            throw Self.startError
        }

        let ctx = IOContext(ring: ring, rate: tapRate)
        var newProc: AudioDeviceIOProcID?
        // The block captures ONLY ctx, never self.
        let pst = AudioDeviceCreateIOProcIDWithBlock(&newProc, newAgg, nil) { inNow, inInputData, inInputTime, _, _ in
            ctx.process(inNow, inInputData, inInputTime)
        }
        guard pst == noErr, let proc = newProc else {
            log("creating the IOProc failed (status \(pst))")
            let dst = AudioHardwareDestroyAggregateDevice(newAgg)
            if dst != noErr { log("destroying the aggregate device returned \(dst)") }
            throw Self.startError
        }
        // Held before starting, so teardownAggregate() can undo both if the start fails.
        aggID = newAgg
        procID = proc

        // The System Audio Recording prompt appears here on first use (capture spike trap 2); it returns at once even then.
        let sst = AudioDeviceStart(newAgg, proc)
        guard sst == noErr else {
            log("starting the aggregate device failed (status \(sst))")
            teardownAggregate()
            throw Self.startError
        }

        outputDevice = out
        outputUID = uid
        let route = OutputRoute.classify(transport: CA.transportType(out), dataSource: CA.dataSource(out), hasInput: hasInput)
        let at = CaptureClock.nowSeconds() - hostStart
        counters.with {
            $0.routes.append(.init(atSeconds: at, route: route))
            $0.systemAudioMode = tapOnly ? "tapOnly" : "device"
        }
        aliveListener = CAListener.add(out, kAudioDevicePropertyDeviceIsAlive, queue: listenerQueue) { [weak self] in
            MeetingRecorder.controlQueue.async { self?.outputDied() }
        }
        log("system audio started (mode \(tapOnly ? "tapOnly" : "device"), route \(route.rawValue))")
    }

    private func teardownAggregate() {
        aliveListener?.remove()
        aliveListener = nil
        if let p = procID {
            let s1 = AudioDeviceStop(aggID, p)
            if s1 != noErr { log("AudioDeviceStop returned \(s1)") }
            let s2 = AudioDeviceDestroyIOProcID(aggID, p)
            if s2 != noErr { log("AudioDeviceDestroyIOProcID returned \(s2)") }
            procID = nil
        }
        // The IOContext goes with the IOProc's block.
        if aggID != AudioObjectID(kAudioObjectUnknown) {
            let s3 = AudioHardwareDestroyAggregateDevice(aggID)
            if s3 != noErr { log("AudioHardwareDestroyAggregateDevice returned \(s3)") }
            aggID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func destroyTap() {
        guard tapID != AudioObjectID(kAudioObjectUnknown) else { return }
        let st = AudioHardwareDestroyProcessTap(tapID)
        if st != noErr { log("AudioHardwareDestroyProcessTap returned \(st)") }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: Route changes (capture spike: a rebuild took 87.7 ms; the TrackSink pads that gap with silence so the
    // file stays on the wall clock)

    private func defaultOutputChanged() {
        guard active, !paused else { return }
        if CA.deviceUID(CA.defaultOutputDevice()) == outputUID { return }
        rebuild("output-changed")
    }

    private func outputDied() {
        guard active, !paused else { return }
        if CA.isAlive(outputDevice) { return }
        rebuild("output-gone")
    }

    private func tapFormatChanged() {
        // Not while asleep: resume() builds the aggregate, and two IOProcs must never write the one-producer ring.
        guard active, !paused else { return }
        let (st, fmt) = CA.get(tapID, kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
        guard st == noErr, fmt.mSampleRate > 0, fmt.mSampleRate != tapRate else { return }
        tapRate = fmt.mSampleRate
        rebuild("format-changed")
    }

    /// Keeps the tap and builds a new aggregate on the current default output. A later default-output change tries
    /// again if this one fails.
    private func rebuild(_ reason: String) {
        let t0 = CaptureClock.nowSeconds()
        teardownAggregate()
        do {
            try buildAggregateAndStart()
            consumer.event(reason)
        } catch {
            log("system audio could not restart after \(reason)")
        }
        log(String(format: "rebuild after %@ took %.1f ms", reason, (CaptureClock.nowSeconds() - t0) * 1000))
    }

    // MARK: Sleep

    func pause() {
        guard active, !paused else { return }
        paused = true
        teardownAggregate()
        consumer.markBreak(after: CaptureClock.nowSeconds())
        consumer.event("sleep")
    }

    func resume() {
        guard active, paused else { return }
        paused = false
        // A wake re-reads the format, which may have changed while asleep; a leftover aggregate is never kept, so only
        // one IOProc ever writes the ring.
        let (fst, fmt) = CA.get(tapID, kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
        if fst == noErr, fmt.mSampleRate > 0 { tapRate = fmt.mSampleRate }
        teardownAggregate()
        do {
            try buildAggregateAndStart()
        } catch {
            log("system audio could not restart after sleep")
        }
        consumer.event("wake")
    }

    func stop() {
        active = false
        for l in listeners { l.remove() }
        listeners = []
        teardownAggregate()
        destroyTap()
    }
}
