import XCTest
@testable import Egasu

final class JunieCollectionReviewTests: XCTestCase {
    func testRegistryHonorsConfiguredJunieHomeAndDefaultHome() async throws {
        for useOverride in [false, true] {
            let home = try UsageRecordFixture.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: home) }
            let custom = home.appendingPathComponent("custom-junie")
            try UsageRecordFixture.write(
                try event(["inputTokens": 900, "outputTokens": 10]),
                to: home.appendingPathComponent(".junie/sessions/default/events.jsonl")
            )
            try UsageRecordFixture.write(
                try event(["inputTokens": 100, "outputTokens": 20]),
                to: custom.appendingPathComponent("sessions/custom/events.jsonl")
            )
            let environment = FakeEnvironment(useOverride ? ["JUNIE_HOME": custom.path] : [:])
            let collector = try XCTUnwrap(
                UsageSourceCollectors.make(environment: environment, home: home).first { $0 is JunieUsageCollector }
            )
            let result = try await collect(collector)
            await collector.flushCache()

            XCTAssertEqual(result.readFailureCount, 0)
            XCTAssertEqual(result.records.count, 1)
            XCTAssertEqual(result.records.first?.sessionID, useOverride ? "custom" : "default")
            XCTAssertEqual(result.records.first?.totalTokens, useOverride ? 120 : 910)
            XCTAssertNil(result.records.first?.providerID)
        }
    }

    func testForkCopiesCountOnceWithoutMergingIndependentSessions() async throws {
        let root = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try event(["inputTokens": 100, "outputTokens": 20, "cacheInputTokens": 30, "cacheCreateTokens": 10])
        let second = try event(["inputTokens": 50, "outputTokens": 10], timestamp: 1_793_494_801_000)
        let third = try event(["inputTokens": 20, "outputTokens": 10], timestamp: 1_793_494_802_000)
        try UsageRecordFixture.write(first, to: root.appendingPathComponent("main/events.jsonl"))
        try UsageRecordFixture.write(first + "\n" + second, to: root.appendingPathComponent("branch/events.jsonl"))
        try UsageRecordFixture.write(first + "\n" + second + "\n" + third,
                                     to: root.appendingPathComponent("leaf/events.jsonl"))
        try UsageRecordFixture.write(first, to: root.appendingPathComponent("independent/events.jsonl"))
        try UsageRecordFixture.write(#"{"forkedFrom":"main"}"#,
                                     to: root.appendingPathComponent("branch/session_metadata.json"))
        try UsageRecordFixture.write(#"{"forkedFrom":"branch"}"#,
                                     to: root.appendingPathComponent("leaf/session_metadata.json"))

        let result = try await collect(JunieUsageCollector(root: root, scanner: IncrementalJSONLScanner()))

        XCTAssertEqual(result.readFailureCount, 0)
        XCTAssertEqual(result.records.count, 4)
        XCTAssertEqual(result.records.reduce(0) { $0 + $1.totalTokens }, 410)
        XCTAssertEqual(result.records.filter { $0.sessionID == "independent" }.count, 1)
        XCTAssertTrue(result.records.allSatisfy { $0.responseID == nil })
        let leaf = try XCTUnwrap(result.records.first { $0.tokens?.input == 20 })
        XCTAssertEqual(leaf.parentSession, "branch")
    }

    func testForkMetadataChangesApplyWithoutChangingCachedEvents() async throws {
        let root = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let row = try event(["inputTokens": 100, "outputTokens": 20])
        let branch = root.appendingPathComponent("branch/events.jsonl")
        let metadata = root.appendingPathComponent("branch/session_metadata.json")
        try UsageRecordFixture.write(row, to: root.appendingPathComponent("main/events.jsonl"))
        try UsageRecordFixture.write(row, to: branch)
        let initialValues = try branch.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let collector = JunieUsageCollector(root: root, scanner: IncrementalJSONLScanner())

        let independent = try await collect(collector)
        XCTAssertEqual(independent.records.count, 2)

        try UsageRecordFixture.write(#"{"forkedFrom":"main"}"#, to: metadata)
        let forked = try await collect(collector)
        XCTAssertEqual(forked.records.count, 1)
        XCTAssertEqual(forked.records.first?.totalTokens, 120)

        try UsageRecordFixture.write("{}", to: metadata)
        let separated = try await collect(collector)
        XCTAssertEqual(separated.records.count, 2)
        XCTAssertTrue(separated.records.allSatisfy { $0.parentSession == nil })
        let finalValues = try branch.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        XCTAssertEqual(finalValues.fileSize, initialValues.fileSize)
        XCTAssertEqual(finalValues.contentModificationDate, initialValues.contentModificationDate)
    }

    func testForkWithMissingParentKeepsItsRecordedUsage() async throws {
        let root = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try UsageRecordFixture.write(try event(["inputTokens": 100, "outputTokens": 20]),
                                     to: root.appendingPathComponent("branch/events.jsonl"))
        try UsageRecordFixture.write(#"{"forkedFrom":"missing-parent"}"#,
                                     to: root.appendingPathComponent("branch/session_metadata.json"))

        let result = try await collect(JunieUsageCollector(root: root, scanner: IncrementalJSONLScanner()))

        XCTAssertEqual(result.readFailureCount, 0)
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records.first?.totalTokens, 120)
        XCTAssertEqual(result.records.first?.parentSession, "missing-parent")
    }

    func testInvalidForkMetadataKeepsRawRecordsAndReportsFailure() async throws {
        let root = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try UsageRecordFixture.write(try event(["inputTokens": 100, "outputTokens": 20]),
                                     to: root.appendingPathComponent("branch/events.jsonl"))
        try UsageRecordFixture.write(#"{"forkedFrom":17}"#,
                                     to: root.appendingPathComponent("branch/session_metadata.json"))
        let diagnostics = DiagnosticEventRecorder()

        let result = try await collect(JunieUsageCollector(root: root, scanner: IncrementalJSONLScanner()))

        XCTAssertEqual(result.readFailureCount, 1)
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records.first?.totalTokens, 120)
        XCTAssertTrue(result.records.first?.issues.contains(.invalidMetadata) == true)
        XCTAssertNil(result.records.first?.parentSession)
        XCTAssertEqual(diagnostics.events.count, 1)
        XCTAssertEqual(diagnostics.events.first?.operation, .historyScan)
        XCTAssertEqual(diagnostics.events.first?.result, .degraded)
    }

    func testSamePromptCanContainMultipleUsageResponses() throws {
        let first = try event(["inputTokens": 100, "outputTokens": 20])
        let second = try event(["inputTokens": 50, "outputTokens": 10], timestamp: 1_793_494_801_000)
        let parsed = try JunieSessionParser.parse(Data((first + "\n" + second).utf8), path: "/fixture/session/events.jsonl")
        let result = UsageRecordDeduplicator.records(parsed)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.reduce(0) { $0 + $1.totalTokens }, 180)
        XCTAssertTrue(result.allSatisfy { $0.responseID == nil })
    }

    func testIdenticalUsageAtDistinctTimestampsRemainsSeparate() throws {
        let values: [String: Any] = ["inputTokens": 100, "outputTokens": 20]
        let first = try event(values)
        let second = try event(values, timestamp: 1_793_494_801_000)
        let parsed = try JunieSessionParser.parse(Data((first + "\n" + second).utf8), path: "/fixture/session/events.jsonl")
        let result = UsageRecordDeduplicator.records(parsed)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.reduce(0) { $0 + $1.totalTokens }, 240)
        XCTAssertEqual(result[0].id, result[1].id)
        XCTAssertNotEqual(result[0].timestamp, result[1].timestamp)
    }

    func testMixedUsageArrayKeepsValidEntriesAndOriginalIndexes() async throws {
        let root = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let usage: [String: Any] = ["inputTokens": 100, "outputTokens": 20, "cost": 0.1, "model": "fixture-model"]
        let usages: [Any] = [usage, NSNull(), "broken", usage]
        let object: [String: Any] = [
            "kind": "SessionA2uxEvent", "timestampMs": 1_793_494_800_000,
            "event": ["agentEvent": ["kind": "LlmResponseMetadataEvent", "modelUsage": usages]]
        ]
        let row = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        try UsageRecordFixture.write(row, to: root.appendingPathComponent("session/events.jsonl"))
        let diagnostics = DiagnosticEventRecorder()

        let result = try await collect(JunieUsageCollector(root: root, scanner: IncrementalJSONLScanner()))

        XCTAssertEqual(result.readFailureCount, 0)
        XCTAssertEqual(result.records.count, 4)
        let valid = result.records.filter { $0.issues.isEmpty }
        XCTAssertEqual(valid.count, 2)
        XCTAssertEqual(valid.reduce(0) { $0 + $1.totalTokens }, 240)
        XCTAssertEqual(valid.compactMap(\.recordedCostUSD).reduce(0, +), 0.2, accuracy: 1e-9)
        XCTAssertTrue(valid.contains { $0.id?.hasSuffix(":0") == true })
        XCTAssertTrue(valid.contains { $0.id?.hasSuffix(":3") == true })
        let invalid = result.records.filter { $0.issues.contains(.invalidMetadata) }
        XCTAssertEqual(Set(invalid.compactMap(\.id)), ["invalid:1", "invalid:2"])
        XCTAssertTrue(invalid.allSatisfy { $0.timestamp != nil && $0.sessionID == "session" })
        XCTAssertEqual(diagnostics.events, [DiagnosticEvent(.historyScan, result: .degraded, category: .decoding)])
    }

    func testCatalogCostsPreserveRawValuesWithoutClaimingReportedBilling() throws {
        let rows = try [
            event(["inputTokens": 100, "outputTokens": 20, "cost": 0.12]),
            event(["inputTokens": 100, "outputTokens": 20, "cost": 0], timestamp: 1_793_494_801_000),
            event(["inputTokens": 100, "outputTokens": 20], timestamp: 1_793_494_802_000),
            event(["inputTokens": 100, "outputTokens": 20, "cost": NSNull()], timestamp: 1_793_494_803_000)
        ].joined(separator: "\n")
        let records = try JunieSessionParser.parse(Data(rows.utf8), path: "/fixture/session/events.jsonl")

        XCTAssertEqual(records.map(\.recordedCostUSD), [0.12, 0, nil, nil])
        XCTAssertTrue(records.allSatisfy { $0.costOrigin == .estimated && $0.zeroCostIsUnknown })
        XCTAssertTrue(records.allSatisfy { $0.providerID == nil && $0.issues.isEmpty })

        var estimated = try XCTUnwrap(records.first)
        estimated.providerID = "anthropic"
        let reportedOnly = try XCTUnwrap(UsageHistoryBuilder.scan(
            .init(records: [estimated]), providerID: "claude", since: .distantPast,
            pricing: .empty, allowEstimates: false
        ))
        XCTAssertEqual(reportedOnly.series.daily.first?.totalTokens, 120)
        XCTAssertNil(reportedOnly.series.daily.first?.costUSD)

        var zero = records[1]
        zero.providerID = "anthropic"
        let repriced = try XCTUnwrap(UsageHistoryBuilder.scan(
            .init(records: [zero]), providerID: "claude", since: .distantPast, pricing: .empty,
            costEstimator: { _, _ in .priced(2) }
        ))
        XCTAssertEqual(zero.recordedCostUSD, 0)
        XCTAssertEqual(repriced.series.daily.first?.costUSD, 2)
    }

    func testMissingTokenBucketsAreIncompleteButExplicitZeroIsValid() async throws {
        let root = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let rows = try [
            event(["cost": 0.12]),
            event(["inputTokens": NSNull(), "outputTokens": NSNull(), "cacheInputTokens": NSNull(),
                   "cacheCreateTokens": NSNull()], timestamp: 1_793_494_801_000),
            event(["inputTokens": 0, "outputTokens": 0, "cacheInputTokens": 0, "cacheCreateTokens": 0],
                  timestamp: 1_793_494_802_000),
            event(["inputTokens": NSNull(), "cacheInputTokens": 30], timestamp: 1_793_494_803_000)
        ].joined(separator: "\n")
        try UsageRecordFixture.write(rows, to: root.appendingPathComponent("session/events.jsonl"))
        let diagnostics = DiagnosticEventRecorder()

        let result = try await collect(JunieUsageCollector(root: root, scanner: IncrementalJSONLScanner()))

        XCTAssertEqual(result.readFailureCount, 0)
        XCTAssertEqual(result.records.count, 4)
        XCTAssertEqual(result.records.filter { $0.issues.contains(.invalidMetadata) }.count, 2)
        XCTAssertTrue(result.records.prefix(2).allSatisfy { $0.tokens == nil })
        XCTAssertEqual(result.records[0].recordedCostUSD, 0.12)
        XCTAssertNotNil(result.records[2].tokens)
        XCTAssertTrue(result.records[2].issues.isEmpty)
        XCTAssertEqual(result.records[2].totalTokens, 0)
        XCTAssertTrue(result.records[3].issues.isEmpty)
        XCTAssertEqual(result.records[3].tokens?.cacheRead, 30)
        XCTAssertEqual(result.records[3].totalTokens, 30)
        XCTAssertEqual(diagnostics.events, [DiagnosticEvent(.historyScan, result: .degraded, category: .decoding)])
    }

    func testJunieHomeNormalizesTildeAndBlankOverride() async throws {
        let home = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        try UsageRecordFixture.write(try event(["inputTokens": 10, "outputTokens": 1]),
                                     to: home.appendingPathComponent(".junie/sessions/default/events.jsonl"))
        try UsageRecordFixture.write(try event(["inputTokens": 20, "outputTokens": 2]),
                                     to: home.appendingPathComponent("custom/sessions/override/events.jsonl"))
        for (value, session) in [("  ~/custom  ", "override"), ("  ", "default")] {
            let collector = UsageSourceCollectors.junieCollector(
                environment: FakeEnvironment(["JUNIE_HOME": value]), home: home,
                scanner: IncrementalJSONLScanner()
            )
            let result = try await collect(collector)
            XCTAssertEqual(result.records.map(\.sessionID), [session])
        }
    }

    func testNullPreferredAliasesUseValidFallbackAndReasoningNullIsAbsent() throws {
        let row = try event([
            "inputTokens": NSNull(), "input": 100,
            "outputTokens": NSNull(), "output": 20,
            "cacheInputTokens": NSNull(), "cacheRead": 30,
            "cacheCreateTokens": NSNull(), "cacheWrite": 10,
            "reasoningTokens": NSNull()
        ])
        let record = try XCTUnwrap(JunieSessionParser.parse(Data(row.utf8), path: "/fixture/session/events.jsonl").first)
        XCTAssertEqual(record.totalTokens, 160)
        XCTAssertEqual(record.tokens?.cacheRead, 30)
        XCTAssertNil(record.reasoningTokens)
        XCTAssertTrue(record.issues.isEmpty)
    }

    func testMalformedMiddleLineKeepsCompletedEventsAndUnfinishedTailIsDeferred() throws {
        let first = try event(["inputTokens": 10, "outputTokens": 1])
        let second = try event(["inputTokens": 20, "outputTokens": 2], timestamp: 1_793_494_801_000)
        let data = Data((first + "\n{" + "\n" + second + "\n{\"kind\":").utf8)
        let records = try JunieSessionParser.parse(data, path: "/fixture/session/events.jsonl")
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records.filter { $0.kind == "invalid-line" && $0.issues.contains(.invalidMetadata) }.count, 1)
        XCTAssertEqual(records.reduce(0) { $0 + $1.totalTokens }, 33)
    }

    private func collect(_ collector: any UsageCollecting) async throws -> UsageCollection {
        let collected = await UsageCollectionCoordinator(collectors: [collector]).collect(since: .distantPast)
        return try XCTUnwrap(collected)
    }

    private func event(_ values: [String: Any], timestamp: Int = 1_793_494_800_000) throws -> String {
        var usage = values
        usage["model"] = "fixture-model"
        let object: [String: Any] = [
            "kind": "SessionA2uxEvent", "timestampMs": timestamp,
            "event": ["agentEvent": [
                "kind": "LlmResponseMetadataEvent", "requestId": "prompt-1", "modelUsage": [usage]
            ]]
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
}
