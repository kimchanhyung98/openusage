import Foundation

/// Cloud Code 호출 결과 — orchestrator가 진짜 auth 실패(refresh 대상)와 일시 장애(다음 base URL/전략 시도, refresh 금지)를 구분하도록 분리.
enum CloudCodeOutcome: Sendable {
    case ok(Data)
    case authFailed
    case unavailable
}

/// 정상 할당량 요약을 서버 우선순위대로 보존한 결과.
enum CloudCodeSummariesOutcome: Sendable {
    case ok([Data])
    case authFailed
    case unavailable
}

/// Google OAuth token refresh 결과 — 죽은 refresh token은 만료된 auth로, 5xx/네트워크 실패는 일시 장애로 읽히도록 분리.
enum TokenRefreshOutcome: Sendable {
    case refreshed(accessToken: String, expiresIn: Double)
    case authFailed
    case unavailable
}

/// Antigravity의 모든 네트워크 I/O: 로컬 language-server RPC(loopback HTTPS, self-signed), Google Cloud Code endpoint, Google OAuth token refresh.
struct AntigravityUsageClient: Sendable {
    static let lsService = "exa.language_server_pb.LanguageServerService"
    static let cloudCodeURLs = [
        "https://cloudcode-pa.googleapis.com",
        "https://daily-cloudcode-pa.googleapis.com"
    ]
    static let fetchModelsPath = "/v1internal:fetchAvailableModels"
    static let loadCodeAssistPath = "/v1internal:loadCodeAssist"
    static let retrieveQuotaPath = "/v1internal:retrieveUserQuota"
    static let quotaSummaryPath = "/v1internal:retrieveUserQuotaSummary"
    static let googleOAuthURL = "https://oauth2.googleapis.com/token"
    // Google OAuth "installed application" client credential — Antigravity 앱 번들에서 그대로 추출(출하된 앱·legacy Tauri plugin과 동일 쌍). installed-app OAuth client의 "secret"은 Google이 기밀로 취급하지 않아(모든 클라이언트 사본에 포함) 커밋은 의도된 trade-off이며 유출된 private key가 아님.
    // refresh-token grant에 필수 — 없으면 앱 종료 상태에서 keychain token refresh 불가.
    static let googleClientID = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
    static let googleClientSecret = "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"
    static let lsMetadata = ["ideName": "antigravity", "extensionName": "antigravity", "ideVersion": "unknown", "locale": "en"]

    /// LS의 self-signed cert를 신뢰하는 loopback 세션 — 원격 호출은 전체 검증.
    var lsHTTP: HTTPClient
    var http: HTTPClient

    init(
        lsHTTP: HTTPClient = URLSessionHTTPClient(allowsInsecureLoopback: true),
        http: HTTPClient = URLSessionHTTPClient()
    ) {
        self.lsHTTP = lsHTTP
        self.http = http
    }

    /// language-server RPC method 호출. transport 실패(live 아닌 port) 시 nil.
    func callLS(scheme: String, port: Int, csrf: String, method: String) async -> HTTPResponse? {
        guard let url = URL(string: "\(scheme)://127.0.0.1:\(port)/\(Self.lsService)/\(method)") else { return nil }
        let body = try? JSONSerialization.data(withJSONObject: ["metadata": Self.lsMetadata])
        let request = HTTPRequest(
            method: "POST",
            url: url,
            headers: [
                "Content-Type": "application/json",
                "Connect-Protocol-Version": "1",
                "x-codeium-csrf-token": csrf
            ],
            body: body,
            timeout: 10
        )
        return try? await lsHTTP.send(request)
    }

    /// 일반 Cloud Code 요청 — 401/403은 즉시 인증 실패, 나머지 오류는 다음 서버 시도.
    func cloudCode(path: String, token: String, userAgent: String, body: [String: String]) async -> CloudCodeOutcome {
        let payload = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        return await cloudCode(path: path, token: token, userAgent: userAgent, payload: payload)
    }

