import libzstd
import XCTest
@testable import OpenUsage

@MainActor
final class DeepSeekCollectionReviewTests: XCTestCase {
    func testModernForkUsesLastInheritedMarkerAndKeepsOnlyNewCalls() async throws {
        for version in [2, 4] {
            let parent = [header(version, id: "parent"), route(0), message(1, input: 100)]
            let fork = [
                header(version, id: "fork", seeded: true), route(0), message(1, input: 100),
                event("session/end-seed", 2, ["inherited": true]), message(3, input: 200),
                event("session/end-seed", 4, ["inherited": true]),
                event("session/end-seed", 5, ["inherited": false]), message(6, input: 20)
            ]
            let result = try await UsageRecordFixture.collect([
                "parent/session.v\(version).jsonl": String(decoding: encode(parent), as: UTF8.self),
                "fork/session.v\(version).jsonl": String(decoding: encode(fork), as: UTF8.self)
            ], sourceID: "dsh", parse: DeepSeekSessionParser.parse)
            XCTAssertEqual(result.records.count, 2)
            XCTAssertEqual(result.records.reduce(0) { $0 + $1.totalTokens }, 120)
            XCTAssertTrue(result.records.allSatisfy { $0.issues.isEmpty })
        }
    }

    func testSeededHeaderAndInheritedMarkersMustAgree() throws {
        for version in [2, 4] {
            let cases = [
                [header(version, seeded: true), route(0), message(1, input: 100)],
                [header(version), event("session/end-seed", 0, ["inherited": true])]
            ]
            for rows in cases {
                XCTAssertThrowsError(try parse(rows, version: version))
            }
            var invalid = header(version)
            invalid["isSeeded"] = 0
            XCTAssertThrowsError(try parse([invalid], version: version))
            invalid["isSeeded"] = nil
            XCTAssertThrowsError(try parse([invalid], version: version))
        }
    }

    func testLegacySeedLengthExcludesCopiedUsage() throws {
        for version in [0, 1] {
            var legacy = header(version)
            legacy["seedLength"] = 2
            let result = try parse([legacy, route(0), message(1, input: 100), message(2, input: 20)], version: version)
            XCTAssertEqual(result.count, 1)
            XCTAssertEqual(result.first?.totalTokens, 20)
            XCTAssertEqual(result.first?.providerID, "anthropic")
        }
    }

