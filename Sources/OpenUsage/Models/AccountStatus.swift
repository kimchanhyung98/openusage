import Foundation

/// 계정의 로컬 인증 준비 상태와 현재 실행의 사용량 확인 결과를 합친 표시 상태.
enum AccountStatus: Equatable {
    case notChecked
    case checking
    case ready
    case sessionExpired(String)
    case signInNeeded(String? = nil)
    case refreshFailed(String)

    var title: String {
        switch self {
        case .notChecked: "Not Checked"
        case .checking: "Checking"
        case .ready: "Ready"
        case .sessionExpired: "Session Expired"
        case .signInNeeded: "Sign-In Needed"
        case .refreshFailed: "Refresh Failed"
        }
    }

    var message: String? {
        switch self {
        case .sessionExpired(let message), .refreshFailed(let message): message
        case .signInNeeded(let message): message
        case .notChecked, .checking, .ready: nil
        }
    }

    var canSwitch: Bool {
        switch self {
        case .sessionExpired, .signInNeeded: false
        case .notChecked, .checking, .ready, .refreshFailed: true
        }
    }
}
