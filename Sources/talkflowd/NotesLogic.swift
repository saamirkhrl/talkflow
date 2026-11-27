import Foundation

/// The note taker's pure rules: assembly, speakers, labels, copy text. No I/O, so --notestest checks them.
enum NotesLogic {
    static let youKey = "you"
    /// The computer-audio track when the voices on it cannot be told apart (Intel Mac, macOS 13, the speaker helper
    /// or its models missing, or the helper failed). Like "you", numberSpeakers leaves it alone.
    static let everyoneKey = "others"
    /// Pieces by the same speaker this close (seconds) merge into one turn. Not measured yet: a pause longer
    /// than a breath starts a new turn. Tune with the real transcriber.
    static let mergeGap: Double = 3.0
    /// A merged turn stops growing at this length (seconds), so a long monologue keeps timestamps to jump to.
    static let maxTurnLength: Double = 90.0
    static let maxNameLength = 40
    static let minimumMacOS = OperatingSystemVersion(majorVersion: 14, minorVersion: 2, patchVersion: 0)

    private static let dot = " \u{00B7} "
    private static let estimateTail = " You can keep using your Mac."

    // MARK: - Assembly

    /// Renumbers the separator's own labels to s1, s2, ... by first appearance in time. Pieces keep their
    /// original order; only the speaker changes.
    static func numberSpeakers(_ pieces: [SpeechPiece]) -> [SpeechPiece] {
        let order = pieces.enumerated().sorted { a, b in
            if a.element.start != b.element.start { return a.element.start < b.element.start }
            if a.element.end != b.element.end { return a.element.end < b.element.end }
            return a.offset < b.offset
        }
        var map: [String: String] = [:]
        var n = 0
        for (_, piece) in order where piece.speaker != youKey && piece.speaker != everyoneKey && map[piece.speaker] == nil {
            n += 1
            map[piece.speaker] = "s\(n)"
        }
        return pieces.map { piece in
            var copy = piece
            if let mapped = map[piece.speaker] { copy.speaker = mapped }
            return copy
        }
    }

    static func assemble(_ pieces: [SpeechPiece]) -> [TranscriptTurn] {
        // Empty pieces are dropped before merging, so they never split a turn.
        var kept: [(offset: Int, piece: SpeechPiece)] = []
        for (i, original) in pieces.enumerated() {
            var p = original
            p.text = p.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if p.text.isEmpty { continue }
            p.end = max(p.end, p.start)
            kept.append((i, p))
        }
        kept.sort { a, b in
            if a.piece.start != b.piece.start { return a.piece.start < b.piece.start }
            return a.offset < b.offset
        }
        var turns: [TranscriptTurn] = []
        for (_, p) in kept {
            if var last = turns.last, last.speaker == p.speaker,
               p.start - last.end <= mergeGap,
               max(last.end, p.end) - last.start <= maxTurnLength {
                last.end = max(last.end, p.end)
                last.text += " " + p.text
                turns[turns.count - 1] = last
            } else {
                turns.append(TranscriptTurn(speaker: p.speaker, start: p.start, end: p.end, text: p.text))
            }
        }
        return turns
    }

    static func transcript(from pieces: [SpeechPiece]) -> Transcript {
        Transcript(turns: assemble(numberSpeakers(pieces)))
    }

    // MARK: - Speakers

    static func speakerKeys(in turns: [TranscriptTurn]) -> [String] {
        var seen = Set<String>()
        var keys: [String] = []
        for t in turns where seen.insert(t.speaker).inserted {
            keys.append(t.speaker)
        }
        return keys
    }

    static func speakers(for turns: [TranscriptTurn], keeping old: [NoteSpeaker]) -> [NoteSpeaker] {
        speakerKeys(in: turns).map { key in
            let o = old.first { $0.key == key }
            return NoteSpeaker(key: key, name: o?.name, nameSource: o?.nameSource)
        }
    }

    static func defaultName(_ key: String) -> String {
        if key == youKey { return "You" }
        if key == everyoneKey { return "Everyone else" }
        if key.hasPrefix("s"), let n = Int(key.dropFirst()), n > 0 { return "Speaker \(n)" }
        return key
    }

    static func displayName(_ key: String, in speakers: [NoteSpeaker]) -> String {
        if let name = speakers.first(where: { $0.key == key })?.name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return defaultName(key)
    }

