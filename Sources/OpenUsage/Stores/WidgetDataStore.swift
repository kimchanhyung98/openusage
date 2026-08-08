import Foundation
import Observation

/// Provider snapshot의 staleness 힌트 — `label`은 고정 단어("Outdated"), 정확한 age는 hover tooltip.
struct StalenessHint: Equatable {
    let label: String
    let tooltip: String
}

@MainActor
@Observable
final class WidgetDataStore {
    private var registry: WidgetRegistry
    private var providersByID: [String: ProviderRuntime]
    private let cache: ProviderSnapshotCache
    private let defaults: UserDefaults
    /// Provider enablement 조회 — 주입식, 기본은 전부 enabled(테스트·프리뷰용).
    private let isProviderEnabled: @MainActor (String) -> Bool
    /// 메뉴바 값을 결정하는 사용자 widget 순서(enablement 필터 적용) — 주입식, 기본은 registry 순서.
    private let orderedDescriptors: @MainActor () -> [WidgetDescriptor]
    /// failure-backoff 윈도우용 clock — 테스트에서 주입.
    private let now: () -> Date
    /// refresh 시간 측정용 monotonic clock — wall clock 조정이 timing을 왜곡하지 않도록 분리.
    private let monotonicNow: () -> TimeInterval
    private let slowProviderRefreshThreshold: TimeInterval
    /// Quota-notification 설정 — nil이면 notification 전체 비활성(테스트·프리뷰).
    private let notificationSettings: (@MainActor () -> NotificationSettingsStore)?
    /// Card id → 현재 로그인된 account identity(launch 시 `ProviderAccountAssembly`가 해석).
    /// snapshot cache의 account stamp 근거 — 쓰기는 producer를 기록, launch 로드는 stamp 일치 entry만 paint.
    private var providerIdentityKeys: [String: String]
    private var familyTotalHistoryCardIDs: Set<String>
    /// Card id → live 카드 title 리졸버(비계정 provider는 nil) — nil(테스트·one-shot CLI)이면 derived name 폴백.
    private let resolveDisplayName: (@MainActor (String) -> String?)?
    /// Milestone notification 전달 지점 — 반환 Bool은 실제 전달 여부, false면 un-marked로 남겨 다음 pass 재시도.
    private let postNotification: @MainActor (String, String, String, String) async -> Bool

    private static let meterStyleKey = "meterStyle"
    private static let resetDisplayModeKey = "resetDisplayMode"
    private static let alwaysShowPacingKey = "alwaysShowPacing"
    /// 실패한 provider의 재probe 억제 윈도우 — 실패는 캐시되지 않아 이 negative-cache만이 wake 연발의 재probe를 차단.
    /// refresh interval보다 짧아 5분 heartbeat 재시도는 유지; 수동 force refresh(⌘R)는 항상 우회.
    private static let failureRetryBackoff: TimeInterval = 60
    static let defaultSlowProviderRefreshThreshold: TimeInterval = 10

    /// 모든 UI/API 표면이 소비하는 렌더링된 snapshot — iCloud sync off면 `localSnapshots`와 동일, on이면 peer union으로 재구성.
    var snapshots: [String: ProviderSnapshot] = [:]
    /// 이 Mac이 생산한 last-good snapshot — 이것만 캐시·iCloud export되어 peer 기여의 echo 증식을 차단.
    private(set) var localSnapshots: [String: ProviderSnapshot] = [:]
    var refreshingProviderIDs: Set<String> = []
    /// 마지막 full refresh pass 종료 시각 — footer의 "Next update in …" 카운트다운 기준. 첫 pass 전에는 nil.
    var lastRefreshAt: Date?
    /// Provider별 최신 refresh 에러 — 에러 snapshot에서 설정, 다음 성공에서 해제.
    /// last-good snapshot은 계속 표시(stale-while-revalidate), dashboard는 경고 indicator만 추가.
    var providerErrors: [String: String] = [:]

    /// Provider별 실패 후 다음 probe 허용 시각(`failureRetryBackoff` 참고) — UI 상태가 아니라 observation 제외.
    @ObservationIgnored private var failureRetryAfter: [String: Date] = [:]

    /// Quota pace-notification 서브시스템의 소유자 — store는 매 pass의 enabled bounded metric 수집·위임만 담당.
    @ObservationIgnored private let notificationEvaluator = QuotaNotificationEvaluator()

