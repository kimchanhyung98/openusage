import Foundation

/// Reset-credit claim의 결과 — consume endpoint의 `code` 4종을 popover 표시용으로 축약.
/// `reset`·`already_redeemed`는 둘 다 성공 (후자는 retry에서 idempotency key가 동작한 것), transport/HTTP 오류는 `.failed`.
enum ResetClaimOutcome: Equatable, Sendable {
    case success
    case nothingToReset
    case noCredit
    case failed
}

/// Codex rate-limit reset credit claim — 앱의 유일한 provider-API write, 의도적으로 좁은 범위 (호출당 credit 1개, 명시적 credit id, caller의 idempotency key 보호).
/// Claim 시점에 credit 목록(안전한 GET)을 재조회해 expiry로 매칭 — 그사이 CLI/web에서 사라진 credit은 `.noCredit`. 성공 시 강제 Codex refresh 완료 후 반환.
@MainActor
final class CodexResetClaimService {
    typealias Credentials = (accessToken: String, accountID: String?)

    private let usageClient: CodexUsageClient
    private let credentialCandidates: () async -> [Credentials]
    private let refreshAfterClaim: () async -> Void
    /// Idempotency key별 매칭된 credit id — retry는 재매칭 없이 같은 (key, credit) 쌍을 replay.
    /// 응답 유실 후 재조회 목록에는 credit이 없어, replay만이 서버의 `already_redeemed`로 성공을 증명. Session-lived, popover의 per-credit UUID가 key.
    private var matchedCreditIDs: [String: String] = [:]

    /// Test seam — credential 후보와 refresh hook 주입, 후보는 인증될 때까지 순서대로 시도 (`claim` 참고).
    init(
        usageClient: CodexUsageClient,
        credentialCandidates: @escaping () async -> [Credentials],
        refreshAfterClaim: @escaping () async -> Void = {}
    ) {
        self.usageClient = usageClient
        self.credentialCandidates = credentialCandidates
        self.refreshAfterClaim = refreshAfterClaim
    }

    /// Production 연결 — provider의 auth store·usage client 공유로 credential 선택이 `refresh()`와 drift 불가 (파일 우선, keychain fallback, auth 거부 시 다음 후보).
    /// Token refresh 없음 — claim은 성공한 usage fetch 직후 실행이라 여전히 auth에 실패하는 후보는 dead, 다음 후보가 정답.
    convenience init(
        authStore: CodexAuthStore,
        usageClient: CodexUsageClient,
        refreshAfterClaim: @escaping () async -> Void
    ) {
        self.init(
            usageClient: usageClient,
            credentialCandidates: {
                var candidates = authStore.loadAuthCandidates()
                if let keychain = await loadOffMainActor({ authStore.loadKeychainAuth() }) {
                    candidates.append(keychain)
                }
                return candidates.compactMap { candidate in
                    guard candidate.hasUsableAccessToken, let token = candidate.auth.tokens?.accessToken else {
                        return nil
                    }
                    return (token, candidate.auth.tokens?.accountID)
                }
            },
            refreshAfterClaim: refreshAfterClaim
        )
    }

    /// `expiry`에 만료되는 credit claim — throw 없음, 모든 실패는 loud log 후 popover용 outcome으로 축약.
    func claim(creditExpiringAt expiry: Date, redeemRequestID: String) async -> ResetClaimOutcome {
        let candidates = await credentialCandidates()
        guard !candidates.isEmpty else {
            AppLog.error(LogTag.plugin("codex"), "reset claim: no usable Codex credentials")
            return .failed
        }

        // 이미 매칭된 idempotency key의 retry는 재매칭 없이 같은 (key, credit) 쌍 replay — 서버의 `already_redeemed`만이 유실된 성공을 증명.
        let creditID: String
        var preferredCandidates = candidates
        if let replayID = matchedCreditIDs[redeemRequestID] {
            creditID = replayID
        } else {
            switch await matchCredit(expiringAt: expiry, candidates: candidates) {
            case .matched(let id, let authenticated):
                creditID = id
                matchedCreditIDs[redeemRequestID] = id
                // 목록 fetch를 인증한 credential 우선. dedup은 (token, account) 쌍 전체 기준 — ChatGPT-Account-Id가 authorization 대상을 바꾸므로 계정이 다른 동일 token은 별개 fallback.
                preferredCandidates = [authenticated] + candidates.filter {
                    $0.accessToken != authenticated.accessToken || $0.accountID != authenticated.accountID
                }
            case .noCredit:
                // 오류 아님 — popover 렌더 이후 CLI/web에서 claim됐거나 만료. refresh가 timeline을 실제 상태와 동기화.
                AppLog.warn(LogTag.plugin("codex"), "reset claim: no available credit matches the picked expiry")
                await refreshAfterClaim()
                return .noCredit
            case .failed:
                return .failed
            }
        }

        let outcome = await consume(
            creditID: creditID, redeemRequestID: redeemRequestID, candidates: preferredCandidates
        )
        if outcome != .failed {
            // 상태 변경(또는 snapshot과 불일치) 확인 — 결과 banner가 이미 동기화된 meter·credit count 위에 뜨도록 refresh 후 반환.
            await refreshAfterClaim()
        }
        return outcome
    }

