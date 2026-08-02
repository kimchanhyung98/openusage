import Foundation
import XCTest
@testable import OpenUsage

final class KimiAuthStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000)

    func testKimiCodeHomeOverridesOnlyCurrentRoot() throws {
        let userHome = URL(fileURLWithPath: "/Users/test")
        let currentHome = userHome.appendingPathComponent("custom-kimi")
        let credential = currentHome.appendingPathComponent("credentials/kimi-code.json")
        let files = FakeFiles([credential.path: credentialJSON(access: "current", expiresAt: 4_000)])
        let store = KimiAuthStore(
            files: files,
            environment: FakeEnvironment(["KIMI_CODE_HOME": "~/custom-kimi"]),
            homeDirectory: { userHome }
        )

        let document = try XCTUnwrap(store.loadCredentialDocument())

        XCTAssertEqual(
            document.credentials.source,
            .current(
                home: currentHome,
                credential: credential,
                lockTarget: currentHome.appendingPathComponent("oauth/kimi-code")
            )
        )
        XCTAssertEqual(document.credentials.accessToken, "current")
    }

    func testCurrentCredentialWinsOverLegacy() throws {
        let home = URL(fileURLWithPath: "/Users/test")
        let current = home.appendingPathComponent(".kimi-code/credentials/kimi-code.json")
        let legacy = home.appendingPathComponent(".kimi/credentials/kimi-code.json")
        let store = KimiAuthStore(
            files: FakeFiles([
                current.path: credentialJSON(access: "current", expiresAt: 4_000),
                legacy.path: credentialJSON(access: "legacy", expiresAt: 4_000)
            ]),
            environment: FakeEnvironment(),
            homeDirectory: { home }
        )

        let document = try XCTUnwrap(store.loadCredentialDocument())

        XCTAssertEqual(document.credentials.accessToken, "current")
        guard case .current = document.credentials.source else {
            return XCTFail("expected the current credential source")
        }
    }

    func testFallsBackToLegacyOnlyWhenCurrentFileIsAbsent() throws {
        let home = URL(fileURLWithPath: "/Users/test")
        let legacy = home.appendingPathComponent(".kimi/credentials/kimi-code.json")
        let store = KimiAuthStore(
            files: FakeFiles([legacy.path: credentialJSON(access: "legacy", expiresAt: 4_000)]),
            environment: FakeEnvironment(),
            homeDirectory: { home }
        )

        let document = try XCTUnwrap(store.loadCredentialDocument())

        XCTAssertEqual(document.credentials.source, .legacy(credential: legacy))
        XCTAssertEqual(document.credentials.accessToken, "legacy")
    }

    func testCorruptCurrentCredentialNeverFallsBackToLegacy() {
        let home = URL(fileURLWithPath: "/Users/test")
        let current = home.appendingPathComponent(".kimi-code/credentials/kimi-code.json")
        let legacy = home.appendingPathComponent(".kimi/credentials/kimi-code.json")
        let store = KimiAuthStore(
            files: FakeFiles([
                current.path: "not-json",
                legacy.path: credentialJSON(access: "legacy", expiresAt: 4_000)
            ]),
            environment: FakeEnvironment(),
            homeDirectory: { home }
        )

        XCTAssertThrowsError(try store.loadCredentialDocument()) { error in
            XCTAssertEqual(error as? KimiAuthError, .credentialsInvalid)
        }
    }

    func testMalformedOrTokenlessFileThrowsCredentialsInvalid() {
        let home = URL(fileURLWithPath: "/Users/test")
        let current = home.appendingPathComponent(".kimi-code/credentials/kimi-code.json")
        for contents in ["[]", #"{"expires_at":4000}"#, #"{"access_token":"   "}"#] {
            let store = KimiAuthStore(
                files: FakeFiles([current.path: contents]),
                environment: FakeEnvironment(),
                homeDirectory: { home }
            )

            XCTAssertThrowsError(try store.loadCredentialDocument()) { error in
                XCTAssertEqual(error as? KimiAuthError, .credentialsInvalid)
            }
        }
    }

    func testCustomHostsFailBeforeCredentialsAreRead() {
        let files = KimiThrowingFiles(readError: KimiTestFileError.readFailed)
        let overrides = [
            "KIMI_CODE_BASE_URL": "https://example.invalid/v1",
            "KIMI_CODE_OAUTH_HOST": "https://example.invalid",
            "KIMI_OAUTH_HOST": "https://example.invalid"
        ]

        for (key, value) in overrides {
            let store = KimiAuthStore(
                files: files,
                environment: FakeEnvironment([key: value]),
                homeDirectory: { URL(fileURLWithPath: "/Users/test") }
            )
            XCTAssertThrowsError(try store.loadCredentialDocument()) { error in
                XCTAssertEqual(error as? KimiAuthError, .unsupportedConfiguration)
            }
        }
        XCTAssertEqual(files.readCount, 0)
    }

    func testDefaultHostsAllowSchemeHostCaseWhitespaceAndTrailingSlash() throws {
        let store = KimiAuthStore(
            files: FakeFiles(),
            environment: FakeEnvironment([
                "KIMI_CODE_BASE_URL": "  HTTPS://API.KIMI.COM/coding/v1/ ",
                "KIMI_CODE_OAUTH_HOST": "https://AUTH.KIMI.COM/"
            ]),
            homeDirectory: { URL(fileURLWithPath: "/Users/test") }
        )

        XCTAssertNil(try store.loadCredentialDocument())
    }

    func testDefaultHostComparisonRejectsDifferentPathOrURLComponents() {
        let values = [
            "https://api.kimi.com/CODING/V1",
            "https://api.kimi.com/coding/v1?account=other",
            "https://user@api.kimi.com/coding/v1",
            "https://api.kimi.com:8443/coding/v1",
        ]

        for value in values {
            let store = KimiAuthStore(
                files: FakeFiles(),
                environment: FakeEnvironment(["KIMI_CODE_BASE_URL": value]),
                homeDirectory: { URL(fileURLWithPath: "/Users/test") }
            )
            XCTAssertThrowsError(try store.loadCredentialDocument()) { error in
                XCTAssertEqual(error as? KimiAuthError, .unsupportedConfiguration)
            }
        }
    }

    func testCurrentAndLegacyUsabilityMatchKimiCLIAndMutationPolicy() {
        let currentSource = KimiCredentialSource.current(
            home: URL(fileURLWithPath: "/tmp/kimi"),
            credential: URL(fileURLWithPath: "/tmp/kimi/credentials.json"),
            lockTarget: URL(fileURLWithPath: "/tmp/kimi/oauth/kimi-code")
        )
        let legacySource = KimiCredentialSource.legacy(credential: URL(fileURLWithPath: "/tmp/legacy.json"))
        let enabled = KimiAuthStore(files: FakeFiles(), environment: FakeEnvironment())
        let disabled = KimiAuthStore(
            files: FakeFiles(),
            environment: FakeEnvironment(["KIMI_DISABLE_OAUTH_LOCK": " 1 "])
        )
        let validCurrent = document(
            source: currentSource,
            access: "access",
            refresh: nil,
            expiresAt: Date(timeIntervalSince1970: 3_000)
        )
        let refreshOnly = document(source: currentSource, access: nil, refresh: "refresh", expiresAt: nil)
        let unknownExpiryCurrent = document(
            source: currentSource,
            access: "access",
            refresh: nil,
            expiresAt: nil
        )
        let zeroExpiryCurrent = document(
            source: currentSource,
            access: "access",
            refresh: "refresh",
            expiresAt: Date(timeIntervalSince1970: 0)
        )
        let expiredCurrent = document(
            source: currentSource,
            access: "access",
            refresh: "refresh",
            expiresAt: Date(timeIntervalSince1970: 1_000)
        )
        let unknownExpiryLegacy = document(
            source: legacySource,
            access: "access",
            refresh: nil,
            expiresAt: nil
        )
        let expiredLegacy = document(
            source: legacySource,
            access: "access",
            refresh: "refresh",
            expiresAt: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertTrue(enabled.isUsable(validCurrent, now: now))
        XCTAssertFalse(enabled.isUsable(refreshOnly, now: now))
        XCTAssertFalse(disabled.isUsable(refreshOnly, now: now))
        XCTAssertTrue(enabled.isUsable(unknownExpiryCurrent, now: now))
        XCTAssertTrue(enabled.isUsable(zeroExpiryCurrent, now: now))
        XCTAssertTrue(enabled.isUsable(expiredCurrent, now: now))
        XCTAssertFalse(disabled.isUsable(expiredCurrent, now: now))
        XCTAssertTrue(enabled.isUsable(unknownExpiryLegacy, now: now))
        XCTAssertFalse(enabled.isUsable(expiredLegacy, now: now))
    }

    func testRefreshThresholdIsMaxOf300SecondsAndHalfExpiresIn() {
        let source = KimiCredentialSource.current(
            home: URL(fileURLWithPath: "/tmp/kimi"),
            credential: URL(fileURLWithPath: "/tmp/kimi/credentials.json"),
            lockTarget: URL(fileURLWithPath: "/tmp/kimi/oauth/kimi-code")
        )
        let store = KimiAuthStore(files: FakeFiles(), environment: FakeEnvironment())

        XCTAssertTrue(store.needsRefresh(
            document(source: source, access: "access", refresh: "refresh", expiresAt: now.addingTimeInterval(300), expiresIn: 60),
            now: now
        ))
        XCTAssertFalse(store.needsRefresh(
            document(source: source, access: "access", refresh: "refresh", expiresAt: now.addingTimeInterval(301), expiresIn: 60),
            now: now
        ))
        XCTAssertTrue(store.needsRefresh(
            document(source: source, access: "access", refresh: "refresh", expiresAt: now.addingTimeInterval(1_800), expiresIn: 3_600),
            now: now
        ))
        XCTAssertFalse(store.needsRefresh(
            document(source: source, access: "access", refresh: "refresh", expiresAt: now.addingTimeInterval(1_801), expiresIn: 3_600),
            now: now
        ))
        XCTAssertFalse(store.needsRefresh(
            document(source: source, access: "access", refresh: "refresh", expiresAt: nil, expiresIn: 3_600),
            now: now
        ))
        XCTAssertFalse(store.needsRefresh(
            document(source: source, access: "access", refresh: "refresh", expiresAt: Date(timeIntervalSince1970: 0), expiresIn: 3_600),
            now: now
        ))
        XCTAssertFalse(store.needsRefresh(
            document(source: source, access: nil, refresh: "refresh", expiresAt: now, expiresIn: 3_600),
            now: now
        ))
    }

    func testPersistencePreservesUnknownFieldsAndFractionalExpiry() throws {
        let credential = URL(fileURLWithPath: "/tmp/kimi/credentials/kimi-code.json")
        let source = KimiCredentialSource.current(
            home: URL(fileURLWithPath: "/tmp/kimi"),
            credential: credential,
            lockTarget: URL(fileURLWithPath: "/tmp/kimi/oauth/kimi-code")
        )
        let files = FakeFiles([credential.path: #"{"access_token":"old","refresh_token":"old-refresh","custom":{"keep":true}}"#])
        let store = KimiAuthStore(files: files, environment: FakeEnvironment())
        let live = KimiCredentialDocument(
            credentials: KimiCredentials(
                source: source,
                accessToken: "old",
                refreshToken: "old-refresh",
                expiresAt: nil,
                expiresIn: nil
            ),
            rawJSON: files.files[credential.path]!
        )

        try store.persistRotatedCredentials(
            replacing: live,
            with: KimiTokenRefresh(
                accessToken: "new",
                refreshToken: "new-refresh",
                expiresAt: Date(timeIntervalSince1970: 4_000.25),
                expiresIn: 3_600,
                scope: "openid",
                tokenType: "Bearer"
            )
        )

        let object = try XCTUnwrap(ProviderParse.jsonObject(Data(files.files[credential.path]!.utf8)))
        XCTAssertEqual(object["access_token"] as? String, "new")
        XCTAssertEqual(object["refresh_token"] as? String, "new-refresh")
        XCTAssertEqual(ProviderParse.number(object["expires_at"]), 4_000.25)
        XCTAssertEqual((object["custom"] as? [String: Any])?["keep"] as? Bool, true)
    }

    func testPersistenceFailureThrowsCredentialSaveFailed() {
        let credential = URL(fileURLWithPath: "/tmp/kimi/credentials/kimi-code.json")
        let source = KimiCredentialSource.current(
            home: URL(fileURLWithPath: "/tmp/kimi"),
            credential: credential,
            lockTarget: URL(fileURLWithPath: "/tmp/kimi/oauth/kimi-code")
        )
        let rawJSON = #"{"access_token":"old","refresh_token":"old-refresh"}"#
        let store = KimiAuthStore(
            files: KimiThrowingFiles(files: [credential.path: rawJSON], writeError: KimiTestFileError.writeFailed),
            environment: FakeEnvironment()
        )
        let live = KimiCredentialDocument(
            credentials: KimiCredentials(
                source: source,
                accessToken: "old",
                refreshToken: "old-refresh",
                expiresAt: nil,
                expiresIn: nil
            ),
            rawJSON: rawJSON
        )

        XCTAssertThrowsError(try store.persistRotatedCredentials(
            replacing: live,
            with: KimiTokenRefresh(
                accessToken: "new",
                refreshToken: "new-refresh",
                expiresAt: Date(timeIntervalSince1970: 4_000),
                expiresIn: 3_600
            )
        )) { error in
            XCTAssertEqual(error as? KimiAuthError, .credentialSaveFailed)
        }
    }

    func testPersistenceRejectsAChangedLiveDocument() {
        let credential = URL(fileURLWithPath: "/tmp/kimi/credentials/kimi-code.json")
        let source = KimiCredentialSource.current(
            home: URL(fileURLWithPath: "/tmp/kimi"),
            credential: credential,
            lockTarget: URL(fileURLWithPath: "/tmp/kimi/oauth/kimi-code")
        )
        let files = FakeFiles([credential.path: #"{"access_token":"changed"}"#])
        let store = KimiAuthStore(files: files, environment: FakeEnvironment())
        let live = KimiCredentialDocument(
            credentials: KimiCredentials(
                source: source,
                accessToken: "old",
                refreshToken: "old-refresh",
                expiresAt: nil,
                expiresIn: nil
            ),
            rawJSON: #"{"access_token":"old","refresh_token":"old-refresh"}"#
        )

        XCTAssertThrowsError(try store.persistRotatedCredentials(
            replacing: live,
            with: KimiTokenRefresh(
                accessToken: "new",
                refreshToken: "new-refresh",
                expiresAt: Date(timeIntervalSince1970: 4_000),
                expiresIn: 3_600
            )
        )) { error in
            XCTAssertEqual(error as? KimiAuthError, .credentialLockCompromised)
        }
        XCTAssertEqual(files.files[credential.path], #"{"access_token":"changed"}"#)
    }

    private func credentialJSON(access: String, expiresAt: Double, refresh: String? = nil) -> String {
        var object: [String: Any] = ["access_token": access, "expires_at": expiresAt]
        if let refresh { object["refresh_token"] = refresh }
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func document(
        source: KimiCredentialSource,
        access: String?,
        refresh: String?,
        expiresAt: Date?,
        expiresIn: TimeInterval? = nil
    ) -> KimiCredentialDocument {
        KimiCredentialDocument(
            credentials: KimiCredentials(
                source: source,
                accessToken: access,
                refreshToken: refresh,
                expiresAt: expiresAt,
                expiresIn: expiresIn
            ),
            rawJSON: "{}"
        )
    }
}

private enum KimiTestFileError: Error {
    case readFailed
    case writeFailed
}

private final class KimiThrowingFiles: TextFileAccessing, @unchecked Sendable {
    var files: [String: String]
    var readCount = 0
    let readError: Error?
    let writeError: Error?

    init(files: [String: String] = [:], readError: Error? = nil, writeError: Error? = nil) {
        self.files = files
        self.readError = readError
        self.writeError = writeError
    }

    func exists(_ path: String) -> Bool { files[path] != nil }

    func readTextIfPresent(_ path: String) throws -> String? {
        readCount += 1
        if let readError { throw readError }
        return files[path]
    }

    func readText(_ path: String) throws -> String {
        if let readError { throw readError }
        return files[path] ?? ""
    }

    func writeText(_ path: String, _ text: String) throws {
        if let writeError { throw writeError }
        files[path] = text
    }

    func remove(_ path: String) throws {
        files.removeValue(forKey: path)
    }
}
