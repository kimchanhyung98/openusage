import XCTest
@testable import OpenUsage

final class NumericUsageSafetyTests: XCTestCase {
    func testCountsKeepExactIntegersAndRejectInvalidValues() {
        let valid: [(Any, Int)] = [
            (0, 0), (Int.max, Int.max), ("9223372036854775807", Int.max),
            ("9.223372036854775807e18", Int.max), (" 42 ", 42), ("1e3", 1_000),
            ("1000e-3", 1), ("1.000000000000000000000000000000000000000000", 1),
            (1.0, 1), ("-0", 0), ("0e999999", 0)
        ]
        for (value, expected) in valid {
            XCTAssertEqual(UsageLogNumbers.count(value), expected, "\(value)")
        }
        let invalid: [Any] = [
            true, false, NSNull(), -1, -0.5, 1.5, Double.nan, Double.infinity, -Double.infinity,
            1e300, Double(Int.max), UInt64.max, "9223372036854775808", "1e999999",
            "-0.00001", "NaN", "Infinity", "true", "", "1.2.3", "12garbage", "0x10",
            "1.0000000000000001", "9007199254740991.1", "9007199254740990.5",
            "1.00000000000000000000000000000000000000000001", "1e-9223372036854775808"
        ]
        for value in invalid {
            XCTAssertNil(UsageLogNumbers.count(value), "\(value)")
        }
        XCTAssertNil(UsageLogNumbers.count(nil))
        XCTAssertEqual(UsageLogNumbers.count(nil, missing: 0), 0)
        XCTAssertNil(UsageLogNumbers.count(NSNull(), missing: 0))
        XCTAssertEqual(UsageLogNumbers.sum(Int.max, 0), Int.max)
        XCTAssertNil(UsageLogNumbers.sum(Int.max, 1))
    }

    func testGrokRejectsEveryInvalidTokenFieldWithoutChangingValidUsage() {
        for field in ["prompt_tokens", "completion_tokens", "reasoning_tokens", "cached_prompt_tokens"] {
            for invalid in ["-1", "true", "1.5", "1e300", "null", "\"NaN\"", "\"1.0000000000000001\""] {
                var usage = ["prompt_tokens": "100", "completion_tokens": "50"]
                usage[field] = invalid
                let scan = grokScan(grokUsage(usage))
                XCTAssertEqual(scan.series.daily.first?.totalTokens, 150, "\(field)=\(invalid)")
                XCTAssertEqual(scan.modelUsage?.daily.first?.models.first?.totalTokens, 150)
                XCTAssertEqual(scan.rejectedNumericRows, 1)
                XCTAssertNotNil(scan.numericWarning)
                XCTAssertNotNil(scan.usageHistory)
            }
        }
    }

    func testGrokRejectsRowBucketOverflowBeforePricing() {
        for usage in [
            ["prompt_tokens": "1", "completion_tokens": String(Int.max)],
            ["prompt_tokens": "0", "completion_tokens": String(Int.max), "reasoning_tokens": "1"]
        ] {
            let scan = grokScan(grokUsage(usage))
            XCTAssertEqual(scan.series.daily.first?.totalTokens, 150)
            XCTAssertEqual(scan.rejectedNumericRows, 1)
        }
    }