    static func renaming(_ key: String, to name: String, in speakers: [NoteSpeaker]) -> [NoteSpeaker] {
        // The microphone is always You.
        if key == youKey { return speakers }
        guard let index = speakers.firstIndex(where: { $0.key == key }) else { return speakers }
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxNameLength))
        let newName: String? = (trimmed.isEmpty || trimmed == defaultName(key)) ? nil : trimmed
        var result = speakers
        if newName == result[index].name && NotesDoc.nameSource(result[index]) != .auto { return speakers }
        result[index].name = newName
        result[index].nameSource = .user
        return result
    }

    // MARK: - Labels

    static func timestamp(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds.rounded(.down))
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }

    private static func wholeMinutes(_ seconds: Double) -> Int {
        guard seconds.isFinite else { return 1 }
        return max(1, Int((seconds / 60).rounded()))
    }

    static func durationText(_ seconds: Double) -> String {
        let minutes = wholeMinutes(seconds)
        if minutes < 60 { return "\(minutes) min" }
        let h = minutes / 60
        let m = minutes % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    static func spokenDuration(_ seconds: Double) -> String {
        let minutes = wholeMinutes(seconds)
        func mins(_ n: Int) -> String { n == 1 ? "1 minute" : "\(n) minutes" }
        if minutes < 60 { return mins(minutes) }
        let h = minutes / 60
        let m = minutes % 60
        let hours = h == 1 ? "1 hour" : "\(h) hours"
        return m > 0 ? hours + " " + mins(m) : hours
    }

    static func speakerCountText(_ n: Int) -> String {
        n == 1 ? "1 speaker" : "\(n) speakers"
    }

    static func displayTitle(_ meta: NoteMeta) -> String {
        let t = meta.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Untitled meeting" : t
    }

    static func rowDetail(_ meta: NoteMeta) -> String {
        switch meta.state {
        case .recording: return "Recording"
        case .writing: return "Writing notes..."
        case .failed: return "Couldn't finish the notes"
        case .ready:
            var parts = [durationText(meta.duration)]
            if meta.speakers.count > 0 { parts.append(speakerCountText(meta.speakers.count)) }
            switch meta.actionItemCount {
            case nil: parts.append("Transcript only")
            case 1?: parts.append("1 action item")
            case let n?: parts.append("\(n) action items")
            }
            return parts.joined(separator: dot)
        }
    }

    // MARK: - Dates

    private static func formatter(_ format: String, calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = format
        return f
    }

    private static func daysAgo(_ date: Date, now: Date, calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
    }

    static func dateLabel(_ date: Date, now: Date, calendar: Calendar) -> String {
        let time = formatter("h:mm a", calendar: calendar).string(from: date)
        let days = daysAgo(date, now: now, calendar: calendar)
        switch days {
        case 0: return "Today, " + time
        case 1: return "Yesterday, " + time
        case 2...6: return formatter("EEEE", calendar: calendar).string(from: date) + ", " + time
        default:
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            let day = formatter(sameYear ? "MMMM d" : "MMMM d, yyyy", calendar: calendar).string(from: date)
            return day + ", " + time
        }
    }

    static func groupTitle(_ date: Date, now: Date, calendar: Calendar) -> String {
        if daysAgo(date, now: now, calendar: calendar) <= 6 { return "This week" }
        return formatter("MMMM yyyy", calendar: calendar).string(from: date)
    }

    static func grouped(_ notes: [NoteMeta], now: Date, calendar: Calendar) -> [NoteGroup] {
        let sorted = notes.sorted {
            if $0.started != $1.started { return $0.started > $1.started }
            return $0.id > $1.id
        }
        var groups: [NoteGroup] = []
        for note in sorted {
            let title = groupTitle(note.started, now: now, calendar: calendar)
            if let last = groups.last, last.title == title {
                groups[groups.count - 1].notes.append(note)
            } else {
                groups.append(NoteGroup(title: title, notes: [note]))
            }
        }
        return groups
    }

    // MARK: - Copy

    static func copyText(meta: NoteMeta, transcript: Transcript, calendar: Calendar) -> String {
        var header = [displayTitle(meta)]
        let when = formatter("MMMM d, yyyy, h:mm a", calendar: calendar).string(from: meta.started)
        header.append(when + dot + durationText(meta.duration))
        if !meta.speakers.isEmpty {
            header.append("Speakers: " + meta.speakers.map { displayName($0.key, in: meta.speakers) }.joined(separator: ", "))
        }
        let turnLines = transcript.turns.map {
            "[" + timestamp($0.start) + "] " + displayName($0.speaker, in: meta.speakers) + ": " + $0.text
        }
        return header.joined(separator: "\n") + (turnLines.isEmpty ? "\n" : "\n\n" + turnLines.joined(separator: "\n\n") + "\n")
    }

    // MARK: - Writing screen

    static func estimateText(_ secondsLeft: Double?) -> String {
        guard let s = secondsLeft, s.isFinite else { return "Working out how long this will take." + estimateTail }
        if s <= 45 { return "Less than a minute left." + estimateTail }
        let minutes = Int((s / 60).rounded(.up))
        if minutes == 1 { return "About a minute left." + estimateTail }
        return "About \(minutes) minutes left." + estimateTail
    }

    static func overallProgress(_ p: WritingProgress) -> Double {
        let index = WritingStep.allCases.firstIndex(of: p.step) ?? 0
        return (Double(index) + min(max(p.fraction, 0), 1)) / Double(WritingStep.allCases.count)
    }

    static func stepLabel(_ step: WritingStep, duration: Double, done: Bool, summaryProvider: String?) -> String {
        switch step {
        case .saving:
            return done ? "Saved \(spokenDuration(duration)) of audio" : "Saving the audio"
        case .transcribing: return "Transcribing on this Mac"
        case .speakers: return "Telling the voices apart"
        case .finishing:
            if let p = summaryProvider { return "Writing the summary with your \(p) key, then deleting the audio" }
            return "Saving the transcript and deleting the audio"
        }
    }

    // MARK: - Availability

    static func supportsRecording(_ v: OperatingSystemVersion) -> Bool {
        (v.majorVersion, v.minorVersion) >= (minimumMacOS.majorVersion, minimumMacOS.minorVersion)
    }

    static func unsupportedMessage(_ v: OperatingSystemVersion) -> String {
        "Recording meetings needs macOS 14.2 or later, the first version that lets an app record the sound a Mac plays. This Mac has macOS \(v.majorVersion).\(v.minorVersion). Dictation and your saved notes keep working. To record meetings, update macOS in System Settings > General > Software Update."
    }
}

/// Whether a key is saved for meeting notes, and whose (NotesAccess.current).
enum NotesKeys {
    static func inUse() -> Bool { NotesAccess.current() != nil }
    static func provider() -> String? { NotesAccess.current()?.provider.name }
}
