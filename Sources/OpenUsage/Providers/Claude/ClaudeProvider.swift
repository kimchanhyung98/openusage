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
                .init(label: "Status", url: "https://status.claude.com/"),
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

    let usageStateStore: ClaudeUsageStateStore

    init(
        provider: Provider = ClaudeProvider.makeProvider(),
        authStore: ClaudeAuthStore = ClaudeAuthStore(),
        usageClient: ClaudeUsageClient = ClaudeUsageClient(),
        usageStateStore: ClaudeUsageStateStore = ClaudeUsageStateStore(),
        logUsageScanner: ClaudeLogUsageScanner = ClaudeLogUsageScanner(),
        includePiUsage: Bool = true,
        now: @escaping @Sendable () -> Date = Date.init,
        pricing: @escaping @Sendable () async -> ModelPricing = { await ModelPricingStore.shared.current() }
    ) {
        self.provider = provider
        self.authStore = authStore
        self.usageClient = usageClient
        self.usageStateStore = usageStateStore
        self.logUsageScanner = logUsageScanner
        self.includePiUsage = includePiUsage
        self.now = now
        self.pricing = pricing
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "\(provider.id).session", provider: provider, title: "Session", sessionStartSignal: .missingResetDate)
                .supportingSoftLimit(.fiveHours)
                .exportingLimit("session", unit: "percent"),
            .percent(id: "\(provider.id).weekly", provider: provider, title: "Weekly")
                .supportingSoftLimit(.weekly)
                .exportingLimit("weekly", unit: "percent"),
            .percent(id: "\(provider.id).fable", provider: provider, title: "Fable")
                .supportingSoftLimit(.weekly)
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
                .supportingSoftLimit(.weekly)
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

    var refreshIsDegraded = false

    func refresh() async -> ProviderSnapshot {
        refreshIsDegraded = false
        return await refresh(
            credentialReloadsRemaining: 1,
            forceDesktopFallback: false,
            previousFallbackError: nil,
            requestedAt: now()
        )
    }

    /// 요청 진행 중 로그인 교체 대응 — 1회 재로드로 구계정의 dashboard/cache 접근 차단, 재시도 횟수 제한.
    private func refresh(
        credentialReloadsRemaining: Int,
        forceDesktopFallback: Bool,
        previousFallbackError: ClaudeAuthError?,
        requestedAt: Date
    ) async -> ProviderSnapshot {
        let allowDesktopInteraction = ProviderRefreshContext.isManual
        let credentialLoad = await loadOffMainActor { [authStore] in
            authStore.loadCredentialSet(
                allowDesktopInteraction: allowDesktopInteraction,
                forceDesktopFallback: forceDesktopFallback,
                allowAccountInteraction: allowDesktopInteraction
            )
        }
        let storedCandidates = credentialLoad.candidates
        if let error = credentialLoad.credentialError {
            return ProviderSnapshot.error(provider: provider, error: error)
        }
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
        let desktopFallbackWarning: ClaudeAuthError? = if !hasLiveUsageCandidate {
            switch credentialLoad.desktopStatus {
            case .permissionRequired:
                .desktopPermissionRequired
            case .stale:
                .desktopTokenExpired
            case .invalid:
                .desktopCredentialsUnavailable
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
                    previousFallbackError: lastFallbackError,
                    requestedAt: requestedAt
                )
            }
            do {
                let snapshot = try await probe(
                    state: state,
                    credentialGeneration: &credentialGeneration,
                    fallbackWarning: desktopFallbackWarning,
                    requestedAt: requestedAt
                )
                AppLog.info(LogTag.plugin("claude"), "refresh end (\(Int(Date().timeIntervalSince(start) * 1000))ms)")
                return snapshot
            } catch ClaudeAuthError.credentialsChanged where credentialReloadsRemaining > 0 {
                AppLog.info(LogTag.auth("claude"), "credential source changed during refresh; reloading current login")
                // 로그인 교체로 폐기한 시도의 저장 실패를 새 결과에 전파하지 않음.
                refreshIsDegraded = false
                return await refresh(
                    credentialReloadsRemaining: credentialReloadsRemaining - 1,
                    forceDesktopFallback: forceDesktopFallback,
                    previousFallbackError: previousFallbackError,
                    requestedAt: requestedAt
                )
            } catch let error as ClaudeAuthError where error.allowsAuthFallback {
                AppLog.info(LogTag.auth("claude"), "\(state.source.label) authentication failed; falling back to next source if any")
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
                previousFallbackError: lastFallbackError,
                requestedAt: requestedAt
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
        fallbackWarning: ClaudeAuthError?,
        requestedAt: Date
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
        var authenticationIssue: ProviderAuthenticationIssue?
        switch authStore.liveUsageAvailability(state) {
        case .available:
            mapped = try await fetchLiveUsage(
                state: &state,
                credentialGeneration: &credentialGeneration,
                requestedAt: requestedAt
            )
            // rate-limited notice는 mapped usage에 실어 header 삼각형까지 전달 — badge/note 라인이 레이아웃에 없어도 표시.
            warning = mapped.warning
        case .missingProfileScope:
            // `user:profile` scope 없는 로그인(`claude setup-token` 계열) — session/weekly 바를 조용히
            // 비우는 대신 로그 + header 경고로 재로그인 안내; 로컬 로그 spend 타일은 영향 없음.
            AppLog.warn(LogTag.plugin("claude"), "live usage unavailable: credential lacks the user:profile scope (inference-only token); re-login with `claude` to restore session/weekly limits")
            warning = ClaudeUsageMapper.missingProfileScopeWarning
            authenticationIssue = .signInNeeded
        case .inferenceOnlyToken:
            // 명시적 CLAUDE_CODE_OAUTH_TOKEN은 설계상 inference 전용 — 조회·안내 대상 아님, spend 타일은 유지.
            break
        }
        if let fallbackWarning, authenticationIssue == nil || fallbackWarning == .desktopPermissionRequired {
            warning = fallbackWarning.localizedDescription
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
            warning = [warning, scan.numericWarning].compactMap { $0 }.joined(separator: " ").nilIfEmpty
            usageHistory = scan.usageHistory
            if usageHistory != nil {
                SpendTileMapper.appendTokenUsage(
                    scan.series, to: &mapped.lines, now: now(),
                    unknownModelsByDay: scan.unknownModelsByDay,
                    modelUsage: scan.modelUsage,
                    modelSourceNote: note
                )
                SpendTileMapper.appendUsageTrend(scan.series, to: &mapped.lines, now: now(), note: note)
            }
        }

        MetricLine.appendNoDataIfNeeded(&mapped.lines)
        return ProviderSnapshot.make(
            provider: provider,
            plan: mapped.plan,
            lines: mapped.lines,
            refreshedAt: now(),
            usageHistory: usageHistory,
            warning: warning,
            authenticationIssue: authenticationIssue,
            isDegraded: refreshIsDegraded ? true : nil,
            liveQuotaObservedAt: mapped.liveQuotaObservedAt,
            quotaObservedAt: mapped.quotaObservedAt,
            usageRetryAfter: mapped.retryAfter
        )
    }

}
