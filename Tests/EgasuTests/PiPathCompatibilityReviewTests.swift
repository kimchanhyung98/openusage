import XCTest
@testable import Egasu

final class PiPathCompatibilityReviewTests: XCTestCase {
    func testRelativeSessionOverrideIsRejectedButAbsoluteAndHomePathsWork() throws {
        let home = URL(fileURLWithPath: "/fixture-home")
        XCTAssertThrowsError(try PiPaths.sessionsDirectory(
            environment: FakeEnvironment(["PI_CODING_AGENT_SESSION_DIR": "relative/sessions"]), homeDirectory: home
        )) { error in
            guard let settingsError = error as? PiPaths.SettingsError,
                  case .relativeSessionDirectory = settingsError else { return XCTFail("Unexpected error") }
        }
        for (path, expected) in [("/custom", "/custom"), ("~/custom", "/fixture-home/custom")] {
            let directory = try PiPaths.sessionsDirectory(
                environment: FakeEnvironment(["PI_CODING_AGENT_SESSION_DIR": path]), homeDirectory: home
            )
            XCTAssertEqual(directory.path, expected)
        }
    }

    func testOMPDataRootIsReevaluatedAfterDirectoryAppears() async throws {
        let home = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let xdg = home.appendingPathComponent("xdg")
        let env = FakeEnvironment(["XDG_DATA_HOME": xdg.path])
        try UsageRecordFixture.write(line(id: "old", input: 10), to: home.appendingPathComponent(".omp/agent/sessions/old.jsonl"))
        let scanner = PiUsageScanner(environment: env, homeDirectory: { home }, incrementalScanner: IncrementalJSONLScanner())
        let oldResult = await scanner.collect(since: .distantPast)
        XCTAssertEqual(try XCTUnwrap(oldResult).records.map(\.id), ["old"])
        try UsageRecordFixture.write(line(id: "new", input: 20), to: xdg.appendingPathComponent("omp/sessions/new.jsonl"))
        let newResult = await scanner.collect(since: .distantPast)
        XCTAssertEqual(try XCTUnwrap(newResult).records.map(\.id), ["new"])
    }

    func testOMPFieldsInExplicitSessionOverrideAndPiReportedZero() async throws {
        let home = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let custom = home.appendingPathComponent("custom")
        let omp = #"{"type":"message","id":"omp","timestamp":"2026-07-12T10:00:00Z","message":{"role":"assistant","provider":"anthropic","model":"fixture","usage":{"input":100,"output":50,"cacheWrite":100,"totalTokens":280,"reasoningTokens":7,"cttl":{"ephemeral5m":25,"ephemeral1h":75},"orchestration":{"input":30},"cost":{"total":0}}}}"#
        let pi = #"{"type":"message","id":"pi","timestamp":"2026-07-12T10:00:01Z","message":{"role":"assistant","provider":"anthropic","model":"fixture","usage":{"input":10,"output":1,"cost":{"total":0,"totalFromProvider":true}}}}"#
        try UsageRecordFixture.write(omp + "\n" + pi + "\n", to: custom.appendingPathComponent("session.jsonl"))
        let scanner = PiUsageScanner(environment: FakeEnvironment(["PI_CODING_AGENT_SESSION_DIR": custom.path]),
                                     homeDirectory: { home }, incrementalScanner: IncrementalJSONLScanner())
        let collected = await scanner.collect(since: .distantPast)
        let records = try XCTUnwrap(collected).records
        let ompRecord = try XCTUnwrap(records.first { $0.id == "omp" })
        XCTAssertEqual(ompRecord.tokens?.input, 130)
        XCTAssertEqual(ompRecord.tokens?.cacheWrite1h, 75)
        XCTAssertEqual(ompRecord.reasoningTokens, 7)
        let piRecord = try XCTUnwrap(records.first { $0.id == "pi" })
        XCTAssertEqual(piRecord.recordedCostUSD, 0)
        XCTAssertEqual(piRecord.costOrigin, .reported)
        XCTAssertFalse(piRecord.zeroCostIsUnknown)
    }

