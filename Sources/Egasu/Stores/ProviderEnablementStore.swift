import Foundation
import Observation

/// provider on/off의 단일 출처 — enabled-list key 존재 시 우선, legacy disabled-list는 downgrade 안전용 휴면 경로
/// known provider IDs가 enabled-list의 "부재" 중의성(의도적 off vs 미출시)을 해소
/// `NewProviderSeeder`는 known 미기록 provider만 probe — 사용자의 off 선택은 절대 override되지 않는 규칙
@MainActor
@Observable
final class ProviderEnablementStore {
    private static let disabledStorageKey = "openusage.disabledProviders.v1"
    private static let enabledStorageKey = "openusage.enabledProviders.v1"
    private static let knownStorageKey = "openusage.knownProviders.v1"

    /// enabled-provider set 실제 변경 시 게시 — refresh loop의 조기 wake 신호
    /// firehose `UserDefaults.didChangeNotification` 구독 금지 규칙 — 무관한 쓰기에 깨어나 refresh 폭주 유발
    /// `nonisolated`: 불변 `Sendable` 상수라 background task가 main actor hop 없이 참조 가능
    nonisolated static let didChangeNotification = Notification.Name("ProviderEnablementDidChange")

    /// provider가 ON으로 바뀌는 순간 호출 (disable·no-op 제외) — 실패 backoff를 지워 enablement wake의 probe 보장
    var onProviderEnabled: (@MainActor (String) -> Void)?
    /// 실제 enablement 변경 후 호출 — iCloud history가 machine document를 재작성해 stale 기여 즉시 제거
    var onChange: (@MainActor () -> Void)?

    /// legacy mode 상태 — 사용자가 끈 provider, enabled-list mode에서는 빈 set
    private(set) var disabledIDs: Set<String>
    /// enabled-list mode 상태 — `nil`이면 legacy disabled-list mode
    private(set) var enabledIDs: Set<String>?
    /// 이 설치가 본 적 있는 provider ID 전체 — v2 migration·`FirstRunSeeder` 시딩 후 `registerKnownProviders`로 성장
    private(set) var knownIDs: Set<String>
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let enabled = defaults.stringArray(forKey: Self.enabledStorageKey) {
            self.enabledIDs = Set(enabled)
            self.disabledIDs = []
        } else {
            self.enabledIDs = nil
            self.disabledIDs = Set(defaults.stringArray(forKey: Self.disabledStorageKey) ?? [])
        }
        self.knownIDs = Set(defaults.stringArray(forKey: Self.knownStorageKey) ?? [])
    }

    func isEnabled(_ id: String) -> Bool {
        if let enabledIDs { return enabledIDs.contains(id) }
        return !disabledIDs.contains(id)
    }

    func setEnabled(_ enabled: Bool, for id: String) {
        if var ids = enabledIDs {
            if enabled { ids.insert(id) } else { ids.remove(id) }
            // no-op toggle은 persist·refresh wake 없이 종료
            guard ids != enabledIDs else { return }
            enabledIDs = ids
            defaults.set(Array(ids), forKey: Self.enabledStorageKey)
        } else {
            let before = disabledIDs
            if enabled {
                disabledIDs.remove(id)
            } else {
                disabledIDs.insert(id)
            }
            guard disabledIDs != before else { return }
            defaults.set(Array(disabledIDs), forKey: Self.disabledStorageKey)
        }
        // wake 알림 전에 backoff 해제 — 트리거된 refresh가 방금 켠 provider를 recently-failed로 건너뛰지 않도록 순서 고정
        if enabled { onProviderEnabled?(id) }
        onChange?()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    /// `ids`를 seen으로 기록하고 신규분 반환 — 순수 bookkeeping, enablement 변경·알림 없음
    @discardableResult
    func registerKnownProviders(_ ids: Set<String>) -> Set<String> {
        let new = ids.subtracting(knownIDs)
        guard !new.isEmpty else { return [] }
        knownIDs.formUnion(new)
        defaults.set(Array(knownIDs), forKey: Self.knownStorageKey)
        return new
    }

    /// enabled-list mode로 전환하며 정확히 `ids`만 on — `FirstRunSeeder` 신규 설치 전용
    /// 신규 on provider마다 `onProviderEnabled` 호출 후 변경 알림 게시
    func seedEnabledProviders(_ ids: Set<String>) {
        let newlyEnabled = ids.filter { !isEnabled($0) }
        let changed = enabledIDs != ids
        enabledIDs = ids
        disabledIDs = []
        defaults.set(Array(ids), forKey: Self.enabledStorageKey)
        guard changed else { return }
        for id in newlyEnabled.sorted() { onProviderEnabled?(id) }
        onChange?()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}
