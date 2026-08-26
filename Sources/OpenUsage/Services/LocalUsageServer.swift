import Foundation
import Network

/// `127.0.0.1:6736`의 read-only usage API용 loopback 전용 HTTP/1.1 listener — 앱과 함께 시작.
/// port 선점 시 세션 동안 조용히 비활성(원본 앱과 동일). 동시 요청 최대 16 — 초과 연결은 즉시 `503 {"error":"server_busy"}`.
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
            AppLog.info(.localAPI, "disabled: \(error.localizedDescription)")
            return
        }

        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                // 대부분 port 선점 — 이번 세션 동안 조용히 비활성.
                AppLog.info(.localAPI, "disabled: \(error.localizedDescription)")
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
                    self.finish(connection, with: nil)
                } else {
                    self.receiveHead(connection, buffered: buffered)
                }
            }
        }
    }

    func route(head: String) -> LocalUsageAPI.Response {
        let (method, path) = Self.parseRequestLine(head)
        // path는 secret-free(loopback API는 정규화된 usage만 서빙) — Debug 전용.
        AppLog.debug(.localAPI, "\(method) \(path)")
        return LocalUsageAPI.respond(
            method: method,
            path: path,
            state: state().redactingAccountNamesForBrowserWire()
        )
    }

    /// HTTP request line을 `(method, path)`로 파싱 — 비어 있거나 malformed head 허용.
    /// request line 부재는 trap 대신 일반 `404`로 라우팅 — 과거 force-index가 loopback payload로 `@MainActor` 프로세스 전체를 crash. `nonisolated` + pure로 listener 없이 unit-test 가능.
    nonisolated static func parseRequestLine(_ head: String) -> (method: String, path: String) {
        guard let requestLine = head.split(separator: "\r\n", maxSplits: 1).first else {
            return ("", "/")
        }
        let parts = requestLine.split(separator: " ")
        let method = parts.indices.contains(0) ? String(parts[0]) : ""
        let path = parts.indices.contains(1) ? String(parts[1]) : "/"
        return (method, path)
    }

    private func finish(_ connection: NWConnection, with response: LocalUsageAPI.Response?) {
        activeConnections -= 1
        if let response {
            Self.send(response, over: connection)
        } else {
            connection.cancel()
        }
    }

    private nonisolated static func send(_ response: LocalUsageAPI.Response, over connection: NWConnection) {
        let reason: String = switch response.status {
        case 200: "OK"
        case 204: "No Content"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 503: "Service Unavailable"
        default: "OK"
        }
        var head = "HTTP/1.1 \(response.status) \(reason)\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Access-Control-Allow-Methods: GET, OPTIONS\r\n"
        head += "Access-Control-Allow-Headers: Content-Type\r\n"
        head += "Connection: close\r\n"
        if let body = response.body {
            head += "Content-Type: application/json\r\n"
            head += "Content-Length: \(body.count)\r\n\r\n"
            connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
                connection.cancel()
            })
        } else {
            head += "Content-Length: 0\r\n\r\n"
            connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}
