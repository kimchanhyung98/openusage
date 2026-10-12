import Foundation

extension ClaudeProvider {
    func fetchLiveUsage(
        state: inout ClaudeCredentialState,
        credentialGeneration: inout ClaudeCredentialGeneration,
        requestedAt: Date
    ) async throws -> ClaudeMappedUsage {
        guard let accountKey = state.accountIdentityKey, !accountKey.isEmpty else {
            AppLog.error(LogTag.plugin("claude"), "usage refresh blocked: account identity unavailable")
            throw ClaudeUsageStateStore.StoreError.identityUnavailable
        }
        let lease = try await usageStateStore.acquire(accountKey: accountKey)
        defer { withExtendedLifetime(lease) {} }
        var record = try await loadOffMainActor { try lease.read() }
        try await validateUsageCredentials(state, expected: credentialGeneration)
        try Task.checkCancellation()

        if let until = record.retryAfter, now() < until {
            AppLog.info(LogTag.plugin("claude"), "rate-limited (saved cooldown active)")
            return rateLimitedUsage(record, credentials: state.oauth)
        }
        // 잠금을 기다린 앱·CLI는 방금 끝난 같은 계정의 결과를 공유하며 수동 요청도 중복 전송하지 않음.
        if let completedAt = record.completedAt,
           (completedAt > requestedAt || (lease.waited && completedAt == requestedAt)),
           var cached = record.lastGood, record.retryAfter == nil {
            cached.liveQuotaObservedAt = nil
            return cached
        }

        var expectedGeneration = credentialGeneration
        defer { credentialGeneration = expectedGeneration }
        if authStore.needsRefresh(state.oauth),
           let refreshToken = state.oauth.refreshToken, !refreshToken.isEmpty {
            let refreshed = try await refreshAccessToken(
                state: &state, refreshToken: refreshToken, expectedGeneration: expectedGeneration
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
                if working.source == .desktop { throw ClaudeAuthError.desktopTokenExpired }
                guard let refreshToken = working.oauth.refreshToken, !refreshToken.isEmpty else {
                    throw ClaudeAuthError.tokenExpired
                }
                let refreshed = try await self.refreshAccessToken(
                    state: &working, refreshToken: refreshToken, expectedGeneration: expectedGeneration
                )
                if refreshed.persisted { expectedGeneration = expectedGeneration.replacing(working) }
                return refreshed.accessToken
            },
            connectionFailed: ClaudeUsageError.connectionFailed,
            authExpired: ClaudeAuthError.tokenExpired
        )
        let observedAt = now()
        if response.statusCode == 429 {
            record.rateLimited(
                now: observedAt,
                retryAfterSeconds: ClaudeUsageMapper.parseRetryAfterSeconds(response, now: observedAt)
            )
            let saved = record
            try await loadOffMainActor { try lease.save(saved) }
            AppLog.warn(LogTag.plugin("claude"), "usage rate limited; account cooldown saved")
            try await validateUsageCredentials(working, expected: expectedGeneration)
            return rateLimitedUsage(record, credentials: working.oauth)
        }

        try await validateUsageCredentials(working, expected: expectedGeneration)
        try Task.checkCancellation()
        var mapped = try ClaudeUsageMapper.mapUsageResponse(response, credentials: working.oauth, now: observedAt)
        mapped.liveQuotaObservedAt = observedAt
        mapped.quotaObservedAt = observedAt
        record.succeeded(mapped, at: observedAt)
        let saved = record
        try await loadOffMainActor { try lease.save(saved) }
        return mapped
    }

    private func validateUsageCredentials(
        _ state: ClaudeCredentialState, expected: ClaudeCredentialGeneration
    ) async throws {
        let allowInteraction = ProviderRefreshContext.isManual
        let current = try await loadOffMainActor { [authStore] in
            try authStore.credentialGeneration(
                forceDesktopFallback: state.source == .desktop,
                allowAccountInteraction: allowInteraction
            )
        }
        guard current == expected else { throw ClaudeAuthError.credentialsChanged }
    }

    private func rateLimitedUsage(
        _ record: ClaudeUsageStateStore.Record, credentials: ClaudeOAuth
    ) -> ClaudeMappedUsage {
        let seconds = record.retryAfter.map {
            Int(min(Double(Int.max / 2), max(0, $0.timeIntervalSince(now()).rounded(.up))))
        }
        var mapped = record.lastGood ?? ClaudeUsageMapper.rateLimitedUsage(
            credentials: credentials, retryAfterSeconds: seconds
        )
        if record.lastGood != nil {
            mapped.lines.append(ClaudeUsageMapper.rateLimitedNote(retryAfterSeconds: seconds))
            mapped.warning = ClaudeUsageMapper.rateLimitedWarning(retryAfterSeconds: seconds)
        }
        mapped.liveQuotaObservedAt = nil
        mapped.retryAfter = record.retryAfter
        return mapped
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
        let decoded: ClaudeRefreshResponse
        do {
            let response = try await usageClient.refreshToken(refreshToken, config: authStore.oauthConfig())
            if response.statusCode == 400 || response.statusCode == 401 {
                let body = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
                let errorCode = body?["error"] as? String ?? body?["error_description"] as? String
                if errorCode == "invalid_grant" {
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
            decoded = try JSONDecoder().decode(ClaudeRefreshResponse.self, from: response.body)
        } catch {
            AppDiagnostics.failure(.credentialRefresh, error: error, providerID: provider.id, localContext: "token refresh request failed")
            throw error
        }
        AppDiagnostics.record(.credentialRefresh, result: .success, providerID: provider.id)
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
        let allowAccountInteraction = ProviderRefreshContext.isManual
        do {
            guard try await Task.detached(priority: .utility, operation: { [authStore, state] in
                try authStore.save(
                    state, ifUnchanged: expectedGeneration, allowAccountInteraction: allowAccountInteraction
                )
            }).value else {
                throw ClaudeAuthError.credentialsChanged
            }
            persisted = true
            AppDiagnostics.record(.credentialSave, result: .success, providerID: provider.id)
        } catch let error as ClaudeAuthError where error == .credentialsChanged {
            AppDiagnostics.record(.credentialSave, result: .bindingChanged, providerID: provider.id)
            throw error
        } catch {
            persisted = false
            refreshIsDegraded = true
            AppDiagnostics.record(.credentialSave, result: .degraded, providerID: provider.id, error: error,
                                  localContext: "failed to persist rotated credentials; using the refreshed token for this session only")
        }
        AppLog.info(LogTag.auth("claude"), "token refresh ok (rotated)")
        return RefreshedAccess(accessToken: decoded.accessToken, persisted: persisted)
    }

}