    /// Telemetry hook(`AppContainer`가 연결) — 실제 fetch(.refreshed/.failed)당 1회 호출, cache-hit·skip·backoff 제외.
    /// 테스트·프리뷰에서는 nil(no-op).
    @ObservationIgnored var onRefreshOutcome: (@MainActor (String, RefreshOutcome, ErrorCategory?, Bool) -> Void)?
    /// `ICloudUsageSyncStore`가 연결 — debounce는 그쪽 담당(동시 provider batch가 파일 하나로 수렴).
    @ObservationIgnored var onLocalHistoryChanged: (@MainActor () -> Void)?
    @ObservationIgnored private var peerHistoryDocuments: [UsageHistoryDocument] = []
    /// 다른 Mac에서 sync됐지만 이곳에 카드가 없는 account — Total Spend에만 노출, 카드로는 미표시.
    private(set) var remoteOnlySpend: [(provider: Provider, snapshot: ProviderSnapshot)] = []

    /// 전역 meter 스타일("used"/"left") — persist, 기본 .used.
    var meterStyle: WidgetDisplayMode {
        didSet { defaults.set(meterStyle.rawValue, forKey: Self.meterStyleKey) }
    }

    /// 전역 reset 카운트다운 형식(relative/absolute) — persist, 기본 .absolute. reset label 클릭으로 toggle.
    var resetDisplayMode: ResetDisplayMode {
        didSet { defaults.set(resetDisplayMode.rawValue, forKey: Self.resetDisplayModeKey) }
    }

    /// 전역 "always show pacing" opt-in — on이면 on-track 행에도 pace projection 노출. persist, 기본 true.
    var alwaysShowPacing: Bool {
        didSet { defaults.set(alwaysShowPacing, forKey: Self.alwaysShowPacingKey) }
    }

    init(
        registry: WidgetRegistry,
        providers: [ProviderRuntime],
        cache: ProviderSnapshotCache = ProviderSnapshotCache(),
        defaults: UserDefaults = .standard,
        isProviderEnabled: @escaping @MainActor (String) -> Bool = { _ in true },
        orderedDescriptors: (@MainActor () -> [WidgetDescriptor])? = nil,
        now: @escaping () -> Date = Date.init,
        monotonicNow: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        slowProviderRefreshThreshold: TimeInterval = WidgetDataStore.defaultSlowProviderRefreshThreshold,
        notificationSettings: (@MainActor () -> NotificationSettingsStore)? = nil,
        postNotification: (@MainActor (String, String, String, String) async -> Bool)? = nil,
        providerIdentityKeys: [String: String] = [:],
        familyTotalHistoryCardIDs: Set<String> = [],
        resolveDisplayName: (@MainActor (String) -> String?)? = nil
    ) {
        precondition(slowProviderRefreshThreshold >= 0)
        self.registry = registry
        self.providersByID = Dictionary(uniqueKeysWithValues: providers.map { ($0.provider.id, $0) })
        self.cache = cache
        self.defaults = defaults
        self.isProviderEnabled = isProviderEnabled
        self.orderedDescriptors = orderedDescriptors ?? { registry.descriptors }
        self.now = now
        self.monotonicNow = monotonicNow
        self.slowProviderRefreshThreshold = slowProviderRefreshThreshold
        self.notificationSettings = notificationSettings
        self.postNotification = postNotification
            ?? { idPrefix, title, subtitle, body in
                await AppNotifications.shared.post(idPrefix: idPrefix, title: title, subtitle: subtitle, body: body)
            }
        self.providerIdentityKeys = providerIdentityKeys
        self.familyTotalHistoryCardIDs = familyTotalHistoryCardIDs
        self.resolveDisplayName = resolveDisplayName
        self.meterStyle = defaults.enumValue(forKey: Self.meterStyleKey, default: .used)
        self.resetDisplayMode = defaults.enumValue(forKey: Self.resetDisplayModeKey, default: .absolute)
        self.alwaysShowPacing = defaults.bool(forKey: Self.alwaysShowPacingKey, default: true)
        // Stale-while-revalidate: 만료 포함 캐시를 즉시 로드 — launch 직후 "—" 대신 last-known 값 표시.
        // Account swap guard: 현재 identity가 known인 카드는 생산 account가 일치하는 entry만 paint — 같은 home에서
        // swap 후 이전 account의 limit·plan 노출 차단. identity 미해석 카드는 검증 불가라 종전대로 캐시 유지.
        let loaded = cache.loadSnapshots(providerIDs: registry.providers.map(\.id))
            .filter { cardID, _ in
                guard cache.hasStaleAccountStamp(providerID: cardID, currentIdentityKey: providerIdentityKeys[cardID]) else {
                    return true
                }
                AppLog.info(.cache, "stale account cache discarded for \(cardID)")
                return false
            }
        self.localSnapshots = loaded
        self.snapshots = loaded
    }

