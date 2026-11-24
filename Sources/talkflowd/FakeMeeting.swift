import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

// `talkflowd --fakemeeting [folder] [--dry-run] [--fake-pipeline] [--notes-model PATH] [--speaker-helper PATH]
// [--speaker-models DIR] [--server PATH]`: records a made-up meeting for real (played
// through the Mac's speakers), writes notes through the app's real pipeline seam, then scores them against the
// truth. --dry-run plays nothing and copies the fixture's 16 kHz files in place of captured audio. Exit codes:
// 0 PASS, 1 FAIL or refused, 2 fixture missing or bad, 130 interrupted. The four path flags override what the app
// would use, so a test can run the real pipeline on test copies of the models and leave the user's models folder alone.

// MARK: - Options

struct FakeMeetingOptions: Equatable {
    var folder: URL
    var dryRun: Bool
    var fakePipeline: Bool
    var notesModel: URL?
    var speakerHelper: URL?
    var speakerModels: URL?
    var server: String?

    static let defaultFolder: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/talkflow/test-fixtures/fakemeeting", isDirectory: true)

    /// `arguments` = CommandLine.arguments. The folder is the element right after "--fakemeeting" when it exists
    /// and doesn't start with "--".
    static func parse(_ arguments: [String]) -> FakeMeetingOptions {
        var folder = defaultFolder
        if let i = arguments.firstIndex(of: "--fakemeeting"), i + 1 < arguments.count, !arguments[i + 1].hasPrefix("--") {
            folder = URL(fileURLWithPath: arguments[i + 1], isDirectory: true)
        }
        // A flag with no value, or whose next argument is another flag, counts as not given.
        func value(_ flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count, !arguments[i + 1].hasPrefix("--") else { return nil }
            return arguments[i + 1]
        }
        return FakeMeetingOptions(folder: folder, dryRun: arguments.contains("--dry-run"),
                                  fakePipeline: arguments.contains("--fake-pipeline"),
                                  notesModel: value("--notes-model").map { URL(fileURLWithPath: $0) },
                                  speakerHelper: value("--speaker-helper").map { URL(fileURLWithPath: $0) },
                                  speakerModels: value("--speaker-models").map { URL(fileURLWithPath: $0, isDirectory: true) },
                                  server: value("--server"))
    }
}

// MARK: - Pure decisions

enum FMGate: Equatable { case wait, go, refuse(String) }

enum FMPreflight {
    static let requiredFiles = ["truth.json", "system_48k.wav", "samir_48k.wav", "mic_speakers.wav", "system.wav"]

    static func missingFiles(exists: (String) -> Bool) -> [String] {
        requiredFiles.filter { !exists($0) }
    }

    static let permissionMessage = "talkflow isn't getting this Mac's sound, so it most likely isn't allowed to record it. Open System Settings > Privacy & Security > Screen & System Audio Recording and, under System Audio Recording Only, turn on talkflow (or the Terminal app you ran this from, if that is what's listed). Then run this command again."

    static func outputProblem(route: OutputRoute, deviceName: String) -> String? {
        switch route {
        case .headphones:
            return "The sound is going to headphones (\(deviceName)). This test needs the Mac's speakers, so the microphone hears the meeting through the air. Switch the sound output to the speakers, then run this again."
        case .speakers, .unknown:
            return nil
        }
    }

    static func volumeProblem(muted: Bool?, volume: Double?) -> String? {
        if muted == true {
            return "The sound is muted. Turn the volume up (this test never changes it), then run this again."
        }
        if let volume, volume <= 0.01 {
            return "The volume is at zero. Turn it up to about half (this test never changes it), then run this again."
        }
        return nil
    }

    static func volumeWarning(volume: Double?) -> String? {
        guard let volume, volume < 0.3 else { return nil }
        return "The volume is low (\(Int((volume * 100).rounded()))%). The microphone may barely hear the meeting; about half volume or more works best."
    }

    /// sinceStart = seconds since NotesModel.start().
    static func beforePlay(status: ComputerAudioStatus, sinceStart: Double) -> FMGate {
        switch status {
        case .notAuthorised, .notArriving:
            return .refuse(permissionMessage)
        case .waitingForPermission:
            return sinceStart < 120 ? .wait
                : .refuse("Nobody answered the macOS question about recording this Mac's sound within 2 minutes. " + permissionMessage)
        case .starting:
            return sinceStart < 15 ? .wait
                : .refuse("Recording this Mac's sound didn't start within 15 seconds. Run this again; if it keeps happening, restart the Mac.")
        case .nothingPlaying, .receiving:
            return sinceStart >= 1.5 ? .go : .wait
        }
    }

