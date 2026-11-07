import os
import XCTest
@testable import Egasu

final class QwenCacheReuseTests: XCTestCase {
    func testManagedResourcesAreRevalidatedAfterMemoryAndDiskCacheHits() async throws {
        for restoreFromDisk in [false, true] {
            let directory = try UsageRecordFixture.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let fixture = Bundle.module.resourceURL!.appendingPathComponent("UsageCollection/qwen-managed-v1")
            let qwen = directory.appendingPathComponent(".qwen")
            try FileManager.default.copyItem(at: fixture, to: qwen)
            let journal = qwen.appendingPathComponent("projects/-workspace/chats/managed-1.jsonl")
            let resources = qwen.appendingPathComponent("resources")
            let persistence = JSONLScanCachePersistence(
                namespace: "qwen-test", schemaVersion: 1, directory: directory.appendingPathComponent("cache")
            )
            let makeCollector = {
                UsageFileCollector(
                    sourceID: "qwen", roots: [journal], scanner: IncrementalJSONLScanner(persistence: persistence),
                    canReuseCachedFile: QwenSessionParser.canReuseCachedFile,
                    includeFile: { _ in true },
                    parse: { try QwenSessionParser.parse($0, path: $1, resources: resources) }
                )
            }
            let original = makeCollector()
            let first = await original.collect(since: .distantPast)
            XCTAssertEqual(first?.records.count, 2)
            XCTAssertEqual(first?.readFailureCount, 0)
            await original.flushCache()
            let collector = restoreFromDisk ? makeCollector() : original
            let rows = try JSONLScanning.lines(in: Data(contentsOf: journal)).map(UsageJSON.object)
            let event = try XCTUnwrap(rows[1]["managedSession"] as? [String: Any])
            let payload = try XCTUnwrap(event["payload"] as? [String: Any])
            let reference = try XCTUnwrap(payload["contentRef"] as? [String: Any])
            let resourceID = try XCTUnwrap(reference["resourceId"] as? String)
            let resource = resources.appendingPathComponent("managed-1/managed-message/\(resourceID)")
            let bytes = try Data(contentsOf: resource)
            try Data("{}".utf8).write(to: resource)
            let changed = await collector.collect(since: .distantPast)
            XCTAssertEqual(changed?.sources.first?.status, .failed)
            XCTAssertEqual(changed?.records.count, 0)
            try bytes.write(to: resource)
            let recovered = await collector.collect(since: .distantPast)
            XCTAssertEqual(recovered?.records.count, 2)
            try FileManager.default.removeItem(at: resource)
            let deleted = await collector.collect(since: .distantPast)
            XCTAssertEqual(deleted?.sources.first?.status, .failed)
            XCTAssertEqual(deleted?.records.count, 0)
            await collector.flushCache()
        }
    }

    func testOrdinaryQwenJournalsReuseCachedParsing() async throws {
        let directory = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = directory.appendingPathComponent("session.jsonl")
        let row = #"{"type":"assistant","uuid":"r","sessionId":"s","timestamp":"2026-11-01T00:00:01Z","usageMetadata":{"totalTokenCount":100}}"#
        try UsageRecordFixture.write(row, to: journal)
        let parses = OSAllocatedUnfairLock(initialState: 0)
        let collector = UsageFileCollector(
            sourceID: "qwen", roots: [journal], scanner: IncrementalJSONLScanner(),
            canReuseCachedFile: QwenSessionParser.canReuseCachedFile, includeFile: { _ in true },
            parse: { data, path in
                parses.withLock { $0 += 1 }
                return try QwenSessionParser.parse(data, path: path, resources: directory)
            }
        )
        let first = await collector.collect(since: .distantPast)
        let second = await collector.collect(since: .distantPast)
        XCTAssertEqual(first?.records.first?.totalTokens, 100)
        XCTAssertEqual(second?.records.first?.totalTokens, 100)
        XCTAssertEqual(parses.withLock { $0 }, 1)
    }

    func testOwnershipPrefixRevalidatesManagedResources() async throws {
        let directory = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = Bundle.module.resourceURL!.appendingPathComponent("UsageCollection/qwen-managed-v1")
        let qwen = directory.appendingPathComponent(".qwen")
        try FileManager.default.copyItem(at: fixture, to: qwen)
        let collector = UsageSourceCollectors.qwenCollector(root: qwen, scanner: IncrementalJSONLScanner())
        let journal = qwen.appendingPathComponent("projects/-workspace/chats/managed-1.jsonl")
        let prefix = #"{"type":"system","subtype":"session_execution_engine","systemPayload":{"version":1,"engine":"managed"}}"# + "\n"
        let bytes = Data(prefix.utf8) + (try Data(contentsOf: journal))
        try bytes.write(to: journal)
        XCTAssertEqual(collector.canReuseCachedFile?(journal.path), false)
        let first = await collector.collect(since: .distantPast)
        XCTAssertEqual(first?.readFailureCount, 0)
        try FileManager.default.removeItem(at: qwen.appendingPathComponent("resources"))
        let failed = await collector.collect(since: .distantPast)
        XCTAssertGreaterThan(try XCTUnwrap(failed?.readFailureCount), 0)
        XCTAssertTrue(failed?.records.isEmpty == true)
        await collector.flushCache()
    }
}
