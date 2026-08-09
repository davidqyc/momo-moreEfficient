import Foundation
import Security

protocol TokenStore: AnyObject {
    func loadToken() throws -> String?
    func saveToken(_ token: String) throws
    func deleteToken() throws
}

enum TokenStoreError: Error, Equatable {
    case unavailable
}

final class KeychainTokenStore: TokenStore, CustomDebugStringConvertible {
    static let service = "com.davidqyc.momoMoreEfficient.maimemo-token"
    static let account = "main-account"
    static let accessibility = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    static let isSynchronizable = false

    func loadToken() throws -> String? {
        var query = Self.identityAttributes
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8)
        else {
            throw TokenStoreError.unavailable
        }
        return token
    }

    func saveToken(_ token: String) throws {
        let data = Data(token.utf8)
        let updates: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: Self.accessibility,
        ]
        let updateStatus = SecItemUpdate(
            Self.identityAttributes as CFDictionary,
            updates as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw TokenStoreError.unavailable
        }

        let addStatus = SecItemAdd(Self.addAttributes(tokenData: data) as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw TokenStoreError.unavailable
        }
    }

    func deleteToken() throws {
        let status = SecItemDelete(Self.identityAttributes as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TokenStoreError.unavailable
        }
    }

    static var identityAttributes: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: isSynchronizable,
        ]
    }

    static func addAttributes(tokenData: Data) -> [String: Any] {
        var attributes = identityAttributes
        attributes[kSecValueData as String] = tokenData
        attributes[kSecAttrAccessible as String] = accessibility
        return attributes
    }

    var debugDescription: String { "KeychainTokenStore(<redacted>)" }
}
