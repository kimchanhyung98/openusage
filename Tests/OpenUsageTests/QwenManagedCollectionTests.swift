import CryptoKit
import XCTest
@testable import OpenUsage

final class QwenManagedCollectionTests: XCTestCase {
    private var fixtures: URL { Bundle.module.resourceURL!.appendingPathComponent("UsageCollection") }

    func testCommittedChunkedMessagesAndV2SnapshotHaveIdenticalUsage() async throws {
        let root = fixtures.appendingPathComponent("qwen-managed-v1")
        let resources = root.appendingPathComponent("resources")
        let directory = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let chats = directory.appendingPathComponent("projects/-workspace/chats")
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let v1 = chats.appendingPathComponent("managed-v1.jsonl")
        let v2 = chats.appendingPathComponent("managed-v2.jsonl")
        try FileManager.default.copyItem(at: root.appendingPathComponent("projects/-workspace/chats/managed-1.jsonl"), to: v1)
        try FileManager.default.copyItem(
            at: fixtures.appendingPathComponent("qwen-managed-v2/projects/-workspace/chats/managed-1.jsonl"), to: v2
        )
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

    func testHeaderDependenciesMissingOrModifiedAreRejectedForV1AndV2() throws {
        for version in ["v1", "v2"] {
            for field in ["definitionRef", "rootSnapshotRef"] {
                for damage in ["missing", "modified"] {
                    let resources = try copiedResources()
                    let rows = try managedRows(version)
                    let header = try XCTUnwrap(rows[0]["managedSession"] as? [String: Any])
                    let ref = try XCTUnwrap(header[field] as? [String: Any])
                    let url = try resourceURL(ref, resources: resources)
                    if damage == "missing" { try FileManager.default.removeItem(at: url) }
                    else { try Data("[]".utf8).write(to: url) }

                    XCTAssertThrowsError(try QwenManagedJournal.messages(rows, resources: resources),
                                         "\(version):\(field):\(damage)")
                }
            }
        }
    }

    func testHeaderRequiresBothResourceReferencesForV1AndV2() throws {
        let resources = fixtures.appendingPathComponent("qwen-managed-v1/resources")
        for version in ["v1", "v2"] {
            for field in ["definitionRef", "rootSnapshotRef"] {
                for value in [nil, NSNull()] as [Any?] {
                    var rows = try managedRows(version)
                    var header = try XCTUnwrap(rows[0]["managedSession"] as? [String: Any])
                    header[field] = value
                    rows[0]["managedSession"] = header

                    XCTAssertThrowsError(try QwenManagedJournal.messages(rows, resources: resources),
                                         "\(version):\(field)")
                }
            }
        }
    }

    func testDeclaredBaseTranscriptProofMustExistAndMatchItsDigest() throws {
        let resources = try copiedResources()
        var rows = try managedRows("v1")
        var header = try XCTUnwrap(rows[0]["managedSession"] as? [String: Any])
        var proof = try XCTUnwrap(header["definitionRef"] as? [String: Any])
        proof["resourceId"] = "proof-fixture"
        header["baseTranscriptProof"] = proof
        rows[0]["managedSession"] = header
        let url = try resourceURL(proof, resources: resources)

        XCTAssertThrowsError(try QwenManagedJournal.messages(rows, resources: resources))
        try Data("{}".utf8).write(to: url)
        XCTAssertEqual(try QwenManagedJournal.messages(rows, resources: resources).count, 2)
        try Data("[]".utf8).write(to: url)
        XCTAssertThrowsError(try QwenManagedJournal.messages(rows, resources: resources))
        header["baseTranscriptProof"] = NSNull()
        rows[0]["managedSession"] = header
        XCTAssertThrowsError(try QwenManagedJournal.messages(rows, resources: resources))
    }

    func testSnapshotValidatesResourcesOutsideItsMessages() throws {
        let resources = try copiedResources()
        var rows = try managedRows("v2")
        let header = try XCTUnwrap(rows[0]["managedSession"] as? [String: Any])
        var ref = try XCTUnwrap(header["definitionRef"] as? [String: Any])
        ref["resourceId"] = "manifest-only-fixture"
        let base = try XCTUnwrap(rows[1]["managedSessionSnapshot"] as? [String: Any])
        let manifestRef = try XCTUnwrap(base["manifest"] as? [String: Any])
        var manifest = try UsageJSON.object(Data(contentsOf: resourceURL(manifestRef, resources: resources)))
        var refs = try XCTUnwrap(manifest["resources"] as? [[String: Any]])
        refs.append(ref)
        manifest["resources"] = refs
        try writeManifest(manifest, rows: &rows, resources: resources)
        let url = try resourceURL(ref, resources: resources)

        XCTAssertThrowsError(try QwenManagedJournal.messages(rows, resources: resources))
        try Data("{}".utf8).write(to: url)
        XCTAssertEqual(try QwenManagedJournal.messages(rows, resources: resources).count, 2)
        try Data("[]".utf8).write(to: url)
        XCTAssertThrowsError(try QwenManagedJournal.messages(rows, resources: resources))
    }

    func testSnapshotRequiresAResourceReferenceList() throws {
        for value in [nil, [:], ["invalid"]] as [Any?] {
            let resources = try copiedResources()
            var rows = try managedRows("v2")
            let base = try XCTUnwrap(rows[1]["managedSessionSnapshot"] as? [String: Any])
            let ref = try XCTUnwrap(base["manifest"] as? [String: Any])
            var manifest = try UsageJSON.object(Data(contentsOf: resourceURL(ref, resources: resources)))
            manifest["resources"] = value
            try writeManifest(manifest, rows: &rows, resources: resources)

            XCTAssertThrowsError(try QwenManagedJournal.messages(rows, resources: resources))
        }
    }

    func testResourceLengthMismatchRejectsShortLongAndSparseFiles() throws {
        for length in [1, 3, 256 * 1024 * 1024] {
            let resources = try copiedResources()
            let rows = try managedRows("v1")
            let header = try XCTUnwrap(rows[0]["managedSession"] as? [String: Any])
            let ref = try XCTUnwrap(header["definitionRef"] as? [String: Any])
            let url = try resourceURL(ref, resources: resources)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(length))
            try handle.close()

            XCTAssertThrowsError(try QwenManagedJournal.messages(rows, resources: resources), "\(length)")
        }
    }

