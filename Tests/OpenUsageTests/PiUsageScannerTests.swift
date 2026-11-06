import XCTest
@testable import OpenUsage

final class PiUsageScannerTests: XCTestCase {
    private func d(_ iso: String) -> Date { OpenUsageISO8601.date(from: iso)! }

    /// carried-$0 fall-through 검증용 fixture pricing (composer input $10/M)
    private let pricing = ModelPricing(
        supplement: PricingSupplement(),
        primary: PricingCatalog(entries: [
            "composer-2.5": ModelRates(
                inputPerMillion: 10, outputPerMillion: 20,
                cacheWritePerMillion: 10, cacheReadPerMillion: 1
            )
        ]),
        secondary: PricingCatalog(entries: [:])
    )

    private func line(
        id: String = "m1", ts: String = "2026-07-12T10:00:00.000Z", provider: String = "anthropic",
        model: String = "claude-opus-4-8", input: Int = 100, output: Int = 50,
        cacheRead: Int = 0, cacheWrite: Int = 0, cacheWrite1h: Int = 0, total: Int = 150,
        cost: String? = "0.5", costObject: String? = nil, responseModel: String? = nil
    ) -> Data {
        let costJSON = costObject.map { ",\"cost\":\($0)" } ?? cost.map { ",\"cost\":{\"total\":\($0)}" } ?? ""
        let responseModelJSON = responseModel.map { ",\"responseModel\":\"\($0)\"" } ?? ""
        let json = """
        {"type":"message","id":"\(id)","timestamp":"\(ts)","message":{"role":"assistant","provider":"\(provider)","model":"\(model)"\(responseModelJSON),"usage":{"input":\(input),"output":\(output),"cacheRead":\(cacheRead),"cacheWrite":\(cacheWrite),"cacheWrite1h":\(cacheWrite1h),"totalTokens":\(total)\(costJSON)}}}
        """
        return Data(json.utf8)
    }

