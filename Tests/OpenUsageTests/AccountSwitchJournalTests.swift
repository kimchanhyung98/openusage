import Foundation
import XCTest
@testable import OpenUsage

final class AccountSwitchJournalTests: XCTestCase {
    func testForeignAccountJournalDoesNotBlockOrChangeDuringCurrentUserJournalLifecycle() throws {
        let foreignValue = "foreign-account-journal"
        let keychain = JournalAccountKeychain(foreignValue: foreignValue)
        let journal = AccountSwitchJournal(keychain: keychain)
        let entry = AccountCredentialVault.Entry(
            credential: #"{"tokens":{"access_token":"target-token","account_id":"acct-b"}}"#,
            claudeOAuthAccount: nil
        )
        let transition = AccountSwitchTransition(
            family: "codex",
            previousProfileID: "previous",
            targetProfileID: "target",
            targetIdentityKey: "acct-b",
            targetSnapshotDigest: try entry.snapshotDigest(),
            original: .codex(authFile: .init(data: nil, permissions: nil, modificationDate: nil)),
            applied: .codex(authFile: .init(
                data: Data(entry.credential.utf8), permissions: 0o600, modificationDate: nil
            ))
        )

        XCTAssertTrue(try journal.hasPending())
        XCTAssertNil(try journal.load())
        XCTAssertNil(keychain.storage.currentUserValues[AccountSwitchJournal.service])

        try journal.save(transition)

        XCTAssertTrue(try journal.hasPending())
        XCTAssertEqual(try journal.load(), transition)
        XCTAssertNotNil(keychain.storage.currentUserValues[AccountSwitchJournal.service])
        XCTAssertEqual(keychain.storage.values, [AccountSwitchJournal.service: foreignValue])

        try journal.clear(transition)

        XCTAssertTrue(try journal.hasPending())
        XCTAssertNil(try journal.load())
        XCTAssertNil(keychain.storage.currentUserValues[AccountSwitchJournal.service])
        XCTAssertEqual(keychain.storage.values, [AccountSwitchJournal.service: foreignValue])
        XCTAssertEqual(keychain.generalReadCount, 0)
    }
}

private final class JournalAccountKeychain: KeychainAccessing, @unchecked Sendable {
    let storage: ServiceKeychain
    private(set) var generalReadCount = 0

    init(foreignValue: String) {
        storage = ServiceKeychain(values: [AccountSwitchJournal.service: foreignValue])
    }

    func genericPasswordExists(service: String) -> Bool? {
        storage.values[service] != nil || storage.currentUserValues[service] != nil
    }

    func readAppOwnedPassword(service: String, forCurrentUser: Bool, allowInteraction: Bool) throws -> String? {
        if forCurrentUser {
            return try storage.readGenericPasswordForCurrentUser(service: service)
        }
        return try readGenericPassword(service: service)
    }

    func readGenericPassword(service: String) throws -> String? {
        generalReadCount += 1
        return try storage.readGenericPassword(service: service)
    }

    func readGenericPasswordForCurrentUser(service: String) throws -> String? {
        try storage.readGenericPasswordForCurrentUser(service: service)
    }

    func writeGenericPassword(service: String, value: String) throws {
        try storage.writeGenericPassword(service: service, value: value)
    }

    func writeGenericPasswordForCurrentUser(service: String, value: String) throws {
        try storage.writeGenericPasswordForCurrentUser(service: service, value: value)
    }

    func deleteGenericPassword(service: String) throws {
        try storage.deleteGenericPassword(service: service)
    }

    func deleteGenericPasswordForCurrentUser(service: String) throws {
        storage.currentUserValues.removeValue(forKey: service)
        storage.currentUserModificationDates.removeValue(forKey: service)
    }
}
