import Foundation
import Combine
import Security
#if canImport(AppKit)
import AppKit
#endif

extension VeeamAPIService {
    // MARK: - Date decoder

    func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dec in
            let container = try dec.singleValueContainer()
            let str = try container.decode(String.self)
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unrecognised date: \(str)"
                )
            }
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = fmt.date(from: trimmed) { return d }
            fmt.formatOptions = [.withInternetDateTime]
            if let d = fmt.date(from: trimmed) { return d }

            let fallbackFormats = [
                "M/d/yyyy h:mm:ss a",
                "M/d/yyyy h:mm a",
                "M/d/yyyy H:mm:ss",
                "M/d/yyyy H:mm"
            ]
            let fallback = DateFormatter()
            fallback.locale = Locale(identifier: "en_US_POSIX")
            fallback.timeZone = TimeZone.current
            for format in fallbackFormats {
                fallback.dateFormat = format
                if let date = fallback.date(from: trimmed) {
                    return date
                }
            }

            throw DecodingError.dataCorruptedError(in: container,
                debugDescription: "Unrecognised date: \(str)")
        }
        return decoder
    }

    // MARK: - Keychain

    func loadSavedCredentials() -> SavedCredentials? {
        if let mostRecentURL = savedConnectionURLs().first,
           let saved = loadSavedCredentials(for: mostRecentURL) {
            return saved
        }

        return loadLegacyCredentials()
    }

    func loadSavedCredentials(for serverURL: String) -> SavedCredentials? {
        let normalizedURL = normalisedServerURL(serverURL)

        guard let encoded = keychainRead(key: connectionKey(for: normalizedURL)),
              let data = encoded.data(using: .utf8),
              let stored = try? JSONDecoder().decode(StoredConnection.self, from: data) else {
            return nil
        }

        return SavedCredentials(
            serverURL: stored.serverURL,
            username: stored.username,
            password: stored.password,
            friendlyName: stored.friendlyName
        )
    }

    func savedConnectionEntries() -> [SavedConnectionEntry] {
        savedConnectionURLs().compactMap { url in
            guard let saved = loadSavedCredentials(for: url) else { return nil }
            let fallbackName = URL(string: saved.serverURL)?.host ?? saved.serverURL
            let displayName = saved.friendlyName?.trimmingCharacters(in: .whitespacesAndNewlines)
            return SavedConnectionEntry(
                serverURL: saved.serverURL,
                friendlyName: ((displayName?.isEmpty == false) ? displayName! : fallbackName).uppercased()
            )
        }
    }

    func deleteSavedConnection(serverURL: String) {
        let normalizedURL = normalisedServerURL(serverURL)
        keychainDelete(key: connectionKey(for: normalizedURL))
        let updated = savedConnectionURLs().filter { normalisedServerURL($0) != normalizedURL }
        UserDefaults.standard.set(updated, forKey: Self.defaultsConnectionHistoryKey)
    }

    func savedConnectionURLs() -> [String] {
        guard let urls = UserDefaults.standard.array(forKey: Self.defaultsConnectionHistoryKey) as? [String] else {
            return []
        }

        return urls
    }

    func saveCredentials(serverURL: String, username: String, password: String, friendlyName: String? = nil) {
        let normalizedURL = normalisedServerURL(serverURL)
        let normalizedFriendly = friendlyName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingFriendly = loadSavedCredentials(for: normalizedURL)?.friendlyName
        let resolvedFriendly = ((normalizedFriendly?.isEmpty == false) ? normalizedFriendly : existingFriendly)?.uppercased()
        let stored = StoredConnection(
            serverURL: normalizedURL,
            username: username,
            password: password,
            friendlyName: (resolvedFriendly?.isEmpty == false) ? resolvedFriendly : nil
        )

        guard let data = try? JSONEncoder().encode(stored),
              let payload = String(data: data, encoding: .utf8) else {
            return
        }

        keychainWrite(key: connectionKey(for: normalizedURL), value: payload)
        saveConnectionHistoryEntry(normalizedURL)
        deleteLegacyCredentials()
    }

    func saveConnectionHistoryEntry(_ serverURL: String) {
        var urls = savedConnectionURLs().filter { $0 != serverURL }
        urls.insert(serverURL, at: 0)
        UserDefaults.standard.set(urls, forKey: Self.defaultsConnectionHistoryKey)
    }

    func loadLegacyCredentials() -> SavedCredentials? {
        guard let serverURL = keychainRead(key: "serverURL"),
              let username = keychainRead(key: "username"),
              let password = keychainRead(key: "password") else {
            return nil
        }

        let saved = SavedCredentials(serverURL: serverURL, username: username, password: password, friendlyName: nil)
        saveCredentials(serverURL: serverURL, username: username, password: password, friendlyName: nil)
        return saved
    }

    func deleteLegacyCredentials() {
        keychainDelete(key: "serverURL")
        keychainDelete(key: "username")
        keychainDelete(key: "password")
    }

    func connectionKey(for serverURL: String) -> String {
        "\(Self.keychainConnectionPrefix)\(serverURL)"
    }

    func normalisedServerURL(_ serverURL: String) -> String {
        var value = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.lowercased().hasPrefix("http://") && !value.lowercased().hasPrefix("https://") {
            value = "https://\(value)"
        }
        while value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }

    func keychainWrite(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: Self.keychainService,
                                    kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(attrs as CFDictionary, nil)
    }

    func keychainRead(key: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: Self.keychainService,
                                    kSecAttrAccount as String: key,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func keychainDelete(key: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: Self.keychainService,
                                    kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
    }
}
