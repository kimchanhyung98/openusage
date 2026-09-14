import XCTest
@testable import OpenUsage

final class CodexReplayNumericSafetyTests: XCTestCase {
    private let timestamp = "2026-09-12T10:00:00Z"

    func testStaleCumulativeSnapshotCannotUndoANewerTurnModel() {
        let content = staleModelReplay()
        let events = CodexLogUsageScanner.parseFile(Data(content.utf8))
        XCTAssertEqual(events.map(\.model), ["gpt-5.4", "gpt-5.5"])
        XCTAssertEqual(events.map(\.total), [100, 20])
        XCTAssertEqual(events.map(\.invalidNumericValues), [false, false])
    }

    func testVersionNineCacheReparsesModelAfterStaleSnapshot() async throws {
        let home = try CodexLogFixture.makeHome(files: ["sessions/stale.jsonl": staleModelReplay()])
        defer { try? FileManager.default.removeItem(at: home) }
        let files = JSONLScanning.jsonlFiles(under: home.appendingPathComponent("sessions"))
        let directory = home.appendingPathComponent("cache")
        let old = IncrementalJSONLScanner<CodexLogUsageScanner.Event>(persistence:
            .init(namespace: "codex", schemaVersion: 9, directory: directory, writeDebounce: .milliseconds(1)))
        let wrongModel = CodexLogUsageScanner.Event(
            timestamp: try XCTUnwrap(OpenUsageISO8601.date(from: timestamp)), model: "gpt-5.4",
            input: 20, cached: 0, output: 0, reasoning: 0, total: 20
        )
        _ = await old.items(from: files, since: .distantPast, cacheIdentity: "stale-model") { _ in [wrongModel] }
        await old.waitForPendingWritesForTesting()
        let scanner = IncrementalJSONLScanner<CodexLogUsageScanner.Event>(persistence:
            .init(namespace: "codex", schemaVersion: CodexLogUsageScanner.cacheSchemaVersion, directory: directory))
        let events = await scanner.items(from: files, since: .distantPast, cacheIdentity: "stale-model", parse: CodexLogUsageScanner.parseFile)
        XCTAssertEqual(events?.map(\.model), ["gpt-5.4", "gpt-5.5"])
        await scanner.waitForPendingWritesForTesting()
    }

    private func staleModelReplay() -> String {
        [
            CodexLogFixture.tokenCount(timestamp: timestamp, totals: CodexLogFixture.usage(input: 100, output: 0), model: "gpt-5.4"),
            CodexLogFixture.turnContext(timestamp: timestamp, model: "gpt-5.5"),
            CodexLogFixture.tokenCount(timestamp: timestamp, totals: CodexLogFixture.usage(input: 100, output: 0), model: "gpt-5.4"),
            CodexLogFixture.tokenCount(timestamp: timestamp, totals: CodexLogFixture.usage(input: 120, output: 0))
        ].joined(separator: "\n")
    }

