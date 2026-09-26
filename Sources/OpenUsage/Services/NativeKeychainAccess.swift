import Foundation
import Security

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

extension GenericPasswordReading {
    func read(service: String, account: String?, allowInteraction: Bool) throws -> String? {
        // login Keychain은 쿼리의 UI 금지 옵션을 무시할 수 있어 프로세스 설정으로 제어 후 복원.
        try NativeKeychainAccess.acquire()
        defer { NativeKeychainAccess.release() }
        var interactionAllowed: DarwinBoolean = false
        try checkInteractionStatus(SecKeychainGetUserInteractionAllowed(&interactionAllowed))
        try checkInteractionStatus(SecKeychainSetUserInteractionAllowed(allowInteraction && interactionAllowed.boolValue))
        defer {
            let status = SecKeychainSetUserInteractionAllowed(interactionAllowed.boolValue)
            if status != errSecSuccess {
                AppLog.error(.keychain, "keychain interaction policy restore failed (status \(status))")
            }
        }
        do {
            return try read(service: service, account: account)
        } catch KeychainError.readFailed(let message) {
            throw KeychainError.readFailed(
                "\(message) If access needs approval, unlock Keychain and refresh manually."
            )
        }
    }

    private func checkInteractionStatus(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            AppLog.error(.keychain, "keychain interaction policy failed (status \(status))")
            throw KeychainError.readFailed("Couldn't configure Keychain access (status \(status)).")
        }
    }
}

extension KeychainAccessing {
    func readAppOwnedPassword(service: String, forCurrentUser: Bool, allowInteraction: Bool) throws -> String? {
        try forCurrentUser
            ? readGenericPasswordForCurrentUser(service: service)
            : readGenericPassword(service: service)
    }
}
