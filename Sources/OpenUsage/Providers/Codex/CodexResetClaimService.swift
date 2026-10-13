import Foundation

/// Reset-credit 소비 결과. 실패한 요청은 사용자 확인 대상을 바꾸지 않고 같은 요청으로만 재시도.
enum ResetClaimOutcome: Equatable, Sendable {
    case success
    case nothingToReset
    case noCredit
    case failed
}

/// 표시한 사용량의 인증 출처·주체로만 크레딧 소비. 재시도도 같은 확인·크레딧에 결합.
@MainActor
final class CodexResetClaimService {
    fileprivate struct MatchedCredit {
        let binding: CodexResetClaimBinding
        let expiry: Date
        let creditID: String
    }

    /// 카드 서비스 교체 후에도 같은 확인 요청의 크레딧·진행 상태 유지.
    @MainActor
    final class RequestState {
        fileprivate var matchedCredits: [String: MatchedCredit] = [:]
        fileprivate var activeRequestIDs: Set<String> = []
    }

    private let usageClient: CodexUsageClient
    private let credentialLoader: (CodexAuthState.Source) async throws -> CodexAuthState?
    private let isCurrent: () -> Bool
    private let refreshAfterClaim: () async -> Void
    let requestState: RequestState

    init(
        usageClient: CodexUsageClient,
        credentialLoader: @escaping (CodexAuthState.Source) async throws -> CodexAuthState?,
        requestState: RequestState = RequestState(),
        isCurrent: @escaping () -> Bool = { true },
        refreshAfterClaim: @escaping () async -> Void = {}
    ) {
        self.usageClient = usageClient
        self.credentialLoader = credentialLoader
        self.requestState = requestState
        self.isCurrent = isCurrent
        self.refreshAfterClaim = refreshAfterClaim
    }

    convenience init(
        authStore: CodexAuthStore,
        usageClient: CodexUsageClient,
        requestState: RequestState = RequestState(),
        isCurrent: @escaping () -> Bool = { true },
        refreshAfterClaim: @escaping () async -> Void
    ) {
        self.init(
            usageClient: usageClient,
            credentialLoader: { source in
                try await loadOffMainActor {
                    switch source {
                    case .file(let path):
                        guard authStore.authPaths().contains(path) else { return nil }
                        return authStore.loadAuth(at: path)
                    case .keychain:
                        return authStore.loadKeychainAuth()
                    case .accountSnapshot(let profileID):
                        guard authStore.scope == .accountSnapshot(profileID: profileID) else { return nil }
                        return try authStore.loadAccountSnapshot(profileID: profileID, allowInteraction: true)
                    }
                }
            },
            requestState: requestState,
            isCurrent: isCurrent,
            refreshAfterClaim: refreshAfterClaim
        )
    }

    func claim(
        creditExpiringAt expiry: Date,
        redeemRequestID: String,
        binding: CodexResetClaimBinding
    ) async -> ResetClaimOutcome {
        guard !Task.isCancelled, isCurrent(), requestState.activeRequestIDs.insert(redeemRequestID).inserted else {
            return bindingFailure()
        }
        defer { requestState.activeRequestIDs.remove(redeemRequestID) }
        if let previous = requestState.matchedCredits[redeemRequestID],
           previous.binding != binding || previous.expiry != expiry {
            return bindingFailure()
        }
        guard let initial = await loadCredential(for: binding) else { return .failed }

        let creditID: String
        if let previous = requestState.matchedCredits[redeemRequestID] {
            creditID = previous.creditID
        } else {
            let list: HTTPResponse
            do {
                list = try await usageClient.fetchResetCredits(
                    accessToken: initial.auth.tokens!.accessToken!, accountID: initial.auth.tokens?.accountID
                )
            } catch {
                AppDiagnostics.failure(.resetClaim, error: error, providerID: "codex",
                                       localContext: "Reset claim credit list request failed")
                return .failed
            }
            guard !Task.isCancelled, isCurrent() else { return bindingFailure() }
            guard (200..<300).contains(list.statusCode),
                  let body = (try? JSONSerialization.jsonObject(with: list.body)) as? [String: Any] else {
                return responseFailure(list, context: "credit list")
            }
            guard let matched = Self.creditID(in: body, expiringAt: expiry) else {
                AppDiagnostics.record(.resetClaim, result: .success, category: .notAvailable, providerID: "codex")
                await refreshIfBound(to: binding)
                return .noCredit
            }
            creditID = matched
            requestState.matchedCredits[redeemRequestID] = MatchedCredit(binding: binding, expiry: expiry, creditID: matched)
        }

        // GET 대기 중의 재로그인·로그아웃 확인. 같은 출처·주체의 정상 토큰 회전만 허용.
        guard let current = await loadCredential(for: binding), !Task.isCancelled, isCurrent() else { return .failed }
        let response: HTTPResponse
        do {
            response = try await usageClient.consumeResetCredit(
                accessToken: current.auth.tokens!.accessToken!, accountID: current.auth.tokens?.accountID,
                creditID: creditID, redeemRequestID: redeemRequestID
            )
        } catch {
            AppDiagnostics.failure(.resetClaim, error: error, providerID: "codex",
                                   localContext: "Reset claim consume request failed")
            return .failed
        }
        let outcome = Self.outcome(fromConsume: response)
        guard outcome != .failed else { return responseFailure(response, context: "consume") }
        AppDiagnostics.record(.resetClaim, result: .success, category: outcome == .success ? nil : .notAvailable,
                              providerID: "codex")
        await refreshIfBound(to: binding)
        return outcome
    }

