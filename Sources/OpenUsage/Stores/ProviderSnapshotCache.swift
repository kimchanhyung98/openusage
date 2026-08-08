import Foundation
import os

struct ProviderSnapshotCache {
    private struct Payload: Codable {
        var snapshots: [String: ProviderSnapshot]
        /// Card id → 저장된 snapshot을 생산한 account identity key. `ProviderSnapshot`이 local HTTP API
        /// (`LocalUsageAPI`)로 그대로 직렬화되므로 필드가 아닌 sidecar map — stamp는 cache bookkeeping,
        /// wire 데이터 아님. account identity 없는 provider(claude/codex family 외)에는 부재.
        var producedByIdentityKeys: [String: String]
    }

    /// persist blob의 in-memory mirror — 읽기마다 전 provider JSON을 MainActor에서 re-decode하던 비용 제거.
    /// 인스턴스당 최대 1회 decode(첫 접근); 쓰기는 mirror 갱신 후 persist. lock으로 value-type 공유 안전.
    private let memo = OSAllocatedUnfairLock<Payload?>(initialState: nil)

    /// 이 cache 인스턴스 생애(=이 세션)에 `store`가 쓴 provider id — freshness gate는 여기 있는 provider만
    /// 신뢰. launch에 disk에서 로드된 snapshot은 표시만 되고 fresh로 취급되지 않아 첫 pass에 refresh 강제(#697).
    private let sessionWrites = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    private let userDefaults: UserDefaults
    private let storageKey: String
    /// 세션 내에 쓴 snapshot의 fresh 유지 기간(1 refresh interval) — 이전 세션의 snapshot은 `refreshedAt`과
    /// 무관하게 non-fresh(`sessionWrites` 참고). 테스트는 고정 TTL 주입.
    private let ttl: TimeInterval
    /// timestamp-only freshness opt-in — 메뉴바 앱은 launch당 1회 refresh를 강제하지만 one-shot reader에는 세션 개념이 없음.
    private let allowsPersistedFreshness: Bool
    private let now: () -> Date
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        userDefaults: UserDefaults = .standard,
        // storage key 버전 bump는 pre-upgrade 캐시를 폐기 — schema 확장 필드를 1회 refetch로 즉시 반영.
        // v9: `producedByIdentityKeys` sidecar 추가 — account swap 후 launch가 이전 account의 캐시를 식별·폐기.
        storageKey: String = "openusage.providerSnapshots.v9",
        ttl: TimeInterval = RefreshSetting.interval,
        allowsPersistedFreshness: Bool = false,
        now: @escaping () -> Date = Date.init
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
        self.ttl = ttl
        self.allowsPersistedFreshness = allowsPersistedFreshness
        self.now = now
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// 대상 provider의 저장 snapshot 전부(만료 포함) — 표시용(stale-while-revalidate).
    /// refresh gating은 TTL 검사하는 `snapshot(providerID:)` 경유.
    func loadSnapshots(providerIDs: [String]) -> [String: ProviderSnapshot] {
        let providerIDSet = Set(providerIDs)
        let loaded = loadPayload().snapshots.filter { providerID, _ in
            providerIDSet.contains(providerID)
        }
        AppLog.debug(.cache, "loaded \(loaded.count) snapshots from disk")
        return loaded
    }

    func snapshot(providerID: String) -> ProviderSnapshot? {
        let snapshot = loadPayload().snapshots[providerID]
        guard let snapshot else { return nil }
        // freshness는 이중 조건: 이 세션에 쓰였고 AND TTL 이내 — 이전 세션 blob은 즉시 paint용일 뿐
        // refresh를 gate하지 않아 launch마다 즉시 refetch(#697).
        let writtenThisSession = sessionWrites.withLock { $0.contains(providerID) }
        let age = now().timeIntervalSince(snapshot.refreshedAt)
        let trusted = allowsPersistedFreshness || writtenThisSession
        let fresh = trusted && age < ttl
        let reason = !trusted ? "stale (not written this session)"
            : fresh ? "fresh" : "stale"
        AppLog.debug(.cache, "\(providerID) staleness \(Int(age))s vs ttl \(Int(ttl))s -> \(reason)")
        return fresh ? snapshot : nil
    }

