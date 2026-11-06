import Foundation
import XCTest
@testable import OpenUsage

final class JSONLScannerCancellationTests: XCTestCase {
    func testCancelledQueuedScanReturnsNilAndNeverInvokesItsParser() async throws {
        let base = try makeDirectory("Queue")
        defer { try? FileManager.default.removeItem(at: base) }
        let file = try makeIntegerFile(in: base)
        let scanner = IncrementalJSONLScanner<Int>()
        let blockingParser = BlockingParser()
        let firstTask = Task {
            await scanner.items(
                from: [file], since: .distantPast, cacheIdentity: "shared-home", parse: blockingParser.parse
            )
        }
        guard await waitUntil({ blockingParser.hasStarted }) else {
            blockingParser.unblock()
            firstTask.cancel()
            _ = await firstTask.value
            return XCTFail("the first parser did not start before the timeout")
        }

        let queuedParser = ParseCounter()
        let queuedTask = Task {
            await scanner.items(
                from: [file], since: .distantPast, cacheIdentity: "shared-home", parse: queuedParser.parse
            )
        }
        guard await waitUntil({ await scanner.queuedScanCountForTesting(identity: "shared-home") > 0 }) else {
            queuedTask.cancel()
            blockingParser.unblock()
            _ = await firstTask.value
            _ = await queuedTask.value
            return XCTFail("the second scan did not queue before the timeout")
        }
        queuedTask.cancel()
        blockingParser.unblock()

        let firstResult = await firstTask.value
        let queuedResult = await queuedTask.value
        XCTAssertEqual(firstResult, [7])
        XCTAssertNil(queuedResult)
        XCTAssertEqual(queuedParser.count, 0)
    }

    func testCancelledClaudeScanIsNotAnAuthoritativeEmptyHistory() async throws {
        let now = Date()
        let home = try ClaudeLogFixture.makeHome(files: [
            "project/session.jsonl": ClaudeLogFixture.usageLine(
                timestamp: OpenUsageISO8601.string(from: now),
                input: 10,
                output: 5,
                costUSD: 0.25
            )
        ])
        defer { try? FileManager.default.removeItem(at: home) }
        let file = try XCTUnwrap(JSONLScanning.jsonlFiles(under: home.appendingPathComponent("projects")).first)
        let incremental = IncrementalJSONLScanner<ClaudeLogUsageScanner.Entry>()
        let blockingParser = BlockingClaudeParser()
        let firstTask = Task {
            await incremental.items(
                from: [file],
                since: .distantPast,
                cacheIdentity: "shared-home",
                parse: blockingParser.parse
            )
        }
        guard await waitUntil({ blockingParser.hasStarted }) else {
            blockingParser.unblock()
            firstTask.cancel()
            _ = await firstTask.value
            return XCTFail("the first parser did not start before the timeout")
        }

        let scanner = ClaudeLogUsageScanner(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": home.path]),
            homeDirectory: { home },
            incrementalScanner: incremental,
            cacheIdentityOverride: "shared-home"
        )
        let cancelledTask = Task {
            await scanner.scan(now: now, pricing: TestPricing.bundled)
        }
        guard await waitUntil({ await incremental.queuedScanCountForTesting(identity: "shared-home") > 0 }) else {
            cancelledTask.cancel()
            blockingParser.unblock()
            _ = await firstTask.value
            _ = await cancelledTask.value
            return XCTFail("the Claude scan did not queue before the timeout")
        }
        cancelledTask.cancel()
        blockingParser.unblock()

        _ = await firstTask.value
        let cancelledResult = await cancelledTask.value
        XCTAssertNil(cancelledResult)
    }

