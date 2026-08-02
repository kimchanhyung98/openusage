import XCTest
@testable import OpenUsage

@MainActor
final class KiroProviderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testHasLocalCredentialsUsesReadOnlyLoaderWithoutNetwork() async {
        let sqlite = KiroProviderSQLiteFake(tokenRows: [kiroProviderTokenJSON(token: "token")])
        let http = KiroProviderHTTPFake()
        let provider = makeProvider(sqlite: sqlite, http: http)

        let hasCredentials = await provider.hasLocalCredentials()

        XCTAssertTrue(hasCredentials)
        XCTAssertEqual(sqlite.tokenQueryCount, 1)
        XCTAssertEqual(sqlite.executeCount, 0)
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testExpiredOrCorruptAuthDoesNotAutoEnable() async {
        let expiredSQLite = KiroProviderSQLiteFake(tokenRows: [
            kiroProviderTokenJSON(token: "expired", expiresAt: "2020-01-01T00:00:00Z")
        ])
        let corruptSQLite = KiroProviderSQLiteFake(tokenRows: ["not-json"])
        let expiredHTTP = KiroProviderHTTPFake()
        let corruptHTTP = KiroProviderHTTPFake()

        let expiredCredentials = await makeProvider(sqlite: expiredSQLite, http: expiredHTTP).hasLocalCredentials()
        let corruptCredentials = await makeProvider(sqlite: corruptSQLite, http: corruptHTTP).hasLocalCredentials()

        XCTAssertFalse(expiredCredentials)
        XCTAssertFalse(corruptCredentials)
        XCTAssertEqual(expiredSQLite.executeCount, 0)
        XCTAssertEqual(corruptSQLite.executeCount, 0)
        XCTAssertTrue(expiredHTTP.requests.isEmpty)
        XCTAssertTrue(corruptHTTP.requests.isEmpty)
    }

    func testExplicitRefreshSurfacesStorageAndAuthErrors() async {
        let cases: [(KiroProviderSQLiteFake, ErrorCategory)] = [
            (KiroProviderSQLiteFake(queryError: KiroProviderTestError.queryFailed), .credentialAccess),
            (KiroProviderSQLiteFake(tokenRows: []), .notLoggedIn),
            (KiroProviderSQLiteFake(tokenRows: ["not-json"]), .authInvalid),
            (KiroProviderSQLiteFake(tokenRows: [kiroProviderTokenJSON(
                token: "expired",
                expiresAt: "2020-01-01T00:00:00Z"
            )]), .authExpired),
        ]

        for (sqlite, expectedCategory) in cases {
            let http = KiroProviderHTTPFake()
            let snapshot = await makeProvider(sqlite: sqlite, http: http).refresh()
            XCTAssertEqual(snapshot.lines.first?.label, "Error")
            XCTAssertEqual(snapshot.errorCategory, expectedCategory)
            XCTAssertTrue(http.requests.isEmpty)
            XCTAssertEqual(sqlite.executeCount, 0)
        }
    }

