import Foundation
import Security

/// APIトークンなどの秘密情報をKeychainに保存する
struct KeychainStore {
    let service: String

    init(service: String = "com.nsan.smartdashboard") {
        self.service = service
    }

    func string(for account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 空文字またはnilを渡すと削除する
    @discardableResult
    func set(_ value: String?, for account: String) -> Bool {
        SecItemDelete(baseQuery(account) as CFDictionary)
        guard let value, !value.isEmpty else { return true }
        var query = baseQuery(account)
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

enum KeychainAccount {
    static let odptToken = "odpt.consumerKey"
}
