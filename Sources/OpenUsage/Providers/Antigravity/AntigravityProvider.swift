import Foundation

/// Antigravity(Google의 Codeium/Windsurf 계열 AI IDE)의 pool quota 추적. quota는 fraction 기반, 최대 4개 percent meter — 공유 Gemini pool과 공유 비Gemini pool(Claude, GPT-OSS), 각각 rolling 5시간 + weekly window.
/// probe 순서(좋은 source 우선): 1) Antigravity language server(실행 중 앱) — authoritative plan 제공, 2) `agy` language server(실행 중 CLI), 3) Keychain token → Google Cloud Code(앱 종료 시에도 동작, Google OAuth로 refresh).
/// 각 source에서 `RetrieveUserQuotaSummary` 우선(병합 pool·weekly window를 보고하는 유일한 endpoint) — 미지원 빌드는 legacy per-model endpoint로 fallback, 5h 전용이라 weekly meter는 "No data".
@MainActor
final class AntigravityProvider: ProviderRuntime {
    let provider = Provider(id: "antigravity", displayName: "Antigravity", icon: .providerMark("antigravity"))

    let authStore: AntigravityAuthStore
    let usageClient: AntigravityUsageClient
    let discovery: LanguageServerDiscovery
    let now: @Sendable () -> Date

