import Foundation

/// The pipeline's time estimate, log privacy and speaker labels, run from --notestest.
enum NotesFlowChecks {
    private static func near(_ a: Double, _ b: Double, _ tolerance: Double = 0.01) -> Bool { abs(a - b) <= tolerance }

    /// A segment whose words are the text's words, 0.3 s apart from `start`.
    private static func segment(_ text: String, start: Double) -> TimedSegment {
        let tokens = text.split(separator: " ").map(String.init)
        let words = tokens.enumerated().map {
            TimedWord(text: $0.element, start: start + 0.3 * Double($0.offset), end: start + 0.3 * Double($0.offset) + 0.25)
        }
        return TimedSegment(start: start, end: words.last?.end ?? start, text: text, words: words)
    }

    static func run(_ report: (Bool, String, String) -> Void) {
        func check(_ ok: Bool, _ label: String, _ detail: String = "") { report(ok, label, detail) }
        // NF1: speakers come before transcribing, so the computer-audio track is cut at speaker changes.
        check(WritingStep.allCases == [.saving, .speakers, .transcribing, .finishing], "NF1 step order",
              "\(WritingStep.allCases.map { $0.rawValue })")

        // NF2: the "others" key.
        check(NotesLogic.defaultName("others") == "Everyone else", "NF2 default name of others")
        let numbered = NotesLogic.numberSpeakers([
            SpeechPiece(speaker: "others", start: 0, end: 1, text: "a"),
            SpeechPiece(speaker: "S7", start: 2, end: 3, text: "b"),
            SpeechPiece(speaker: "you", start: 4, end: 5, text: "c"),
        ])
        check(numbered.map { $0.speaker } == ["others", "s1", "you"], "NF2 numberSpeakers keeps others",
              "\(numbered.map { $0.speaker })")

        // NF3-NF5: the estimates.
        let b1 = NotesEstimate.beforeCut(3600, turbo: true)
        let b2 = NotesEstimate.beforeCut(600, turbo: false)
        check(near(b1, 355.5) && near(b2, 30.75), "NF3 beforeCut", "\(b1) \(b2)")
        let t1 = NotesEstimate.transcribing(piecesLeft: 10, speechLeft: 200, turbo: true, observedRatio: nil)
        let t2 = NotesEstimate.transcribing(piecesLeft: 10, speechLeft: 200, turbo: true, observedRatio: 4)
        let t3 = NotesEstimate.transcribing(piecesLeft: 10, speechLeft: 200, turbo: true, observedRatio: 0.2)
        check(near(t1, 19.3) && near(t2, 57.9) && near(t3, 9.65), "NF4 transcribing", "\(t1) \(t2) \(t3)")
        let r1 = NotesEstimate.observedRatio(elapsed: 20, fittedDone: 10, piecesDone: 2)
        let r2 = NotesEstimate.observedRatio(elapsed: 20, fittedDone: 10, piecesDone: 5)
        check(r1 == nil && r2 == 2, "NF5 observedRatio", "\(String(describing: r1)) \(String(describing: r2))")

        // NF6: the system track says the same words: the "you" piece goes, one "others" piece stays.
        let words = "four score and seven years"
        let echoed = NotesJob.assemble(results: [
            PieceResult(track: "you", start: 0, end: 5, segments: [segment(words, start: 1.0)]),
            PieceResult(track: "others", start: 0.9, end: 3, segments: [segment(words, start: 0.9)]),
        ], runs: nil, englishRules: true)
        check(echoed.pieces.count == 1 && echoed.pieces[0].speaker == "others" && echoed.removedWords == 5,
              "NF6 echoed you piece removed", "\(echoed.pieces.map { $0.speaker }) removed \(echoed.removedWords)")

        // NF7: the others piece takes the speaker with the most overlap.
        let turns = [SpeakerSegment(speaker: "S1", start: 0, end: 10), SpeakerSegment(speaker: "S2", start: 10, end: 20)]
        let voiced = NotesJob.assemble(results: [
            PieceResult(track: "others", start: 9, end: 14, segments: [segment("Hello there.", start: 9.5)]),
        ], runs: turns, englishRules: true)
        check(voiced.pieces.map { $0.speaker } == ["S2"], "NF7 speaker by overlap", "\(voiced.pieces.map { $0.speaker })")

        // NF8: fillers go and the first letter is capital.
        let filler = NotesJob.assemble(results: [
            PieceResult(track: "you", start: 0, end: 3, segments: [segment("um so we ship it", start: 0.2)]),
        ], runs: nil, englishRules: true)
        check(filler.pieces.map { $0.text } == ["So we ship it"], "NF8 filler removed", "\(filler.pieces.map { $0.text })")

        // NF9: a result with no text gives no piece.
        let empty = NotesJob.assemble(results: [
            PieceResult(track: "you", start: 0, end: 3, segments: [TimedSegment(start: 0.2, end: 1, text: "", words: [])]),
        ], runs: nil, englishRules: true)
        check(empty.pieces.isEmpty, "NF9 empty text gives no piece", "\(empty.pieces.count)")

        // NF10: the log never holds what was said.
        let clean = Transcript(turns: [TranscriptTurn(speaker: "you", start: 0, end: 1, text: "we shipped twelve turns today")])
        let leaky = Transcript(turns: [TranscriptTurn(speaker: "you", start: 0, end: 1, text: "so the launch moves to march")])
        check(!NotesFlow.logLeaks(log: "notes written: 12 turns, 3 speakers", transcript: clean), "NF10 counts are not a leak")
        check(NotesFlow.logLeaks(log: "x so the launch moves y", transcript: leaky), "NF10 three words in a row are a leak")
    }
}
