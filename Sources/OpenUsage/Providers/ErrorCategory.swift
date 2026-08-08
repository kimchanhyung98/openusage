import Foundation

/// refresh 실패를 telemetry에서 그룹화하기 위한 안정적 bucket — free-form 오류 메시지는 그룹화 불가·정보 유출 위험이라 raw value만 전송. raw value는 telemetry에 보고되는 문자열이므로 변경 금지.
/// `notLoggedIn`은 의도적 분리 — 미인증 provider의 실패는 버그가 아닌 기대 노이즈라 분석에서 필터링 가능해야 함.
enum ErrorCategory: String, Sendable, CaseIterable, Codable {
    case notLoggedIn = "not_logged_in"
    /// 유효했던 credential의 만료·폐기·세션 충돌.
    case authExpired = "auth_expired"
    /// 만료가 아니라 구조적으로 잘못된 auth (payload 손상, OAuth URL 오설정, 미지원 key).
    case authInvalid = "auth_invalid"
    /// 로컬 credential은 존재하나 file·database·Keychain 항목 읽기 실패.
    case credentialAccess = "credential_access"
    /// 요청 자체가 완료되지 못한 경우 (transport/connection 실패).
    case network = "network"
    /// 응답은 왔지만 파싱 실패 또는 필수 필드 누락.
    case decoding = "decoding"
    case http4xx = "http_4xx"
    case http5xx = "http_5xx"
    case rateLimited = "rate_limited"
    /// 해당 account/plan에서 usage 데이터가 정당하게 없는 경우 (구독 없음, API-key 전용, quota endpoint 부재) — 오작동 아님.
    case notAvailable = "not_available"
    case other = "other"

    /// non-2xx HTTP status 분류 — 429는 rate limiting, 나머지는 4xx/5xx 경계로 구분.
    static func http(_ statusCode: Int) -> ErrorCategory {
        switch statusCode {
        case 429: return .rateLimited
        case 400..<500: return .http4xx
        case 500..<600: return .http5xx
        default: return .other
        }
    }
}

/// 자신의 telemetry bucket을 아는 error — 아래 모든 provider error enum이 conform.
protocol CategorizedError: Error {
    var errorCategory: ErrorCategory { get }
}

// MARK: - Provider conformances
// retroactive conformance를 한 파일에 모음 — 새 error case가 `.other`로 조용히 떨어지는 대신 여기서 컴파일 오류 발생 (exhaustive switch).

extension ClaudeAuthError: CategorizedError {
    var errorCategory: ErrorCategory {
        switch self {
        case .notLoggedIn: .notLoggedIn
        case .sessionExpired, .tokenExpired, .desktopTokenExpired: .authExpired
        case .invalidOAuthURL, .desktopCredentialsUnavailable: .authInvalid
        case .desktopPermissionRequired: .credentialAccess
        case .credentialsChanged: .other
        }
    }
}

extension ClaudeUsageError: CategorizedError {
    var errorCategory: ErrorCategory {
        switch self {
        case .connectionFailed: .network
        case .invalidResponse: .decoding
        case .requestFailed(let status): ErrorCategory.http(status)
        }
    }
}

extension CodexAuthError: CategorizedError {
    var errorCategory: ErrorCategory {
        switch self {
        case .notLoggedIn: .notLoggedIn
        case .sessionExpired, .tokenConflict, .tokenRevoked, .tokenExpired: .authExpired
        case .usageAPIKey: .notAvailable
        case .invalidAuthPayload: .authInvalid
        }
    }
}

extension CodexUsageError: CategorizedError {
    var errorCategory: ErrorCategory {
        switch self {
        case .connectionFailed: .network
        case .invalidResponse: .decoding
        case .requestFailed(let status): ErrorCategory.http(status)
        }
    }
}

extension CursorAuthError: CategorizedError {
    var errorCategory: ErrorCategory {
        switch self {
        case .notLoggedIn: .notLoggedIn
        case .sessionExpired, .tokenExpired: .authExpired
        }
    }
}

extension CursorUsageError: CategorizedError {
    var errorCategory: ErrorCategory {
        switch self {
        case .connectionFailed: .network
        case .invalidResponse, .totalUsageLimitMissing: .decoding
        case .requestFailed(let status): ErrorCategory.http(status)
        case .requestBasedUnavailable, .noActiveSubscription: .notAvailable
        case .usageAfterRefreshFailed: .other
        }
    }
}

extension GrokAuthError: CategorizedError {
    var errorCategory: ErrorCategory {
        switch self {
        case .notLoggedIn: .notLoggedIn
        case .invalidAuth: .authInvalid
        case .expired: .authExpired
        }
    }
}

