import Foundation
import XCTest
import libzstd
@testable import OpenUsage

final class CodexCompressedUsageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_789_200_000)
    private let pricing = ModelPricing(
        supplement: PricingSupplement(pricing: [
            "gpt-5.2": .init(inputPerMillion: 1_000, outputPerMillion: 3_000,
                             cacheWritePerMillion: 1_000, cacheReadPerMillion: 100)
        ]), primary: PricingCatalog(), secondary: PricingCatalog()
    )

    func testConfiguredHomeWithCommaDoesNotReadSplitOrDefaultHomes() async throws {
        let root = try CodexLogFixture.makeHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let configured = root.appendingPathComponent("custom,work")
        try write(rows(input: 100, output: 50), "sessions/selected.jsonl", under: configured)
        try write(rows(input: 999, output: 999), "sessions/other.jsonl", under: root.appendingPathComponent("custom"))
        try write(rows(input: 999, output: 999), "sessions/default.jsonl", under: root.appendingPathComponent(".codex"))
        let scanner = CodexLogUsageScanner(
            environment: FakeEnvironment(["CODEX_HOME": configured.path]), homeDirectory: { root },
            incrementalScanner: IncrementalJSONLScanner<CodexLogUsageScanner.Event>()
        )

        let scan = await scanner.scan(now: now, pricing: pricing)

        XCTAssertEqual(scan?.series.daily.first?.totalTokens, 150)
        XCTAssertEqual(scan?.readFailureCount, 0)
    }

    func testScanReadsCompressedActiveAndArchivedRollouts() async throws {
        let home = try CodexLogFixture.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(compress(rows(input: 100, output: 50)), "sessions/2026/09/active.jsonl.zst", under: home)
        try write(compress(rows(input: 30, output: 20)), "archived_sessions/archived.jsonl.zst", under: home)

        let scan = await CodexLogFixture.scanner(home: home).scan(now: now, pricing: pricing)

        XCTAssertEqual(scan?.series.daily.first?.totalTokens, 200)
        XCTAssertEqual(try XCTUnwrap(scan?.series.daily.first?.costUSD), 0.34, accuracy: 1e-9)
        XCTAssertEqual(scan?.readFailureCount, 0)
    }

    func testPlainSiblingWinsOverCompressedCopyAndUnreadableCompressedSibling() async throws {
        let home = try CodexLogFixture.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(rows(input: 100, output: 50), "sessions/sibling.jsonl", under: home)
        try write(compress(rows(input: 999, output: 999)), "sessions/sibling.jsonl.zst", under: home)
        try write(rows(input: 30, output: 20), "sessions/other.jsonl", under: home)
        try write(Data("invalid zstd".utf8), "sessions/other.jsonl.zst", under: home)

        let scan = await CodexLogFixture.scanner(home: home).scan(now: now, pricing: pricing)

        XCTAssertEqual(scan?.series.daily.first?.totalTokens, 200)
        XCTAssertEqual(scan?.readFailureCount, 0)
    }

    func testActiveCopyWinsAcrossPlainAndCompressedRepresentations() async throws {
        for activeCompressed in [false, true] {
            let home = try CodexLogFixture.makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            let active = rows(input: 100, output: 50)
            let archived = rows(input: 999, output: 999)
            try write(activeCompressed ? compress(active) : active,
                      "sessions/rollout.jsonl" + (activeCompressed ? ".zst" : ""), under: home)
            try write(activeCompressed ? archived : compress(archived),
                      "archived_sessions/rollout.jsonl" + (activeCompressed ? "" : ".zst"), under: home)

            let scan = await CodexLogFixture.scanner(home: home).scan(now: now, pricing: pricing)

            XCTAssertEqual(scan?.series.daily.first?.totalTokens, 150)
            XCTAssertEqual(scan?.readFailureCount, 0)
        }
    }

    func testCompressionTransitionKeepsUsageAndReadsLaterReplacement() async throws {
        let home = try CodexLogFixture.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let content = rows(input: 100, output: 50)
        try write(content, "sessions/rollout.jsonl", under: home)
        let scanner = CodexLogFixture.scanner(home: home)
        let plain = await scanner.scan(now: now, pricing: pricing)
        try write(compress(content), "sessions/rollout.jsonl.zst", under: home)
        try FileManager.default.removeItem(at: home.appendingPathComponent("sessions/rollout.jsonl"))

        let compressed = await scanner.scan(now: now, pricing: pricing)
        try write(compress(content + Data([0x0A]) + rows(input: 30, output: 20)),
                  "sessions/rollout.jsonl.zst", under: home)
        let updated = await scanner.scan(now: now, pricing: pricing)

        XCTAssertEqual(compressed?.series, plain?.series)
        XCTAssertEqual(compressed?.series.daily.first?.totalTokens, 150)
        XCTAssertEqual(updated?.series.daily.first?.totalTokens, 200)
        XCTAssertEqual(updated?.readFailureCount, 0)
    }

    func testCorruptAndTruncatedCompressedFilesReportFailuresAndKeepReadableHistory() async throws {
        let home = try CodexLogFixture.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let content = try compress(rows(input: 100, output: 50))
        try write(content, "sessions/rollout.jsonl.zst", under: home)
        let scanner = CodexLogFixture.scanner(home: home)
        let initial = await scanner.scan(now: now, pricing: pricing)
        XCTAssertEqual(initial?.series.daily.first?.totalTokens, 150)
        try write(Data("invalid zstd".utf8), "sessions/rollout.jsonl.zst", under: home)
        try write(Data(content.dropLast()), "sessions/truncated.jsonl.zst", under: home)

        let failed = await scanner.scan(now: now, pricing: pricing)
        XCTAssertEqual(failed?.readFailureCount, 2)
        XCTAssertTrue(failed?.series.daily.isEmpty == true)
        XCTAssertNotNil(failed?.readWarning)
        XCTAssertNil(failed?.usageHistory)

        try write(compress(rows(input: 30, output: 20)), "sessions/readable.jsonl.zst", under: home)
        let partial = await scanner.scan(now: now, pricing: pricing)
        XCTAssertEqual(partial?.series.daily.first?.totalTokens, 50)
        XCTAssertEqual(partial?.readFailureCount, 2)
        XCTAssertNotNil(partial?.readWarning)
        XCTAssertNotNil(partial?.usageHistory)
    }

    func testCompressedUnknownModelKeepsNativeTokensAndOmitsPeriodCost() async throws {
        let home = try CodexLogFixture.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(compress(rows(input: 100, output: 50)), "sessions/known.jsonl.zst", under: home)
        try write(compress(rows(input: 30, output: 20, model: "unpublished-model")),
                  "sessions/unknown.jsonl.zst", under: home)

        let scan = await CodexLogFixture.scanner(home: home).scan(now: now, pricing: pricing)
        let value = try XCTUnwrap(scan)
        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(value.series, to: &lines, now: now)

        XCTAssertEqual(value.series.daily.first?.totalTokens, 200)
        XCTAssertNil(value.series.daily.first?.costUSD)
        XCTAssertEqual(value.unknownModelsByDay.values.first, ["unpublished-model"])
        XCTAssertNotNil(value.usageHistory)
        for line in lines {
            guard case .values(_, let values, _, _, _, _) = line else { continue }
            XCTAssertFalse(values.contains { $0.kind == .dollars })
            XCTAssertTrue(values.contains { $0.kind == .count && $0.number == 200 })
        }
        XCTAssertEqual(lines.count, 2)
    }

    func testCompressedSymlinkWithoutTargetSuffixReadsAndReportsCorruption() async throws {
        let home = try CodexLogFixture.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let target = home.appendingPathComponent("payload")
        try compress(rows(input: 100, output: 50)).write(to: target)
        let sessions = home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: sessions.appendingPathComponent("rollout.jsonl.zst"),
                                                   withDestinationURL: target)
        let scanner = CodexLogFixture.scanner(home: home)
        let initial = await scanner.scan(now: now, pricing: pricing)
        XCTAssertEqual(initial?.series.daily.first?.totalTokens, 150)
        XCTAssertEqual(initial?.readFailureCount, 0)
        try Data([0x28, 0xB5]).write(to: target)
        let broken = await scanner.scan(now: now, pricing: pricing)
        XCTAssertEqual(broken?.readFailureCount, 1)
        XCTAssertNotNil(broken?.readWarning)
    }

    func testAddingCompressedAliasInvalidatesRawInterpretationCache() async throws {
        let home = try CodexLogFixture.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let target = home.appendingPathComponent("payload")
        try compress(rows(input: 100, output: 50)).write(to: target)
        let sessions = home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: sessions.appendingPathComponent("one.jsonl"), withDestinationURL: target)
        let scanner = CodexLogFixture.scanner(home: home)
        let raw = await scanner.scan(now: now, pricing: pricing)
        XCTAssertTrue(raw?.series.daily.isEmpty == true)
        try FileManager.default.createSymbolicLink(at: sessions.appendingPathComponent("other.jsonl.zst"), withDestinationURL: target)
        let compressed = await scanner.scan(now: now, pricing: pricing)
        XCTAssertEqual(compressed?.series.daily.first?.totalTokens, 150)
        XCTAssertEqual(compressed?.readFailureCount, 0)
    }

    func testCompressedAliasWinsWhenBothAliasesResolveToSameFile() async throws {
        let home = try CodexLogFixture.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let target = home.appendingPathComponent("payload")
        try compress(rows(input: 100, output: 50)).write(to: target)
        let sessions = home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        for name in ["one.jsonl", "other.jsonl.zst"] {
            try FileManager.default.createSymbolicLink(at: sessions.appendingPathComponent(name), withDestinationURL: target)
        }
        let scan = await CodexLogFixture.scanner(home: home).scan(now: now, pricing: pricing)
        XCTAssertEqual(scan?.series.daily.first?.totalTokens, 150)
        XCTAssertEqual(scan?.readFailureCount, 0)
    }

    private func rows(input: Int, output: Int, model: String = "gpt-5.2") -> Data {
        Data(CodexLogFixture.tokenCount(
            timestamp: OpenUsageISO8601.string(from: now.addingTimeInterval(-60)),
            last: CodexLogFixture.usage(input: input, output: output), model: model
        ).utf8)
    }

    private func write(_ data: Data, _ relative: String, under root: URL) throws {
        let file = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
    }

    private func compress(_ input: Data) throws -> Data {
        var output = Data(count: ZSTD_compressBound(input.count))
        let capacity = output.count
        let count = input.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { target in
                ZSTD_compress(target.baseAddress, capacity, source.baseAddress, source.count, 1)
            }
        }
        guard ZSTD_isError(count) == 0 else { throw CocoaError(.coderInvalidValue) }
        output.count = count
        return output
    }
}
