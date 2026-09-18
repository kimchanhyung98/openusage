import Foundation
import Security

protocol GenericPasswordWriting: Sendable {
    /// `account == nil`은 기존 service-only 항목 하나를 정확히 찾아 갱신하고, 부재 시 빈 account로 생성.
    func write(service: String, account: String?, value: Data) throws
}

enum GenericPasswordWriteError: Error, LocalizedError, Equatable {
    case ambiguousService
    case securityStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .ambiguousService:
            "Multiple Keychain items matched the service; no credential was changed."
        case .securityStatus(let status):
            "Keychain write failed (status \(status))."
        }
    }
}

struct SecurityFrameworkGenericPasswordWriter: GenericPasswordWriting {
    private let keychainPathOverride: String?
    private let searchListPathsOverride: [String]?

    init(keychainPath: String? = nil, searchListPaths: [String]? = nil) {
        keychainPathOverride = keychainPath
        searchListPathsOverride = searchListPaths
    }

    func write(service: String, account requestedAccount: String?, value: Data) throws {
        let keychains = try keychainsToSearch()
        let existingItem: ExistingItem?
        let account: String
        if let requestedAccount {
            account = requestedAccount
            existingItem = try singleExistingItem(service: service, account: account, keychains: keychains)
        } else {
            existingItem = try singleExistingItem(service: service, account: nil, keychains: keychains)
            account = existingItem?.account ?? ""
        }
        if let existingItem {
            try update(existingItem, value: value)
            return
        }

        let keychain = try defaultKeychain()
        var item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseKeychain as String: keychain,
        ]
        item[kSecValueData as String] = value
        item[kSecAttrLabel as String] = service
        item[kSecAttrDescription as String] = "application password"
        item[kSecAttrAccess as String] = try makeAccess(label: service)
        switch SecItemAdd(item as CFDictionary, nil) {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            guard let racedItem = try singleExistingItem(
                service: service,
                account: account,
                keychains: [keychain]
            ) else {
                throw GenericPasswordWriteError.securityStatus(errSecDuplicateItem)
            }
            try update(racedItem, value: value)
        case let status:
            throw GenericPasswordWriteError.securityStatus(status)
        }
    }

    private struct ExistingItem {
        var account: String
        var persistentReference: Data
    }

    private func defaultKeychain() throws -> SecKeychain {
        if let keychainPathOverride {
            return try openKeychain(at: keychainPathOverride)
        }
        var keychain: SecKeychain?
        let status = SecKeychainCopyDefault(&keychain)
        guard status == errSecSuccess, let keychain else {
            throw GenericPasswordWriteError.securityStatus(status)
        }
        return keychain
    }

    private func keychainsToSearch() throws -> [SecKeychain]? {
        let paths = searchListPathsOverride ?? keychainPathOverride.map { [$0] }
        return try paths?.map { try openKeychain(at: $0) }
    }

    private func openKeychain(at path: String) throws -> SecKeychain {
        var keychain: SecKeychain?
        let status = SecKeychainOpen(path, &keychain)
        guard status == errSecSuccess, let keychain else {
            throw GenericPasswordWriteError.securityStatus(status)
        }
        return keychain
    }

    private func singleExistingItem(
        service: String,
        account: String?,
        keychains: [SecKeychain]?
    ) throws -> ExistingItem? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: account == nil ? kSecMatchLimitAll : kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
            kSecReturnPersistentRef as String: true,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        if let keychains {
            query[kSecMatchSearchList as String] = keychains
        }
        if let account {
            query[kSecAttrAccount as String] = account
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw GenericPasswordWriteError.securityStatus(status)
        }

        let items: [[String: Any]]
        if let array = result as? [[String: Any]] {
            items = array
        } else if let item = result as? [String: Any] {
            items = [item]
        } else {
            throw GenericPasswordWriteError.securityStatus(errSecInternalError)
        }
        guard items.count == 1 else { throw GenericPasswordWriteError.ambiguousService }
        let item = items[0]
        guard let persistentReference = item[kSecValuePersistentRef as String] as? Data else {
            throw GenericPasswordWriteError.securityStatus(errSecInternalError)
        }
        return ExistingItem(
            account: (item[kSecAttrAccount as String] as? String) ?? "",
            persistentReference: persistentReference
        )
    }

    private func update(_ item: ExistingItem, value: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecValuePersistentRef as String: item.persistentReference,
        ]
        let status = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: value] as CFDictionary
        )
        guard status == errSecSuccess else {
            throw GenericPasswordWriteError.securityStatus(status)
        }
    }

    private func makeAccess(label: String) throws -> SecAccess {
        var currentApplication: SecTrustedApplication?
        var securityTool: SecTrustedApplication?
        var status = SecTrustedApplicationCreateFromPath(nil, &currentApplication)
        guard status == errSecSuccess, let currentApplication else {
            throw GenericPasswordWriteError.securityStatus(status)
        }
        status = SecTrustedApplicationCreateFromPath("/usr/bin/security", &securityTool)
        guard status == errSecSuccess, let securityTool else {
            throw GenericPasswordWriteError.securityStatus(status)
        }
        var access: SecAccess?
        status = SecAccessCreate(label as CFString, [currentApplication, securityTool] as CFArray, &access)
        guard status == errSecSuccess, let access else {
            throw GenericPasswordWriteError.securityStatus(status)
        }
        return access
    }
}
