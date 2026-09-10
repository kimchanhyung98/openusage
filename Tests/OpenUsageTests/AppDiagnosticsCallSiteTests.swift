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
