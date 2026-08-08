import CryptoKit
import Foundation

@MainActor
final class ClaudeProvider: ProviderRuntime {
    /// 기본 카드의 identity — 추가 계정 카드는 `@` suffix id와 계정 유래 이름만 다른 동일 runtime.
    static func makeProvider(id: String = "claude", displayName: String = "Claude") -> Provider {
        Provider(
            id: id,
            displayName: displayName,
            icon: .providerMark("claude"),
            links: [
                .init(label: "Status", url: "https://status.anthropic.com/"),
                .init(label: "Dashboard", url: "https://claude.ai/settings/usage")
            ]
        )
    }

    let provider: Provider

    let authStore: ClaudeAuthStore
    let usageClient: ClaudeUsageClient
    let logUsageScanner: ClaudeLogUsageScanner
    let includePiUsage: Bool
    let now: @Sendable () -> Date
    let pricing: @Sendable () async -> ModelPricing

    /// refresh 간 유지되는 마지막 성공 라이브 usage + rate-limit cooldown — 429 시 last-good 바를
    /// staleness note와 함께 제공하고, cooldown 만료까지 라이브 호출 skip(429 가중 방지).
    private var cachedCredentialFingerprint: Data?
    private var lastGoodUsage: ClaudeMappedUsage?
    private var rateLimitedUntil: Date?
    private static let rateLimitCooldown: TimeInterval = 5 * 60

