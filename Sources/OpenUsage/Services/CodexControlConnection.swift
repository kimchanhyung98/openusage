import Darwin
import Foundation
import Network

enum ControlJSON: Codable, Sendable, Equatable {
    case object([String: Self]), array([Self]), string(String), number(Double), bool(Bool), null

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let object = try? value.decode([String: Self].self) { self = .object(object) }
        else if let array = try? value.decode([Self].self) { self = .array(array) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else { self = .number(try value.decode(Double.self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let object): try value.encode(object)
        case .array(let array): try value.encode(array)
        case .string(let string): try value.encode(string)
        case .number(let number): try value.encode(number)
        case .bool(let bool): try value.encode(bool)
        case .null: try value.encodeNil()
        }
    }

    subscript(_ key: String) -> Self? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    var string: String? { if case .string(let value) = self { value } else { nil } }
    var array: [Self]? { if case .array(let value) = self { value } else { nil } }
    var integer: Int? {
        guard case .number(let value) = self, value.isFinite,
              value.rounded() == value, value >= Double(Int32.min), value <= Double(Int32.max)
        else { return nil }
        return Int(value)
    }
}

@MainActor
protocol CodexControlRequesting: AnyObject {
    func request(_ method: String, params: ControlJSON) async throws -> ControlJSON
    func close()
}

/// 로컬 Unix socket의 WebSocket 제어 채널 — AI process 실행·종료 없음.
@MainActor
final class CodexControlConnection: CodexControlRequesting {
    private struct Pending {
        let continuation: CheckedContinuation<ControlJSON, any Error>
        let deadline: Task<Void, Never>
    }

    private let transport: NWConnection
    private var pending: [Int: Pending] = [:]
    private var nextID = 0
    private var codec = CodexWebSocketCodec()
    private var queued: [Data] = []
    private var closed = false
    private let timeout: Duration
    private static let maxFrameBytes = 1_048_576

    init(socketPath: String, timeout: Duration = .seconds(5)) throws {
        try Self.validateSocket(socketPath)
        self.timeout = timeout
        transport = NWConnection(to: .unix(path: socketPath), using: .tcp)
        transport.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .failed = state { self?.close() }
                if case .waiting = state { self?.close() }
            }
        }
        transport.start(queue: DispatchQueue(label: "com.openusage.soft-limit.codex"))
        write(codec.handshake)
        receiveNext()
    }

    func initialize() async throws {
        _ = try await request("initialize", params: .object([
            "clientInfo": .object(["name": .string("openusage_soft_limit"), "version": .string("1")]),
            "capabilities": .object(["experimentalApi": .bool(true)])
        ]))
        try send(.object(["method": .string("initialized"), "params": .object([:])]))
    }

    isolated deinit { close() }

    func request(_ method: String, params: ControlJSON) async throws -> ControlJSON {
        try Task.checkCancellation()
        guard !closed else { throw SoftLimitControlError.disconnected }
        nextID += 1
        let id = nextID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let deadline = Task { [weak self, timeout] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.finish(id: id, result: .failure(SoftLimitControlError.timedOut))
                }
                pending[id] = Pending(continuation: continuation, deadline: deadline)
                do {
                    try send(.object(["id": .number(Double(id)), "method": .string(method), "params": params]))
                } catch {
                    finish(id: id, result: .failure(error))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id: id, result: .failure(CancellationError())) }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        transport.stateUpdateHandler = nil
        transport.cancel()
        queued.removeAll()
        failAll(SoftLimitControlError.disconnected)
    }

    private func send(_ message: ControlJSON) throws {
        guard !closed else { throw SoftLimitControlError.disconnected }
        let data = try JSONEncoder().encode(message)
        guard data.count <= Self.maxFrameBytes else { throw SoftLimitControlError.invalidResponse }
        let frame = try CodexWebSocketCodec.frame(data)
        if codec.ready { write(frame) } else { queued.append(frame) }
    }

    private func write(_ data: Data) {
        transport.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil { Task { @MainActor in self?.close() } }
        })
    }

    private func receiveNext() {
        transport.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                guard error == nil else { self.close(); return }
                do {
                    for event in try self.codec.receive(data ?? Data()) {
                        switch event {
                        case .ready:
                            for frame in self.queued { self.write(frame) }
                            self.queued.removeAll()
                        case .message(let message): self.receive(message)
                        case .ping(let payload): self.write(try CodexWebSocketCodec.frame(payload, opcode: 10))
                        case .closed: self.close()
                        }
                    }
                } catch { self.failAll(SoftLimitControlError.invalidResponse); self.close() }
                if complete { self.close() }
                if !self.closed { self.receiveNext() }
            }
        }
    }

    private func receive(_ data: Data) {
        guard data.count <= Self.maxFrameBytes,
              let message = try? JSONDecoder().decode(ControlJSON.self, from: data)
        else { failAll(SoftLimitControlError.invalidResponse); close(); return }
        // 기존 UI의 approval 대행 금지 — response만 대조하고 notification·server request 무시.
        guard message["method"] == nil, let id = message["id"]?.integer else { return }
        if let result = message["result"] { finish(id: id, result: .success(result)) }
        else if let error = message["error"] {
            finish(id: id, result: .failure(SoftLimitControlError.rejected(error["code"]?.integer ?? -1)))
        } else { finish(id: id, result: .failure(SoftLimitControlError.invalidResponse)) }
    }

    private func finish(id: Int, result: Result<ControlJSON, any Error>) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.deadline.cancel()
        request.continuation.resume(with: result)
    }

    private func failAll(_ error: any Error) {
        for id in Array(pending.keys) { finish(id: id, result: .failure(error)) }
    }

    static func validateSocket(_ path: String) throws {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw SoftLimitControlError.unsafeEndpoint }
        var info = stat()
        guard path.withCString({ lstat($0, &info) }) == 0 else { throw SoftLimitControlError.unavailable }
        guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            throw SoftLimitControlError.unsafeEndpoint
        }
        let parent = (path as NSString).deletingLastPathComponent
        guard parent.withCString({ lstat($0, &info) }) == 0,
              info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o022 == 0
        else { throw SoftLimitControlError.unsafeEndpoint }
    }
}
