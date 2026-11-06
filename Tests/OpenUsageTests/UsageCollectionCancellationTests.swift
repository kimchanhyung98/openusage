import Foundation
import SQLite3
import XCTest
@testable import OpenUsage

final class UsageCollectionCancellationTests: XCTestCase {
    func testCancelledGrokParsingDoesNotPublishMetadataDiagnostics() async {
        let log = #"{"ts":"2026-06-12T09:00:00Z","pid":7,"sid":"unattributed","msg":"shell.turn.inference_done","ctx":{"prompt_tokens":100}}"#
        let diagnostics = DiagnosticEventRecorder()
        let cancelled = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return GrokLogUsageScanner.parse(log, since: .distantPast, pricing: .empty, reportNumericFailures: false)
        }.value
        XCTAssertEqual(cancelled.rejectedMetadataRows, 0)
        XCTAssertTrue(diagnostics.events.isEmpty)
        let completed = GrokLogUsageScanner.parse(log, since: .distantPast, pricing: .empty, reportNumericFailures: false)
        XCTAssertEqual(completed.rejectedMetadataRows, 1)
        XCTAssertEqual(diagnostics.events, [
            DiagnosticEvent(.historyScan, result: .degraded, category: .decoding, providerID: "grok")
        ])
    }

    func testGrokCancellationDuringParsingStopsAtCancelledLine() async {
        let line = #"{"ts":"2026-06-12T09:00:00Z","pid":7,"sid":"unattributed","msg":"shell.turn.inference_done","ctx":{"prompt_tokens":100}}"#
        let log = Array(repeating: line, count: 8).joined(separator: "\n")
        let diagnostics = DiagnosticEventRecorder()
        let cancelled = await Task {
            var visited = 0
            let scan = GrokLogUsageScanner.parse(
                log, since: .distantPast, pricing: .empty, reportNumericFailures: false,
                onLine: {
                    visited += 1
                    if visited == 3 { withUnsafeCurrentTask { $0?.cancel() } }
                }
            )
            return (scan, visited)
        }.value
        XCTAssertEqual(cancelled.1, 3)
        XCTAssertEqual(cancelled.0.rejectedMetadataRows, 2)
        XCTAssertTrue(diagnostics.events.isEmpty)
        let completed = GrokLogUsageScanner.parse(log, since: .distantPast, pricing: .empty, reportNumericFailures: false)
        XCTAssertEqual(completed.rejectedMetadataRows, 8)
        XCTAssertEqual(diagnostics.events, [
            DiagnosticEvent(.historyScan, result: .degraded, category: .decoding, providerID: "grok")
        ])
    }

    func testSQLiteCancellationAfterParsingDiscardsRowsAndDiagnostics() async throws {
        let root = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("usage.db")
        var handle: OpaquePointer?
        guard sqlite3_open(database.path, &handle) == SQLITE_OK else {
            if let handle { sqlite3_close(handle) }
            return XCTFail("could not create test database")
        }
        sqlite3_close(handle)
        let diagnostics = DiagnosticEventRecorder()
        let calls = CollectionCancellationCounter()
        let collector = UsageSQLiteCollector(
            sourceID: "pi", roots: [root], includeFile: { $0.pathExtension == "db" },
            parse: { _, _ in
                calls.increment()
                withUnsafeCurrentTask { $0?.cancel() }
                return [UsageRecord(sourceID: "pi", formatID: "test", kind: "invalid", issues: [.invalidMetadata])]
            }
        )
        let result = await Task { await collector.collect(since: .distantPast) }.value
        XCTAssertNil(result)
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(diagnostics.events.isEmpty)
    }

    func testCancelledEmptySQLiteCollectionReturnsNil() async {
        let collector = UsageSQLiteCollector(sourceID: "pi", roots: [], includeFile: { _ in true }, parse: { _, _ in [] })
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await collector.collect(since: .distantPast)
        }.value
        XCTAssertNil(result)
    }

    func testDiscoveryCancellationStopsEnumerationBeforeParsing() async throws {
        let root = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<10 {
            try Data("{}\n".utf8).write(to: root.appendingPathComponent("\(index).jsonl"))
        }
        let discovered = CollectionCancellationCounter()
        let parsed = CollectionCancellationCounter()
        let collector = UsageFileCollector(
            sourceID: "pi", roots: [root], scanner: IncrementalJSONLScanner(),
            includeFile: { _ in
                discovered.increment()
                withUnsafeCurrentTask { $0?.cancel() }
                return true
            },
            parse: { _, _ in parsed.increment(); return [] }
        )
        let result = await Task { await collector.collect(since: .distantPast) }.value
        XCTAssertNil(result)
        XCTAssertEqual(discovered.count, 1)
        XCTAssertEqual(parsed.count, 0)
    }

    func testCancelledThrowingParserDoesNotPoisonReadFailureReporting() async throws {
        let root = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("usage.jsonl")
        try Data("{}\n".utf8).write(to: path)
        let file = try XCTUnwrap(JSONLScanning.jsonlFiles(under: root).first)
        let scanner = IncrementalJSONLScanner<UsageRecord>(logTag: "plugin:codex")
        let diagnostics = DiagnosticEventRecorder()
        let gate = CollectionCancellationGate()
        let task = Task {
            await scanner.scan(from: [file], since: .distantPast) { data, _ in
                gate.wait()
                return try UsageRecordFixture.piRecords(data)
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !gate.hasStarted, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard gate.hasStarted else {
            task.cancel()
            gate.unblock()
            _ = await task.value
            return XCTFail("parser did not start before timeout")
        }
        task.cancel()
        gate.unblock()
        let cancelled = await task.value
        XCTAssertNil(cancelled)
        XCTAssertTrue(diagnostics.events.isEmpty)

        let failed = await scanner.scan(from: [file], since: .distantPast) { _, _ in
            throw CocoaError(.fileReadUnknown)
        }
        XCTAssertEqual(failed?.failedPaths, Set([file.path]))
        XCTAssertEqual(diagnostics.events, [
            DiagnosticEvent(.historyScan, result: .degraded, category: .storage, providerID: "codex")
        ])
    }

    func testIndependentParserCancellationRetainsCompletedCacheWithoutPublishingPartialResult() async throws {
        let root = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for value in 1...3 {
            try Data(String(value).utf8).write(to: root.appendingPathComponent("\(value).jsonl"))
        }
        let files = JSONLScanning.jsonlFiles(under: root).sorted { $0.path < $1.path }
        XCTAssertEqual(files.count, 3)
        let persistence = JSONLScanCachePersistence(
            namespace: "test", schemaVersion: 1, directory: root.appendingPathComponent("cache"),
            writeDebounce: .milliseconds(1)
        )
        let scanner = IncrementalJSONLScanner<Int>(logTag: "plugin:codex", persistence: persistence)
        let diagnostics = DiagnosticEventRecorder()
        let attempts = CollectionCancellationCounter()
        let result = await scanner.scan(from: files, since: .distantPast) { data, _ in
            attempts.increment()
            if data == Data("2".utf8) { throw CancellationError() }
            return Int(String(decoding: data, as: UTF8.self)).map { [$0] }
        }
        XCTAssertFalse(Task.isCancelled)
        XCTAssertNil(result)
        XCTAssertEqual(attempts.count, 2, "a parser cancellation must stop scheduling subsequent files")
        XCTAssertTrue(diagnostics.events.isEmpty)
        await scanner.waitForPendingWritesForTesting()

        let reloaded = IncrementalJSONLScanner<Int>(logTag: "plugin:codex", persistence: persistence)
        for instance in [reloaded, scanner] {
            let retried = CollectionCancellationCounter()
            let recovered = await instance.scan(from: files, since: .distantPast) { data, _ in
                retried.increment()
                return Int(String(decoding: data, as: UTF8.self)).map { [$0] }
            }
            XCTAssertEqual(recovered?.items, [1, 2, 3])
            XCTAssertEqual(retried.count, 2, "the completed first file must survive in memory and on disk")
            XCTAssertEqual(recovered?.completedFiles, 3)
            XCTAssertEqual(recovered?.failedPaths, Set<String>())
            await instance.waitForPendingWritesForTesting()
        }
        XCTAssertTrue(diagnostics.events.isEmpty)
    }

    func testParserNilResultDoesNotCancelOtherFiles() async throws {
        let root = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for value in 1...2 {
            try Data(String(value).utf8).write(to: root.appendingPathComponent("\(value).jsonl"))
        }
        let files = JSONLScanning.jsonlFiles(under: root).sorted { $0.path < $1.path }
        let failedPath = try XCTUnwrap(files.first).path
        let scanner = IncrementalJSONLScanner<Int>()
        let result = await scanner.scan(from: files, since: .distantPast) { data, _ in
            if data == Data("1".utf8) { return nil }
            return [2]
        }
        XCTAssertEqual(result?.items, [2])
        XCTAssertEqual(result?.completedFiles, 1)
        XCTAssertEqual(result?.failedPaths, Set([failedPath]))
    }

    func testPiFixturePropagatesCancellation() async {
        let cancelled = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try UsageRecordFixture.piRecords(Data("{}\n".utf8))
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }.value
        XCTAssertTrue(cancelled)
    }

    func testGrokCancelledReadDoesNotSuppressNextActualReadFailure() async {
        let calls = CollectionCancellationCounter()
        let scanner = GrokLogUsageScanner(
            files: CollectionCancellationFiles {
                if calls.increment() == 1 { withUnsafeCurrentTask { $0?.cancel() } }
                throw CocoaError(.fileReadUnknown)
            }, environment: FakeEnvironment([:]), homeDirectory: { URL(fileURLWithPath: "/test") }
        )
        let diagnostics = DiagnosticEventRecorder()
        let cancelled = await Task { await scanner.scan(pricing: TestPricing.bundled) }.value
        XCTAssertNil(cancelled)
        XCTAssertTrue(diagnostics.events.isEmpty)
        let failed = await scanner.scan(pricing: TestPricing.bundled)
        XCTAssertEqual(failed?.readFailureCount, 1)
        XCTAssertEqual(diagnostics.events, [
            DiagnosticEvent(.historyScan, result: .degraded, category: .storage, providerID: "grok")
        ])
    }

    func testGrokExplicitCancellationErrorIsNotReadFailure() async {
        let scanner = GrokLogUsageScanner(
            files: CollectionCancellationFiles { throw CancellationError() },
            environment: FakeEnvironment([:]), homeDirectory: { URL(fileURLWithPath: "/test") }
        )
        let diagnostics = DiagnosticEventRecorder()
        let result = await scanner.scan(pricing: TestPricing.bundled)
        XCTAssertNil(result)
        XCTAssertTrue(diagnostics.events.isEmpty)
    }

    func testPiCancellationDuringSettingsLookupWithNoCollectorsDoesNotPublishFailures() async throws {
        let root = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("invalid json".utf8).write(to: root.appendingPathComponent("settings.json"))
        let cancelledReads = CollectionCancellationCounter()
        let scanner = PiUsageScanner(
            environment: CollectionCancellationEnvironment(
                values: ["PI_CODING_AGENT_DIR": root.path, "OMP_PROFILE": "../invalid"],
                cancelledReads: cancelledReads
            ),
            homeDirectory: { root }, incrementalScanner: IncrementalJSONLScanner()
        )
        let diagnostics = DiagnosticEventRecorder()
        let result = await Task { await scanner.collect(since: .distantPast) }.value
        XCTAssertEqual(cancelledReads.count, 1, "settings lookup must cancel after collect's entry guard")
        XCTAssertNil(result)
        XCTAssertTrue(diagnostics.events.isEmpty)
    }

    func testPiCancellationWithNoValidCollectorsDoesNotPublishFailures() async throws {
        let root = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("invalid json".utf8).write(to: root.appendingPathComponent("settings.json"))
        let scanner = PiUsageScanner(
            environment: FakeEnvironment(["PI_CODING_AGENT_DIR": root.path, "OMP_PROFILE": "../invalid"]),
            homeDirectory: { root }
        )
        let diagnostics = DiagnosticEventRecorder()
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await scanner.collect(since: .distantPast)
        }.value
        XCTAssertNil(result)
        XCTAssertTrue(diagnostics.events.isEmpty)
        let normal = await scanner.collect(since: .distantPast)
        XCTAssertEqual(normal?.readFailureCount, 2)
        XCTAssertEqual(diagnostics.events.count, 2)
    }
}

private final class CollectionCancellationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }

    @discardableResult
    func increment() -> Int { lock.withLock { value += 1; return value } }
}

private final class CollectionCancellationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private let release = DispatchSemaphore(value: 0)

    var hasStarted: Bool { lock.withLock { started } }

    func wait() {
        lock.withLock { started = true }
        _ = release.wait(timeout: .now() + 5)
    }

    func unblock() { release.signal() }
}

private struct CollectionCancellationFiles: TextFileAccessing {
    let read: @Sendable () throws -> String

    func exists(_ path: String) -> Bool { true }
    func readText(_ path: String) throws -> String { try read() }
    func writeText(_ path: String, _ text: String) throws {}
    func remove(_ path: String) throws {}
}

private struct CollectionCancellationEnvironment: EnvironmentReading {
    let values: [String: String]
    let cancelledReads: CollectionCancellationCounter

    func value(for name: String) -> String? {
        if name == "PI_CODING_AGENT_SESSION_DIR" {
            cancelledReads.increment()
            withUnsafeCurrentTask { $0?.cancel() }
        }
        return values[name]
    }
}
