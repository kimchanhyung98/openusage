import Foundation
import Network

/// provider HTTP 요청의 선택적 proxy 라우팅 — `~/.openusage/config.json`의 `{"proxy": {"enabled": true, "url": ...}}` 사용.
/// 시작 시 1회 로드 — 파일 수정 후 앱 재시작 필요. 부재·비활성·무효·읽기 불가 config는 proxy off. URL 내장 credential 지원, loopback host는 항상 proxy 우회.
struct ProxyConfig: Equatable, Sendable {
    enum Scheme: String, Equatable, Sendable {
        case socks5
        case http
        case https

        var defaultPort: UInt16 {
            switch self {
            case .socks5: return 1080
            case .http: return 80
            case .https: return 443
            }
        }
    }

    var scheme: Scheme
    var host: String
    var port: UInt16
    var username: String?
    var password: String?

    static let configPath = "~/.openusage/config.json"

    /// 앱 전역 proxy — 첫 사용 시 디스크에서 정확히 1회 read.
    static let current: ProxyConfig? = load(
        text: try? String(
            contentsOfFile: NSString(string: configPath).expandingTildeInPath,
            encoding: .utf8
        )
    )

    /// config 파일 텍스트 파싱 — `proxy.enabled == true` + 유효한 socks5/http/https URL이 아니면 `nil`(원본이 문서화한 silent-disable 동작).
    static func load(text: String?) -> ProxyConfig? {
        guard let text,
              let data = text.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let proxy = root["proxy"] as? [String: Any],
              proxy["enabled"] as? Bool == true,
              let urlString = proxy["url"] as? String,
              let url = URL(string: urlString),
              let schemeRaw = url.scheme?.lowercased(),
              let scheme = Scheme(rawValue: schemeRaw),
              let host = url.host(), !host.isEmpty
        else { return nil }

        return ProxyConfig(
            scheme: scheme,
            host: host,
            port: url.port.flatMap { UInt16(exactly: $0) } ?? scheme.defaultPort,
            username: url.user(percentEncoded: false),
            password: url.password(percentEncoded: false)
        )
    }

    /// 이 config가 기술하는 Network framework proxy — loopback 항상 제외.
    func proxyConfiguration() -> ProxyConfiguration {
        let endpoint = NWEndpoint.hostPort(host: .init(host), port: .init(rawValue: port)!)
        var configuration: ProxyConfiguration
        switch scheme {
        case .socks5:
            configuration = ProxyConfiguration(socksv5Proxy: endpoint)
        case .http:
            configuration = ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: nil)
        case .https:
            configuration = ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: NWProtocolTLS.Options())
        }
        if let username, let password {
            configuration.applyCredential(username: username, password: password)
        }
        configuration.excludedDomains = ["localhost", "127.0.0.1", "::1"]
        return configuration
    }
}
