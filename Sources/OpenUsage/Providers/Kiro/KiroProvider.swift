import Foundation

@MainActor
final class KiroProvider: ProviderRuntime {
    let retainsDedicatedSpendOnScanFailure = true
    let provider = Provider(
        id: "kiro",
        displayName: "Kiro",
        icon: .providerMark("kiro"),
        links: [],
        usesDedicatedSpendLines: true
    )

    let authStore: KiroAuthStore
    let usageClient: KiroUsageClient
    let usageScanner: KiroUsageScanner
    let now: @Sendable () -> Date

    init(
        authStore: KiroAuthStore = KiroAuthStore(),
        usageClient: KiroUsageClient = KiroUsageClient(),
        usageScanner: KiroUsageScanner = KiroUsageScanner(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.usageScanner = usageScanner
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .boundedCount(
                id: "kiro.credits",
                provider: provider,
                title: "Credits",
                limit: 50,
                suffix: "credits",
                periodDurationMs: KiroUsageMapper.billingPeriodMs
            )
            .exportingLimit("credits", unit: "credits")
        ]
    }

    func hasLocalCredentials() async -> Bool {
        do {
            guard let auth = try await loadOffMainActor({ [authStore] in try authStore.loadAuth() }) else {
                return false
            }
            return authStore.isUsable(auth, now: now())
        } catch {
            return false
        }
    }

    func refresh() async -> ProviderSnapshot {
        var snapshot = await quotaSnapshot()
        let refreshedAt = now()
        snapshot.refreshedAt = refreshedAt
        do {
            if let scan = try await usageScanner.scan(now: refreshedAt) {
                if !scan.daily.isEmpty || scan.invalidRows == 0 {
                    snapshot.totalSpendLines = scan.totalSpendLines(now: refreshedAt)
                }
                for warning in scan.warnings { appendWarning(warning, to: &snapshot) }
                if !scan.warnings.isEmpty {
                    AppDiagnostics.record(
                        .historyScan, result: .degraded,
                        category: scan.invalidRows > 0 ? .decoding : .other, providerID: provider.id
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
        do {
            guard var auth = try await loadOffMainActor({ [authStore] in try authStore.loadAuth() }) else {
                throw KiroAuthError.notLoggedIn
            }
            guard authStore.isUsable(auth, now: now()) else {
                throw KiroAuthError.authExpired
            }

            var response = try await fetch(auth)
            if ProviderAuthRetry.isAuthFailure(response) {
                guard let reloaded = try await loadOffMainActor({ [authStore] in try authStore.loadAuth() }),
                      reloaded.accessToken != auth.accessToken,
                      authStore.isUsable(reloaded, now: now())
                else {
                    throw KiroAuthError.authExpired
                }
                auth = reloaded
                response = try await fetch(auth)
                guard !ProviderAuthRetry.isAuthFailure(response) else {
                    throw KiroAuthError.authExpired
                }
            }

            try ProviderAuthRetry.requireSuccess(
                response,
                authExpired: KiroAuthError.authExpired,
                requestFailed: KiroUsageError.requestFailed
            )
            let mapped = try KiroUsageMapper.map(response.body)
            return ProviderSnapshot.make(
                provider: provider,
                plan: mapped.plan,
                lines: mapped.lines,
                refreshedAt: now()
            )
        } catch {
            return ProviderSnapshot.error(provider: provider, error: normalized(error))
        }
    }

    private func fetch(_ auth: KiroAuth) async throws -> HTTPResponse {
        do {
            return try await usageClient.fetchUsageLimits(
                accessToken: auth.accessToken,
                profileArn: auth.profileArn
            )
        } catch {
            throw KiroUsageError.connectionFailed
        }
    }

    private func normalized(_ error: Error) -> Error {
        if error is KiroAuthError || error is KiroUsageError { return error }
        return KiroUsageError.connectionFailed
    }
}
