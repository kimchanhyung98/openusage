import Foundation
import Network

/// `127.0.0.1:6736`의 read-only usage API용 loopback 전용 HTTP/1.1 listener — 앱과 함께 시작.
/// port 선점 시 오류 기록 후 세션 동안 비활성. 동시 요청 최대 16 — 초과 연결은 즉시 `503 {"error":"server_busy"}`.
@MainActor
final class LocalUsageServer {
    static let port: UInt16 = 6736
    private static let maxConcurrentConnections = 16
    private static let headLimit = 8192

    private let state: @MainActor () -> LocalUsageAPI.State
    private let queue = DispatchQueue(label: "openusage.local-api")
    private var listener: NWListener?
    private var activeConnections = 0

    init(state: @escaping @MainActor () -> LocalUsageAPI.State) {
        self.state = state
    }

    func start() {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: Self.port)!
        )

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            AppDiagnostics.failure(.localAPIListen, error: error,
                                   localContext: "Local API listener could not be created; disabled for this session")
            return
        }

        listener.stateUpdateHandler = { state in
            if case .ready = state { AppDiagnostics.record(.localAPIListen, result: .success) }
            if case .failed(let error) = state {
                // 대부분 port 선점 — 이번 세션 동안 비활성.
                AppDiagnostics.failure(.localAPIListen, error: error,
                                       localContext: "Local API listener failed; disabled for this session")
            }
        }
        listener.newConnectionHandler = { connection in
            Task { @MainActor [weak self] in
                self?.accept(connection)
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        guard activeConnections < Self.maxConcurrentConnections else {
            AppDiagnostics.record(.localAPIRequest, result: .failure, category: .rateLimited)
            Self.send(LocalUsageAPI.busy, over: connection)
            return
        }
        activeConnections += 1
        receiveHead(connection, buffered: Data())
    }

    /// 요청 head 끝(`\r\n\r\n`)까지 read — GET/OPTIONS body는 무관, router는 head만 필요.
    private func receiveHead(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.headLimit) { data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else {
                    connection.cancel()
                    return
                }
                var buffered = buffered
                if let data {
                    buffered.append(data)
                }
                if let headEnd = buffered.range(of: Data("\r\n\r\n".utf8)) {
                    let head = String(data: buffered[..<headEnd.lowerBound], encoding: .utf8) ?? ""
                    self.finish(connection, with: self.route(head: head))
                } else if error != nil || isComplete || buffered.count >= Self.headLimit {
                    if let error { Self.recordTransportFailure(error) }
                    self.finish(connection, with: nil)
                } else {
                    self.receiveHead(connection, buffered: buffered)
                }
            }
        }
    }

    nonisolated static func recordTransportFailure(_ error: NWError) {
        switch error {
        case .posix(.ECONNRESET), .posix(.EPIPE):
            AppDiagnostics.record(.localAPIRequest, result: .cancelled)
        default:
            AppDiagnostics.failure(.localAPIRequest, error: error)
        }
    }

    func route(head: String) -> LocalUsageAPI.Response {
        guard let request = Self.parseRequestHead(head), Self.isAllowedHost(request.headers["host"]) else {
            AppDiagnostics.record(.localAPIRequest, result: .failure, category: .http4xx)
            return LocalUsageAPI.badRequest
        }
        guard request.headers["origin"] == nil else {
            AppDiagnostics.record(.localAPIRequest, result: .failure, category: .permission)
            return LocalUsageAPI.forbidden
        }
        let method = request.method
        let path = request.path
        // 외부 입력은 고정 route·method 분류만 기록 — 계정 경로·쿼리·임의 문자열 제외.
        AppLog.debug(.localAPI, "\(Self.logMethod(method)) \(Self.logRoute(path))")
        return LocalUsageAPI.respond(
            method: method,
            path: path,
            state: state().redactingAccountNamesForLocalWire()
        )
    }

    private nonisolated static func logMethod(_ method: String) -> String {
        method == "GET" ? method : "other"
    }

    private nonisolated static func logRoute(_ path: String) -> String {
        let route = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        for base in ["/v1/limits", "/v1/usage"] {
            if route == base { return base }
            if route.hasPrefix(base + "/") { return base + "/provider" }
        }
        return "unknown"
    }

    /// HTTP request line을 `(method, path)`로 파싱 — 부재 시 빈 method와 기본 경로 반환.
    /// 빈 request line은 호출부의 request head 검증에서 `400`으로 거부.
    nonisolated static func parseRequestLine(_ head: String) -> (method: String, path: String) {
        guard let requestLine = head.split(separator: "\r\n", maxSplits: 1).first else {
            return ("", "/")
        }
        let parts = requestLine.split(separator: " ")
        let method = parts.indices.contains(0) ? String(parts[0]) : ""
        let path = parts.indices.contains(1) ? String(parts[1]) : "/"
        return (method, path)
    }

    struct RequestHead: Equatable, Sendable {
        var method: String
        var path: String
        var headers: [String: [String]]
    }

    nonisolated static func parseRequestHead(_ head: String) -> RequestHead? {
        let lines = head.components(separatedBy: "\r\n")
        guard let first = lines.first, !first.isEmpty else { return nil }
        let (method, path) = parseRequestLine(first)
        guard !method.isEmpty else { return nil }

        var headers: [String: [String]] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let separator = line.firstIndex(of: ":") else { return nil }
            let name = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !name.isEmpty else { return nil }
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name, default: []].append(value)
        }
        return RequestHead(method: method, path: path, headers: headers)
    }

    nonisolated static func isAllowedHost(_ values: [String]?) -> Bool {
        guard let values, values.count == 1 else { return false }
        switch values[0].lowercased() {
        case "127.0.0.1", "127.0.0.1:\(port)", "localhost", "localhost:\(port)":
            return true
        default:
            return false
        }
    }

    private func finish(_ connection: NWConnection, with response: LocalUsageAPI.Response?) {
        activeConnections -= 1
        if let response {
            Self.send(response, over: connection)
        } else {
            connection.cancel()
        }
    }

    nonisolated static func serializedResponse(_ response: LocalUsageAPI.Response) -> Data {
        let reason: String = switch response.status {
        case 200: "OK"
        case 204: "No Content"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 503: "Service Unavailable"
        default: "OK"
        }
        var head = "HTTP/1.1 \(response.status) \(reason)\r\n"
        head += "Connection: close\r\n"
        if let body = response.body {
            head += "Content-Type: application/json\r\n"
            head += "Content-Length: \(body.count)\r\n\r\n"
            return Data(head.utf8) + body
        } else {
            head += "Content-Length: 0\r\n\r\n"
            return Data(head.utf8)
        }
    }

    private nonisolated static func send(_ response: LocalUsageAPI.Response, over connection: NWConnection) {
        connection.send(content: serializedResponse(response), completion: .contentProcessed { error in
            if let error { Self.recordTransportFailure(error) }
            connection.cancel()
        })
    }
}
