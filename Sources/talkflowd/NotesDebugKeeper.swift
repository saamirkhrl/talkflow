import Foundation

/// Keeps a copy of a note's audio and pipeline numbers for debugging, when the hidden notesKeepDebugData preference is on.
/// Runs on the notes job thread before the audio is deleted. Never throws; a file that fails is skipped.
enum NotesDebugKeeper {
    static let defaultsKey = "notesKeepDebugData"
    static var enabled: Bool { Preferences.defaults.bool(forKey: defaultsKey) }
    static var root: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/talkflow/debug-runs", isDirectory: true)

    @discardableResult
    static func keep(audioFolder: URL, stats: NotesJobStats, tracks: [String: [Int16]], turns: Int, duration: Double) -> URL? {
        let fm = FileManager.default
        let noteID = audioFolder.deletingLastPathComponent().lastPathComponent
        var dest = root.appendingPathComponent(noteID, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = root.appendingPathComponent("\(noteID)-\(n)", isDirectory: true)
            n += 1
        }
        do {
            try fm.createDirectory(at: dest, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        } catch {
            return nil
        }
        var files = 0

        // 1. The captured files, same names.
        let names: [String] = (try? fm.contentsOfDirectory(atPath: audioFolder.path)) ?? []
        for name in names.sorted() {
            let src = audioFolder.appendingPathComponent(name)
            let values = try? src.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            do {
                try fm.copyItem(at: src, to: dest.appendingPathComponent(name))
                files += 1
            } catch {
                continue
            }
        }

        // 2. The pipeline's own tracks.
        for name in tracks.keys.sorted() {
            guard let samples = tracks[name] else { continue }
            if writeWav(samples, to: dest.appendingPathComponent(name)) { files += 1 }
        }

        // 3. The numbers.
        let json = pipelineJSON(stats, turns: turns, duration: duration, noteID: noteID)
        if JSONSerialization.isValidJSONObject(json),
           let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            do {
                try data.write(to: dest.appendingPathComponent("pipeline.json"), options: .atomic)
                files += 1
            } catch {
                // skipped
            }
        }

        print("talkflowd: notes: debug data kept: \(files) files")
        return dest
    }

    private static func writeWav(_ samples: [Int16], to url: URL) -> Bool {
        guard !samples.isEmpty, let writer = try? StreamingWav(url: url) else { return false }
        var ok = true
        samples.withUnsafeBufferPointer { (all: UnsafeBufferPointer<Int16>) in
            let slice = 160_000
            var at = 0
            while at < all.count && ok {
                let n = min(slice, all.count - at)
                ok = writer.append(UnsafeBufferPointer(rebasing: all[at..<at + n]))
                at += n
            }
        }
        writer.finish()
        if !ok { try? FileManager.default.removeItem(at: url) }
        return ok
    }

    private static func opt(_ v: Double?) -> Any { v ?? NSNull() }

    /// Numbers and category strings only: never transcript text, prompt text or dictionary words.
    static func pipelineJSON(_ stats: NotesJobStats, turns: Int, duration: Double, noteID: String) -> [String: Any] {
        var out: [String: Any] = [:]
        out["note_id"] = noteID
        out["turns"] = turns
        out["duration_seconds"] = duration

        var echo: [String: Any] = [:]
        echo["gate"] = stats.echoGate
        echo["lag_samples"] = opt(stats.lagSamples)
        echo["drift_ppm"] = opt(stats.driftPPM)
        echo["echo_only_zeroed_seconds"] = stats.nearEndZeroedSeconds
        echo["residual_dbfs"] = opt(stats.residualDB)
        echo["leakage_db"] = opt(stats.leakageDB)
        echo["echo_active_seconds"] = stats.echoActiveSeconds
        echo["residue_dropped_seconds"] = stats.residueDroppedSeconds
        out["echo"] = echo

        var speakers: [String: Any] = [:]
        speakers["engine"] = stats.speakerEngine
        speakers["reason"] = stats.speakerReason ?? NSNull()
        speakers["count"] = stats.speakerCount
        out["speakers"] = speakers

        var align: [String: Any] = [:]
        align["aligned"] = stats.aligned
        align["breaks"] = stats.alignBreaks
        align["removed_seconds"] = stats.alignRemovedSeconds
        align["mic_start_seconds"] = opt(stats.micStartSeconds)
        align["system_start_seconds"] = opt(stats.systemStartSeconds)
        align["mic_drift_fit_ppm"] = opt(stats.micDriftFitPPM)
        align["system_drift_fit_ppm"] = opt(stats.systemDriftFitPPM)
        out["align"] = align

        var counts: [String: Any] = [:]
        counts["pieces_you"] = stats.piecesYou
        counts["pieces_others"] = stats.piecesOthers
        counts["retries"] = stats.retries
        counts["splits"] = stats.splits
        counts["dropped"] = stats.dropped
        counts["inaudible"] = stats.inaudible
        counts["prompt_echoes"] = stats.promptEchoes
        counts["phantoms"] = stats.phantoms
        counts["quiet_skipped"] = stats.quietSkipped
        counts["rule_removed_words"] = stats.ruleRemovedWords
        counts["paused_seconds"] = stats.pausedSeconds
        counts["audio_seconds"] = stats.audioSeconds
        counts["speech_seconds"] = stats.speechSeconds
        out["counts"] = counts

        out["timings"] = stats.timings
        out["engine_memory_mb"] = NSNull()

        var regions: [[String: Any]] = []
        for r in stats.regions {
            var d: [String: Any] = [:]
            d["start"] = r.start
            d["end"] = r.end
            d["level_db"] = r.levelDB
            d["above_leak_db"] = opt(r.aboveLeakDB)
            d["kept"] = r.kept
            d["reason"] = r.reason
            regions.append(d)
        }
        out["regions"] = regions

        var pieces: [[String: Any]] = []
        for p in stats.pieceRecords {
            var d: [String: Any] = [:]
            d["track"] = p.track
            d["start"] = p.start
            d["end"] = p.end
            d["speech"] = p.speech
            d["level_db"] = p.levelDB
            d["words"] = p.words
            d["no_speech_prob"] = opt(p.noSpeechProb)
            d["avg_logprob"] = opt(p.avgLogprob)
            d["prompt_echoes"] = p.promptEchoes
            d["outcome"] = p.outcome
            d["seconds"] = p.seconds
            pieces.append(d)
        }
        out["pieces"] = pieces
        return out
    }
}