    func testSuccessfulFetchReturnsCreditsAndPlanOnly() async throws {
        let sqlite = KiroProviderSQLiteFake(tokenRows: [kiroProviderTokenJSON(token: "token")])
        let http = KiroProviderHTTPFake(responses: [
            HTTPResponse(statusCode: 200, headers: [:], body: kiroProviderUsageData())
        ])
        let provider = makeProvider(sqlite: sqlite, http: http)

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.providerID, "kiro")
        XCTAssertEqual(snapshot.plan, "Kiro Pro")
        XCTAssertEqual(snapshot.lines.map(\.label), ["Credits"])
        guard case .progress(_, let used, let limit, let format, _, let period, _) = snapshot.lines.first else {
            return XCTFail("expected Credits progress line")
        }
        XCTAssertEqual(used, 10.25)
        XCTAssertEqual(limit, 50)
        XCTAssertEqual(format, .count(suffix: "credits"))
        XCTAssertEqual(period, KiroUsageMapper.billingPeriodMs)
        XCTAssertEqual(snapshot.refreshedAt, now)
        XCTAssertEqual(sqlite.executeCount, 0)
    }

    func testUnauthorizedRereadsDatabaseAndRetriesChangedTokenOnce() async {
        let sqlite = KiroProviderSQLiteFake(tokenRows: [
            kiroProviderTokenJSON(token: "old-token"),
            kiroProviderTokenJSON(token: "new-token"),
        ])
        let http = KiroProviderHTTPFake(responses: [
            HTTPResponse(statusCode: 401, headers: [:], body: Data()),
            HTTPResponse(statusCode: 200, headers: [:], body: kiroProviderUsageData()),
        ])

        let snapshot = await makeProvider(sqlite: sqlite, http: http).refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(sqlite.tokenQueryCount, 2)
        XCTAssertEqual(http.requests.map { $0.headers["Authorization"] }, ["Bearer old-token", "Bearer new-token"])
        XCTAssertEqual(sqlite.executeCount, 0)
    }

    func testForbiddenAlsoRetriesChangedTokenOnce() async {
        let sqlite = KiroProviderSQLiteFake(tokenRows: [
            kiroProviderTokenJSON(token: "old-token"),
            kiroProviderTokenJSON(token: "new-token"),
        ])
        let http = KiroProviderHTTPFake(responses: [
            HTTPResponse(statusCode: 403, headers: [:], body: Data()),
            HTTPResponse(statusCode: 200, headers: [:], body: kiroProviderUsageData()),
        ])

        let snapshot = await makeProvider(sqlite: sqlite, http: http).refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(sqlite.tokenQueryCount, 2)
        XCTAssertEqual(http.requests.count, 2)
    }

    func testUnauthorizedUnchangedTokenReturnsAuthExpired() async {
        let tokenRow = kiroProviderTokenJSON(token: "same-token")
        let sqlite = KiroProviderSQLiteFake(tokenRows: [tokenRow, tokenRow])
        let http = KiroProviderHTTPFake(responses: [
            HTTPResponse(statusCode: 401, headers: [:], body: Data())
        ])

        let snapshot = await makeProvider(sqlite: sqlite, http: http).refresh()

        XCTAssertEqual(snapshot.errorCategory, .authExpired)
        XCTAssertEqual(sqlite.tokenQueryCount, 2)
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(sqlite.executeCount, 0)
    }

    func testSecondUnauthorizedReturnsAuthExpired() async {
        let sqlite = KiroProviderSQLiteFake(tokenRows: [
            kiroProviderTokenJSON(token: "old-token"),
            kiroProviderTokenJSON(token: "new-token"),
        ])
        let http = KiroProviderHTTPFake(responses: [
            HTTPResponse(statusCode: 401, headers: [:], body: Data()),
            HTTPResponse(statusCode: 403, headers: [:], body: Data()),
        ])

        let snapshot = await makeProvider(sqlite: sqlite, http: http).refresh()

        XCTAssertEqual(snapshot.errorCategory, .authExpired)
        XCTAssertEqual(sqlite.tokenQueryCount, 2)
        XCTAssertEqual(http.requests.count, 2)
        XCTAssertEqual(sqlite.executeCount, 0)
    }

    func testNonAuthFailureDoesNotRereadDatabase() async {
        let sqlite = KiroProviderSQLiteFake(tokenRows: [kiroProviderTokenJSON(token: "token")])
        let http = KiroProviderHTTPFake(responses: [
            HTTPResponse(statusCode: 429, headers: [:], body: Data())
        ])

        let snapshot = await makeProvider(sqlite: sqlite, http: http).refresh()

        XCTAssertEqual(snapshot.errorCategory, .rateLimited)
        XCTAssertEqual(sqlite.tokenQueryCount, 1)
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(sqlite.executeCount, 0)
    }

    func testRuntimeNeverWritesSQLiteOrCallsRefreshEndpoint() async {
        let sqlite = KiroProviderSQLiteFake(tokenRows: [kiroProviderTokenJSON(token: "token")])
        let http = KiroProviderHTTPFake(responses: [
            HTTPResponse(statusCode: 200, headers: [:], body: kiroProviderUsageData())
        ])

        _ = await makeProvider(sqlite: sqlite, http: http).refresh()

        XCTAssertEqual(sqlite.executeCount, 0)
        XCTAssertEqual(http.requests.map(\.url), [KiroUsageClient.endpoint])
        XCTAssertEqual(http.requests.map { $0.headers["x-amz-target"] }, [KiroUsageClient.target])
    }

    func testUsageAPI500ReturnsHTTP5xxCategory() async {
        let sqlite = KiroProviderSQLiteFake(tokenRows: [kiroProviderTokenJSON(token: "token")])
        let http = KiroProviderHTTPFake(responses: [
            HTTPResponse(statusCode: 500, headers: [:], body: Data())
        ])

        let snapshot = await makeProvider(sqlite: sqlite, http: http).refresh()

        XCTAssertEqual(snapshot.errorCategory, .http5xx)
        XCTAssertEqual(sqlite.tokenQueryCount, 1)
        XCTAssertEqual(http.requests.count, 1)
    }

    func testTransportFailureReturnsNetworkCategory() async {
        let sqlite = KiroProviderSQLiteFake(tokenRows: [kiroProviderTokenJSON(token: "token")])
        let http = KiroProviderHTTPFake(error: URLError(.cannotConnectToHost))

        let snapshot = await makeProvider(sqlite: sqlite, http: http).refresh()

        XCTAssertEqual(snapshot.errorCategory, .network)
        XCTAssertEqual(sqlite.tokenQueryCount, 1)
    }

    func testProviderIdentityDescriptorAndLimitResource() throws {
        let provider = KiroProvider()

        XCTAssertEqual(provider.provider.id, "kiro")
        XCTAssertEqual(provider.provider.displayName, "Kiro")
        XCTAssertTrue(provider.provider.visibleLinks.isEmpty)
        let descriptor = try XCTUnwrap(provider.widgetDescriptors.only)
        XCTAssertEqual(descriptor.id, "kiro.credits")
        XCTAssertEqual(descriptor.metricLabel, "Credits")
        let resource = try XCTUnwrap(descriptor.limitResources.only)
        XCTAssertEqual(resource.key, "credits")
        XCTAssertEqual(resource.kind, .consumption)
        XCTAssertEqual(resource.unit, "credits")
        XCTAssertEqual(resource.source, .progress)
    }

    private func makeProvider(
        sqlite: KiroProviderSQLiteFake,
        http: KiroProviderHTTPFake
    ) -> KiroProvider {
        KiroProvider(
            authStore: KiroAuthStore(sqlite: sqlite),
            usageClient: KiroUsageClient(http: http),
            now: { [now] in now }
        )
    }
}

