import Foundation
import Security

/// The user's own API keys, kept in the login Keychain rather than in
/// UserDefaults - a plist in ~/Library/Preferences is readable by anything
/// running as the user and ends up in backups in the clear.
enum APIKeys {
    enum Provider: String {
        case openAI = "openai"
        case anthropic = "anthropic"

        var name: String { self == .openAI ? "OpenAI" : "Anthropic" }
    }

    private static let service = "com.samir.talkflow.apikeys"
    /// Read once per provider and kept, so a hold never waits on the Keychain.
    private static var cache: [Provider: String] = [:]
    private static let lock = NSLock()

    static func key(for provider: Provider) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[provider] { return cached.isEmpty ? nil : cached }
        var query = baseQuery(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        let value = status == errSecSuccess ? (item as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? "" : ""
        cache[provider] = value
        return value.isEmpty ? nil : value
    }

    static func hasKey(_ provider: Provider) -> Bool { key(for: provider) != nil }

    @discardableResult
    static func save(_ value: String, for provider: Provider) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock(); defer { lock.unlock() }
        SecItemDelete(baseQuery(provider) as CFDictionary)
        var query = baseQuery(provider)
        query[kSecValueData as String] = Data(trimmed.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        cache[provider] = status == errSecSuccess ? trimmed : nil
        if status != errSecSuccess { print("talkflowd: could not save the \(provider.name) key to the Keychain (\(status))") }
        return status == errSecSuccess
    }

    static func remove(_ provider: Provider) {
        lock.lock(); defer { lock.unlock() }
        SecItemDelete(baseQuery(provider) as CFDictionary)
        cache[provider] = ""
    }

    private static func baseQuery(_ provider: Provider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: provider.rawValue]
    }
}
