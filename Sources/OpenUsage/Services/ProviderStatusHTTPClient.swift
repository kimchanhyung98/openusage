import Foundation

/// 공개 상태 API 전용 전송 계층 — provider 인증·cookie·cache와 분리하고 redirect를 따르지 않음.
struct ProviderStatusHTTPClient: HTTPClient {
    private static let timeout: TimeInterval = 10

    private let session: URLSession

    init(proxy: ProxyConfig? = ProxyConfig.current) {
        session = URLSession(
            configuration: Self.configuration(proxy: proxy),
            delegate: ProviderStatusRedirectDelegate(),
            delegateQueue: nil
        )
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let urlRequest = try Self.urlRequest(from: request)
        let (data, response) = try await session.data(for: urlRequest)
        return try Self.response(from: response, data: data)
    }

    static func response(from response: URLResponse, data: Data) throws -> HTTPResponse {
        guard let http = response as? HTTPURLResponse else {
            throw ProviderStatusHTTPClientError.invalidResponse
        }

        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            headers[String(describing: key).lowercased()] = String(describing: value)
        }

        return HTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
    }

    static func configuration(proxy: ProxyConfig?) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        if let proxy {
            configuration.proxyConfigurations = [proxy.proxyConfiguration()]
        }
        return configuration
    }

    static func urlRequest(from request: HTTPRequest) throws -> URLRequest {
        let allowedHeaders = request.headers.allSatisfy { key, value in
            key.caseInsensitiveCompare("Accept") == .orderedSame
                && value.caseInsensitiveCompare("application/json") == .orderedSame
        }
        guard request.method == "GET",
              request.body == nil,
              request.url.scheme?.lowercased() == "https",
              request.url.host() != nil,
              request.url.user(percentEncoded: false) == nil,
              request.url.password(percentEncoded: false) == nil,
              allowedHeaders
        else {
            throw ProviderStatusHTTPClientError.invalidRequest
        }

        var urlRequest = URLRequest(
            url: request.url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeout
        )
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        return urlRequest
    }
}

enum ProviderStatusHTTPClientError: Error, Equatable, Sendable {
    case invalidRequest
    case invalidResponse
}

final class ProviderStatusRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