    func testRelativeAgentPathsAndApplicableXDGAreUnresolved() throws {
        let home = URL(fileURLWithPath: "/fixture-home")
        let relativeAgent = FakeEnvironment(["PI_CODING_AGENT_DIR": "agent"])
        XCTAssertThrowsError(try PiPaths.sessionsDirectory(environment: relativeAgent, homeDirectory: home))
        XCTAssertNil(PiPaths.ompSessionsDirectory(environment: relativeAgent, homeDirectory: home))
        let sessionOverride = FakeEnvironment([
            "PI_CODING_AGENT_DIR": "agent", "PI_CODING_AGENT_SESSION_DIR": "/sessions"
        ])
        XCTAssertEqual(try PiPaths.sessionsDirectory(environment: sessionOverride, homeDirectory: home).path, "/sessions")
        XCTAssertNil(PiPaths.ompSessionsDirectory(environment: sessionOverride, homeDirectory: home))

        let relativeXDG = FakeEnvironment(["XDG_DATA_HOME": "data"])
        XCTAssertNil(PiPaths.ompSessionsDirectory(environment: relativeXDG, homeDirectory: home))
        let defaultAgent = FakeEnvironment(["PI_CODING_AGENT_DIR": "~/.omp/agent", "XDG_DATA_HOME": "data"])
        XCTAssertNil(PiPaths.ompSessionsDirectory(environment: defaultAgent, homeDirectory: home))
        let explicitAgent = FakeEnvironment(["PI_CODING_AGENT_DIR": "/custom", "XDG_DATA_HOME": "data"])
        XCTAssertEqual(PiPaths.ompSessionsDirectory(environment: explicitAgent, homeDirectory: home)?.path,
                       "/custom/sessions")
        let namedProfile = FakeEnvironment(["OMP_PROFILE": "work", "PI_CODING_AGENT_DIR": "relative"])
        XCTAssertEqual(PiPaths.ompSessionsDirectory(environment: namedProfile, homeDirectory: home)?.path,
                       "/fixture-home/.omp/profiles/work/agent/sessions")
        let invalidProfile = FakeEnvironment(["OMP_PROFILE": "../bad", "XDG_DATA_HOME": "data"])
        XCTAssertNil(PiPaths.ompSessionsDirectory(environment: invalidProfile, homeDirectory: home))
    }

    func testRelativePathReportsFailureWhileAbsolutePiOverrideStillCollects() async throws {
        let home = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let sessions = home.appendingPathComponent("sessions")
        try UsageRecordFixture.write(line(id: "pi", input: 10), to: sessions.appendingPathComponent("session.jsonl"))
        let env = FakeEnvironment(["PI_CODING_AGENT_DIR": "relative", "PI_CODING_AGENT_SESSION_DIR": sessions.path])
        let scanner = PiUsageScanner(environment: env, homeDirectory: { home }, incrementalScanner: IncrementalJSONLScanner())
        let collected = await scanner.collect(since: .distantPast)
        let result = try XCTUnwrap(collected)
        XCTAssertEqual(result.records.map(\.id), ["pi"])
        XCTAssertEqual(result.sources.first { $0.sourceID == "omp" }?.failedStores, 1)
        XCTAssertEqual(result.sources.first { $0.sourceID == "pi" }?.failedStores, 0)
        let xdgScanner = PiUsageScanner(environment: FakeEnvironment(["XDG_DATA_HOME": "relative"]),
                                        homeDirectory: { home }, incrementalScanner: IncrementalJSONLScanner())
        let xdgCollected = await xdgScanner.collect(since: .distantPast)
        let xdgResult = try XCTUnwrap(xdgCollected)
        XCTAssertEqual(xdgResult.sources.first { $0.sourceID == "omp" }?.failedStores, 1)
    }

    private func line(id: String, input: Int) -> String {
        """
        {"type":"message","id":"\(id)","timestamp":"2026-07-12T10:00:00Z","message":{"role":"assistant","provider":"anthropic","model":"fixture","usage":{"input":\(input),"output":0,"cost":{"total":0}}}}
        """
    }
}