    /// sincePlay = seconds since playback started.
    static func afterPlay(status: ComputerAudioStatus, sincePlay: Double) -> FMGate {
        switch status {
        case .receiving: return .go
        case .notAuthorised, .notArriving: return .refuse(permissionMessage)
        default: return sincePlay < 8 ? .wait : .refuse(permissionMessage)
        }
    }
}

/// The numbers the PASS line is judged on.
struct FMOutcome: Equatable {
    var notesReady: Bool
    var audioGone: Bool
    var werOverall: Double?
    var werPerPerson: [String: Double?]   // only persons with N > 0
    var voicesSubstantive: Int
    var wrongShare: Double
    var echoLeakRate: Double?
    var samirKeep: Double?
    var invented: Int
    var writeSeconds: Double
    var meetingSeconds: Double
    var peakMB: Double
}

enum FMThresholds {
    static let werOverallMax = 0.15
    static let werPerPersonMax = 0.30
    static let voicesMin = 4, voicesMax = 6          // system voices with >= 5 s of speech; the truth has 5
    static let wrongShareMax = 0.25
    static let echoLeakRateMax = 0.05
    static let samirKeepMin = 0.85
    static let inventedMax = 2
    static let peakMBMax = 2048.0
    // writing the notes may take at most as long as the meeting itself (writeSeconds <= meetingSeconds)

    static func outcome(_ s: FMScore, notesReady: Bool, audioGone: Bool, writeSeconds: Double,
                        meetingSeconds: Double, peakMB: Double) -> FMOutcome {
        var perPerson: [String: Double?] = [:]
        for p in s.persons {
            if let w = s.wer[p], w.n > 0 { perPerson[p] = Optional(w.wer) }
        }
        return FMOutcome(notesReady: notesReady, audioGone: audioGone, werOverall: s.werOverall, werPerPerson: perPerson,
                         voicesSubstantive: s.voicesFoundSystemSubstantive, wrongShare: s.wrongShare,
                         echoLeakRate: s.echoLeakRate, samirKeep: s.samirKeep, invented: s.inventedWords,
                         writeSeconds: writeSeconds, meetingSeconds: meetingSeconds, peakMB: peakMB)
    }

    private static func pct(_ v: Double) -> String { String(format: "%.1f%%", v * 100) }
    private static func limit(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }

    /// One plain line per failed threshold, in a fixed order. Empty = PASS. Lines hold numbers and person names only.
    static func failures(_ o: FMOutcome) -> [String] {
        var out: [String] = []
        if !o.notesReady { out.append("the notes were not ready") }
        if !o.audioGone { out.append("the audio was not deleted") }
        if let w = o.werOverall {
            if w > werOverallMax { out.append("overall word error rate \(pct(w)) is over \(limit(werOverallMax))") }
        } else {
            out.append("overall word error rate could not be measured")
        }
        for name in o.werPerPerson.keys.sorted() {
            if let value = o.werPerPerson[name] {
                if let w = value {
                    if w > werPerPersonMax { out.append("\(name) word error rate \(pct(w)) is over \(limit(werPerPersonMax))") }
                } else {
                    out.append("\(name) word error rate could not be measured")
                }
            }
        }
        if o.voicesSubstantive < voicesMin || o.voicesSubstantive > voicesMax {
            out.append("\(o.voicesSubstantive) voices found on the system track, needs \(voicesMin) to \(voicesMax)")
        }
        if o.wrongShare > wrongShareMax { out.append("wrong-speaker share \(pct(o.wrongShare)) is over \(limit(wrongShareMax))") }
        if let e = o.echoLeakRate, e > echoLeakRateMax { out.append("echo leak rate \(pct(e)) is over \(limit(echoLeakRateMax))") }
        if let k = o.samirKeep {
            if k < samirKeepMin { out.append("your words kept \(pct(k)) is under \(limit(samirKeepMin))") }
        } else {
            out.append("your words kept could not be measured")
        }
        if o.invented > inventedMax { out.append("\(o.invented) invented words, allowed \(inventedMax)") }
        if o.writeSeconds > o.meetingSeconds {
            out.append(String(format: "writing took %.0f s, longer than the %.0f s meeting", o.writeSeconds, o.meetingSeconds))
        }
        if o.peakMB > peakMBMax { out.append(String(format: "peak memory %.0f MB is over %.0f MB", o.peakMB, peakMBMax)) }
        return out
    }
}