    /// Enabled provider 전체를 동시 refresh — 느린 provider 하나가 나머지를 지연시키지 않는 구조.
    /// `force`는 snapshot cache 우회(수동 refresh 경로); 주기 loop는 cache를 존중.
    func refreshAll(force: Bool = false) async {
        // MainActor 격리 유지를 위해 task group 대신 provider별 Task 생성 후 일괄 await.
        let providerIDs = registry.providers.map(\.id).filter { isProviderEnabled($0) }
        let start = monotonicNow()
        AppLog.info(.refresh, "batch start (\(providerIDs.count) providers, force=\(force))")
        let tasks = providerIDs.map { providerID in
            Task { await self.refresh(providerID: providerID, force: force, notifyHistoryChange: false) }
        }
        var outcomes: [RefreshOutcome] = []
        outcomes.reserveCapacity(tasks.count)
        for task in tasks {
            outcomes.append(await task.value)
        }
        // pass 종료 시각 stamp — footer 카운트다운이 다음 예정 refresh(이 시각 + 1 interval)를 겨냥.
        lastRefreshAt = Date()
        let durationMs = durationMilliseconds(since: start)
        // 이번 batch의 실제 outcome만 집계 — 누적 providerErrors로 세면 cache hit·과거 실패가 오염.
        let refreshed = outcomes.count { $0 == .refreshed }
        let failed = outcomes.count { $0 == .failed }
        let cached = outcomes.count { $0 == .cacheHit }
        let backedOff = outcomes.count { $0 == .backedOff }
        if refreshed > 0 { onLocalHistoryChanged?() }
        AppLog.info(.refresh, "batch end (\(durationMs)ms, \(refreshed) ok / \(failed) failed / \(cached) cached / \(backedOff) backed off)")
    }

    /// Account switch 직후의 선택 카드 fetch — 주기 refresh가 카드를 점유 중이면 끝나기를 기다렸다가
    /// 사용자 요청 fetch를 실행, 다음 cadence까지 strip이 stale하게 남는 것을 방지.
    func refreshAfterAccountSelection(
        providerID: String,
        maxAttempts: Int = 45,
        retryDelay: Duration = .seconds(1)
    ) async {
        precondition(maxAttempts > 0)
        for attempt in 0..<maxAttempts {
            switch await refresh(providerID: providerID, force: true) {
            case .refreshed, .cacheHit, .backedOff, .failed:
                return
            case .skipped:
                guard attempt < maxAttempts - 1 else { break }
                AppLog.info(.refresh, "account selection waiting out an in-flight refresh for \(providerID) (attempt \(attempt + 1))")
                try? await Task.sleep(for: retryDelay)
            }
        }
        AppLog.error(.refresh, "account selection refresh kept being skipped for \(providerID); waiting for the next cycle")
    }

    /// 카탈로그 교체마다 증가 — `refresh`가 fetch 시작 시 캡처해 교체를 가로지른 결과를 폐기,
    /// 한 account에서 시작한 fetch가 이후 설치된 identity로 publish·stamp되는 일 차단.
    private var catalogGeneration = 0

