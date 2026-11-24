import Foundation

/// Notes transcription: the hallucination guard, reply parsing and the retry rule, run from --notestest.
enum TranscribeChecks {
    private static func seg(_ text: String, nsp: Double? = nil, lp: Double? = nil, words: [TimedWord] = []) -> WhisperSegment {
        WhisperSegment(start: 0, end: 1, text: text, words: words, avgLogprob: lp, noSpeechProb: nsp)
    }

    static func run(_ check: (Bool, String, String) -> Void) {
        let guardNo = HallucinationGuard.self

        let g1 = guardNo.clean([seg("[BLANK_AUDIO]")], fromRetry: false)
        check(g1.segments.isEmpty && g1.dropped == 1, "TG1 blank audio label is dropped", "\(g1)")

        let g2 = guardNo.clean([seg(" [INAUDIBLE] ")], fromRetry: false)
        check(g2.segments.count == 1 && g2.segments[0].text == "[inaudible]" && g2.segments[0].words.isEmpty
              && g2.inaudible == 1 && g2.dropped == 0, "TG2 inaudible label becomes [inaudible]", "\(g2)")

        let g3 = guardNo.clean([seg(" . . . .")], fromRetry: false)
        check(g3.segments.isEmpty && g3.dropped == 1, "TG3 punctuation only is dropped", "\(g3)")

        let w = [TimedWord(text: "(music)", start: 0, end: 0.5), TimedWord(text: "Hello", start: 0.5, end: 0.8)]
        let g4 = guardNo.clean([seg("(music) Hello there.", words: w)], fromRetry: false)
        check(g4.segments.count == 1 && g4.segments[0].text == "Hello there." && g4.segments[0].words.isEmpty,
              "TG4 music label removed, words cleared", "\(g4)")
        let g4b = guardNo.clean([seg("\u{266A} la la \u{266B}")], fromRetry: false)
        check(g4b.segments.count == 1 && g4b.segments[0].text == "la la", "TG4b music notes removed", "\(g4b)")

        let g5a = guardNo.clean([seg("Some words here.", nsp: 0.7, lp: -1.2)], fromRetry: false)
        let g5b = guardNo.clean([seg("Some words here.", nsp: 0.7, lp: -0.5)], fromRetry: false)
        let g5c = guardNo.clean([seg("Some words here.", nsp: 0.2, lp: -1.2)], fromRetry: false)
        let g5d = guardNo.clean([seg("Some words here.", nsp: 0.2, lp: -1.2)], fromRetry: true)
        check(g5a.segments.isEmpty && g5a.dropped == 1, "TG5a no-speech and low logprob dropped", "\(g5a)")
        check(g5b.segments.count == 1, "TG5b no-speech with good logprob kept", "\(g5b)")
        check(g5c.segments.count == 1, "TG5c low logprob kept when not a retry", "\(g5c)")
        check(g5d.segments.isEmpty && g5d.dropped == 1, "TG5d low logprob dropped on a retry", "\(g5d)")

        let loop = String(repeating: "the ", count: 40)
        let g6a = guardNo.clean([seg(loop)], fromRetry: false)
        let sentence = "We met on Tuesday to review the budget for the new office and agreed that the hiring plan should wait until spring."
        let g6b = guardNo.clean([seg(sentence)], fromRetry: false)
        let ratio = guardNo.compressionRatio(sentence)
        check(g6a.segments.isEmpty && g6a.dropped == 1, "TG6a repetition loop dropped", String(format: "ratio %.2f", guardNo.compressionRatio(loop)))
        check(g6b.segments.count == 1 && ratio < 2.4, "TG6b normal sentence kept", String(format: "ratio %.2f", ratio))

        check(guardNo.needsRetry(words: 3, speech: 6), "TG7a 3 words in 6 s needs a retry", "")
        check(!guardNo.needsRetry(words: 3, speech: 4), "TG7b short piece never retried", "")
        check(!guardNo.needsRetry(words: 12, speech: 6), "TG7c enough words no retry", "")

        func cleaned(_ text: String) -> HallucinationGuard.Cleaned {
            HallucinationGuard.Cleaned(segments: [seg(text)], dropped: 0, inaudible: 0)
        }
        let pick = guardNo.best([cleaned("one two"), cleaned("one two three four five"), cleaned("a b c d e")])
        check(pick == 1, "TG8 best picks the most words, earlier on a tie", "\(pick)")
        check(guardNo.wordCount([seg("[inaudible]"), seg("Hello, big world . .")]) == 3, "TG8b word count", "")

        let json = """
        {"segments":[{"id":0,"text":" Four score, and","start":0.0,"end":0.9,"avg_logprob":-0.25,"no_speech_prob":0.01,
        "words":[{"word":" Four","start":0.0,"end":0.3,"probability":0.9},{"word":" sc","start":0.3,"end":0.4,"probability":0.9},
        {"word":"ore","start":0.4,"end":0.6,"probability":0.9},{"word":",","start":0.6,"end":0.6,"probability":0.9},
        {"word":" and","start":0.7,"end":0.9,"probability":0.9}]},
        {"id":1,"text":" Plain.","start":1.0,"end":2.0}]}
        """
        let parsed = WhisperReply.parse(Data(json.utf8))
        let first = parsed?.first
        check(parsed?.count == 2 && first?.words.map { $0.text } == ["Four", "score,", "and"]
              && first?.words.map({ $0.start }) == [0.0, 0.3, 0.7] && first?.words.map({ $0.end }) == [0.3, 0.6, 0.9],
              "TP1 tokens merge into words with times", "\(String(describing: first?.words))")
        check(first?.avgLogprob == -0.25 && first?.noSpeechProb == 0.01 && first?.start == 0 && first?.end == 0.9,
              "TP2 avg_logprob, no_speech_prob and times read", "")
        check(parsed?.last?.words.isEmpty == true && parsed?.last?.avgLogprob == nil && parsed?.last?.text == " Plain.",
              "TP3 segment without words", "")
        check(WhisperReply.parse(Data("not json".utf8)) == nil, "TP4 invalid JSON is nil", "")

        // P1-P5 the prompt echo.
        let pr = "I use talkflow, a dictation app."
        let longPrompt = "I'm Samir, and I use talkflow, a dictation app. Names and words here: Halvorsen, Pedalpoint."
        let p1 = guardNo.stripPrompt([seg("I use talkflow, a dictation app.")], prompt: pr)
        check(p1.segments.isEmpty && p1.removed == 1, "TG P1 the prompt alone is dropped", "\(p1)")
        let p2 = guardNo.stripPrompt([seg("Thank you. I use talkflow, a dictation app.", words: [TimedWord(text: "Thank", start: 0, end: 0.2)])], prompt: pr)
        check(p2.segments.count == 1 && p2.segments[0].text == "Thank you." && p2.segments[0].words.isEmpty && p2.removed == 1,
              "TG P2 the prompt after real words is cut off", "\(p2)")
        let p3 = guardNo.stripPrompt([seg("We use talkflow every day.")], prompt: pr)
        check(p3.segments == [seg("We use talkflow every day.")] && p3.removed == 0, "TG P3 a short overlap stays", "\(p3)")
        let p4 = guardNo.stripPrompt([seg("Halvorsen Design sent the quote.")], prompt: longPrompt)
        check(p4.segments == [seg("Halvorsen Design sent the quote.")] && p4.removed == 0, "TG P4 a name from the prompt stays", "\(p4)")
        let p5 = guardNo.stripPrompt([seg("and I use talkflow a dictation")], prompt: longPrompt)
        check(p5.segments.isEmpty && p5.removed == 1, "TG P5 a 6-word run without punctuation is dropped", "\(p5)")

        let wav = WavData.make([1, -2, 3][...])
        func tag(_ at: Int) -> String { String(decoding: wav[at..<at + 4], as: UTF8.self) }
        func u32(_ at: Int) -> Int { (0..<4).reduce(0) { $0 | Int(wav[at + $1]) << (8 * $1) } }
        check(wav.count == 50 && tag(0) == "RIFF" && tag(8) == "WAVE" && tag(12) == "fmt " && tag(36) == "data",
              "TW1 wav header tags and size", "\(wav.count)")
        check(u32(40) == 6 && u32(28) == 32000 && u32(4) == 42 && u32(24) == 16000, "TW2 wav data size and byte rate", "")
    }
}