    private func refreshIfBound(to binding: CodexResetClaimBinding) async {
        // 완료된 요청의 인증만 재확인. 무관한 카탈로그 변경의 후속 조회 허용 여부는 router에서 판단.
        do {
            guard !Task.isCancelled,
                  let current = try await credentialLoader(binding.source),
                  binding.matches(current), !Task.isCancelled else {
                AppLog.info(LogTag.plugin("codex"), "post-claim refresh skipped: credential binding changed")
                AppDiagnostics.record(.postClaimRefresh, result: .bindingChanged, providerID: "codex")
                return
            }
            await refreshAfterClaim()
        } catch {
            AppDiagnostics.failure(.postClaimRefresh, error: error, providerID: "codex",
                                   localContext: "Post-claim credential verification failed")
        }
    }

    private func loadCredential(for binding: CodexResetClaimBinding) async -> CodexAuthState? {
        guard !Task.isCancelled, isCurrent() else {
            _ = bindingFailure()
            return nil
        }
        do {
            guard let state = try await credentialLoader(binding.source) else {
                AppDiagnostics.record(.resetClaim, result: .failure, category: .notLoggedIn, providerID: "codex")
                return nil
            }
            guard !Task.isCancelled, isCurrent(), binding.matches(state) else {
                _ = bindingFailure()
                return nil
            }
            return state
        } catch {
            AppDiagnostics.failure(.resetClaim, error: error, providerID: "codex",
                                   localContext: "Reset claim credential read failed")
            return nil
        }
    }

    private func bindingFailure() -> ResetClaimOutcome {
        AppDiagnostics.record(.resetClaim, result: .failure, category: .authInvalid, providerID: "codex",
                              localContext: "Reset claim stopped because its account confirmation changed")
        return .failed
    }

    private func responseFailure(_ response: HTTPResponse, context: String) -> ResetClaimOutcome {
        AppDiagnostics.record(.resetClaim, result: .failure,
                              category: (200..<300).contains(response.statusCode) ? .decoding : .http(response.statusCode),
                              providerID: "codex", localContext: "Reset claim \(context) failed (HTTP \(response.statusCode))")
        return .failed
    }

    /// `expires_at`이 `expiry`와 일치(±1s — 실제 매칭은 정확 일치, 허용치는 sub-second 절단 흡수용)하는 still-available credit의 id.
    /// mapper의 status filter와 동일 — `status` 없는 credit은 available 간주, 명시적 non-"available"만 제외.
    static func creditID(in body: [String: Any], expiringAt expiry: Date) -> String? {
        guard let credits = body["credits"] as? [[String: Any]] else { return nil }
        return credits.first { credit in
            if let status = credit["status"] as? String, status != "available" { return false }
            guard let date = parseExpiry(credit["expires_at"]) else { return false }
            return abs(date.timeIntervalSince(expiry)) < 1
        }?["id"] as? String
    }

    /// Consume 응답 → popover outcome. protocol code 4종 모두 HTTP 200으로 도착(outcome은 body의 `code`) — non-2xx·미인식 code는 `.failed`.
    static func outcome(fromConsume response: HTTPResponse) -> ResetClaimOutcome {
        guard (200..<300).contains(response.statusCode),
              let body = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any],
              let code = body["code"] as? String
        else {
            return .failed
        }
        switch code {
        case "reset", "already_redeemed":
            return .success
        case "nothing_to_reset":
            return .nothingToReset
        case "no_credit":
            return .noCredit
        default:
            return .failed
        }
    }

    private static func parseExpiry(_ value: Any?) -> Date? {
        if let string = value as? String, let date = OpenUsageISO8601.date(from: string) {
            return date
        }
        if let seconds = ProviderParse.number(value) {
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }
}
