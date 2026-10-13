import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class CodexCredentialImportRaceTests: XCTestCase {
    func testDefaultImportWaitsForRefreshBeforeReadingSharedCredentials() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageTests.CodexImportRace.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let suiteName = "OpenUsageTests.CodexImportRace.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let authFile = home.appendingPathComponent(".codex/auth.json")
        try LocalTextFileAccessor().writeText(
            authFile.path,
            #"{"tokens":{"access_token":"original-access","refresh_token":"original-refresh","account_id":"account-a"}}"#
        )
        let writePaused = DispatchSemaphore(value: 0)
        let resumeWrite = DispatchSemaphore(value: 0)
        let credentialRead = DispatchSemaphore(value: 0)
        let keychain = ObservedCodexImportKeychain(credentialRead: credentialRead)
        let authStore = CodexAuthStore(
            environment: FakeEnvironment(),
            files: GatedCodexImportFiles(writePaused: writePaused, resumeWrite: resumeWrite),
            keychain: FakeKeychain(),
            scope: .home(path: authFile.deletingLastPathComponent().path)
        )
        var rotated = try XCTUnwrap(authStore.loadAuth(at: authFile.path))
        rotated.auth.tokens?.accessToken = "rotated-access"
        rotated.auth.tokens?.refreshToken = "rotated-refresh"
        let refreshedState = rotated
        let importer = AccountCredentialImporter(
            keychain: keychain,
            environment: FakeEnvironment(),
            homeDirectory: home,
            workspace: AccountSignInWorkspace(baseDirectory: home.appendingPathComponent("workspaces"))
        )
        let profiles = AccountProfilesStore(defaults: defaults)
        let refreshFinished = DispatchGroup()
        refreshFinished.enter()
        defer {
            resumeWrite.signal()
            XCTAssertEqual(refreshFinished.wait(timeout: .now() + 5), .success)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            defer { refreshFinished.leave() }
            do { _ = try authStore.save(refreshedState) }
            catch { XCTFail("Refresh writeback failed: \(error)") }
        }
        guard writePaused.wait(timeout: .now() + 3) == .success else {
            throw CodexImportRaceError.writeGateNotReached
        }
        DispatchQueue.global(qos: .userInitiated).async {
            // 기존 구현은 shared auth를 읽은 뒤 Keychain 조회에 도달. 수정 후에는 읽기 전 lock에서 대기.
            _ = credentialRead.wait(timeout: .now() + 1)
            resumeWrite.signal()
        }

        let profile = try XCTUnwrap(importer.importDefaultAccount(family: "codex", into: profiles))

        let sharedText = try String(contentsOf: authFile, encoding: .utf8)
        let snapshot = try XCTUnwrap(AccountCredentialVault(keychain: keychain).load(profile: profile))
        XCTAssertEqual(CodexAuthStore.parseAuth(sharedText)?.tokens?.accessToken, "rotated-access")
        XCTAssertEqual(CodexAuthStore.parseAuth(sharedText)?.tokens?.refreshToken, "rotated-refresh")
        XCTAssertEqual(snapshot.credential, sharedText)
        XCTAssertEqual(profiles.preferredProfileID(family: "codex"), profile.id)
    }
}

private enum CodexImportRaceError: Error {
    case writeGateNotReached
    case writeGateTimedOut
}

private struct GatedCodexImportFiles: TextFileAccessing {
    let writePaused: DispatchSemaphore
    let resumeWrite: DispatchSemaphore
    private let local = LocalTextFileAccessor()

    func exists(_ path: String) -> Bool { local.exists(path) }
    func readText(_ path: String) throws -> String { try local.readText(path) }
    func readTextIfPresent(_ path: String) throws -> String? { try local.readTextIfPresent(path) }
    func remove(_ path: String) throws { try local.remove(path) }

    func writeText(_ path: String, _ text: String) throws {
        writePaused.signal()
        guard resumeWrite.wait(timeout: .now() + 5) == .success else {
            throw CodexImportRaceError.writeGateTimedOut
        }
        try local.writeText(path, text)
    }
}

private struct ObservedCodexImportKeychain: KeychainAccessing {
    let credentialRead: DispatchSemaphore
    private let base = FakeKeychain()

    func readGenericPassword(service: String) throws -> String? {
        if service == CodexAuthStore.keychainService { credentialRead.signal() }
        return try base.readGenericPassword(service: service)
    }

    func writeGenericPassword(service: String, value: String) throws {
        try base.writeGenericPassword(service: service, value: value)
    }

    func deleteGenericPassword(service: String) throws {
        try base.deleteGenericPassword(service: service)
    }
}