    func testHeaderResourceReferencesKeepPathContainment() throws {
        let resources = try copiedResources()
        let original = try managedRows("v1")
        var header = try XCTUnwrap(original[0]["managedSession"] as? [String: Any])
        var ref = try XCTUnwrap(header["definitionRef"] as? [String: Any])
        let outside = resources.deletingLastPathComponent().appendingPathComponent("outside")
        try Data("{}".utf8).write(to: outside)
        let link = resources.appendingPathComponent("managed-1/managed-definition/escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        for id in ["../outside", "escape"] {
            var rows = original
            ref["resourceId"] = id
            header["definitionRef"] = ref
            rows[0]["managedSession"] = header

            XCTAssertThrowsError(try QwenManagedJournal.messages(rows, resources: resources), id)
        }
    }

    func testUncommittedTailResourceOutsideTheManifestIsNotRead() throws {
        let resources = try copiedResources()
        let original = try managedRows("v1")
        let event = try XCTUnwrap(original.last?["managedSession"] as? [String: Any])
        let payload = try XCTUnwrap(event["payload"] as? [String: Any])
        let ref = try XCTUnwrap(payload["contentRef"] as? [String: Any])
        try FileManager.default.removeItem(at: resourceURL(ref, resources: resources))

        for version in ["v1", "v2"] {
            let records = try QwenManagedJournal.messages(managedRows(version), resources: resources)
            XCTAssertEqual(records.count, 2, version)
        }
    }

    func testMissingHeaderResourceIsACollectionReadFailure() async throws {
        let resources = try copiedResources()
        let rows = try managedRows("v1")
        let header = try XCTUnwrap(rows[0]["managedSession"] as? [String: Any])
        let ref = try XCTUnwrap(header["definitionRef"] as? [String: Any])
        try FileManager.default.removeItem(at: resourceURL(ref, resources: resources))
        let journal = fixtures.appendingPathComponent("qwen-managed-v1/projects/-workspace/chats/managed-1.jsonl")
        let collector = UsageFileCollector(sourceID: "qwen", roots: [journal], scanner: IncrementalJSONLScanner(),
                                           includeFile: { _ in true },
                                           parse: { try QwenSessionParser.parse($0, path: $1, resources: resources) })

        let collected = await collector.collect(since: .distantPast)
        let result = try XCTUnwrap(collected)

        XCTAssertTrue(result.records.isEmpty)
        XCTAssertEqual(result.sources.first?.status, .failed)
        XCTAssertEqual(result.readFailureCount, 1)
    }

