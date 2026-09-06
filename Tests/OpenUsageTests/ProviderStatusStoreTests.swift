import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class ProviderStatusStoreTests: XCTestCase {
    func testAccountAliasesShareOneFamilyRequestAndStatus() async {
        let checkedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let http = ProviderStatusHTTPStub(responses: [
            .success(Self.claudeResponse(status: "partial_outage")),
        ])
        let store = ProviderStatusStore(http: http, now: { checkedAt })

        await store.refresh(providerIDs: ["claude", "claude@work", "claude@personal"])

        let requestCount = await http.requestCount()
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(store.status(for: "claude"), store.status(for: "claude@work"))
        XCTAssertEqual(
            store.status(for: "claude@personal"),
            .disrupted(ProviderServiceIssue(
                severity: .partial,
                componentName: "Claude API (api.anthropic.com)",
                checkedAt: checkedAt
            ))
        )
    }

    func testSuccessTTLSkipsAutomaticRefreshButForceBypassesIt() async {
        let clock = ProviderStatusTestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let http = ProviderStatusHTTPStub(responses: [
            .success(Self.claudeResponse(status: "operational")),
            .success(Self.claudeResponse(status: "partial_outage")),
        ])
        let store = ProviderStatusStore(http: http, now: { clock.value })

        await store.refresh(providerIDs: ["claude"])
        clock.value.addTimeInterval(ProviderStatusStore.successTTL - 1)
        await store.refresh(providerIDs: ["claude"])
        let automaticCount = await http.requestCount()

        await store.refresh(providerIDs: ["claude"], force: true)
        let forcedCount = await http.requestCount()

        XCTAssertEqual(automaticCount, 1)
        XCTAssertEqual(forcedCount, 2)
        XCTAssertNotNil(store.status(for: "claude").issue)
    }

    func testProviderEnablementClearsOnlyOrdinaryFailureGate() async {
        let clock = ProviderStatusTestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let http = ProviderStatusHTTPStub(responses: [
            .failure(ProviderStatusHTTPStub.StubError.transport),
            .success(Self.claudeResponse(status: "operational")),
        ])
        let store = ProviderStatusStore(http: http, now: { clock.value })

        await store.refresh(providerIDs: ["claude"])
        clock.value.addTimeInterval(1)
        await store.refresh(providerIDs: ["claude"])
        let backedOffCount = await http.requestCount()

        store.providerEnabled("claude@work")
        await store.refresh(providerIDs: ["claude@work"])
        let retriedCount = await http.requestCount()

        XCTAssertEqual(backedOffCount, 1)
        XCTAssertEqual(retriedCount, 2)
        XCTAssertEqual(store.status(for: "claude"), .operational)
    }

    func testCancellationDoesNotCreateFailureBackoff() async {
        let http = ProviderStatusHTTPStub(responses: [
            .failure(CancellationError()),
            .success(Self.claudeResponse(status: "operational")),
        ])
        let store = ProviderStatusStore(http: http)

        await store.refresh(providerIDs: ["claude"])
        await store.refresh(providerIDs: ["claude"])

        let requestCount = await http.requestCount()
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(store.status(for: "claude"), .operational)
    }

    func testAlreadyCancelledRefreshDoesNotStartARequest() async {
        let http = ProviderStatusHTTPStub(responses: [.success(Self.claudeResponse(status: "operational"))])
        let store = ProviderStatusStore(http: http)
        let refresh = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await store.refresh(providerIDs: ["claude"], force: true)
        }
        await refresh.value
        let count = await http.requestCount()
        XCTAssertEqual(count, 0)
        XCTAssertEqual(store.status(for: "claude"), .unknown)
    }

    func testRetryAfterBlocksForceAndSurvivesProviderEnablement() async {
        let clock = ProviderStatusTestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let http = ProviderStatusHTTPStub(responses: [
            .success(HTTPResponse(statusCode: 429, headers: ["retry-after": "120"], body: Data())),
            .success(Self.claudeResponse(status: "operational")),
        ])
        let store = ProviderStatusStore(http: http, now: { clock.value })

        await store.refresh(providerIDs: ["claude"])
        clock.value.addTimeInterval(60)
        store.providerEnabled("claude")
        await store.refresh(providerIDs: ["claude"], force: true)
        let blockedCount = await http.requestCount()

        clock.value.addTimeInterval(61)
        await store.refresh(providerIDs: ["claude"], force: true)
        let retriedCount = await http.requestCount()

        XCTAssertEqual(blockedCount, 1)
        XCTAssertEqual(retriedCount, 2)
    }

    func testHTTPDateRetryAfterIsClampedToOneHour() async {
        let clock = ProviderStatusTestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let http = ProviderStatusHTTPStub(responses: [
            .success(HTTPResponse(
                statusCode: 429,
                headers: ["retry-after": "Fri, 15 Jan 2027 10:00:00 GMT"],
                body: Data()
            )),
            .success(Self.claudeResponse(status: "operational")),
        ])
        let store = ProviderStatusStore(http: http, now: { clock.value })

        await store.refresh(providerIDs: ["claude"])
        clock.value.addTimeInterval(ProviderStatusStore.maximumRetryAfter - 1)
        await store.refresh(providerIDs: ["claude"], force: true)
        let blockedCount = await http.requestCount()

        clock.value.addTimeInterval(2)
        await store.refresh(providerIDs: ["claude"], force: true)
        let retriedCount = await http.requestCount()

        XCTAssertEqual(blockedCount, 1)
        XCTAssertEqual(retriedCount, 2)
    }

    func testRetryAfterOnNonRateLimitFailureDoesNotBlockForceRefresh() async {
        let http = ProviderStatusHTTPStub(responses: [
            .success(HTTPResponse(statusCode: 503, headers: ["retry-after": "3600"], body: Data())),
            .success(Self.claudeResponse(status: "operational")),
        ])
        let store = ProviderStatusStore(http: http)

        await store.refresh(providerIDs: ["claude"])
        await store.refresh(providerIDs: ["claude"], force: true)

        let requestCount = await http.requestCount()
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(store.status(for: "claude"), .operational)
    }

    func testFailureKeepsRecentIssueButExpiresItAtStaleBoundary() async {
        let clock = ProviderStatusTestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let http = ProviderStatusHTTPStub(responses: [
            .success(Self.claudeResponse(status: "partial_outage")),
            .failure(ProviderStatusHTTPStub.StubError.transport),
            .failure(ProviderStatusHTTPStub.StubError.transport),
        ])
        let store = ProviderStatusStore(http: http, now: { clock.value })

        await store.refresh(providerIDs: ["claude"])
        clock.value.addTimeInterval(ProviderStatusStore.successTTL + 1)
        await store.refresh(providerIDs: ["claude"])
        XCTAssertNotNil(store.status(for: "claude").issue)

        clock.value.addTimeInterval(
            ProviderStatusStore.staleGracePeriod - ProviderStatusStore.successTTL - 1
        )
        await store.refresh(providerIDs: ["claude"])

        XCTAssertEqual(store.status(for: "claude"), .unknown)
        let requestCount = await http.requestCount()
        XCTAssertEqual(requestCount, 3)
    }

    func testFailureCrossingStaleBoundaryKeepsPassStartSnapshotUntilNextRefresh() async {
        let clock = ProviderStatusTestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let http = ProviderStatusStaleBoundaryHTTPStub()
        let store = ProviderStatusStore(http: http, now: { clock.value })

        await store.refresh(providerIDs: ["claude"])
        clock.value.addTimeInterval(ProviderStatusStore.staleGracePeriod - 1)

        let refresh = Task { await store.refresh(providerIDs: ["claude"], force: true) }
        await http.waitForSecondRequest()
        clock.value.addTimeInterval(2)
        await http.releaseFailure()
        await refresh.value

        XCTAssertNotNil(store.status(for: "claude").issue)

        await store.refresh(providerIDs: ["claude"])
        XCTAssertEqual(store.status(for: "claude"), .unknown)
    }

    func testSuccessfulMaintenanceClearsPreviouslyConfirmedIssue() async {
        let clock = ProviderStatusTestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let http = ProviderStatusHTTPStub(responses: [
            .success(Self.claudeResponse(status: "major_outage")),
            .success(Self.claudeResponse(status: "under_maintenance")),
        ])
        let store = ProviderStatusStore(http: http, now: { clock.value })

        await store.refresh(providerIDs: ["claude"])
        XCTAssertNotNil(store.status(for: "claude").issue)

        await store.refresh(providerIDs: ["claude"], force: true)

        XCTAssertEqual(store.status(for: "claude"), .unknown)
    }

    func testUnsupportedFamiliesDoNotMakeRequests() async {
        let http = ProviderStatusHTTPStub(responses: [])
        let store = ProviderStatusStore(http: http)

        await store.refresh(providerIDs: ["grok", "devin", "openrouter"])

        let requestCount = await http.requestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func testDifferentFamiliesStartInParallel() async {
        let http = ProviderStatusGateHTTPStub()
        let store = ProviderStatusStore(http: http)

        let refresh = Task { await store.refresh(providerIDs: ["claude", "cursor"]) }
        await http.waitForRequestCount(2)
        let maximumActive = await http.maximumActiveRequestCount()
        await http.releaseAll()
        await refresh.value

        XCTAssertEqual(maximumActive, 2)
        XCTAssertEqual(store.status(for: "claude"), .operational)
        XCTAssertEqual(store.status(for: "cursor"), .operational)
    }

    func testOverlappingAliasesJoinTheSameFamilyFlight() async {
        let http = ProviderStatusGateHTTPStub()
        let didJoin = expectation(description: "Alias joined shared flight")
        var hasJoined = false
        let store = ProviderStatusStore(http: http, onFlightJoined: { _ in
            hasJoined = true
            didJoin.fulfill()
        })

        let first = Task { await store.refresh(providerIDs: ["claude"]) }
        await http.waitForRequestCount(1)
        let second = Task { await store.refresh(providerIDs: ["claude@work"], force: true) }
        await fulfillment(of: [didJoin], timeout: 2)
        if !hasJoined { second.cancel() }
        await http.releaseAll()
        await first.value
        await second.value

        let requestCount = await http.currentRequestCount()
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(store.status(for: "claude@work"), .operational)
    }

    func testCancellingOneJoinedWaiterDoesNotCancelTheSharedFlight() async {
        let http = ProviderStatusGateHTTPStub()
        let didJoin = expectation(description: "Waiter joined shared flight")
        let store = ProviderStatusStore(http: http, onFlightJoined: { _ in didJoin.fulfill() })

        let first = Task { await store.refresh(providerIDs: ["claude"]) }
        await http.waitForRequestCount(1)
        let joined = Task { await store.refresh(providerIDs: ["claude@work"]) }
        await fulfillment(of: [didJoin], timeout: 2)
        joined.cancel()
        await http.releaseAll()
        await first.value
        await joined.value

        let requestCount = await http.currentRequestCount()
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(store.status(for: "claude"), .operational)
        XCTAssertEqual(store.status(for: "claude@work"), .operational)
    }

    func testOwnerCancellationCancelsTransportAndAllowsAReplacementFlight() async {
        let http = ProviderStatusGateHTTPStub()
        let store = ProviderStatusStore(http: http)
        let first = Task { await store.refresh(providerIDs: ["claude"]) }
        await http.waitForRequestCount(1)

        store.cancelRefreshes()
        let replacement = Task { await store.refresh(providerIDs: ["claude"]) }
        await http.waitForRequestCount(2)
        await http.releaseAll()
        await first.value
        await replacement.value

        let cancelledCount = await http.cancelledRequestCount()
        XCTAssertEqual(cancelledCount, 1)
        XCTAssertEqual(store.status(for: "claude"), .operational)
    }

    private static func claudeResponse(status: String) -> HTTPResponse {
        HTTPResponse(
            statusCode: 200,
            headers: ["content-type": "application/json"],
            body: Data(
                #"{"components":[{"id":"k8w3r06qmzrp","name":"Claude API (api.anthropic.com)","status":"\#(status)"},{"id":"yyzkbfz2thpt","name":"Claude Code","status":"operational"}]}"#.utf8
            )
        )
    }
}

