import Foundation

/// 인증 오류의 사용자 복구 구분 — telemetry의 통합 authExpired bucket과 별개.
enum ProviderAuthenticationIssue: String, Codable, Sendable {
    case sessionExpired
    case signInNeeded

    init?(error: Error) {
        switch error {
        case CodexAuthError.sessionExpired, ClaudeAuthError.sessionExpired, ClaudeAuthError.desktopTokenExpired:
            self = .sessionExpired
        default:
            switch (error as? CategorizedError)?.errorCategory {
            case .notLoggedIn, .authExpired, .authInvalid: self = .signInNeeded
            default: return nil
            }
        }
    }
}

struct ProviderRefreshFailure: Equatable, Sendable {
    let message: String
    var category: ErrorCategory = .other
    var authenticationIssue: ProviderAuthenticationIssue?
}

/// 현재 앱 실행에서 완료된 refresh 결과 — 과거 사용량 cache를 인증 성공으로 오인하지 않음.
enum ProviderRefreshResult: Equatable, Sendable {
    case succeeded
    case failed(ProviderRefreshFailure)

    var failure: ProviderRefreshFailure? {
        guard case .failed(let failure) = self else { return nil }
        return failure
    }
}