    func testCollectsPiOMPAndUnknownProvidersWithoutLosingRouting() async throws {
        let home = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        try UsageRecordFixture.write(line(provider: "nvidia-nim", responseModel: "upstream-model"),
                                     to: home.appendingPathComponent(".pi/agent/sessions/a.jsonl"))
        try UsageRecordFixture.write(#"{"type":"model_usage","id":"m2","timestamp":"2026-07-12T10:00:00Z","provider":"anthropic","model":"claude-opus-4-8","usage":{"input":20,"output":10,"cost":{"total":0.2}}}"#,
                                     to: home.appendingPathComponent(".omp/agent/sessions/b.jsonl"))
        let collector = PiUsageScanner(environment: FakeEnvironment([:]), homeDirectory: { home },
                                       incrementalScanner: IncrementalJSONLScanner<UsageRecord>())
        let resultResult = await collector.collect(since: .distantPast)
        let result = try XCTUnwrap(resultResult)
        XCTAssertEqual(result.records.count, 2)
        XCTAssertEqual(Set(result.records.map(\.sourceID)), ["pi", "omp"])
        let unknown = try XCTUnwrap(result.records.first { $0.providerID == "nvidia-nim" })
        XCTAssertEqual(unknown.model, "claude-opus-4-8")
        XCTAssertEqual(unknown.responseModel, "upstream-model")
        XCTAssertEqual(unknown.totalTokens, 150)
        let scan = try XCTUnwrap(UsageHistoryBuilder.scan(result, providerID: "claude", since: .distantPast, pricing: .empty))
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 30)
        XCTAssertEqual(scan.series.daily.first?.costUSD, 0.2)
    }

    func testForkCopiesDeduplicateButIndependentShortIDsSurvive() throws {
        let original = try PiSessionParser.parse(Data((#"{"type":"session","id":"original"}"# + "\n" + String(decoding: line(), as: UTF8.self)).utf8),
                                                 path: "/sessions/original.jsonl", sourceID: "omp")
        let fork = try PiSessionParser.parse(Data((#"{"type":"session","id":"fork","parentSession":"/sessions/original.jsonl"}"# + "\n" + String(decoding: line(cost: "0"), as: UTF8.self)).utf8),
                                             path: "/sessions/fork.jsonl", sourceID: "omp")
        let independent = try PiSessionParser.parse(Data((#"{"type":"session","id":"other"}"# + "\n" + String(decoding: line(), as: UTF8.self)).utf8),
                                                    path: "/sessions/other.jsonl", sourceID: "omp")
        for records in [fork + original + independent, independent + original + fork] {
            let unique = UsageRecordDeduplicator.records(records)
            XCTAssertEqual(unique.count, 2)
            let scan = UsageRecordFixture.history(records: unique, providerID: "claude", since: .distantPast, pricing: .empty)
            XCTAssertEqual(scan.series.daily.first?.totalTokens, 300)
            XCTAssertEqual(scan.series.daily.first?.costUSD, 1)
        }
    }

    func testPriceIndependentCacheRetainsUnknownModelAndReprices() async throws {
        let directory = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("sessions/usage.jsonl")
        try UsageRecordFixture.write(line(provider: "cursor", model: "composer-2.5", cost: "0"), to: source)
        let persistence = JSONLScanCachePersistence(namespace: "pi", schemaVersion: PiUsageScanner.cacheSchemaVersion,
                                                   directory: directory.appendingPathComponent("cache"), writeDebounce: .milliseconds(1))
        let first = UsageFileCollector(sourceID: "pi", roots: [source], scanner: IncrementalJSONLScanner(persistence: persistence),
                                      includeFile: { _ in true }, parse: { try PiSessionParser.parse($0, path: $1, sourceID: "pi") })
        let collectionResult = await first.collect(since: .distantPast)
        let collection = try XCTUnwrap(collectionResult)
        let unpriced = try XCTUnwrap(UsageHistoryBuilder.scan(collection, providerID: "cursor", since: .distantPast, pricing: .empty))
        XCTAssertEqual(unpriced.series.daily.first?.totalTokens, 150)
        XCTAssertNil(unpriced.series.daily.first?.costUSD)
        await first.flushCache()
        let second = UsageFileCollector(sourceID: "pi", roots: [source], scanner: IncrementalJSONLScanner(persistence: persistence),
                                       includeFile: { _ in true }, parse: { _, _ in XCTFail("Expected raw disk cache reuse"); return [] })
        let restoredResult = await second.collect(since: .distantPast)
        let restored = try XCTUnwrap(restoredResult)
        XCTAssertEqual(restored.records, collection.records)
        let priced = try XCTUnwrap(UsageHistoryBuilder.scan(restored, providerID: "cursor", since: .distantPast, pricing: pricing))
        XCTAssertEqual(priced.series.daily.first?.totalTokens, 150)
        XCTAssertEqual(try XCTUnwrap(priced.series.daily.first?.costUSD), 0.002, accuracy: 1e-9)
    }

    func testMalformedFilesPreserveValidRecordsAndDifferFromAbsentSource() async throws {
        let home = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let collector = PiUsageScanner(environment: FakeEnvironment([:]), homeDirectory: { home },
                                       incrementalScanner: IncrementalJSONLScanner<UsageRecord>())
        let absentResult = await collector.collect(since: .distantPast)
        let absent = try XCTUnwrap(absentResult)
        XCTAssertTrue(absent.sources.allSatisfy { $0.status == .absent })
        let root = home.appendingPathComponent(".pi/agent/sessions")
        try UsageRecordFixture.write(line(), to: root.appendingPathComponent("good.jsonl"))
        try UsageRecordFixture.write("not JSON\n", to: root.appendingPathComponent("bad.jsonl"))
        let partialResult = await collector.collect(since: .distantPast)
        let partial = try XCTUnwrap(partialResult)
        XCTAssertEqual(partial.sources.first?.status, .complete)
        XCTAssertEqual(partial.readFailureCount, 0)
        let scan = try XCTUnwrap(UsageHistoryBuilder.scan(partial, providerID: "claude", since: .distantPast, pricing: .empty))
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 150)
        XCTAssertNotNil(scan.metadataWarning)
        try FileManager.default.removeItem(at: root.appendingPathComponent("good.jsonl"))
        let failedResult = await collector.collect(since: .distantPast)
        let failed = try XCTUnwrap(failedResult)
        XCTAssertEqual(failed.sources.first?.status, .complete)
        let invalidScan = UsageHistoryBuilder.scan(failed, providerID: "claude", since: .distantPast, pricing: .empty)
        XCTAssertNil(invalidScan?.usageHistory)
        XCTAssertNotNil(invalidScan?.metadataWarning)
    }

    func testCancellationDoesNotBecomeAnEmptySuccessfulCollection() async {
        let collector = UsageCollectionCoordinator(collectors: [])
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return await collector.collect(since: .distantPast)
        }
        task.cancel()
        let result = await task.value
        XCTAssertNil(result)
    }

    func testIncompleteCompactionRetainsOriginalRecordWithoutInventingRouting() throws {
        let records = try PiSessionParser.parse(Data(#"{"type":"compaction","id":"c1","usage":{"input":100}}"#.utf8),
                                                path: "/fixture/a.jsonl", sourceID: "omp")
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.totalTokens, 100)
        XCTAssertNil(records.first?.providerID)
        XCTAssertNil(records.first?.model)
        XCTAssertTrue(records.first?.issues.contains(.invalidMetadata) == true)
        let scan = UsageRecordFixture.history(records: records, providerID: "claude", since: .distantPast, pricing: .empty)
        XCTAssertNil(scan.usageHistory)
        XCTAssertNotNil(scan.metadataWarning)
    }

    func testResponseModelCacheWriteAndReportedTotalRemainIndependent() throws {
        let entry = try XCTUnwrap(UsageRecordFixture.piRecord(line(cacheWrite: 1000, cacheWrite1h: 400, total: 5000,
                                                                 responseModel: "resolved-model")))
        XCTAssertEqual(entry.model, "claude-opus-4-8")
        XCTAssertEqual(entry.effectiveModel, "resolved-model")
        XCTAssertEqual(entry.tokens?.cacheWrite5m, 600)
        XCTAssertEqual(entry.tokens?.cacheWrite1h, 400)
        let scan = UsageRecordFixture.history(records: [entry], providerID: "claude", since: .distantPast, pricing: .empty)
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 5000)
        XCTAssertEqual(scan.modelUsage?.daily.first?.models.first?.model, "resolved-model")
        XCTAssertEqual(scan.series.daily.first?.costUSD, 0.5)
    }

    func testInvalidReportedCostDoesNotBecomeAFreeOrEstimatedRequest() throws {
        for value in ["-1", "true", "\"invalid\"", "null"] {
            let record = try XCTUnwrap(UsageRecordFixture.piRecord(line(cost: value)))
            XCTAssertTrue(record.issues.contains(.invalidNumbers))
            let scan = UsageRecordFixture.history(records: [record], providerID: "claude", since: .distantPast, pricing: pricing)
            XCTAssertNil(scan.usageHistory)
            XCTAssertNotNil(scan.numericWarning)
        }
    }

    func testProviderReportedCostPreservesZeroAndExcludesCatalogCostFromReportedOnlyCards() throws {
        let estimated = try XCTUnwrap(UsageRecordFixture.piRecord(line(provider: "github-copilot", cost: "0.5")))
        let reported = try XCTUnwrap(UsageRecordFixture.piRecord(line(
            provider: "github-copilot", costObject: #"{"total":0,"totalFromProvider":true}"#
        )))
        XCTAssertEqual(estimated.costOrigin, .estimated)
        XCTAssertEqual(reported.costOrigin, .reported)
        XCTAssertFalse(reported.zeroCostIsUnknown)
        let estimateScan = try XCTUnwrap(UsageHistoryBuilder.scan(
            .init(records: [estimated]), providerID: "copilot", since: .distantPast,
            pricing: pricing, allowEstimates: false
        ))
        XCTAssertEqual(estimateScan.series.daily.first?.totalTokens, 150)
        XCTAssertNil(estimateScan.series.daily.first?.costUSD)
        let reportedScan = try XCTUnwrap(UsageHistoryBuilder.scan(
            .init(records: [reported]), providerID: "copilot", since: .distantPast,
            pricing: pricing, allowEstimates: false
        ))
        XCTAssertEqual(reportedScan.series.daily.first?.costUSD, 0)
    }

    func testReasoningIsPreservedAsOutputSubsetAndInvalidCountIsDiagnosed() throws {
        let raw = String(decoding: line(output: 50), as: UTF8.self)
        let valid = raw.replacingOccurrences(of: #""output":50"#, with: #""output":50,"reasoning":20"#)
        let record = try XCTUnwrap(UsageRecordFixture.piRecord(Data(valid.utf8)))
        XCTAssertEqual(record.reasoningTokens, 20)
        XCTAssertEqual(record.tokens?.output, 50)
        XCTAssertEqual(record.totalTokens, 150)
        let invalid = valid.replacingOccurrences(of: #""reasoning":20"#, with: #""reasoning":-1"#)
        XCTAssertTrue(try XCTUnwrap(UsageRecordFixture.piRecord(Data(invalid.utf8))).issues.contains(.invalidNumbers))
    }

    func testProviderMappingUsesRecordedRouteInsteadOfModelManufacturer() {
        XCTAssertEqual(UsageProviderMapping.providerID(for: "claude-agent-sdk"), "claude")
        XCTAssertEqual(UsageProviderMapping.providerID(for: "openai-codex"), "codex")
        XCTAssertEqual(UsageProviderMapping.providerID(for: "openrouter"), "openrouter")
        XCTAssertNil(UsageProviderMapping.providerID(for: "openai"))
        XCTAssertNil(UsageProviderMapping.providerID(for: "nvidia-nim"))
    }

    func testOMPProfileAndXDGResolutionMatchTheActiveProfile() throws {
        let home = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let xdg = home.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: xdg.appendingPathComponent("omp"), withIntermediateDirectories: true)
        XCTAssertEqual(PiPaths.ompSessionsDirectory(environment: FakeEnvironment(["OMP_PROFILE": "default", "XDG_DATA_HOME": xdg.path]), homeDirectory: home),
                       xdg.appendingPathComponent("omp/sessions"))
        XCTAssertEqual(PiPaths.ompSessionsDirectory(environment: FakeEnvironment(["OMP_PROFILE": "work", "XDG_DATA_HOME": xdg.path]), homeDirectory: home),
                       home.appendingPathComponent(".omp/profiles/work/agent/sessions"))
        XCTAssertNil(PiPaths.ompSessionsDirectory(environment: FakeEnvironment(["OMP_PROFILE": "../escape"]), homeDirectory: home))
        XCTAssertEqual(try PiPaths.sessionsDirectory(environment: FakeEnvironment(["PI_CODING_AGENT_SESSION_DIR": "~/custom"]), homeDirectory: home),
                       home.appendingPathComponent("custom"))
    }

    func testMalformedLineAndIncompleteTailKeepSameFileUsageWithoutContent() throws {
        let text = String(decoding: line(), as: UTF8.self) + "\n"
            + #"{"type":"message","content":"fixture-private""# + "\n"
            + String(decoding: line(id: "m2"), as: UTF8.self) + "\n"
            + #"{"type":"message""#
        let records = try PiSessionParser.parse(Data(text.utf8), path: "/fixture/a.jsonl", sourceID: "pi")
        XCTAssertEqual(records.count, 4)
        XCTAssertEqual(records.filter { $0.issues.contains(.invalidMetadata) }.count, 2)
        let history = UsageRecordFixture.history(records: records, providerID: "claude", since: .distantPast, pricing: .empty)
        XCTAssertEqual(history.series.daily.first?.totalTokens, 300)
        XCTAssertEqual(history.series.daily.first?.costUSD, 1)
        XCTAssertNotNil(history.metadataWarning)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(records), as: UTF8.self).contains("fixture-private"))
    }

    func testMalformedUsageObjectsDifferFromAbsentOptionalUsage() throws {
        for type in ["compaction", "branch_summary", "usage", "model_usage"] {
            let absent = Data("{\"type\":\"\(type)\",\"id\":\"c1\"}".utf8)
            XCTAssertTrue(try PiSessionParser.parse(absent, path: "/fixture/a.jsonl", sourceID: "pi").isEmpty)
            for value in ["true", "[]", "\"invalid\"", "null"] {
                let data = Data("{\"type\":\"\(type)\",\"id\":\"c1\",\"usage\":\(value)}".utf8)
                let record = try XCTUnwrap(PiSessionParser.parse(data, path: "/fixture/a.jsonl", sourceID: "pi").first)
                XCTAssertTrue(record.issues.contains(.invalidMetadata))
                XCTAssertNil(record.tokens)
            }
        }
        let assistant = Data(#"{"type":"message","id":"m1","timestamp":"2026-07-12T10:00:00Z","message":{"role":"assistant","provider":"anthropic","model":"fixture-model","usage":false}}"#.utf8)
        let record = try XCTUnwrap(PiSessionParser.parse(assistant, path: "/fixture/a.jsonl", sourceID: "pi").first)
        XCTAssertEqual(record.providerID, "anthropic")
        XCTAssertTrue(record.issues.contains(.invalidMetadata))
    }

    func testMalformedAppendAndDiskCacheRetainNormalUsageAndWarning() async throws {
        let root = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        let initial = String(decoding: line(), as: UTF8.self) + "\n"
        try UsageRecordFixture.write(initial, to: file)
        let persistence = JSONLScanCachePersistence(
            namespace: "pi", schemaVersion: PiUsageScanner.cacheSchemaVersion,
            directory: root.appendingPathComponent("cache"), writeDebounce: .milliseconds(1)
        )
        let collector = UsageFileCollector(
            sourceID: "pi", roots: [file], scanner: IncrementalJSONLScanner(persistence: persistence),
            includeFile: { _ in true }, parse: { try PiSessionParser.parse($0, path: $1, sourceID: "pi") }
        )
        let first = await collector.collect(since: .distantPast)
        XCTAssertEqual(first?.records.count, 1)
        try UsageRecordFixture.write(initial + "invalid\n" + String(decoding: line(id: "m2"), as: UTF8.self), to: file)
        let updatedResult = await collector.collect(since: .distantPast)
        let updated = try XCTUnwrap(updatedResult)
        await collector.flushCache()
        let restoredCollector = UsageFileCollector(
            sourceID: "pi", roots: [file], scanner: IncrementalJSONLScanner(persistence: persistence),
            includeFile: { _ in true }, parse: { _, _ in XCTFail("Expected valid and invalid records from cache"); return [] }
        )
        let restoredResult = await restoredCollector.collect(since: .distantPast)
        let restored = try XCTUnwrap(restoredResult)
        XCTAssertEqual(restored.records, updated.records)
        let history = try XCTUnwrap(UsageHistoryBuilder.scan(restored, providerID: "claude", since: .distantPast, pricing: .empty))
        XCTAssertEqual(history.series.daily.first?.totalTokens, 300)
        XCTAssertNotNil(history.metadataWarning)
    }

    func testGlobalSessionSettingsRespectAgentDirectoryAndEnvironmentPriority() throws {
        let home = URL(fileURLWithPath: "/fixture-home")
        let files = FakeFiles()
        XCTAssertEqual(try PiPaths.sessionsDirectory(environment: FakeEnvironment(), homeDirectory: home, files: files),
                       home.appendingPathComponent(".pi/agent/sessions"))
        files.files["/fixture-home/.pi/agent/settings.json"] = #"{"sessionDir":"/fixture-sessions"}"#
        XCTAssertEqual(try PiPaths.sessionsDirectory(environment: FakeEnvironment(), homeDirectory: home, files: files),
                       URL(fileURLWithPath: "/fixture-sessions"))
        files.files["/fixture-home/custom-agent/settings.json"] = #"{"sessionDir":"~/custom-sessions"}"#
        XCTAssertEqual(try PiPaths.sessionsDirectory(
            environment: FakeEnvironment(["PI_CODING_AGENT_DIR": "~/custom-agent"]), homeDirectory: home, files: files
        ), home.appendingPathComponent("custom-sessions"))
        files.files["/fixture-home/.pi/agent/settings.json"] = "invalid settings"
        XCTAssertEqual(try PiPaths.sessionsDirectory(
            environment: FakeEnvironment(["PI_CODING_AGENT_SESSION_DIR": "/explicit"]), homeDirectory: home, files: files
        ), URL(fileURLWithPath: "/explicit"))
    }

    func testGlobalSessionSettingsRejectMalformedAndRelativeLocations() throws {
        let home = URL(fileURLWithPath: "/fixture-home")
        for text in ["broken", "[]", #"{"sessionDir":true}"#, #"{"sessionDir":null}"#, #"{"sessionDir":"relative/sessions"}"#] {
            XCTAssertThrowsError(try PiPaths.sessionsDirectory(
                environment: FakeEnvironment(), homeDirectory: home,
                files: FakeFiles(["/fixture-home/.pi/agent/settings.json": text])
            ), text)
        }
        XCTAssertEqual(try PiPaths.sessionsDirectory(
            environment: FakeEnvironment(), homeDirectory: home,
            files: FakeFiles(["/fixture-home/.pi/agent/settings.json": #"{"sessionDir":""}"#])
        ), home.appendingPathComponent(".pi/agent/sessions"))
    }

    func testGlobalSessionSettingsConnectToCollectorAndInvalidSettingsWarn() async throws {
        let home = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = home.appendingPathComponent(".pi/agent/settings.json")
        try UsageRecordFixture.write(#"{"sessionDir":"~/custom-sessions"}"#, to: settings)
        try UsageRecordFixture.write(line(), to: home.appendingPathComponent("custom-sessions/a.jsonl"))
        let scanner = PiUsageScanner(environment: FakeEnvironment(), homeDirectory: { home },
                                     incrementalScanner: IncrementalJSONLScanner<UsageRecord>())
        let collected = await scanner.collect(since: .distantPast)
        XCTAssertEqual(collected?.records.first?.totalTokens, 150)
        try UsageRecordFixture.write(#"{"sessionDir":"relative/sessions"}"#, to: settings)
        try UsageRecordFixture.write(line(), to: home.appendingPathComponent(".pi/agent/sessions/default.jsonl"))
        let invalidScanner = PiUsageScanner(environment: FakeEnvironment(), homeDirectory: { home },
                                            incrementalScanner: IncrementalJSONLScanner<UsageRecord>())
        let invalidResult = await invalidScanner.collect(since: .distantPast)
        let invalid = try XCTUnwrap(invalidResult)
        XCTAssertTrue(invalid.records.isEmpty)
        XCTAssertEqual(invalid.sources.first { $0.sourceID == "pi" }?.status, .failed)
        let history = try XCTUnwrap(UsageHistoryBuilder.scan(invalid, providerID: "claude", since: .distantPast, pricing: .empty))
        XCTAssertNotNil(history.readWarning)
    }

    func testOMPExplicitDefaultIgnoresOnlyInheritedProfileAgentDirectory() {
        let home = URL(fileURLWithPath: "/fixture-home")
        for profile in ["", "default"] {
            let environment = FakeEnvironment([
                "OMP_PROFILE": profile, "PI_PROFILE": "work",
                "PI_CODING_AGENT_DIR": "/fixture-home/.omp/profiles/work/agent"
            ])
            XCTAssertEqual(PiPaths.ompSessionsDirectory(environment: environment, homeDirectory: home),
                           home.appendingPathComponent(".omp/agent/sessions"))
        }
        XCTAssertEqual(PiPaths.ompSessionsDirectory(environment: FakeEnvironment([
            "OMP_PROFILE": "", "PI_PROFILE": "work", "PI_CODING_AGENT_DIR": "/custom-agent"
        ]), homeDirectory: home), URL(fileURLWithPath: "/custom-agent/sessions"))
        XCTAssertEqual(PiPaths.ompSessionsDirectory(environment: FakeEnvironment([
            "OMP_PROFILE": "", "PI_PROFILE": "work", "PI_CONFIG_DIR": ".omp-custom",
            "PI_CODING_AGENT_DIR": "/fixture-home/.omp-custom/profiles/work/agent"
        ]), homeDirectory: home), home.appendingPathComponent(".omp-custom/agent/sessions"))
        XCTAssertEqual(PiPaths.ompSessionsDirectory(environment: FakeEnvironment([
            "PI_PROFILE": "work", "PI_CODING_AGENT_DIR": "/custom-agent"
        ]), homeDirectory: home), home.appendingPathComponent(".omp/profiles/work/agent/sessions"))
    }
}