extension GrokUsageError: CategorizedError {
    var errorCategory: ErrorCategory {
        switch self {
        case .connectionFailed: .network
        case .invalidResponse: .decoding
        case .requestFailed(let status): ErrorCategory.http(status)
        }
    }
}

extension KimiAuthError: CategorizedError {
    var errorCategory: ErrorCategory {
        switch self {
        case .notLoggedIn: .notLoggedIn
        case .credentialsUnreadable, .credentialLockUnavailable,
             .credentialLockCompromised, .credentialSaveFailed: .credentialAccess
        case .credentialsInvalid, .unsupportedConfiguration: .authInvalid
        case .authExpired, .refreshRejected: .authExpired
        case .refreshResponseInvalid: .decoding
        }
    }
}

extension KimiUsageError: CategorizedError {
    var errorCategory: ErrorCategory {
        switch self {
        case .connectionFailed: .network
        case .requestFailed(let status): ErrorCategory.http(status)
        case .invalidResponse: .decoding
        case .quotaUnavailable: .notAvailable
        }
    }
}

extension KiroAuthError: CategorizedError {
    var errorCategory: ErrorCategory {
        switch self {
        case .notLoggedIn: .notLoggedIn
        case .credentialsUnreadable: .credentialAccess
        case .credentialsInvalid, .missingProfile: .authInvalid
        case .authExpired: .authExpired
        }
    }
}

extension KiroUsageError: CategorizedError {
    var errorCategory: ErrorCategory {
        switch self {
        case .connectionFailed: .network
        case .requestFailed(let status): ErrorCategory.http(status)
        case .invalidResponse: .decoding
        case .quotaUnavailable: .notAvailable
        }
    }
}

extension DevinAuthError: CategorizedError {
    var errorCategory: ErrorCategory {
        switch self {
        case .notLoggedIn: .notLoggedIn
        }
    }
}

extension DevinUsageError: CategorizedError {
    var errorCategory: ErrorCategory {
        switch self {
        case .invalidResponse: .decoding
        case .quotaUnavailable: .notAvailable
        }
    }
}

extension CopilotAuthError: CategorizedError {
    var errorCategory: ErrorCategory {
        switch self {
        case .notLoggedIn: .notLoggedIn
        case .tokenInvalid: .authExpired
        }
    }
}

extension CopilotUsageError: CategorizedError {
    var errorCategory: ErrorCategory {
        switch self {
        case .connectionFailed: .network
        case .invalidResponse: .decoding
        case .requestFailed(let status): ErrorCategory.http(status)
        case .quotaUnavailable: .notAvailable
        }
    }
}

extension OpenCodeUsageError: CategorizedError {
    var errorCategory: ErrorCategory {
        switch self {
        case .notLoggedIn: .notLoggedIn
        case .credentialsUnreadable, .databaseUnreadable: .credentialAccess
        }
    }
}

extension OpenRouterAuthError: CategorizedError {
    var errorCategory: ErrorCategory {
        switch self {
        case .missingKey: .notLoggedIn
        case .invalidKey: .authInvalid
        case .saveFailed, .deleteFailed: .other
        }
    }
}

extension OpenRouterUsageError: CategorizedError {
    var errorCategory: ErrorCategory {
        switch self {
        case .connectionFailed: .network
        case .invalidResponse: .decoding
        case .requestFailed(let status): ErrorCategory.http(status)
        }
    }
}

extension ZAIAuthError: CategorizedError {
    var errorCategory: ErrorCategory {
        switch self {
        case .missingKey: .notLoggedIn
        case .invalidKey: .authInvalid
        case .saveFailed, .deleteFailed: .other
        }
    }
}

extension ZAIUsageError: CategorizedError {
    var errorCategory: ErrorCategory {
        switch self {
        case .connectionFailed: .network
        case .invalidResponse: .decoding
        case .requestFailed(let status): ErrorCategory.http(status)
        case .noCodingPlan: .notAvailable
        }
    }
}

extension HTTPClientError: CategorizedError {
    var errorCategory: ErrorCategory {
        switch self {
        case .invalidResponse: .decoding
        }
    }
}

extension AntigravityError: CategorizedError {
    var errorCategory: ErrorCategory {
        switch self {
        case .notSignedIn: .notLoggedIn
        case .credentialStoreUnreadable: .credentialAccess
        case .invalidCredentialData: .authInvalid
        case .authExpired: .authExpired
        case .unavailable: .network
        }
    }
}
