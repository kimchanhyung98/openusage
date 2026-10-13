import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class CursorCredentialPreservationTests: XCTestCase {
    func testKeychainReloginDuringRefreshPreservesReplacementPair() async throws {
        let oldAccess = cursorPreservationToken(subject: "account-a", expiresAt: 1)
        let newAccess = cursorPreservationToken(subject: "account-b", expiresAt: 4_000_000_000)
        let rotatedAccess = cursorPreservationToken(subject: "account-a", expiresAt: 4_000_000_001)
        let keychain = CursorPreservationKeychain()
        keychain.replaceAuth(accessToken: oldAccess, refreshToken: "account-a-refresh")
        let http = RoutingHTTPClient { request in
            guard request.url == CursorUsageClient.refreshURL else {
                return HTTPResponse(statusCode: 503, headers: [:], body: Data())
            }
            keychain.replaceAuth(accessToken: newAccess, refreshToken: "account-b-refresh")
            return try cursorPreservationRefreshResponse(accessToken: rotatedAccess)
        }
        let provider = CursorProvider(
            authStore: CursorAuthStore(sqlite: CursorPreservationEmptySQLite(), keychain: keychain),
            usageClient: CursorUsageClient(http: http),
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(
            try keychain.readGenericPassword(service: CursorAuthStore.keychainAccessTokenService), newAccess
        )
        XCTAssertEqual(
            try keychain.readGenericPassword(service: CursorAuthStore.keychainRefreshTokenService), "account-b-refresh"
        )
        XCTAssertEqual(http.requests.filter { $0.url == CursorUsageClient.refreshURL }.count, 1)
        XCTAssertEqual(snapshot.errorCategory, .other)
        XCTAssertTrue(http.requests.allSatisfy { $0.url == CursorUsageClient.refreshURL })
        let staleAuthorizations = ["Bearer \(oldAccess)", "Bearer \(rotatedAccess)"]
        XCTAssertFalse(http.requests.contains { staleAuthorizations.contains($0.headers["Authorization"] ?? "") })
    }

    func testSQLiteReloginDuringRefreshPreservesReplacementPair() async throws {
        let database = try CursorPreservationSQLite()
        defer { database.remove() }
        let oldAccess = cursorPreservationToken(subject: "account-a", expiresAt: 1)
        let newAccess = cursorPreservationToken(subject: "account-b", expiresAt: 4_000_000_000)
        let rotatedAccess = cursorPreservationToken(subject: "account-a", expiresAt: 4_000_000_001)
        try database.replaceAuth(accessToken: oldAccess, refreshToken: "account-a-refresh")
        let http = RoutingHTTPClient { request in
            guard request.url == CursorUsageClient.refreshURL else {
                return HTTPResponse(statusCode: 503, headers: [:], body: Data())
            }
            try database.replaceAuth(accessToken: newAccess, refreshToken: "account-b-refresh")
            return try cursorPreservationRefreshResponse(accessToken: rotatedAccess)
        }
        let provider = CursorProvider(
            authStore: CursorAuthStore(sqlite: database, keychain: CursorPreservationKeychain()),
            usageClient: CursorUsageClient(http: http),
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(try database.value(for: CursorAuthStore.accessTokenKey), newAccess)
        XCTAssertEqual(try database.value(for: CursorAuthStore.refreshTokenKey), "account-b-refresh")
        XCTAssertEqual(http.requests.filter { $0.url == CursorUsageClient.refreshURL }.count, 1)
        XCTAssertEqual(snapshot.errorCategory, .other)
        XCTAssertTrue(http.requests.allSatisfy { $0.url == CursorUsageClient.refreshURL })
        let staleAuthorizations = ["Bearer \(oldAccess)", "Bearer \(rotatedAccess)"]
        XCTAssertFalse(http.requests.contains { staleAuthorizations.contains($0.headers["Authorization"] ?? "") })
        for secret in [oldAccess, newAccess, rotatedAccess, "account-a-refresh", "account-b-refresh"] {
            XCTAssertFalse(database.sqlStatements.contains { $0.contains(secret) })
            XCTAssertFalse(database.processArguments.flatMap { $0 }.contains { $0.contains(secret) })
        }
    }

    func testKeychainLogoutDuringRefreshDoesNotRestoreCredentials() async throws {
        let keychain = CursorPreservationKeychain()
        keychain.replaceAuth(accessToken: "expired-access", refreshToken: "original-refresh")
        let http = RoutingHTTPClient { request in
            guard request.url == CursorUsageClient.refreshURL else {
                return HTTPResponse(statusCode: 503, headers: [:], body: Data())
            }
            keychain.clearAuth()
            return try cursorPreservationRefreshResponse(accessToken: "stale-rotation")
        }
        let provider = CursorProvider(
            authStore: CursorAuthStore(sqlite: CursorPreservationEmptySQLite(), keychain: keychain),
            usageClient: CursorUsageClient(http: http), pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(try keychain.readGenericPassword(service: CursorAuthStore.keychainAccessTokenService))
        XCTAssertNil(try keychain.readGenericPassword(service: CursorAuthStore.keychainRefreshTokenService))
        XCTAssertEqual(snapshot.errorCategory, .other)
        XCTAssertEqual(http.requests.map(\.url), [CursorUsageClient.refreshURL])
    }

    func testSQLiteLogoutDuringRefreshDoesNotRestoreCredentialRows() async throws {
        let database = try CursorPreservationSQLite()
        defer { database.remove() }
        try database.replaceAuth(accessToken: "expired-access", refreshToken: "original-refresh")
        let http = RoutingHTTPClient { request in
            guard request.url == CursorUsageClient.refreshURL else {
                return HTTPResponse(statusCode: 503, headers: [:], body: Data())
            }
            try database.replaceAuth(accessToken: nil, refreshToken: nil)
            return try cursorPreservationRefreshResponse(accessToken: "stale-rotation")
        }
        let provider = CursorProvider(
            authStore: CursorAuthStore(sqlite: database, keychain: CursorPreservationKeychain()),
            usageClient: CursorUsageClient(http: http), pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(try database.value(for: CursorAuthStore.accessTokenKey))
        XCTAssertNil(try database.value(for: CursorAuthStore.refreshTokenKey))
        XCTAssertEqual(snapshot.errorCategory, .other)
        XCTAssertEqual(http.requests.map(\.url), [CursorUsageClient.refreshURL])
    }

    func testPriorKeychainRotationDuringUnauthorizedRetryIsPreserved() async throws {
        let original = cursorPreservationToken(subject: "same-account", expiresAt: 4_000_000_000)
        let external = cursorPreservationToken(subject: "same-account", expiresAt: 4_000_000_001)
        let keychain = CursorPreservationKeychain()
        keychain.replaceAuth(accessToken: original, refreshToken: "original-refresh")
        let http = RoutingHTTPClient { request in
            if request.url == CursorUsageClient.refreshURL {
                keychain.replaceAuth(accessToken: external, refreshToken: "external-refresh")
                return try cursorPreservationRefreshResponse(accessToken: "late-rotation")
            }
            return HTTPResponse(statusCode: 401, headers: [:], body: Data())
        }
        let provider = CursorProvider(
            authStore: CursorAuthStore(sqlite: CursorPreservationEmptySQLite(), keychain: keychain),
            usageClient: CursorUsageClient(http: http), pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(try keychain.readGenericPassword(service: CursorAuthStore.keychainAccessTokenService), external)
        XCTAssertEqual(try keychain.readGenericPassword(service: CursorAuthStore.keychainRefreshTokenService), "external-refresh")
        XCTAssertEqual(snapshot.errorCategory, .other)
        XCTAssertEqual(http.requests.map(\.url), [CursorUsageClient.usageURL, CursorUsageClient.refreshURL])
    }

    func testKeychainVerificationReadFailurePreservesOriginalPairAndStopsUsage() async throws {
        let keychain = CursorPreservationKeychain()
        keychain.replaceAuth(accessToken: "expired-access", refreshToken: "original-refresh")
        let http = RoutingHTTPClient { request in
            guard request.url == CursorUsageClient.refreshURL else {
                return HTTPResponse(statusCode: 503, headers: [:], body: Data())
            }
            keychain.failReads()
            return try cursorPreservationRefreshResponse(accessToken: "rotated-access")
        }
        let provider = CursorProvider(
            authStore: CursorAuthStore(sqlite: CursorPreservationEmptySQLite(), keychain: keychain),
            usageClient: CursorUsageClient(http: http), pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(keychain.storedValue(for: CursorAuthStore.keychainAccessTokenService), "expired-access")
        XCTAssertEqual(keychain.storedValue(for: CursorAuthStore.keychainRefreshTokenService), "original-refresh")
        XCTAssertEqual(snapshot.errorCategory, .other)
        XCTAssertEqual(http.requests.map(\.url), [CursorUsageClient.refreshURL])
    }

    func testKeychainWithoutOriginalAuthenticationCannotCreateCredentials() throws {
        let keychain = CursorPreservationKeychain()
        let store = CursorAuthStore(sqlite: CursorPreservationEmptySQLite(), keychain: keychain)
        let absent = CursorAuthState(accessToken: nil, refreshToken: nil, source: .keychain)

        XCTAssertThrowsError(try store.saveAccessToken("unowned-token", replacing: absent)) { error in
            XCTAssertEqual(error as? CursorAuthError, .credentialsChanged)
        }

        XCTAssertNil(try keychain.readGenericPassword(service: CursorAuthStore.keychainAccessTokenService))
        XCTAssertNil(try keychain.readGenericPassword(service: CursorAuthStore.keychainRefreshTokenService))
    }

    func testAuthRetryAfterFailedFirstSaveCanPersistSecondRotation() async throws {
        try await assertRetryAfterFailedSave(.saved)
    }

    func testAuthRetryAfterTwoWriteFailuresKeepsOriginalPairAndUsesLiveToken() async throws {
        try await assertRetryAfterFailedSave(.writeFailed)
    }

    func testAuthRetryAfterFailedFirstSaveStillRejectsExternalAccountChange() async throws {
        try await assertRetryAfterFailedSave(.externalChange)
    }

    private func assertRetryAfterFailedSave(_ outcome: CursorRetryPersistenceOutcome) async throws {
        let database = try CursorPreservationSQLite()
        defer { database.remove() }
        let original = cursorPreservationToken(subject: "account-a", expiresAt: 1)
        let first = cursorPreservationToken(subject: "account-a", expiresAt: 4_000_000_000)
        let second = cursorPreservationToken(subject: "account-a", expiresAt: 4_000_000_001)
        let external = cursorPreservationToken(subject: "account-b", expiresAt: 4_000_000_002)
        try database.replaceAuth(accessToken: original, refreshToken: "original-refresh")
        database.beforeNextConditionalWrite { throw CocoaError(.fileWriteNoPermission) }
        let refreshCount = CursorPreservationCounter()
        let diagnostics = DiagnosticEventRecorder()
        let http = RoutingHTTPClient { request in
            if request.url == CursorUsageClient.refreshURL {
                if refreshCount.increment() == 1 {
                    return try cursorPreservationRefreshResponse(accessToken: first)
                }
                switch outcome {
                case .saved:
                    break
                case .writeFailed:
                    database.beforeNextConditionalWrite { throw CocoaError(.fileWriteNoPermission) }
                case .externalChange:
                    try database.replaceAuth(accessToken: external, refreshToken: "external-refresh")
                }
                return try cursorPreservationRefreshResponse(accessToken: second)
            }
            if request.url == CursorUsageClient.usageURL {
                if request.headers["Authorization"] == "Bearer \(first)" {
                    return HTTPResponse(statusCode: 401, headers: [:], body: Data())
                }
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(
                    #"{"enabled":true,"planUsage":{"limit":40000,"remaining":32000,"totalPercentUsed":20}}"#.utf8
                ))
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        let provider = CursorProvider(
            authStore: CursorAuthStore(sqlite: database, keychain: CursorPreservationKeychain()),
            usageClient: CursorUsageClient(http: http), pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(http.requests.filter { $0.url == CursorUsageClient.refreshURL }.count, 2)
        let usageAuthorizations = http.requests.filter { $0.url == CursorUsageClient.usageURL }
            .compactMap { $0.headers["Authorization"] }
        let expectedAccess: String
        if outcome == .externalChange {
            expectedAccess = external
            XCTAssertEqual(snapshot.errorCategory, .other)
            XCTAssertEqual(usageAuthorizations, ["Bearer \(first)"])
        } else {
            expectedAccess = outcome == .saved ? second : original
            XCTAssertNil(snapshot.errorCategory)
            XCTAssertEqual(snapshot.isDegraded, true)
            XCTAssertEqual(usageAuthorizations, ["Bearer \(first)", "Bearer \(second)"])
        }
        XCTAssertEqual(try database.value(for: CursorAuthStore.accessTokenKey), expectedAccess)
        XCTAssertEqual(
            try database.value(for: CursorAuthStore.refreshTokenKey),
            outcome == .externalChange ? "external-refresh" : "original-refresh"
        )
        XCTAssertEqual(
            diagnostics.events.filter { $0.operation == .credentialSave && $0.result == .degraded }.count,
            outcome == .writeFailed ? 2 : 1
        )
    }
}

private enum CursorRetryPersistenceOutcome: Equatable, Sendable {
    case saved
    case writeFailed
    case externalChange
}

private final class CursorPreservationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

private func cursorPreservationToken(subject: String, expiresAt: Int) -> String {
    let payload = Data(#"{"sub":"auth0|\#(subject)","exp":\#(expiresAt)}"#.utf8)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "header.\(payload).signature"
}

private func cursorPreservationRefreshResponse(accessToken: String) throws -> HTTPResponse {
    HTTPResponse(
        statusCode: 200, headers: [:],
        body: try JSONSerialization.data(withJSONObject: ["access_token": accessToken])
    )
}

private struct CursorPreservationEmptySQLite: SQLiteAccessing {
    func queryValue(path: String, sql: String) throws -> String? { nil }
    func execute(path: String, sql: String) throws { throw SQLiteError.boundParametersUnsupported }
}

private final class CursorPreservationKeychain: KeychainAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var readsFail = false

    func replaceAuth(accessToken: String, refreshToken: String) {
        lock.lock()
        defer { lock.unlock() }
        values[CursorAuthStore.keychainAccessTokenService] = accessToken
        values[CursorAuthStore.keychainRefreshTokenService] = refreshToken
    }

    func readGenericPassword(service: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        if readsFail { throw KeychainError.readFailed("Fixture Keychain read failure") }
        return values[service]
    }

    func storedValue(for service: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[service]
    }

    func clearAuth() {
        lock.lock()
        values.removeAll()
        lock.unlock()
    }

    func failReads() {
        lock.lock()
        readsFail = true
        lock.unlock()
    }

    func writeGenericPassword(service: String, value: String) throws {
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
