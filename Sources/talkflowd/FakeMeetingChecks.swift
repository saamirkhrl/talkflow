import Foundation

/// The --fakemeeting decisions on plain values, plus the dry-run stand-ins on the real fixture when it is on this
/// Mac (skipped in CI). Called from --notestest. Details hold numbers and states only.
enum FakeMeetingChecks {
    static func run(_ report: (Bool, String, String) -> Void) {
        let fm = FileManager.default
        let perm = FMPreflight.permissionMessage

        // G1 parse
        let d = FakeMeetingOptions.defaultFolder.standardizedFileURL.path
        let a = FakeMeetingOptions.parse(["talkflowd", "--fakemeeting"])
        let b = FakeMeetingOptions.parse(["talkflowd", "--fakemeeting", "/x/y", "--dry-run"])
        let c = FakeMeetingOptions.parse(["talkflowd", "--fakemeeting", "--dry-run", "--fake-pipeline"])
        report(a.folder.standardizedFileURL.path == d && !a.dryRun && !a.fakePipeline
               && b.folder.standardizedFileURL.path == "/x/y" && b.dryRun && !b.fakePipeline
               && c.folder.standardizedFileURL.path == d && c.dryRun && c.fakePipeline,
               "FG1 --fakemeeting arguments are parsed", "")

        // G1b path flags
        let p1 = FakeMeetingOptions.parse(["talkflowd", "--fakemeeting", "--dry-run", "--notes-model", "/m.bin",
                                           "--speaker-helper", "/h", "--speaker-models", "/d", "--server", "/s"])
        let p2 = FakeMeetingOptions.parse(["talkflowd", "--fakemeeting", "--dry-run", "--notes-model"])
        let p3 = FakeMeetingOptions.parse(["talkflowd", "--fakemeeting", "/fixture", "--notes-model", "/m.bin"])
        let p4 = FakeMeetingOptions.parse(["talkflowd", "--fakemeeting", "--notes-model", "--dry-run"])
        report(p1.folder.standardizedFileURL.path == d && p1.dryRun
               && p1.notesModel?.path == "/m.bin" && p1.speakerHelper?.path == "/h"
               && p1.speakerModels?.path == "/d" && p1.server == "/s",
               "FG1b all four pipeline path flags are parsed", "")
        report(p2.notesModel == nil && p2.dryRun && p4.notesModel == nil && p4.dryRun
               && a.notesModel == nil && a.speakerHelper == nil && a.speakerModels == nil && a.server == nil,
               "FG1c a path flag without a value is left unset", "")
        report(p3.folder.standardizedFileURL.path == "/fixture" && p3.notesModel?.path == "/m.bin",
               "FG1d a folder and a path flag are both kept", "")

        // FM-S1 --with-summary
        let w1 = FakeMeetingOptions.parse(["talkflowd", "--fakemeeting", "--dry-run", "--with-summary"])
        let w2 = FakeMeetingOptions.parse(["talkflowd", "--fakemeeting", "/fixture", "--with-summary", "--dry-run"])
        report(!a.withSummary && !b.withSummary && !c.withSummary && w1.withSummary && w1.dryRun
               && w1.folder.standardizedFileURL.path == d,
               "FM-S1 --with-summary is off unless given", "")
        report(w2.withSummary && w2.dryRun && w2.folder.standardizedFileURL.path == "/fixture",
               "FM-S2 a folder is still parsed when --with-summary follows it", "")

        // G1e --misaligned
        let mis = FakeMeetingOptions.parse(["talkflowd", "--fakemeeting", "--dry-run", "--misaligned"])
        report(mis.misaligned && mis.dryRun && !a.misaligned, "FG1e --misaligned is parsed", "")

        // G1f the misaligned dry run's break and time shift
        let spansA: [(start: Double, end: Double)] = [(0, 10), (10.2, 50), (50.1, 61), (62, 70)]
        let spansB: [(start: Double, end: Double)] = [(0, 10), (11, 20)]
        let spansC: [(start: Double, end: Double)] = [(0, 61), (30, 70), (70.4, 80), (81, 90)]
        let breakA = FMMisalign.breakAt(spansA)
        let breakB = FMMisalign.breakAt(spansB)
        let breakC = FMMisalign.breakAt(spansC)
        report(breakA == 61.5, "FG1f the break goes in the first pause of 0.5 s or more after 60 s", "\(String(describing: breakA))")
        report(breakB == nil, "FG1g no pause after 60 s means no break", "\(String(describing: breakB))")
        report(breakC == 80.5, "FG1h an overlapping utterance does not fake a pause", "\(String(describing: breakC))")
        let shiftEarly = FMMisalign.shift(5, breakAt: 61.5)
        let shiftLate = FMMisalign.shift(61.5, breakAt: 61.5)
        report(shiftEarly == 17 && shiftLate == 81.5, "FG1i truth times move by the late start, and by the break after it",
               "\(shiftEarly), \(shiftLate)")

        // G2 missing files
        let none = FMPreflight.missingFiles { _ in true }
        let some = FMPreflight.missingFiles { $0 == "truth.json" || $0 == "system.wav" }
        report(none.isEmpty && some == ["system_48k.wav", "samir_48k.wav", "mic_speakers.wav"],
               "FG2 missing fixture files are listed in order", "\(some.count) missing")

        // G3 output problem
        let hp = FMPreflight.outputProblem(route: .headphones, deviceName: "AirPods")
        report(hp != nil && hp!.contains("headphones")
               && FMPreflight.outputProblem(route: .speakers, deviceName: "x") == nil
               && FMPreflight.outputProblem(route: .unknown, deviceName: "x") == nil,
               "FG3 headphones are refused, speakers and unknown are not", "")

        // G4 volume
        let warn = FMPreflight.volumeWarning(volume: 0.2)
        report(FMPreflight.volumeProblem(muted: true, volume: 0.5) != nil
               && FMPreflight.volumeProblem(muted: false, volume: 0.0) != nil
               && FMPreflight.volumeProblem(muted: false, volume: 0.005) != nil
               && FMPreflight.volumeProblem(muted: false, volume: 0.5) == nil
               && FMPreflight.volumeProblem(muted: nil, volume: nil) == nil
               && FMPreflight.volumeProblem(muted: false, volume: nil) == nil
               && warn != nil && warn!.contains("20%")
               && FMPreflight.volumeWarning(volume: 0.5) == nil
               && FMPreflight.volumeWarning(volume: nil) == nil,
               "FG4 muted, zero and low volume are judged", "")

        // G5 before play
        func refusesWithPerm(_ g: FMGate) -> Bool {
            if case .refuse(let m) = g, m.hasSuffix(perm) { return true }
            return false
        }
        report(FMPreflight.beforePlay(status: .waitingForPermission, sinceStart: 89.9) == .wait
               && refusesWithPerm(FMPreflight.beforePlay(status: .waitingForPermission, sinceStart: 90))
               && FMPreflight.beforePlay(status: .notAuthorised, sinceStart: 0.5) == .wait
               && FMPreflight.beforePlay(status: .notAuthorised, sinceStart: 3.0) == .go
               && FMPreflight.beforePlay(status: .notArriving, sinceStart: 2.9) == .wait
               && FMPreflight.beforePlay(status: .notArriving, sinceStart: 3.0) == .go
               && FMPreflight.beforePlay(status: .starting, sinceStart: 16) == .go
               && FMPreflight.beforePlay(status: .nothingPlaying, sinceStart: 1.0) == .wait
               && FMPreflight.beforePlay(status: .nothingPlaying, sinceStart: 3.2) == .go
               && FMPreflight.beforePlay(status: .receiving, sinceStart: 2) == .go,
               "FG5 the gate before playing", "")

        // G6 after play
        report(FMPreflight.afterPlay(status: .receiving, sincePlay: 0.3) == .go
               && FMPreflight.afterPlay(status: .notArriving, sincePlay: 4) == .wait
               && FMPreflight.afterPlay(status: .notAuthorised, sincePlay: 1) == .wait
               && FMPreflight.afterPlay(status: .nothingPlaying, sincePlay: 4.9) == .wait
               && FMPreflight.afterPlay(status: .nothingPlaying, sincePlay: 5) == .refuse(perm)
               && FMPreflight.afterPlay(status: .waitingForPermission, sincePlay: 5) == .refuse(perm),
               "FG6 the gate after playing", "")

        // G11 the live wait before playing, with a fake capture and a tick clock (no float drift)
        func driveBefore(_ statusAt: @escaping (Int) -> ComputerAudioStatus) -> (FMGate, Double, Int) {
            var ticks = 0
            var notices = 0
            let g = FMPreflight.waitBeforePlay(
                status: { statusAt(ticks) },
                elapsed: { Double(ticks) / 10 },
                pump: { _ in ticks += 1 },
                say: { if $0 == "waiting for you to click Allow" { notices += 1 } })
            return (g, Double(ticks) / 10, notices)
        }
        let ba = driveBefore { $0 >= 370 ? .nothingPlaying : .waitingForPermission }
        let bb = driveBefore { _ in .waitingForPermission }
        let bc = driveBefore { _ in .notAuthorised }
        let bd = driveBefore { _ in .receiving }
        let be = driveBefore { _ in .notArriving }
        let bf = driveBefore { $0 < 20 ? .starting : .nothingPlaying }
        report(ba.0 == .go && ba.1 == 37.0 && ba.2 == 3
               && refusesWithPerm(bb.0) && bb.1 == 90.0 && bb.2 == 8
               && bc.0 == .go && bc.1 == 3.0 && bc.2 == 0
               && bd.0 == .go && bd.1 == 1.5 && bd.2 == 0
               && be.0 == .go && be.1 == 3.0 && be.2 == 0
               && bf.0 == .go && bf.1 == 2.0 && bf.2 == 0,
               "FG11 the wait for Allow", "A \(ba.1)s/\(ba.2) B \(bb.1)s/\(bb.2) C \(bc.1)s D \(bd.1)s E \(be.1)s F \(bf.1)s")

        // G12 the live wait after playing
        func driveAfter(_ statusAt: @escaping (Int) -> ComputerAudioStatus) -> (FMGate, Double) {
            var ticks = 0
            let g = FMPreflight.waitAfterPlay(status: { statusAt(ticks) }, elapsed: { Double(ticks) / 10 },
                                              pump: { _ in ticks += 1 })
            return (g, Double(ticks) / 10)
        }
        let aa = driveAfter { _ in .receiving }
        let ab = driveAfter { $0 >= 20 ? .receiving : .notAuthorised }
        let ac = driveAfter { _ in .nothingPlaying }
        report(aa.0 == .go && aa.1 == 0.1
               && ab.0 == .go && ab.1 == 2.0
               && refusesWithPerm(ac.0) && ac.1 == 5.0,
               "FG12 the wait after playing", "A \(aa.1)s B \(ab.1)s C \(ac.1)s")

        // G7 permission text
        report(perm.contains("Privacy & Security > Screen & System Audio Recording"),
               "FG7 the permission message names the settings pane", "")

        // G8 thresholds
        let good = FMOutcome(notesReady: true, audioGone: true, werOverall: 0.05, werPerPerson: ["samir": 0.1, "bob": 0.2],
                             voicesSubstantive: 5, wrongShare: 0.1, echoLeakRate: 0.01, samirKeep: 0.95, invented: 0,
                             writeSeconds: 100, meetingSeconds: 532.683, peakMB: 500)
        func count(_ edit: (inout FMOutcome) -> Void) -> Int {
            var o = good
            edit(&o)
            return FMThresholds.failures(o).count
        }
        var single: [(String, Int)] = []
        single.append(("notesReady", count { $0.notesReady = false }))
        single.append(("audioGone", count { $0.audioGone = false }))
        single.append(("wer 0.16", count { $0.werOverall = 0.16 }))
        single.append(("wer nil", count { $0.werOverall = nil }))
        single.append(("bob 0.31", count { $0.werPerPerson["bob"] = Optional(0.31) }))
        single.append(("voices 3", count { $0.voicesSubstantive = 3 }))
        single.append(("voices 7", count { $0.voicesSubstantive = 7 }))
        single.append(("wrong 0.26", count { $0.wrongShare = 0.26 }))
        single.append(("echo 0.06", count { $0.echoLeakRate = 0.06 }))
        single.append(("keep 0.84", count { $0.samirKeep = 0.84 }))
        single.append(("keep nil", count { $0.samirKeep = nil }))
        single.append(("invented 3", count { $0.invented = 3 }))
        single.append(("write 533", count { $0.writeSeconds = 533 }))
        single.append(("peak 2049", count { $0.peakMB = 2049 }))
        let badOnes = single.filter { $0.1 != 1 }.map { $0.0 }
        var edges: [(String, Int)] = []
        edges.append(("wer 0.15", count { $0.werOverall = 0.15 }))
        edges.append(("bob 0.30", count { $0.werPerPerson["bob"] = Optional(0.30) }))
        edges.append(("voices 4", count { $0.voicesSubstantive = 4 }))
        edges.append(("voices 6", count { $0.voicesSubstantive = 6 }))
        edges.append(("wrong 0.25", count { $0.wrongShare = 0.25 }))
        edges.append(("echo 0.05", count { $0.echoLeakRate = 0.05 }))
        edges.append(("echo nil", count { $0.echoLeakRate = nil }))
        edges.append(("keep 0.85", count { $0.samirKeep = 0.85 }))
        edges.append(("invented 2", count { $0.invented = 2 }))
        edges.append(("write 532.683", count { $0.writeSeconds = 532.683 }))
        edges.append(("peak 2048", count { $0.peakMB = 2048 }))
        let badEdges = edges.filter { $0.1 != 0 }.map { $0.0 }
        report(FMThresholds.failures(good).isEmpty && badOnes.isEmpty && badEdges.isEmpty,
               "FG8 each threshold fails alone and passes at its limit",
               "good \(FMThresholds.failures(good).count) failures, off-by-count: \((badOnes + badEdges).joined(separator: ", "))")

        // G9 the dry-run capture on the real fixture
        let fixture = FakeMeetingOptions.defaultFolder
        if fm.fileExists(atPath: fixture.appendingPathComponent("mic_speakers.wav").path)
            && fm.fileExists(atPath: fixture.appendingPathComponent("system.wav").path) {
            let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("talkflow-g9-\(UUID().uuidString)", isDirectory: true)
            try? fm.createDirectory(at: temp, withIntermediateDirectories: true)
            let cap = FixtureCapture(fixture: fixture)
            var ok = true
            var detail = ""
            do {
                try cap.start(into: temp)
                let you = temp.appendingPathComponent(CaptureFolder.mic)
                let others = temp.appendingPathComponent(CaptureFolder.system)
                let wy = WavInfo.read(you), wo = WavInfo.read(others)
                ok = ok && wy?.headerMatchesFile == true && wy?.sampleRate == 16000
                ok = ok && wo?.headerMatchesFile == true && wo?.sampleRate == 16000
                let ny = Int64(((wy?.fileBytes ?? 44) - 44) / 2), no = Int64(((wo?.fileBytes ?? 44) - 44) / 2)
                let info = CaptureSessionInfo.read(from: temp)
                ok = ok && info?.micSamples == ny && info?.systemSamples == no
                for name in [CaptureFolder.micTimeline, CaptureFolder.systemTimeline] {
                    let attrs = try? fm.attributesOfItem(atPath: temp.appendingPathComponent(name).path)
                    ok = ok && ((attrs?[.size] as? Int) ?? 0) > 0
                }
                ok = ok && cap.isRecording
                let seconds = cap.stop()
                ok = ok && abs(seconds - Double(max(ny, no)) / 16000) < 0.001 && !cap.isRecording
                detail = "\(ny) and \(no) samples, \(String(format: "%.3f", seconds)) s"
            } catch {
                ok = false
                detail = "start failed (\(type(of: error)))"
            }
            try? fm.removeItem(at: temp)
            report(ok && !fm.fileExists(atPath: temp.path), "FG9 the fixture stand-in leaves what a recording would", detail)
        } else {
            report(true, "FG9 fixture stand-ins skipped (no fixture)", "")
        }

        // G10 the truth pipeline
        let emptyFolder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("talkflow-g10-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: emptyFolder, withIntermediateDirectories: true)
        let turns = [FMTurn(speaker: "You", start: 0, end: 1, text: "hi"), FMTurn(speaker: "Speaker 1", start: 1, end: 2, text: "yo")]

        var failedOutcome: PipelineOutcome?
        // Held in a variable: the pipeline's scheduled steps only keep it weakly, as NotesModel's strong reference does.
        let emptyRun = TruthPipeline(turns: turns)
        emptyRun.run(audioFolder: emptyFolder, progress: { _ in }, completion: { failedOutcome = $0 })
        let until1 = Date().addingTimeInterval(2)
        while failedOutcome == nil && Date() < until1 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        var failedOK = false
        if case .failed(let f)? = failedOutcome, f.retry == .notes { failedOK = true }

        for name in [CaptureFolder.mic, CaptureFolder.system] {
            try? Data().write(to: emptyFolder.appendingPathComponent(name))
        }
        let tp = TruthPipeline(turns: turns)
        tp.offset = 2
        var finished: PipelineOutcome?
        var progressCalls = 0
        tp.run(audioFolder: emptyFolder, progress: { _ in progressCalls += 1 }, completion: { finished = $0 })
        let until2 = Date().addingTimeInterval(4)
        while finished == nil && Date() < until2 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        var finishedOK = false
        if case .finished(let pieces, let duration)? = finished {
            finishedOK = pieces == [SpeechPiece(speaker: "you", start: 2, end: 3, text: "hi"),
                                    SpeechPiece(speaker: "spk_speaker_1", start: 3, end: 4, text: "yo")]
                && duration == 4
        }
        try? fm.removeItem(at: emptyFolder)
        report(failedOK && finishedOK && progressCalls >= 2, "FG10 the truth pipeline fails without audio and returns the truth with it",
               "failed \(failedOK), finished \(finishedOK), progress calls \(progressCalls)")
    }
}