    init(
        authStore: AntigravityAuthStore = AntigravityAuthStore(),
        usageClient: AntigravityUsageClient = AntigravityUsageClient(),
        discovery: LanguageServerDiscovery = LanguageServerDiscovery(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.discovery = discovery
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: AntigravityMetric.geminiID, provider: provider, title: AntigravityMetric.sessionLabel, isSessionWindow: true)
                .supportingSoftLimit(.fiveHours)
                .exportingLimit("geminiSession", unit: "percent"),
            .percent(id: AntigravityMetric.geminiWeeklyID, provider: provider, title: AntigravityMetric.weeklyLabel)
                .supportingSoftLimit(.weekly)
                .exportingLimit("geminiWeekly", unit: "percent"),
            .percent(id: AntigravityMetric.claudeID, provider: provider, title: AntigravityMetric.claudeLabel, isSessionWindow: true)
                .supportingSoftLimit(.fiveHours)
                .exportingLimit("nonGeminiSession", unit: "percent"),
            .percent(id: AntigravityMetric.claudeWeeklyID, provider: provider, title: AntigravityMetric.claudeWeeklyLabel)
                .supportingSoftLimit(.weekly)
                .exportingLimit("nonGeminiWeekly", unit: "percent")
        ]
    }

    func hasLocalCredentials() async -> Bool {
        // Keychain 로그인이 source of truth — 앱 소유 access-token cache는 파생물이라 로그아웃 후 단독으로 provider를 켜면 안 됨.
        do {
            let keychainToken = try await loadOffMainActor { [authStore] in
                try authStore.loadKeychainToken()
            }
            guard keychainToken != nil else {
                await loadOffMainActor { [authStore] in authStore.discardCachedToken() }
                return false
            }
            return true
        } catch {
            // detection은 1회 실행 — 판정 불가한 store는 켠 채 두어 refresh가 복구 안내를 표시하게 함.
            return true
        }
    }

    func refresh() async -> ProviderSnapshot {
        do {
            let result = try await probe()
            return ProviderSnapshot.make(provider: provider, plan: result.plan, lines: result.lines, refreshedAt: now())
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }

    private struct StrategyResult {
        var plan: String?
        var lines: [MetricLine]
    }

    private func probe() async throws -> StrategyResult {
        if let result = await probeLS(
            processName: "language_server",
            markers: ["antigravity", "antigravity-ide"],
            csrfFlag: "--csrf_token",
            portFlag: "--extension_server_port"
        ) {
            return result
        }
        if let result = await probeLS(processName: "agy", markers: [], csrfFlag: "", portFlag: nil) {
            return result
        }
        return try await probeCloudCode()
    }

    // MARK: - Language server

    private func probeLS(processName: String, markers: [String], csrfFlag: String, portFlag: String?) async -> StrategyResult? {
        let discovery = self.discovery
        let options = LanguageServerDiscovery.Options(
            processName: processName,
            markers: markers,
            csrfFlag: csrfFlag,
            portFlag: portFlag
        )
        guard let discovered = await loadOffMainActor({ discovery.discover(options) }) else { return nil }

        // HTTPS 우선(LS는 self-signed cert), 다음 HTTP, 마지막 HTTP 전용 extension port.
        var endpoints: [(scheme: String, port: Int)] = []
        for port in discovered.ports {
            endpoints.append(("https", port))
            endpoints.append(("http", port))
        }
        if let extensionPort = discovered.extensionPort {
            endpoints.append(("http", extensionPort))
        }

        for endpoint in endpoints {
            // quota summary가 authoritative(병합 pool + weekly window)라 최우선. 파싱된 summary는 usable bucket이 0이어도 probe 종료 — 아래 legacy endpoint는 quota 정보 부재를 "fully used"로 지어내므로 authoritative 답이 거기로 흘러가면 안 됨. 빈 lines는 "No data" 행으로 렌더.
            if let summary = await usageClient.callLS(scheme: endpoint.scheme, port: endpoint.port, csrf: discovered.csrf, method: "RetrieveUserQuotaSummary") {
                if (200..<300).contains(summary.statusCode) {
                    if let lines = AntigravityUsageMapper.parseQuotaSummary(summary.body) {
                        // plan은 독립적인 GetUserStatus 호출 — summary는 이에 gate되지 않고, plan 조회 실패는 빈 plan으로만 남음.
                        var plan: String?
                        if let status = await usageClient.callLS(scheme: endpoint.scheme, port: endpoint.port, csrf: discovered.csrf, method: "GetUserStatus"),
                           (200..<300).contains(status.statusCode) {
                            plan = AntigravityUsageMapper.parseUserStatus(status.body)?.plan
                        }
                        return StrategyResult(plan: plan, lines: lines)
                    }
                    // 2xx지만 summary payload 아님 — parser가 경고, legacy 흐름으로 진행.
                } else if summary.statusCode != 404 {
                    // 404 = RPC 없는 빌드(기대된 상황, legacy가 진실, 재시도 없음). 그 외는 5h 전용 데이터로 강등 전에 알릴 만큼 이례적.
                    AppLog.warn(LogTag.plugin("antigravity"), "RetrieveUserQuotaSummary HTTP \(summary.statusCode); falling back to legacy quota endpoints")
                }
            }

            guard let response = await usageClient.callLS(scheme: endpoint.scheme, port: endpoint.port, csrf: discovered.csrf, method: "GetUserStatus"),
                  (200..<300).contains(response.statusCode)
            else {
                continue
            }

            if let parsed = AntigravityUsageMapper.parseUserStatus(response.body) {
                let lines = AntigravityUsageMapper.buildLines(parsed.configs)
                if !lines.isEmpty { return StrategyResult(plan: parsed.plan, lines: lines) }
            }

            // endpoint는 응답했지만 GetUserStatus에 쓸 게 없음 — 문서화된 fallback 시도.
            if let fallback = await usageClient.callLS(scheme: endpoint.scheme, port: endpoint.port, csrf: discovered.csrf, method: "GetCommandModelConfigs"),
               (200..<300).contains(fallback.statusCode),
               let configs = AntigravityUsageMapper.parseCommandModelConfigs(fallback.body) {
                let lines = AntigravityUsageMapper.buildLines(configs)
                if !lines.isEmpty { return StrategyResult(plan: nil, lines: lines) }
            }
        }
        return nil
    }

    // MARK: - Cloud Code

    private func probeCloudCode() async throws -> StrategyResult {
        let authStore = self.authStore
        let keychainToken = try await loadOffMainActor { try authStore.loadKeychainToken() }

        guard let keychainToken else {
            // 확인된 로그아웃은 파생 cache 무효화. Keychain 읽기 실패는 위에서 throw되고 복구를 위해 cache를 의도적으로 보존.
            await loadOffMainActor { authStore.discardCachedToken() }
            throw AntigravityError.notSignedIn
        }

        var tokens: [String] = []
        if let access = keychainToken.accessToken, authStore.isUsable(expiry: keychainToken.expiry) {
            tokens.append(access)
        }
        if let cached = await loadOffMainActor({ authStore.loadCachedToken(matching: keychainToken) }),
           !tokens.contains(cached) {
            tokens.append(cached)
        }

        // 시도한 token이 있거나 refresh token이 있으면 인증 수단 보유 — 일시 장애("temporarily unavailable")와 진짜 "not signed in" 구분에 사용.
        let hasCredentials = !tokens.isEmpty || (keychainToken.refreshToken?.isEmpty == false)

        var sawAuthFailure = false
        for token in tokens {
            switch await fetchCloudCode(token: token) {
            case .success(let result): return result
            case .authFailed: sawAuthFailure = true
            case .unavailable: break
            }
        }

        // auth 실패 증거(또는 시도할 token 없음)일 때만 refresh — 일시적 Cloud Code 장애가 매 cycle Google OAuth refresh를 유발하면 안 됨.
        if sawAuthFailure || tokens.isEmpty, let refreshToken = keychainToken.refreshToken {
            switch await usageClient.refreshGoogleToken(refreshToken) {
            case .refreshed(let accessToken, let expiresIn):
                await loadOffMainActor {
                    authStore.cacheToken(
                        accessToken,
                        expiresIn: expiresIn,
                        sourceRefreshToken: refreshToken
                    )
                }
                switch await fetchCloudCode(token: accessToken) {
                case .success(let result): return result
                case .authFailed: throw AntigravityError.authExpired
                // 갱신된 token은 유효 — 여기서의 non-2xx는 auth 불량이 아닌 일시 장애.
                case .unavailable: throw AntigravityError.unavailable
                }
            // refresh token 자체가 죽음(revoked/expired) — 장애가 아닌 만료된 auth.
            case .authFailed: throw AntigravityError.authExpired
            // refresh가 일시적으로만 불가(throttle/5xx/네트워크). refresh token은 유효할 수 있어 일시 장애로 보고 — access token 만료로 인한 401은 정상이며 sign-in 사망의 증거가 아님.
            case .unavailable: throw AntigravityError.unavailable
            }
        }

        // refresh 미시도(refresh token 없음)일 때만 도달 — 거부된 token에 refresh 수단이 없으면 진짜 만료된 auth.
        if sawAuthFailure { throw AntigravityError.authExpired }
        // 로그인 상태지만 모든 endpoint 접근 불가 — "not signed in"이 아닌 일시 실패로 보고.
        if hasCredentials { throw AntigravityError.unavailable }
        throw AntigravityError.notSignedIn
    }

    private enum CloudCodeProbe {
        case success(StrategyResult)
        case authFailed
        case unavailable
    }

    private func fetchCloudCode(token: String) async -> CloudCodeProbe {
        // authoritative 우선: quota summary(병합 pool + weekly window). 파싱된 summary는 usable bucket이 0이어도 답 — 아래 legacy chain은 quota 부재를 "fully used"로 지어내므로 절대 흘러가면 안 됨. 404(RPC 없는 빌드)는 `.unavailable`로 fallthrough.
        switch await usageClient.cloudCode(path: AntigravityUsageClient.quotaSummaryPath, token: token, userAgent: "antigravity", body: [:]) {
        case .authFailed:
            return .authFailed
        case .ok(let data):
            if let lines = AntigravityUsageMapper.parseQuotaSummary(data) {
                return .success(StrategyResult(plan: await loadPlan(token: token), lines: lines))
            }
            // 2xx지만 summary payload 아님 — parser가 경고, legacy chain으로 진행.
        case .unavailable:
            break
        }

        // legacy: fetchAvailableModels — Antigravity 전체 모델 집합 (Gemini + Claude + GPT-OSS).
        switch await usageClient.cloudCode(path: AntigravityUsageClient.fetchModelsPath, token: token, userAgent: "antigravity", body: [:]) {
        case .authFailed:
            return .authFailed
        case .ok(let data):
            let lines = AntigravityUsageMapper.buildLines(AntigravityUsageMapper.parseCloudCodeModels(data))
            if !lines.isEmpty {
                return .success(StrategyResult(plan: await loadPlan(token: token), lines: lines))
            }
        case .unavailable:
            break
        }

        // fallback: loadCodeAssist(plan + project) → retrieveUserQuota(Gemini 전용 bucket).
        var plan: String?
        var project: String?
        switch await usageClient.cloudCode(path: AntigravityUsageClient.loadCodeAssistPath, token: token, userAgent: "agy", body: [:]) {
        case .authFailed: return .authFailed
        case .ok(let data):
            plan = AntigravityUsageMapper.parseLoadCodeAssistPlan(data)
            project = AntigravityUsageMapper.parseProject(data)
        case .unavailable: break
        }

        var quota = await usageClient.cloudCode(
            path: AntigravityUsageClient.retrieveQuotaPath,
            token: token,
            userAgent: "agy",
            body: project.map { ["project": $0] } ?? [:]
        )
        if case .unavailable = quota, project != nil {
            quota = await usageClient.cloudCode(path: AntigravityUsageClient.retrieveQuotaPath, token: token, userAgent: "agy", body: [:])
        }
        switch quota {
        case .authFailed: return .authFailed
        case .ok(let data):
            let lines = AntigravityUsageMapper.buildLines(AntigravityUsageMapper.parseQuotaBuckets(data))
            if !lines.isEmpty { return .success(StrategyResult(plan: plan, lines: lines)) }
        case .unavailable: break
        }
        return .unavailable
    }

    private func loadPlan(token: String) async -> String? {
        if case .ok(let data) = await usageClient.cloudCode(path: AntigravityUsageClient.loadCodeAssistPath, token: token, userAgent: "agy", body: [:]) {
            return AntigravityUsageMapper.parseLoadCodeAssistPlan(data)
        }
        return nil
    }
}