// MARK: - Stand-ins

/// --dry-run capture: copies the fixture's 16 kHz tracks into the note's audio folder, plus the timelines and
/// session.json the real capture writes, so a real pipeline reads what a recording would leave. Plays and records
/// nothing.
final class FixtureCapture: MeetingCapture {
    private let fixture: URL
    private var recording = false
    private var duration = 0.0

    init(fixture: URL) { self.fixture = fixture }

    var unavailableReason: String? { nil }
    var microphoneName: String { "fake meeting fixture" }
    var isRecording: Bool { recording }

    func start(into folder: URL) throws {
        let hostStart = CaptureClock.nowSeconds()
        let fm = FileManager.default
        var samples: [Int64] = []
        for (source, dest, timeline) in [("mic_speakers.wav", CaptureFolder.mic, CaptureFolder.micTimeline),
                                         ("system.wav", CaptureFolder.system, CaptureFolder.systemTimeline)] {
            let target = folder.appendingPathComponent(dest)
            do {
                try? fm.removeItem(at: target)
                try fm.copyItem(at: fixture.appendingPathComponent(source), to: target)
            } catch {
                throw NotesError(message: "The fake meeting files couldn't be copied.")
            }
            guard let info = WavInfo.read(target) else { throw NotesError(message: "The fake meeting files couldn't be copied.") }
            let n = (info.fileBytes - 44) / 2
            samples.append(Int64(n))
            // One line per second of audio, like the real sink's timeline.
            let tl = try TrackTimeline(url: folder.appendingPathComponent(timeline))
            for i in stride(from: 0, to: n, by: 16000) {
                tl.write(["k": "chunk", "idx": i, "host": hostStart + Double(i) / 16000])
            }
            tl.close()
        }
        let info = CaptureSessionInfo(started: Date(), hostStart: hostStart,
                                      routes: [.init(atSeconds: 0, route: .speakers)], systemAudioMode: "fixture",
                                      micSamples: samples[0], systemSamples: samples[1], finalComputerAudio: "receiving")
        do { try info.write(to: folder) } catch { throw NotesError(message: "The fake meeting files couldn't be copied.") }
        duration = Double(max(samples[0], samples[1])) / 16000
        recording = true
    }

    func levels() -> CaptureLevels {
        CaptureLevels(elapsed: duration, you: 0.5, others: 0.5, noComputerAudio: false, echoHandlingActive: false)
    }

    func stop() -> Double {
        recording = false
        return duration
    }
}

/// --fake-pipeline: hands back the truth as speech pieces after about a second, so store, NotesModel's assembly,
/// audio deletion and scoring all run without a speech engine. `offset` (seconds) is added to every time, so in a
/// live run the pieces sit on the recording's clock like a real pipeline's would.
final class TruthPipeline: NotesPipeline {
    private let turns: [FMTurn]
    var offset: Double = 0
    private var cancelled = false

    init(turns: [FMTurn]) { self.turns = turns }

    func run(audioFolder: URL, progress: @escaping (WritingProgress) -> Void,
             completion: @escaping (PipelineOutcome) -> Void) {
        cancelled = false
        let fm = FileManager.default
        let have = [CaptureFolder.mic, CaptureFolder.system].allSatisfy {
            fm.fileExists(atPath: audioFolder.appendingPathComponent($0).path)
        }
        guard have else {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.cancelled else { return }
                completion(.failed(NoteFailure(step: .transcribing, message: "No recorded audio was found.", retry: .notes)))
            }
            return
        }
        progress(WritingProgress(step: .transcribing, fraction: 0, secondsLeft: 1))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !self.cancelled else { return }
            progress(WritingProgress(step: .speakers, fraction: 0.5, secondsLeft: 0.5))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, !self.cancelled else { return }
                let off = self.offset
                let pieces = self.turns.map { t in
                    SpeechPiece(speaker: t.speaker == "You" ? NotesLogic.youKey
                                    : "spk_" + t.speaker.lowercased().replacingOccurrences(of: " ", with: "_"),
                                start: t.start + off, end: t.end + off, text: t.text)
                }
                completion(.finished(pieces: pieces, duration: (self.turns.last?.end ?? 0) + off))
            }
        }
    }

    func cancel() { cancelled = true }
}

// MARK: - Cleanup

