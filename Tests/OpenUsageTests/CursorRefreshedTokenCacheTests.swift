import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class CursorRefreshedTokenCacheTests: XCTestCase {
    func testUnchangedKeychainCredentialsReuseRotationAcrossPollsWithoutWriting() async {
        let rotated = cacheToken(expiresAt: 1_800_003_600)
        let fixture = CursorCacheFixture(rotatedTokens: [rotated])
        let originalValues = fixture.keychain.values

        let first = await fixture.provider.refresh()
        fixture.responses.now += 300
        let second = await fixture.provider.refresh()

        XCTAssertNil(first.errorCategory)
        XCTAssertNil(second.errorCategory)
        XCTAssertNil(second.isDegraded)
        XCTAssertEqual(fixture.refreshRequests.count, 1)
        XCTAssertEqual(fixture.usageTokens, [rotated, rotated])
        XCTAssertEqual(fixture.keychain.values, originalValues)
        XCTAssertTrue(fixture.keychain.modificationDates.isEmpty)
    }

    func testEitherSourceTokenChangeDiscardsCachedRotation() async throws {
        for changesAccessToken in [true, false] {
            let first = cacheToken(expiresAt: 1_800_003_600)
            let second = cacheToken(expiresAt: 1_800_007_200)
            let fixture = CursorCacheFixture(rotatedTokens: [first, second])
            _ = await fixture.provider.refresh()
            if changesAccessToken {
                fixture.keychain.values[CursorAuthStore.keychainAccessTokenService] = cacheToken(expiresAt: 2)
            } else {
                fixture.keychain.values[CursorAuthStore.keychainRefreshTokenService] = "replacement-refresh"
            }
            let replacement = fixture.keychain.values

            let snapshot = await fixture.provider.refresh()

            XCTAssertNil(snapshot.errorCategory)
            XCTAssertEqual(fixture.refreshRequests.count, 2)
            XCTAssertEqual(fixture.usageTokens, [first, second])
            let body = try XCTUnwrap(fixture.refreshRequests.last?.body)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            XCTAssertEqual(payload["refresh_token"], changesAccessToken ? "original-refresh" : "replacement-refresh")
            XCTAssertEqual(fixture.keychain.values, replacement)
            XCTAssertTrue(fixture.keychain.modificationDates.isEmpty)
        }
    }

    func testSourceChangeWithIdenticalTokenPairDiscardsCachedRotation() async {
        let first = cacheToken(expiresAt: 1_800_003_600)
        let second = cacheToken(expiresAt: 1_800_007_200)
        let fixture = CursorCacheFixture(rotatedTokens: [first, second])
        _ = await fixture.provider.refresh()
        fixture.sqlite.values = [
            CursorAuthStore.accessTokenKey: fixture.keychain.values[CursorAuthStore.keychainAccessTokenService]!,
            CursorAuthStore.refreshTokenKey: "original-refresh"
        ]

        let snapshot = await fixture.provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(fixture.refreshRequests.count, 2)
        XCTAssertEqual(fixture.usageTokens, [first, second])
        XCTAssertEqual(fixture.sqlite.values[CursorAuthStore.accessTokenKey], second)
        XCTAssertEqual(fixture.keychain.values[CursorAuthStore.keychainAccessTokenService], cacheToken(expiresAt: 1))
    }

    func testLogoutDiscardsCacheBeforeIdenticalCredentialsReturn() async {
        let first = cacheToken(expiresAt: 1_800_003_600)
        let second = cacheToken(expiresAt: 1_800_007_200)
        let fixture = CursorCacheFixture(rotatedTokens: [first, second])
        let originalValues = fixture.keychain.values
        _ = await fixture.provider.refresh()
        fixture.keychain.values.removeAll()
        let requestCount = fixture.http.requests.count

        let loggedOut = await fixture.provider.refresh()

        XCTAssertEqual(loggedOut.errorCategory, .notLoggedIn)
        XCTAssertEqual(fixture.http.requests.count, requestCount)
        fixture.keychain.values = originalValues
        let restored = await fixture.provider.refresh()
        XCTAssertNil(restored.errorCategory)
        XCTAssertEqual(fixture.refreshRequests.count, 2)
        XCTAssertEqual(fixture.usageTokens, [first, second])
        XCTAssertEqual(fixture.keychain.values, originalValues)
    }

    func testCachedTokenEnteringRefreshBufferGetsRotated() async {
        let first = cacheToken(expiresAt: 1_800_000_600)
        let second = cacheToken(expiresAt: 1_800_007_200)
        let fixture = CursorCacheFixture(rotatedTokens: [first, second])
        _ = await fixture.provider.refresh()
        fixture.responses.now += 300

        let refreshed = await fixture.provider.refresh()
        let reused = await fixture.provider.refresh()

        XCTAssertNil(refreshed.errorCategory)
        XCTAssertNil(reused.errorCategory)
        XCTAssertEqual(fixture.refreshRequests.count, 2)
        XCTAssertEqual(fixture.usageTokens, [first, second, second])
        XCTAssertEqual(fixture.keychain.values[CursorAuthStore.keychainAccessTokenService], cacheToken(expiresAt: 1))
    }

    func testUnauthorizedCachedTokenRefreshesAndCachesRetryResult() async {
        let first = cacheToken(expiresAt: 1_800_003_600)
        let second = cacheToken(expiresAt: 1_800_007_200)
        let fixture = CursorCacheFixture(rotatedTokens: [first, second])
        _ = await fixture.provider.refresh()
        fixture.responses.rejectedTokens = [first]

        let retried = await fixture.provider.refresh()
        let reused = await fixture.provider.refresh()

        XCTAssertNil(retried.errorCategory)
        XCTAssertNil(reused.errorCategory)
        XCTAssertEqual(fixture.refreshRequests.count, 2)
        XCTAssertEqual(fixture.usageTokens, [first, first, second, second])
        XCTAssertTrue(fixture.keychain.modificationDates.isEmpty)
    }

    func testRepeatedUnauthorizedResponseDiscardsRejectedRetryToken() async {
        let first = cacheToken(expiresAt: 1_800_003_600)
        let second = cacheToken(expiresAt: 1_800_007_200)
        let third = cacheToken(expiresAt: 1_800_010_800)
        let fixture = CursorCacheFixture(rotatedTokens: [first, second, third])
        _ = await fixture.provider.refresh()
        fixture.responses.rejectedTokens = [first, second]

        let rejected = await fixture.provider.refresh()
        let recovered = await fixture.provider.refresh()

        XCTAssertEqual(rejected.errorCategory, .authExpired)
        XCTAssertNil(recovered.errorCategory)
        XCTAssertEqual(fixture.refreshRequests.count, 3)
        XCTAssertEqual(fixture.usageTokens, [first, first, second, third])
        XCTAssertTrue(fixture.keychain.modificationDates.isEmpty)
    }
}