    init(
        provider: Provider = ClaudeProvider.makeProvider(),
        authStore: ClaudeAuthStore = ClaudeAuthStore(),
        usageClient: ClaudeUsageClient = ClaudeUsageClient(),
        logUsageScanner: ClaudeLogUsageScanner = ClaudeLogUsageScanner(),
        includePiUsage: Bool = true,
        now: @escaping @Sendable () -> Date = Date.init,
        pricing: @escaping @Sendable () async -> ModelPricing = { await ModelPricingStore.shared.current() }
    ) {
        self.provider = provider
        self.authStore = authStore
        self.usageClient = usageClient
        self.logUsageScanner = logUsageScanner
        self.includePiUsage = includePiUsage
        self.now = now
        self.pricing = pricing
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "\(provider.id).session", provider: provider, title: "Session", isSessionWindow: true)
                .exportingLimit("session", unit: "percent"),
            .percent(id: "\(provider.id).weekly", provider: provider, title: "Weekly")
                .exportingLimit("weekly", unit: "percent"),
            .percent(id: "\(provider.id).fable", provider: provider, title: "Fable")
                .exportingLimit("fable", unit: "percent"),
            .usageTrend(provider: provider)
                .exportingHistory(
                    scope: .machineLocal,
                    estimatedCost: true,
                    sourceNote: "From your Claude usage history (estimated)"
                ),
            .boundedDollars(id: "\(provider.id).extra", provider: provider, title: "Extra Usage", metricLabel: "Extra usage spent", limit: 100, valueWord: "spent")
                .exportingLimit("extraUsage", unit: "usd", source: .progressOrValue(kind: .dollars)),
            .percent(id: "\(provider.id).sonnet", provider: provider, title: "Sonnet")
                .exportingLimit("sonnet", unit: "percent")
        ] + WidgetDescriptor.spendTiles(provider: provider)
    }

    func hasLocalCredentials() async -> Bool {
        // scoped 카드는 footprint만 확인(파일 존재/keychain attributes) — 매 실행 seeding probe에서
        // keychain dialog 발생 금지; secret 읽기는 첫 refresh에서 수행.
        if authStore.scope != .standard {
            return await loadOffMainActor { [authStore] in authStore.hasCredentialFootprint() }
        }
        // first-run 감지 중 타 앱 Keychain prompt 금지 — 암호화된 Desktop 자료도 로컬 로그인으로 집계,
        // 접근 요청은 첫 수동 refresh에서 수행.
        let load = await loadOffMainActor { [authStore] in authStore.loadCredentialSet() }
        if load.candidates.contains(where: \.hasUsableAccessToken) { return true }
        return load.desktopStatus == .permissionRequired || load.desktopStatus == .stale
    }

    func refresh() async -> ProviderSnapshot {
        await refresh(
            credentialReloadsRemaining: 1,
            forceDesktopFallback: false,
            previousFallbackError: nil
        )
    }

    /// 요청 진행 중 로그인 교체 대응 — 1회 재로드로 구계정의 dashboard/cache 접근 차단, 재시도 횟수 제한.
    private func refresh(
        credentialReloadsRemaining: Int,
        forceDesktopFallback: Bool,
        previousFallbackError: ClaudeAuthError?
    ) async -> ProviderSnapshot {
        let allowDesktopInteraction = ProviderRefreshContext.isManual
        let credentialLoad = await loadOffMainActor { [authStore] in
            authStore.loadCredentialSet(
                allowDesktopInteraction: allowDesktopInteraction,
                forceDesktopFallback: forceDesktopFallback
            )
        }
        let storedCandidates = credentialLoad.candidates
        let candidates = storedCandidates.filter {
            $0.hasUsableAccessToken && (!forceDesktopFallback || $0.source == .desktop)
        }
        if forceDesktopFallback {
            switch credentialLoad.desktopStatus {
            case .permissionRequired:
                return ProviderSnapshot.error(provider: provider, error: ClaudeAuthError.desktopPermissionRequired)
            case .stale, .invalid, .notFound:
                if let previousFallbackError {
                    return ProviderSnapshot.error(provider: provider, error: previousFallbackError)
                }
            case .notChecked, .available:
                break
            }
        }
        let hasLiveUsageCandidate = candidates.contains {
            authStore.liveUsageAvailability($0) == .available
        }
        let desktopFallbackWarning: String? = if !hasLiveUsageCandidate {
            switch credentialLoad.desktopStatus {
            case .permissionRequired:
                ClaudeAuthError.desktopPermissionRequired.localizedDescription
            case .stale:
                ClaudeAuthError.desktopTokenExpired.localizedDescription
            case .invalid:
                ClaudeAuthError.desktopCredentialsUnavailable.localizedDescription
            case .notChecked, .notFound, .available:
                nil
            }
        } else {
            nil
        }
        guard !candidates.isEmpty else {
            switch credentialLoad.desktopStatus {
            case .permissionRequired:
                return ProviderSnapshot.error(provider: provider, error: ClaudeAuthError.desktopPermissionRequired)
            case .stale:
                return ProviderSnapshot.error(provider: provider, error: ClaudeAuthError.desktopTokenExpired)
            case .invalid:
                return ProviderSnapshot.error(provider: provider, error: ClaudeAuthError.desktopCredentialsUnavailable)
            case .notChecked, .notFound, .available:
                break
            }
            AppLog.info(LogTag.auth("claude"), "no access token, not logged in")
            return ProviderSnapshot.error(provider: provider, error: ClaudeAuthError.notLoggedIn)
        }

        // source별 진단을 info 레벨로(토큰 없는 라벨) — 기본 로그만으로 "token expired" 진단 가능(#738).
        let sources = candidates.map { $0.diagnosticsLabel(now: now()) }.joined(separator: ", ")
        AppLog.info(LogTag.plugin("claude"), "refresh start (\(candidates.count) source\(candidates.count == 1 ? "" : "s"): \(sources))")
        let start = Date()
        // keychain-우선 순서로 credential source probe. auth-expiry 실패는 다음 source로 폴백;
        // 비-auth 에러(rate limit, transport)는 즉시 표면화 — 실제 장애를 재시도로 가리지 않음.
        var lastFallbackError: ClaudeAuthError?
        var credentialGeneration = ClaudeCredentialGeneration(storedCandidates)
        for state in candidates {
            // environment 토큰은 subscription usage 조회 불가 — spend 전용 폴백이 거짓 성공이 되기 전에 Desktop 시도.
            if !forceDesktopFallback,
               lastFallbackError != nil,
               credentialLoad.desktopStatus == .notChecked,
               authStore.liveUsageAvailability(state) == .inferenceOnlyToken
            {
                return await refresh(
                    credentialReloadsRemaining: credentialReloadsRemaining,
                    forceDesktopFallback: true,
                    previousFallbackError: lastFallbackError
                )
            }
            do {
                let snapshot = try await probe(
                    state: state,
                    credentialGeneration: &credentialGeneration,
                    fallbackWarning: desktopFallbackWarning
                )
                AppLog.info(LogTag.plugin("claude"), "refresh end (\(Int(Date().timeIntervalSince(start) * 1000))ms)")
                return snapshot
            } catch ClaudeAuthError.credentialsChanged where credentialReloadsRemaining > 0 {
                AppLog.info(LogTag.auth("claude"), "credential source changed during refresh; reloading current login")
                return await refresh(
                    credentialReloadsRemaining: credentialReloadsRemaining - 1,
                    forceDesktopFallback: forceDesktopFallback,
                    previousFallbackError: previousFallbackError
                )
            } catch let error as ClaudeAuthError where error.allowsAuthFallback {
                AppLog.warn(LogTag.auth("claude"), "\(state.source.label) failed (\(error)); falling back to next source if any")
                lastFallbackError = error
                continue
            } catch {
                return ProviderSnapshot.error(provider: provider, error: error)
            }
        }
        if !forceDesktopFallback,
           lastFallbackError != nil,
           credentialLoad.desktopStatus == .notChecked
        {
            AppLog.info(LogTag.auth("claude"), "stored Claude login failed; trying Claude Desktop")
            return await refresh(
                credentialReloadsRemaining: credentialReloadsRemaining,
                forceDesktopFallback: true,
                previousFallbackError: lastFallbackError
            )
        }
        return ProviderSnapshot.error(
            provider: provider,
            error: lastFallbackError ?? ClaudeAuthError.notLoggedIn
        )
    }

    private func probe(
        state initialState: ClaudeCredentialState,
        credentialGeneration: inout ClaudeCredentialGeneration,
        fallbackWarning: String?
    ) async throws -> ProviderSnapshot {
        var state = initialState
        var mapped = ClaudeMappedUsage(
            plan: ClaudeUsageMapper.formatPlan(
                subscriptionType: state.oauth.subscriptionType,
                rateLimitTier: state.oauth.rateLimitTier
            ),
            lines: []
        )

        var warning: String?
        switch authStore.liveUsageAvailability(state) {
        case .available:
            mapped = try await fetchLiveUsage(
                state: &state,
                credentialGeneration: &credentialGeneration
            )
            // rate-limited notice는 mapped usage에 실어 header 삼각형까지 전달 — badge/note 라인이 레이아웃에 없어도 표시.
            warning = mapped.warning
        case .missingProfileScope:
            // `user:profile` scope 없는 로그인(`claude setup-token` 계열) — session/weekly 바를 조용히
            // 비우는 대신 로그 + header 경고로 재로그인 안내; 로컬 로그 spend 타일은 영향 없음.
            AppLog.warn(LogTag.plugin("claude"), "live usage unavailable: credential lacks the user:profile scope (inference-only token); re-login with `claude` to restore session/weekly limits")
            warning = ClaudeUsageMapper.missingProfileScopeWarning
        case .inferenceOnlyToken:
            // 명시적 CLAUDE_CODE_OAUTH_TOKEN은 설계상 inference 전용 — 조회·안내 대상 아님, spend 타일은 유지.
            break
        }
        if let fallbackWarning {
            warning = fallbackWarning
        }

        // 로컬 spend 타일 — 네이티브 로그 스캔 + pi 내 Claude usage 병합, 두 스캔 모두 scanner actor에서 main actor 밖 실행.
        let pricing = await pricing()
        let nativeScan = await logUsageScanner.scan(now: now(), pricing: pricing)
        let piScan = includePiUsage
            ? await PiUsageScanner.shared.scan(cardID: provider.id, now: now(), pricing: pricing)
            : nil
        var usageHistory: ProviderUsageHistory?
        // 취소가 native/pi 스캔 사이에 올 수 있음 — 쌍을 한 단위로 취급해 부분 결과의 last-good 교체 방지.
        if !Task.isCancelled, let scan = DailyUsageAccumulator.merged([nativeScan, piScan]) {
            let note = piScan == nil
                ? "From your Claude usage history (estimated)"
                : "From your Claude usage history and pi (estimated)"
            usageHistory = ProviderUsageHistory(
                series: scan.series,
                modelUsage: scan.modelUsage,
                unknownModelsByDay: scan.unknownModelsByDay
            )
            SpendTileMapper.appendTokenUsage(
                scan.series, to: &mapped.lines, now: now(),
                unknownModelsByDay: scan.unknownModelsByDay,
                modelUsage: scan.modelUsage,
                modelSourceNote: note
            )
            SpendTileMapper.appendUsageTrend(scan.series, to: &mapped.lines, now: now(), note: note)
        }

        MetricLine.appendNoDataIfNeeded(&mapped.lines)
        return ProviderSnapshot.make(
            provider: provider,
            plan: mapped.plan,
            lines: mapped.lines,
            refreshedAt: now(),
            usageHistory: usageHistory,
            warning: warning
        )
    }

    private func fetchLiveUsage(
        state: inout ClaudeCredentialState,
        credentialGeneration: inout ClaudeCredentialGeneration
    ) async throws -> ClaudeMappedUsage {
        var expectedGeneration = credentialGeneration
        defer { credentialGeneration = expectedGeneration }
        activateLiveUsageCache(for: state.oauth)

        // rate-limit cooldown 중에는 라이브 호출 skip, last-good 제공 — dashboard 공백과 429 가중 방지.
        if let until = rateLimitedUntil, now() < until {
            AppLog.info(LogTag.plugin("claude"), "rate-limited (cooldown active, serving \(lastGoodUsage == nil ? "badge" : "last-good usage"))")
            return rateLimitedSnapshot(credentials: state.oauth, retryAfterSeconds: Int(until.timeIntervalSince(now()).rounded(.up)))
        }

        if authStore.needsRefresh(state.oauth),
           let refreshToken = state.oauth.refreshToken,
           !refreshToken.isEmpty {
            let refreshed = try await refreshAccessToken(
                state: &state,
                refreshToken: refreshToken,
                expectedGeneration: expectedGeneration
            )
            state.oauth.accessToken = refreshed.accessToken
            if refreshed.persisted { expectedGeneration = expectedGeneration.replacing(state) }
        }

        var working = state
        defer { state = working }
        let response = try await ProviderAuthRetry.fetch(
            token: working.oauth.accessToken ?? "",
            attempt: { try await self.usageClient.fetchUsage(accessToken: $0, config: self.authStore.oauthConfig()) },
            refreshAccessToken: {
                if working.source == .desktop {
                    throw ClaudeAuthError.desktopTokenExpired
                }
                guard let refreshToken = working.oauth.refreshToken, !refreshToken.isEmpty else {
                    throw ClaudeAuthError.tokenExpired
                }
                let refreshed = try await self.refreshAccessToken(
                    state: &working,
                    refreshToken: refreshToken,
                    expectedGeneration: expectedGeneration
                )
                if refreshed.persisted {
                    expectedGeneration = expectedGeneration.replacing(working)
                }
                return refreshed.accessToken
            },
            connectionFailed: ClaudeUsageError.connectionFailed,
            authExpired: ClaudeAuthError.tokenExpired
        )

        let forceDesktopGeneration = working.source == .desktop
        let currentGeneration = await loadOffMainActor { [authStore] in
            authStore.credentialGeneration(forceDesktopFallback: forceDesktopGeneration)
        }
        guard currentGeneration == expectedGeneration else { throw ClaudeAuthError.credentialsChanged }

        // 429는 양쪽 attempt에서 가능 — Retry-After 존중 cooldown 시작, bare badge 대신 last-good 제공.
        if response.statusCode == 429 {
            let retryAfterSeconds = ClaudeUsageMapper.parseRetryAfterSeconds(response, now: now())
            rateLimitedUntil = now().addingTimeInterval(TimeInterval(retryAfterSeconds ?? Int(Self.rateLimitCooldown)))
            AppLog.info(LogTag.plugin("claude"), "rate-limited (serving \(lastGoodUsage == nil ? "badge" : "last-good usage"))")
            return rateLimitedSnapshot(credentials: working.oauth, retryAfterSeconds: retryAfterSeconds)
        }

        let mapped = try ClaudeUsageMapper.mapUsageResponse(response, credentials: working.oauth, now: now())
        lastGoodUsage = mapped
        rateLimitedUntil = nil
        return mapped
    }

    /// last-good usage + staleness note, 없으면 bare rate-limited badge. `lastGoodUsage`는 항상 clean한
    /// `mapUsageResponse` 결과만 보유 — note 중복·stale spend 타일 동반 없음.
    private func rateLimitedSnapshot(credentials: ClaudeOAuth, retryAfterSeconds: Int?) -> ClaudeMappedUsage {
        guard var mapped = lastGoodUsage else {
            return ClaudeUsageMapper.rateLimitedUsage(credentials: credentials, retryAfterSeconds: retryAfterSeconds)
        }
        mapped.lines.append(ClaudeUsageMapper.rateLimitedNote(retryAfterSeconds: retryAfterSeconds))
        mapped.warning = ClaudeUsageMapper.rateLimitedWarning(retryAfterSeconds: retryAfterSeconds)
        return mapped
    }

    /// 캐시 상태는 access + refresh 쌍 단위 — 로그인 변경 시 access token이 같아도 last-good·cooldown 초기화.
    private func activateLiveUsageCache(for credentials: ClaudeOAuth) {
        let fingerprint = Self.credentialFingerprint(credentials)
        guard cachedCredentialFingerprint != fingerprint else { return }
        cachedCredentialFingerprint = fingerprint
        lastGoodUsage = nil
        rateLimitedUntil = nil
    }

    private static func credentialFingerprint(_ credentials: ClaudeOAuth) -> Data {
        let access = Data((credentials.accessToken ?? "").utf8)
        let refresh = Data((credentials.refreshToken ?? "").utf8)
        var pair = Data(SHA256.hash(data: access))
        pair.append(contentsOf: SHA256.hash(data: refresh))
        return Data(SHA256.hash(data: pair))
    }

    private struct RefreshedAccess {
        var accessToken: String
        var persisted: Bool
    }

    private func refreshAccessToken(
        state: inout ClaudeCredentialState,
        refreshToken: String,
        expectedGeneration: ClaudeCredentialGeneration
    ) async throws -> RefreshedAccess {
        AppLog.info(LogTag.auth("claude"), "token refresh attempt")
        let response = try await usageClient.refreshToken(refreshToken, config: authStore.oauthConfig())
        if response.statusCode == 400 || response.statusCode == 401 {
            let body = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
            let errorCode = body?["error"] as? String ?? body?["error_description"] as? String
            if errorCode == "invalid_grant" {
                AppLog.warn(LogTag.auth("claude"), "session expired (invalid_grant)")
                throw ClaudeAuthError.sessionExpired
            }
            // 인식 못한 OAuth 에러 코드의 400/401은 만료 확정 아님(proxy/WAF/gateway 가능) —
            // 재로그인 안내 대신 HTTP status 표면화.
            throw ClaudeUsageError.requestFailed(response.statusCode)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw ClaudeUsageError.requestFailed(response.statusCode)
        }
        // decoded.accessToken / refreshToken 로깅 금지 — rotation 발생 사실만 기록.
        let decoded = try JSONDecoder().decode(ClaudeRefreshResponse.self, from: response.body)
        let previousOAuth = state.oauth
        state.oauth.accessToken = decoded.accessToken
        if let refreshToken = decoded.refreshToken {
            state.oauth.refreshToken = refreshToken
        }
        if let expiresIn = decoded.expiresIn {
            state.oauth.expiresAt = now().timeIntervalSince1970 * 1000 + expiresIn * 1000
        }
        // loudly 실패: save 누락 시 구 refresh token이 디스크에 남아 다음 launch가 무효 토큰으로
        // "session expired" 오인; refresh된 토큰은 이번 세션에 유효하므로 로그 후 계속.
        let persisted: Bool
        do {
            guard try await Task.detached(priority: .utility, operation: { [authStore, state] in
                try authStore.save(state, ifUnchanged: expectedGeneration)
            }).value else {
                throw ClaudeAuthError.credentialsChanged
            }
            persisted = true
        } catch let error as ClaudeAuthError where error == .credentialsChanged {
            throw error
        } catch {
            AppLog.error(LogTag.auth("claude"), "failed to persist rotated credentials; using the refreshed token for this session only: \(error.localizedDescription)")
            persisted = false
        }
        if cachedCredentialFingerprint == Self.credentialFingerprint(previousOAuth) {
            cachedCredentialFingerprint = Self.credentialFingerprint(state.oauth)
        }
        AppLog.info(LogTag.auth("claude"), "token refresh ok (rotated)")
        return RefreshedAccess(accessToken: decoded.accessToken, persisted: persisted)
    }

}
