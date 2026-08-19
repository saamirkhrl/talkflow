import Foundation

/// Sends audio to the local whisper-server for transcription.
///
/// The server is a LaunchAgent that stays up with the model already resident, so
/// a request costs only inference: measured on this M4, 0.35s for 5.7s of speech
/// and 0.37s for 7.7s with small.en. That is what makes transcribing once, at the
/// end of the hold, feel instant rather than like waiting.
enum Transcriber {
    struct Result {
        let text: String
        let elapsed: TimeInterval
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
    static func stripPlaceholderSegments(_ text: String) -> String {
        let segments = text.split(separator: "\n", omittingEmptySubsequences: false)
        let kept = segments
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !isPlaceholder($0) }
        return kept.joined(separator: "\n")
    }

    static func transcribe(
        wav: Data,
        serverURL: URL,
        timeout: TimeInterval = 20,
        completion: @escaping (Result?) -> Void
    ) {
        let boundary = "talkflow-\(UUID().uuidString)"
        var body = Data()
        func append(_ string: String) { body.append(contentsOf: Array(string.utf8)) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(wav)
        append("\r\n--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\ntext\r\n")
        append("--\(boundary)--\r\n")

        var request = URLRequest(url: serverURL)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        request.httpBody = body

        let startedAt = Date()
        URLSession.shared.dataTask(with: request) { data, response, error in
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
            let text = stripPlaceholderSegments(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            completion(Result(text: text, elapsed: elapsed))
        }.resume()
    }
}
