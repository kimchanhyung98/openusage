import Foundation

@MainActor
final class CodexSoftLimitAdapter: SoftLimitCancelling {
    let providerID = "codex"
    let coverageNotice = "Only tasks on the connected local Codex App Server are protected. Other Codex sessions may still run."
    private let makeConnection: @MainActor () async throws -> any CodexControlRequesting
    private var connection: (any CodexControlRequesting)?
    private var generation = 0

    init(makeConnection: @escaping @MainActor () async throws -> any CodexControlRequesting = CodexSoftLimitAdapter.localConnection) {
        self.makeConnection = makeConnection
    }

    func runningTasks() async throws -> [SoftLimitTask] {
        let client = try await client()
        var tasks: [SoftLimitTask] = []
        var cursor: String?
        var seenCursors: Set<String> = []
        repeat {
            var params: [String: ControlJSON] = ["limit": .number(100)]
            if let cursor { params["cursor"] = .string(cursor) }
            let page = try await client.request("thread/loaded/list", params: .object(params))
            guard let ids = page["data"]?.array else { throw SoftLimitControlError.invalidResponse }
            for value in ids {
                try Task.checkCancellation()
                guard let id = value.string else { throw SoftLimitControlError.invalidResponse }
                let metadata = try await client.request("thread/read", params: .object([
                    "threadId": .string(id), "includeTurns": .bool(false)
                ]))
                guard let thread = metadata["thread"], let status = thread["status"]?["type"]?.string,
                      let modelProvider = thread["modelProvider"]?.string
                else { throw SoftLimitControlError.invalidResponse }
                guard status == "active", modelProvider == "openai" else { continue }
                let turns = try await turns(threadID: id, client: client)
                for turn in turns where turn.status == "inProgress" {
                    tasks.append(.init(providerID: providerID, sessionID: id, operationID: turn.id))
                }
            }
            cursor = page["nextCursor"]?.string
            if let cursor, !seenCursors.insert(cursor).inserted { throw SoftLimitControlError.invalidResponse }
        } while cursor != nil
        return tasks
    }

    func cancel(_ task: SoftLimitTask, isAuthorized: @escaping @MainActor () -> Bool) async throws -> SoftLimitCancellationOutcome {
        guard task.providerID == providerID else { throw SoftLimitControlError.wrongProvider }
        guard isAuthorized() else { throw CancellationError() }
        let client = try await client()
        let before = try await turns(threadID: task.sessionID, client: client)
        guard let turn = before.first(where: { $0.id == task.operationID }) else { throw SoftLimitControlError.invalidResponse }
        guard turn.status == "inProgress" else { return .alreadyFinished }
        try Task.checkCancellation()
        guard isAuthorized() else { throw CancellationError() }
        _ = try await client.request("turn/interrupt", params: .object([
            "threadId": .string(task.sessionID), "turnId": .string(task.operationID)
        ]))
        for _ in 0..<25 {
            try Task.checkCancellation()
            let current = try await turns(threadID: task.sessionID, client: client)
            if let stopped = current.first(where: { $0.id == task.operationID }) {
                if stopped.status == "interrupted" { return .cancelled }
                if stopped.status == "completed" || stopped.status == "failed" { return .alreadyFinished }
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw SoftLimitControlError.timedOut
    }

    func disconnect() {
        generation += 1
        connection?.close()
        connection = nil
    }

    private func client() async throws -> any CodexControlRequesting {
        if let connection { return connection }
        let boundGeneration = generation
        let created = try await makeConnection()
        guard generation == boundGeneration else { created.close(); throw CancellationError() }
        connection = created
        return created
    }

    private func turns(threadID: String, client: any CodexControlRequesting) async throws -> [(id: String, status: String)] {
        let response = try await client.request("thread/turns/list", params: .object([
            "threadId": .string(threadID), "limit": .number(100), "sortDirection": .string("desc"),
            "itemsView": .string("notLoaded")
        ]))
        guard let turns = response["data"]?.array else { throw SoftLimitControlError.invalidResponse }
        return try turns.map { turn in
            guard let id = turn["id"]?.string, let status = turn["status"]?.string,
                  ["inProgress", "interrupted", "completed", "failed"].contains(status)
            else { throw SoftLimitControlError.invalidResponse }
            return (id, status)
        }
    }

    private static func localConnection() async throws -> any CodexControlRequesting {
        let environment = await loadOffMainActor {
            let reader = ProcessEnvironmentReader()
            var values: [String: String] = [:]
            for key in ["CODEX_HOME"] {
                if let value = reader.value(for: key) { values[key] = value }
            }
            return values
        }
        let home = environment["CODEX_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        let path = URL(fileURLWithPath: home).appendingPathComponent("app-server-control/app-server-control.sock").path
        let connection = try CodexControlConnection(socketPath: path)
        do { try await connection.initialize() }
        catch { connection.close(); throw error }
        return connection
    }
}
