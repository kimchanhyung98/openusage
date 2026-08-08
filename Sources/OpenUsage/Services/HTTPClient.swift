import Foundation

struct HTTPRequest: Sendable {
    var method: String
    var url: URL
    var headers: [String: String] = [:]
    var body: Data?
    var timeout: TimeInterval = 15
}

struct HTTPResponse: Sendable {
    var statusCode: Int
    var headers: [String: String]
    var body: Data

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

protocol HTTPClient: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

// header·성공 응답 body 로깅 금지 — `Authorization`/`Cookie`/`Bearer` header와 token 포함 body 유출 방지.
// Debug 라인은 method + redacted URL + status code만; HTTP 에러(>= 400)는 `LogRedaction.bodyPreview`를 통과한 500 byte 이하 preview만 추가 — 전체 body 금지.

struct URLSessionHTTPClient: HTTPClient {
    /// true면 `127.0.0.1` 한정 self-signed TLS cert를 수용하는 loopback 세션 사용 (`LoopbackTLSDelegate`).
    /// 로컬 language server의 self-signed HTTPS 전용 — 기본 off, 원격 호출은 전체 certificate 검증 유지.
    var allowsInsecureLoopback: Bool = false

    /// 모든 provider 요청 공용 세션 — 선택적 `~/.openusage/config.json` proxy 적용해 1회 생성 (`ProxyConfig`).
    /// 유효한 proxy 미설정 시 `URLSession.shared`와 동일한 cookie/cache 의미의 기본 configuration.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        if let proxy = ProxyConfig.current {
            configuration.proxyConfigurations = [proxy.proxyConfiguration()]
            // proxy 적용 사실 기록(지원 로그용) — scheme/host/port만, 내장 `user:pass`는 별도 필드로 로깅 금지.
            AppLog.info(.config, "proxy enabled \(proxy.scheme.rawValue)://\(proxy.host):\(proxy.port)")
        }
        return URLSession(configuration: configuration)
    }()

    /// loopback 전용 세션 — ephemeral(공유 cookie/cache 없음), proxy 없음, `127.0.0.1` 한정 self-signed cert 신뢰 delegate. 1회 생성.
    private static let loopbackSession: URLSession = {
        URLSession(configuration: .ephemeral, delegate: LoopbackTLSDelegate(), delegateQueue: nil)
    }()

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        let session = allowsInsecureLoopback ? Self.loopbackSession : Self.session
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw HTTPClientError.invalidResponse
        }

        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            headers[String(describing: key).lowercased()] = String(describing: value)
        }

        let line = "\(request.method) \(LogRedaction.redactURL(request.url.absoluteString)) -> \(http.statusCode)"
        if http.statusCode >= 400 {
            AppLog.debug(.http, "\(line) body: \(LogRedaction.bodyPreview(String(decoding: data, as: UTF8.self)))")
        } else {
            AppLog.debug(.http, line)
        }
        return HTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
    }
}

enum HTTPClientError: Error, LocalizedError {
    case invalidResponse

    var errorDescription: String? {
        "Invalid HTTP response."
    }
}

/// self-signed 서버 cert를 loopback(`127.0.0.1`)에만 수용 — 그 외 host·non-server-trust challenge는 기본 검증으로 통과, 원격 endpoint 신뢰 약화 없음.
/// mutable 상태 없음 — loopback 세션 간 공유 안전.
private final class LoopbackTLSDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == "127.0.0.1",
              let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

