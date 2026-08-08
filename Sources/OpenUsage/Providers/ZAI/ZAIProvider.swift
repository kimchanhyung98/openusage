import Foundation

@MainActor
final class ZAIProvider: ProviderRuntime {
    let provider = Provider(
        id: "zai",
        displayName: "Z.ai",
        icon: .providerMark("zai"),
        links: [
            ProviderLink(label: "Dashboard", url: "https://z.ai/manage-apikey/coding-plan/personal/my-plan"),
            ProviderLink(label: "API Keys", url: "https://z.ai/manage-apikey/apikey-list")
        ]
    )

    let authStore: ZAIAuthStore
    let usageClient: ZAIUsageClient
    let now: @Sendable () -> Date

    init(
        authStore: ZAIAuthStore = ZAIAuthStore(),
        usageClient: ZAIUsageClient = ZAIUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "zai.session", provider: provider, title: "Session",
                     metricLabel: "Session")
                .exportingLimit("session", unit: "percent"),
            .percent(id: "zai.weekly", provider: provider, title: "Weekly",
                     metricLabel: "Weekly")
                .exportingLimit("weekly", unit: "percent"),
            .boundedCount(id: "zai.webSearches", provider: provider, title: "Web Searches",
                          metricLabel: "Web Searches", limit: 1000, suffix: "searches",
                          periodDurationMs: ZAIUsageMapper.monthlyPeriodMs)
                .exportingLimit("webSearches", unit: "searches")
        ]
    }

    func hasLocalCredentials() async -> Bool {
        // `refresh()`와 동일 소스 — 저장되었거나 환경 변수로 export된 API key
        await loadOffMainActor { [authStore] in authStore.loadAPIKey() } != nil
    }

    func refresh() async -> ProviderSnapshot {
        guard let auth = await loadOffMainActor({ [authStore] in authStore.loadAPIKey() }) else {
            return ProviderSnapshot.error(provider: provider, error: ZAIAuthError.missingKey)
        }

        // quota endpoint는 필수, subscription endpoint는 plan 이름용 best-effort — subscription 실패가 meter를 지우면 안 됨
        let quota = await load { try await usageClient.fetchQuota(apiKey: auth.apiKey) }
        let subscription = await loadOptional { try await usageClient.fetchSubscription(apiKey: auth.apiKey) }

        switch quota {
        case .success(let body):
            // 유효 key지만 GLM Coding Plan이 없는 계정은 2xx + `success:false` 응답
            // 이유를 설명하지 못하는 빈 "No data" meter 세 개 대신 명확한 provider 경고(header amber notice)로 노출
            if ZAIUsageMapper.isNoCodingPlan(body) {
                return ProviderSnapshot.error(provider: provider, error: ZAIUsageError.noCodingPlan)
            }
            do {
                let mapped = try ZAIUsageMapper.map(quotaBody: body, subscriptionBody: subscription)
                return ProviderSnapshot.make(provider: provider, plan: mapped.plan, lines: mapped.lines, refreshedAt: now())
            } catch {
                return ProviderSnapshot.error(provider: provider, error: error)
            }
        case .authFailure:
            return ProviderSnapshot.error(provider: provider, error: ZAIAuthError.invalidKey)
        case .failed(let error):
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }

    /// 필수 quota 호출 실행 후 결과 분류 — 2xx는 body, 401/403은 auth failure, 그 외는 typed failure.
    private func load(_ call: () async throws -> HTTPResponse) async -> QuotaResult {
        do {
            let response = try await call()
            if response.statusCode == 401 || response.statusCode == 403 { return .authFailure }
            guard (200..<300).contains(response.statusCode) else {
                return .failed(.requestFailed(response.statusCode))
            }
            return .success(response.body)
        } catch {
            return .failed(.connectionFailed)
        }
    }

    /// 선택적 subscription 호출 실행 — snapshot으로 throw하지 않음, 모든 실패는 "이번 refresh에 plan 이름 없음"일 뿐.
    /// mapper가 소비하는 body만 반환, 그 외 결과는 폐기.
    private func loadOptional(_ call: () async throws -> HTTPResponse) async -> Data? {
        do {
            let response = try await call()
            guard (200..<300).contains(response.statusCode) else { return nil }
            return response.body
        } catch {
            return nil
        }
    }
}

extension ZAIProvider: APIKeyManaging {
    var apiKeyStatus: APIKeyStatus { authStore.keyStatus() }
    func currentAPIKey() -> String? { authStore.currentAPIKey() }
    func saveAPIKey(_ key: String) throws { try authStore.saveAPIKey(key) }
    func deleteAPIKey() throws { try authStore.deleteAPIKey() }
}

private enum QuotaResult {
    case success(Data)
    case authFailure
    case failed(ZAIUsageError)
}