    func testGrokKeepsReasoningAdditiveAndClampsCacheToPrompt() {
        let scan = grokScan(grokUsage([
            "prompt_tokens": "100", "completion_tokens": "50", "reasoning_tokens": "25",
            "cached_prompt_tokens": "999"
        ]), includeValid: false)
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 175)
        XCTAssertEqual(scan.rejectedNumericRows, 0)
        XCTAssertNil(scan.numericWarning)
    }

    func testGrokPIDPrecisionAndMalformedPIDCannotCrossAttributeModels() {
        let largeA = "9007199254740992"
        let largeB = "9007199254740993"
        let log = """
        {"pid":\(largeA),"msg":"model changed","ctx":{"model":"grok-build"}}
        {"pid":"\(largeB)","msg":"model changed","ctx":{"model":"grok-composer-2.5-fast"}}
        \(grokUsage(["prompt_tokens": "100"], pid: largeA))
        \(grokUsage(["prompt_tokens": "200"], pid: "\"\(largeB)\""))
        {"pid":1e300,"msg":"model changed","ctx":{"model":"PRIVATE_MODEL"}}
        \(grokUsage(["prompt_tokens": "300"], pid: "1e300"))
        \(grokUsage(["prompt_tokens": "300"], pid: "0"))
        \(grokUsage(["prompt_tokens": "300"], pid: "true"))
        """
        let scan = GrokLogUsageScanner.parse(log, since: .distantPast, pricing: TestPricing.bundled)
        let models = Dictionary(uniqueKeysWithValues: (scan.modelUsage?.daily.first?.models ?? []).map { ($0.model, $0.totalTokens) })
        XCTAssertEqual(models, ["grok-build": 100, "grok-composer-2.5-fast": 200])
        XCTAssertEqual(scan.rejectedNumericRows, 4)
    }

    func testPiRejectsInvalidBucketsEvenWithCarriedCostAndPreservesReportedTotal() throws {
        for field in ["input", "output", "cacheRead", "cacheWrite", "cacheWrite1h", "totalTokens"] {
            for invalid in ["-1", "true", "1.5", "1e300", "null", "\"Infinity\""] {
                let entry = try XCTUnwrap(PiUsageScanner.parseLine(piLine([field: invalid])))
                XCTAssertTrue(entry.invalidNumericValues, "\(field)=\(invalid)")
                let scan = PiUsageScanner.aggregate(entries: [entry], cardID: "claude", since: .distantPast, pricing: .empty)
                XCTAssertTrue(scan.series.daily.isEmpty)
                XCTAssertEqual(scan.rejectedNumericRows, 1)
                XCTAssertNil(scan.usageHistory)
            }
        }
        let valid = try XCTUnwrap(PiUsageScanner.parseLine(piLine([
            "input": "10", "cacheWrite": "10", "cacheWrite1h": "20", "totalTokens": "999"
        ])))
        XCTAssertFalse(valid.invalidNumericValues)
        XCTAssertEqual(valid.tokens.cacheWrite5m, 0)
        XCTAssertEqual(valid.tokens.cacheWrite1h, 20)
        XCTAssertEqual(valid.tokens.totalTokens, 30)
        let scan = PiUsageScanner.aggregate(entries: [valid], cardID: "claude", since: .distantPast, pricing: .empty)
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 999)
        XCTAssertEqual(scan.series.daily.first?.costUSD, 0.5)
    }

    func testPiRejectsBucketSumOverflowAndScopesQualityToCardAndWindow() throws {
        let bad = try XCTUnwrap(PiUsageScanner.parseLine(piLine(["input": String(Int.max), "cacheRead": "1"])))
        XCTAssertTrue(bad.invalidNumericValues)
        let otherCard = PiUsageScanner.aggregate(entries: [bad], cardID: "codex", since: .distantPast, pricing: .empty)
        XCTAssertNil(otherCard.numericWarning)
        XCTAssertNotNil(otherCard.usageHistory)
        let older = PiUsageScanner.aggregate(entries: [bad], cardID: "claude", since: date.addingTimeInterval(1), pricing: .empty)
        XCTAssertNil(older.numericWarning)
        let valid = try XCTUnwrap(PiUsageScanner.parseLine(piLine(["totalTokens": "150"], id: "valid")))
        let mixed = PiUsageScanner.aggregate(entries: PiUsageScanner.dedup([bad, bad, valid]), cardID: "claude", since: .distantPast, pricing: .empty)
        XCTAssertEqual(mixed.rejectedNumericRows, 1)
        XCTAssertEqual(mixed.series.daily.first?.totalTokens, 150)
        XCTAssertNotNil(mixed.usageHistory)
    }

    func testAccumulatorRejectsOverflowAtomicallyAcrossDaysAndModels() {
        for (day, model) in [("2026-09-12", "a"), ("2026-09-12", "b"), ("2026-09-11", "a")] {
            var accumulator = DailyUsageAccumulator()
            accumulator.add(day: "2026-09-12", tokens: Int.max, cost: 1, model: "a")
            accumulator.add(day: day, tokens: 1, cost: 99, model: model)
            accumulator.add(day: "2026-09-11", tokens: 0, cost: 0.5, model: "a")
            let scan = accumulator.build()
            XCTAssertEqual(scan.series.daily.reduce(0) { $0 + $1.totalTokens }, Int.max)
            XCTAssertEqual(scan.series.daily.compactMap(\.costUSD).reduce(0, +), 1.5)
            XCTAssertEqual(scan.rejectedNumericRows, 1)
            var lines: [MetricLine] = []
            SpendTileMapper.appendTokenUsage(scan.series, to: &lines, now: date, modelUsage: scan.modelUsage, modelSourceNote: "test")
            guard case .values(_, let values, _, _, _, let breakdown) = lines.first(where: { $0.label == "Last 30 Days" }) else {
                return XCTFail("Expected period totals")
            }
            XCTAssertEqual(values.first?.number, 1.5)
            XCTAssertEqual(breakdown?.models.first?.totalTokens, Int.max)
        }
    }

    func testNativePiMergePropagatesNumericQualityAndRejectsOverflow() {
        var native = DailyUsageAccumulator()
        native.add(day: "2026-09-12", tokens: Int.max, cost: 1, model: "a")
        var pi = DailyUsageAccumulator()
        pi.add(day: "2026-09-11", tokens: 1, cost: 99, model: "b")
        pi.rejectNumericRow()
        let merged = DailyUsageAccumulator.merged([native.build(), pi.build()])
        XCTAssertEqual(merged?.series.daily.count, 1)
        XCTAssertEqual(merged?.series.daily.first?.totalTokens, Int.max)
        XCTAssertEqual(merged?.series.daily.first?.costUSD, 1)
        XCTAssertEqual(merged?.rejectedNumericRows, 2)
        XCTAssertNotNil(merged?.usageHistory)
        XCTAssertNotNil(merged?.numericWarning)
    }

    func testPiInvalidMarkerSurvivesMemoryDiskCacheAndSchemaMigration() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let data = piLine(["input": "-1"])
        let url = base.appendingPathComponent("session.jsonl")
        try data.write(to: url)
        let mtime = try XCTUnwrap(url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let file = JSONLScanning.DiscoveredFile(path: url.path, size: data.count, mtime: mtime)
        let cacheDirectory = base.appendingPathComponent("cache")
        let oldPersistence = JSONLScanCachePersistence(namespace: "pi", schemaVersion: 1, directory: cacheDirectory, writeDebounce: .milliseconds(1))
        let old = IncrementalJSONLScanner<PiUsageScanner.Entry>(persistence: oldPersistence)
        _ = await old.items(from: [file], since: .distantPast, cacheIdentity: "home", parse: { _ in [] })
        await old.waitForPendingWritesForTesting()
        let persistence = JSONLScanCachePersistence(namespace: "pi", schemaVersion: PiUsageScanner.cacheSchemaVersion, directory: cacheDirectory, writeDebounce: .milliseconds(1))
        let fresh = IncrementalJSONLScanner<PiUsageScanner.Entry>(persistence: persistence)
        let parsed = await fresh.items(from: [file], since: .distantPast, cacheIdentity: "home", parse: PiUsageScanner.parseFile)
        XCTAssertEqual(parsed?.count, 1, "The old schema's empty parse must be invalidated")
        XCTAssertTrue(parsed?.first?.invalidNumericValues == true)
        let cached = await fresh.items(from: [file], since: .distantPast, cacheIdentity: "home", parse: { _ in
            XCTFail("An unchanged file should use memory cache")
            return []
        })
        await fresh.waitForPendingWritesForTesting()
        let relaunched = IncrementalJSONLScanner<PiUsageScanner.Entry>(persistence: persistence)
        let restored = await relaunched.items(from: [file], since: .distantPast, cacheIdentity: "home", parse: { _ in
            XCTFail("An unchanged file should use disk cache")
            return []
        })
        for entries in [parsed, cached, restored] {
            let scan = PiUsageScanner.aggregate(entries: try XCTUnwrap(entries), cardID: "claude", since: .distantPast, pricing: .empty)
            XCTAssertEqual(scan.rejectedNumericRows, 1)
            XCTAssertNil(scan.usageHistory, "Invalid-only history must not erase the last good history")
            XCTAssertNotNil(scan.numericWarning)
        }
    }

    private var date: Date { OpenUsageISO8601.date(from: "2026-09-12T10:00:00Z")! }

    private func grokUsage(_ fields: [String: String], pid: String = "1") -> String {
        let ctx = fields.sorted { $0.key < $1.key }.map { "\"\($0.key)\":\($0.value)" }.joined(separator: ",")
        return """
        {"ts":"2026-09-12T10:00:00Z","pid":\(pid),"msg":"shell.turn.inference_done","ctx":{\(ctx)}}
        """
    }

    private func grokScan(_ usage: String, includeValid: Bool = true) -> LogUsageScan {
        let valid = includeValid ? grokUsage(["prompt_tokens": "100", "completion_tokens": "50"]) : ""
        return GrokLogUsageScanner.parse("""
        {"pid":1,"msg":"model changed","ctx":{"model":"grok-build"}}
        \(valid)
        \(usage)
        """, since: .distantPast, pricing: TestPricing.bundled)
    }

    private func piLine(_ fields: [String: String], id: String = "pi-id") -> Data {
        let usage = fields.sorted { $0.key < $1.key }.map { "\"\($0.key)\":\($0.value)" }.joined(separator: ",")
        return Data("""
        {"type":"message","id":"\(id)","timestamp":"2026-09-12T10:00:00Z","message":{"role":"assistant","provider":"anthropic","model":"claude-opus-4-8","usage":{\(usage),"cost":{"total":0.5}}}}
        """.utf8)
    }
}
