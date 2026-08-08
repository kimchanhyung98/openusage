import Foundation

@MainActor
final class CodexProvider: ProviderRuntime {
    /// 기본 카드의 identity. 추가 계정 카드는 `@` suffix id와 계정 기반 display name만 주입, runtime은 동일. (`ClaudeProvider.makeProvider` mirror.)
    static func makeProvider(id: String = "codex", displayName: String = "Codex") -> Provider {
        Provider(
            id: id,
            displayName: displayName,
            icon: .providerMark("codex"),
            links: [
                .init(label: "Status", url: "https://status.openai.com/"),
                .init(label: "Dashboard", url: "https://chatgpt.com/codex/settings/usage")
            ]
        )
    }

    let provider: Provider
    let authStore: CodexAuthStore
    let usageClient: CodexUsageClient
    let logUsageScanner: CodexLogUsageScanner
    let includePiUsage: Bool
    let now: @Sendable () -> Date
    let pricing: @Sendable () async -> ModelPricing

    init(
        provider: Provider = CodexProvider.makeProvider(),
        authStore: CodexAuthStore = CodexAuthStore(),
        usageClient: CodexUsageClient = CodexUsageClient(),
        logUsageScanner: CodexLogUsageScanner = CodexLogUsageScanner(),
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
            .percent(id: "\(provider.id).session", provider: provider, title: "Session")
                .exportingLimit("session", unit: "percent"),
            .percent(id: "\(provider.id).weekly", provider: provider, title: "Weekly")
                .exportingLimit("weekly", unit: "percent"),
            .usageTrend(provider: provider)
                .exportingHistory(
                    scope: .machineLocal,
                    estimatedCost: true,
                    sourceNote: "From your Codex logs (estimated)"
                ),
            .values(id: "\(provider.id).rateLimitResets", provider: provider, title: "Rate Limit Resets", metricLabel: "Rate Limit Resets", traySuffix: "resets", showsResetExpiries: true)
                .exportingLimit("rateLimitResets", kind: .balance, unit: "resets", source: .value(kind: .count, label: "available")),
            // `additional_rate_limits`의 Spark 전용 limit (GPT-5.3-Codex-Spark) — `DefaultLayout`에서 On Demand·비활성·unpinned로 seed.
            .percent(id: "\(provider.id).spark", provider: provider, title: "Spark")
                .exportingLimit("spark", unit: "percent"),
            .percent(id: "\(provider.id).sparkWeekly", provider: provider, title: "Spark Weekly")
                .exportingLimit("sparkWeekly", unit: "percent"),
            .combined(id: "\(provider.id).credits", provider: provider, title: "Extra Usage", metricLabel: "Credits")
                .exportingLimit("credits", kind: .balance, unit: "credits", source: .value(kind: .count, label: "credits"))
                .exportingLimit("creditValue", kind: .balance, unit: "usd", source: .value(kind: .dollars))
        ] + WidgetDescriptor.spendTiles(provider: provider)
    }

    func hasLocalCredentials() async -> Bool {
        // `refresh()`와 동일한 source 순서(auth.json 후보 → keychain), usable access token만 인정 — API-key-only auth.json은 usage API 사용 불가.
        let fileCandidates = authStore.loadAuthCandidates()
        if fileCandidates.contains(where: \.hasUsableAccessToken) {
            return true
        }
        let keychain = await loadOffMainActor { [authStore] in authStore.loadKeychainAuth() }
        return keychain?.hasUsableAccessToken == true
    }

    func refresh() async -> ProviderSnapshot {
        let fileCandidates = authStore.loadAuthCandidates()
        var lastFallbackError: Error?

        for candidate in fileCandidates {
            do {
                return try await probe(authState: candidate)
            } catch let error as CodexAuthError where error.allowsAuthFallback {
                lastFallbackError = error
                continue
            } catch {
                return ProviderSnapshot.error(provider: provider, error: error)
            }
        }

        if let keychainCandidate = await loadOffMainActor({ [authStore] in authStore.loadKeychainAuth() }) {
            do {
                return try await probe(authState: keychainCandidate)
            } catch {
                return ProviderSnapshot.error(provider: provider, error: error)
            }
        }

        if let lastFallbackError {
            return ProviderSnapshot.error(provider: provider, error: lastFallbackError)
        }
        return ProviderSnapshot.error(provider: provider, error: CodexAuthError.notLoggedIn)
    }

    private func probe(authState initialState: CodexAuthState) async throws -> ProviderSnapshot {
        var authState = initialState
        guard var accessToken = authState.auth.tokens?.accessToken, !accessToken.isEmpty else {
            if authState.auth.apiKey?.isEmpty == false {
                throw CodexAuthError.usageAPIKey
            }
            throw CodexAuthError.notLoggedIn
        }

        if authStore.needsRefresh(authState.auth) {
            // `codex` CLI가 디스크의 token을 이미 회전시켰을 수 있음 — live credential을 먼저 재판독해 최신 access token 채택 (stale 사본 refresh 시 `refresh_token_reused`, issue #516).
            if let live = reloadLiveAuth(source: authState.source),
               let liveToken = live.auth.tokens?.accessToken, !liveToken.isEmpty {
                authState = live
                accessToken = liveToken
            }
        }

        if authStore.needsRefresh(authState.auth),
           let refreshToken = authState.auth.tokens?.refreshToken,
           !refreshToken.isEmpty {
            let refreshed = try await refreshAccessToken(authState: &authState, refreshToken: refreshToken)
            accessToken = refreshed
        }

        let response = try await fetchUsageWithRetry(accessToken: accessToken, authState: &authState)
        // usage fetch의 refresh-and-retry 중 access token 회전 가능 — live token 재판독.
        let currentToken = authState.auth.tokens?.accessToken ?? accessToken
        let resetCredits = await fetchResetCreditsBestEffort(
            accessToken: currentToken,
            accountID: authState.auth.tokens?.accountID
        )
        var mapped = try CodexUsageMapper.mapUsageResponse(response, resetCredits: resetCredits, now: now())

        // Local spend tile — Codex CLI session rollout native 스캔 + pi 안에서 발생한 Codex usage 병합, 두 스캔 모두 scanner actor에서 main actor 밖 실행.
        let pricing = await pricing()
        let nativeScan = await logUsageScanner.scan(now: now(), pricing: pricing)
        let piScan = includePiUsage
            ? await PiUsageScanner.shared.scan(cardID: provider.id, now: now(), pricing: pricing)
            : nil
        var usageHistory: ProviderUsageHistory?
        // native·pi 스캔 사이 cancellation 가능 — 부분 결과가 WidgetDataStore의 last-good combined history를 대체하지 않도록 쌍을 한 단위로 처리.
        if !Task.isCancelled, let scan = DailyUsageAccumulator.merged([nativeScan, piScan]) {
            let note = piScan == nil
                ? "From your Codex logs (estimated)"
                : "From your Codex logs and pi (estimated)"
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
            usageHistory: usageHistory
        )
    }

    /// On-demand reset-credit 잔액(및 per-credit expiry) 조회 — best-effort, refresh 전체를 실패시키지 않음.
    /// 실패는 log 후 `nil`, mapper가 usage body에 내장된 count로 fallback — endpoint가 죽어도 Session/Weekly/Credits 유지.
    private func fetchResetCreditsBestEffort(accessToken: String, accountID: String?) async -> HTTPResponse? {
        do {
            return try await usageClient.fetchResetCredits(accessToken: accessToken, accountID: accountID)
        } catch {
            AppLog.warn(LogTag.plugin("codex"), "reset-credit fetch failed; using usage-body count: \(error.localizedDescription)")
            return nil
        }
    }

    private func fetchUsageWithRetry(accessToken: String, authState: inout CodexAuthState) async throws -> HTTPResponse {
        var working = authState
        defer { authState = working }
        return try await ProviderAuthRetry.fetch(
            token: accessToken,
            attempt: { try await self.usageClient.fetchUsage(accessToken: $0, accountID: working.auth.tokens?.accountID) },
            refreshAccessToken: {
                guard let refreshToken = working.auth.tokens?.refreshToken, !refreshToken.isEmpty else {
                    throw CodexAuthError.tokenExpired
                }
                do {
                    return try await self.refreshAccessToken(authState: &working, refreshToken: refreshToken)
                } catch let error as CodexAuthError {
                    throw error
                } catch {
                    throw CodexUsageError.connectionFailed
                }
            },
            connectionFailed: CodexUsageError.connectionFailed,
            authExpired: CodexAuthError.tokenExpired
        )
    }

    /// 원래 source(같은 파일 또는 keychain entry)에서 credential 재판독 — `codex` CLI가 out-of-band로 회전시킨 token을 자체 refresh 전에 수용.
    /// 그 source 하나만 읽고 후보 경로 재스캔 없음 — `codex`가 `CODEX_HOME`의 단일 `auth.json`만 읽는 방식과 일치.
    private func reloadLiveAuth(source: CodexAuthState.Source) -> CodexAuthState? {
        switch source {
        case .file(let path):
            return authStore.loadAuth(at: path)
        case .keychain:
            return authStore.loadKeychainAuth()
        case .accountSnapshot(let profileID):
            return authStore.loadAccountSnapshot(profileID: profileID)
        }
    }

    private func refreshAccessToken(authState: inout CodexAuthState, refreshToken: String) async throws -> String {
        let response = try await usageClient.refreshToken(refreshToken)
        authState.auth.tokens?.accessToken = response.accessToken
        if let refreshToken = response.refreshToken {
            authState.auth.tokens?.refreshToken = refreshToken
        }
        if let idToken = response.idToken {
            authState.auth.tokens?.idToken = idToken
        }
        authState.auth.lastRefresh = OpenUsageISO8601.string(from: now())
        // save 실패는 loud log 후 계속 — 삼키면 회전된 token이 디스크에 남아 다음 실행에서 false "token expired" 유발, refreshed token은 이번 세션에서 유효.
        do {
            try authStore.save(authState)
        } catch {
            AppLog.error(LogTag.auth("codex"), "failed to persist rotated credentials; using the refreshed token for this session only: \(error.localizedDescription)")
        }
        return response.accessToken
    }
}
