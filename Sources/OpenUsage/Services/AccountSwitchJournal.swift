import Foundation

struct AccountSwitchTransition: Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var family: String
    var previousProfileID: String?
    var targetProfileID: String
    var targetIdentityKey: String
    var targetSnapshotDigest: String
    var original: AccountCredentialArtifacts.Snapshot
    var applied: AccountCredentialArtifacts.Snapshot
}

/// 선택 저장까지 유지하는 공유 인증 전환 기록 — 원본 인증은 앱 소유 Keychain에만 보관.
struct AccountSwitchJournal {
    static let service = "OpenUsage Account Switch Recovery v1"

    enum Error: LocalizedError, Equatable {
        case presenceUnknown
        case invalidRecord
        case pendingTransition
        case recordChanged
        case saveVerificationFailed

        var errorDescription: String? {
            switch self {
            case .presenceUnknown:
                "OpenUsage couldn't check for an unfinished account switch. Try again after the next refresh."
            case .invalidRecord:
                "The saved account switch could not be read. Its recovery record was left unchanged."
            case .pendingTransition:
                "Another account switch is still being recovered. Try again after the next refresh."
            case .recordChanged:
                "The saved account switch changed during recovery. Its current record was left unchanged."
            case .saveVerificationFailed:
                "The account switch recovery record could not be verified. Try again before switching accounts."
            }
        }
    }

    private let keychain: any KeychainAccessing

    init(keychain: any KeychainAccessing) {
        self.keychain = keychain
    }

    func hasPending() throws -> Bool {
        switch keychain.genericPasswordExists(service: Self.service) {
        case .some(false): return false
        case .none: throw Error.presenceUnknown
        case .some(true): return true
        }
    }

    func load(allowInteraction: Bool = false) throws -> AccountSwitchTransition? {
        guard try hasPending() else { return nil }
        let value: String?
        do {
            value = try keychain.readAppOwnedPassword(
                service: Self.service, forCurrentUser: true, allowInteraction: allowInteraction
            )
        } catch KeychainError.invalidData {
            throw Error.invalidRecord
        }
        guard let value else { return nil }
        guard let transaction = try? JSONDecoder().decode(AccountSwitchTransition.self, from: Data(value.utf8)) else {
            throw Error.invalidRecord
        }
        try validate(transaction)
        return transaction
    }

    func save(_ transaction: AccountSwitchTransition, allowInteraction: Bool = false) throws {
        try validate(transaction)
        guard try load(allowInteraction: allowInteraction) == nil else { throw Error.pendingTransition }
        let data = try JSONEncoder().encode(transaction)
        try keychain.writeAppOwnedPassword(
            service: Self.service, value: String(decoding: data, as: UTF8.self),
            forCurrentUser: true, allowInteraction: allowInteraction
        )
        guard try load(allowInteraction: allowInteraction) == transaction else { throw Error.saveVerificationFailed }
    }

    func clear(_ transaction: AccountSwitchTransition, allowInteraction: Bool = false) throws {
        guard try load(allowInteraction: allowInteraction) == transaction else { throw Error.recordChanged }
        try keychain.deleteGenericPasswordForCurrentUser(service: Self.service)
    }

    private func validate(_ transaction: AccountSwitchTransition) throws {
        guard AccountProfilesStore.isSupportedFamily(transaction.family),
              transaction.original.family == transaction.family,
              transaction.applied.family == transaction.family,
              isValidProfileID(transaction.targetProfileID),
              transaction.previousProfileID.map(isValidProfileID) ?? true,
              !transaction.targetIdentityKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              transaction.targetSnapshotDigest.utf8.count == 64,
              transaction.targetSnapshotDigest.utf8.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0)
              }) else {
            throw Error.invalidRecord
        }
    }

    private func isValidProfileID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && !id.contains("/") && !id.contains("\\")
            && !id.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }
}
