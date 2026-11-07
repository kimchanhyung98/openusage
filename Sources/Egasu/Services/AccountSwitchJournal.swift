import CryptoKit
import Foundation

/// Claude 전환의 선택 복구 기록 — 인증 원문 없이 계정 ID·신원·세대 해시만 보관.
struct AccountSwitchJournal: Sendable {
    struct Record: Codable, Equatable, Sendable {
        var id = UUID()
        var previousProfileID: String
        var previousIdentity: String
        var previousCredentialFingerprint: String?
        var previousStateFingerprint: String?
        var priorSelectionIDs: [String] = []
        var selectedProfileID: String
        var selectedIdentity: String
        var selectedCredentialFingerprint: String
    }

    struct SharedState: Codable, Equatable, Sendable {
        var credentials: [String?]
        var accounts: [String?]
        var identities: [String?]

        func fingerprint() throws -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return AccountSwitchJournal.fingerprint(try encoder.encode(self))
        }

        func matches(credentialFingerprint: String, identity: String, requiresAllSources: Bool) -> Bool {
            if requiresAllSources,
               (credentials.contains(where: { $0 == nil }) || identities.contains(where: { $0 == nil })) {
                return false
            }
            let presentCredentials = credentials.compactMap { $0 }
            let presentIdentities = identities.compactMap { $0 }
            return !presentCredentials.isEmpty && !presentIdentities.isEmpty
                && presentCredentials.allSatisfy { AccountSwitchJournal.fingerprint($0) == credentialFingerprint }
                && presentIdentities.allSatisfy { $0 == identity }
                && zip(accounts, identities).allSatisfy { $0 == nil || $1 != nil }
        }
    }

    let path: String
    private let files: any TextFileAccessing

    init(path: String, files: any TextFileAccessing = LocalTextFileAccessor()) {
        self.path = path
        self.files = files
    }

    func load() throws -> Record? {
        guard let text = try files.readTextIfPresent(path) else { return nil }
        guard let record = try? JSONDecoder().decode(Record.self, from: Data(text.utf8)),
              !record.previousProfileID.isEmpty, !record.previousIdentity.isEmpty,
              !record.selectedProfileID.isEmpty, !record.selectedIdentity.isEmpty,
              record.priorSelectionIDs.allSatisfy({ !$0.isEmpty }),
              Self.isFingerprint(record.selectedCredentialFingerprint),
              record.previousCredentialFingerprint.map(Self.isFingerprint) ?? true,
              record.previousStateFingerprint.map(Self.isFingerprint) ?? true
        else {
            AppLog.error(.auth, "account switch journal is unreadable; preserving it and blocking reconciliation")
            throw AccountIdentityReplacementError.invalidTransaction
        }
        return record
    }

    func save(_ record: Record, replacing previous: Record?) throws {
        guard try load() == previous else { throw AccountIdentityReplacementError.pendingTransaction }
        let data = try JSONEncoder().encode(record)
        try files.writeText(path, String(decoding: data, as: UTF8.self))
        guard try load() == record else { throw AccountIdentityReplacementError.invalidTransaction }
    }

    func clear(_ record: Record) throws {
        guard try load() == record else { throw AccountIdentityReplacementError.pendingTransaction }
        try files.remove(path)
        guard try load() == nil else { throw AccountIdentityReplacementError.invalidTransaction }
    }

    static func fingerprint(_ text: String) -> String {
        fingerprint(Data(text.utf8))
    }

    private static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isFingerprint(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}
