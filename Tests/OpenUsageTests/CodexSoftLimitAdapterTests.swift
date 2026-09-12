import XCTest
@testable import OpenUsage

@MainActor
final class CodexSoftLimitAdapterTests: XCTestCase {
    func testEnumeratesAllPagesAndOnlyActiveOpenAIThreads() async throws {
        let rpc = FixtureCodexControl()
        let adapter = CodexSoftLimitAdapter(makeConnection: { rpc })

        let tasks = try await adapter.runningTasks()

        XCTAssertEqual(Set(tasks.map(\.sessionID)), ["first", "second"])
        XCTAssertTrue(rpc.methods.allSatisfy { ["thread/loaded/list", "thread/read", "thread/turns/list"].contains($0) })
        XCTAssertTrue(rpc.turnRequests.allSatisfy { $0["itemsView"]?.string == "notLoaded" })
    }

    func testCancellationWaitsForInterruptedStateAndNeverDeletesOrClosesSession() async throws {
        let rpc = FixtureCodexControl()
        let adapter = CodexSoftLimitAdapter(makeConnection: { rpc })
        let tasks = try await adapter.runningTasks()
        let task = try XCTUnwrap(tasks.first)

        let outcome = try await adapter.cancel(task, isAuthorized: { true })

        if case .cancelled = outcome {} else { XCTFail("Expected acknowledged cancellation") }
        XCTAssertEqual(rpc.interrupted, [task.sessionID])
        XCTAssertFalse(rpc.methods.contains { $0.contains("delete") || $0.contains("archive") || $0.contains("resume") })
        XCTAssertEqual(rpc.closeCalls, 0)
    }

    func testPermissionIsRecheckedAfterAsynchronousPreflight() async throws {
        let rpc = FixtureCodexControl()
        let adapter = CodexSoftLimitAdapter(makeConnection: { rpc })
        var allowed = true
        rpc.onTurns = { allowed = false }
        do {
            _ = try await adapter.cancel(.init(providerID: "codex", sessionID: "first", operationID: "first-turn"), isAuthorized: { allowed })
            XCTFail("Cancellation should have been revoked")
        } catch is CancellationError {}
        XCTAssertTrue(rpc.interrupted.isEmpty)
    }

    func testDifferentProviderCannotReachControlConnection() async {
        let rpc = FixtureCodexControl()
        let adapter = CodexSoftLimitAdapter(makeConnection: { rpc })
        do {
            _ = try await adapter.cancel(.init(providerID: "claude", sessionID: "first", operationID: "first-turn"), isAuthorized: { true })
            XCTFail("Expected provider rejection")
        } catch {
            XCTAssertEqual(error as? SoftLimitControlError, .wrongProvider)
        }
        XCTAssertTrue(rpc.methods.isEmpty)
    }
}

@MainActor
private final class FixtureCodexControl: CodexControlRequesting {
    var methods: [String] = []
    var turnRequests: [ControlJSON] = []
    var interrupted: Set<String> = []
    var closeCalls = 0
    var onTurns: (@MainActor () -> Void)?

    func request(_ method: String, params: ControlJSON) async throws -> ControlJSON {
        methods.append(method)
        let id = params["threadId"]?.string ?? ""
        switch method {
        case "thread/loaded/list":
            return params["cursor"] == nil
                ? .object(["data": .array([.string("first"), .string("idle"), .string("other-provider")]), "nextCursor": .string("next")])
                : .object(["data": .array([.string("second")]), "nextCursor": .null])
        case "thread/read":
            return .object(["thread": .object([
                "status": .object(["type": .string(id == "idle" ? "idle" : "active")]),
                "modelProvider": .string(id == "other-provider" ? "ollama" : "openai")
            ])])
        case "thread/turns/list":
            turnRequests.append(params)
            onTurns?()
            return .object(["data": .array([.object([
                "id": .string("\(id)-turn"), "status": .string(interrupted.contains(id) ? "interrupted" : "inProgress")
            ])])])
        case "turn/interrupt":
            guard params["turnId"]?.string == "\(id)-turn" else { throw SoftLimitControlError.invalidResponse }
            interrupted.insert(id)
            return .object([:])
        default: throw SoftLimitControlError.invalidResponse
        }
    }

    func close() { closeCalls += 1 }
}
