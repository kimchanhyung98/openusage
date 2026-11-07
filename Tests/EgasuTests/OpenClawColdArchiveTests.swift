import XCTest
@testable import Egasu

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

    func testVerifiedArchiveStillRejectsIncompleteFinalJSONLRow() throws {
        let prefix = OpenClawTestStore.header + "\n" + (try OpenClawTestStore.message(id: "complete", cost: 0.25)) + "\n"
        let transcript = Data((prefix + #"{"type":"message"#).utf8)
        for encoding in ["identity", "zstd"] {
            let store = try OpenClawTestStore()
            let bytes = encoding == "zstd" ? try OpenClawTestStore.compress(transcript) : transcript
            try store.execute("""
            INSERT INTO session_transcript_archives VALUES('s1','g1','\(encoding)',
              \(OpenClawTestStore.blob(bytes)),'\(OpenClawTestStore.sha256(bytes))')
            """)

            XCTAssertThrowsError(try store.records(), encoding)
        }
    }

    func testMissingPayloadClearsAttributionUntilExplicitMetadataRestoresIt() throws {
        func withoutAttribution(id: String, input: Int, output: Int) throws -> String {
            var object = try UsageJSON.object(Data(OpenClawTestStore.message(id: id, cost: 0.5, input: input, output: output).utf8))
            var message = try XCTUnwrap(object["message"] as? [String: Any])
            message.removeValue(forKey: "provider")
            message.removeValue(forKey: "model")
            object["message"] = message
            return try OpenClawTestStore.json(object)
        }
        var explicit = try UsageJSON.object(Data(OpenClawTestStore.message(id: "route", provider: "openai", cost: 0, input: 0, output: 0).utf8))
        var explicitMessage = try XCTUnwrap(explicit["message"] as? [String: Any])
        explicitMessage["model"] = "gpt-5.2"
        explicit["message"] = explicitMessage
        let routes = [
            #"{"type":"model_change","provider":"openai","modelId":"gpt-5.2"}"#,
            #"{"type":"custom","customType":"model-snapshot","data":{"provider":"openai","modelId":"gpt-5.2"}}"#,
            try OpenClawTestStore.json(explicit)
        ]
        for route in routes {
            let store = try OpenClawTestStore()
            let events: [(Int, String?)] = [
                (0, OpenClawTestStore.header), (1, try OpenClawTestStore.message(id: "before", cost: 0.25)),
                (2, nil), (3, try withoutAttribution(id: "unknown", input: 200, output: 40)),
                (4, route), (5, try withoutAttribution(id: "after", input: 300, output: 60))
            ]
            for (sequence, text) in events {
                try store.execute("INSERT INTO transcript_events VALUES('s1',\(sequence),\(text.map(OpenClawTestStore.literal) ?? "NULL"),NULL,\(text?.utf8.count ?? 123))")
            }
            let independent = try OpenClawTestStore.message(id: "independent", provider: "opencode", cost: 0.1)
            try store.execute("INSERT INTO transcript_events VALUES('s2',0,\(OpenClawTestStore.literal(independent)),NULL,\(independent.utf8.count))")

            let records = try store.records()
            let unknown = try XCTUnwrap(records.first { $0.id == "unknown" })
            let restored = try XCTUnwrap(records.first { $0.id == "after" })
            XCTAssertNil(unknown.providerID)
            XCTAssertNil(unknown.model)
            XCTAssertEqual(unknown.totalTokens, 240)
            XCTAssertEqual(unknown.recordedCostUSD, 0.5)
            XCTAssertTrue(unknown.issues.contains(.invalidMetadata))
            XCTAssertEqual(restored.providerID, "openai")
            XCTAssertEqual(restored.model, "gpt-5.2")
            XCTAssertEqual(restored.totalTokens, 360)
            XCTAssertTrue(restored.issues.isEmpty)
            XCTAssertEqual(records.first { $0.id == "independent" }?.providerID, "opencode")
            XCTAssertEqual(records.filter { $0.kind == "missing-payload" }.count, 1)
            let scan = try XCTUnwrap(UsageHistoryBuilder.scan(
                UsageCollection(records: records), providerID: "claude", since: .distantPast,
                pricing: .empty, allowEstimates: false
            ))
            XCTAssertEqual(scan.series.daily.first?.totalTokens, 120)
            XCTAssertEqual(scan.series.daily.first?.costUSD, 0.25)
        }
    }

    func testDatabaseSessionHeadersRejectMismatchedMissingAndNonStringIDsInEveryStorage() throws {
        let headers = [#"{"type":"session","id":"other"}"#, #"{"type":"session"}"#, #"{"type":"session","id":123}"#]
        for storage in ["json", "zstd", "cold"] {
            for header in headers {
                XCTAssertThrowsError(try recordsWithHeader(header, storage: storage), storage + ": " + header)
            }
        }
    }

    func testMatchingDatabaseSessionHeadersRetainTheRowSessionInEveryStorage() throws {
        for storage in ["json", "zstd", "cold"] {
            let records = try recordsWithHeader(OpenClawTestStore.header, storage: storage)
            XCTAssertEqual(records.count, 1, storage)
            XCTAssertEqual(records.first?.sessionID, "s1", storage)
            XCTAssertEqual(records.first?.totalTokens, 120, storage)
        }
    }

    private func recordsWithHeader(_ header: String, storage: String) throws -> [UsageRecord] {
        let store = try OpenClawTestStore()
        let message = try OpenClawTestStore.message(id: "e1", cost: 0.25)
        if storage == "cold" {
            try store.install([OpenClawTestStore.ColdArchive(events: [(0, header), (1, message)])])
        } else {
            let text = storage == "json" ? OpenClawTestStore.literal(header) : "NULL"
            let blob = storage == "zstd" ? try OpenClawTestStore.blob(OpenClawTestStore.compress(Data(header.utf8))) : "NULL"
            try store.execute("INSERT INTO transcript_events VALUES('s1',0,\(text),\(blob),\(header.utf8.count))")
            try store.execute("INSERT INTO transcript_events VALUES('s1',1,\(OpenClawTestStore.literal(message)),NULL,\(message.utf8.count))")
        }
        return try store.records()
    }

}
