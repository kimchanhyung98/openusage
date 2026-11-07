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
        ],
        usesDedicatedSpendLines: true
    )

    let authStore: ZAIAuthStore
    let usageClient: ZAIUsageClient
    let now: @Sendable () -> Date
    let calendar: Calendar?
    let pricing: @Sendable () async -> ModelPricing

    init(
        authStore: ZAIAuthStore = ZAIAuthStore(),
        usageClient: ZAIUsageClient = ZAIUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init,
        calendar: Calendar? = nil,
        pricing: @escaping @Sendable () async -> ModelPricing = { await ModelPricingStore.shared.current() }
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
        self.calendar = calendar
        self.pricing = pricing
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "zai.session", provider: provider, title: "Session",
                     metricLabel: "Session")
                .supportingSoftLimit(.fiveHours)
                .exportingLimit("session", unit: "percent"),
            .percent(id: "zai.weekly", provider: provider, title: "Weekly",
                     metricLabel: "Weekly")
                .supportingSoftLimit(.weekly)
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
        let refreshedAt = now()
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
                let statistics = await loadStatistics(apiKey: auth.apiKey, at: refreshedAt)
                if Task.isCancelled {
                    return ProviderSnapshot.error(provider: provider, error: CancellationError())
                }
                return ProviderSnapshot.make(
                    provider: provider, plan: mapped.plan, lines: mapped.lines,
                    totalSpendLines: statistics.lines,
                    refreshedAt: refreshedAt,
                    warning: statistics.warnings.isEmpty ? nil : statistics.warnings.joined(separator: " "),
                    warningPresentation: statistics.warnings.isEmpty ? nil : statistics.warnings.map { LocalizedMessage($0) },
                    isDegraded: statistics.isDegraded ? true : nil
                )
            } catch {
                return ProviderSnapshot.error(provider: provider, error: error)
            }
        case .authFailure:
            return ProviderSnapshot.error(provider: provider, error: ZAIAuthError.invalidKey)
        case .failed(let error):
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }

    private func loadStatistics(
        apiKey: String, at date: Date
    ) async -> (lines: [MetricLine]?, warnings: [String], isDegraded: Bool) {
        let calendar = calendar ?? .current
        let window = ZAIActivityWindow(now: date, calendar: calendar)
        let prices = await pricing()
        let previousWindow = ZAIDetailWindow(days: Array(window.days.dropLast()), hourly: false)
        let todayWindow = ZAIDetailWindow(
            days: [window.days.last!], hourly: true, hourlyThrough: calendar.component(.hour, from: date)
        )
        let activity = await loadActivity(apiKey: apiKey, at: date)
        let previous = await loadDetails(apiKey: apiKey, window: previousWindow, pricing: prices)
        let today = await loadDetails(apiKey: apiKey, window: todayWindow, pricing: prices)
        let days = (previous?.days ?? [:]).merging(today?.days ?? [:]) { _, latest in latest }
        let detailUnavailable = previous == nil || today == nil
        var costUnavailable = detailUnavailable || days.values.contains { $0.costUSD == nil }
        var lines: [MetricLine] = []
        for period in TotalSpendPeriod.allCases {
            let keys: [String]
            switch period {
            case .today: keys = [window.days.last!]
            case .yesterday: keys = [window.days[window.days.count - 2]]
            case .last30: keys = window.days
            }
            if let priced = pricedLine(period: period, keys: keys, days: days) {
                lines.append(priced)
            } else {
                if let fallback = activity?.first(where: { $0.label == period.lineLabel })
                    ?? detailTokenLine(period: period, keys: keys, days: days) {
                    lines.append(fallback)
                    if case .values(_, let values, _, _, _, _) = fallback,
                       values.contains(where: { $0.number > 0 }) { costUnavailable = true }
                }
                if keys.contains(where: { (days[$0]?.tokens ?? 0) > 0 }) { costUnavailable = true }
            }
        }
        var warnings: [String] = []
        if activity == nil, lines.count < TotalSpendPeriod.allCases.count {
            warnings.append("Z.ai token statistics are unavailable. Quota data is still available.")
        }
        if detailUnavailable {
            warnings.append("Some Z.ai cost estimates are unavailable. Other usage data is still available.")
        }
        if costUnavailable, !Task.isCancelled {
            AppDiagnostics.record(
                .historyScan, result: .degraded, category: .decoding, providerID: provider.id,
                localContext: "coding plan model breakdown or exact pricing incomplete"
            )
        }
        return (lines.isEmpty && activity == nil ? nil : lines, warnings, costUnavailable || !warnings.isEmpty)
    }

    private func pricedLine(
        period: TotalSpendPeriod, keys: [String], days: [String: ZAIDetailMapper.Day]
    ) -> MetricLine? {
        var tokens = 0
        var cost = 0.0
        for key in keys {
            guard let day = days[key], let amount = day.costUSD,
                  let next = UsageLogNumbers.sum(tokens, day.tokens), (cost + amount).isFinite else { return nil }
            tokens = next
            cost += amount
        }
        // 상세가 비어 있으면 이미 보고된 activity 토큰을 0으로 덮지 않음.
        guard tokens > 0 else { return nil }
        return .values(label: period.lineLabel, values: [
            MetricValue(number: cost, kind: .dollars, estimated: true),
            MetricValue(number: Double(tokens), kind: .count, label: "tokens")
        ])
    }

    private func detailTokenLine(
        period: TotalSpendPeriod, keys: [String], days: [String: ZAIDetailMapper.Day]
    ) -> MetricLine? {
        var tokens = 0
        for key in keys {
            guard let day = days[key], day.tokensComplete,
                  let next = UsageLogNumbers.sum(tokens, day.tokens) else { return nil }
            tokens = next
        }
        return .values(label: period.lineLabel, values: [
            MetricValue(number: Double(tokens), kind: .count, label: "tokens")
        ])
    }

    private func loadDetails(
        apiKey: String, window: ZAIDetailWindow, pricing: ModelPricing
    ) async -> ZAIDetailMapper.Parsed? {
        do {
            try Task.checkCancellation()
            let response = try await usageClient.fetchDetails(apiKey: apiKey, window: window)
            guard (200..<300).contains(response.statusCode) else {
                throw ZAIUsageError.requestFailed(response.statusCode)
            }
            return try ZAIDetailMapper.map(response.body, window: window, pricing: pricing)
        } catch {
            guard !Task.isCancelled else { return nil }
            AppDiagnostics.record(
                .historyScan, result: .degraded, providerID: provider.id, error: error,
                localContext: "coding plan model detail unavailable"
            )
            return nil
        }
    }

    private func loadActivity(apiKey: String, at date: Date) async -> [MetricLine]? {
        do {
            try Task.checkCancellation()
            let window = ZAIActivityWindow(now: date, calendar: calendar ?? .current)
            let response = try await usageClient.fetchActivity(apiKey: apiKey, window: window)
            guard (200..<300).contains(response.statusCode) else {
                throw ZAIUsageError.requestFailed(response.statusCode)
            }
            return try ZAIActivityMapper.map(response.body, window: window)
        } catch {
            guard !Task.isCancelled else { return nil }
            AppDiagnostics.record(
                .historyScan, result: .degraded, providerID: provider.id, error: error,
                localContext: "coding plan token activity unavailable"
            )
            return nil
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