    func testCancelledScanRetainsCompletedFilesForRetryAndRelaunch() async throws {
        let base = try makeDirectory("CompletedFiles")
        defer { try? FileManager.default.removeItem(at: base) }
        let files = try [1, 2, 3].map { try makeIntegerFile(named: "\($0).jsonl", value: $0, in: base) }
        let persistence = JSONLScanCachePersistence(
            namespace: "test", schemaVersion: 1, directory: base.appendingPathComponent("cache"),
            writeDebounce: .milliseconds(1)
        )
        let scanner = IncrementalJSONLScanner<Int>(persistence: persistence)
        let blockingParser = BlockingParser()
        let completedParser = ParseCounter()
        let task = Task {
            await scanner.items(from: files, since: .distantPast) { data in
                if data == Data("2".utf8) { return blockingParser.parse(data) }
                return completedParser.parse(data)
            }
        }
        guard await waitUntil({ blockingParser.hasStarted }) else {
            blockingParser.unblock()
            task.cancel()
            _ = await task.value
            return XCTFail("the second parser did not start before the timeout")
        }
        task.cancel()
        blockingParser.unblock()
        let cancelled = await task.value
        XCTAssertNil(cancelled, "partial totals must not reach the provider")
        XCTAssertEqual(completedParser.count, 1, "the third file must wait for the next scan")
        await scanner.waitForPendingWritesForTesting()

        let reloaded = IncrementalJSONLScanner<Int>(persistence: persistence)
        for instance in [reloaded, scanner] {
            let counter = ParseCounter()
            let values = await instance.items(from: files, since: .distantPast, parse: counter.parse)
            XCTAssertEqual(values, [1, 2, 3])
            XCTAssertEqual(counter.count, 2, "the first completed file must survive cancellation")
            await instance.waitForPendingWritesForTesting()
        }
    }

    func testCancelledScanClearsReadFailureForCompletedFileBeforeCacheReuse() async throws {
        let base = try makeDirectory("ReadFailureRecovery")
        defer { try? FileManager.default.removeItem(at: base) }
        let recoveredURL = base.appendingPathComponent("first.jsonl")
        try FileManager.default.createDirectory(at: recoveredURL, withIntermediateDirectories: true)
        let unreadable = JSONLScanning.DiscoveredFile(path: recoveredURL.path, size: 0, mtime: Date())
        let diagnostics = DiagnosticEventRecorder()
        let scanner = IncrementalJSONLScanner<Int>(logTag: "plugin:codex")
        let counter = ParseCounter()
        _ = await scanner.items(from: [unreadable], since: .distantPast, parse: counter.parse)
        XCTAssertEqual(diagnostics.events, [
            DiagnosticEvent(.historyScan, result: .degraded, category: .storage, providerID: "codex")
        ])

        try FileManager.default.removeItem(at: recoveredURL)
        let recovered = try makeIntegerFile(named: "first.jsonl", value: 1, in: base)
        let second = try makeIntegerFile(named: "second.jsonl", value: 2, in: base)
        let blocker = BlockingParser()
        let task = Task {
            await scanner.items(from: [recovered, second], since: .distantPast) { data in
                if data == Data("2".utf8) { return blocker.parse(data) }
                return counter.parse(data)
            }
        }
        guard await waitUntil({ blocker.hasStarted }) else {
            task.cancel()
            blocker.unblock()
            _ = await task.value
            return XCTFail("the second parser did not start before the timeout")
        }
        task.cancel()
        blocker.unblock()
        let cancelled = await task.value
        XCTAssertNil(cancelled)
        XCTAssertEqual(diagnostics.events, [
            DiagnosticEvent(.historyScan, result: .degraded, category: .storage, providerID: "codex"),
            DiagnosticEvent(.historyScan, result: .success, providerID: "codex")
        ])
        let retry = await scanner.items(from: [recovered], since: .distantPast, parse: counter.parse)
        XCTAssertEqual(retry, [1])
        XCTAssertEqual(counter.count, 1, "the recovered file must be served from the cancellation cache")

        try FileManager.default.removeItem(at: recoveredURL)
        try FileManager.default.createDirectory(at: recoveredURL, withIntermediateDirectories: true)
        var failedAgain = recovered
        failedAgain.mtime.addTimeInterval(1)
        _ = await scanner.items(from: [failedAgain], since: .distantPast, parse: counter.parse)
        XCTAssertEqual(diagnostics.events, [
            DiagnosticEvent(.historyScan, result: .degraded, category: .storage, providerID: "codex"),
            DiagnosticEvent(.historyScan, result: .success, providerID: "codex"),
            DiagnosticEvent(.historyScan, result: .degraded, category: .storage, providerID: "codex")
        ])
    }

