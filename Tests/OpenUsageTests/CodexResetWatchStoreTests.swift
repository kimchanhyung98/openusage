import Foundation
import XCTest
@testable import OpenUsage

final class CodexResetWatchStoreTests: XCTestCase {
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testActiveWatchDecodesAndSendsPublicRequestWithoutCredentials() async throws {
        let deadline = Self.start.addingTimeInterval(3_600)
        let http = ResetWatchHTTPClient([
            .init(response: Self.activeResponse(chance: 75, deadline: deadline))
        ])
        let clock = ResetWatchClock(Self.start)
        let store = CodexResetWatchStore(http: http, now: clock.read)

        let current = await store.current()
        let watch = try XCTUnwrap(current)

        XCTAssertEqual(watch.chancePercent, 75)
        XCTAssertEqual(watch.deadline, deadline)
        let recordedRequests = await http.recordedRequests()
        let request = try XCTUnwrap(recordedRequests.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.url.absoluteString, "https://codex-resets.com/api/v1/status")
        XCTAssertEqual(request.timeout, 8)
        XCTAssertEqual(request.headers["Accept"], "application/json")
        XCTAssertEqual(request.headers["User-Agent"], "OpenUsage")
        XCTAssertNil(request.body)

        let headerNames = Set(request.headers.keys.map { $0.lowercased() })
        XCTAssertFalse(headerNames.contains("authorization"))
        XCTAssertFalse(headerNames.contains("cookie"))
        XCTAssertFalse(headerNames.contains("chatgpt-account-id"))
    }

