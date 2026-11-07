import Foundation

/// 모든 provider의 `UsageError`가 그대로 반복하던 공용 user-facing 문구 (transport 실패, 손상된 응답, non-2xx status).
/// 의도적으로 표현이 다른 provider(Grok의 "billing" 문구 등)는 자체 문자열 유지.
enum ProviderUsageErrorText {
    static let connectionFailed = "Usage request failed. Check your connection."
    static let invalidResponse = "Usage response invalid. Try again later."
    static func requestFailed(statusCode: Int) -> String {
        "Usage request failed (HTTP \(statusCode)). Try again later."
    }
}
