import Foundation

/// Antigravity의 user-facing 실패. 전략별 오류(LS 미실행, decode miss)는 삼키고 다음 전략 시도 — 모든 전략 소진 시에만 이 중 하나가 UI 도달.
enum AntigravityError: Error, LocalizedError, Equatable {
    /// 어디에도 사용 가능한 credential 없음 (LS 미실행, keychain token 없음, cache 없음).
    case notSignedIn
    /// Keychain credential이 있을 수 있으나 macOS가 읽기를 거부.
    case credentialStoreUnreadable
    /// Keychain 항목은 있으나 사용 가능한 Antigravity credential 데이터가 없음.
    case invalidCredentialData
    /// token이 있었지만 거부(401/403)되고 refresh로도 복구 실패.
    case authExpired
    /// credential은 유효해 보이나 모든 endpoint 접근 불가 (네트워크/서버 장애). `notSignedIn`과 구분 — 장애 중 로그인된 사용자에게 Antigravity 시작을 안내하지 않기 위함.
    case unavailable

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Start Antigravity or run `agy` and try again."
        case .credentialStoreUnreadable:
            return "Couldn't read Antigravity credentials from Keychain. Unlock Keychain or sign in to Antigravity again."
        case .invalidCredentialData:
            return "Antigravity credentials are invalid. Open Antigravity or run `agy` to sign in again."
        case .authExpired:
            return "Antigravity sign-in expired. Open Antigravity or run `agy` to refresh."
        case .unavailable:
            return "Antigravity usage is temporarily unavailable. Try again shortly."
        }
    }
}
