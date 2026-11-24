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
        let w121 = FMPreflight.beforePlay(status: .waitingForPermission, sinceStart: 121)
        var w121ok = false
        if case .refuse(let m) = w121, m.hasSuffix(perm) { w121ok = true }
        var s16ok = false
        if case .refuse = FMPreflight.beforePlay(status: .starting, sinceStart: 16) { s16ok = true }
        report(FMPreflight.beforePlay(status: .notAuthorised, sinceStart: 0.5) == .refuse(perm)
               && FMPreflight.beforePlay(status: .notArriving, sinceStart: 5) == .refuse(perm)
               && FMPreflight.beforePlay(status: .waitingForPermission, sinceStart: 10) == .wait
               && w121ok
               && FMPreflight.beforePlay(status: .starting, sinceStart: 3) == .wait
               && s16ok
               && FMPreflight.beforePlay(status: .nothingPlaying, sinceStart: 1.0) == .wait
               && FMPreflight.beforePlay(status: .nothingPlaying, sinceStart: 3.2) == .go
               && FMPreflight.beforePlay(status: .receiving, sinceStart: 2) == .go,
               "FG5 the gate before playing", "")

        // G6 after play
        report(FMPreflight.afterPlay(status: .receiving, sincePlay: 0.3) == .go
               && FMPreflight.afterPlay(status: .notArriving, sincePlay: 4) == .refuse(perm)
               && FMPreflight.afterPlay(status: .notAuthorised, sincePlay: 1) == .refuse(perm)
               && FMPreflight.afterPlay(status: .nothingPlaying, sincePlay: 5) == .wait
               && FMPreflight.afterPlay(status: .nothingPlaying, sincePlay: 8.0) == .refuse(perm)
               && FMPreflight.afterPlay(status: .starting, sincePlay: 7.9) == .wait
               && FMPreflight.afterPlay(status: .waitingForPermission, sincePlay: 9) == .refuse(perm),
               "FG6 the gate after playing", "")

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