@MainActor
private final class CursorCacheFixture {
    let keychain: ServiceKeychain
    let sqlite: CursorCacheSQLite
    let responses: CursorCacheResponses
    let http: RoutingHTTPClient
    let provider: CursorProvider

    init(rotatedTokens: [String]) {
        let keychain = ServiceKeychain(values: [
            CursorAuthStore.keychainAccessTokenService: cacheToken(expiresAt: 1),
            CursorAuthStore.keychainRefreshTokenService: "original-refresh"
        ])
        let sqlite = CursorCacheSQLite()
        let responses = CursorCacheResponses(rotatedTokens: rotatedTokens)
        let http = RoutingHTTPClient { try responses.respond(to: $0) }
        self.keychain = keychain
        self.sqlite = sqlite
        self.responses = responses
        self.http = http
        self.provider = CursorProvider(
            authStore: CursorAuthStore(sqlite: sqlite, keychain: keychain, now: {
                Date(timeIntervalSince1970: responses.now)
            }),
            usageClient: CursorUsageClient(http: http),
            now: { Date(timeIntervalSince1970: responses.now) },
            pricing: { .empty }
        )
    }

    var refreshRequests: [HTTPRequest] {
        http.requests.filter { $0.url == CursorUsageClient.refreshURL }
    }

    var usageTokens: [String] {
        http.requests.filter { $0.url == CursorUsageClient.usageURL }
            .compactMap { $0.headers["Authorization"].map { String($0.dropFirst("Bearer ".count)) } }
    }
}

private final class CursorCacheResponses: @unchecked Sendable {
    var now: TimeInterval = 1_800_000_000
    var rejectedTokens: Set<String> = []
    private let rotatedTokens: [String]
    private var refreshCount = 0

    init(rotatedTokens: [String]) {
        self.rotatedTokens = rotatedTokens
    }

    func respond(to request: HTTPRequest) throws -> HTTPResponse {
        let body: String
        switch request.url {
        case CursorUsageClient.refreshURL:
            let token = rotatedTokens[min(refreshCount, rotatedTokens.count - 1)]
            refreshCount += 1
            return HTTPResponse(statusCode: 200, headers: [:], body: try JSONSerialization.data(
                withJSONObject: ["access_token": token]
            ))
        case CursorUsageClient.usageURL:
            if rejectedTokens.contains(where: { request.headers["Authorization"] == "Bearer \($0)" }) {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            body = #"{"enabled":true,"planUsage":{"limit":40000,"remaining":32000,"totalPercentUsed":20}}"#
        case CursorUsageClient.planURL:
            body = #"{"planInfo":{"planName":"pro"}}"#
        case CursorUsageClient.creditsURL:
            body = #"{"hasCreditGrants":false}"#
        case CursorUsageClient.stripeURL:
            body = #"{"customerBalance":0}"#
        default:
            guard request.url.path == CursorUsageClient.exportCSVURL.path else {
                throw URLError(.unsupportedURL)
            }
            body = "Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens\n"
        }
        return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
    }
}

private final class CursorCacheSQLite: SQLiteAccessing, @unchecked Sendable {
    var values: [String: String] = [:]

    func queryValue(path: String, sql: String) throws -> String? {
        values.first { sql.contains($0.key) }?.value
    }

    func execute(path: String, sql: String) throws {
        throw SQLiteError.boundParametersUnsupported
    }

    func executeChanges(path: String, sql: String, bindings: [String?]) throws -> Int {
        guard bindings.count == 8, let key = bindings[0], let value = bindings[1],
              values[CursorAuthStore.accessTokenKey] == bindings[4],
              values[CursorAuthStore.refreshTokenKey] == bindings[7] else { return 0 }
        values[key] = value
        return 1
    }
}

private func cacheToken(expiresAt: Int) -> String {
    let payload = Data(#"{"sub":"auth0|cache-account","exp":\#(expiresAt)}"#.utf8)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "header.\(payload).signature"
}
