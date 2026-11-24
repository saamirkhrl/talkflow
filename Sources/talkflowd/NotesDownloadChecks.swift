import Foundation

/// Checks for the Notes first-use downloads: the card's rules, the progress label, the helper's prepare lines, the
/// speaker-models test and the NoteDownloads state machine against a fake environment.
enum NotesDownloadChecks {
    private final class FakeTask: NoteDownloadTask {
        var cancels = 0
        func cancel() { cancels += 1 }
    }

    private static func spin() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

    static func run(_ report: (Bool, String, String) -> Void) {
        typealias S = NoteDownloadState
        typealias L = NoteDownloadsLogic

        // ND1
        let cardCases: [(S, S, Bool, Bool)] = [
            (.absent, .absent, false, true), (.absent, .absent, true, false), (.downloading(0.1), .done, true, true),
            (.done, .done, false, false), (.done, .unavailable, false, false), (.failed, .done, false, true),
            (.done, .absent, false, true),
        ]
        let cardBad = cardCases.filter { L.showsCard(model: $0.0, speakers: $0.1, declined: $0.2) != $0.3 }.count
        report(cardBad == 0, "ND1 showsCard truth table", "\(cardCases.count - cardBad)/\(cardCases.count) match")

        // ND2
        let linkCases: [(S, S, Bool, Bool)] = [
            (.absent, .done, true, true), (.absent, .done, false, false), (.downloading(0.5), .absent, true, false),
            (.done, .unavailable, true, false),
        ]
        let linkBad = linkCases.filter { L.showsReofferLink(model: $0.0, speakers: $0.1, declined: $0.2) != $0.3 }.count
        report(linkBad == 0, "ND2 showsReofferLink", "\(linkCases.count - linkBad)/\(linkCases.count) match")

        // ND3
        let a = L.progressLabel(fraction: 0.42, totalMB: 574)
        let b = L.progressLabel(fraction: 1.5, totalMB: 21)
        let c = L.progressLabel(fraction: -1, totalMB: 574)
        report(a == "241 of 574 MB" && b == "21 of 21 MB" && c == "0 of 574 MB", "ND3 progressLabel", "\(a) | \(b) | \(c)")

        // ND4
        let p1 = L.parsePrepare(#"{"event":"progress","fraction":0.25,"file":"downloading 1/5"}"#)
        let p2 = L.parsePrepare(#"{"event":"done","models_dir":"x","bytes":5}"#)
        let p3 = L.parsePrepare(#"{"event":"progress","fraction":1.7}"#)
        let p4 = L.parsePrepare("[Profiling] something")
        let p5 = L.parsePrepare(#"{"event":"progress","phase":"loading"}"#)
        report(p1 == .progress(0.25) && p2 == .done && p3 == .progress(1.0) && p4 == nil && p5 == nil,
               "ND4 parsePrepare", "\(String(describing: p1)) \(String(describing: p2)) \(String(describing: p3)) \(String(describing: p4)) \(String(describing: p5))")

        // ND5
        let rows = [L.rowCount(model: .absent, speakers: .absent), L.rowCount(model: .absent, speakers: .unavailable),
                    L.rowCount(model: .downloading(0.4), speakers: .done), L.rowCount(model: .done, speakers: .done)]
        report(rows == [2, 1, 2, 0], "ND5 rowCount", "\(rows)")

        // ND6
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("talkflow-nd-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let empty = SpeakerHelper.modelsPresent(root)
        let repo = root.appendingPathComponent(SpeakerHelper.repoFolder, isDirectory: true)
        for name in SpeakerHelper.requiredModels {
            let url = repo.appendingPathComponent(name)
            if name.hasSuffix(".mlmodelc") {
                try? fm.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try? fm.createDirectory(at: repo, withIntermediateDirectories: true)
                fm.createFile(atPath: url.path, contents: Data("{}".utf8))
            }
        }
        let full = SpeakerHelper.modelsPresent(root)
        fm.createFile(atPath: repo.appendingPathComponent("Embedding.mlmodelc/weight.bin.partial").path, contents: Data([1]))
        let partial = SpeakerHelper.modelsPresent(root)
        report(!empty && full && !partial, "ND6 modelsPresent", "empty=\(empty) full=\(full) withPartial=\(partial)")

        // ND7
        var modelComplete = false
        var speakersPresent = false
        var stored = false
        var modelStarts = 0
        var speakerStarts = 0
        var modelProgress: ((Double) -> Void)?
        var modelFinish: ((Bool) -> Void)?
        var speakerFinish: ((Bool) -> Void)?
        var modelTask = FakeTask()
        var speakerTask = FakeTask()
        let env = NoteDownloads.Environment(
            modelComplete: { modelComplete },
            speakersAvailable: { true },
            speakersPresent: { speakersPresent },
            startModel: { progress, finish in
                modelStarts += 1
                modelProgress = progress
                modelFinish = finish
                modelTask = FakeTask()
                return modelTask
            },
            startSpeakers: { _, finish in
                speakerStarts += 1
                speakerFinish = finish
                speakerTask = FakeTask()
                return speakerTask
            },
            loadDeclined: { stored },
            saveDeclined: { stored = $0 })
        let d = NoteDownloads(environment: env)
        let ga = d.model == .absent && d.speakers == .absent && d.showsCard
        d.download()
        let gb = modelStarts == 1 && speakerStarts == 1 && d.model == .downloading(0) && d.speakers == .downloading(0)
        modelProgress?(0.5)
        spin()
        let gc = d.model == .downloading(0.5)
        modelComplete = true
        modelFinish?(true)
        spin()
        let gd = d.model == .done
        speakerFinish?(false)
        spin()
        let ge = d.speakers == .failed && d.showsCard
        d.download()
        let gf = speakerStarts == 2 && modelStarts == 1 && d.speakers == .downloading(0)
        let lateFinish = speakerFinish
        d.decline()
        let gg = speakerTask.cancels == 1 && d.speakers == .absent && d.declined && stored && !d.showsCard && d.showsReofferLink
        lateFinish?(true)
        speakersPresent = true
        spin()
        let gh = d.speakers == .absent
        d.reoffer()
        let gi = !d.declined && !stored && d.showsCard
        let flags = [ga, gb, gc, gd, ge, gf, gg, gh, gi]
        report(!flags.contains(false), "ND7 NoteDownloads state machine",
               "a-i: " + flags.map { $0 ? "ok" : "FAIL" }.joined(separator: " "))

        // ND8
        let inert = NoteDownloads(environment: .inert)
        report(!inert.showsCard && !inert.showsReofferLink, "ND8 inert environment", "card=\(inert.showsCard) link=\(inert.showsReofferLink)")
    }
}
