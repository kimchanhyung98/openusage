import Foundation
import Security

protocol GenericPasswordReading: Sendable {
    func read(service: String, account: String?) throws -> String?
}

/// 앱이 저장한 항목을 같은 서명 신원으로 조회.
struct SecurityFrameworkGenericPasswordReader: GenericPasswordReading {
    var keychainPath: String?

    func read(service: String, account: String?) throws -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        if let keychainPath {
            var keychain: SecKeychain?
            let status = SecKeychainOpen(keychainPath, &keychain)
            guard status == errSecSuccess, let keychain else { throw readError(status) }
            query[kSecMatchSearchList as String] = [keychain]
        }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw readError(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw readError(errSecDecode)
        }
        return value
    }

    private func readError(_ status: OSStatus) -> KeychainError {
        AppLog.error(.keychain, "account credential read failed (status \(status))")
        return .readFailed("Couldn't read the saved account from Keychain (status \(status)).")
    }
}