    func testCompactionUsesItsExplicitRouteWithoutChangingTheMainRequestRoute() throws {
        let compaction = event("compaction/summary", 2, [
            "compactionId": "summary", "provider": "deepseek", "model": "summary-model",
            "source": ["provider": "anthropic", "model": "wrong-model"], "usage": usage(20)
        ])
        let rows = [header(4), route(0), message(1, input: 100), compaction, message(3, input: 10, step: 2)]
        let result = try parse(rows)
        let summary = try XCTUnwrap(result.first { $0.kind == "compaction" })
        XCTAssertEqual(summary.providerID, "deepseek")
        XCTAssertEqual(summary.model, "summary-model")
        XCTAssertNil(summary.responseModel)
        XCTAssertEqual(result.last?.providerID, "anthropic")
        XCTAssertEqual(result.last?.model, "main-model")
        let scan = try XCTUnwrap(UsageHistoryBuilder.scan(.init(records: result), providerID: "claude", since: .distantPast, pricing: .empty))
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 110)
    }

    func testCompactionDoesNotGuessMissingProviderOrModel() throws {
        let rows = [header(4), route(0), event("compaction/summary", 1, ["usage": usage(20)])]
        let record = try XCTUnwrap(parse(rows).first)
        XCTAssertNil(record.providerID)
        XCTAssertNil(record.model)
        XCTAssertEqual(record.totalTokens, 20)
    }

    func testLegacyFailedAndCancelledUsageSurvivesRetryAndSettlement() throws {
        for version in [0, 1] {
            let rows = [
                header(version), route(0), chunk(1, input: 10, output: 1), chunk(2, input: 100, output: 10),
                event("llm/retry", 3, ["turn": 1, "step": 1]),
                event("llm/retry-started", 4, ["turn": 1, "step": 1]),
                chunk(5, input: 20, output: 2), settlement(6, input: 30, output: 3, sources: [5]),
                event("llm/retry-started", 7, ["turn": 1, "step": 1]), chunk(8, input: 40, output: 4),
                event("step/end", 9, ["turn": 1, "step": 1]), chunk(10, input: 50, output: 5)
            ]
            let result = try parse(rows, version: version)
            XCTAssertEqual(result.count, 4)
            XCTAssertEqual(result.map(\.totalTokens), [110, 33, 44, 55])
            XCTAssertTrue(result.allSatisfy { $0.providerID == "anthropic" && $0.issues.isEmpty })
        }
    }

    func testLegacyFinishedStreamStartsANewAttemptEvenWithoutRetryMarker() throws {
        for version in [0, 1] {
            let rows = [
                header(version), route(0), chunk(1, input: 100),
                event("assistant/chunk", 2, ["turn": 1, "step": 1, "chunk": ["type": "finish"]]),
                event("assistant/chunk", 3, ["turn": 1, "step": 1, "chunk": ["type": "text-delta", "text": "next"]]),
                chunk(4, input: 20), settlement(5, input: 30, sources: [[3, 4]] as [[Int]])
            ]
            let result = try parse(rows, version: version)
            XCTAssertEqual(result.map(\.totalTokens), [100, 30])
        }
    }

    func testLegacyPackedChunksRespectFinishedAttemptBoundary() throws {
        let packed: [String: Any] = [
            "type": "text-chunks", "seq0": 3, "time0": timestamp,
            "data": ["turn": 1, "step": 1, "index": 0, "dt": [], "texts": ["next"]]
        ]
        let rows = [
            header(1), route(0), chunk(1, input: 100),
            event("assistant/chunk", 2, ["turn": 1, "step": 1, "chunk": ["type": "finish"]]),
            packed, chunk(4, input: 20)
        ]
        XCTAssertEqual(try parse(rows, version: 1).map(\.totalTokens), [100, 20])
    }

    func testLegacySettlementWithoutUsageKeepsTheLastChunkAndDisjointCacheBuckets() throws {
        var sample = usage(100, output: 20)
        sample["cacheReadTokens"] = 30
        sample["cacheWriteTokens"] = 10
        sample["reasoningTokens"] = 5
        var settled = event("assistant/message", 2, ["turn": 1, "step": 1, "message": ["id": "settled"]])
        settled["sourceEventSeqs"] = [1]
        let rows = [
            header(1), route(0),
            event("assistant/chunk", 1, ["turn": 1, "step": 1, "chunk": ["type": "usage", "usage": sample]]),
            settled
        ]
        let result = try parse(rows, version: 1)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.totalTokens, 160)
        XCTAssertEqual(result.first?.tokens?.input, 100)
        XCTAssertEqual(result.first?.tokens?.output, 20)
        XCTAssertEqual(result.first?.reasoningTokens, 5)
    }

    func testLegacyUnrelatedSettlementKeepsTheUnsettledFailedCall() throws {
        for version in [0, 1] {
            let prefix = [header(version), route(0), chunk(1, input: 100)]
            let result = try parse(prefix + [settlement(2, input: 20, sources: [])], version: version)
            XCTAssertEqual(result.map(\.totalTokens), [100, 20])
            XCTAssertThrowsError(try parse(prefix + [message(2, input: 20)], version: version))
            XCTAssertThrowsError(try parse(prefix + [settlement(2, input: 20, sources: [0])], version: version))
        }
    }

    func testNoncanonicalGenerationNamesCannotHideTheSupportedFile() throws {
        let directory = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let supported = directory.appendingPathComponent("session.v4.jsonl")
        try UsageRecordFixture.write(encode([header(4)]), to: supported)
        for name in ["session.v04.jsonl", "session.v0.jsonl", "session.v-1.jsonl", "session.v+9.jsonl", "session.v9007199254740992.jsonl", "session.V9.jsonl", "session.v9.jsonl.tmp"] {
            let file = directory.appendingPathComponent(name)
            try UsageRecordFixture.write(encode([header(4)]), to: file)
            XCTAssertFalse(DeepSeekSessionParser.isCurrentGeneration(file), name)
            XCTAssertThrowsError(try DeepSeekSessionParser.parse(encode([header(4)]), path: file.path), name)
        }
        XCTAssertTrue(DeepSeekSessionParser.isCurrentGeneration(supported))
    }

    func testFutureCanonicalGenerationFailsWithoutFallingBack() async throws {
        let directory = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try UsageRecordFixture.write(encode([header(4), route(0), message(1, input: 100)]), to: directory.appendingPathComponent("session.v4.jsonl"))
        try UsageRecordFixture.write(encode([header(5), route(0), message(1, input: 200)]), to: directory.appendingPathComponent("session.v5.jsonl"))
        let collector = UsageFileCollector(sourceID: "dsh", roots: [directory], scanner: IncrementalJSONLScanner(),
                                           includeFile: DeepSeekSessionParser.isCurrentGeneration, parse: DeepSeekSessionParser.parse)
        let result = await collector.collect(since: .distantPast)
        XCTAssertEqual(result?.records.count, 0)
        XCTAssertEqual(result?.sources.first?.completedStores, 0)
        XCTAssertEqual(result?.readFailureCount, 1)
    }

    func testHeaderVersionMustBeSupportedAndMatchTheFilename() throws {
        for version in [0, 1, 2, 3, 4] {
            XCTAssertEqual(try parse([header(version), route(0), message(1, input: 100)], version: version).count, 1)
        }
        XCTAssertThrowsError(try parse([header(3)], version: 4))
        XCTAssertThrowsError(try parse([header(5)], version: 5))
        let invalidVersions: [Any] = ["4", true, -1, NSNull()]
        for invalidVersion in invalidVersions {
            var invalid = header(4)
            invalid["version"] = invalidVersion
            XCTAssertThrowsError(try parse([invalid]))
        }
        var missing = header(4)
        missing["version"] = nil
        XCTAssertThrowsError(try parse([missing]))
        XCTAssertThrowsError(try parse([message(0, input: 100)]))
    }

    func testUnterminatedRawTailKeepsOnlyCompleteRowsAndReportsIncompleteMetadata() throws {
        let prefix = try encode([header(4), route(0), message(1, input: 100)])
        for tail in [Data(#"{"type":"assistant/message","seq":2"#.utf8), try encode([message(2, input: 200)]).dropLast()] {
            let result = try DeepSeekSessionParser.parse(prefix + tail, path: "/fixture/session.v4.jsonl")
            XCTAssertEqual(result.filter { $0.kind == "assistant" }.map(\.totalTokens), [100])
            XCTAssertEqual(result.filter { $0.issues.contains(.invalidMetadata) }.count, 1)
            let scan = try XCTUnwrap(UsageHistoryBuilder.scan(.init(records: result), providerID: "claude", since: .distantPast, pricing: .empty))
            XCTAssertEqual(scan.series.daily.first?.totalTokens, 100)
            XCTAssertEqual(scan.rejectedMetadataRows, 1)
        }
    }

    func testCompleteMalformedJSONLineStillRejectsTheFile() throws {
        let prefix = try encode([header(4), route(0), message(1, input: 100)])
        XCTAssertThrowsError(try DeepSeekSessionParser.parse(prefix + Data("{invalid}\n".utf8), path: "/fixture/session.v4.jsonl"))
        XCTAssertThrowsError(try DeepSeekSessionParser.parse(Data(#"{"type":"session""#.utf8), path: "/fixture/session.v4.jsonl"))
    }

    func testTornLastZstandardFrameKeepsCompleteDecodedRows() throws {
        let first = try compress(encode([header(4), route(0), message(1, input: 100)]))
        let second = try compress(encode([message(2, input: 20, step: 2)]) + Data(#"{"type":"assistant/message""#.utf8))
        let torn = first + second.dropLast()
        let decoded = try UsageZstandard.decodePrefix(torn)
        XCTAssertTrue(decoded.incomplete)
        XCTAssertThrowsError(try UsageZstandard.decode(torn))
        let result = try DeepSeekSessionParser.parse(torn, path: "/fixture/session.v4.jsonl.zstd")
        XCTAssertEqual(result.filter { $0.kind == "assistant" }.map(\.totalTokens), [100, 20])
        XCTAssertEqual(result.filter { $0.issues.contains(.invalidMetadata) }.count, 1)

        let headerOnlyTail = first + second.prefix(6)
        let retained = try DeepSeekSessionParser.parse(headerOnlyTail, path: "/fixture/session.v4.jsonl.zstd")
        XCTAssertEqual(retained.filter { $0.kind == "assistant" }.map(\.totalTokens), [100])
        XCTAssertEqual(retained.filter { $0.issues.contains(.invalidMetadata) }.count, 1)
    }

    func testCompleteZstandardChecksumFailureAndSizeLimitRemainErrors() throws {
        var compressed = try compress(encode([header(4), route(0), message(1, input: 100)]))
        XCTAssertFalse(try UsageZstandard.decodePrefix(compressed).incomplete)
        XCTAssertThrowsError(try UsageZstandard.decodePrefix(compressed, maximumBytes: 10))
        compressed[compressed.count - 1] ^= 1
        XCTAssertThrowsError(try UsageZstandard.decodePrefix(compressed))
        XCTAssertThrowsError(try DeepSeekSessionParser.parse(compressed, path: "/fixture/session.v4.jsonl.zstd"))
    }

    private var timestamp: Int { 1_793_494_800_000 }

    private func header(_ version: Int, id: String = "session", seeded: Bool = false) -> [String: Any] {
        var value: [String: Any] = ["type": "session", "version": version, "id": id, "createdAt": timestamp, "delegationDepth": 0]
        if version >= 2 { value["isSeeded"] = seeded }
        return value
    }

    private func event(_ type: String, _ seq: Int, _ data: [String: Any]) -> [String: Any] {
        ["type": type, "seq": seq, "time": timestamp + seq, "data": data]
    }

    private func route(_ seq: Int) -> [String: Any] {
        event("request/header", seq, ["header": ["config": ["provider": "anthropic", "model": "main-model"]]])
    }

    private func usage(_ input: Int, output: Int = 0) -> [String: Any] {
        ["inputTokens": input, "outputTokens": output]
    }

    private func message(_ seq: Int, input: Int, output: Int = 0, step: Int = 1) -> [String: Any] {
        event("assistant/message", seq, ["turn": 1, "step": step, "message": ["id": "message-\(seq)"], "usage": usage(input, output: output)])
    }

    private func chunk(_ seq: Int, input: Int, output: Int = 0) -> [String: Any] {
        event("assistant/chunk", seq, ["turn": 1, "step": 1, "chunk": ["type": "usage", "usage": usage(input, output: output)]])
    }

    private func settlement(_ seq: Int, input: Int, output: Int = 0, sources: [Any]) -> [String: Any] {
        var value = message(seq, input: input, output: output)
        value["sourceEventSeqs"] = sources
        return value
    }

    private func encode(_ rows: [[String: Any]]) throws -> Data {
        try rows.reduce(into: Data()) { data, row in
            data.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
            data.append(0x0A)
        }
    }

    private func parse(_ rows: [[String: Any]], version: Int = 4) throws -> [UsageRecord] {
        let filename = version == 0 ? "session.jsonl" : "session.v\(version).jsonl"
        return try DeepSeekSessionParser.parse(encode(rows), path: "/fixture/\(filename)")
    }

    private func compress(_ input: Data) throws -> Data {
        guard let context = ZSTD_createCCtx() else { throw CocoaError(.coderInvalidValue) }
        defer { ZSTD_freeCCtx(context) }
        guard ZSTD_isError(ZSTD_CCtx_setParameter(context, ZSTD_c_checksumFlag, 1)) == 0 else {
            throw CocoaError(.coderInvalidValue)
        }
        var output = Data(count: ZSTD_compressBound(input.count))
        let capacity = output.count
        let count = input.withUnsafeBytes { bytes in
            output.withUnsafeMutableBytes { target in ZSTD_compress2(context, target.baseAddress, capacity, bytes.baseAddress, bytes.count) }
        }
        guard ZSTD_isError(count) == 0 else { throw CocoaError(.coderInvalidValue) }
        output.count = count
        return output
    }
}
