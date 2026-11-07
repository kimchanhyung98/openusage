import Foundation

/// OAuth형 provider 공통 authenticated-fetch 시퀀스: 시도 → 401/403이면 token refresh 후 1회 재시도 → 재차 401/403은 hard auth 실패. auth 실패가 아닌 응답(성공, 429, 5xx)은 그대로 반환 — 해석은 provider mapper 소관.
/// `refreshAccessToken` closure가 provider별 refresh 전부(refresh token 로드, token endpoint 호출, body 해석, rotated credential 저장)를 소유. Devin은 의도적 미사용 — 401/403 시 token refresh가 아니라 auth source 전환.
@MainActor
enum ProviderAuthRetry {
    /// "요청 실패"가 아니라 "token 불량"을 뜻하는 status.
    nonisolated static func isAuthFailure(_ response: HTTPResponse) -> Bool {
        response.statusCode == 401 || response.statusCode == 403
    }

    /// 사용 가능한 body를 기대하는 응답의 triage: 401/403은 `authExpired`, 그 외 non-2xx는 `requestFailed(status)`, 2xx는 통과.
    nonisolated static func requireSuccess(
        _ response: HTTPResponse,
        authExpired: Error,
        requestFailed: (Int) -> Error
    ) throws {
        guard !isAuthFailure(response) else { throw authExpired }
        guard (200..<300).contains(response.statusCode) else { throw requestFailed(response.statusCode) }
    }

    /// `attempt`는 최대 2회 호출. `retriedConnectionFailed`는 재시도 중 transport 실패용 별도 오류(Cursor) — 생략 시 `connectionFailed`.
    static func fetch(
        token: String,
        attempt: (_ accessToken: String) async throws -> HTTPResponse,
        refreshAccessToken: () async throws -> String,
        connectionFailed: Error,
        retriedConnectionFailed: Error? = nil,
        authExpired: Error
    ) async throws -> HTTPResponse {
        let response: HTTPResponse
        do {
            response = try await attempt(token)
        } catch {
            throw connectionFailed
        }
        guard isAuthFailure(response) else { return response }

        AppLog.debug(.auth, "\(response.statusCode) -> refreshing token, retrying once")
        let refreshed = try await refreshAccessToken()

        let retried: HTTPResponse
        do {
            retried = try await attempt(refreshed)
        } catch {
            throw retriedConnectionFailed ?? connectionFailed
        }
        if isAuthFailure(retried) {
            AppLog.warn(.auth, "retry still unauthorized -> auth expired")
            throw authExpired
        }
        return retried
    }
}
