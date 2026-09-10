import XCTest
@testable import OpenUsage

final class AppDiagnosticsTests: XCTestCase {
    private var directory: URL!
    private var originalSink: LogFile!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppDiagnosticsTests." + UUID().uuidString)
        originalSink = AppLog.sink
        AppLog.sink = LogFile(directory: directory, fileName: "diagnostics.log")
        AppLog.sink.open()
        AppLog.reloadLevel(.debug)
    }

    override func tearDownWithError() throws {
        AppLog.sink = originalSink
        AppLog.reloadLevel()
        try FileManager.default.removeItem(at: directory)
    }

    private func lines() throws -> [String] {
        try String(contentsOf: directory.appendingPathComponent("diagnostics.log"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }

    func testFailureKeepsLocalErrorIdentityAndPublishesOneSafeEvent() throws {
        let diagnostics = DiagnosticEventRecorder()
        let error = NSError(domain: "FixtureDiagnosticError", code: 17,
                            userInfo: [NSLocalizedDescriptionKey: "PRIVATE_ERROR_TOKEN_AND_ACCOUNT"])
        AppDiagnostics.failure(.resetVoteFetch, error: error, providerID: "codex@profile-private")

        let recorded = try lines()
        XCTAssertEqual(recorded.count, 1)
        let line = try XCTUnwrap(recorded.first)
        XCTAssertTrue(line.contains("[ERROR] [plugin:codex]"), line)
        XCTAssertTrue(line.contains("error_domain=FixtureDiagnosticError"), line)
        XCTAssertTrue(line.contains("error_code=17"), line)
        XCTAssertFalse(line.contains("PRIVATE_ERROR_TOKEN_AND_ACCOUNT"))
        XCTAssertEqual(diagnostics.events, [DiagnosticEvent(.resetVoteFetch, result: .failure, category: .other, providerID: "codex")])
        let eventJSON = String(decoding: try JSONEncoder().encode(diagnostics.events), as: UTF8.self)
        for value in ["FixtureDiagnosticError", "error_code", "PRIVATE_ERROR_TOKEN_AND_ACCOUNT", "profile-private"] {
            XCTAssertFalse(eventJSON.contains(value), eventJSON)
        }
    }

    func testDifferentFailureCodesStayDistinguishableInLocalLog() throws {
        AppDiagnostics.failure(.resetVoteFetch, error: NSError(domain: "VotesFixture", code: 1))
        AppDiagnostics.failure(.resetVoteFetch, error: NSError(domain: "VotesFixture", code: 2))
        let recorded = try lines()
        XCTAssertEqual(recorded.count, 2)
        XCTAssertTrue(recorded[0].contains("error_code=1"), recorded[0])
        XCTAssertTrue(recorded[1].contains("error_code=2"), recorded[1])
    }

    func testPartialFailureIsOneWarningAndOneDiagnostic() throws {
        let diagnostics = DiagnosticEventRecorder()
        AppDiagnostics.record(.cursorPlan, result: .degraded, category: .network, providerID: "cursor")
        let recorded = try lines()
        XCTAssertEqual(recorded.count, 1)
        XCTAssertTrue(recorded[0].contains("[WARN] [plugin:cursor]"), recorded[0])
        XCTAssertEqual(diagnostics.events, [DiagnosticEvent(.cursorPlan, result: .degraded, category: .network, providerID: "cursor")])
    }

    func testExpectedFailureStaysInformationalAndCancellationDoesNotLogAnError() throws {
        let diagnostics = DiagnosticEventRecorder()
        AppDiagnostics.record(.resetCreditFetch, result: .failure, category: .notAvailable, providerID: "codex")
        AppDiagnostics.failure(.credentialRefresh, error: URLError(.cancelled), providerID: "claude@profile-private")
        let recorded = try lines()
        XCTAssertEqual(recorded.count, 1)
        XCTAssertTrue(recorded[0].contains("[INFO]"), recorded[0])
        XCTAssertFalse(recorded[0].contains("[ERROR]"))
        XCTAssertEqual(diagnostics.events.map(\.result), [.failure, .cancelled])
    }
}
