import Foundation
import Security

/// Holds only the user's private backend address and its revocable device token.
/// An OpenAI/provider key is never stored by the iPhone application.
enum AIConfiguration {
    private static let urlKey = "office.ai.backendURL"
    private static let service = "com.arhitektoffice.backend-access"

    static var savedURL: String { UserDefaults.standard.string(forKey: urlKey) ?? "" }
    static var baseURL: URL? {
        guard let url = URL(string: savedURL), url.scheme?.lowercased() == "https",
              url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { return nil }
        return url
    }

    static func accessToken(for url: URL) throws -> String {
        var query = keychainQuery(account: url.absoluteString)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data, let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            throw AIError.notConfigured
        }
        return token
    }

    static func save(address: String, token: String) throws {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw AIError.invalidResponse("Unesite valjanu HTTPS adresu poslužitelja bez korisničkog imena, upita ili lozinke u adresi.")
        }
        if !token.isEmpty {
            let query = keychainQuery(account: url.absoluteString)
            let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8),
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
            var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
            }
            guard status == errSecSuccess else {
                throw AIError.invalidResponse("Pristupni token nije moguće sigurno spremiti u privjesak ključeva.")
            }
        } else { _ = try accessToken(for: url) }
        UserDefaults.standard.set(url.absoluteString, forKey: urlKey)
    }

    static func remove() {
        if let url = baseURL { SecItemDelete(keychainQuery(account: url.absoluteString) as CFDictionary) }
        UserDefaults.standard.removeObject(forKey: urlKey)
    }

    private static func keychainQuery(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}
