import Foundation

/// The punctuation pass run by Claude with the user's own key (Settings:
/// "Use my Anthropic key"), in place of Apple's on-device model. Anthropic has
/// no speech-to-text API, so this is the only place a Claude key is used.
///
/// The same guarantee as `Polish`: Claude's answer is never inserted as is.
/// It goes through `Polish.merge`, which keeps the original words and takes
/// only punctuation, casing and line breaks from it, and then has to pass
/// `SelfCorrection.isDeletionOnly`.
enum ClaudePolish {
    enum Model: String, CaseIterable {
        case opus = "claude-opus-5-5"
        case sonnet = "claude-sonnet-5-5"
        case haiku = "claude-haiku-4-5"

        var title: String {
            switch self {
            case .opus: return "Claude Opus 5.5"
            case .sonnet: return "Claude Sonnet 5.5"
            case .haiku: return "Claude Haiku 4.5 (fastest)"
            }
        }
    }

    /// Longer than the on-device budget: a network round-trip plus a large
    /// model. Past it the text goes in unpunctuated by Claude, never late.
    static let budget: TimeInterval = 6

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    /// Text only, but still the user's dictation: never cached to disk.
    private static var session: URLSession { CloudTranscriber.session }

    /// Calls `completion` on the main queue with the polished text, or with
    /// `text` unchanged and an error message for the pill.
    static func run(_ text: String, names: [String], completion: @escaping (String, String?) -> Void) {
        guard let key = APIKeys.key(for: .anthropic) else {
            DispatchQueue.main.async { completion(text, "Claude: no API key saved") }
            return
        }
        let model = Preferences.claudeModel
        var body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": 4096,
            "system": Polish.instructions,
            "messages": [["role": "user", "content": text]]
        ]
        var request = URLRequest(url: endpoint)
        if model != .haiku {
            // Thinking cannot be turned off on these models; low effort keeps
            // it short. Haiku 4.5 takes no effort setting.
            body["output_config"] = ["effort": "low"]
            // A safety classifier declining dictated text re-runs it on the
            // recommended fallback model instead of failing.
            body["fallbacks"] = "default"
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        request.httpMethod = "POST"
        request.timeoutInterval = budget
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let startedAt = Date()
        session.dataTask(with: request) { data, response, error in
            let result: (String, String?)
            defer { DispatchQueue.main.async { completion(result.0, result.1) } }
            if let error {
                let timedOut = (error as? URLError)?.code == .timedOut
                result = (text, timedOut ? "Claude took longer than \(Int(budget))s, inserted without it" : "Claude unreachable: \(error.localizedDescription)")
                return
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(code), let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                result = (text, failureMessage(code: code, data: data))
                return
            }
            if json["stop_reason"] as? String == "refusal" {
                result = (text, "Claude declined this text, inserted without it")
                return
            }
            let reply = (json["content"] as? [[String: Any]] ?? [])
                .filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
                .joined()
            let merged = Polish.merge(original: text, suggestion: reply, names: names)
            let safe = SelfCorrection.isDeletionOnly(original: text, result: merged) ? merged : text
            print("talkflowd: Claude punctuation (\(model.rawValue)) \(safe == text ? "changed nothing" : "applied") in \(String(format: "%.2f", Date().timeIntervalSince(startedAt)))s")
            result = (safe, nil)
        }.resume()
    }

    /// Checks a key before it is saved: lists models, which costs nothing.
    static func validate(_ key: String, completion: @escaping (String?) -> Void) {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models")!)
        request.timeoutInterval = 10
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        session.dataTask(with: request) { data, response, error in
            if let error { completion("Anthropic unreachable: \(error.localizedDescription)"); return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            completion((200..<300).contains(code) ? nil : failureMessage(code: code, data: data))
        }.resume()
    }

    private static func failureMessage(code: Int, data: Data?) -> String {
        switch code {
        case 401, 403: return "Anthropic rejected your API key"
        case 429: return "Claude: rate limit reached"
        case 529: return "Claude is overloaded, inserted without it"
        default:
            let detail = CloudTranscriber.errorDetail(data)
            return "Claude error \(code)" + (detail.isEmpty ? "" : ": \(detail)")
        }
    }
}
