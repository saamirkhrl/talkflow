import Foundation

/// Sends audio to the local whisper-server for transcription.
///
/// The server is a LaunchAgent that stays up with the model already resident, so
/// a request costs only inference: measured on this M4 with small.en, 0.30s for
/// 5.8s of speech and 1.25s for 39s. That is what makes transcribing once, at the
/// end of the hold, feel instant rather than like waiting. large-v3-turbo and
/// medium.en took 2-4x as long and were dropped (see HANDOFF.md).
enum Transcriber {
    struct Result {
        let text: String
        let elapsed: TimeInterval
        /// How many segments whisper returned before they were joined. Logged,
        /// because a long hold's problems tend to sit at the segment seams.
        var segments = 1
    }

    /// whisper emits these bracketed placeholders instead of words when it hears
    /// no speech. They are not transcripts and must never reach the screen.
    private static let placeholders = [
        "[blank_audio]", "[silence]", "[typing]", "[music]", "[music playing]",
        "(soft music)", "(silence)", "[no speech]", "[inaudible]", "[applause]",
        "(upbeat music)", "[sound]", "(music)"
    ]

    static func isPlaceholder(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty { return true }
        if placeholders.contains(trimmed) { return true }
        // Anything wholly wrapped in brackets or parens is whisper narrating the
        // audio rather than transcribing speech.
        if (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) || (trimmed.hasPrefix("(") && trimmed.hasSuffix(")")) {
            return true
        }
        return false
    }

    /// whisper-server returns one segment per line, and past roughly 30 seconds
    /// of audio there is always more than one. A pause inside a long dictation
    /// comes back as a segment of its own reading `[BLANK_AUDIO]`, which
    /// `isPlaceholder` does not catch because the transcript as a whole is real
    /// speech - so the literal characters "[BLANK_AUDIO]" were typed into the
    /// user's document, at the end of exactly the long dictations that are
    /// hardest to notice it in. Measured, from the app's own log.
    ///
    /// Segments are dropped whole rather than pattern-matched inside a line: a
    /// placeholder is always its own segment, and editing within a segment would
    /// risk touching real words.
    ///
    /// What is left is joined with a SPACE. A segment boundary is where whisper's
    /// 30s window ended, which lands wherever the clock says, mid-sentence as
    /// often as not. Joining with "\n" typed a hard line break into the middle
    /// of a Gmail dictation ("post about your work\nWins, post about") and the
    /// capitalisation pass, which treats "\n" as a sentence start, capitalised
    /// the word after it. Measured on whisper-server: the next segment starts
    /// lowercase (" and the way that you"), so the capital was ours, not
    /// whisper's. A paragraph the user wants is spoken ("new paragraph") and
    /// handled by TextCommands, so nothing real is lost.
    ///
    /// whisper also closes its window with a period it did not hear
    /// ("around the product.\n over the last year"). When the next segment opens
    /// lowercase the sentence plainly carries on, so that one period is dropped.
    /// Abbreviations keep theirs.
    static func joinSegments(_ text: String) -> String {
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !isPlaceholder($0) }
        var joined = ""
        for segment in kept {
            if !joined.isEmpty {
                if segment.first?.isLowercase == true, closesWithCutPeriod(joined) { joined.removeLast() }
                joined += " "
            }
            joined += segment
        }
        return joined
    }

    private static let abbreviations: Set<String> = ["mr", "mrs", "ms", "dr", "prof", "st", "vs", "etc", "e.g", "i.e", "jr", "sr"]

    /// A single "." after an ordinary word - not "...", not "Dr.".
    private static func closesWithCutPeriod(_ text: String) -> Bool {
        guard text.hasSuffix("."), !text.hasSuffix("..") else { return false }
        let lastWord = text.dropLast().split(separator: " ").last.map { $0.lowercased() } ?? ""
        return !lastWord.isEmpty && !abbreviations.contains(lastWord)
    }

    /// Deliberately not the shared session.
    ///
    /// `URLSession.shared` caches according to the protocol, the whisper server
    /// sends no `Cache-Control`, and Foundation therefore wrote *both* directions
    /// of every transcription to disk: the multipart request body, which is the
    /// raw WAV of the user speaking, and the response body, which is the
    /// transcript. They accumulated unencrypted and survived reboots in
    /// `~/Library/Caches/com.samir.talkflow/Cache.db` - 18 audio blobs and
    /// readable sentences were found sitting there. The app believed audio never
    /// touched the disk, and its own code never put it there; the networking
    /// layer did, silently.
    ///
    /// Ephemeral keeps caches, cookies and credentials in memory only, a nil
    /// `urlCache` removes even the in-memory response cache, and the explicit
    /// policy on each request means nothing consults or populates a cache
    /// whatever a later configuration change does.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: configuration)
    }()

    /// Sent with every request as whisper's initial prompt, which biases its
    /// spelling towards the words in it. Without it the app's own name came out
    /// as "top flow" and "talk flow" in real dictation.
    ///
    /// Edit this sentence to teach whisper other names it mishears. Keep it a
    /// normal, capitalised, punctuated sentence: whisper imitates the prompt's
    /// STYLE as well as its words. Measured on the local server: the terse
    /// "Vocabulary: talkflow." made an unrelated clip come back with no capitals
    /// and no punctuation, and "I often mention talkflow." still wrote
    /// "topflow". This one fixed "top flow" and "talk flow", left silence and
    /// one-word clips as they were without it, and cost no measurable time.
    static let vocabularyPrompt = "I use talkflow, a dictation app."

    static func multipartBody(wav: Data, boundary: String, prompt: String) -> Data {
        var body = Data()
        func append(_ string: String) { body.append(contentsOf: Array(string.utf8)) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(wav)
        append("\r\n--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\ntext\r\n")
        if !prompt.isEmpty {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n\(prompt)\r\n")
        }
        append("--\(boundary)--\r\n")
        return body
    }

    static func transcribe(
        wav: Data,
        serverURL: URL,
        timeout: TimeInterval = 20,
        completion: @escaping (Result?) -> Void
    ) {
        let boundary = "talkflow-\(UUID().uuidString)"
        let body = multipartBody(wav: wav, boundary: boundary, prompt: vocabularyPrompt)

        var request = URLRequest(url: serverURL)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.httpBody = body

        let startedAt = Date()
        session.dataTask(with: request) { data, response, error in
            let elapsed = Date().timeIntervalSince(startedAt)
            if let error {
                print("talkflowd: transcription request failed after \(String(format: "%.2f", elapsed))s: \(error.localizedDescription)")
                completion(nil)
                return
            }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                print("talkflowd: transcription server returned HTTP \(code)")
                completion(nil)
                return
            }
            guard let data, let raw = String(data: data, encoding: .utf8) else {
                completion(nil)
                return
            }
            let text = joinSegments(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            let segments = raw.split(separator: "\n").filter { !isPlaceholder(String($0)) }.count
            completion(Result(text: text, elapsed: elapsed, segments: max(segments, 1)))
        }.resume()
    }
}