    /// Settings의 account 발견 이후 catalog 교체 — store 객체는 유지되어 view·status item이
    /// 메뉴바 process 재시작 없이 새 registry를 즉시 관찰.
    func replaceProviderCatalog(
        registry: WidgetRegistry,
        providers: [ProviderRuntime],
        identityKeys: [String: String],
        familyTotalHistoryCardIDs: Set<String> = []
    ) {
        let liveIDs = Set(registry.providers.map(\.id))
        // Managed switch는 bare claude/codex 카드 id를 유지한 채 account만 교체 — 이전 identity가 생산한
        // snapshot·error·failure backoff는 이월 금지. `hasStaleAccountStamp`와 동일 규칙: 새 identity가
        // known이고 이전과 다르면 빈 상태로 시작.
        let previousIdentityKeys = providerIdentityKeys
        func keepsState(_ cardID: String) -> Bool {
            guard liveIDs.contains(cardID) else { return false }
            guard let newKey = identityKeys[cardID] else { return true }
            return previousIdentityKeys[cardID] == newKey
        }
        catalogGeneration += 1
        self.registry = registry
        self.providersByID = Dictionary(uniqueKeysWithValues: providers.map { ($0.provider.id, $0) })
        self.providerIdentityKeys = identityKeys
        self.familyTotalHistoryCardIDs = familyTotalHistoryCardIDs
        localSnapshots = localSnapshots.filter { keepsState($0.key) }
        providerErrors = providerErrors.filter { keepsState($0.key) }
        failureRetryAfter = failureRetryAfter.filter { keepsState($0.key) }

        let cached = cache.loadSnapshots(providerIDs: Array(liveIDs)).filter { cardID, _ in
            !cache.hasStaleAccountStamp(providerID: cardID, currentIdentityKey: identityKeys[cardID])
        }
        for (cardID, snapshot) in cached where localSnapshots[cardID] == nil {
            localSnapshots[cardID] = snapshot
        }
        rebuildRenderedSnapshots()
    }

    var knownProviderIDs: [String] { registry.providers.map(\.id) }
    var limitDescriptorsByProvider: [String: [WidgetDescriptor]] { registry.limitDescriptorsByProvider }

    /// 표시 중인 enabled bounded metric의 quota pace milestone 평가·notification 발송 — `refreshAll` 이후
    /// 주기 loop에서 구동해 시간 경과만으로 악화된 pace도 포착. 이번 pass에 방문하지 않은 metric의
    /// 상태는 prune — 재활성화·재추가 시 stale "already fired" flag 없이 fresh 시작.
    func evaluateNotifications(now: Date = Date()) async {
        guard let settingsProvider = notificationSettings else { return }
        let toggles = settingsProvider().toggles
        // unbounded 행·chart는 pace 대상이 아니라 제외; 순서는 layout 순서, evaluator가 미방문 상태를 prune.
        // pass 입력은 첫 delivery await 이전에 고정 — mid-pass refresh가 이후 metric의 입력을 바꾸지 않음.
        let metrics = orderedDescriptors()
            .filter { isProviderEnabled($0.providerID) }
            .compactMap { descriptor -> QuotaNotificationEvaluator.Metric? in
                let data = data(for: descriptor)
                guard data.isBounded else { return nil }
                return QuotaNotificationEvaluator.Metric(
                    key: "\(descriptor.providerID).\(descriptor.id)",
                    providerID: descriptor.providerID,
                    data: data
                )
            }
        await notificationEvaluator.evaluate(
            metrics: metrics,
            toggles: toggles,
            now: now,
            providerName: { [providersByID, resolveDisplayName] id in
                resolveDisplayName?(id) ?? providersByID[id]?.provider.displayName ?? id
            },
            post: postNotification
        )
    }

    /// 한 provider의 refresh가 이번 pass에서 실제 수행한 일 — batch 요약의 근거. `.backedOff`는
    /// backoff로 의도적으로 건너뛴 probe(disabled/unknown/in-flight의 `.skipped`와 구분).
    enum RefreshOutcome: Sendable { case refreshed, failed, cacheHit, skipped, backedOff }