@MainActor
private final class ProviderStatusTestClock {
    var value: Date

    init(_ value: Date) {
        self.value = value
    }
}

private actor ProviderStatusHTTPStub: HTTPClient {
    enum StubError: Error {
        case exhausted
        case transport
    }

    private var responses: [Result<HTTPResponse, Error>]
    private var requests: [HTTPRequest] = []

    init(responses: [Result<HTTPResponse, Error>]) {
        self.responses = responses
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw StubError.exhausted }
        return try responses.removeFirst().get()
    }

    func requestCount() -> Int {
        requests.count
    }
}

private actor ProviderStatusGateHTTPStub: HTTPClient {
    private var activeRequestCount = 0
    private var maximumActive = 0
    private var requestCount = 0
    private var cancelledCount = 0
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
    private var countWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requestCount += 1
        activeRequestCount += 1
        maximumActive = max(maximumActive, activeRequestCount)
        resumeCountWaiters()
        await withCheckedContinuation { continuation in
            releaseContinuations.append(continuation)
        }
        activeRequestCount -= 1
        if Task.isCancelled { cancelledCount += 1 }

        if request.url.host() == "status.cursor.com" {
            return HTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: Data(#"{"components":[{"id":"rflc60xp5jp2","name":"IDE","status":"operational"},{"id":"jh0714rgjgt4","name":"cursor.com","status":"operational"}]}"#.utf8)
            )
        }
        return HTTPResponse(
            statusCode: 200,
            headers: ["content-type": "application/json"],
            body: Data(#"{"components":[{"id":"k8w3r06qmzrp","name":"Claude API (api.anthropic.com)","status":"operational"},{"id":"yyzkbfz2thpt","name":"Claude Code","status":"operational"}]}"#.utf8)
        )
    }

    func waitForRequestCount(_ target: Int) async {
        guard requestCount < target else { return }
        await withCheckedContinuation { continuation in
            countWaiters.append((target, continuation))
        }
    }

    func releaseAll() {
        let continuations = releaseContinuations
        releaseContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func maximumActiveRequestCount() -> Int {
        maximumActive
    }

    func currentRequestCount() -> Int {
        requestCount
    }

    func cancelledRequestCount() -> Int {
        cancelledCount
    }

    private func resumeCountWaiters() {
        var remaining: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in countWaiters {
            if requestCount >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        countWaiters = remaining
    }
}

private actor ProviderStatusStaleBoundaryHTTPStub: HTTPClient {
    private var requestCount = 0
    private var secondRequestWaiters: [CheckedContinuation<Void, Never>] = []
    private var failureContinuation: CheckedContinuation<Void, Never>?

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requestCount += 1
        if requestCount == 1 {
            return HTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: Data(#"{"components":[{"id":"k8w3r06qmzrp","name":"Claude API (api.anthropic.com)","status":"partial_outage"},{"id":"yyzkbfz2thpt","name":"Claude Code","status":"operational"}]}"#.utf8)
            )
        }

        let waiters = secondRequestWaiters
        secondRequestWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            failureContinuation = continuation
        }
        throw ProviderStatusHTTPStub.StubError.transport
    }

    func waitForSecondRequest() async {
        guard requestCount < 2 else { return }
        await withCheckedContinuation { continuation in
            secondRequestWaiters.append(continuation)
        }
    }

    func releaseFailure() {
        failureContinuation?.resume()
        failureContinuation = nil
    }
}
