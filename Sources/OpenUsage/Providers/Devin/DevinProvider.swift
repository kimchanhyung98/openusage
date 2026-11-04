import Foundation

@MainActor
final class DevinProvider: ProviderRuntime {
    let retainsDedicatedSpendOnScanFailure = true
    let provider = Provider(
        id: "devin",
        displayName: "Devin",
        icon: .providerMark("devin"),
        links: [
            .init(label: "Dashboard", url: "https://app.devin.ai/settings/plans")
        ],
        usesDedicatedSpendLines: true
    )

    let authStore: DevinAuthStore
    let usageClient: DevinUsageClient
    let usageScanner: DevinUsageScanner
    let now: @Sendable () -> Date
    let pricing: @Sendable () async -> ModelPricing

    init(
        authStore: DevinAuthStore = DevinAuthStore(),
        usageClient: DevinUsageClient = DevinUsageClient(),
        usageScanner: DevinUsageScanner = DevinUsageScanner(),
        now: @escaping @Sendable () -> Date = Date.init,
        pricing: @escaping @Sendable () async -> ModelPricing = { await ModelPricingStore.shared.current() }
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.usageScanner = usageScanner
        self.now = now
        self.pricing = pricing
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "devin.daily", provider: provider, title: "Daily", metricLabel: "Daily quota")
                .exportingLimit("daily", unit: "percent"),
            .percent(id: "devin.weekly", provider: provider, title: "Weekly", metricLabel: "Weekly quota")
                .exportingLimit("weekly", unit: "percent"),
            .dollarBalance(id: "devin.extra", provider: provider, title: "Extra Balance", metricLabel: "Extra usage balance", valueWord: "left")
                .exportingLimit("extraUsageBalance", kind: .balance, unit: "usd", source: .value(kind: .dollars))
        ]
    }

    func hasLocalCredentials() async -> Bool {
        // `refresh()`와 동일한 credential 소스(credentials 파일 → 앱 auth) 확인, blocking 디스크/SQLite 읽기라 main actor 밖에서 수행
        if await loadOffMainActor({ [authStore] in authStore.loadCredentialsFile() }) != nil { return true }
        return await loadOffMainActor { [authStore] in authStore.loadAppAuth() } != nil
    }

    func refresh() async -> ProviderSnapshot {
        var snapshot = await quotaSnapshot()
        let refreshedAt = now()
        snapshot.refreshedAt = refreshedAt
        do {
            if let scan = try await usageScanner.scan(now: refreshedAt, pricing: await pricing()) {
                if !scan.series.daily.isEmpty || (scan.invalidRows == 0 && scan.unreadableStores == 0) {
                    snapshot.totalSpendLines = scan.totalSpendLines(now: refreshedAt)
                }
                for warning in scan.warnings { appendWarning(warning, to: &snapshot) }
                if !scan.warnings.isEmpty {
                    let category: ErrorCategory
                    if scan.unreadableStores > 0 {
                        category = .storage
                    } else if scan.invalidRows > 0 {
                        category = .decoding
                    } else {
                        category = .other
                    }
                    AppDiagnostics.record(
                        .historyScan, result: .degraded,
                        category: category, providerID: provider.id
                    )
                }
            }
        } catch is CancellationError {
            return snapshot
        } catch {
            AppDiagnostics.record(.historyScan, result: .failure, providerID: provider.id, error: error)
            appendWarning(error.localizedDescription, to: &snapshot)
        }
        return snapshot
    }

    private func appendWarning(_ message: String, to snapshot: inout ProviderSnapshot) {
        snapshot.warning = [snapshot.warning, message].compactMap { $0 }.joined(separator: " ")
        snapshot.warningPresentation = (snapshot.warningPresentation ?? []) + [.init(message)]
        snapshot.isDegraded = true
    }

    private func quotaSnapshot() async -> ProviderSnapshot {
        var sawAPIKey = false
        var sawAuthFailure = false
        let credentials = await loadOffMainActor { [authStore] in authStore.loadCredentialsFile() }

        if let credentials {
            sawAPIKey = true
            switch await attempt(auth: credentials) {
            case .success(let mapped):
                return snapshot(from: mapped)
            case .authFailure:
                sawAuthFailure = true
            case .unavailable:
                break
            }
        }

        let appAuth = await loadOffMainActor({ [authStore] in authStore.loadAppAuth() })
        if let appAuth,
           credentials == nil || shouldAttemptAppAuth(appAuth, after: credentials) {
            sawAPIKey = true
            switch await attempt(auth: appAuth) {
            case .success(let mapped):
                return snapshot(from: mapped)
            case .authFailure:
                sawAuthFailure = true
            case .unavailable:
                break
            }
        }

        if sawAuthFailure {
            return ProviderSnapshot.error(provider: provider, error: DevinAuthError.notLoggedIn)
        }
        if sawAPIKey {
            return ProviderSnapshot.error(provider: provider, error: DevinUsageError.quotaUnavailable)
        }
        return ProviderSnapshot.error(provider: provider, error: DevinAuthError.notLoggedIn)
    }

    private func attempt(auth: DevinAuth) async -> DevinAuthAttempt {
        let apiServerURL = authStore.effectiveAPIServerURL(auth)
        do {
            let response = try await usageClient.fetchUserStatus(auth: auth, apiServerURL: apiServerURL)
            if response.statusCode == 401 || response.statusCode == 403 {
                return .authFailure
            }
            guard (200..<300).contains(response.statusCode) else {
                return .unavailable
            }
            return .success(try DevinUsageMapper.mapUserStatusResponse(response))
        } catch {
            return .unavailable
        }
    }

    private func shouldAttemptAppAuth(_ appAuth: DevinAuth, after credentials: DevinAuth?) -> Bool {
        guard let credentials else { return true }
        return appAuth.apiKey != credentials.apiKey ||
            authStore.effectiveAPIServerURL(appAuth) != authStore.effectiveAPIServerURL(credentials)
    }

    private func snapshot(from mapped: DevinMappedUsage) -> ProviderSnapshot {
        ProviderSnapshot.make(provider: provider, plan: mapped.plan, lines: mapped.lines, refreshedAt: now())
    }
}

private enum DevinAuthAttempt {
    case success(DevinMappedUsage)
    case authFailure
    case unavailable
}