/// Everything to undo however the run ends. Main thread, plus exit's atexit hook (which runs on the exiting thread).
private enum FMCleanup {
    static var afplay: Process?
    static var player: AVAudioPlayer?
    static var model: NotesModel?
    static var temp: URL?
    static var suiteName: String?
    static var done = false
    static var sources: [DispatchSourceSignal] = []

    /// Stops our own player and the child afplay (bounded wait, then SIGKILL). Safe to call twice.
    static func stopPlayback() {
        player?.stop()
        if let p = afplay, p.isRunning {
            p.terminate()
            let deadline = Date().addingTimeInterval(1)
            while p.isRunning && Date() < deadline { usleep(10_000) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
    }

    static func run() {
        if done { return }
        done = true
        stopPlayback()
        if let m = model {
            if m.isRecording { _ = m.capture.stop() }   // closes the files; never starts writing notes
            m.pipeline.cancel()
        }
        if let t = temp { try? FileManager.default.removeItem(at: t) }
        if let s = suiteName { UserDefaults(suiteName: s)?.removePersistentDomain(forName: s) }
    }

    static func install() {
        for s in [SIGINT, SIGTERM, SIGHUP, SIGPIPE] { signal(s, SIG_IGN) }
        for s in [SIGINT, SIGTERM, SIGHUP] {
            let src = DispatchSource.makeSignalSource(signal: s, queue: .main)
            src.setEventHandler {
                FakeMeeting.say(s == SIGINT ? "Stopped by Ctrl-C. Playback and recording stopped; temporary files deleted."
                                : "Stopped by signal \(s). Playback and recording stopped; temporary files deleted.")
                FakeMeeting.appLog("interrupted")
                run()
                exit(130)
            }
            src.resume()
            sources.append(src)
        }
        atexit { FMCleanup.run() }
    }
}

// MARK: - The run

struct FMOutputDevice {
    var name: String
    var route: OutputRoute
    var muted: Bool?
    var volume: Double?
}

enum FakeMeeting {
    private static let logURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("talkflow-fakemeeting.log")
    private static var logHandle: FileHandle?
    private static let tty: FileHandle? = FileHandle(forWritingAtPath: "/dev/tty")

    // MARK: Output

    /// To the terminal and the run's own log file. Fixture text (made up) may appear here.
    static func say(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        // The throwing write: the non-throwing one raises an exception when the terminal is gone.
        if let tty { try? tty.write(contentsOf: data) }
        if let logHandle { try? logHandle.write(contentsOf: data) }
    }

    /// For the app log: counts, durations, states and fixed category words only.
    static func appLog(_ s: String) {
        print("talkflowd: fakemeeting: \(s)")
    }

    private static func resetLog() {
        try? FileManager.default.removeItem(at: logURL)
        FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        logHandle = FileHandle(forWritingAtPath: logURL.path)
    }

    // MARK: Small helpers

    private static func now() -> Double { CaptureClock.nowSeconds() }

    /// Never sleeps on the main thread: signal handlers and NotesModel's timer need the run loop.
    private static func pump(_ seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private static func percent(_ v: Double?) -> String { v.map { String(format: "%.1f%%", $0 * 100) } ?? "n/a" }

    private static func finish(_ code: Int32) -> Never {
        FMCleanup.run()
        exit(code)
    }

    /// Says why, logs a fixed category word, undoes everything and exits 1.
    private static func refuse(_ message: String, category: String) -> Never {
        say(message)
        appLog("refused: \(category)")
        finish(1)
    }

    // MARK: Output device

    static func currentOutput() -> FMOutputDevice {
        let dev = CA.defaultOutputDevice()
        let name = CA.string(dev, kAudioObjectPropertyName) ?? "an unnamed device"
        let route = OutputRoute.classify(transport: CA.transportType(dev), dataSource: CA.dataSource(dev),
                                         hasInput: CA.channelCount(dev, scope: kAudioDevicePropertyScopeInput) > 0)
        let (mst, mv) = CA.get(dev, kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput, default: UInt32(0))
        let muted: Bool? = mst == noErr ? mv != 0 : nil
        return FMOutputDevice(name: name, route: route, muted: muted, volume: readVolume(dev))
    }

    /// Reads only; no property is ever set.
    private static func float32(_ dev: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                element: AudioObjectPropertyElement) -> Double? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
        guard AudioObjectHasProperty(dev, &addr) else { return nil }
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let st = AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v)
        return st == noErr ? Double(v) : nil
    }

    private static func readVolume(_ dev: AudioObjectID) -> Double? {
        let main = kAudioObjectPropertyElementMain
        if let v = float32(dev, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, element: main) { return v }
        if let v = float32(dev, kAudioDevicePropertyVolumeScalar, element: main) { return v }
        let sides = [float32(dev, kAudioDevicePropertyVolumeScalar, element: 1),
                     float32(dev, kAudioDevicePropertyVolumeScalar, element: 2)].compactMap { $0 }
        return sides.max()
    }

    // MARK: Playback timing

    /// Seconds (CaptureClock) when the process's sound output turned on, or nil if it did not within `timeout`.
    @available(macOS 14.0, *)
    static func waitForOutput(pid: pid_t, timeout: Double) -> Double? {
        let deadline = CaptureClock.nowSeconds() + timeout
        while CaptureClock.nowSeconds() < deadline {
            let obj = CA.processObject(pid: pid)
            if obj != AudioObjectID(kAudioObjectUnknown),
               CA.get(obj, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)).1 != 0 { return CaptureClock.nowSeconds() }
            usleep(2_000)
        }
        return nil
    }

