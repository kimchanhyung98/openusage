import XCTest
@testable import OpenUsage

final class KiroAuthStoreTests: XCTestCase {
    func testMissingDatabaseOrTokenRowReturnsNil() throws {
        let sqlite = KiroAuthSQLiteFake()

        XCTAssertNil(try KiroAuthStore(sqlite: sqlite).loadAuth())
        XCTAssertEqual(sqlite.queries.count, 1)
        XCTAssertEqual(sqlite.queries.first?.path, KiroAuthStore.stateDBPath)
        XCTAssertTrue(sqlite.queries.first?.sql.contains(KiroAuthStore.socialTokenKey) == true)
    }

    func testReadsSnakeCaseAccessTokenAndISO8601Expiry() throws {
        let sqlite = KiroAuthSQLiteFake(tokenJSON: #"""
        {
            "access_token":"  access-token  ",
            "expires_at":"2099-01-02T03:04:05.000Z",
            "profile_arn":"  arn:aws:codewhisperer:us-east-1:123456789012:profile/ABC  "
        }
        """#)

        let auth = try XCTUnwrap(KiroAuthStore(sqlite: sqlite).loadAuth())

        XCTAssertEqual(auth.accessToken, "access-token")
        XCTAssertEqual(auth.expiresAt, OpenUsageISO8601.date(from: "2099-01-02T03:04:05.000Z"))
        XCTAssertEqual(auth.profileArn, "arn:aws:codewhisperer:us-east-1:123456789012:profile/ABC")
    }

    func testTokenProfileArnWinsOverStateFallback() throws {
        let sqlite = KiroAuthSQLiteFake(
            tokenJSON: validTokenJSON(profileArn: "arn:embedded"),
            profileJSON: #"{"arn":"arn:fallback"}"#
        )

        let auth = try XCTUnwrap(KiroAuthStore(sqlite: sqlite).loadAuth())

        XCTAssertEqual(auth.profileArn, "arn:embedded")
        XCTAssertEqual(sqlite.queries.count, 1)
    }

    func testStateFallbackReadsArnFromApiCodewhispererProfile() throws {
        let sqlite = KiroAuthSQLiteFake(
            tokenJSON: validTokenJSON(profileArn: nil),
            profileJSON: #"{"arn":"  arn:aws:codewhisperer:us-east-1:123456789012:profile/FALLBACK  "}"#
        )

        let auth = try XCTUnwrap(KiroAuthStore(sqlite: sqlite).loadAuth())

        XCTAssertEqual(auth.profileArn, "arn:aws:codewhisperer:us-east-1:123456789012:profile/FALLBACK")
        XCTAssertEqual(sqlite.queries.count, 2)
        XCTAssertTrue(sqlite.queries[1].sql.contains(KiroAuthStore.profileKey))
    }

    func testMissingOrMalformedExpiryThrowsCredentialsInvalid() {
        for tokenJSON in [
            #"{"access_token":"token","profile_arn":"arn:profile"}"#,
            #"{"access_token":"token","expires_at":"not-a-date","profile_arn":"arn:profile"}"#,
            #"{"access_token":"token","expires_at":123,"profile_arn":"arn:profile"}"#,
        ] {
            XCTAssertThrowsError(try KiroAuthStore(sqlite: KiroAuthSQLiteFake(tokenJSON: tokenJSON)).loadAuth()) {
                XCTAssertEqual($0 as? KiroAuthError, .credentialsInvalid)
            }
        }
    }

    func testTokenlessRowThrowsCredentialsInvalid() {
        let sqlite = KiroAuthSQLiteFake(
            tokenJSON: #"{"expires_at":"2099-01-02T03:04:05Z","profile_arn":"arn:profile"}"#
        )

        XCTAssertThrowsError(try KiroAuthStore(sqlite: sqlite).loadAuth()) {
            XCTAssertEqual($0 as? KiroAuthError, .credentialsInvalid)
        }
    }

    func testExpiredAuthIsNotUsable() {
        let store = KiroAuthStore(sqlite: KiroAuthSQLiteFake())
        let now = Date(timeIntervalSince1970: 2_000)

        XCTAssertFalse(store.isUsable(
            KiroAuth(accessToken: "token", expiresAt: Date(timeIntervalSince1970: 1_999), profileArn: "arn"),
            now: now
        ))
        XCTAssertFalse(store.isUsable(
            KiroAuth(accessToken: "token", expiresAt: now, profileArn: "arn"),
            now: now
        ))
        XCTAssertTrue(store.isUsable(
            KiroAuth(accessToken: "token", expiresAt: Date(timeIntervalSince1970: 2_001), profileArn: "arn"),
            now: now
        ))
    }

    func testMalformedTokenJSONThrowsCredentialsInvalid() {
        XCTAssertThrowsError(try KiroAuthStore(sqlite: KiroAuthSQLiteFake(tokenJSON: "not-json")).loadAuth()) {
            XCTAssertEqual($0 as? KiroAuthError, .credentialsInvalid)
        }
    }

    func testMissingOrMalformedFallbackProfileThrowsMissingProfile() {
        for profileJSON in [nil, "not-json", #"{"profileArn":"wrong-key"}"#, #"{"arn":"   "}"#] as [String?] {
            let sqlite = KiroAuthSQLiteFake(
                tokenJSON: validTokenJSON(profileArn: nil),
                profileJSON: profileJSON
            )

            XCTAssertThrowsError(try KiroAuthStore(sqlite: sqlite).loadAuth()) {
                XCTAssertEqual($0 as? KiroAuthError, .missingProfile)
            }
        }
    }

    func testQueryFailureThrowsCredentialsUnreadable() {
        let sqlite = KiroAuthSQLiteFake(queryError: KiroAuthTestError.queryFailed)

        XCTAssertThrowsError(try KiroAuthStore(sqlite: sqlite).loadAuth()) {
            XCTAssertEqual($0 as? KiroAuthError, .credentialsUnreadable)
        }
    }

    func testFallbackProfileQueryFailureThrowsCredentialsUnreadable() {
        let sqlite = KiroAuthSQLiteFake(
            tokenJSON: validTokenJSON(profileArn: nil),
            profileQueryError: KiroAuthTestError.queryFailed
        )

        XCTAssertThrowsError(try KiroAuthStore(sqlite: sqlite).loadAuth()) {
            XCTAssertEqual($0 as? KiroAuthError, .credentialsUnreadable)
        }
    }

    func testLoaderNeverCallsSQLiteExecute() throws {
        let sqlite = KiroAuthSQLiteFake(tokenJSON: validTokenJSON())

        _ = try KiroAuthStore(sqlite: sqlite).loadAuth()

        XCTAssertEqual(sqlite.executeCount, 0)
    }

    func testLoaderSQLContainsNoCredentialValue() throws {
        let token = "secret-access-token"
        let profileArn = "arn:aws:codewhisperer:us-east-1:123456789012:profile/SECRET"
        let sqlite = KiroAuthSQLiteFake(tokenJSON: validTokenJSON(token: token, profileArn: profileArn))

        _ = try KiroAuthStore(sqlite: sqlite).loadAuth()

        for query in sqlite.queries {
            XCTAssertFalse(query.sql.contains(token))
            XCTAssertFalse(query.sql.contains(profileArn))
        }
        XCTAssertEqual(sqlite.executeCount, 0)
    }
}

private func validTokenJSON(
    token: String = "access-token",
    expiresAt: String = "2099-01-02T03:04:05Z",
    profileArn: String? = "arn:profile"
) -> String {
    var object = [
        "access_token": token,
        "expires_at": expiresAt,
    ]
    if let profileArn { object["profile_arn"] = profileArn }
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

private enum KiroAuthTestError: Error {
    case queryFailed
    case executeForbidden
}

private final class KiroAuthSQLiteFake: SQLiteAccessing, @unchecked Sendable {
    struct Query {
        var path: String
        var sql: String
    }

    var tokenJSON: String?
    var profileJSON: String?
    var queryError: Error?
    var profileQueryError: Error?
    var queries: [Query] = []
    var executeCount = 0

    init(
        tokenJSON: String? = nil,
        profileJSON: String? = nil,
        queryError: Error? = nil,
        profileQueryError: Error? = nil
    ) {
        self.tokenJSON = tokenJSON
        self.profileJSON = profileJSON
        self.queryError = queryError
        self.profileQueryError = profileQueryError
    }

    func queryValue(path: String, sql: String) throws -> String? {
        queries.append(Query(path: path, sql: sql))
        if let queryError { throw queryError }
        if sql.contains("FROM auth_kv") { return tokenJSON }
        if sql.contains("FROM state") {
            if let profileQueryError { throw profileQueryError }
            return profileJSON
        }
        return nil
    }

    func execute(path: String, sql: String) throws {
        executeCount += 1
        throw KiroAuthTestError.executeForbidden
    }
}