    /// Consume POST — auth 거부(401/403) 시 다음 credential 후보로 fallback.
    /// 반복 안전 — 모든 시도가 같은 idempotency key를 전송하므로 credit은 최대 1개만 소모.
    private func consume(
        creditID: String, redeemRequestID: String, candidates: [Credentials]
    ) async -> ResetClaimOutcome {
        var lastRejection: Int?
        for credentials in candidates {
            let response: HTTPResponse
            do {
                response = try await usageClient.consumeResetCredit(
                    accessToken: credentials.accessToken,
                    accountID: credentials.accountID,
                    creditID: creditID,
                    redeemRequestID: redeemRequestID
                )
            } catch {
                AppLog.error(LogTag.plugin("codex"), "reset claim: consume request failed: \(error.localizedDescription)")
                return .failed
            }
            if response.statusCode == 401 || response.statusCode == 403 {
                lastRejection = response.statusCode
                continue
            }
            let outcome = Self.outcome(fromConsume: response)
            if outcome == .failed {
                AppLog.error(
                    LogTag.plugin("codex"),
                    "reset claim: consume failed (\(response.statusCode)): "
                        + LogRedaction.bodyPreview(String(decoding: response.body, as: UTF8.self), limit: 300)
                )
            }
            return outcome
        }
        AppLog.error(LogTag.plugin("codex"), "reset claim: consume rejected for every credential (last: \(lastRejection.map(String.init) ?? "none"))")
        return .failed
    }

    private enum MatchResult {
        case matched(creditID: String, credentials: Credentials)
        case noCredit
        case failed
    }

    /// 새 credit 목록(안전한 GET)에서 사용자가 고른 credit의 id를 expiry로 매칭.
    /// credential 후보를 순서대로 시도, 401/403은 다음 후보로 — provider probe와 동일한 fallback이라 stale한 첫 auth 파일이 claim을 가로막지 못함.
    private func matchCredit(expiringAt expiry: Date, candidates: [Credentials]) async -> MatchResult {
        var lastFailure = "no credential candidate authenticated"
        for credentials in candidates {
            let list: HTTPResponse
            do {
                list = try await usageClient.fetchResetCredits(
                    accessToken: credentials.accessToken, accountID: credentials.accountID
                )
            } catch {
                AppLog.error(LogTag.plugin("codex"), "reset claim: credit list fetch failed: \(error.localizedDescription)")
                return .failed
            }
            if list.statusCode == 401 || list.statusCode == 403 {
                lastFailure = "credit list fetch rejected (\(list.statusCode))"
                continue
            }
            guard (200..<300).contains(list.statusCode), let body = ProviderParse.jsonObject(list.body) else {
                AppLog.error(LogTag.plugin("codex"), "reset claim: credit list fetch failed (\(list.statusCode))")
                return .failed
            }
            guard let matched = Self.creditID(in: body, expiringAt: expiry) else { return .noCredit }
            return .matched(creditID: matched, credentials: credentials)
        }
        AppLog.error(LogTag.plugin("codex"), "reset claim: \(lastFailure)")
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
              let body = ProviderParse.jsonObject(response.body),
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
