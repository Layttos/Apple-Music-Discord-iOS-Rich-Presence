import Foundation
import Security

/// Stockage du jeton d'appareil dans le trousseau.
///
/// Le jeton autorise l'écriture sur l'API : il n'a rien à faire dans
/// `UserDefaults`, qui est lisible depuis une sauvegarde non chiffrée.
enum Keychain {
    private static let service = "dev.layttos.AppleMusicPresenceLocal"

    static func set(_ value: String, for account: String) {
        let data = Data(value.utf8)

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        // Un jeton doit rester lisible quand l'app tourne en arrière-plan,
        // écran verrouillé : `AfterFirstUnlock` est le bon compromis.
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            query.merge(attributes) { current, _ in current }
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }

        return value
    }

    static func remove(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