    func testCorruptLastUsageIsNotRecoveredThroughCurrentOrFutureTotals() {
        let text = [
            CodexLogFixture.tokenCount(timestamp: timestamp, totals: CodexLogFixture.usage(input: 100, output: 0), model: "gpt-5.4"),
            CodexLogFixture.tokenCount(timestamp: timestamp, last: ["input_tokens": -1],
                totals: CodexLogFixture.usage(input: 150, output: 0), model: "gpt-5.5"),
            CodexLogFixture.tokenCount(timestamp: timestamp, totals: CodexLogFixture.usage(input: 170, output: 0))
        ].joined(separator: "\n")
        let events = CodexLogUsageScanner.parseFile(Data(text.utf8))
        XCTAssertEqual(events.map(\.total), [100, 0, 20])
        XCTAssertEqual(events.map(\.invalidNumericValues), [false, true, false])
        XCTAssertEqual(events.last?.model, "gpt-5.5")
        let scan = CodexLogUsageScanner.aggregate(events: events, since: .distantPast, pricing: TestPricing.bundled)
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 120)
        XCTAssertEqual(scan.rejectedNumericRows, 1)
        XCTAssertNotNil(scan.numericWarning)
    }

    func testCorruptParentReplayRequiresANewBaselineForEveryChildGate() {
        let metadata = [
            CodexLogFixture.subagentSessionMeta(timestamp: timestamp),
            CodexLogFixture.forkSessionMeta(timestamp: timestamp),
            #"{"type":"session_meta","payload":{"forked_from_id":"parent"}}"#,
        ]
        for meta in metadata {
            for corrupt in [
                ["input_tokens": -1, "output_tokens": 50],
                ["input_tokens": Int.max, "output_tokens": 50],
            ] {
                let events = CodexLogUsageScanner.parseFile(Data(rollout(meta: meta, corrupt: corrupt).utf8))
                XCTAssertEqual(events.map(\.total), [0])
                XCTAssertEqual(events.map(\.input), [0])
                XCTAssertEqual(events.map(\.output), [0])
                XCTAssertEqual(events.map(\.invalidNumericValues), [true])
                let scan = CodexLogUsageScanner.aggregate(
                    events: events, since: .distantPast, pricing: TestPricing.bundled
                )
                XCTAssertTrue(scan.series.daily.isEmpty)
                XCTAssertEqual(scan.rejectedNumericRows, 1)
            }
        }
    }

    func testVersionFiveReplayCacheReparsesAndPersistsUncertainUsage() async throws {
        let content = rollout(
            meta: CodexLogFixture.subagentSessionMeta(timestamp: timestamp),
            corrupt: ["input_tokens": -1, "output_tokens": 50]
        )
        try await assertReplayCacheReparsed(content: content, oldVersion: 5)
    }

    func testVersionSixCacheReparsesMissingReplayTotals() async throws {
        let content = missingTotalsReplay(
            meta: CodexLogFixture.subagentSessionMeta(timestamp: timestamp), seed: 100
        ).split(separator: "\n").dropLast().joined(separator: "\n")
        try await assertReplayCacheReparsed(content: content, oldVersion: 6)
    }

    private func assertReplayCacheReparsed(content: String, oldVersion: Int) async throws {
        let home = try CodexLogFixture.makeHome(files: ["sessions/replay.jsonl": content])
        defer { try? FileManager.default.removeItem(at: home) }
        let files = JSONLScanning.jsonlFiles(under: home.appendingPathComponent("sessions"))
        let directory = home.appendingPathComponent("cache")
        let now = try XCTUnwrap(OpenUsageISO8601.date(from: timestamp))
        let old = IncrementalJSONLScanner<CodexLogUsageScanner.Event>(
            persistence: .init(namespace: "codex", schemaVersion: oldVersion, directory: directory, writeDebounce: .milliseconds(1))
        )
        let poisoned = CodexLogUsageScanner.Event(
            timestamp: now, model: "gpt-5.4", input: 100, cached: 0, output: 0, reasoning: 0,
            total: 100
        )
        _ = await old.items(from: files, since: .distantPast, cacheIdentity: "replay-account") { _ in [poisoned] }
        await old.waitForPendingWritesForTesting()

        let persistence = JSONLScanCachePersistence(
            namespace: "codex", schemaVersion: CodexLogUsageScanner.cacheSchemaVersion,
            directory: directory, writeDebounce: .milliseconds(1)
        )
        let rebuilt = IncrementalJSONLScanner<CodexLogUsageScanner.Event>(persistence: persistence)
        let scanner = CodexLogUsageScanner(
            incrementalScanner: rebuilt, cacheIdentityOverride: "replay-account", rootsOverride: [home]
        )
        let scan = await scanner.scan(now: now, pricing: TestPricing.bundled)
        XCTAssertTrue(scan?.series.daily.isEmpty == true)
        XCTAssertNil(scan?.usageHistory)
        XCTAssertEqual(scan?.rejectedNumericRows, 1)
        await rebuilt.waitForPendingWritesForTesting()

        let relaunched = IncrementalJSONLScanner<CodexLogUsageScanner.Event>(persistence: persistence)
        let cached = await relaunched.items(
            from: files, since: .distantPast, cacheIdentity: "replay-account"
        ) { _ in [] }
        XCTAssertEqual(cached?.map(\.total), [0])
        XCTAssertEqual(cached?.map(\.invalidNumericValues), [true])
        await relaunched.waitForPendingWritesForTesting()
    }

    func testCorruptReplayCannotDoubleCountParentUsageAfterRecovery() throws {
        let childText = rollout(
            meta: CodexLogFixture.subagentSessionMeta(timestamp: timestamp),
            corrupt: ["input_tokens": -1, "output_tokens": 50]
        ) + "\n" + CodexLogFixture.tokenCount(
            timestamp: "2026-09-12T10:02:00Z", totals: CodexLogFixture.usage(input: 250, output: 50)
        )
        let parentText = [
            CodexLogFixture.turnContext(timestamp: timestamp, model: "gpt-5.4"),
            CodexLogFixture.tokenCount(timestamp: "2026-09-12T09:58:00Z", totals: CodexLogFixture.usage(input: 100, output: 50)),
            CodexLogFixture.tokenCount(timestamp: "2026-09-12T09:59:00Z", totals: CodexLogFixture.usage(input: 180, output: 50)),
        ].joined(separator: "\n")
        let parent = CodexLogUsageScanner.parseFile(Data(parentText.utf8))
        let child = CodexLogUsageScanner.parseFile(Data(childText.utf8))
        let scan = CodexLogUsageScanner.aggregate(events: parent + child, since: .distantPast, pricing: TestPricing.bundled)
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 280)
        XCTAssertEqual(scan.rejectedNumericRows, 1)
        XCTAssertNotNil(scan.numericWarning)
    }

    func testValidLastOrRestoredReplayBaselinePreservesKnownLiveUsage() {
        for meta in [CodexLogFixture.subagentSessionMeta(timestamp: timestamp), CodexLogFixture.forkSessionMeta(timestamp: timestamp),
                     #"{"type":"session_meta","payload":{"forked_from_id":"parent"}}"#] {
            for restoreReplay in [false, true] {
                let text = rollout(meta: meta, corrupt: ["input_tokens": -1],
                    last: restoreReplay ? nil : CodexLogFixture.usage(input: 20, output: 0),
                    recoveredReplay: restoreReplay ? CodexLogFixture.usage(input: 180, output: 50) : nil)
                let events = CodexLogUsageScanner.parseFile(Data(text.utf8))
                XCTAssertEqual(events.map(\.total), [20])
                XCTAssertEqual(events.map(\.invalidNumericValues), [false])
            }
        }
    }

    func testCorruptReplayWithoutLiveUsageDoesNotCreateChildWarnings() {
        let text = [CodexLogFixture.subagentSessionMeta(timestamp: timestamp),
                    CodexLogFixture.tokenCount(timestamp: timestamp, totals: ["input_tokens": -1])].joined(separator: "\n")
        let events = CodexLogUsageScanner.parseFile(Data(text.utf8))
        XCTAssertTrue(events.isEmpty)
        let scan = CodexLogUsageScanner.aggregate(events: events, since: .distantPast, pricing: TestPricing.bundled)
        XCTAssertEqual(scan.rejectedNumericRows, 0)
        XCTAssertNil(scan.numericWarning)
    }

    func testMissingReplayTotalsRequireANewBaseline() {
        for meta in [CodexLogFixture.subagentSessionMeta(timestamp: timestamp),
                     CodexLogFixture.forkSessionMeta(timestamp: timestamp),
                     #"{"type":"session_meta","payload":{"forked_from_id":"parent"}}"#] {
            for seed in [nil, 100, 200] as [Int?] {
                for totalsJSON in [nil, "null", "42", "[]"] as [String?] {
                    let text = missingTotalsReplay(meta: meta, seed: seed, totalsJSON: totalsJSON)
                    let events = CodexLogUsageScanner.parseFile(Data(text.utf8))
                    XCTAssertEqual(events.map(\.total), [0, 20])
                    XCTAssertEqual(events.map(\.invalidNumericValues), [true, false])
                    let scan = CodexLogUsageScanner.aggregate(events: events, since: .distantPast, pricing: TestPricing.bundled)
                    XCTAssertEqual(scan.series.daily.first?.totalTokens, 20)
                    XCTAssertEqual(scan.rejectedNumericRows, 1)
                }
            }
        }
    }

    func testMissingReplayTotalsRecoverOnlyFromValidCumulativeUsage() {
        for restoreReplay in [false, true] {
            let text = missingTotalsReplay(
                meta: CodexLogFixture.subagentSessionMeta(timestamp: timestamp), seed: 100,
                restoreReplay: restoreReplay, liveLastOnly: !restoreReplay
            )
            let events = CodexLogUsageScanner.parseFile(Data(text.utf8))
            XCTAssertEqual(events.map(\.total), restoreReplay ? [20, 20] : [10, 0, 20])
            XCTAssertEqual(events.map(\.invalidNumericValues), restoreReplay ? [false, false] : [false, true, false])
        }
    }

    func testMissingReplayTotalsWithoutLiveUsageDoNotWarn() {
        let text = [CodexLogFixture.subagentSessionMeta(timestamp: timestamp),
                    CodexLogFixture.tokenCount(timestamp: timestamp, last: CodexLogFixture.usage(input: 10, output: 0))]
            .joined(separator: "\n")
        XCTAssertTrue(CodexLogUsageScanner.parseFile(Data(text.utf8)).isEmpty)
    }

    func testChildWithoutReplayUsageRequiresACumulativeBaseline() {
        for meta in [CodexLogFixture.subagentSessionMeta(timestamp: timestamp),
                     CodexLogFixture.forkSessionMeta(timestamp: timestamp),
                     #"{"type":"session_meta","payload":{"forked_from_id":"parent"}}"#] {
            for lastOnly in [false, true] {
                let text = truncatedReplay(meta: meta, lastOnly: lastOnly)
                let events = CodexLogUsageScanner.parseFile(Data(text.utf8))
                XCTAssertEqual(events.map(\.total), lastOnly ? [10, 0, 20] : [0, 20])
                XCTAssertEqual(events.map(\.invalidNumericValues), lastOnly ? [false, true, false] : [true, false])
            }
        }
    }

    func testVersionSevenCacheReparsesTruncatedReplay() async throws {
        let content = truncatedReplay(meta: CodexLogFixture.subagentSessionMeta(timestamp: timestamp))
            .split(separator: "\n").dropLast().joined(separator: "\n")
        try await assertReplayCacheReparsed(content: content, oldVersion: 7)
    }

    func testRootWithoutReplayKeepsItsFirstCumulativeUsage() {
        let text = truncatedReplay(meta: #"{"type":"session_meta","payload":{"source":"cli"}}"#)
        let events = CodexLogUsageScanner.parseFile(Data(text.utf8))
        XCTAssertEqual(events.map(\.total), [200, 20])
        XCTAssertEqual(events.map(\.invalidNumericValues), [false, false])
    }

    func testRejectedUsageRetainsModelMetadataForLaterTotals() {
        for modelField in [#""model":"gpt-5.5","info":{"last_token_usage":{"input_tokens":-1}}"#,
                           #""info":{"model":"gpt-5.5","total_token_usage":{"input_tokens":-1}}"#] {
            let text = [
                CodexLogFixture.turnContext(timestamp: timestamp, model: "gpt-5.4"),
                CodexLogFixture.tokenCount(timestamp: timestamp, totals: CodexLogFixture.usage(input: 100, output: 0)),
                "{\"timestamp\":\"\(timestamp)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\(modelField)}}",
                CodexLogFixture.tokenCount(timestamp: timestamp, totals: CodexLogFixture.usage(input: 150, output: 0))
            ].joined(separator: "\n")
            let events = CodexLogUsageScanner.parseFile(Data(text.utf8))
            XCTAssertEqual(events.map(\.model), ["gpt-5.4", "", "gpt-5.5"])
            XCTAssertEqual(events.map(\.total), [100, 0, 50])
            XCTAssertEqual(events.map(\.invalidNumericValues), [false, true, false])
        }
    }

    func testVersionEightCacheReparsesModelStateAfterRejectedUsage() async throws {
        let content = [
            #"{"timestamp":"2026-09-12T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"model":"gpt-5.5","last_token_usage":{"input_tokens":-1}}}}"#,
            CodexLogFixture.tokenCount(timestamp: timestamp, totals: CodexLogFixture.usage(input: 100, output: 0))
        ].joined(separator: "\n")
        let home = try CodexLogFixture.makeHome(files: ["sessions/model.jsonl": content])
        defer { try? FileManager.default.removeItem(at: home) }
        let files = JSONLScanning.jsonlFiles(under: home.appendingPathComponent("sessions"))
        let directory = home.appendingPathComponent("cache")
        let old = IncrementalJSONLScanner<CodexLogUsageScanner.Event>(persistence:
            .init(namespace: "codex", schemaVersion: 8, directory: directory, writeDebounce: .milliseconds(1)))
        let wrongModel = CodexLogUsageScanner.Event(
            timestamp: try XCTUnwrap(OpenUsageISO8601.date(from: timestamp)), model: "gpt-5",
            input: 100, cached: 0, output: 0, reasoning: 0, total: 100
        )
        _ = await old.items(from: files, since: .distantPast, cacheIdentity: "model-account") { _ in [wrongModel] }
        await old.waitForPendingWritesForTesting()
        let scanner = IncrementalJSONLScanner<CodexLogUsageScanner.Event>(persistence:
            .init(namespace: "codex", schemaVersion: CodexLogUsageScanner.cacheSchemaVersion, directory: directory))
        let events = await scanner.items(from: files, since: .distantPast, cacheIdentity: "model-account", parse: CodexLogUsageScanner.parseFile)
        XCTAssertEqual(events?.map(\.model), ["", "gpt-5.5"])
        await scanner.waitForPendingWritesForTesting()
    }

    private func truncatedReplay(meta: String, lastOnly: Bool = false) -> String {
        var lines = [meta, CodexLogFixture.turnContext(timestamp: timestamp, model: "gpt-5.4"),
                     CodexLogFixture.taskStarted(timestamp: timestamp,
                         startedAt: Int(OpenUsageISO8601.date(from: timestamp)!.timeIntervalSince1970))]
        if lastOnly {
            lines.append(CodexLogFixture.tokenCount(timestamp: timestamp, last: CodexLogFixture.usage(input: 10, output: 0)))
        }
        for input in [200, 220] {
            lines.append(CodexLogFixture.tokenCount(timestamp: timestamp, totals: CodexLogFixture.usage(input: input, output: 0)))
        }
        return lines.joined(separator: "\n")
    }

    private func missingTotalsReplay(
        meta: String, seed: Int?, totalsJSON: String? = nil,
        restoreReplay: Bool = false, liveLastOnly: Bool = false
    ) -> String {
        var lines = [meta, CodexLogFixture.turnContext(timestamp: timestamp, model: "gpt-5.4")]
        if let seed {
            lines.append(CodexLogFixture.tokenCount(timestamp: timestamp, totals: CodexLogFixture.usage(input: seed, output: 0)))
        }
        let totalField = totalsJSON.map { ",\"total_token_usage\":\($0)" } ?? ""
        lines.append("{\"timestamp\":\"\(timestamp)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":10}\(totalField)}}}")
        if restoreReplay {
            lines.append(CodexLogFixture.tokenCount(timestamp: timestamp, totals: CodexLogFixture.usage(input: 180, output: 0)))
        }
        lines.append(CodexLogFixture.taskStarted(
            timestamp: timestamp, startedAt: Int(OpenUsageISO8601.date(from: timestamp)!.timeIntervalSince1970)
        ))
        if liveLastOnly {
            lines.append(CodexLogFixture.tokenCount(timestamp: timestamp, last: CodexLogFixture.usage(input: 10, output: 0)))
        }
        for input in [200, 220] {
            lines.append(CodexLogFixture.tokenCount(timestamp: timestamp, totals: CodexLogFixture.usage(input: input, output: 0)))
        }
        return lines.joined(separator: "\n")
    }

    private func rollout(meta: String, corrupt: [String: Int], last: [String: Int]? = nil, recoveredReplay: [String: Int]? = nil) -> String {
        let epoch = Int(OpenUsageISO8601.date(from: timestamp)!.timeIntervalSince1970)
        var lines = [
            meta,
            CodexLogFixture.turnContext(timestamp: timestamp, model: "gpt-5.4"),
            CodexLogFixture.tokenCount(
                timestamp: timestamp, totals: CodexLogFixture.usage(input: 100, output: 50)
            ),
            CodexLogFixture.tokenCount(timestamp: timestamp, totals: corrupt),
        ]
        if let recoveredReplay { lines.append(CodexLogFixture.tokenCount(timestamp: timestamp, totals: recoveredReplay)) }
        lines += [
            CodexLogFixture.taskStarted(timestamp: timestamp, startedAt: epoch),
            CodexLogFixture.tokenCount(
                timestamp: timestamp, last: last, totals: CodexLogFixture.usage(input: 200, output: 50)
            ),
        ]
        return lines.joined(separator: "\n")
    }
}