    func testNullActiveWatchAndNullChanceReturnNoWatch() async {
        let deadline = Self.start.addingTimeInterval(3_600)
        let bodies = [
            Data(#"{"data":{"active_watch":null}}"#.utf8),
            Data("""
            {"data":{"active_watch":{"reset_chance_percent":null,
            "expires_at":"\(OpenUsageISO8601.string(from: deadline))"}}}
            """.utf8)
        ]

        for body in bodies {
            let http = ResetWatchHTTPClient([
                .init(response: Self.response(body: body))
            ])
            let clock = ResetWatchClock(Self.start)
            let store = CodexResetWatchStore(http: http, now: clock.read)

            let watch = await store.current()
            let requestCount = await http.requestCount()
            XCTAssertNil(watch)
            XCTAssertEqual(requestCount, 1)
        }
    }

    func testMalformedRangeInvalidDateAndExpiredPayloadsReturnNoWatch() async {
        let future = Self.start.addingTimeInterval(3_600)
        let expired = Self.start.addingTimeInterval(-1)
        let cases: [(String, Data)] = [
            ("invalid JSON", Data("not json".utf8)),
            ("missing active_watch", Data(#"{"data":{}}"#.utf8)),
            ("negative chance", Self.activeBody(chanceJSON: "-1", deadline: future)),
            ("chance above 100", Self.activeBody(chanceJSON: "101", deadline: future)),
            ("invalid deadline", Self.activeBody(chanceJSON: "75", deadlineJSON: "not-a-date")),
            ("expired deadline", Self.activeBody(chanceJSON: "75", deadline: expired))
        ]

        for (name, body) in cases {
            let http = ResetWatchHTTPClient([
                .init(response: Self.response(body: body))
            ])
            let clock = ResetWatchClock(Self.start)
            let store = CodexResetWatchStore(http: http, now: clock.read)

            let watch = await store.current()
            let requestCount = await http.requestCount()
            XCTAssertNil(watch, name)
            XCTAssertEqual(requestCount, 1, name)
        }
    }

    func testFreshCacheSkipsNetwork() async throws {
        let deadline = Self.start.addingTimeInterval(3_600)
        let http = ResetWatchHTTPClient([
            .init(response: Self.activeResponse(
                chance: 75,
                deadline: deadline,
                headers: ["cache-control": "public, max-age=30, stale-while-revalidate=300"]
            )),
            .init(response: HTTPResponse(statusCode: 500, headers: [:], body: Data()))
        ])
        let clock = ResetWatchClock(Self.start)
        let store = CodexResetWatchStore(http: http, now: clock.read)

        let initial = await store.current()
        _ = try XCTUnwrap(initial)
        clock.advance(by: 29)
        let cachedResult = await store.current()
        let cached = try XCTUnwrap(cachedResult)

        XCTAssertEqual(cached.chancePercent, 75)
        let requestCount = await http.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testSuccessfulResponseWithoutCacheLifetimeReturnsWatchForCurrentRead() async throws {
        let deadline = Self.start.addingTimeInterval(3_600)
        let http = ResetWatchHTTPClient([
            .init(response: Self.activeResponse(
                chance: 75,
                deadline: deadline,
                headers: ["cache-control": "max-age=0, stale-while-revalidate=0"]
            )),
            .init(response: Self.activeResponse(chance: 80, deadline: deadline))
        ])
        let clock = ResetWatchClock(Self.start)
        let store = CodexResetWatchStore(http: http, now: clock.read)

        let current = await store.current()
        let watch = try XCTUnwrap(current)

        XCTAssertEqual(watch.chancePercent, 75)
        XCTAssertEqual(watch.deadline, deadline)
        let nextResult = await store.current()
        let next = try XCTUnwrap(nextResult)
        XCTAssertEqual(next.chancePercent, 80, "a zero-lifetime response must not suppress revalidation")
        let requestCount = await http.requestCount()
        XCTAssertEqual(requestCount, 2)
    }

    func testExpiredFreshCacheIsRevalidatedWithETagAnd304KeepsWatch() async throws {
        let deadline = Self.start.addingTimeInterval(3_600)
        let http = ResetWatchHTTPClient([
            .init(response: Self.activeResponse(
                chance: 75,
                deadline: deadline,
                headers: [
                    "cache-control": "max-age=1, stale-while-revalidate=300",
                    "etag": "\"reset-v1\""
                ]
            )),
            .init(response: HTTPResponse(
                statusCode: 304,
                headers: ["cache-control": "max-age=30, stale-while-revalidate=300"],
                body: Data()
            ))
        ])
        let clock = ResetWatchClock(Self.start)
        let store = CodexResetWatchStore(http: http, now: clock.read)

        let initial = await store.current()
        _ = try XCTUnwrap(initial)
        clock.advance(by: 2)
        let revalidatedResult = await store.current()
        let revalidated = try XCTUnwrap(revalidatedResult)

        XCTAssertEqual(revalidated.chancePercent, 75)
        let requests = await http.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertNil(requests[0].headers["If-None-Match"])
        XCTAssertEqual(requests[1].headers["If-None-Match"], "\"reset-v1\"")

        clock.advance(by: 29)
        let cached = await store.current()
        _ = try XCTUnwrap(cached)
        let requestCount = await http.requestCount()
        XCTAssertEqual(requestCount, 2, "304 freshness should suppress another request")
    }

    func testRateLimitAndServiceFailureServeStaleWatchAndHonorBackoff() async throws {
        let deadline = Self.start.addingTimeInterval(3_600)
        let http = ResetWatchHTTPClient([
            .init(response: Self.activeResponse(
                chance: 75,
                deadline: deadline,
                headers: ["cache-control": "max-age=1, stale-while-revalidate=300"]
            )),
            .init(response: HTTPResponse(
                statusCode: 429,
                headers: ["retry-after": "10"],
                body: Data()
            )),
            .init(response: HTTPResponse(statusCode: 503, headers: [:], body: Data())),
            .init(response: Self.activeResponse(chance: 80, deadline: deadline))
        ])
        let clock = ResetWatchClock(Self.start)
        let store = CodexResetWatchStore(http: http, now: clock.read)

        let initial = await store.current()
        _ = try XCTUnwrap(initial)
        clock.advance(by: 2)
        let afterRateLimitResult = await store.current()
        let afterRateLimit = try XCTUnwrap(afterRateLimitResult)
        let rateLimitedRequestCount = await http.requestCount()
        XCTAssertEqual(afterRateLimit.chancePercent, 75)
        XCTAssertEqual(rateLimitedRequestCount, 2)

        clock.advance(by: 9)
        let beforeRetryResult = await store.current()
        let beforeRetry = try XCTUnwrap(beforeRetryResult)
        let beforeRetryRequestCount = await http.requestCount()
        XCTAssertEqual(beforeRetry.chancePercent, 75)
        XCTAssertEqual(beforeRetryRequestCount, 2, "Retry-After should block an early retry")

        clock.advance(by: 2)
        let afterServiceFailureResult = await store.current()
        let afterServiceFailure = try XCTUnwrap(afterServiceFailureResult)
        let serviceFailureRequestCount = await http.requestCount()
        XCTAssertEqual(afterServiceFailure.chancePercent, 75)
        XCTAssertEqual(serviceFailureRequestCount, 3, "request resumes after Retry-After")

        clock.advance(by: 59)
        let beforeFailureRetryResult = await store.current()
        let beforeFailureRetry = try XCTUnwrap(beforeFailureRetryResult)
        let beforeFailureRetryRequestCount = await http.requestCount()
        XCTAssertEqual(beforeFailureRetry.chancePercent, 75)
        XCTAssertEqual(beforeFailureRetryRequestCount, 3, "503 should apply the failure cooldown")

        clock.advance(by: 2)
        let recoveredResult = await store.current()
        let recovered = try XCTUnwrap(recoveredResult)
        let recoveredRequestCount = await http.requestCount()
        XCTAssertEqual(recovered.chancePercent, 80)
        XCTAssertEqual(recoveredRequestCount, 4)
    }

    @MainActor
    func testFailureAtCoordinatorCadenceKeepsWatchUntilForecastDeadline() async throws {
        let deadline = Self.start.addingTimeInterval(3_600)
        let http = ResetWatchHTTPClient([
            .init(response: Self.activeResponse(
                chance: 75,
                deadline: deadline,
                headers: ["cache-control": "max-age=300, stale-while-revalidate=300"]
            )),
            .init(response: HTTPResponse(statusCode: 503, headers: [:], body: Data())),
            .init(response: HTTPResponse(statusCode: 503, headers: [:], body: Data())),
            .init(response: HTTPResponse(statusCode: 503, headers: [:], body: Data()))
        ])
        let clock = ResetWatchClock(Self.start)
        let store = CodexResetWatchStore(http: http, now: clock.read)

        let initial = await store.current()
        _ = try XCTUnwrap(initial)
        clock.advance(by: CodexResetWatchCoordinator.refreshInterval)
        let afterFailureResult = await store.current()
        let afterFailure = try XCTUnwrap(afterFailureResult)

        XCTAssertEqual(afterFailure.chancePercent, 75)
        XCTAssertEqual(afterFailure.deadline, deadline)

        clock.advance(by: 30)
        let duringCooldownResult = await store.current()
        let duringCooldown = try XCTUnwrap(duringCooldownResult)
        XCTAssertEqual(duringCooldown.chancePercent, 75)
        let cooldownRequestCount = await http.requestCount()
        XCTAssertEqual(cooldownRequestCount, 2)

        clock.advance(by: 870)
        let afterRepeatedFailureResult = await store.current()
        let afterRepeatedFailure = try XCTUnwrap(afterRepeatedFailureResult)
        XCTAssertEqual(afterRepeatedFailure.chancePercent, 75)

        clock.advance(by: 1_799)
        let beforeDeadlineResult = await store.current()
        let beforeDeadline = try XCTUnwrap(beforeDeadlineResult)
        XCTAssertEqual(beforeDeadline.chancePercent, 75)

        clock.advance(by: 1)
        let atDeadline = await store.current()
        XCTAssertNil(atDeadline)
        let requestCount = await http.requestCount()
        XCTAssertEqual(requestCount, 4)
    }

    @MainActor
    func testZeroRetryAfterKeepsWatchForRateLimitedRead() async throws {
        let deadline = Self.start.addingTimeInterval(3_600)
        let http = ResetWatchHTTPClient([
            .init(response: Self.activeResponse(
                chance: 75,
                deadline: deadline,
                headers: ["cache-control": "max-age=300, stale-while-revalidate=300"]
            )),
            .init(response: HTTPResponse(
                statusCode: 429,
                headers: ["retry-after": "0"],
                body: Data()
            ))
        ])
        let clock = ResetWatchClock(Self.start)
        let store = CodexResetWatchStore(http: http, now: clock.read)

        let initial = await store.current()
        _ = try XCTUnwrap(initial)
        clock.advance(by: CodexResetWatchCoordinator.refreshInterval)
        let rateLimitedResult = await store.current()
        let rateLimited = try XCTUnwrap(rateLimitedResult)

        XCTAssertEqual(rateLimited.chancePercent, 75)
        let requestCount = await http.requestCount()
        XCTAssertEqual(requestCount, 2)
    }

    func testNonFiniteAndOversizedRetryAfterUseBoundedBackoff() async throws {
        for retryAfter in ["inf", "999999"] {
            let deadline = Self.start.addingTimeInterval(3_600)
            let http = ResetWatchHTTPClient([
                .init(response: Self.activeResponse(
                    chance: 75,
                    deadline: deadline,
                    headers: ["cache-control": "max-age=1, stale-while-revalidate=300"]
                )),
                .init(response: HTTPResponse(
                    statusCode: 429,
                    headers: ["retry-after": retryAfter],
                    body: Data()
                )),
                .init(response: Self.activeResponse(chance: 80, deadline: deadline))
            ])
            let clock = ResetWatchClock(Self.start)
            let store = CodexResetWatchStore(http: http, now: clock.read)

            let initialResult = await store.current()
            _ = try XCTUnwrap(initialResult)
            clock.advance(by: 2)
            let rateLimitedResult = await store.current()
            _ = try XCTUnwrap(rateLimitedResult)
            clock.advance(by: 298)
            let beforeRetryResult = await store.current()
            _ = try XCTUnwrap(beforeRetryResult)
            let beforeRetryCount = await http.requestCount()
            XCTAssertEqual(beforeRetryCount, 2, retryAfter)

            clock.advance(by: 3)
            let recoveredResult = await store.current()
            let recovered = try XCTUnwrap(recoveredResult)
            let recoveredCount = await http.requestCount()
            XCTAssertEqual(recovered.chancePercent, 80, retryAfter)
            XCTAssertEqual(recoveredCount, 3, retryAfter)
        }
    }

    func testConcurrentReadsShareSingleFlight() async throws {
        let deadline = Self.start.addingTimeInterval(3_600)
        let http = ResetWatchHTTPClient([
            .init(
                response: Self.activeResponse(chance: 75, deadline: deadline),
                delayNanoseconds: 100_000_000
            )
        ])
        let clock = ResetWatchClock(Self.start)
        let store = CodexResetWatchStore(http: http, now: clock.read)

        let watches = await withTaskGroup(of: CodexResetWatch?.self, returning: [CodexResetWatch?].self) { group in
            for _ in 0..<24 {
                group.addTask { await store.current() }
            }
            var results: [CodexResetWatch?] = []
            for await watch in group {
                results.append(watch)
            }
            return results
        }

        XCTAssertEqual(watches.count, 24)
        XCTAssertTrue(watches.allSatisfy { $0?.chancePercent == 75 })
        let requestCount = await http.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testNoStoreDoesNotRetainForecastOrETag() async {
        let http = ResetWatchHTTPClient([
            .init(response: Self.activeResponse(chance: 75, deadline: Self.start.addingTimeInterval(3_600),
                headers: ["cache-control": "no-store, max-age=300", "etag": "private"])),
            .init(response: HTTPResponse(statusCode: 503, headers: [:], body: Data()))
        ])
        let store = CodexResetWatchStore(http: http, now: { Self.start })
        let initial = await store.current()
        let failed = await store.current()
        let requests = await http.recordedRequests()
        XCTAssertNotNil(initial)
        XCTAssertNil(failed)
        XCTAssertEqual(requests.count, 2)
        XCTAssertNil(requests.last?.headers["If-None-Match"])
    }

    func testNoCacheRequiresValidationAndDoesNotServeFailedCache() async {
        let http = ResetWatchHTTPClient([
            .init(response: Self.activeResponse(chance: 75, deadline: Self.start.addingTimeInterval(3_600),
                headers: ["cache-control": "no-cache, max-age=300", "etag": "validate"])),
            .init(response: HTTPResponse(statusCode: 304, headers: [:], body: Data())),
            .init(response: HTTPResponse(statusCode: 503, headers: [:], body: Data()))
        ])
        let store = CodexResetWatchStore(http: http, now: { Self.start })
        let initial = await store.current()
        let revalidated = await store.current()
        let failed = await store.current()
        let requests = await http.recordedRequests()
        XCTAssertNotNil(initial)
        XCTAssertNotNil(revalidated)
        XCTAssertNil(failed)
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests.last?.headers["If-None-Match"], "validate")
    }

    private static func activeResponse(
        chance: Int,
        deadline: Date,
        headers: [String: String] = ["cache-control": "max-age=30, stale-while-revalidate=300"]
    ) -> HTTPResponse {
        response(body: activeBody(chanceJSON: String(chance), deadline: deadline), headers: headers)
    }

    private static func activeBody(chanceJSON: String, deadline: Date) -> Data {
        activeBody(chanceJSON: chanceJSON, deadlineJSON: OpenUsageISO8601.string(from: deadline))
    }

    private static func activeBody(chanceJSON: String, deadlineJSON: String) -> Data {
        Data("""
        {"data":{"active_watch":{"reset_chance_percent":\(chanceJSON),
        "expires_at":"\(deadlineJSON)"}}}
        """.utf8)
    }

    private static func response(
        body: Data,
        headers: [String: String] = ["cache-control": "max-age=30, stale-while-revalidate=300"]
    ) -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: headers, body: body)
    }
}

private final class ResetWatchClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Date

    init(_ instant: Date) {
        self.instant = instant
    }

    func read() -> Date {
        lock.withLock { instant }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { instant.addTimeInterval(interval) }
    }
}

private actor ResetWatchHTTPClient: HTTPClient {
    struct Stub: Sendable {
        let response: HTTPResponse
        let delayNanoseconds: UInt64

        init(response: HTTPResponse, delayNanoseconds: UInt64 = 0) {
            self.response = response
            self.delayNanoseconds = delayNanoseconds
        }
    }

    private var stubs: [Stub]
    private var requests: [HTTPRequest] = []

    init(_ stubs: [Stub]) {
        self.stubs = stubs
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !stubs.isEmpty else { throw ResetWatchHTTPClientError.unscriptedRequest }
        let stub = stubs.removeFirst()
        if stub.delayNanoseconds > 0 {
            try await Task<Never, Never>.sleep(nanoseconds: stub.delayNanoseconds)
        }
        return stub.response
    }

    func recordedRequests() -> [HTTPRequest] {
        requests
    }

    func requestCount() -> Int {
        requests.count
    }
}

private enum ResetWatchHTTPClientError: Error {
    case unscriptedRequest
}
