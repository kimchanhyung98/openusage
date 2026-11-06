import XCTest
@testable import OpenUsage

@MainActor
final class KiroUsageScannerTests: XCTestCase {
    private let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 12))!

    func testSavedCreditAndTextHistoryFeedsExistingPeriods() throws {
        let result = try result(history())
        let lines = result.totalSpendLines(now: now)

        XCTAssertEqual(value(lines, "Today", .dollars), 0.1)
        XCTAssertEqual(value(lines, "Today", .count), 5)
        XCTAssertEqual(value(lines, "Last 30 Days", .count), 5)
        XCTAssertNil(value(lines, "Yesterday", .dollars))
        guard case .values(_, let values, _, _, _, _) = lines.first else { return XCTFail("missing totals") }
        XCTAssertTrue(values.allSatisfy(\.estimated))
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testInputIncludesSavedContextAgainAfterToolResult() throws {
        var data = try prefix()
        data += try row("reason", ["type": "assistant", "operationType": "Reasoning", "content": "12345678", "executionId": "turn"])
        data += try row("say-1", ["type": "assistant", "content": "abcd", "executionId": "turn"])
        data += try row("tool", ["type": "tool_call", "args": [:], "executionId": "turn"])
        data += try row("result", ["type": "tool_result", "content": "abcd", "executionId": "turn"])
        data += try row("say-2", ["type": "assistant", "content": "abcdefgh", "executionId": "turn"])
        data += try summary("turn", credits: 3)

        let usage = try result(data)

        XCTAssertEqual(usage.daily.first?.tokens, 14)
        XCTAssertEqual(usage.daily.first?.costUSD, 0.12)
    }

    func testStreamingUpdatesUseFinalMessageOnce() throws {
        var data = try prefix()
        data += try row("reply", ["type": "assistant", "content": "abcd", "executionId": "turn"])
        data += try row("reply", ["type": "assistant", "content": "abcdefgh", "executionId": "turn"])
        data += try summary("turn", credits: 2.5)

        XCTAssertEqual(try result(data).daily.first?.tokens, 5)
    }

    func testModelFallbackRemovesAbandonedContextButKeepsConsumedUsage() throws {
        var data = try prefix()
        data += try row("abandoned", ["type": "assistant", "content": String(repeating: "a", count: 400),
                                     "executionId": "turn"])
        data += try row("fallback", ["type": "session_metadata", "key": "modelFallback", "executionId": "turn",
                                    "value": ["from": "model-a", "to": "model-b", "trigger": "refusal",
                                              "abandonedMessageIds": ["abandoned", "abandoned", "missing"]]])
        data += try summary("turn", credits: 1)
        data += try row("user-2", ["type": "user", "content": "abcdefgh"])
        data += try row("start-2", ["type": "turn_start", "executionId": "next"])
        data += try row("reply-2", ["type": "assistant", "content": "abcd", "executionId": "next"])
        data += try summary("next", credits: 1)

        let parsed = try KiroUsageScanner.parse(data)

        XCTAssertEqual(parsed.records.map(\.tokens), [103, 6])
        XCTAssertEqual(parsed.records.map(\.costUSD), [0.04, 0.04])
        XCTAssertEqual(parsed.invalidRows, 0)
    }

    func testAppliedFallbackWithoutAbandonedMessagesStartsAnotherRequestInSameTurn() throws {
        var data = try prefix()
        data += try row("reply-1", ["type": "assistant", "content": "abcd", "executionId": "turn"])
        data += try row("fallback", ["type": "session_metadata", "key": "modelFallback", "executionId": "turn",
                                    "value": ["from": "model-a", "to": "model-b", "trigger": "capacity"]])
        data += try row("reply-2", ["type": "assistant", "content": "abcd", "executionId": "turn"])
        data += try summary("turn", credits: 2)

        let usage = try result(data)

        XCTAssertEqual(usage.daily.first?.tokens, 9)
        XCTAssertEqual(usage.daily.first?.costUSD, 0.08)
        XCTAssertTrue(usage.warnings.isEmpty)
    }

    func testDeclinedFallbackDoesNotStartAnotherRequest() throws {
        var data = try prefix()
        data += try row("reply-1", ["type": "assistant", "content": "abcd", "executionId": "turn"])
        data += try row("declined", ["type": "session_metadata", "key": "modelFallback", "executionId": "turn",
                                    "value": ["from": "model-a", "trigger": "refusal", "reason": "unsafeToReissue"]])
        data += try row("reply-2", ["type": "assistant", "content": "abcd", "executionId": "turn"])
        data += try summary("turn", credits: 1)

        let usage = try result(data)

        XCTAssertEqual(usage.daily.first?.tokens, 5)
        XCTAssertEqual(usage.daily.first?.costUSD, 0.04)
        XCTAssertTrue(usage.warnings.isEmpty)
    }

    func testRewindChangesFutureContextButKeepsConsumedUsage() throws {
        var data = try history(credits: 1)
        data += try row("rewind", ["type": "tombstone", "kind": "checkpoint_revert", "effectiveFromMessageId": "user"])
        data += try row("user-2", ["type": "user", "content": "abcd"])
        data += try row("start-2", ["type": "turn_start", "executionId": "next"])
        data += try row("reply-2", ["type": "assistant", "content": "abcd", "executionId": "next"])
        data += try summary("next", credits: 1)

        let usage = try result(data)

        XCTAssertEqual(usage.daily.first?.tokens, 9)
        XCTAssertEqual(usage.daily.first?.costUSD, 0.08)
    }

    func testCompactionSummaryReplacesRemovedContextWithoutInventingARequest() throws {
        var data = try history(credits: 1)
        data += try row("compact", ["type": "tombstone", "kind": "summarization", "effectiveFromMessageId": "user"])
        data += try row("summary", ["type": "assistant", "operationType": "Summary", "content": "abcd"])
        data += try row("user-2", ["type": "user", "content": "abcd"])
        data += try row("start-2", ["type": "turn_start", "executionId": "next"])
        data += try row("reply-2", ["type": "assistant", "content": "abcd", "executionId": "next"])
        data += try summary("next", credits: 1)

        XCTAssertEqual(try result(data).daily.first?.tokens, 10)
    }

    func testCostOnlyTurnOmitsTokensForItsWholePeriod() throws {
        let data = try history() + summary("without-history", credits: 1, date: now.addingTimeInterval(-86_400))
        let usage = try result(data)
        let lines = usage.totalSpendLines(now: now)

        XCTAssertEqual(value(lines, "Today", .count), 5)
        XCTAssertNil(value(lines, "Yesterday", .count))
        XCTAssertNil(value(lines, "Last 30 Days", .count))
        XCTAssertEqual(try XCTUnwrap(value(lines, "Last 30 Days", .dollars)), 0.14, accuracy: 0.000001)
        XCTAssertEqual(usage.warnings.count, 1)
    }

    func testModelRouteNoteReplacesContextWithoutCountingItAsOutput() throws {
        var data = try history(credits: 1)
        data += try row("route", ["type": "model_route", "fromModel": "model-a", "toModel": "model-b",
                                 "reason": "classifier", "handoffMode": "compacted"])
        data += try row("compact", ["type": "tombstone", "kind": "summarization", "effectiveFromMessageId": "user"])
        data += try row("note", ["type": "agent_note", "content": "saved notes!", "noteUserRequests": ["abcd"]])
        data += try row("start-2", ["type": "turn_start", "executionId": "next"])
        data += try row("reply-2", ["type": "assistant", "content": "abcd", "executionId": "next"])
        data += try summary("next", credits: 1)

        let parsed = try KiroUsageScanner.parse(data)

        XCTAssertEqual(parsed.records.map(\.tokens), [5, 6])
        XCTAssertEqual(parsed.records.map(\.costUSD), [0.04, 0.04])
        XCTAssertEqual(parsed.invalidRows, 0)
    }

    func testInvalidCreditsAndFinishedBadJSONWarnWhileActiveTailWaits() throws {
        var data = try history()
        for (index, bad) in [true, -1, "1", "NaN"].enumerated() {
            data += try row("bad-\(index)", ["type": "usage_summary", "executionId": "bad-\(index)",
                                           "promptTurnSummaries": [["unit": "credit", "usage": bad]]])
        }
        data += try row("wrong-unit", ["type": "usage_summary", "executionId": "wrong-unit",
                                     "promptTurnSummaries": [["unit": "tokens", "usage": 999]]])
        data += Data("bad-json\n{\"id\":\"unfinished\"".utf8)

        let usage = try result(data)

        XCTAssertEqual(usage.invalidRows, 6)
        XCTAssertEqual(usage.daily.first?.costUSD, 0.1)
        XCTAssertEqual(usage.daily.first?.tokens, 5)
    }

    func testCalendarWindowUsesLocalDayAndExcludesFutureAndOldTurns() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 9 * 3600)!
        let midnight = calendar.startOfDay(for: now)
        let dates = [midnight.addingTimeInterval(-1), midnight, now.addingTimeInterval(1),
                     calendar.date(byAdding: .day, value: -31, to: midnight)!]
        let parsed = KiroUsageScanner.Parsed(records: dates.enumerated().map { index, date in
            .init(id: String(index), timestamp: date, costUSD: 0.1, tokens: 10)
        })

        let usage = KiroUsageScanner.aggregate(parsed, now: now, calendar: calendar)

        XCTAssertEqual(usage.daily.count, 2)
        XCTAssertEqual(usage.daily.reduce(0) { $0 + $1.tokens }, 20)
    }

    func testOverflowIsRejectedWithoutCrashingPeriodTotals() {
        let records = [
            KiroUsageScanner.Record(id: "a", timestamp: now, costUSD: 0.1, tokens: Int.max),
            KiroUsageScanner.Record(id: "b", timestamp: now, costUSD: 0.1, tokens: 1),
            KiroUsageScanner.Record(id: "c", timestamp: now, costUSD: .infinity, tokens: 0)
        ]
        let usage = KiroUsageScanner.aggregate(.init(records: records), now: now)

        XCTAssertEqual(usage.invalidRows, 2)
        XCTAssertEqual(value(usage.totalSpendLines(now: now), "Last 30 Days", .count), Double(Int.max))
    }

    func testFutureDuplicateDoesNotReplaceAValidTurn() {
        let parsed = KiroUsageScanner.Parsed(records: [
            .init(id: "turn", timestamp: now, costUSD: 0.1, tokens: 5),
            .init(id: "turn", timestamp: now.addingTimeInterval(1), costUSD: 100, tokens: 5_000)
        ])

        let usage = KiroUsageScanner.aggregate(parsed, now: now)

        XCTAssertEqual(usage.daily.first?.tokens, 5)
        XCTAssertEqual(usage.daily.first?.costUSD, 0.1)
    }

    func testForkCopiesCountOnceAndChildFilesDoNotDuplicateParentCredits() async throws {
        let fixture = try KiroHistoryFixture()
        defer { fixture.remove() }
        let original = try history()
        var fork = original
        fork += try row("user-2", ["type": "user", "content": "abcd"])
        fork += try row("start-2", ["type": "turn_start", "executionId": "next"])
        fork += try row("reply-2", ["type": "assistant", "content": "abcd", "executionId": "next"])
        fork += try summary("next", credits: 2)
        let first = try fixture.write(original, session: "original")
        let second = try fixture.write(fork, session: "fork")
        let child = second.deletingLastPathComponent().appendingPathComponent("sub-executions/child.jsonl")
        try FileManager.default.createDirectory(at: child.deletingLastPathComponent(), withIntermediateDirectories: true)
        try summary("child", credits: 100).write(to: child)

        let usage = try await fixture.scanner.scan(now: now)

        XCTAssertEqual(usage?.daily.first?.tokens, 12)
        XCTAssertEqual(try XCTUnwrap(usage?.daily.first?.costUSD), 0.18, accuracy: 0.000001)
        XCTAssertEqual(try Data(contentsOf: first), original)
        XCTAssertEqual(try Data(contentsOf: second), fork)
    }

    func testMissingAndEmptyStoresDoNotInventUsage() async throws {
        let fixture = try KiroHistoryFixture()
        defer { fixture.remove() }
        let missing = try await fixture.scanner.scan(now: now)
        XCTAssertNil(missing)
        _ = try fixture.write(Data())
        let empty = try await fixture.scanner.scan(now: now)
        XCTAssertEqual(empty?.totalSpendLines(now: now), [])
    }

    func testKiroHomeSelectsV3ProfileWithoutMergingDefaultHistory() async throws {
        let fixture = try KiroHistoryFixture()
        defer { fixture.remove() }
        _ = try fixture.write(history(credits: 100))
        let profile = fixture.home.appendingPathComponent("separate-profile")
        _ = try fixture.write(history(credits: 2), kiroHome: profile)
        let scanner = KiroUsageScanner(environment: FakeEnvironment(["KIRO_HOME": profile.path]), homeDirectory: fixture.home)

        let usage = try await scanner.scan(now: now)

        XCTAssertEqual(usage?.daily.first?.costUSD, 0.08)
        XCTAssertEqual(usage?.daily.first?.tokens, 5)
    }

    func testMissingKiroHomeProfileDoesNotFallBackToDefaultHistory() async throws {
        let fixture = try KiroHistoryFixture()
        defer { fixture.remove() }
        _ = try fixture.write(history())
        let scanner = KiroUsageScanner(environment: FakeEnvironment([
            "KIRO_HOME": fixture.home.appendingPathComponent("missing-profile").path
        ]), homeDirectory: fixture.home)

        let usage = try await scanner.scan(now: now)

        XCTAssertNil(usage)
    }

    func testInvalidKiroHomePathsUseDefaultProfile() async throws {
        let fixture = try KiroHistoryFixture()
        defer { fixture.remove() }
        _ = try fixture.write(history())
        let invalidPaths = [
            "", "relative-profile", "~/profile", "/", fixture.home.path, fixture.home.path + "/",
            fixture.home.deletingLastPathComponent().path, fixture.home.path + "/.."
        ]
        for path in invalidPaths {
            let scanner = KiroUsageScanner(environment: FakeEnvironment(["KIRO_HOME": path]), homeDirectory: fixture.home)

            let usage = try await scanner.scan(now: now)

            XCTAssertEqual(usage?.daily.first?.costUSD, 0.1, path)
            XCTAssertEqual(usage?.daily.first?.tokens, 5, path)
        }
    }

    func testKiroHomeAcceptsSiblingWithSharedHomePrefix() async throws {
        let fixture = try KiroHistoryFixture()
        defer { fixture.remove() }
        let userHome = fixture.home.appendingPathComponent("user")
        let profile = fixture.home.appendingPathComponent("user-profile")
        _ = try fixture.write(history(), kiroHome: profile)
        let scanner = KiroUsageScanner(environment: FakeEnvironment(["KIRO_HOME": profile.path]), homeDirectory: userHome)

        let usage = try await scanner.scan(now: now)

        XCTAssertEqual(usage?.daily.first?.costUSD, 0.1)
    }

    func testUnreadableSessionDoesNotDiscardOtherHistory() async throws {
        let fixture = try KiroHistoryFixture()
        defer { fixture.remove() }
        let valid = try fixture.write(history(), session: "valid")
        let unreadable = valid.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("unreadable/messages.jsonl")
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)

        let usage = try await fixture.scanner.scan(now: now)

        XCTAssertEqual(usage?.daily.first?.tokens, 5)
        XCTAssertEqual(usage?.daily.first?.costUSD, 0.1)
        XCTAssertEqual(usage?.invalidRows, 0)
        XCTAssertEqual(usage?.readFailureCount, 1)
    }

    func testProviderFeedsDashboardAndKeepsCreditsSeparate() async throws {
        let fixture = try KiroHistoryFixture()
        defer { fixture.remove() }
        _ = try fixture.write(history())
        let provider = provider(fixture)

        let snapshot = await provider.refresh()
        let total = TotalSpendAggregator.total(for: .today, providers: [provider.provider], snapshots: ["kiro": snapshot])

        XCTAssertEqual(snapshot.lines.map(\.label), ["Credits"])
        XCTAssertEqual(total.slices.first?.tokenCount, 5)
        XCTAssertEqual(total.slices.first?.amountUSD, 0.1)
        XCTAssertTrue(total.slices.first?.estimated == true)
        XCTAssertTrue(total.projection(for: .tokens).isEstimated)
        XCTAssertTrue(total.projection(for: .tokens).slices.first?.estimated == true)
        XCTAssertNil(snapshot.errorCategory)
    }

    func testHistoryRemainsAvailableWhenQuotaLoginIsMissing() async throws {
        let fixture = try KiroHistoryFixture()
        defer { fixture.remove() }
        _ = try fixture.write(history())

        let snapshot = await provider(fixture, authenticated: false).refresh()

        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
        XCTAssertEqual(value(snapshot.totalSpendLines ?? [], "Today", .count), 5)
    }

    func testUnreadableHistoryKeepsQuotaAndReportsFailure() async throws {
        let fixture = try KiroHistoryFixture()
        defer { fixture.remove() }
        let log = fixture.home.appendingPathComponent(".kiro/sessions/workspace/session/messages.jsonl")
        try FileManager.default.createDirectory(at: log, withIntermediateDirectories: true)

        let snapshot = await provider(fixture).refresh()

        XCTAssertEqual(snapshot.lines.map(\.label), ["Credits"])
        XCTAssertNil(snapshot.totalSpendLines)
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertTrue(snapshot.isDegraded == true)
        XCTAssertEqual(snapshot.warningPresentation?.count, 1)
        XCTAssertEqual(snapshot.warning, "Some local usage files could not be read. Usage history may be incomplete.")
    }

    private func result(_ data: Data) throws -> KiroUsageScanner.Result {
        KiroUsageScanner.aggregate(try KiroUsageScanner.parse(data), now: now)
    }

    private func prefix() throws -> Data {
        try row("system", ["type": "session_start", "content": "12345678"])
            + row("user", ["type": "user", "content": "abcd"])
            + row("start", ["type": "turn_start", "executionId": "turn"])
    }

    private func history(credits: Double = 2.5) throws -> Data {
        try prefix() + row("reply", ["type": "assistant", "content": "abcdefgh", "executionId": "turn"])
            + summary("turn", credits: credits)
    }

    private func summary(_ execution: String, credits: Double, date: Date? = nil) throws -> Data {
        try row("\(execution)-usage", ["type": "usage_summary", "executionId": execution,
                                    "promptTurnSummaries": [["unit": "credit", "unitPlural": "credits", "usage": credits]]],
                date: date)
    }

    private func row(_ id: String, _ payload: [String: Any], date: Date? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "id": id, "timestamp": OpenUsageISO8601.string(from: date ?? now.addingTimeInterval(-1)), "payload": payload
        ]) + Data([0x0A])
    }

    private func value(_ lines: [MetricLine], _ label: String, _ kind: MetricKind) -> Double? {
        guard case .values(_, let values, _, _, _, _) = lines.first(where: { $0.label == label }) else { return nil }
        return values.first(where: { $0.kind == kind })?.number
    }

    private func provider(_ fixture: KiroHistoryFixture, authenticated: Bool = true) -> KiroProvider {
        KiroProvider(
            authStore: KiroAuthStore(sqlite: KiroHistoryAuthSQLite(authenticated: authenticated)),
            usageClient: KiroUsageClient(http: FakeHTTPClient(response: HTTPResponse(
                statusCode: 200, headers: [:], body: Data(#"{"subscriptionInfo":{"subscriptionTitle":"Kiro Pro"},"usageBreakdownList":[{"resourceType":"CREDIT","currentUsageWithPrecision":10.25,"usageLimitWithPrecision":50.0}]}"#.utf8)
            ))), usageScanner: fixture.scanner, now: { [now] in now }
        )
    }
}

private struct KiroHistoryFixture {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var scanner: KiroUsageScanner { KiroUsageScanner(environment: FakeEnvironment(), homeDirectory: home) }

    init() throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func write(_ data: Data, session: String = "session", kiroHome: URL? = nil) throws -> URL {
        let root = kiroHome ?? home.appendingPathComponent(".kiro")
        let log = root.appendingPathComponent("sessions/workspace/\(session)/messages.jsonl")
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: log)
        return log
    }

    func remove() { try? FileManager.default.removeItem(at: home) }
}

private struct KiroHistoryAuthSQLite: SQLiteAccessing {
    let authenticated: Bool
    func queryValue(path: String, sql: String) throws -> String? {
        authenticated ? #"{"access_token":"fixture","expires_at":"2099-01-01T00:00:00Z","profile_arn":"fixture-profile"}"# : nil
    }
    func execute(path: String, sql: String) throws {}
}
