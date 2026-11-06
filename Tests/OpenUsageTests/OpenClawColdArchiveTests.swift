import XCTest
@testable import OpenUsage

@MainActor
final class OpenClawColdArchiveTests: XCTestCase {
    func testSQLiteColdPayloadsAndHotCopyAreCountedOnceWithoutWritingDatabase() async throws {
        let store = try OpenClawTestStore()
        let first = try OpenClawTestStore.message(id: "e1", cost: 0.25)
        let second = try OpenClawTestStore.message(id: "e2", cost: 0)
        let archive = try OpenClawTestStore.ColdArchive(events: [(0, OpenClawTestStore.header), (1, first), (2, second)])
        try store.install([archive])
        try store.execute("UPDATE transcript_events SET event_json=\(OpenClawTestStore.literal(first)) WHERE seq=1")
        let before = try Data(contentsOf: store.file)
        let transcript = store.directory.appendingPathComponent("sessions/s1.jsonl")
        try UsageRecordFixture.write(OpenClawTestStore.header + "\n" + first + "\n" + second, to: transcript)
        let file = store.file
        let fileCollector = UsageFileCollector(
            sourceID: "openclaw", roots: [transcript], scanner: IncrementalJSONLScanner(),
            includeFile: { _ in true }, parse: OpenClawSessionParser.parse
        )
        let databaseCollector = UsageSQLiteCollector(
            sourceID: "openclaw", roots: [file], includeFile: { _ in true }, parse: OpenClawSessionParser.database
        )
        let collected = await UsageCollectionCoordinator(collectors: [fileCollector, databaseCollector]).collect(since: .distantPast)
        let result = try XCTUnwrap(collected)
        XCTAssertEqual(result.records.count, 2)
        XCTAssertEqual(result.records.reduce(0) { $0 + $1.totalTokens }, 240)
        XCTAssertEqual(result.records.reduce(0) { $0 + ($1.recordedCostUSD ?? 0) }, 0.25)
        XCTAssertEqual(result.readFailureCount, 0)
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testFileColdArchiveUsesOwningAgentSessionsDirectoryAndVerifiesContent() throws {
        let store = try OpenClawTestStore()
        let archive = try OpenClawTestStore.ColdArchive(events: [(1, OpenClawTestStore.message(id: "e1", cost: 0.25))])
        try store.install([archive], storage: "file")
        XCTAssertEqual(try store.records().first?.totalTokens, 120)
        let file = store.coldDirectory.appendingPathComponent(archive.name)
        try (archive.bytes + Data([0])).write(to: file)
        XCTAssertThrowsError(try store.records())
        try archive.bytes.write(to: file)
        try store.execute("UPDATE session_transcript_cold_archives SET archive_sha256='\(String(repeating: "0", count: 64))'")
        XCTAssertThrowsError(try store.records())
        try store.execute("UPDATE session_transcript_cold_archives SET archive_sha256='\(archive.hash)',archive_name='../outside.jsonl.zst'")
        XCTAssertThrowsError(try store.records())
    }

    func testBothChunkStorageModesRestoreOrderedPayloadsAndRejectParentMismatch() throws {
        for storage in ["sqlite", "file"] {
            let store = try OpenClawTestStore()
            let first = try OpenClawTestStore.ColdArchive(events: [
                (0, OpenClawTestStore.header), (1, OpenClawTestStore.message(id: "e1", cost: 0.25))
            ])
            let second = try OpenClawTestStore.ColdArchive(events: [(3, OpenClawTestStore.message(id: "e2", cost: 0))])
            try store.install([first, second], storage: storage)
            let records = try store.records()
            XCTAssertEqual(records.map(\.id), ["e1", "e2"], storage)
            XCTAssertEqual(records.reduce(0) { $0 + $1.totalTokens }, 240, storage)
            try store.execute("UPDATE session_transcript_cold_archive_chunks SET first_seq=1 WHERE chunk_index=1")
            XCTAssertThrowsError(try store.records(), storage)
            try store.execute("UPDATE session_transcript_cold_archive_chunks SET first_seq=3 WHERE chunk_index=1")
            XCTAssertEqual(try store.records().count, 2)
            try store.execute("UPDATE session_transcript_cold_archives SET raw_bytes=raw_bytes+1")
            XCTAssertThrowsError(try store.records(), storage)
        }
    }

    func testColdEnvelopeRejectsWrongIdentityOrderAndUnsupportedRecords() throws {
        let message = try OpenClawTestStore.message(id: "e1", cost: 0.25)
        let changes: [([[String: Any]]) -> [[String: Any]]] = [
            { var rows = $0; rows[0]["sessionId"] = "other"; return rows },
            { var rows = $0; rows[0]["generation"] = "other"; return rows },
            { var rows = $0; rows[0]["version"] = 2; return rows },
            { var rows = $0; rows[0]["version"] = "1"; return rows },
            { rows in [rows[0], rows[0]] + Array(rows.dropFirst()) },
            { rows in [rows[0]] + Array(rows.dropFirst().reversed()) },
            { rows in rows + [["kind": "unknown", "row": [:]]] }
        ]
        for (index, change) in changes.enumerated() {
            let store = try OpenClawTestStore()
            let archive = try OpenClawTestStore.ColdArchive(events: [(0, OpenClawTestStore.header), (1, message)], transform: change)
            try store.install([archive])
            XCTAssertThrowsError(try store.records(), "case \(index)")
        }
    }

    func testColdManifestBoundsAndRequiredPayloadAreVerifiedBeforeReturningUsage() throws {
        let changes = [
            "UPDATE session_transcript_cold_archives SET event_count=event_count+1",
            "UPDATE session_transcript_cold_archives SET raw_bytes=raw_bytes+1",
            "UPDATE session_transcript_cold_archives SET archive_bytes=archive_bytes+1",
            "UPDATE session_transcript_cold_archives SET last_seq=last_seq+1",
            "UPDATE transcript_events SET event_utf8_bytes=event_utf8_bytes+1",
            "UPDATE transcript_events SET seq=99",
            "UPDATE session_transcript_cold_archives SET archive_blob=NULL"
        ]
        for change in changes {
            let store = try OpenClawTestStore()
            let archive = try OpenClawTestStore.ColdArchive(events: [(1, OpenClawTestStore.message(id: "e1", cost: 0.25))])
            try store.install([archive])
            try store.execute(change)
            XCTAssertThrowsError(try store.records(), change)
        }
    }

    func testColdRestoreAcceptsAuxiliaryIndexAndIdentityRowsWithoutCountingThem() throws {
        let store = try OpenClawTestStore()
        let archive = try OpenClawTestStore.ColdArchive(events: [(1, OpenClawTestStore.message(id: "e1", cost: 0.25))]) { rows in
            rows + [
                ["kind": "identity", "row": ["event_id": "e1", "seq": 1, "event_type": "message",
                                              "parent_id": NSNull(), "message_idempotency_key": NSNull(), "created_at": 1793494800]],
                ["kind": "active", "row": ["active_position": 0, "event_seq": 1,
                                            "message_position": NSNull(), "context_eligible": NSNull()]],
                ["kind": "index", "row": ["indexed_seq": -1, "leaf_event_id": NSNull(), "needs_rebuild": 1,
                                           "active_event_count": 1, "active_message_count": 1, "updated_at": 1793494800]],
                ["kind": "fts", "row": ["text": "not retained", "message_id": "e1", "role": "assistant", "timestamp": NSNull()]]
            ]
        }
        try store.install([archive])
        XCTAssertEqual(try store.records().count, 1)
        XCTAssertEqual(try store.records().first?.totalTokens, 120)
    }

    func testTruncatedColdFrameWithMatchingHashStillFails() throws {
        let store = try OpenClawTestStore()
        let archive = try OpenClawTestStore.ColdArchive(events: [(1, OpenClawTestStore.message(id: "e1", cost: 0.25))])
        try store.install([archive])
        let truncated = Data(archive.bytes.dropLast())
        let hash = OpenClawTestStore.sha256(truncated)
        try store.execute("""
        UPDATE session_transcript_cold_archives SET archive_blob=\(OpenClawTestStore.blob(truncated)),
          archive_name='\(hash).jsonl.zst',archive_sha256='\(hash)',archive_bytes=\(truncated.count)
        """)
        XCTAssertThrowsError(try store.records())
    }

    func testUnpublishedDeletedAndResetArchiveCopiesShareRequestIdentity() async throws {
        let store = try OpenClawTestStore()
        let transcript = Data((OpenClawTestStore.header + "\n" + (try OpenClawTestStore.message(id: "e1", cost: 0.25))).utf8)
        for (generation, encoding) in [("deleted", "identity"), ("reset", "zstd")] {
            let bytes = encoding == "zstd" ? try OpenClawTestStore.compress(transcript) : transcript
            try store.execute("""
            INSERT INTO session_transcript_archives VALUES('s1','\(generation)','\(encoding)',
              \(OpenClawTestStore.blob(bytes)),'\(OpenClawTestStore.sha256(bytes))')
            """)
        }
        let file = store.file
        let collector = UsageSQLiteCollector(
            sourceID: "openclaw", roots: [file], includeFile: { _ in true }, parse: OpenClawSessionParser.database
        )
        let collected = await UsageCollectionCoordinator(collectors: [collector]).collect(since: .distantPast)
        let result = try XCTUnwrap(collected)
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records.first?.totalTokens, 120)
        XCTAssertEqual(result.readFailureCount, 0)
        try store.execute("UPDATE session_transcript_archives SET archive_sha256='\(String(repeating: "0", count: 64))'")
        let invalid = await collector.collect(since: .distantPast)
        XCTAssertEqual(invalid?.readFailureCount, 1)
        XCTAssertTrue(invalid?.records.isEmpty == true)
    }

    func testMissingColdManifestKeepsIncompleteRecordInsteadOfInventingZeroUsage() throws {
        let store = try OpenClawTestStore()
        try store.execute("INSERT INTO transcript_events VALUES('s1',1,NULL,NULL,123)")
        let record = try XCTUnwrap(store.records().first)
        XCTAssertEqual(record.kind, "missing-payload")
        XCTAssertTrue(record.issues.contains(.invalidMetadata))
        XCTAssertNil(record.recordedCostUSD)
    }

    func testCanonicalArchiveRequiresRegisteredSessionHeader() throws {
        let message = try OpenClawTestStore.message(id: "e1", cost: 0.25)
        for transcript in ["", message, #"{"type":"session","id":"other"}"# + "\n" + message] {
            let store = try OpenClawTestStore()
            let bytes = Data(transcript.utf8)
            try store.execute("""
            INSERT INTO session_transcript_archives VALUES('s1','g1','identity',
              \(OpenClawTestStore.blob(bytes)),'\(OpenClawTestStore.sha256(bytes))')
            """)
            XCTAssertThrowsError(try store.records())
        }
    }
}
