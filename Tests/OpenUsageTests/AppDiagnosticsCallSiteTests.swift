import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class AppDiagnosticsCallSiteTests: XCTestCase {
    func testTerminalHelperFailureWritesOneLocalErrorAndOneDiagnostic() throws {
        let capture = try Capture()
        defer { capture.cleanUp() }
        let source = capture.directory.appendingPathComponent("helper")
        try Data().write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
        let installer = CommandLineToolInstaller(
            sourcePath: source.path,
            destinationPath: capture.directory.appendingPathComponent("bin/helper").path,
            performPrivileged: { _, _, _ in .failure("PRIVATE_AUTHORIZATION_MESSAGE", code: -60005) }
        )

        installer.install()

        let lines = try capture.lines()
        XCTAssertEqual(lines.count, 1, lines.joined(separator: "\n"))
        XCTAssertTrue(lines.allSatisfy { $0.contains("[ERROR]") })
        XCTAssertTrue(lines.contains { $0.contains("error_code=-60005") })
        XCTAssertFalse(lines.joined().contains("PRIVATE_AUTHORIZATION_MESSAGE"))
        XCTAssertEqual(capture.events, [DiagnosticEvent(.cliInstall, result: .failure, category: .permission)])
        XCTAssertEqual(installer.status, .notInstalled)
        XCTAssertEqual(installer.errorMessage, "Couldn't install the terminal helper: PRIVATE_AUTHORIZATION_MESSAGE")
    }

    func testVotePayloadFailuresKeepDistinctLocalCodesWithoutRemotePayload() async throws {
        let capture = try Capture()
        defer { capture.cleanUp() }
        let bodies = [
            #"{"episode_id":"PRIVATE_EPISODE","yes":1,"no":1}"#,
            #"{"episode_id":"123","yes":-1,"no":0}"#,
            #"{"private":"PRIVATE_JSON_VALUE"}"#
        ]
        for body in bodies {
            let response = HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
            let result = await CodexResetWatchVotes.load(
                http: ResponseClient(response: response),
                endpoint: URL(string: "https://example.invalid/votes")!,
                episodeID: "123"
            )
            XCTAssertNil(result.percent)
            XCTAssertNotNil(result.retryNotBefore)
        }

        let lines = try capture.lines()
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines.allSatisfy { $0.contains("[ERROR]") })
        let causes = lines.compactMap { line -> String? in
            guard let domain = line.range(of: "error_domain=") else { return nil }
            return String(line[domain.lowerBound...])
        }
        XCTAssertEqual(Set(causes).count, 3, lines.joined(separator: "\n"))
        XCTAssertTrue(causes.allSatisfy { $0.contains("error_code=") })
        XCTAssertFalse(lines.joined().contains("PRIVATE_EPISODE"))
        XCTAssertFalse(lines.joined().contains("PRIVATE_JSON_VALUE"))
        let expected = DiagnosticEvent(.resetVoteFetch, result: .failure, category: .decoding, providerID: "codex")
        let events = capture.events
        XCTAssertEqual(events, Array(repeating: expected, count: 3))
        let encoded = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertFalse(encoded.contains("error_domain"))
        XCTAssertFalse(encoded.contains("PRIVATE_"))
    }

    func testEmptyVotesRemainUnavailableWithoutAnErrorLog() async throws {
        let capture = try Capture()
        defer { capture.cleanUp() }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let response = HTTPResponse(statusCode: 200, headers: [:], body: Data(
            #"{"episode_id":"123","yes":0,"no":0}"#.utf8
        ))

        let result = await CodexResetWatchVotes.load(
            http: ResponseClient(response: response),
            endpoint: URL(string: "https://example.invalid/votes")!,
            episodeID: "123",
            now: { now }
        )

        XCTAssertNil(result.percent)
        XCTAssertEqual(result.retryNotBefore, now.addingTimeInterval(60))
        let lines = try capture.lines()
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines.allSatisfy { $0.contains("[INFO]") })
        XCTAssertEqual(capture.events, [
            DiagnosticEvent(.resetVoteFetch, result: .failure, category: .notAvailable, providerID: "codex")
        ])
    }

    func testUsageReadFailureWritesOneWarningPerNewFailureWithoutPathDisclosure() async throws {
        let capture = try Capture()
        defer { capture.cleanUp() }
        let reporter = UsageLogReadFailureReporter(logTag: "plugin:codex")
        let privatePath = "/Users/private/account/session.jsonl"
        _ = await reporter.update(checkedPaths: [privatePath], failingPaths: [privatePath])
        _ = await reporter.update(checkedPaths: [privatePath], failingPaths: [privatePath])
        _ = await reporter.update(checkedPaths: [privatePath], failingPaths: [])
        _ = await reporter.update(checkedPaths: [privatePath], failingPaths: [privatePath])

        let lines = try capture.lines()
        XCTAssertEqual(lines.count, 2, lines.joined(separator: "\n"))
        XCTAssertTrue(lines.allSatisfy { $0.contains("[WARN]") })
        XCTAssertTrue(lines.allSatisfy { $0.contains("Could not read 1 local usage log file") })
        XCTAssertFalse(lines.joined().contains("session.jsonl"))
        XCTAssertEqual(capture.events, [
            DiagnosticEvent(.historyScan, result: .degraded, category: .storage, providerID: "codex"),
            DiagnosticEvent(.historyScan, result: .success, providerID: "codex"),
            DiagnosticEvent(.historyScan, result: .degraded, category: .storage, providerID: "codex")
        ])
    }

    func testPiUsageReadFailureKeepsLocalScannerSourceWithoutAddingRemoteProvider() async throws {
        let capture = try Capture()
        defer { capture.cleanUp() }
        let reporter = UsageLogReadFailureReporter(logTag: "plugin:pi")
        let privatePath = "/Users/private/account/pi-session.jsonl"
        _ = await reporter.update(checkedPaths: [privatePath], failingPaths: [privatePath])

        let lines = try capture.lines()
        XCTAssertEqual(lines.count, 1, lines.joined(separator: "\n"))
        XCTAssertTrue(lines.allSatisfy { $0.contains("[WARN]") && $0.contains("source=plugin:pi") })
        XCTAssertFalse(lines.joined().contains("pi-session.jsonl"))
        XCTAssertFalse(lines.joined().contains("/Users/private/account"))
        let events = capture.events
        XCTAssertEqual(events, [DiagnosticEvent(.historyScan, result: .degraded, category: .storage)])
        XCTAssertNil(events.first?.provider)
        let encoded = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertFalse(encoded.contains("plugin:pi"))
        XCTAssertFalse(encoded.contains("source="))
    }

    func testPiInvalidNumbersReportOnePrivateSummaryAndCacheAggregationDoesNotRepeatIt() throws {
        let capture = try Capture()
        defer { capture.cleanUp() }
        let bad = #"{"type":"message","id":"PRIVATE_ID","timestamp":"2026-09-12T10:00:00Z","message":{"role":"assistant","provider":"anthropic","model":"PRIVATE_MODEL","usage":{"input":-123456789,"totalTokens":150}}}"#
        let entries = PiUsageScanner.parseFile(Data((bad + "\n" + bad).utf8))
        for _ in 0..<2 {
            let scan = PiUsageScanner.aggregate(entries: entries, cardID: "claude", since: .distantPast, pricing: .empty)
            XCTAssertEqual(scan.rejectedNumericRows, 2)
        }

        let lines = try capture.lines()
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines.first?.contains("source=pi; invalid_numeric_rows=2") == true)
        XCTAssertFalse(lines.joined().contains("PRIVATE_"))
        XCTAssertFalse(lines.joined().contains("123456789"))
        XCTAssertEqual(capture.events, [DiagnosticEvent(.historyScan, result: .degraded, category: .decoding)])
        let encoded = String(decoding: try JSONEncoder().encode(capture.events), as: UTF8.self)
        XCTAssertFalse(encoded.contains("pi"))
        XCTAssertFalse(encoded.contains("invalid_numeric_rows"))
        XCTAssertFalse(encoded.contains("PRIVATE_"))
    }

    func testNativeInvalidNumbersLogOnceBeforeRepeatedAggregation() throws {
        let capture = try Capture()
        defer { capture.cleanUp() }
        let claude = ClaudeLogUsageScanner.parseFile(Data(#"{"timestamp":"2026-09-12T10:00:00Z","message":{"model":"PRIVATE_MODEL","usage":{"input_tokens":-123456789,"output_tokens":0}}}"#.utf8))
        let codex = CodexLogUsageScanner.parseFile(Data(#"{"timestamp":"2026-09-12T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":-123456789}}}}"#.utf8))
        for _ in 0..<2 {
            let scans = [ClaudeLogUsageScanner.aggregate(entries: claude, since: .distantPast, pricing: .empty),
                         CodexLogUsageScanner.aggregate(events: codex, since: .distantPast, pricing: .empty)]
            XCTAssertEqual(DailyUsageAccumulator.merged(scans)?.rejectedNumericRows, 2)
        }
        let lines = try capture.lines()
        XCTAssertEqual(lines.count, 2)
        for source in ["claude", "codex"] {
            XCTAssertTrue(lines.contains { $0.contains("source=\(source); invalid_numeric_rows=1") })
        }
        XCTAssertFalse(lines.joined().contains("PRIVATE_"))
        XCTAssertFalse(lines.joined().contains("123456789"))
        XCTAssertEqual(capture.events.count, 2)
    }

    func testRestoredNumericMarkersReportOnceWithoutReparsingOrRepeatedAggregation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let claudeHome = directory.appendingPathComponent("claude")
        let codexHome = directory.appendingPathComponent("codex")
        let piHome = directory.appendingPathComponent("pi").resolvingSymlinksInPath()
        let now = try XCTUnwrap(OpenUsageISO8601.date(from: "2026-09-14T00:00:00Z"))
        let claudeCache = try await seedNumericCache(
            data: Data(#"{"timestamp":"2026-09-12T10:00:00Z","message":{"model":"PRIVATE_MODEL","usage":{"input_tokens":-1,"output_tokens":0}}}"#.utf8),
            path: claudeHome.appendingPathComponent("projects/session.jsonl"), namespace: "claude",
            schema: ClaudeLogUsageScanner.cacheSchemaVersion, identity: "claude-home", parse: ClaudeLogUsageScanner.parseFile)
        let codexCache = try await seedNumericCache(
            data: Data(#"{"timestamp":"2026-09-12T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":-1}}}}"#.utf8),
            path: codexHome.appendingPathComponent("sessions/session.jsonl"), namespace: "codex",
            schema: CodexLogUsageScanner.cacheSchemaVersion, identity: "codex-home", parse: CodexLogUsageScanner.parseFile)
        let piCache = try await seedNumericCache(
            data: Data(#"{"type":"message","timestamp":"2026-09-12T10:00:00Z","message":{"role":"assistant","provider":"anthropic","model":"PRIVATE_MODEL","usage":{"input":-1}}}"#.utf8),
            path: piHome.appendingPathComponent("session.jsonl"), namespace: "pi",
            schema: PiUsageScanner.cacheSchemaVersion, identity: piHome.path, parse: PiUsageScanner.parseFile)
        let capture = try Capture()
        defer { capture.cleanUp() }
        let claudeIncremental = IncrementalJSONLScanner<ClaudeLogUsageScanner.Entry>(persistence: claudeCache)
        let codexIncremental = IncrementalJSONLScanner<CodexLogUsageScanner.Event>(persistence: codexCache)
        let piIncremental = IncrementalJSONLScanner<PiUsageScanner.Entry>(persistence: piCache)
        let claude = ClaudeLogUsageScanner(incrementalScanner: claudeIncremental,
                                           cacheIdentityOverride: "claude-home", rootsOverride: [claudeHome])
        let codex = CodexLogUsageScanner(incrementalScanner: codexIncremental,
                                         cacheIdentityOverride: "codex-home", rootsOverride: [codexHome])
        let pi = PiUsageScanner(environment: FakeEnvironment(["PI_CODING_AGENT_SESSION_DIR": piHome.path]),
                                incrementalScanner: piIncremental)
        for _ in 0..<2 {
            let scans = [await claude.scan(now: now, pricing: .empty), await codex.scan(now: now, pricing: .empty),
                         await pi.scan(cardID: "claude", now: now, pricing: .empty)]
            for scan in scans {
                XCTAssertEqual(scan?.rejectedNumericRows, 1)
                XCTAssertNotNil(scan?.numericWarning)
                XCTAssertNil(scan?.usageHistory)
            }
        }
        // fixture와 전역 로그 sink 정리 전에 지연 저장 완료 — 다음 테스트의 로그 캡처로 오류가 새지 않도록 보장.
        await claudeIncremental.waitForPendingWritesForTesting()
        await codexIncremental.waitForPendingWritesForTesting()
        await piIncremental.waitForPendingWritesForTesting()
        XCTAssertFalse(try capture.lines().contains { $0.contains("could not persist") })
        XCTAssertEqual(capture.events.count, 3)
        let lines = try capture.lines().filter { $0.contains("invalid_numeric_rows") }
        XCTAssertEqual(lines.count, 3)
        for source in ["claude", "codex", "pi"] {
            XCTAssertTrue(lines.contains { $0.contains("source=\(source); invalid_numeric_rows=1") })
        }
        XCTAssertFalse(lines.joined().contains("PRIVATE_MODEL"))
    }

    private func seedNumericCache<Item: Codable & Sendable>(
        data: Data, path: URL, namespace: String, schema: Int, identity: String,
        parse: @Sendable @escaping (Data) -> [Item]?
    ) async throws -> JSONLScanCachePersistence {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: path)
        let mtime = try XCTUnwrap(path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let persistence = JSONLScanCachePersistence(namespace: namespace, schemaVersion: schema,
            directory: path.deletingLastPathComponent().appendingPathComponent("cache"), writeDebounce: .milliseconds(1))
        let scanner = IncrementalJSONLScanner<Item>(persistence: persistence)
        _ = await scanner.items(from: [.init(path: path.resolvingSymlinksInPath().path, size: data.count, mtime: mtime)],
                                since: .distantPast, cacheIdentity: identity, parse: parse)
        await scanner.waitForPendingWritesForTesting()
        return persistence
    }

    func testClaimFallbackKeepsAccountCandidatesAndRecordsOnlyFinalFailure() async throws {
        let capture = try Capture()
        defer { capture.cleanUp() }
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let http = RoutingHTTPClient { request in
            let account = request.headers["ChatGPT-Account-Id"]
            if request.url == CodexUsageClient.resetCreditsURL {
                if account == "PRIVATE_ACCOUNT_A" {
                    return HTTPResponse(statusCode: 401, headers: [:], body: Data())
                }
                let body = #"{"credits":[{"id":"PRIVATE_CREDIT","expires_at":1800000000}]}"#
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
            }
            XCTAssertEqual(request.url, CodexUsageClient.consumeResetCreditURL)
            let status = account == "PRIVATE_ACCOUNT_B" ? 403 : 500
            return HTTPResponse(statusCode: status, headers: [:], body: Data("PRIVATE_RESPONSE_BODY".utf8))
        }
        let service = CodexResetClaimService(
            usageClient: CodexUsageClient(http: http),
            credentialCandidates: {
                [("PRIVATE_SHARED_TOKEN", "PRIVATE_ACCOUNT_A"), ("PRIVATE_SHARED_TOKEN", "PRIVATE_ACCOUNT_B")]
            },
            refreshAfterClaim: { XCTFail("A failed claim must not refresh an account") }
        )

        let outcome = await service.claim(creditExpiringAt: expiry, redeemRequestID: "PRIVATE_REQUEST_ID")

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(http.requests.map { $0.headers["ChatGPT-Account-Id"] },
                       ["PRIVATE_ACCOUNT_A", "PRIVATE_ACCOUNT_B", "PRIVATE_ACCOUNT_B", "PRIVATE_ACCOUNT_A"])
        XCTAssertEqual(http.requests.map(\.method), ["GET", "GET", "POST", "POST"])
        let lines = try capture.lines()
        XCTAssertEqual(lines.count, 1, lines.joined(separator: "\n"))
        XCTAssertTrue(lines.allSatisfy { $0.contains("[ERROR]") && $0.contains("consume failed (HTTP 500)") })
        XCTAssertFalse(lines.joined().contains("PRIVATE_"))
        let events = capture.events
        XCTAssertEqual(events, [DiagnosticEvent(.resetClaim, result: .failure, category: .http(500), providerID: "codex")])
        let encoded = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertFalse(encoded.contains("PRIVATE_"))
        XCTAssertFalse(encoded.contains("500"))
    }

    func testMalformedClaimResponsesWriteOneFinalFailurePerOperation() async throws {
        for malformedList in [true, false] {
            let capture = try Capture()
            defer { capture.cleanUp() }
            let http = RoutingHTTPClient { request in
                let body: String
                if request.url == CodexUsageClient.resetCreditsURL, !malformedList {
                    body = #"{"credits":[{"id":"PRIVATE_CREDIT","expires_at":1800000000}]}"#
                } else {
                    body = "PRIVATE_MALFORMED_RESPONSE"
                }
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
            }
            let service = CodexResetClaimService(
                usageClient: CodexUsageClient(http: http),
                credentialCandidates: { [("PRIVATE_TOKEN", "PRIVATE_ACCOUNT")] },
                refreshAfterClaim: { XCTFail("Malformed responses must not refresh an account") }
            )

            let result = await service.claim(
                creditExpiringAt: Date(timeIntervalSince1970: 1_800_000_000),
                redeemRequestID: "PRIVATE_REQUEST"
            )

            XCTAssertEqual(result, .failed)
            XCTAssertEqual(http.requests.count, malformedList ? 1 : 2)
            let lines = try capture.lines()
            XCTAssertEqual(lines.count, 1, lines.joined(separator: "\n"))
            XCTAssertTrue(lines.allSatisfy { $0.contains("[ERROR]") })
            XCTAssertFalse(lines.joined().contains("PRIVATE_"))
            XCTAssertEqual(capture.events, [
                DiagnosticEvent(.resetClaim, result: .failure, category: .decoding, providerID: "codex")
            ])
        }
    }

    private struct ResponseClient: HTTPClient {
        let response: HTTPResponse
        func send(_ request: HTTPRequest) async throws -> HTTPResponse { response }
    }

    private final class Capture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        private let diagnostics = DiagnosticEventRecorder()
        var events: [DiagnosticEvent] { diagnostics.events }
        private let previousSink: LogFile

        init() throws {
            previousSink = AppLog.sink
            let sink = LogFile(directory: directory, fileName: "diagnostics.log")
            sink.open()
            AppLog.sink = sink
            AppLog.reloadLevel(.info)
        }

        func lines() throws -> [String] {
            try String(contentsOf: directory.appendingPathComponent("diagnostics.log"), encoding: .utf8)
                .split(separator: "\n").map(String.init)
        }

        func cleanUp() {
            AppLog.sink = previousSink
            AppLog.reloadLevel()
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
