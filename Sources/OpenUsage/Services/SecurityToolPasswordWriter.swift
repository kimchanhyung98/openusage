import Foundation
import Security

/// Claude Code 공유 항목은 기존 CLI 작성자로 갱신해 접근 승인 유지.
struct SecurityToolGenericPasswordWriter: GenericPasswordWriting {
    var keychainPath: String?
    var processRunner: any ProcessRunning = SystemProcessRunner()

    func write(service: String, account: String?, value: Data) throws {
        try NativeKeychainAccess.acquire()
        defer { NativeKeychainAccess.release() }
        var keychain: SecKeychain?
        try check(keychainPath.map { SecKeychainOpen($0, &keychain) } ?? SecKeychainCopyDefault(&keychain))
        guard let keychain else { throw GenericPasswordWriteError.securityStatus(errSecInvalidKeychain) }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchSearchList as String: [keychain],
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status != errSecItemNotFound { try check(status) }
        let matches: [[String: Any]]
        if status == errSecItemNotFound {
            matches = []
        } else if let items = result as? [[String: Any]] {
            matches = items
        } else {
            throw GenericPasswordWriteError.securityStatus(errSecDecode)
        }
        guard matches.count <= 1 else { throw GenericPasswordWriteError.ambiguousService }

        var bytes = [CChar](repeating: 0, count: Int(PATH_MAX))
        var length = UInt32(bytes.count)
        try check(SecKeychainGetPath(keychain, &length, &bytes))
        let path = String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let name = matches.first?[kSecAttrService as String] as? String ?? service
        let owner = matches.first?[kSecAttrAccount as String] as? String ?? account ?? ""
        let passwordArguments: [String]
        if let text = String(data: value, encoding: .utf8), !containsLineBreakOrNul(text) {
            passwordArguments = ["-w", text]
        } else {
            passwordArguments = ["-X", value.map { String(format: "%02x", $0) }.joined()]
        }
        let arguments = ["add-generic-password", "-U", "-s", name, "-a", owner] + passwordArguments + [path]
        let command = try arguments.map(quote).joined(separator: " ") + "\n"
        // security 대화형 입력은 행당 4096바이트 — 잘린 토큰 저장 전에 실패 처리.
        guard command.utf8.count < 4096 else {
            throw KeychainError.writeFailed(
                "The credential exceeds the Keychain tool's input limit; the stored credential was not changed.")
        }
        let written = try processRunner.run(
            executable: "/usr/bin/security", arguments: ["-i", "-q"], environment: [:], timeout: 5,
            standardInput: Data(command.utf8)
        )
        guard written.succeeded else {
            throw KeychainError.writeFailed("Keychain write failed (exit \(written.exitCode)).")
        }
    }

    private func quote(_ value: String) throws -> String {
        guard !containsLineBreakOrNul(value) else {
            throw KeychainError.writeFailed("Keychain item names contain unsupported control characters.")
        }
        return "\""
            + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private func containsLineBreakOrNul(_ value: String) -> Bool {
        value.utf8.contains { $0 == 0 || $0 == 10 || $0 == 13 }
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw GenericPasswordWriteError.securityStatus(status) }
    }
}
