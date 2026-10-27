import XCTest
import Darwin
@testable import OpenUsage

@MainActor
final class CodexSoftLimitNativeTests: XCTestCase {
    func testNativeAppServerCancelsTwoTurnsAndPreservesServerAndConversations() async throws {
        guard ProcessInfo.processInfo.environment["OPENUSAGE_RUN_CODEX_CONTROL_TEST"] == "1" else {
            throw XCTSkip("Opt-in native Codex fixture requires the installed Codex CLI and Node.js")
        }
        let directory = URL(fileURLWithPath: "/tmp/openusage-soft-limit-e2e-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Fixture directory cleanup failed: \(error)") }
        }
        let socket = directory.appendingPathComponent("control.sock").path
        let ready = directory.appendingPathComponent("ready.json")
        let logURL = directory.appendingPathComponent("server.log")
        XCTAssertTrue(FileManager.default.createFile(atPath: logURL.path, contents: nil))
        let log = try FileHandle(forWritingTo: logURL)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = Process()
        fixture.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        fixture.arguments = ["node", root.appendingPathComponent("script/fixtures/codex_soft_limit_server.mjs").path, directory.path, socket, ready.path]
        fixture.standardOutput = FileHandle.nullDevice
        fixture.standardError = log
        try fixture.run()
        defer {
            if fixture.isRunning { fixture.terminate() }
            fixture.waitUntilExit()
            try? log.close()
        }
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: ready.path) { break }
            guard fixture.isRunning else { throw nativeError("Fixture exited before opening its socket", log: logURL) }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard FileManager.default.fileExists(atPath: ready.path) else { throw nativeError("Fixture socket startup timed out", log: logURL) }
        let readyJSON = try JSONDecoder().decode(ControlJSON.self, from: Data(contentsOf: ready))
        let port = try XCTUnwrap(readyJSON["port"]?.integer)
        let owner = try CodexControlConnection(socketPath: socket)
        defer { owner.close() }
        try await owner.initialize()
        let started = try await owner.request("thread/start", params: .object([
            "cwd": .string(directory.path), "approvalPolicy": .string("never"), "sandbox": .string("read-only")
        ]))
        let id = try XCTUnwrap(started["thread"]?["id"]?.string)
        var threadIDs = [id]
        _ = try await owner.request("turn/start", params: .object([
            "threadId": .string(id), "input": .array([.object(["type": .string("text"), "text": .string("Harmless local Soft Limit cancellation fixture.")])])
        ]))
        let terminal = Process()
        terminal.executableURL = URL(fileURLWithPath: "/usr/bin/expect")
        terminal.currentDirectoryURL = directory
        let terminalReady = directory.appendingPathComponent("terminal.pid")
        terminal.arguments = [root.appendingPathComponent("script/fixtures/codex_soft_limit_terminal.exp").path, directory.path, socket, terminalReady.path]
        terminal.environment = ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin", "CODEX_HOME": directory.path, "TERM": "xterm-256color", "LANG": "en_US.UTF-8"]
        terminal.standardOutput = log
        terminal.standardError = log
        try terminal.run()
        defer {
            if terminal.isRunning { terminal.terminate() }
            terminal.waitUntilExit()
            XCTAssertEqual(terminal.terminationReason, .exit, "Terminal fixture must report child failures")
            XCTAssertEqual(terminal.terminationStatus, 0, "Terminal fixture failed; see the native test log")
        }
        let adapter = CodexSoftLimitAdapter(makeConnection: {
            let connection = try CodexControlConnection(socketPath: socket)
            try await connection.initialize()
            return connection
        })
        defer { adapter.disconnect() }
        var tasks: [SoftLimitTask] = []
        var initialStats = try await stats(port)
        for _ in 0..<100 {
            tasks = try await adapter.runningTasks()
            initialStats = try await stats(port)
            if tasks.count == 2, initialStats.hasActiveStreams(for: tasks) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(tasks.count, 2)
        XCTAssertTrue(initialStats.hasActiveStreams(for: tasks), "Both target turns must reach the local model stream: \(initialStats)")
        guard tasks.count == 2, initialStats.hasActiveStreams(for: tasks) else { return }
        XCTAssertTrue(Set(tasks.map(\.sessionID)).isSuperset(of: threadIDs))
        threadIDs = tasks.map(\.sessionID)
        let terminalPID = try XCTUnwrap(Int32(String(contentsOf: terminalReady, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        let suite = "OpenUsageTests.SoftLimit.Native.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SoftLimitSettingsStore(defaults: defaults)
        settings.enabled = true
        settings.thresholdPercent = 90
        let coordinator = SoftLimitCoordinator(settings: settings, adapters: [adapter], isProviderEnabled: { _ in true }, isCancellationScopeVerified: { _ in true })
        let provider = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor.percent(id: "codex.weekly", provider: provider, title: "Weekly")
            .supportingSoftLimit(.weekly).exportingLimit("weekly", unit: "percent")
        func quota(_ used: Double) -> ProviderSnapshot {
            let observed = Date()
            return .init(
                providerID: provider.id, displayName: provider.displayName,
                lines: [.progress(label: "Weekly", used: used, limit: 100, format: .percent, periodDurationMs: MetricPeriod.weekMs)],
                refreshedAt: observed, liveQuotaObservedAt: observed
            )
        }
        let unverifiedCoordinator = SoftLimitCoordinator(
            settings: settings, adapters: [adapter], isProviderEnabled: { _ in true }
        )
        unverifiedCoordinator.receive(quota(95), descriptors: [descriptor])
        await unverifiedCoordinator.check()
        XCTAssertEqual(unverifiedCoordinator.status(for: "codex").phase, .unsupported)
        let unverifiedTasks = try await adapter.runningTasks()
        XCTAssertEqual(unverifiedTasks.count, 2, "An unverified account scope must not interrupt either real task")
        let unverifiedStats = try await stats(port)
        XCTAssertTrue(unverifiedStats.hasActiveStreams(for: tasks))

        for used in [89.0, 90.0] {
            coordinator.receive(quota(used), descriptors: [descriptor])
            await coordinator.check()
            if used < 90 {
                let stillRunning = try await adapter.runningTasks()
                XCTAssertEqual(stillRunning.count, 2, "Below the threshold both real tasks must keep running")
            }
        }
        XCTAssertEqual(coordinator.status(for: "codex").phase, .cancelled)
        XCTAssertEqual(coordinator.status(for: "codex").cancelledCount, 2)
        XCTAssertTrue(fixture.isRunning, "The local App Server must survive task cancellation")
        XCTAssertTrue(terminal.isRunning)
        XCTAssertEqual(kill(terminalPID, 0), 0, "The interactive Codex terminal client must survive cancellation")
        let remaining = try await adapter.runningTasks()
        XCTAssertTrue(remaining.isEmpty)
        for id in threadIDs {
            let history = try await owner.request("thread/read", params: .object(["threadId": .string(id), "includeTurns": .bool(true)]))
            let turns = try XCTUnwrap(history["thread"]?["turns"]?.array)
            XCTAssertEqual(turns.last?["status"]?.string, "interrupted")
            XCTAssertFalse(turns.last?["items"]?.array?.isEmpty ?? true, "Conversation input must remain after interruption")
        }
        var finalStats = try await stats(port)
        for _ in 0..<50 {
            if finalStats.hasClosedStreams(for: tasks) { break }
            try await Task.sleep(for: .milliseconds(100))
            finalStats = try await stats(port)
        }
        XCTAssertTrue(finalStats.hasClosedStreams(for: tasks), "Every model stream for both target turns must close: \(finalStats)")
        XCTAssertEqual(kill(terminalPID, 0), 0)
        let targetStreams = finalStats.streams(for: tasks)
        print("Native Codex fixture: interrupted=2, serverAlive=\(fixture.isRunning), terminalAlive=\(kill(terminalPID, 0) == 0), conversations=2, targetStreams=\(targetStreams.count), closedTargetStreams=\(targetStreams.filter(\.closed).count), totalOpened=\(finalStats.opened), totalClosed=\(finalStats.closed), directory=\(directory.path)")
    }

    func testStreamReadinessRequiresBothTargetTurnsInsteadOfBackgroundRequests() {
        let first = SoftLimitTask(providerID: "codex", sessionID: "first", operationID: "turn-a")
        let second = SoftLimitTask(providerID: "codex", sessionID: "second", operationID: "turn-b")
        let pending = FixtureStats(opened: 2, closed: 0, requests: [
            .init(threadId: first.sessionID, turnId: first.operationID, closed: false),
            .init(threadId: "title", turnId: "title-turn", closed: false)
        ])
        XCTAssertFalse(pending.hasActiveStreams(for: [first, second]))
        XCTAssertFalse(pending.hasActiveStreams(for: []))

        let ready = FixtureStats(opened: 3, closed: 0, requests: pending.requests + [
            .init(threadId: second.sessionID, turnId: second.operationID, closed: false)
        ])
        XCTAssertTrue(ready.hasActiveStreams(for: [first, second]))
        XCTAssertFalse(ready.hasClosedStreams(for: [first, second]))
    }

    func testStreamClosureRequiresEveryRequestForTheExactTargetTurns() {
        let first = SoftLimitTask(providerID: "codex", sessionID: "first", operationID: "turn-a")
        let second = SoftLimitTask(providerID: "codex", sessionID: "second", operationID: "turn-b")
        let backgroundClosed = FixtureStats(opened: 3, closed: 2, requests: [
            .init(threadId: first.sessionID, turnId: first.operationID, closed: true),
            .init(threadId: "title", turnId: "title-turn", closed: true),
            .init(threadId: second.sessionID, turnId: second.operationID, closed: false)
        ])
        XCTAssertFalse(backgroundClosed.hasClosedStreams(for: [first, second]))
        XCTAssertFalse(backgroundClosed.hasClosedStreams(for: []))

        let targetsClosed = FixtureStats(opened: 3, closed: 2, requests: [
            .init(threadId: first.sessionID, turnId: first.operationID, closed: true),
            .init(threadId: second.sessionID, turnId: second.operationID, closed: true),
            .init(threadId: second.sessionID, turnId: "different-turn", closed: false)
        ])
        XCTAssertTrue(targetsClosed.hasClosedStreams(for: [first, second]))
        let retryOpen = FixtureStats(opened: 4, closed: 2, requests: targetsClosed.requests + [
            .init(threadId: second.sessionID, turnId: second.operationID, closed: false)
        ])
        XCTAssertFalse(retryOpen.hasClosedStreams(for: [first, second]))
        let missingTurn = SoftLimitTask(providerID: "codex", sessionID: first.sessionID, operationID: "unseen-turn")
        XCTAssertFalse(targetsClosed.hasClosedStreams(for: [first, missingTurn]))
    }

    private func stats(_ port: Int) async throws -> FixtureStats {
        let request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/stats")!, cachePolicy: .reloadIgnoringLocalCacheData)
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(FixtureStats.self, from: data)
    }

    private func nativeError(_ message: String, log: URL) -> NSError {
        let detail = (try? String(contentsOf: log, encoding: .utf8)) ?? "No fixture log"
        return NSError(domain: "CodexSoftLimitNativeTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(message): \(detail.suffix(3000))"])
    }

    private struct FixtureStats: Decodable {
        struct Request: Decodable {
            let threadId: String?
            let turnId: String?
            let closed: Bool
        }

        let opened: Int
        let closed: Int
        let requests: [Request]

        func streams(for tasks: [SoftLimitTask]) -> [Request] {
            requests.filter { request in
                tasks.contains { $0.sessionID == request.threadId && $0.operationID == request.turnId }
            }
        }

        func hasActiveStreams(for tasks: [SoftLimitTask]) -> Bool {
            !tasks.isEmpty && tasks.allSatisfy { task in streams(for: [task]).contains { !$0.closed } }
        }

        func hasClosedStreams(for tasks: [SoftLimitTask]) -> Bool {
            !tasks.isEmpty && tasks.allSatisfy { task in
                let matching = streams(for: [task])
                return !matching.isEmpty && matching.allSatisfy(\.closed)
            }
        }
    }
}
