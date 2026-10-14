import Foundation
import XCTest
@testable import OpenUsage

final class CodexCredentialMutationSerializationTests: XCTestCase {
    func testSharedAccountSwitchCannotInterleaveWithRefreshWriteback() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageTests.CodexMutation.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let codexHome = home.appendingPathComponent(".codex", isDirectory: true)
        let authFile = codexHome.appendingPathComponent("auth.json")
        let originalText = authText(accessToken: "account-a-original", accountID: "account-a")
        let switchedText = authText(accessToken: "account-b", accountID: "account-b")
        try LocalTextFileAccessor().writeText(authFile.path, originalText)
        let gate = CredentialMutationWriteGate()
        let store = CodexAuthStore(
            environment: FakeEnvironment(),
            files: GatedCredentialMutationFiles(gate: gate),
            keychain: FakeKeychain(),
            scope: .home(path: codexHome.path)
        )
        var rotated = try XCTUnwrap(store.loadAuth(at: authFile.path))
        rotated.auth.tokens?.accessToken = "account-a-rotated"
        let refreshedState = rotated
        let switcher = AccountCredentialSwitcher(
            keychain: FakeKeychain(), environment: FakeEnvironment(), homeDirectory: home
        )
        gate.arm()

        try assertSerializedMutation(
            gate: gate,
            refresh: { _ = try store.save(refreshedState) },
            competing: {
                try switcher.applySharedAuthentication(
                    .init(credential: switchedText, claudeOAuthAccount: nil), family: "codex"
                )
            }
        )

        XCTAssertEqual(try String(contentsOf: authFile, encoding: .utf8), switchedText)
        XCTAssertEqual(store.loadAuth(at: authFile.path)?.auth.tokens?.accountID, "account-b")
    }

    func testSavedAccountReplacementCannotInterleaveWithRefreshWriteback() throws {
        let gate = CredentialMutationWriteGate()
        let keychain = GatedCredentialMutationKeychain(gate: gate)
        let profile = makeProfile()
        let vault = AccountCredentialVault(keychain: keychain)
        try vault.save(
            .init(credential: authText(accessToken: "original"), claudeOAuthAccount: nil), profile: profile
        )
        let store = CodexAuthStore(
            environment: FakeEnvironment(), files: FakeFiles(), keychain: keychain,
            scope: .accountSnapshot(profileID: profile.id)
        )
        var rotated = try XCTUnwrap(store.loadAccountSnapshot(profileID: profile.id))
        rotated.auth.tokens?.accessToken = "rotated"
        let refreshedState = rotated
        let replacement = AccountCredentialVault.Entry(
            credential: authText(accessToken: "signed-in-again"), claudeOAuthAccount: nil
        )
        gate.arm()

        try assertSerializedMutation(
            gate: gate,
            refresh: { _ = try store.save(refreshedState) },
            competing: { try AccountCredentialVault(keychain: keychain).save(replacement, profile: profile) }
        )

        XCTAssertEqual(try vault.load(profile: profile), replacement)
    }

    func testSavedAccountDeletionCannotBeUndoneByRefreshWriteback() throws {
        let gate = CredentialMutationWriteGate()
        let keychain = GatedCredentialMutationKeychain(gate: gate)
        let profile = makeProfile()
        let vault = AccountCredentialVault(keychain: keychain)
        try vault.save(
            .init(credential: authText(accessToken: "original"), claudeOAuthAccount: nil), profile: profile
        )
        let store = CodexAuthStore(
            environment: FakeEnvironment(), files: FakeFiles(), keychain: keychain,
            scope: .accountSnapshot(profileID: profile.id)
        )
        var rotated = try XCTUnwrap(store.loadAccountSnapshot(profileID: profile.id))
        rotated.auth.tokens?.accessToken = "rotated"
        let refreshedState = rotated
        gate.arm()

        try assertSerializedMutation(
            gate: gate,
            refresh: { _ = try store.save(refreshedState) },
            competing: { try AccountCredentialVault(keychain: keychain).delete(profile: profile) }
        )

        XCTAssertNil(try vault.load(profile: profile))
    }

    private func assertSerializedMutation(
        gate: CredentialMutationWriteGate,
        refresh: @escaping @Sendable () throws -> Void,
        competing: @escaping @Sendable () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let refreshFinished = expectation(description: "refresh writeback finished")
        let competingStarted = DispatchSemaphore(value: 0)
        let competingCompletion = DispatchGroup()
        defer { gate.release() }
        DispatchQueue.global(qos: .userInitiated).async {
            defer { refreshFinished.fulfill() }
            do { try refresh() }
            catch { XCTFail("Refresh writeback failed: \(error)", file: file, line: line) }
        }
        guard gate.waitUntilPaused() else {
            gate.release()
            wait(for: [refreshFinished], timeout: 5)
            throw CredentialMutationTestError.writeGateNotReached
        }
        let competingFinished = expectation(description: "competing credential mutation finished")
        competingCompletion.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                competingCompletion.leave()
                competingFinished.fulfill()
            }
            competingStarted.signal()
            do { try competing() }
            catch { XCTFail("Competing mutation failed: \(error)", file: file, line: line) }
        }
        XCTAssertEqual(competingStarted.wait(timeout: .now() + 3), .success, file: file, line: line)
        let earlyCompletion = competingCompletion.wait(timeout: .now() + 0.2)
        gate.release()
        wait(for: [refreshFinished, competingFinished], timeout: 5)
        XCTAssertEqual(
            earlyCompletion, .timedOut,
            "Credential mutation entered the writeback transaction", file: file, line: line
        )
    }

    private func makeProfile() -> AccountProfile {
        AccountProfile(
            id: UUID().uuidString, family: "codex", label: "Fixture",
            identityKey: "account-a", createdAt: .distantPast
        )
    }

    private func authText(accessToken: String, accountID: String = "account-a") -> String {
        #"{"tokens":{"access_token":"\#(accessToken)","refresh_token":"refresh-\#(accessToken)","account_id":"\#(accountID)"},"last_refresh":"2026-10-05T00:00:00Z"}"#
    }
}