    func testCancellationDuringParseReturnsNilWithoutPersistingPartialCache() async throws {
        let base = try makeDirectory("ActiveParse")
        defer { try? FileManager.default.removeItem(at: base) }
        let first = try makeIntegerFile(named: "first.jsonl", value: 1, in: base)
        let second = try makeIntegerFile(named: "second.jsonl", value: 2, in: base)
        let persistence = JSONLScanCachePersistence(
            namespace: "test",
            schemaVersion: 1,
            directory: base.appendingPathComponent("cache"),
            writeDebounce: .milliseconds(1)
        )
        let scanner = IncrementalJSONLScanner<Int>(maxConcurrentParses: 1, persistence: persistence)
        let blockingParser = BlockingParser()
        let task = Task {
            await scanner.items(
                from: [first, second],
                since: .distantPast,
                cacheIdentity: "home",
                parse: blockingParser.parse
            )
        }
        guard await waitUntil({ blockingParser.hasStarted }) else {
            blockingParser.unblock()
            task.cancel()
            _ = await task.value
            return XCTFail("the parser did not start before the timeout")
        }
        task.cancel()
        blockingParser.unblock()

        let cancelledResult = await task.value
        XCTAssertNil(cancelledResult)
        await scanner.waitForPendingWritesForTesting()

        let reloadCounter = ParseCounter()
        let reloaded = IncrementalJSONLScanner<Int>(persistence: persistence)
        let reloadedItems = await reloaded.items(
            from: [first, second],
            since: .distantPast,
            cacheIdentity: "home",
            parse: reloadCounter.parse
        )
        XCTAssertEqual(reloadedItems, [1, 2])
        XCTAssertEqual(reloadCounter.count, 2)
    }

    func testCancelledCodexDiscoveryFailureDoesNotReturnWarningScan() async throws {
        let home = try makeDirectory("CodexDiscovery")
        defer { try? FileManager.default.removeItem(at: home) }
        let sessions = home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: sessions.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sessions.path) }
        try XCTSkipIf(FileManager.default.isReadableFile(atPath: sessions.path), "Requires an unreadable directory")
        let incremental = IncrementalJSONLScanner<CodexLogUsageScanner.Event>()
        let scanner = CodexLogUsageScanner(incrementalScanner: incremental,
                                            cacheIdentityOverride: "shared-home", rootsOverride: [home])
        let failed = await scanner.scan(pricing: .empty)
        XCTAssertEqual(failed?.readFailureCount, 1)
        let blockerFile = try makeIntegerFile(in: home)
        let blocker = BlockingCodexParser()
        let first = Task { await incremental.items(from: [blockerFile], since: .distantPast,
                                                    cacheIdentity: "shared-home", parse: blocker.parse) }
        guard await waitUntil({ blocker.hasStarted }) else {
            blocker.unblock(); first.cancel(); _ = await first.value
            return XCTFail("the first parser did not start")
        }
        let cancelled = Task { await scanner.scan(pricing: .empty) }
        guard await waitUntil({ await incremental.queuedScanCountForTesting(identity: "shared-home") > 0 }) else {
            cancelled.cancel(); blocker.unblock(); _ = await first.value; _ = await cancelled.value
            return XCTFail("the Codex scan did not queue")
        }
        cancelled.cancel()
        blocker.unblock()
        _ = await first.value
        let result = await cancelled.value
        XCTAssertNil(result)
    }

    private func waitUntil(
        _ condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return await condition()
    }

    private func makeDirectory(_ suffix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageScannerCancellation\(suffix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeIntegerFile(
        named name: String = "usage.jsonl",
        value: Int = 7,
        in directory: URL
    ) throws -> JSONLScanning.DiscoveredFile {
        let url = directory.appendingPathComponent(name)
        try Data(String(value).utf8).write(to: url)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return JSONLScanning.DiscoveredFile(
            path: url.path,
            size: try XCTUnwrap(values.fileSize),
            mtime: try XCTUnwrap(values.contentModificationDate)
        )
    }
}

private final class BlockingClaudeParser: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private let release = DispatchSemaphore(value: 0)

    var hasStarted: Bool {
        lock.withLock { started }
    }

    func parse(_ data: Data) -> [ClaudeLogUsageScanner.Entry]? {
        lock.withLock { started = true }
        release.wait()
        return ClaudeLogUsageScanner.parseFile(data)
    }

    func unblock() {
        release.signal()
    }
}

private final class BlockingCodexParser: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private let release = DispatchSemaphore(value: 0)
    var hasStarted: Bool { lock.withLock { started } }
    func parse(_ data: Data) -> [CodexLogUsageScanner.Event]? {
        lock.withLock { started = true }
        release.wait()
        return []
    }
    func unblock() { release.signal() }
}
