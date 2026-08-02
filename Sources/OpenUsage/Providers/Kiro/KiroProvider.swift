import Foundation

@MainActor
final class KiroProvider: ProviderRuntime {
    let provider = Provider(
        id: "kiro",
        displayName: "Kiro",
        icon: .providerMark("kiro"),
        links: []
    )

    let authStore: KiroAuthStore
    let usageClient: KiroUsageClient
    let now: @Sendable () -> Date

    init(
        authStore: KiroAuthStore = KiroAuthStore(),
        usageClient: KiroUsageClient = KiroUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
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
