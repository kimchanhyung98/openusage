import Foundation

@MainActor
final class OpenRouterProvider: ProviderRuntime {
    let provider = Provider(
        id: "openrouter",
        displayName: "OpenRouter",
        icon: .providerMark("openrouter"),
        links: [
            ProviderLink(label: "Activity", url: "https://openrouter.ai/activity"),
            ProviderLink(label: "Credits", url: "https://openrouter.ai/settings/credits")
        ]
    )

    let authStore: OpenRouterAuthStore
    let usageClient: OpenRouterUsageClient
    let now: @Sendable () -> Date

    init(
        authStore: OpenRouterAuthStore = OpenRouterAuthStore(),
        usageClient: OpenRouterUsageClient = OpenRouterUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .boundedDollars(id: "openrouter.credits", provider: provider, title: "Credits",
                            metricLabel: "Credits", limit: 100, limitNoun: "purchased")
                .exportingLimit("credits", unit: "usd"),
            .dollarBalance(id: "openrouter.balance", provider: provider, title: "Balance",
                           metricLabel: "Balance", valueWord: "left")
                .exportingLimit("balance", kind: .balance, unit: "usd", source: .value(kind: .dollars)),
            .values(id: "openrouter.today", provider: provider, title: "Today",
                    metricLabel: "Today", selection: .kind(.dollars), isUsagePeriod: true),
            .values(id: "openrouter.week", provider: provider, title: "This Week",
                    metricLabel: "This Week", selection: .kind(.dollars), isUsagePeriod: true),
            .values(id: "openrouter.month", provider: provider, title: "This Month",
                    metricLabel: "This Month", selection: .kind(.dollars), isUsagePeriod: true),
            .boundedDollars(id: "openrouter.keyLimit", provider: provider, title: "Key Limit",
                            metricLabel: "Key Limit", limit: 100, valueWord: "spent")
                .exportingLimit("keyLimit", unit: "usd")
        ]
    }

    func hasLocalCredentials() async -> Bool {
        // `refresh()`와 동일 소스 — 저장되었거나 환경 변수로 export된 API key
        await loadOffMainActor { [authStore] in authStore.loadAPIKey() } != nil
    }

    func refresh() async -> ProviderSnapshot {
        guard let auth = await loadOffMainActor({ [authStore] in authStore.loadAPIKey() }) else {
            return ProviderSnapshot.error(provider: provider, error: OpenRouterAuthError.missingKey)
        }

        // 두 endpoint를 독립 fetch해 성공한 쪽만 매핑 — `/credits`는 balance, `/key`는 tier + period spend
        // OpenRouter가 key 타입별로 endpoint를 gate하므로 한쪽의 403이 다른 쪽 데이터를 지우면 안 됨
        let credits = await load { try await usageClient.fetchCredits(apiKey: auth.apiKey) }
        let key = await load { try await usageClient.fetchKey(apiKey: auth.apiKey) }

        var lines: [MetricLine] = []
        var plan: String?
        if case .success(let data) = credits {
            lines += OpenRouterUsageMapper.creditsLines(from: data)
        }
        if case .success(let data) = key {
            let mapped = OpenRouterUsageMapper.keyMetrics(from: data)
            plan = mapped.plan
            lines += mapped.lines
        }

        if !lines.isEmpty {
            return ProviderSnapshot.make(provider: provider, plan: plan, lines: lines, refreshedAt: now())
        }

        // 사용 가능한 응답 전무 — 두 endpoint 모두 401/403일 때만 invalid key 판정
        // 한쪽만 403이면 key 타입별 gate일 뿐 유효한 key — invalid 처리 금지
        if credits.isAuthFailure && key.isAuthFailure {
            return ProviderSnapshot.error(provider: provider, error: OpenRouterAuthError.invalidKey)
        }
        let error = credits.failureError ?? key.failureError ?? OpenRouterUsageError.invalidResponse
        return ProviderSnapshot.error(provider: provider, error: error)
    }

    /// endpoint 호출 1회 실행 후 결과 분류 — 2xx는 parse된 data object, 401/403은 auth failure, 그 외는 typed failure.
    private func load(_ call: () async throws -> HTTPResponse) async -> EndpointResult {
        do {
            let response = try await call()
            if response.statusCode == 401 || response.statusCode == 403 { return .authFailure }
            guard (200..<300).contains(response.statusCode) else {
                return .failed(.requestFailed(response.statusCode))
            }
            guard let data = OpenRouterUsageMapper.dataObject(response.body) else {
                return .failed(.invalidResponse)
            }
            return .success(data)
        } catch {
            return .failed(.connectionFailed)
        }
    }
}

extension OpenRouterProvider: APIKeyManaging {
    var apiKeyStatus: APIKeyStatus { authStore.keyStatus() }
    func currentAPIKey() -> String? { authStore.currentAPIKey() }
    func saveAPIKey(_ key: String) throws { try authStore.saveAPIKey(key) }
    func deleteAPIKey() throws { try authStore.deleteAPIKey() }
}

private enum EndpointResult {
    case success([String: Any])
    case authFailure
    case failed(OpenRouterUsageError)

    var isAuthFailure: Bool {
        if case .authFailure = self { return true }
        return false
    }

    var failureError: OpenRouterUsageError? {
        if case .failed(let error) = self { return error }
        return nil
    }
}
