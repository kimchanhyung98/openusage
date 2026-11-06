import XCTest
@testable import OpenUsage

final class QwenManagedCollectionTests: XCTestCase {
    private var fixtures: URL { Bundle.module.resourceURL!.appendingPathComponent("UsageCollection") }

    func testCommittedChunkedMessagesAndV2SnapshotHaveIdenticalUsage() async throws {
        let root = fixtures.appendingPathComponent("qwen-managed-v1")
        let resources = root.appendingPathComponent("resources")
        let v1 = root.appendingPathComponent("projects/-workspace/chats/managed-1.jsonl")
        let v2 = fixtures.appendingPathComponent("qwen-managed-v2/projects/-workspace/chats/managed-1.jsonl")
        let collector = UsageFileCollector(sourceID: "qwen", roots: [v1, v2], scanner: IncrementalJSONLScanner(),
                                           includeFile: { $0.pathExtension == "jsonl" },
                                           parse: { try QwenSessionParser.parse($0, path: $1, resources: resources) })
        let coordinator = UsageCollectionCoordinator(collectors: [collector])
        let collection = await coordinator.collect(since: .distantPast)
        let result = try XCTUnwrap(collection)
        XCTAssertEqual(result.readFailureCount, 0)
        XCTAssertEqual(result.records.count, 2)
        XCTAssertEqual(result.records.reduce(0) { $0 + $1.totalTokens }, 275)
        XCTAssertEqual(Set(result.records.compactMap(\.id)), ["managed-record-1", "managed-record-2"])
        let encoded = String(decoding: try JSONEncoder().encode(result.records), as: UTF8.self)
        XCTAssertFalse(encoded.contains(String(repeating: "x", count: 100)))
    }

    func testUncommittedTailIsIgnoredButBrokenCommitIsAReadFailure() async throws {
        let root = fixtures.appendingPathComponent("qwen-managed-v1")
        let resources = root.appendingPathComponent("resources")
        let text = try String(contentsOf: root.appendingPathComponent("projects/-workspace/chats/managed-1.jsonl"), encoding: .utf8)
        let directory = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.jsonl")
        let lines = text.split(separator: "\n")
        let withoutCommit = lines.filter { !$0.contains("managed_session_commit_v1") }.joined(separator: "\n")
        XCTAssertTrue(try QwenSessionParser.parse(Data(withoutCommit.utf8), path: file.path, resources: resources).isEmpty)
        let corrupted = text.replacingOccurrences(of: #""eventCount":2"#, with: #""eventCount":3"#)
        try UsageRecordFixture.write(corrupted, to: file)
        let collector = UsageFileCollector(sourceID: "qwen", roots: [file], scanner: IncrementalJSONLScanner(),
                                           includeFile: { _ in true },
                                           parse: { try QwenSessionParser.parse($0, path: $1, resources: resources) })
        let collected = await collector.collect(since: .distantPast)
        let result = try XCTUnwrap(collected)
        XCTAssertTrue(result.records.isEmpty)
        XCTAssertEqual(result.sources.first?.status, .failed)
    }

    func testChangedCommittedResourceIsRejected() throws {
        let source = fixtures.appendingPathComponent("qwen-managed-v1")
        let directory = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let resources = directory.appendingPathComponent("resources")
        try FileManager.default.copyItem(at: source.appendingPathComponent("resources"), to: resources)
        let journal = source.appendingPathComponent("projects/-workspace/chats/managed-1.jsonl")
        let rows = try JSONLScanning.lines(in: Data(contentsOf: journal)).map(UsageJSON.object)
        let event = try XCTUnwrap(rows[1]["managedSession"] as? [String: Any])
        let payload = try XCTUnwrap(event["payload"] as? [String: Any])
        let reference = try XCTUnwrap(payload["contentRef"] as? [String: Any])
        let resourceID = try XCTUnwrap(reference["resourceId"] as? String)
        let message = resources.appendingPathComponent("managed-1/managed-message/\(resourceID)")
        try UsageRecordFixture.write("{}", to: message)
        XCTAssertThrowsError(try QwenSessionParser.parse(Data(contentsOf: journal), path: journal.path, resources: resources))
    }

    func testOwnershipPrefixDoesNotHideManagedV1OrV2() throws {
        let resources = fixtures.appendingPathComponent("qwen-managed-v1/resources")
        let prefix = #"{"type":"system","subtype":"session_execution_engine","systemPayload":{"version":1,"engine":"managed"}}"# + "\n"
        for version in ["v1", "v2"] {
            let file = fixtures.appendingPathComponent("qwen-managed-\(version)/projects/-workspace/chats/managed-1.jsonl")
            let data = Data(prefix.utf8) + (try Data(contentsOf: file))
            let records = try QwenSessionParser.parse(data, path: file.path, resources: resources)
            XCTAssertEqual(records.count, 2)
            XCTAssertEqual(records.reduce(0) { $0 + $1.totalTokens }, 275)
        }
    }

    func testManagedCommitRequiresNewlineAndTornTailPreservesCommittedPrefix() throws {
        let root = fixtures.appendingPathComponent("qwen-managed-v1")
        let file = root.appendingPathComponent("projects/-workspace/chats/managed-1.jsonl")
        let resources = root.appendingPathComponent("resources")
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        let lastCommit = try XCTUnwrap(lines.lastIndex { $0.contains("managed_session_commit_v1") })
        let text = lines[...lastCommit].joined(separator: "\n")
        XCTAssertTrue(try QwenSessionParser.parse(Data(text.utf8), path: file.path, resources: resources).isEmpty)
        let committed = text + "\n"
        let torn = committed + #"{"subtype":"managed_session_event_v1""#
        XCTAssertEqual(try QwenSessionParser.parse(Data(torn.utf8), path: file.path, resources: resources).count, 2)
        XCTAssertThrowsError(try QwenSessionParser.parse(Data((torn + "\n").utf8), path: file.path, resources: resources))
    }

    func testJavaScriptGeneratedCommitDigestAcceptsKeyOrderAndFractionalNumbers() throws {
        let root = fixtures.appendingPathComponent("qwen-managed-v1")
        let file = root.appendingPathComponent("projects/-workspace/chats/managed-canonical.jsonl")
        let records = try QwenSessionParser.parse(
            Data(contentsOf: file), path: file.path, resources: root.appendingPathComponent("resources")
        )
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.reduce(0) { $0 + $1.totalTokens }, 275)
    }
}