    @discardableResult
    func refresh(
        providerID: String,
        force: Bool = false,
        notifyHistoryChange: Bool = true
    ) async -> RefreshOutcome {
        guard isProviderEnabled(providerID) else { return .skipped }
        // TTL-fresh라도 다른 account 소유가 증명된 entry는 refresh를 short-circuit하면 안 됨 —
        // miss로 취급해 fetch가 덮어쓰도록 처리(persisted freshness의 one-shot CLI에서 특히 위험).
        let staleAccountStamp = cache.hasStaleAccountStamp(
            providerID: providerID,
            currentIdentityKey: providerIdentityKeys[providerID]
        )
        if !force, !staleAccountStamp, let cached = cache.snapshot(providerID: providerID) {
            // no-op write 회피 — @Observable은 값 비교를 하지 않아 재할당만으로 메뉴바 label 재렌더 발생.
            AppLog.debug(.refresh, "cache hit \(providerID)")
            if localSnapshots[providerID] != cached {
                localSnapshots[providerID] = cached
                rebuildRenderedSnapshots()
            }
            return .cacheHit
        }
        if !force { AppLog.debug(.refresh, "cache miss \(providerID)") }

        // 실패는 캐시되지 않아 backoff 만료까지 재probe 보류; 수동 force refresh는 backoff 무시.
        if !force, let retryAfter = failureRetryAfter[providerID], now() < retryAfter {
            AppLog.debug(.refresh, "backoff skip \(providerID) (failed <\(Int(Self.failureRetryBackoff))s ago)")
            return .backedOff
        }

        guard let provider = providersByID[providerID] else { return .skipped }
        // in-flight refresh가 이미 소유 중이면 skip — 동일 provider 중복 network call 방지.
        guard !refreshingProviderIDs.contains(providerID) else {
            AppLog.debug(.refresh, "cache skip \(providerID) (already in flight)")
            return .skipped
        }
        refreshingProviderIDs.insert(providerID)
        defer { refreshingProviderIDs.remove(providerID) }
        let boundGeneration = catalogGeneration
        let start = monotonicNow()
        var snapshot = await ProviderRefreshContext.$isManual.withValue(force) {
            await provider.refresh()
        }
        // 취소된 refresh도 non-throwing 작업이면 결과 반환 가능 — partial snapshot publish 금지, last-good 유지.
        guard !Task.isCancelled else {
            AppLog.debug(.refresh, "cancelled \(providerID) refresh; keeping last-good snapshot")
            return .skipped
        }
        // fetch 중 catalog 교체: 카드 id가 다른 account를 가리킬 수 있어 결과 폐기 — publish하면 이전
        // account 데이터가 새 identity stamp로 정당화됨. switch 경로가 선택 카드를 직접 force-refresh.
        guard catalogGeneration == boundGeneration else {
            AppLog.info(.refresh, "\(providerID) discarding result: the provider catalog changed mid-fetch")
            return .skipped
        }
        let durationMs = durationMilliseconds(since: start)
        if TimeInterval(durationMs) >= slowProviderRefreshThreshold * 1000 {
            AppLog.warn(
                .refresh,
                "\(providerID) slow refresh (\(durationMs)ms, threshold=\(Int(slowProviderRefreshThreshold * 1000))ms)"
            )
        }
        if let message = Self.errorMessage(in: snapshot) {
            // 실패 시 에러만 노출하고 last-good snapshot 유지 — 전 행 "No data" 붕괴 방지.
            providerErrors[providerID] = message
            // 실패 negative-cache — wake 연발의 tight-loop 재probe 차단.
            failureRetryAfter[providerID] = now().addingTimeInterval(Self.failureRetryBackoff)
            AppLog.warn(.refresh, "\(providerID) failed: \(message)")
            onRefreshOutcome?(providerID, .failed, snapshot.errorCategory, force)
            return .failed
        }
        if providerErrors[providerID] != nil {
            providerErrors[providerID] = nil
        }
        // 회복 시 backoff 해제 — 즉시 정상 cadence 복귀.
        failureRetryAfter[providerID] = nil
        // live limit refresh 성공 + local log/CSV scan 무결과이면 last-good normalized history만 보존(새 plan·
        // limit·warning·timestamp는 반영). non-nil 빈 history는 scan 완료의 증거라 authoritative — 기존 행 삭제.
        if snapshot.usageHistory == nil,
           let history = localSnapshots[providerID]?.usageHistory,
           let descriptor = registry.historyDescriptorsByProvider[providerID]
        {
            snapshot.usageHistory = history
            snapshot = UsageHistorySnapshotRenderer.render(
                local: snapshot,
                history: history,
                descriptor: descriptor,
                now: now(),
                combined: false
            )
            AppLog.debug(.refresh, "preserved last-good history for \(providerID) after scan miss")
        }
        localSnapshots[providerID] = snapshot
        // launch에 해석된 account identity로 write를 stamp — 비계정 provider·identity 미해석 카드는 nil(no stamp).
        cache.store(snapshot, producedByIdentityKey: providerIdentityKeys[providerID])
        rebuildRenderedSnapshots()
        if notifyHistoryChange { onLocalHistoryChanged?() }
        AppLog.info(.refresh, "\(providerID) ok (\(durationMs)ms)")
        onRefreshOutcome?(providerID, .refreshed, nil, force)
        return .refreshed
    }

