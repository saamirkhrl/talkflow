import Foundation

/// The final pass, transcribed by OpenAI with the user's own key (Settings:
/// "Use my OpenAI key"). The live caption never comes here: it runs every
/// 0.7s while the key is held, and sending each tick to the cloud would cost
/// money and still be slower than the local server.
enum CloudTranscriber {
    static let model = "gpt-4o-transcribe"
    private static let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!

    /// Same reasoning as `Transcriber.session`: the request body is the
    /// user's voice and must never be cached to disk.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: configuration)
    }()

    enum Failure: Error {
        case noKey
        case rejectedKey
        case quota
        case http(Int, String)
        case network(String)

        /// Short enough to read on the pill.
        var message: String {
            switch self {
            case .noKey: return "OpenAI: no API key saved"
            case .rejectedKey: return "OpenAI rejected your API key"
            case .quota: return "OpenAI: rate limit or out of credit"
            case .http(let code, let detail): return "OpenAI error \(code)" + (detail.isEmpty ? "" : ": \(detail)")
            case .network(let detail): return "OpenAI unreachable: \(detail)"
            }
        }
    }

    static func transcribe(wav: Data, prompt: String, timeout: TimeInterval = 12,
                           completion: @escaping (Swift.Result<Transcriber.Result, Failure>) -> Void) {
        guard let key = APIKeys.key(for: .openAI) else { completion(.failure(.noKey)); return }
        let boundary = "talkflow-\(UUID().uuidString)"
        var body = Data()
        func append(_ string: String) { body.append(contentsOf: Array(string.utf8)) }
        func field(_ name: String, _ value: String) {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        body.append(wav)
        append("\r\n")
        field("model", model)
        field("response_format", "text")
        if !prompt.isEmpty { field("prompt", prompt) }
        append("--\(boundary)--\r\n")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let startedAt = Date()
        session.dataTask(with: request) { data, response, error in
            let elapsed = Date().timeIntervalSince(startedAt)
            if let error { completion(.failure(.network(error.localizedDescription))); return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(code), let data, let raw = String(data: data, encoding: .utf8) else {
                completion(.failure(failure(code: code, data: data)))
                return
            }
            let text = Transcriber.joinSegments(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            completion(.success(Transcriber.Result(text: text, elapsed: elapsed)))
        }.resume()
    }

    /// Checks a key before it is saved: lists models, which costs nothing.
    static func validate(_ key: String, completion: @escaping (String?) -> Void) {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.timeoutInterval = 10
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        session.dataTask(with: request) { data, response, error in
            if let error { completion(Failure.network(error.localizedDescription).message); return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            completion((200..<300).contains(code) ? nil : failure(code: code, data: data).message)
        }.resume()
    }

    private static func failure(code: Int, data: Data?) -> Failure {
        switch code {
        case 401, 403: return .rejectedKey
        case 429: return .quota
        default: return .http(code, errorDetail(data))
        }
    }

    /// `{"error": {"message": "..."}}`, the shape both OpenAI and Anthropic use.
    static func errorDetail(_ data: Data?) -> String {
        guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any], let message = error["message"] as? String else { return "" }
        return String(message.prefix(80))
    }
}
