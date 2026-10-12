import XCTest
@testable import OpenUsage

@MainActor
final class ClaudeUsageStateStoreTests: XCTestCase {
    func testRetryAfterAcceptsSecondsAndHTTPDateAndRejectsInvalidValues() {
        let now = OpenUsageISO8601.date(from: "2026-10-12T00:00:00.000Z")!
        for (value, expected) in [("7200", 7200), ("Mon, 12 Oct 2026 02:00:00 GMT", 7200)] {
            let response = HTTPResponse(statusCode: 429, headers: ["retry-after": value], body: Data())
            XCTAssertEqual(ClaudeUsageMapper.parseRetryAfterSeconds(response, now: now), expected)
        }
        for value in ["", "-1", "invalid", "999999999999999999999999999999"] {
            let response = HTTPResponse(statusCode: 429, headers: ["retry-after": value], body: Data())
            XCTAssertNil(ClaudeUsageMapper.parseRetryAfterSeconds(response, now: now))
        }
    }

    func testRateLimitsEscalateAndOnlySuccessResetsThem() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var record = ClaudeUsageStateStore.Record()
        for interval: TimeInterval in [900, 1800, 3600, 3600] {
            record.rateLimited(now: now, retryAfterSeconds: 1)
            XCTAssertEqual(record.retryAfter, now.addingTimeInterval(interval))
        }
        record.rateLimited(now: now, retryAfterSeconds: 7200)
        XCTAssertEqual(record.retryAfter, now.addingTimeInterval(7200))
        record.failed(.requestFailed(503), at: now.addingTimeInterval(7201))
        XCTAssertEqual(record.consecutiveRateLimits, 3)
        XCTAssertEqual(record.lastFailure, .requestFailed(503))
        record.succeeded(ClaudeMappedUsage(lines: [], quotaObservedAt: now), at: now)
        XCTAssertNil(record.retryAfter)
        XCTAssertNil(record.lastFailure)
        XCTAssertEqual(record.consecutiveRateLimits, 0)
        record.rateLimited(now: now, retryAfterSeconds: nil)
        XCTAssertEqual(record.retryAfter, now.addingTimeInterval(900))
    }

    func testPersistedAccountsAreIsolatedAndFilesContainNoRawIdentity() async throws {
        let store = isolatedClaudeUsageStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let now = Date()
        do {
            let lease = try await store.acquire(accountKey: "private-account|private-org")
            var record = ClaudeUsageStateStore.Record()
            record.succeeded(ClaudeMappedUsage(lines: [], quotaObservedAt: now), at: now)
            record.rateLimited(now: now, retryAfterSeconds: nil)
            try lease.save(record)
        }
        let restarted = ClaudeUsageStateStore(directory: store.directory)
        let restored = try await restarted.acquire(accountKey: "private-account|private-org")
        XCTAssertEqual(try restored.read().retryAfter, now.addingTimeInterval(900))
        XCTAssertEqual(try restored.read().lastGood?.quotaObservedAt, now)
        let other = try await restarted.acquire(accountKey: "other-account")
        XCTAssertNil(try other.read().retryAfter)
        let files = try FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil)
        for file in files {
            XCTAssertFalse(file.lastPathComponent.contains("private"))
            XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("private-account"))
            let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
            XCTAssertEqual(permissions, 0o600)
        }
    }

    func testContendingStoreWaitsForTheSavedResultAndCancellationReleasesDescriptor() async throws {
        let cancelledWaitStarted = expectation(description: "Cancelled waiter reached the lock")
        let successfulWaitStarted = expectation(description: "Successful waiter reached the lock")
        let store = isolatedClaudeUsageStore(onContention: { cancelledWaitStarted.fulfill() })
        defer { try? FileManager.default.removeItem(at: store.directory) }
        var first: ClaudeUsageStateStore.Lease? = try await store.acquire(accountKey: "account")
        let waiting = Task { try await store.acquire(accountKey: "account") }
        await fulfillment(of: [cancelledWaitStarted], timeout: 2)
        waiting.cancel()
        do { _ = try await waiting.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let contendingStore = ClaudeUsageStateStore(directory: store.directory, onContention: { successfulWaitStarted.fulfill() })
        let second = Task { try await contendingStore.acquire(accountKey: "account") }
        await fulfillment(of: [successfulWaitStarted], timeout: 2)
        var record = ClaudeUsageStateStore.Record()
        record.rateLimited(now: Date(), retryAfterSeconds: nil)
        try first?.save(record)
        first = nil
        let acquired = try await second.value
        XCTAssertTrue(acquired.waited)
        XCTAssertEqual(try acquired.read().retryAfter, record.retryAfter)
    }

    func testCorruptRecordAndUnavailableStorageFailLoudly() async throws {
        let store = isolatedClaudeUsageStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let lease = try await store.acquire(accountKey: "account")
        try lease.save(.init())
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: store.directory, includingPropertiesForKeys: nil
        ).first { $0.pathExtension == "json" })
        try Data("broken".utf8).write(to: file)
        XCTAssertThrowsError(try lease.read())
        let unavailable = ClaudeUsageStateStore(directory: file)
        do { _ = try await unavailable.acquire(accountKey: "account"); XCTFail("Expected storage error") }
        catch let error as ClaudeUsageStateStore.StoreError {
            guard case .storageUnavailable = error else { return XCTFail("Unexpected error") }
        }
        try FileManager.default.removeItem(at: store.directory)
        XCTAssertThrowsError(try lease.save(.init()))
    }
}
