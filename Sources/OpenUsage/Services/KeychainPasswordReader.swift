import Foundation
import Security

protocol GenericPasswordReading: Sendable {
    func read(service: String, account: String?, allowInteraction: Bool) throws -> String?
}

/// 프로세스 전체 승인 설정을 쓰는 동안 모든 native Keychain 접근 직렬화.
enum NativeKeychainAccess {
    private static let lock = NSLock()

    static func acquire() throws {
        guard lock.lock(before: Date().addingTimeInterval(5)) else {
            AppLog.error(.keychain, "native keychain access timed out waiting for another operation")
            throw KeychainError.accessBusy
        }
    }

    static func tryAcquire() -> Bool { lock.try() }

    static func release() { lock.unlock() }
}

/// 앱이 저장한 항목을 같은 서명 신원으로 읽고, 명시적으로 요청한 경우에만 승인 UI 허용.
struct SecurityFrameworkGenericPasswordReader: GenericPasswordReading {
    var keychainPath: String?

    func read(service: String, account: String?, allowInteraction: Bool) throws -> String? {
        // login Keychain은 쿼리의 UI 금지 옵션을 무시할 수 있어 상호작용 설정도 직렬화해 복원.
        try NativeKeychainAccess.acquire()
        defer { NativeKeychainAccess.release() }
        var interactionAllowed: DarwinBoolean = false
        let previousStatus = SecKeychainGetUserInteractionAllowed(&interactionAllowed)
        guard previousStatus == errSecSuccess else { throw readError(previousStatus) }
        let interactionStatus = SecKeychainSetUserInteractionAllowed(allowInteraction && interactionAllowed.boolValue)
        guard interactionStatus == errSecSuccess else { throw readError(interactionStatus) }
        defer {
            let status = SecKeychainSetUserInteractionAllowed(interactionAllowed.boolValue)
            if status != errSecSuccess {
                AppLog.error(.keychain, "keychain interaction policy restore failed (status \(status))")
            }
        }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        if !allowInteraction {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
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
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed {
            return .readFailed("OpenUsage needs access to this saved account in Keychain. Unlock Keychain and refresh manually to allow access.")
        }
        return .readFailed("Couldn't read the saved account from Keychain (status \(status)).")
    }
}

extension KeychainAccessing {
    func readAppOwnedPassword(service: String, forCurrentUser: Bool, allowInteraction: Bool) throws -> String? {
        try forCurrentUser
            ? readGenericPasswordForCurrentUser(service: service)
            : readGenericPassword(service: service)
    }
}
