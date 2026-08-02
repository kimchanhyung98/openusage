import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class KimiProviderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000)

    func testProviderMetadataAndDescriptors() {
        let provider = KimiProvider(now: { Date(timeIntervalSince1970: 2_000) })

        XCTAssertEqual(provider.provider.id, "kimi")
        XCTAssertEqual(provider.provider.displayName, "Kimi")
        XCTAssertTrue(provider.provider.links.isEmpty)
        XCTAssertEqual(provider.widgetDescriptors.map(\.id), ["kimi.session", "kimi.weekly"])
        XCTAssertEqual(provider.widgetDescriptors.map(\.metricLabel), ["Session", "Weekly"])
        XCTAssertTrue(provider.widgetDescriptors[0].sample.isSessionWindow)
        XCTAssertEqual(provider.widgetDescriptors[0].limitResources.first?.key, "session")
        XCTAssertEqual(provider.widgetDescriptors[1].limitResources.first?.key, "weekly")
    }

    func testHasLocalCredentialsUsesLoaderWithoutNetwork() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let files = FakeFiles([
            fixture.credential.path: credentialJSON(access: "valid", refresh: nil, expiresAt: now.addingTimeInterval(3_600))
        ])
        let http = KimiRecordingHTTPClient { _ in
            HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }
        let provider = makeProvider(fixture: fixture, files: files, http: http)

        let hasCredentials = await provider.hasLocalCredentials()
        XCTAssertTrue(hasCredentials)
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testCorruptCredentialDoesNotAutoEnableAndExplicitRefreshSurfacesError() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let http = KimiRecordingHTTPClient { _ in
            XCTFail("corrupt credentials must fail before network access")
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }
        let provider = makeProvider(
            fixture: fixture,
            files: FakeFiles([fixture.credential.path: "not-json"]),
            http: http
        )

        let hasCredentials = await provider.hasLocalCredentials()
        XCTAssertFalse(hasCredentials)
        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .authInvalid)
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testValidCurrentTokenFetchesWithoutLock() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let files = FakeFiles([
            fixture.credential.path: credentialJSON(
                access: "valid-access",
                refresh: "unused-refresh",
                expiresAt: now.addingTimeInterval(7_200),
                expiresIn: 3_600
            )
        ])
        let http = KimiRecordingHTTPClient { request in
            XCTAssertEqual(request.url, KimiUsageClient.usageURL)
            XCTAssertEqual(request.headers["Authorization"], "Bearer valid-access")
            return HTTPResponse(statusCode: 200, headers: [:], body: Self.usageBody)
        }
        let provider = makeProvider(fixture: fixture, files: files, http: http)

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.plan, "Allegro")
        XCTAssertEqual(kimiProviderProgress(snapshot.lines, "Session")?.used, 25)
        XCTAssertEqual(kimiProviderProgress(snapshot.lines, "Weekly")?.used, 60)
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.lockURL.path))
    }

    func testNonExpiringCurrentTokenFetchesWithoutRefresh() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let files = FakeFiles([
            fixture.credential.path: credentialJSON(
                access: "non-expiring-access",
                refresh: "unused-refresh",
                expiresAt: nil
            )
        ])
        let http = KimiRecordingHTTPClient { request in
            XCTAssertEqual(request.url, KimiUsageClient.usageURL)
            XCTAssertEqual(request.headers["Authorization"], "Bearer non-expiring-access")
            return HTTPResponse(statusCode: 200, headers: [:], body: Self.usageBody)
        }
        let provider = makeProvider(fixture: fixture, files: files, http: http)

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(http.requests.map(\.url), [KimiUsageClient.usageURL])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.lockURL.path))
    }

    func testProactiveRefreshPersistsRotatedCredentialBeforeUsageFetch() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let files = FakeFiles([
            fixture.credential.path: credentialJSON(
                access: "expiring-access",
                refresh: "fake-refresh",
                expiresAt: now.addingTimeInterval(60),
                expiresIn: 3_600,
                extra: ["custom": "keep"]
            )
        ])
        let http = KimiRecordingHTTPClient { request in
            if request.url == KimiUsageClient.refreshURL {
                return Self.refreshResponse(access: "rotated-access", refresh: "rotated-refresh")
            }
            XCTAssertEqual(request.headers["Authorization"], "Bearer rotated-access")
            return HTTPResponse(statusCode: 200, headers: [:], body: Self.usageBody)
        }
        let provider = makeProvider(fixture: fixture, files: files, http: http)

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(http.requests.map(\.url), [KimiUsageClient.refreshURL, KimiUsageClient.usageURL])
        let saved = try XCTUnwrap(ProviderParse.jsonObject(Data(files.files[fixture.credential.path]!.utf8)))
        XCTAssertEqual(saved["access_token"] as? String, "rotated-access")
        XCTAssertEqual(saved["refresh_token"] as? String, "rotated-refresh")
        XCTAssertEqual(saved["custom"] as? String, "keep")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.lockURL.path))
    }

    func testRefreshOnlyCurrentCredentialIsRevokedWithoutNetworkAccess() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let files = FakeFiles([
            fixture.credential.path: credentialJSON(access: nil, refresh: "fake-refresh", expiresAt: nil)
        ])
        let http = KimiRecordingHTTPClient { _ in
            XCTFail("revoked credentials must fail before network access")
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }
        let provider = makeProvider(fixture: fixture, files: files, http: http)

        let hasCredentials = await provider.hasLocalCredentials()
        let snapshot = await provider.refresh()

        XCTAssertFalse(hasCredentials)
        XCTAssertEqual(snapshot.errorCategory, .authExpired)
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testChangedTokenAfterLockIsAdoptedWithoutOAuthRefresh() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let old = credentialJSON(
            access: "old-access",
            refresh: "fake-refresh",
            expiresAt: now.addingTimeInterval(60),
            expiresIn: 3_600
        )
        let changed = credentialJSON(
            access: "changed-access",
            refresh: "changed-refresh",
            expiresAt: now.addingTimeInterval(7_200),
            expiresIn: 3_600
        )
        let files = KimiSequencedCredentialFiles(
            credentialPath: fixture.credential.path,
            documents: [old, changed]
        )
        let http = KimiRecordingHTTPClient { request in
            XCTAssertEqual(request.url, KimiUsageClient.usageURL)
            XCTAssertEqual(request.headers["Authorization"], "Bearer changed-access")
            return HTTPResponse(statusCode: 200, headers: [:], body: Self.usageBody)
        }
        let provider = makeProvider(fixture: fixture, files: files, http: http)

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(http.requests.map(\.url), [KimiUsageClient.usageURL])
        XCTAssertEqual(files.writeCount, 0)
    }

    func testChangedButExpiredAccessTokenIsRefreshedInsteadOfAdopted() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let old = credentialJSON(
            access: "old-access",
            refresh: "old-refresh",
            expiresAt: now.addingTimeInterval(60),
            expiresIn: 3_600
        )
        let changed = credentialJSON(
            access: "expired-access",
            refresh: "changed-refresh",
            expiresAt: now.addingTimeInterval(-60),
            expiresIn: 3_600
        )
        let files = KimiSequencedCredentialFiles(
            credentialPath: fixture.credential.path,
            documents: [old, changed]
        )
        let http = KimiRecordingHTTPClient { request in
            if request.url == KimiUsageClient.refreshURL {
                let body = String(decoding: request.body ?? Data(), as: UTF8.self)
                XCTAssertTrue(body.contains("refresh_token=changed-refresh"))
                return Self.refreshResponse(access: "rotated-access", refresh: "rotated-refresh")
            }
            XCTAssertEqual(request.headers["Authorization"], "Bearer rotated-access")
            return HTTPResponse(statusCode: 200, headers: [:], body: Self.usageBody)
        }
        let provider = makeProvider(fixture: fixture, files: files, http: http)

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(http.requests.map(\.url), [KimiUsageClient.refreshURL, KimiUsageClient.usageURL])
        XCTAssertEqual(files.writeCount, 1)
    }

    func testUnauthorizedFetchRefreshesAndRetriesExactlyOnce() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let files = FakeFiles([
            fixture.credential.path: credentialJSON(
                access: "old-access",
                refresh: "fake-refresh",
                expiresAt: now.addingTimeInterval(7_200),
                expiresIn: 3_600
            )
        ])
        var usageCalls = 0
        let http = KimiRecordingHTTPClient { request in
            if request.url == KimiUsageClient.refreshURL {
                return Self.refreshResponse(access: "new-access", refresh: "new-refresh")
            }
            usageCalls += 1
            if usageCalls == 1 {
                XCTAssertEqual(request.headers["Authorization"], "Bearer old-access")
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            XCTAssertEqual(request.headers["Authorization"], "Bearer new-access")
            return HTTPResponse(statusCode: 200, headers: [:], body: Self.usageBody)
        }
        let provider = makeProvider(fixture: fixture, files: files, http: http)

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(
            http.requests.map(\.url),
            [KimiUsageClient.usageURL, KimiUsageClient.refreshURL, KimiUsageClient.usageURL]
        )
    }

    func testSecondUnauthorizedReturnsAuthExpired() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let files = FakeFiles([
            fixture.credential.path: credentialJSON(
                access: "old-access",
                refresh: "fake-refresh",
                expiresAt: now.addingTimeInterval(7_200),
                expiresIn: 3_600
            )
        ])
        let http = KimiRecordingHTTPClient { request in
            if request.url == KimiUsageClient.refreshURL {
                return Self.refreshResponse(access: "new-access", refresh: "new-refresh")
            }
            return HTTPResponse(statusCode: 403, headers: [:], body: Data())
        }
        let provider = makeProvider(fixture: fixture, files: files, http: http)

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .authExpired)
        XCTAssertEqual(http.requests.filter { $0.url == KimiUsageClient.usageURL }.count, 2)
        XCTAssertEqual(http.requests.filter { $0.url == KimiUsageClient.refreshURL }.count, 1)
    }

    func testLegacyCredentialNeverRefreshesOrWrites() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let legacy = fixture.root.appendingPathComponent(".kimi/credentials/kimi-code.json")
        let files = FakeFiles([
            legacy.path: credentialJSON(access: "legacy-access", refresh: "legacy-refresh", expiresAt: now.addingTimeInterval(7_200))
        ])
        let http = KimiRecordingHTTPClient { request in
            XCTAssertEqual(request.url, KimiUsageClient.usageURL)
            return HTTPResponse(statusCode: 401, headers: [:], body: Data())
        }
        let provider = makeProvider(
            fixture: fixture,
            files: files,
            http: http,
            environment: FakeEnvironment(["KIMI_CODE_HOME": fixture.root.appendingPathComponent("missing-current").path]),
            homeDirectory: { fixture.root }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .authExpired)
        XCTAssertEqual(http.requests.map(\.url), [KimiUsageClient.usageURL])
        XCTAssertEqual(files.files[legacy.path], credentialJSON(
            access: "legacy-access",
            refresh: "legacy-refresh",
            expiresAt: now.addingTimeInterval(7_200)
        ))
    }

    func testNonAuthFailureDoesNotRefresh() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let files = FakeFiles([
            fixture.credential.path: credentialJSON(
                access: "valid-access",
                refresh: "unused-refresh",
                expiresAt: now.addingTimeInterval(7_200),
                expiresIn: 3_600
            )
        ])
        let http = KimiRecordingHTTPClient { _ in
            HTTPResponse(statusCode: 503, headers: [:], body: Data())
        }
        let provider = makeProvider(fixture: fixture, files: files, http: http)

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .http5xx)
        XCTAssertEqual(http.requests.map(\.url), [KimiUsageClient.usageURL])
    }

    func testCompromisedLockPreventsCredentialWrite() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = credentialJSON(
            access: "expiring-access",
            refresh: "fake-refresh",
            expiresAt: now.addingTimeInterval(60),
            expiresIn: 3_600
        )
        let files = FakeFiles([fixture.credential.path: original])
        let http = KimiRecordingHTTPClient { request in
            if request.url == KimiUsageClient.refreshURL {
                try? FileManager.default.removeItem(at: fixture.lockURL)
                try? FileManager.default.createDirectory(at: fixture.lockURL, withIntermediateDirectories: false)
                return Self.refreshResponse(access: "new-access", refresh: "new-refresh")
            }
            return HTTPResponse(statusCode: 200, headers: [:], body: Self.usageBody)
        }
        let provider = makeProvider(fixture: fixture, files: files, http: http)

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .credentialAccess)
        XCTAssertEqual(files.files[fixture.credential.path], original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.lockURL.path))
    }

    func testPersistenceFailureReleasesOwnedLock() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let files = KimiProviderFiles(
            files: [fixture.credential.path: credentialJSON(
                access: "expiring-access",
                refresh: "fake-refresh",
                expiresAt: now.addingTimeInterval(60),
                expiresIn: 3_600
            )],
            failWrites: true
        )
        let http = KimiRecordingHTTPClient { request in
            if request.url == KimiUsageClient.refreshURL {
                return Self.refreshResponse(access: "new-access", refresh: "new-refresh")
            }
            return HTTPResponse(statusCode: 200, headers: [:], body: Self.usageBody)
        }
        let provider = makeProvider(fixture: fixture, files: files, http: http)

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .credentialAccess)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.lockURL.path))
    }

    private func makeProvider(
        fixture: KimiProviderFixture,
        files: TextFileAccessing,
        http: HTTPClient,
        environment: EnvironmentReading? = nil,
        homeDirectory: (@Sendable () -> URL)? = nil
    ) -> KimiProvider {
        let fixedNow = now
        return KimiProvider(
            authStore: KimiAuthStore(
                files: files,
                environment: environment ?? FakeEnvironment(["KIMI_CODE_HOME": fixture.root.path]),
                homeDirectory: homeDirectory ?? { fixture.root }
            ),
            usageClient: KimiUsageClient(http: http, now: { fixedNow }),
            credentialLock: KimiCredentialLock(configuration: KimiCredentialLock.Configuration(
                staleInterval: 1,
                heartbeatInterval: 0.05,
                acquisitionBudget: 0.3,
                retryDelay: 0.005
            )),
            now: { fixedNow }
        )
    }

    private func makeFixture() throws -> KimiProviderFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-kimi-provider-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let credential = root.appendingPathComponent("credentials/kimi-code.json")
        let lockTarget = root.appendingPathComponent("oauth/kimi-code")
        return KimiProviderFixture(
            root: root,
            credential: credential,
            lockURL: URL(fileURLWithPath: lockTarget.path + ".lock")
        )
    }

    private func credentialJSON(
        access: String?,
        refresh: String?,
        expiresAt: Date?,
        expiresIn: TimeInterval? = nil,
        extra: [String: Any] = [:]
    ) -> String {
        var object = extra
        if let access { object["access_token"] = access }
        if let refresh { object["refresh_token"] = refresh }
        if let expiresAt { object["expires_at"] = expiresAt.timeIntervalSince1970 }
        if let expiresIn { object["expires_in"] = expiresIn }
        return String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    private static let usageBody = Data(#"""
    {
      "user":{"membership":{"level":"LEVEL_ADVANCED"}},
      "limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":100,"used":25}}],
      "usage":{"limit":100,"used":60}
    }
    """#.utf8)

    private static func refreshResponse(access: String, refresh: String) -> HTTPResponse {
        HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"access_token":"\#(access)","refresh_token":"\#(refresh)","expires_in":3600}"#.utf8)
        )
    }
}

private struct KimiProviderFixture: Sendable {
    var root: URL
    var credential: URL
    var lockURL: URL
}

private final class KimiRecordingHTTPClient: HTTPClient, @unchecked Sendable {
    var requests: [HTTPRequest] = []
    private let handler: (HTTPRequest) throws -> HTTPResponse

    init(handler: @escaping (HTTPRequest) throws -> HTTPResponse) {
        self.handler = handler
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        return try handler(request)
    }
}

private final class KimiSequencedCredentialFiles: TextFileAccessing, @unchecked Sendable {
    let credentialPath: String
    let documents: [String]
    var readCount = 0
    var writeCount = 0

    init(credentialPath: String, documents: [String]) {
        self.credentialPath = credentialPath
        self.documents = documents
    }

    func exists(_ path: String) -> Bool { path == credentialPath }

    func readTextIfPresent(_ path: String) throws -> String? {
        guard path == credentialPath else { return nil }
        let index = min(readCount, documents.count - 1)
        readCount += 1
        return documents[index]
    }

    func readText(_ path: String) throws -> String {
        try readTextIfPresent(path) ?? ""
    }

    func writeText(_ path: String, _ text: String) throws {
        writeCount += 1
    }

    func remove(_ path: String) throws {}
}

private final class KimiProviderFiles: TextFileAccessing, @unchecked Sendable {
    var files: [String: String]
    let failWrites: Bool

    init(files: [String: String], failWrites: Bool) {
        self.files = files
        self.failWrites = failWrites
    }

    func exists(_ path: String) -> Bool { files[path] != nil }
    func readTextIfPresent(_ path: String) throws -> String? { files[path] }
    func readText(_ path: String) throws -> String { files[path] ?? "" }

    func writeText(_ path: String, _ text: String) throws {
        if failWrites { throw KimiProviderFileError.writeFailed }
        files[path] = text
    }

    func remove(_ path: String) throws {
        files.removeValue(forKey: path)
    }
}

private enum KimiProviderFileError: Error {
    case writeFailed
}

private func kimiProviderProgress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double)? {
    guard case .progress(_, let used, let limit, _, _, _, _) = lines.first(where: { $0.label == label }) else {
        return nil
    }
    return (used, limit)
}