    private func durationMilliseconds(since start: TimeInterval) -> Int {
        max(0, Int((monotonicNow() - start) * 1000))
    }

    /// 실패 backoff 해제 — provider 재활성화라는 사용자 action만 호출(주기 loop는 호출 금지),
    /// enablement wake의 즉시 fetch가 꺼지기 직전 실패의 stale backoff에 막히지 않도록 보장.
    func clearFailureBackoff(for providerID: String) {
        failureRetryAfter[providerID] = nil
    }

    /// Provider toggle 직후 in-memory union 재구성 — disabled provider는 peer 기여 수신 중단, local 캐시는 직접 API 읽기에 유지.
    func providerEnablementDidChange() {
        rebuildRenderedSnapshots()
    }

    /// 다운로드한 peer set 교체 — device별 최신 유효 문서만 남기고 이 Mac의 자체 사본은 현재 메모리 우선으로 제외.
    func setPeerHistoryDocuments(_ documents: [UsageHistoryDocument], ownDeviceID: String) {
        peerHistoryDocuments = UsageHistoryDocument.newestByDevice(documents)
            .filter { $0.deviceID != ownDeviceID }
        rebuildRenderedSnapshots()
    }

    func clearPeerHistoryDocuments() {
        guard !peerHistoryDocuments.isEmpty else { return }
        peerHistoryDocuments = []
        rebuildRenderedSnapshots()
    }

    func localHistoryDocument(deviceID: String, deviceName: String, updatedAt: Date = Date()) -> UsageHistoryDocument {
        var providers: [String: ProviderUsageHistory] = [:]
        var identities: [String: String] = [:]
        // machine-local 카드는 account 카드 포함 전부 sync — id가 identity 파생이라 모든 Mac에서 같은 account를
        // 의미. identities map은 peer가 default 카드의 history를 그쪽 카드에 매칭하는 근거(`PeerHistoryRemapper`).
        for (providerID, descriptor) in registry.historyDescriptorsByProvider
        where descriptor.scope == .machineLocal && isProviderEnabled(providerID) {
            if let history = localSnapshots[providerID]?.usageHistory {
                providers[providerID] = history
                // managed shared-home history는 switch된 모든 account의 session이 섞인 family 합계 — 선택 profile의
                // identity 없이 sync. stamp를 찍으면 peer가 합계 전체를 현재 선택 account로 재귀속.
                if let identity = providerIdentityKeys[providerID],
                   !familyTotalHistoryCardIDs.contains(providerID) {
                    identities[providerID] = identity
                }
            }
        }
        return UsageHistoryDocument(
            deviceID: deviceID,
            deviceName: deviceName,
            updatedAt: updatedAt,
            providers: providers,
            identities: identities.isEmpty ? nil : identities
        )
    }

    private func rebuildRenderedSnapshots() {
        guard !peerHistoryDocuments.isEmpty else {
            snapshots = localSnapshots
            remoteOnlySpend = []
            return
        }
        let renderDate = now()
        let enabledDescriptors = registry.historyDescriptorsByProvider.reduce(
            into: [String: UsageHistoryDescriptor]()
        ) { result, entry in
            if isProviderEnabled(entry.key) { result[entry.key] = entry.value }
        }
        // peer 매칭은 card id가 아닌 account identity 기준 — 같은 account가 Mac마다 다른 카드일 수 있음.
        // local 카드와 무매칭이면 아래에서 Total Spend 전용 remote entry로 처리.
        let remapped = PeerHistoryRemapper.remap(
            documents: peerHistoryDocuments,
            localIdentityByCardID: providerIdentityKeys
        )
        let merged = UsageHistoryAggregator.merged(
            localSnapshots: localSnapshots,
            peerHistories: remapped.histories,
            descriptors: enabledDescriptors,
            now: renderDate
        )
        remoteOnlySpend = Self.renderRemoteOnlySpend(
            remapped.remoteOnly,
            registry: registry,
            now: renderDate
        )
        var rendered = localSnapshots
        for (providerID, history) in merged {
            guard let descriptor = registry.historyDescriptorsByProvider[providerID],
                  let provider = registry.provider(id: providerID)
            else { continue }
            let local = localSnapshots[providerID] ?? ProviderSnapshot(
                providerID: providerID,
                displayName: provider.displayName,
                lines: [],
                refreshedAt: peerHistoryDocuments.map(\.updatedAt).max() ?? renderDate
            )
            rendered[providerID] = UsageHistorySnapshotRenderer.render(
                local: local,
                history: history,
                descriptor: descriptor,
                now: renderDate
            )
        }
        snapshots = rendered
    }

