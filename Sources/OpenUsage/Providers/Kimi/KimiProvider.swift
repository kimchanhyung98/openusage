import Foundation

@MainActor
final class KimiProvider: ProviderRuntime {
    let provider = Provider(
        id: "kimi",
        displayName: "Kimi",
        icon: .providerMark("kimi"),
        links: [],
        usesDedicatedSpendLines: true
    )

    let authStore: KimiAuthStore
    let usageClient: KimiUsageClient
    let credentialLock: KimiCredentialLock
    let usageScanner: KimiUsageScanner
    let now: @Sendable () -> Date
    let pricing: @Sendable () async -> ModelPricing

    init(
        authStore: KimiAuthStore = KimiAuthStore(),
        usageClient: KimiUsageClient = KimiUsageClient(),
        credentialLock: KimiCredentialLock = KimiCredentialLock(),
        usageScanner: KimiUsageScanner? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        pricing: @escaping @Sendable () async -> ModelPricing = { await ModelPricingStore.shared.current() }
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.credentialLock = credentialLock
        self.usageScanner = usageScanner ?? KimiUsageScanner(
            environment: authStore.environment, homeDirectory: authStore.homeDirectory()
        )
        self.now = now
        self.pricing = pricing
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "kimi.session", provider: provider, title: "Session", sessionStartSignal: .zeroUsage)
                .supportingSoftLimit(.fiveHours)
                .exportingLimit("session", unit: "percent"),
            .percent(id: "kimi.weekly", provider: provider, title: "Weekly")
                .supportingSoftLimit(.weekly)
                .exportingLimit("weekly", unit: "percent")
        ]
    }

    func hasLocalCredentials() async -> Bool {
        do {
            guard let document = try await loadOffMainActor({ [authStore] in
                try authStore.loadCredentialDocument()
            }) else {
                return false
            }
            return authStore.isUsable(document, now: now())
        } catch {
            return false
        }
    }

    func refresh() async -> ProviderSnapshot {
        var snapshot = await quotaSnapshot()
        guard snapshot.errorCategory == nil else { return snapshot }
        let refreshedAt = snapshot.refreshedAt
        do {
            try Task.checkCancellation()
            if let scan = try await usageScanner.scan(now: refreshedAt, pricing: await pricing()) {
                snapshot.totalSpendLines = scan.totalSpendLines(now: refreshedAt)
                for warning in scan.warnings {
                    appendWarning(warning, to: &snapshot)
                }
                if scan.invalidRows > 0 {
                    AppDiagnostics.record(
                        .historyScan, result: .degraded, category: .decoding, providerID: provider.id,
                        localContext: "invalid Kimi Code usage records=\(scan.invalidRows)"
                    )
                }
            }
        } catch is CancellationError {
            return ProviderSnapshot.error(provider: provider, error: CancellationError())
        } catch {
            AppDiagnostics.record(
                .historyScan, result: .failure, providerID: provider.id, error: error
            )
            appendWarning(KimiHistoryError.unreadable.localizedDescription, to: &snapshot)
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
            guard var document = try await loadOffMainActor({ [authStore] in
                try authStore.loadCredentialDocument()
            }) else {
                throw KimiAuthError.notLoggedIn
            }
            guard authStore.isUsable(document, now: now()) else {
                throw KimiAuthError.authExpired
            }

            if authStore.needsRefresh(document, now: now()) {
                document = try await rotate(document, force: false)
            }
            guard var accessToken = document.credentials.accessToken?.nilIfEmpty else {
                throw KimiAuthError.authExpired
            }

            var response = try await fetch(accessToken)
            if ProviderAuthRetry.isAuthFailure(response) {
                guard case .current = document.credentials.source,
                      authStore.oauthLockEnabled
                else {
                    throw KimiAuthError.authExpired
                }
                document = try await rotate(document, force: true)
                guard let refreshedAccessToken = document.credentials.accessToken?.nilIfEmpty else {
                    throw KimiAuthError.authExpired
                }
                accessToken = refreshedAccessToken
                response = try await fetch(accessToken)
                guard !ProviderAuthRetry.isAuthFailure(response) else {
                    throw KimiAuthError.authExpired
                }
            }

            try ProviderAuthRetry.requireSuccess(
                response,
                authExpired: KimiAuthError.authExpired,
                requestFailed: KimiUsageError.requestFailed
            )
            let mapped = try KimiUsageMapper.map(response.body)
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

    private func rotate(
        _ original: KimiCredentialDocument,
        force: Bool
    ) async throws -> KimiCredentialDocument {
        guard case .current(_, _, let lockTarget) = original.credentials.source,
              authStore.oauthLockEnabled
        else {
            throw KimiAuthError.authExpired
        }

        let handle = try await credentialLock.acquire(target: lockTarget)
        do {
            let live = try await loadOffMainActor { [authStore] in
                try authStore.reloadCurrentDocument(original.credentials.source)
            }
            let tokenChanged = live.credentials.accessToken != original.credentials.accessToken
            if tokenChanged, authStore.hasUsableAccess(live, now: now()) {
                guard await handle.release() else {
                    throw KimiAuthError.credentialLockCompromised
                }
                return live
            }
            if !force, !authStore.needsRefresh(live, now: now()),
               authStore.isUsable(live, now: now()) {
                guard await handle.release() else {
                    throw KimiAuthError.credentialLockCompromised
                }
                return live
            }
            guard let refreshToken = live.credentials.refreshToken?.nilIfEmpty else {
                throw KimiAuthError.authExpired
            }

            let rotated: KimiTokenRefresh
            do {
                rotated = try await usageClient.refreshToken(refreshToken: refreshToken)
            } catch let error as KimiAuthError {
                throw error
            } catch let error as KimiUsageError {
                throw error
            } catch {
                throw KimiUsageError.connectionFailed
            }
            try await handle.performWhileValid { [authStore] in
                try await loadOffMainActor {
                    try authStore.persistRotatedCredentials(replacing: live, with: rotated)
                }
            }

            var updated = live
            updated.credentials.accessToken = rotated.accessToken
            updated.credentials.refreshToken = rotated.refreshToken
            updated.credentials.expiresAt = rotated.expiresAt
            updated.credentials.expiresIn = rotated.expiresIn
            guard await handle.release() else {
                throw KimiAuthError.credentialLockCompromised
            }
            return updated
        } catch {
            guard await handle.release() else {
                throw KimiAuthError.credentialLockCompromised
            }
            throw error
        }
    }

    private func fetch(_ accessToken: String) async throws -> HTTPResponse {
        do {
            return try await usageClient.fetchUsage(accessToken: accessToken)
        } catch {
            throw KimiUsageError.connectionFailed
        }
    }

    private func normalized(_ error: Error) -> Error {
        if error is KimiAuthError || error is KimiUsageError { return error }
        return KimiUsageError.connectionFailed
    }
}
