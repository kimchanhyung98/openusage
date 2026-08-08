import Foundation

/// background refresh cadence의 단일 출처
/// refresh loop와 snapshot-cache TTL이 같은 값을 읽어 불일치 불가 — cadence는 고정, 사용자 제어 없음
enum RefreshSetting {
    static let defaultMinutes = 5
    static let interval = TimeInterval(defaultMinutes * 60)
}