    /// `producedByIdentityKey`는 이 snapshot을 생산한 account identity(쓰기 시점의 카드 identity) —
    /// account identity 없는 provider·identity 미해석이면 nil.
    func store(_ snapshot: ProviderSnapshot, producedByIdentityKey: String? = nil) {
        guard !snapshot.lines.contains(where: \.isError) else {
            AppLog.debug(.cache, "skip write \(snapshot.providerID) (error snapshot)")
            return
        }
        AppLog.debug(.cache, "write \(snapshot.providerID)")
        // 이 세션의 쓰기로 기록 — 이제 freshness gate 충족(launch 로드 snapshot은 불충족, `sessionWrites` 참고).
        sessionWrites.withLock { $0.insert(snapshot.providerID) }
        var payload = loadPayload()
        payload.snapshots[snapshot.providerID] = snapshot
        // entry 옆에 생산 account를 stamp(또는 clear) — nil identity는 이전 stamp를 반드시 clear.
        // 무귀속 snapshot에 이전 account의 stamp가 남으면 다음 launch의 identity 검사를 거짓 통과.
        payload.producedByIdentityKeys[snapshot.providerID] = producedByIdentityKey
        save(payload)
    }

    /// entry 저장 시 stamp된 account identity — entry 부재·무stamp면 nil. launch 필터가 account-aware
    /// 카드의 현재 identity와 비교(`WidgetDataStore.init`).
    func producedByIdentityKey(providerID: String) -> String? {
        loadPayload().producedByIdentityKeys[providerID]
    }

    /// 저장 entry를 `currentIdentityKey`로 귀속할 수 없는지 — entry 존재 + 현재 identity known + stamp 누락/타 account.
    /// 모든 read 경로(launch paint 필터·refresh cache-hit gate·one-shot CLI의 persisted-freshness 읽기)가 이를
    /// 부재로 취급해야 같은 home에서의 swap이 이전 account 데이터를 서빙하지 않음.
    /// identity 미해석(nil)이면 false — 검증 불가 entry는 stamp 도입 전과 동일하게 paint.
    func hasStaleAccountStamp(providerID: String, currentIdentityKey: String?) -> Bool {
        guard let currentIdentityKey else { return false }
        let payload = loadPayload()
        guard payload.snapshots[providerID] != nil else { return false }
        return payload.producedByIdentityKeys[providerID] != currentIdentityKey
    }

    private func loadPayload() -> Payload {
        if let mirror = memo.withLock({ $0 }) { return mirror }
        // 첫 접근에만 blob decode 후 mirror — lock 밖 decode로 @Sendable closure에서 self 제외, race는 동일 값 중복 decode에 그침(무해).
        let loaded = decodeStoredPayload()
        memo.withLock { $0 = loaded }
        return loaded
    }

    private func decodeStoredPayload() -> Payload {
        // 저장 데이터 없음은 정상 first-launch·cleared-cache — 조용히 empty 복구. 데이터가 있는데 decode 실패는
        // 실제 문제(schema drift, half-write) — 크게 log 후 empty 복구(조용한 drop은 전 provider 캐시 소실 + refresh storm).
        guard let data = userDefaults.data(forKey: storageKey) else {
            return Payload(snapshots: [:], producedByIdentityKeys: [:])
        }
        do {
            return try decoder.decode(Payload.self, from: data)
        } catch {
            AppLog.warn(.cache, "cache decode failed, dropping stored snapshots: \(error.localizedDescription)")
            return Payload(snapshots: [:], producedByIdentityKeys: [:])
        }
    }

    private func save(_ payload: Payload) {
        // mirror 먼저 갱신 — encode 실패해도 세션 내 읽기는 이 쓰기를 반영(persist만 best-effort).
        memo.withLock { $0 = payload }
        // encode 실패는 크게 log — 조용히 삼키면 snapshot이 persisted cache에서 소리 없이 빠짐.
        do {
            let data = try encoder.encode(payload)
            userDefaults.set(data, forKey: storageKey)
        } catch {
            AppLog.warn(.cache, "encode failed, snapshot not persisted: \(error.localizedDescription)")
        }
    }
}