    // MARK: The flow

    static func run(_ arguments: [String]) -> Never {
        resetLog()
        FMCleanup.install()
        // The run loop must always have a source, or RunLoop.run(until:) returns at once and the loops below spin.
        RunLoop.main.add(Timer(timeInterval: 0.25, repeats: true) { _ in }, forMode: .common)

        let o = FakeMeetingOptions.parse(arguments)
        say("--- fakemeeting (\(o.dryRun ? "dry run" : "live")), pipeline: \(o.fakePipeline ? "fake: the truth word for word" : "the app's") ---")
        let mode = o.dryRun ? "dry run" : "live"
        // Refuse before anything else when the given model is not there (same style as a missing fixture).
        if let m = o.notesModel, !FileManager.default.fileExists(atPath: m.path) {
            say("The notes model given with --notes-model is not there.")
            appLog("notes model missing")
            finish(2)
        }

        // 2. The fixture.
        let fm = FileManager.default
        let missing = FMPreflight.missingFiles { fm.fileExists(atPath: o.folder.appendingPathComponent($0).path) }
        if !missing.isEmpty {
            say("The fake meeting fixture is missing or incomplete at \(o.folder.path) (missing: \(missing.joined(separator: ", "))). Build it first (see its README.md), or pass its folder: --fakemeeting <folder>.")
            appLog("fixture missing")
            finish(2)
        }
        let truth: FMTruth
        do {
            truth = try FMTruth.load(o.folder.appendingPathComponent("truth.json"))
        } catch {
            say(error.localizedDescription)
            appLog("fixture bad: truth")
            finish(2)
        }
        for (file, rate) in [("system_48k.wav", UInt32(48000)), ("samir_48k.wav", 48000),
                             ("mic_speakers.wav", 16000), ("system.wav", 16000)] {
            guard let w = WavInfo.read(o.folder.appendingPathComponent(file)),
                  w.sampleRate == rate, w.channels == 1, w.bits == 16, w.headerMatchesFile else {
                say("The fixture audio isn't in the expected format: \(file).")
                appLog("fixture bad: audio format")
                finish(2)
            }
        }

        // 3. Live only: what playing needs.
        var useTap = false
        if !o.dryRun {
            if #available(macOS 14.2, *) { useTap = true }
            if !useTap { say("Recording a meeting needs macOS 14.2 or later."); appLog("refused: macos"); finish(1) }
            if !fm.isExecutableFile(atPath: "/usr/bin/afplay") {
                refuse("The sound player (/usr/bin/afplay) isn't available on this Mac.", category: "afplay")
            }
        }

        // 4. The output device, in both modes. A dry run says what a live run would refuse and carries on.
        let out = currentOutput()
        let volumeText = out.volume.map { "\(Int(($0 * 100).rounded()))%" } ?? "unknown"
        say("sound output: \(out.name) (\(out.route.rawValue)), volume \(volumeText)\(out.muted == true ? ", muted" : "")")
        func problem(_ message: String?, category: String) {
            guard let message else { return }
            if o.dryRun { say("would refuse: \(message)") } else { refuse(message, category: category) }
        }
        problem(FMPreflight.outputProblem(route: out.route, deviceName: out.name), category: "headphones")
        problem(FMPreflight.volumeProblem(muted: out.muted, volume: out.volume), category: out.muted == true ? "muted" : "volume")
        if let w = FMPreflight.volumeWarning(volume: out.volume) { say(w) }
        if out.route == .unknown {
            say("talkflow can't tell whether \(out.name) is speakers or headphones. This test needs speakers the microphone can hear; carrying on.")
        }

        // 5. Sandbox: a temporary notes folder and a settings suite of its own, never the user's. Registered with the
        // cleanup before anything is created.
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("talkflow-fakemeeting-\(UUID().uuidString)", isDirectory: true)
        FMCleanup.temp = temp
        let suiteName = "com.samir.talkflow.fakemeeting"
        FMCleanup.suiteName = suiteName
        do {
            try fm.createDirectory(at: temp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            say("talkflow couldn't make a temporary folder.")
            appLog("refused: temp folder")
            finish(1)
        }
        let notesRoot = temp.appendingPathComponent("notes", isDirectory: true)
        if let suite = UserDefaults(suiteName: suiteName) {
            suite.removePersistentDomain(forName: suiteName)
            Preferences.defaults = suite
        }

        // 6. Pipeline and capture. Not setting TALKFLOW_DATA_DIR: the real pipeline may need the speech model, which
        // lives outside it.
        let truthPipeline: TruthPipeline? = o.fakePipeline ? TruthPipeline(turns: FMScorer.perfectTurns(truth.utterances)) : nil
        // The same pipeline class and config the app uses, with only the file locations swapped.
        let pipeline: NotesPipeline = truthPipeline ?? LocalNotesPipeline(makeConfig: {
            var c = LocalNotesPipeline.liveConfig()
            if let m = o.notesModel { c.model = m }
            if let h = o.speakerHelper { c.speakerHelper = h }
            if let d = o.speakerModels { c.speakerModels = d }
            if let s = o.server { c.serverBinary = s }
            return c
        })
        if !o.fakePipeline {
            // File names only, so the line says what is in use without printing paths.
            let m = o.notesModel?.lastPathComponent ?? "app default"
            let h = o.speakerHelper?.lastPathComponent ?? "app default"
            let d = o.speakerModels?.lastPathComponent ?? "app default"
            let sv = o.server.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "app default"
            say("pipeline files: model \(m), speaker helper \(h), speaker models \(d), server \(sv)")
        }
        let capture: MeetingCapture = o.dryRun ? FixtureCapture(fixture: o.folder) : MeetingRecorder()
        let store = NoteStore(root: notesRoot)
        let model = NotesModel(store: store, capture: capture, pipeline: pipeline)
        model.confirmDelete = { false }
        FMCleanup.model = model

        // 7. Live only, before the recording starts: this process becomes a sound client first. The tap leaves this
        // process out, which keeps the user's own voice off the system track so it reaches only the microphone,
        // through the air.
        var player: AVAudioPlayer?
        if !o.dryRun {
            do {
                let p = try AVAudioPlayer(contentsOf: o.folder.appendingPathComponent("samir_48k.wav"))
                p.prepareToPlay()
                player = p
                FMCleanup.player = p
            } catch {
                refuse("The fake meeting's voice file couldn't be opened for playback.", category: "playback")
            }
        }

        // 8. Start recording.
        model.start()
        guard let noteID = model.session?.noteID else {
            refuse("Recording didn't start: \(model.problem ?? "no reason given")", category: "start")
        }
        let startT = now()

        // 9. Before playing.
        if o.dryRun {
            // Nothing to wait for: the fixture reports itself ready, so the 1.5 s settle time is taken as given.
            let l = model.capture.levels()
            say("computer audio gate (dry run): \(describe(FMPreflight.beforePlay(status: l.computerAudio, sinceStart: max(now() - startT, 1.5))))")
        } else {
            var announced = false
            gate: while true {
                pump(0.1)
                let l = model.capture.levels()
                if l.computerAudio == .waitingForPermission && !announced {
                    announced = true
                    say("macOS is asking whether talkflow may record this Mac's sound. Click Allow; the meeting starts right after.")
                }
                switch FMPreflight.beforePlay(status: l.computerAudio, sinceStart: now() - startT) {
                case .wait:
                    continue
                case .go:
                    if l.computerAudio == .receiving {
                        say("Note: something else is already playing sound on this Mac. Pause it for a clean result.")
                    }
                    break gate
                case .refuse(let message):
                    refuse(message, category: l.computerAudio == .starting ? "start timeout" : "permission")
                }
            }
        }

        // 10. Live: play the meeting. afplay is a different process, so the tap hears it; our own player is excluded.
        var skew = "n/a (dry run)"
        var offset = 0.0
        var ownAt = 0.0
        if !o.dryRun, let player {
            let total = Int(truth.duration.rounded())
            say("playing the meeting (\(total / 60) min \(total % 60) s) through the speakers. Ctrl-C stops it; nothing is kept.")
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            proc.arguments = ["-t", String(Int(truth.duration) + 5), o.folder.appendingPathComponent("system_48k.wav").path]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            FMCleanup.afplay = proc
            let tLaunch = now()
            do { try proc.run() } catch { refuse("The sound player couldn't start.", category: "afplay") }
            var runningAt: Double?
            if #available(macOS 14.0, *) { runningAt = waitForOutput(pid: proc.processIdentifier, timeout: 2.0) }
            player.play()
            ownAt = now()
            offset = model.capture.levels().elapsed
            truthPipeline?.offset = offset
            if let r = runningAt {
                skew = String(format: "afplay sound running %.0f ms after launch; your voice started %.0f ms after it",
                              (r - tLaunch) * 1000, (ownAt - r) * 1000)
            } else {
                skew = "afplay did not report sound within 2 s; start skew unknown"
            }
            say("start skew: \(skew)")

            // 11. After play.
            let sincePlayGate = ownAt
            after: while true {
                pump(0.1)
                let l = model.capture.levels()
                switch FMPreflight.afterPlay(status: l.computerAudio, sincePlay: now() - sincePlayGate) {
                case .wait: continue
                case .go:
                    say("this Mac's sound is arriving.")
                    break after
                case .refuse(let message): refuse(message, category: "permission")
                }
            }

            // 12. Play to the end.
            var maxYou = 0.0, maxOthers = 0.0
            var nextReport = 30.0
            var lastProblem: String?
            while true {
                pump(0.1)
                let t = now()
                // The levels NotesModel's own tick just read: levels() hands out the peak since the last call, so a
                // second reader here would see only part of the peaks.
                guard case .recording(let l)? = model.session?.phase else { break }
                maxYou = max(maxYou, l.you)
                maxOthers = max(maxOthers, l.others)
                if t - ownAt >= nextReport {
                    say(String(format: "  %@ / %@   you %.2f  others %.2f", clock(t - ownAt), clock(truth.duration), l.you, l.others))
                    nextReport += 30
                }
                if let p = l.problem, p != lastProblem { say(p); lastProblem = p }
                if t >= ownAt + truth.duration + 1.5 { break }
                if t - ownAt > 5 && !player.isPlaying && !proc.isRunning { break }
                if !model.isRecording { break }   // the capture stopped by itself
            }
            FMCleanup.stopPlayback()
            say(String(format: "peak levels: you %.2f, others %.2f", maxYou, maxOthers))
            if maxYou < 0.05 { say("warning: the microphone barely heard anything. Is the volume up and the microphone uncovered?") }
        } else {
            // 11. Dry run: the same gate on the fixture's levels.
            let l = model.capture.levels()
            say("computer audio arriving (dry run): \(describe(FMPreflight.afterPlay(status: l.computerAudio, sincePlay: 0)))")
            say("dry run: nothing is played; the fixture's 16 kHz files stand in for the recording.")
        }

        // 13. Stop and wait for the notes.
        let stopT = now()
        if model.isRecording { model.stop() }
        var lastStep: WritingStep?
        while model.session != nil {
            pump(0.2)
            if case .writing(let p)? = model.session?.phase, p.step != lastStep {
                lastStep = p.step
                say("writing notes: \(p.step.rawValue)")
            }
            if now() - stopT > 45 * 60 {
                say("RESULT: FAIL - notes were not written within 45 minutes")
                appLog("finished: 0 turns, result FAIL, writing timeout, \(mode)")
                finish(1)
            }
        }
        let writeSeconds = now() - stopT
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let peakMB = Double(usage.ru_maxrss) / 1_048_576   // bytes on macOS
        say(String(format: "peak memory (this process; helper processes not counted): %.0f MB", peakMB))

        // 14. The result.
        guard let meta = store.meta(noteID) else {
            say("RESULT: FAIL - the note could not be read back")
            appLog("finished: 0 turns, result FAIL, writing \(Int(writeSeconds)) s, \(mode)")
            finish(1)
        }
        let meetingSeconds = meta.duration > 0 ? meta.duration : truth.duration
        var outcome = FMOutcome(notesReady: false, audioGone: false, werOverall: nil, werPerPerson: [:], voicesSubstantive: 0,
                                wrongShare: 0, echoLeakRate: nil, samirKeep: nil, invented: 0, writeSeconds: writeSeconds,
                                meetingSeconds: meetingSeconds, peakMB: peakMB)
        var turnCount = 0
        let audioGone = !store.hasAudio(noteID) && !fm.fileExists(atPath: store.audioFolder(for: noteID).path)
        outcome.audioGone = audioGone
        switch meta.state {
        case .failed(let f):
            say("Writing the notes failed at \(f.step.rawValue): \(f.message)")
        case .ready:
            say("audio deleted after the notes were written: \(audioGone ? "yes" : "NO")")
            if let transcript = store.transcript(noteID) {
                let turns = transcript.turns.map {
                    FMTurn(speaker: $0.speaker == NotesLogic.youKey ? "You" : $0.speaker, start: $0.start - offset,
                           end: $0.end - offset, text: $0.text)
                }
                turnCount = turns.count
                let score = FMScorer.score(turns: turns, truth: truth.utterances, mic: "speakers")
                for line in FMReport.lines(score) { say(line) }
                outcome = FMThresholds.outcome(score, notesReady: true, audioGone: audioGone, writeSeconds: writeSeconds,
                                               meetingSeconds: meetingSeconds, peakMB: peakMB)
                summary(score, outcome: outcome, skew: skew)
                crossCheck(score, folder: o.folder, turns: turns)
            } else {
                say("The transcript could not be read back.")
            }
        default:
            say("The note was left in an unexpected state.")
        }

        // 15. The verdict.
        let failures = FMThresholds.failures(outcome)
        say("PASS needs: overall WER <= 15%, each person <= 30%, 4 to 6 system voices, wrong speaker <= 25%, echo leak <= 5%, your words kept >= 85%, invented words <= 2, writing <= meeting length, peak memory <= 2048 MB, notes ready, audio deleted")
        say(failures.isEmpty ? "RESULT: PASS" : "RESULT: FAIL - " + failures.joined(separator: "; "))
        appLog("finished: \(turnCount) turns, result \(failures.isEmpty ? "PASS" : "FAIL"), writing \(Int(writeSeconds)) s, \(mode)")
        FMCleanup.run()
        say("temporary files deleted: \(fm.fileExists(atPath: temp.path) ? "NO" : "yes")")
        exit(failures.isEmpty ? 0 : 1)
    }

    private static func describe(_ gate: FMGate) -> String {
        switch gate {
        case .wait: return "wait"
        case .go: return "go"
        case .refuse: return "refuse"
        }
    }

    private static func summary(_ s: FMScore, outcome: FMOutcome, skew: String) {
        say("--- summary ---")
        let people = s.persons.compactMap { p -> String? in
            guard let w = s.wer[p], w.n > 0 else { return nil }
            return "\(p) \(percent(w.wer))"
        }
        say("word error rate per person: \(people.isEmpty ? "n/a" : people.joined(separator: ", ")) (overall \(percent(s.werOverall)))")
        say("voices found on the system track (substantive): \(s.voicesFoundSystemSubstantive) of 5")
        say("wrong-speaker share: \(percent(s.wrongShare))")
        say("echo leak rate: \(percent(s.echoLeakRate)); your words kept: \(percent(s.samirKeep))")
        say("inaudible stretch: invented words \(s.inventedWords), marker \(s.markerPresent ? "yes" : "no")")
        say(String(format: "writing time: %.0f s (meeting %.0f s)", outcome.writeSeconds, outcome.meetingSeconds))
        say(String(format: "peak memory: %.0f MB", outcome.peakMB))
        say("start skew: \(skew)")
    }

    /// Informational only; never part of PASS.
    private static func crossCheck(_ score: FMScore, folder: URL, turns: [FMTurn]) {
        let scorePy = folder.appendingPathComponent("score.py")
        guard let py = FMPython.find(), FileManager.default.fileExists(atPath: scorePy.path) else {
            say("score.py cross-check skipped (no python3)")
            return
        }
        guard let result = FMPython.run(python: py, scorePy: scorePy, truthJSON: folder.appendingPathComponent("truth.json"),
                                        turns: turns, mic: "speakers") else {
            say("score.py cross-check could not run")
            return
        }
        let mismatches = FMPython.compare(score, result)
        say(mismatches.isEmpty ? "score.py agrees with the Swift scorer" : "score.py disagrees: " + mismatches.joined(separator: "; "))
    }
}