    func testCommittedMessagesRequirePayloadAndContentReference() throws {
        let resources = fixtures.appendingPathComponent("qwen-managed-v1/resources")
        for damage in ["missing-payload", "null-payload", "text-payload", "missing-ref", "null-ref", "text-ref", "array-ref"] {
            let rows = try updatingFirstCommittedEvent { event in
                switch damage {
                case "missing-payload": event.removeValue(forKey: "payload")
                case "null-payload": event["payload"] = NSNull()
                case "text-payload": event["payload"] = "invalid"
                default:
                    var payload = try XCTUnwrap(event["payload"] as? [String: Any])
                    switch damage {
                    case "missing-ref": payload.removeValue(forKey: "contentRef")
                    case "null-ref": payload["contentRef"] = NSNull()
                    case "text-ref": payload["contentRef"] = "invalid"
                    default: payload["contentRef"] = [] as [Any]
                    }
                    event["payload"] = payload
                }
            }

            XCTAssertThrowsError(try QwenManagedJournal.messages(rows, resources: resources), damage)
        }
    }

    func testOtherCommittedEventsDoNotRequireMessageContentReference() throws {
        let rows = try updatingFirstCommittedEvent { event in
            event["kind"] = "message.delta"
            event["payload"] = ["messageId": "delta-message", "turnId": "turn-1", "role": "assistant", "text": "delta"]
        }
        let resources = fixtures.appendingPathComponent("qwen-managed-v1/resources")

        let messages = try QwenManagedJournal.messages(rows, resources: resources)

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?["uuid"] as? String, "managed-record-2")
    }

    func testMissingCommittedMessageReferenceIsACollectionReadFailure() async throws {
        let rows = try updatingFirstCommittedEvent { event in
            var payload = try XCTUnwrap(event["payload"] as? [String: Any])
            payload.removeValue(forKey: "contentRef")
            event["payload"] = payload
        }
        let directory = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = directory.appendingPathComponent("session.jsonl")
        var bytes = Data()
        for row in rows {
            bytes.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
            bytes.append(0x0A)
        }
        try bytes.write(to: journal)
        let resources = fixtures.appendingPathComponent("qwen-managed-v1/resources")
        let collector = UsageFileCollector(sourceID: "qwen", roots: [journal], scanner: IncrementalJSONLScanner(),
                                           includeFile: { _ in true },
                                           parse: { try QwenSessionParser.parse($0, path: $1, resources: resources) })

        let collected = await collector.collect(since: .distantPast)
        let result = try XCTUnwrap(collected)

        XCTAssertTrue(result.records.isEmpty)
        XCTAssertEqual(result.sources.first?.status, .failed)
        XCTAssertEqual(result.readFailureCount, 1)
    }

    private func updatingFirstCommittedEvent(_ update: (inout [String: Any]) throws -> Void) throws -> [[String: Any]] {
        var rows = try managedRows("v1")
        var event = try XCTUnwrap(rows[1]["managedSession"] as? [String: Any])
        try update(&event)
        rows[1]["managedSession"] = event
        let commitIndex = try XCTUnwrap(rows.firstIndex { $0["subtype"] as? String == "managed_session_commit_v1" })
        let events = try rows[1..<commitIndex].map { try XCTUnwrap($0["managedSession"] as? [String: Any]) }
        let data = try QwenCanonicalJSON().encode(events)
        var commit = try XCTUnwrap(rows[commitIndex]["managedSession"] as? [String: Any])
        commit["eventsDigest"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        rows[commitIndex]["managedSession"] = commit
        return rows
    }

    private func copiedResources() throws -> URL {
        let directory = try UsageRecordFixture.temporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let resources = directory.appendingPathComponent("resources")
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("qwen-managed-v1/resources"), to: resources)
        return resources
    }

    private func managedRows(_ version: String) throws -> [[String: Any]] {
        let journal = fixtures.appendingPathComponent("qwen-managed-\(version)/projects/-workspace/chats/managed-1.jsonl")
        return try JSONLScanning.lines(in: Data(contentsOf: journal)).map(UsageJSON.object)
    }

    private func resourceURL(_ ref: [String: Any], resources: URL) throws -> URL {
        let kind = try XCTUnwrap(ref["kind"] as? String)
        let id = try XCTUnwrap(ref["resourceId"] as? String)
        return resources.appendingPathComponent("managed-1").appendingPathComponent(kind).appendingPathComponent(id)
    }

    private func writeManifest(_ manifest: [String: Any], rows: inout [[String: Any]], resources: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        var base = try XCTUnwrap(rows[1]["managedSessionSnapshot"] as? [String: Any])
        var ref = try XCTUnwrap(base["manifest"] as? [String: Any])
        ref["resourceId"] = digest
        ref["digest"] = digest
        ref["byteLength"] = data.count
        try data.write(to: resourceURL(ref, resources: resources))
        base["manifest"] = ref
        rows[1]["managedSessionSnapshot"] = base
    }
}