private enum CredentialMutationTestError: Error {
    case writeGateNotReached
    case writeGateTimedOut
}

private final class CredentialMutationWriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private let entered = DispatchSemaphore(value: 0)
    private let resume = DispatchSemaphore(value: 0)
    private var armed = false

    func arm() {
        lock.lock()
        armed = true
        lock.unlock()
    }

    func pauseNextWriteIfArmed() throws {
        lock.lock()
        let shouldPause = armed
        armed = false
        lock.unlock()
        guard shouldPause else { return }
        entered.signal()
        guard resume.wait(timeout: .now() + 5) == .success else {
            throw CredentialMutationTestError.writeGateTimedOut
        }
    }

    func waitUntilPaused() -> Bool { entered.wait(timeout: .now() + 3) == .success }
    func release() { resume.signal() }
}

private struct GatedCredentialMutationFiles: TextFileAccessing {
    let gate: CredentialMutationWriteGate
    private let local = LocalTextFileAccessor()

    func exists(_ path: String) -> Bool { local.exists(path) }
    func readText(_ path: String) throws -> String { try local.readText(path) }
    func readTextIfPresent(_ path: String) throws -> String? { try local.readTextIfPresent(path) }
    func remove(_ path: String) throws { try local.remove(path) }

    func writeText(_ path: String, _ text: String) throws {
        try gate.pauseNextWriteIfArmed()
        try local.writeText(path, text)
    }
}

private final class GatedCredentialMutationKeychain: KeychainAccessing, @unchecked Sendable {
    private let gate: CredentialMutationWriteGate
    private let lock = NSLock()
    private var values: [String: String] = [:]

    init(gate: CredentialMutationWriteGate) { self.gate = gate }

    func readGenericPassword(service: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[service]
    }

    func writeGenericPassword(service: String, value: String) throws {
        try gate.pauseNextWriteIfArmed()
        lock.lock()
        defer { lock.unlock() }
        values[service] = value
    }

    func deleteGenericPassword(service: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values.removeValue(forKey: service)
    }
}