private func kiroProviderTokenJSON(
    token: String,
    expiresAt: String = "2099-01-01T00:00:00Z",
    profileArn: String = "arn:aws:codewhisperer:us-east-1:123456789012:profile/ABC"
) -> String {
    let data = try! JSONSerialization.data(withJSONObject: [
        "access_token": token,
        "expires_at": expiresAt,
        "profile_arn": profileArn,
    ], options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

private func kiroProviderUsageData() -> Data {
    try! JSONSerialization.data(withJSONObject: [
        "subscriptionInfo": ["subscriptionTitle": "Kiro Pro"],
        "usageBreakdownList": [[
            "resourceType": "CREDIT",
            "currentUsageWithPrecision": 10.25,
            "usageLimitWithPrecision": 50.0,
            "nextDateReset": 1_788_134_400,
            "bonuses": [],
        ]],
        "overageConfiguration": ["overageStatus": "DISABLED"],
    ], options: [.sortedKeys])
}

private enum KiroProviderTestError: Error {
    case queryFailed
    case executeForbidden
    case responseMissing
}

private final class KiroProviderSQLiteFake: SQLiteAccessing, @unchecked Sendable {
    var tokenRows: [String]
    var queryError: Error?
    var tokenQueryCount = 0
    var executeCount = 0

    init(tokenRows: [String] = [], queryError: Error? = nil) {
        self.tokenRows = tokenRows
        self.queryError = queryError
    }

    func queryValue(path: String, sql: String) throws -> String? {
        if let queryError { throw queryError }
        if sql.contains("FROM auth_kv") {
            tokenQueryCount += 1
            return tokenRows.isEmpty ? nil : tokenRows.removeFirst()
        }
        return nil
    }

    func execute(path: String, sql: String) throws {
        executeCount += 1
        throw KiroProviderTestError.executeForbidden
    }
}

private final class KiroProviderHTTPFake: HTTPClient, @unchecked Sendable {
    var responses: [HTTPResponse]
    var error: Error?
    var requests: [HTTPRequest] = []

    init(responses: [HTTPResponse] = [], error: Error? = nil) {
        self.responses = responses
        self.error = error
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        if let error { throw error }
        guard !responses.isEmpty else { throw KiroProviderTestError.responseMissing }
        return responses.removeFirst()
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