    /// 다른 Mac에만 있는 account의 Total Spend entry 합성 — pseudo provider(family icon, "Claude · Mac mini")
    /// + 실제 카드와 같은 renderer로 그린 표준 spend-tile line snapshot.
    private static func renderRemoteOnlySpend(
        _ remoteOnly: [PeerHistoryRemapper.RemoteOnlyHistory],
        registry: WidgetRegistry,
        now: Date
    ) -> [(provider: Provider, snapshot: ProviderSnapshot)] {
        remoteOnly.compactMap { entry in
            guard let familyProvider = registry.provider(id: entry.family),
                  let descriptor = registry.historyDescriptorsByProvider[entry.family]
            else { return nil }
            let history = UsageHistoryAggregator.mergeHistories(entry.histories, now: now)
            guard !history.series.daily.isEmpty else { return nil }

            // slice 이름은 identity 파생 card id("claude@ab12cd34") — account별 유일, 그 account가 여기 로그인하면
            // 받을 id와 동일. pseudo provider id는 실제 card id와 충돌하지 않도록 별도 형식 유지.
            let provider = Provider(
                id: "\(entry.family)@peer-\(ProviderAccountID.hash8(entry.identityKey))",
                displayName: entry.cardID,
                icon: familyProvider.icon
            )
            let empty = ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [],
                refreshedAt: now
            )
            let snapshot = UsageHistorySnapshotRenderer.render(
                local: empty,
                history: history,
                descriptor: descriptor,
                now: now
            )
            return (provider, snapshot)
        }
    }

    func errorMessage(for providerID: String) -> String? {
        providerErrors[providerID]
    }

    /// 최신 *성공* snapshot의 soft warning(예: Claude "Re-login for live usage") — 실패 후에도 last-good이
    /// 유지돼 남을 수 있음; 렌더링되는 triangle은 hard error가 우선하는 `headerNotice(for:)` 사용.
    func warningMessage(for providerID: String) -> String? {
        snapshots[providerID]?.warning
    }

    /// Provider header의 amber-triangle notice — 현재 hard refresh error가 stale soft warning에 우선
    /// (에러가 밀리면 stale warning이 실제 실패를 가림). 에러 없으면 soft warning 표시.
    func headerNotice(for providerID: String) -> String? {
        errorMessage(for: providerID) ?? warningMessage(for: providerID)
    }

    /// 에러 line만 있는 snapshot은 실패한 refresh — 메시지는 badge에서 추출.
    private static func errorMessage(in snapshot: ProviderSnapshot) -> String? {
        guard !snapshot.lines.isEmpty, snapshot.lines.allSatisfy(\.isError) else { return nil }
        if case .badge(_, let text, _, _) = snapshot.lines[0] { return text }
        return "Refresh failed"
    }

    func data(for descriptor: WidgetDescriptor) -> WidgetData {
        var result: WidgetData
        if let snapshot = snapshots[descriptor.providerID],
           let line = snapshot.line(label: descriptor.metricLabel),
           let data = resolve(line, descriptor: descriptor) {
            result = data
        } else {
            // 배치된 tile을 뒷받침하는 실제 metric line 부재 — sample 숫자는 placeholder이므로 no-data 처리.
            result = descriptor.sample
            result.hasData = false
        }

        // 전역 단일 choke point — dashboard/share 행과 메뉴바 값이 모두 여기를 거치므로 mode를 한 번만 stamp.
        result.displayMode = meterStyle
        result.resetDisplayMode = resetDisplayMode
        result.alwaysShowPacing = alwaysShowPacing
        // 행 자신의 카드 identity — per-card action(Codex reset-claim router)의 키.
        result.providerID = descriptor.providerID
        return result
    }

    /// 최신 snapshot의 plan label — snapshot 없음·plan 미노출이면 nil. provider section header가 표시.
    func plan(for providerID: String) -> String? {
        snapshots[providerID]?.plan
    }

    /// 표시 중 snapshot의 staleness 판정 경계 — 2 interval. 정상 per-cycle aging에는 미발화(flicker 방지),
    /// refresh가 실제로 누락됐을 때(계속 실패하는 loop, 장기 suspend된 timer)만 발화.
    static let stalenessThreshold = RefreshSetting.interval * 2

    /// snapshot이 `stalenessThreshold`를 넘겼을 때의 "Outdated" 힌트 — 데이터가 현재이면 nil.
    /// 실패 loop가 last-good plan/limit을 계속 표시하는 fossilized-cache(#582)의 가시화 장치;
    /// label은 header overflow 방지를 위해 짧게, 정확한 age는 tooltip에. 주입된 clock 사용(테스트 고정).
    func stalenessHint(for providerID: String) -> StalenessHint? {
        guard let refreshedAt = snapshots[providerID]?.refreshedAt else { return nil }
        let age = now().timeIntervalSince(refreshedAt)
        guard age >= Self.stalenessThreshold, let duration = Formatters.compactDuration(age) else {
            return nil
        }
        return StalenessHint(label: "Outdated", tooltip: "Last updated \(duration) ago")
    }

    private func resolve(_ line: MetricLine, descriptor: WidgetDescriptor) -> WidgetData? {
        switch line {
        case .progress(_, let used, let limit, let format, let resetsAt, let periodDurationMs, _):
            // percent meter는 0...100 bounded — 모든 provider가 거치는 단일 구성 choke point에서 clamp,
            // 어떤 표면도 "-5%"/"105%"를 렌더하지 않음. 비percent는 raw 유지 — 실제 overage는 spent state로 전달.
            let normalizedUsed = format == .percent ? ProviderParse.clampPercent(used) : used
            var result = WidgetData(
                title: descriptor.sample.title,
                icon: descriptor.sample.icon,
                kind: format.metricKind,
                used: normalizedUsed,
                limit: limit,
                countSuffix: format.countSuffix,
                valuePrefix: descriptor.sample.valuePrefix,
                resetsAt: resetsAt,
                periodDurationMs: periodDurationMs,
                limitNoun: descriptor.sample.limitNoun,
                infoNote: descriptor.sample.infoNote
            )
            // descriptor opt-in flag(session-window meter의 "Not started") — `.progress` 결과는 sample에서 시작하지 않으므로 명시적으로 carry.
            result.isSessionWindow = descriptor.sample.isSessionWindow
            return result
        case .text:
            // text line은 local API용 provider notice — 숫자 widget은 typed line만 소비, display text parse 금지.
            return nil
        case .values(_, let values, _, let expiriesAt, let unknownModels, let modelBreakdown):
            // 숫자는 raw로 carry(regex re-parse 없음) — presentation은 sample, live 값은 line.
            var data = descriptor.sample
            data.values = values
            // `.values` line은 정의상 unbounded — descriptor template의 placeholder limit이 있어도 meter로 렌더하지 않음.
            data.limit = nil
            // 만료 시각(Codex reset-credit) — row hover tooltip에 노출, clock tick마다 재렌더로 live 유지.
            data.expiriesAt = expiriesAt
            // 미가격 model 목록(Cursor spend tile) — label 경고 triangle과 hover 목록 구동.
            data.unknownModels = unknownModels
            data.modelBreakdown = modelBreakdown
            // selection에 값이 없는 tile은 "No data" 렌더 — 오해 소지의 $0.00 / 0 방지.
            data.hasData = !data.selectedValues.isEmpty
            // ⓘ는 data-driven — 표시 값이 로컬 추정(estimated)일 때만 estimate note, 실측 값은 clean.
            data.infoNote = data.selectedValues.contains(where: \.estimated)
                ? WidgetData.localEstimateNote
                : descriptor.sample.infoNote
            return data
        case .badge(_, let text, _, let subtitle):
            var data = descriptor.sample
            data.valueTextOverride = text
            data.subtitleOverride = subtitle
            return data
        case .chart(_, let points, let note):
            // point 없음은 "source를 읽었지만 사용 가능한 day 없음" — 빈 축 대신 "No data" 렌더.
            var data = descriptor.sample
            data.isChart = true
            data.chartPoints = points
            data.chartNote = note
            data.hasData = !points.isEmpty
            return data
        }
    }

}