    /// 요금제 응답에 필요한 Antigravity 클라이언트 정보 포함.
    func loadCodeAssist(token: String) async -> CloudCodeOutcome {
        await cloudCode(
            path: Self.loadCodeAssistPath,
            token: token,
            userAgent: Self.clientUserAgent,
            payload: Data(#"{"metadata":{"ideType":"ANTIGRAVITY","platform":"PLATFORM_UNSPECIFIED","pluginType":"GEMINI"}}"#.utf8)
        )
    }

    /// 서버가 요금제 조회를 지원하는 Antigravity 클라이언트 형식.
    private static let clientUserAgent: String = {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "amd64"
        #endif
        return "antigravity/2.24.0 (aidev_client; os_type=darwin; arch=\(architecture))"
    }()

    private func cloudCode(path: String, token: String, userAgent: String, payload: Data) async -> CloudCodeOutcome {
        for base in Self.cloudCodeURLs {
            guard let url = URL(string: base + path) else { continue }
            let request = Self.cloudCodeRequest(url: url, token: token, userAgent: userAgent, payload: payload)
            guard let response = try? await http.send(request) else { continue }
            if response.statusCode == 401 || response.statusCode == 403 { return .authFailed }
            if (200..<300).contains(response.statusCode) { return .ok(response.body) }
        }
        return .unavailable
    }

    /// 부분 요약은 다른 서버에서 보충. 정상 요약이 하나라도 있으면 서버별 인증 오류보다 우선.
    func cloudCodeQuotaSummaries(token: String) async -> CloudCodeSummariesOutcome {
        var bodies: [Data] = []
        var sawAuthFailure = false
        for base in Self.cloudCodeURLs {
            guard let url = URL(string: base + Self.quotaSummaryPath) else { continue }
            let request = Self.cloudCodeRequest(
                url: url, token: token, userAgent: "antigravity", payload: Data("{}".utf8)
            )
            let response: HTTPResponse
            do {
                response = try await http.send(request)
            } catch {
                if (error as? URLError)?.code != .cancelled {
                    AppLog.warn(
                        LogTag.plugin("antigravity"),
                        "quota summary request failed on \(base) (code=\((error as NSError).code), category=\(ErrorCategory.classify(error).rawValue))"
                    )
                }
                continue
            }
            if response.statusCode == 401 || response.statusCode == 403 {
                sawAuthFailure = true
            }
            guard (200..<300).contains(response.statusCode) else {
                if response.statusCode != 404 {
                    AppLog.warn(LogTag.plugin("antigravity"), "quota summary HTTP \(response.statusCode) on \(base)")
                }
                continue
            }
            guard AntigravityUsageMapper.isQuotaSummary(response.body) else {
                AppLog.warn(LogTag.plugin("antigravity"), "quota summary response has no decodable groups on \(base)")
                continue
            }
            bodies.append(response.body)
            if AntigravityUsageMapper.isCompleteSummary(response.body) { break }
        }
        if !bodies.isEmpty { return .ok(bodies) }
        return sawAuthFailure ? .authFailed : .unavailable
    }

    private static func cloudCodeRequest(url: URL, token: String, userAgent: String, payload: Data) -> HTTPRequest {
        HTTPRequest(
            method: "POST",
            url: url,
            headers: [
                "Accept": "application/json",
                "Content-Type": "application/json",
                "Authorization": "Bearer \(token)",
                "User-Agent": userAgent
            ],
            body: payload,
            timeout: 15
        )
    }

    /// Google refresh token을 새 access token으로 교환. 죽은 refresh token(4xx, `invalid_grant` 등)과 일시 실패(5xx/네트워크/decode 불가)를 구분 — 호출자가 "sign-in expired"와 "temporarily unavailable"을 정확히 보고.
    func refreshGoogleToken(_ refreshToken: String) async -> TokenRefreshOutcome {
        guard let url = URL(string: Self.googleOAuthURL) else { return .unavailable }
        let form = [
            "client_id=\(Self.googleClientID.urlFormEncoded)",
            "client_secret=\(Self.googleClientSecret.urlFormEncoded)",
            "refresh_token=\(refreshToken.urlFormEncoded)",
            "grant_type=refresh_token"
        ].joined(separator: "&")
        let request = HTTPRequest(
            method: "POST",
            url: url,
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: Data(form.utf8),
            timeout: 15
        )
        guard let response = try? await http.send(request) else { return .unavailable }
        switch response.statusCode {
        case 200..<300:
            guard let decoded = try? JSONDecoder().decode(GoogleTokenResponse.self, from: response.body),
                  let access = decoded.accessToken?.nilIfEmpty
            else {
                return .unavailable // 2xx지만 decode 불가/빈 값 — 일시 장애로 취급
            }
            return .refreshed(accessToken: access, expiresIn: decoded.expiresIn ?? 3600)
        case 408, 429:
            return .unavailable // timeout/rate limit — revoked token이 아닌 일시 장애
        case 400..<500:
            return .authFailed // invalid_grant/invalid_client — refresh token revoked 또는 만료
        default:
            return .unavailable // 5xx 및 나머지 — 일시 장애
        }
    }
}

struct GoogleTokenResponse: Decodable {
    let accessToken: String?
    let expiresIn: Double?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
    }
}
