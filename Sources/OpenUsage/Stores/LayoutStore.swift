import SwiftUI
import Observation

/// Mutable 레이아웃 상태 — enabled widget 집합(`placed`), provider 순서, provider별 custom metric 순서.
@MainActor
@Observable
final class LayoutStore {
    // Swift의 private은 file-scope — `LayoutStore+Customization.swift`와 공유하는 멤버는 module-internal 유지.
    var placed: [PlacedWidget]

    /// In-popover navigation 전담 store — 아래 forwarding 표면이 유일한 접근 경로(같은 상태로 가는 두 경로 방지).
    private let navigation = PopoverNavigationStore()

    /// 현재 표시 중인 in-popover screen — footer 버튼·Esc handler·popover-close reset 공용.
    var screen: PopoverScreen {
        get { navigation.screen }
        set { navigation.screen = newValue }
    }
    /// DashboardView 수평 slide용 — 떠나는 screen과 per-switch counter.
    var screenSlideFrom: PopoverScreen { navigation.screenSlideFrom }
    var screenSlideID: Int { navigation.screenSlideID }
    var isEditing: Bool {
        get { navigation.isEditing }
        set { navigation.isEditing = newValue }
    }
    var customizeProviderID: String? {
        get { navigation.customizeProviderID }
        set { navigation.customizeProviderID = newValue }
    }
    var draggingID: UUID?
    /// Persist되는 provider 표시 순서(provider id) — dashboard group과 Customize section 공용.
    var providerOrder: [String]
    /// Persist되는 provider별 metric 순서 — toggle이 이를 바꾸지 않아 on/off로 행이 이동하지 않음.
    var metricOrderByProvider: [String: [String]]

    /// 메뉴바 pin된 descriptor id — membership만 저장, 표시 순서는 provider+metric 순서에서 파생.
    /// `canPin`으로 provider당 최대 `maxPinsPerProvider`개 제한(strip이 값을 pair로 쌓는 구조).
    private(set) var pinnedMetricIDs: Set<String>

    /// per-provider "Shown on expand" divider 아래의 descriptor id — membership만 저장, section 내 순서는
    /// metric 순서를 따름. disabled 동안에도 membership 유지 — 재활성화 시 원래 section 복원.
    var expandedMetricIDs: Set<String>

    /// expanded metric을 펼쳐 둔 provider — 사용자 preference라 popover 닫힘·앱 재시작에도 유지.
    private(set) var expandedProviderIDs: Set<String>

    private let pinNotice = TransientNotice<String?>(clearedValue: nil, timeout: .seconds(3))
    private let shareNotice = TransientNotice<Bool>(clearedValue: false, timeout: .seconds(2.5))
    private let customizeNotice = TransientNotice<CustomizationNoticeContent?>(clearedValue: nil, timeout: .seconds(2.5))

    var pinLimitNotice: String? { pinNotice.value }
    var pinNoticeShakeTrigger: Int { pinNotice.trigger }

    var shareConfirmation: Bool { shareNotice.value }
    var shareConfirmationTrigger: Int { shareNotice.trigger }

    var customizationNotice: String? { customizeNotice.value?.message }
    /// notice tone(.positive/.notice) — clear 후 .positive 폴백(메시지·tone이 원자적으로 clear되어 snap-back 비관측).
    var customizationNoticeTone: CustomizationNoticeTone { customizeNotice.value?.tone ?? .positive }
    var customizationNoticeTrigger: Int { customizeNotice.trigger }

    /// 레이아웃 customization용 bounded 앱 전역 undo stack — 비persist(세션 내 affordance),
    /// entry는 변경 전 `LayoutSnapshot`, `undo()`가 pop·복원.
    private var undoHistory = LayoutUndoHistory()
    /// `undo()` replay 중 flag — replay가 유발한 mutation의 stack 재기록 차단(undo는 새 undoable action이 아님).
    private var isApplyingUndo = false

    /// 메뉴바 표시 스타일(Text strip/Bars) — persist, 기본 .bars.
    var menuBarStyle: MenuBarStyle {
        didSet { persistence.saveMenuBarStyle(menuBarStyle) }
    }

    private(set) var registry: WidgetRegistry
    private let persistence: LayoutPersistence
    private let baseDefaultMetricIDs: [String]
    private let migrationBaselineMetricIDs: [String]
    private let baseDefaultExpandedMetricIDs: [String]
    private var defaultMetricIDs: [String]
    private let defaultPinnedMetricIDs: [String]
    private var defaultExpandedMetricIDs: [String]
    var defaultExpandedOnEnableIDs: Set<String>
    let isProviderEnabled: @MainActor (String) -> Bool

    init(
        registry: WidgetRegistry,
        defaults: UserDefaults = .standard,
        storageKey: String = "openusage.layout.v1",
        defaultMetricIDs: [String] = DefaultLayout.metricIDs,
        migrationBaselineMetricIDs: [String] = DefaultLayout.migrationBaselineMetricIDs,
        defaultPinnedMetricIDs: [String] = DefaultLayout.pinnedMetricIDs,
        defaultExpandedMetricIDs: [String] = DefaultLayout.expandedMetricIDs,
        isProviderEnabled: @escaping @MainActor (String) -> Bool = { _ in true }
    ) {
        self.registry = registry
        let persistence = LayoutPersistence(defaults: defaults, storageKey: storageKey)
        self.persistence = persistence
        // extra account 카드는 family의 default metric set(과 caret split)을 seed — pin과 migration
        // baseline은 의도적으로 미번역(`translatedForAccountCards` 참고).
        self.baseDefaultMetricIDs = defaultMetricIDs
        self.migrationBaselineMetricIDs = migrationBaselineMetricIDs
        self.baseDefaultExpandedMetricIDs = defaultExpandedMetricIDs
        let registryProviderIDs = registry.providers.map(\.id)
        let translatedMetricIDs = DefaultLayout.translatedForAccountCards(defaultMetricIDs, providerIDs: registryProviderIDs)
        let translatedExpandedIDs = DefaultLayout.translatedForAccountCards(defaultExpandedMetricIDs, providerIDs: registryProviderIDs)
        self.defaultMetricIDs = translatedMetricIDs
        self.defaultPinnedMetricIDs = defaultPinnedMetricIDs
        self.defaultExpandedMetricIDs = translatedExpandedIDs
        self.isProviderEnabled = isProviderEnabled

        let initial = LayoutBootstrap.load(
            registry: registry,
            persistence: persistence,
            defaults: LayoutDefaultSet(
                metricIDs: translatedMetricIDs,
                migrationBaselineMetricIDs: migrationBaselineMetricIDs,
                pinnedMetricIDs: defaultPinnedMetricIDs,
                expandedMetricIDs: translatedExpandedIDs
            )
        )
        placed = initial.placed
        providerOrder = initial.providerOrder
        metricOrderByProvider = initial.metricOrderByProvider
        pinnedMetricIDs = initial.pinnedMetricIDs
        expandedMetricIDs = initial.expandedMetricIDs
        expandedProviderIDs = initial.expandedProviderIDs
        defaultExpandedOnEnableIDs = initial.defaultExpandedOnEnableIDs
        menuBarStyle = initial.menuBarStyle

        if initial.shouldPersistExpandOnEnable { persistExpandOnEnable() }
        if initial.shouldPersistExpanded { persistExpanded() }
        if let seededDefaults = initial.seededDefaultsToPersist { persistSeededDefaults(seededDefaults) }
        syncPlacedOrder(persistChanges: initial.shouldPersistPlaced)
    }

    /// 새로 발견된 account 카드를 기존 레이아웃에 reconcile — launch와 같은 bootstrap 경로로 재로드해
    /// 저장된 선택은 보존하고 새 account의 family default만 seed; store 객체는 유지되어 popover 연결 지속.
    func replaceRegistry(_ registry: WidgetRegistry) {
        guard registry.providers != self.registry.providers || registry.descriptors != self.registry.descriptors else {
            return
        }
        self.registry = registry
        let providerIDs = registry.providers.map(\.id)
        let translatedMetricIDs = DefaultLayout.translatedForAccountCards(
            baseDefaultMetricIDs,
            providerIDs: providerIDs
        )
        let translatedExpandedIDs = DefaultLayout.translatedForAccountCards(
            baseDefaultExpandedMetricIDs,
            providerIDs: providerIDs
        )
        defaultMetricIDs = translatedMetricIDs
        defaultExpandedMetricIDs = translatedExpandedIDs

        let reloaded = LayoutBootstrap.load(
            registry: registry,
            persistence: persistence,
            defaults: LayoutDefaultSet(
                metricIDs: translatedMetricIDs,
                migrationBaselineMetricIDs: migrationBaselineMetricIDs,
                pinnedMetricIDs: defaultPinnedMetricIDs,
                expandedMetricIDs: translatedExpandedIDs
            )
        )
        placed = reloaded.placed
        providerOrder = reloaded.providerOrder
        metricOrderByProvider = reloaded.metricOrderByProvider
        pinnedMetricIDs = reloaded.pinnedMetricIDs
        expandedMetricIDs = reloaded.expandedMetricIDs
        expandedProviderIDs = reloaded.expandedProviderIDs
        defaultExpandedOnEnableIDs = reloaded.defaultExpandedOnEnableIDs
        menuBarStyle = reloaded.menuBarStyle
        undoHistory.clear()
        cancelDrag()

        if reloaded.shouldPersistExpandOnEnable { persistExpandOnEnable() }
        if reloaded.shouldPersistExpanded { persistExpanded() }
        if let seededDefaults = reloaded.seededDefaultsToPersist { persistSeededDefaults(seededDefaults) }
        syncPlacedOrder(persistChanges: reloaded.shouldPersistPlaced)
    }

    func isProviderExpanded(_ providerID: String) -> Bool {
        registry.provider(id: providerID) != nil && expandedProviderIDs.contains(providerID)
    }

    @discardableResult
    func setProviderExpanded(_ expanded: Bool, for providerID: String) -> Bool {
        guard registry.provider(id: providerID) != nil else { return false }
        guard expandedProviderIDs.contains(providerID) != expanded else { return false }
        if expanded {
            expandedProviderIDs.insert(providerID)
        } else {
            expandedProviderIDs.remove(providerID)
        }
        persistExpandedProviders()
        return true
    }

    // MARK: - Customize mutations

    /// metric on/off toggle — Customize 스위치가 구동하는 단일 seam, 앱의 add/remove 경로와 공유.
    func setMetricEnabled(_ descriptorID: String, _ enabled: Bool) {
        recordingUndoStep {
            if enabled {
                if defaultExpandedOnEnableIDs.remove(descriptorID) != nil {
                    expandedMetricIDs.insert(descriptorID)
                    persistExpanded()
                    persistExpandOnEnable()
                }
                add(descriptorID)
            } else if let widget = placed.first(where: { $0.descriptorID == descriptorID }) {
                remove(widget.id)
            }
        }
    }

    // MARK: - Undo

    /// undo 가능 여부 — Customize Undo 버튼 표시와 앱 전역 ⌘Z handler의 no-op guard 구동.
    var canUndo: Bool { undoHistory.canUndo }

    private func currentSnapshot() -> LayoutSnapshot {
        LayoutSnapshot(
            placed: placed,
            providerOrder: providerOrder,
            metricOrderByProvider: metricOrderByProvider,
            pinnedMetricIDs: pinnedMetricIDs,
            expandedMetricIDs: expandedMetricIDs,
            defaultExpandedOnEnableIDs: defaultExpandedOnEnableIDs
        )
    }

    /// 사용자 레이아웃 mutation을 undo step 1개로 기록하며 실행 — 실제 변경이 있을 때만 사전 snapshot을
    /// push(no-op action은 빈 step 미기록). 재진입 호출과 undo replay는 `isApplyingUndo`로 외부 단일 step에 coalesce.
    func recordingUndoStep<T>(_ body: () -> T) -> T {
        // 이미 undoable scope 내부(또는 undo replay 중) — 바깥 scope가 단일 step을 소유, undo는 자신을 기록하지 않음.
        guard !isApplyingUndo else { return body() }
        let before = currentSnapshot()
        isApplyingUndo = true
        defer { isApplyingUndo = false }
        let result = body()
        if currentSnapshot() != before {
            undoHistory.record(before)
        }
        return result
    }

    /// 최근 customization step 롤백 — 없으면 false. 반복 호출로 계속 후퇴; 앱 전역에서 사용 가능.
    @discardableResult
    func undo() -> Bool {
        guard let snapshot = undoHistory.popLast() else { return false }
        isApplyingUndo = true
        defer { isApplyingUndo = false }
        restore(snapshot)
        return true
    }

    /// snapshot의 undoable 필드 전체 복원·persist — `undo()`가 호출. `expandedProviderIDs`는 transient
    /// view 상태라 의도적으로 제외(step 사이의 caret toggle은 rewind하지 않음).
    private func restore(_ snapshot: LayoutSnapshot) {
        cancelDrag()
        placed = snapshot.placed
        providerOrder = snapshot.providerOrder
        metricOrderByProvider = snapshot.metricOrderByProvider
        pinnedMetricIDs = snapshot.pinnedMetricIDs
        expandedMetricIDs = snapshot.expandedMetricIDs
        defaultExpandedOnEnableIDs = snapshot.defaultExpandedOnEnableIDs
        persist()
        persistProviderOrder()
        persistMetricOrder()
        persistPins()
        persistExpanded()
        persistExpandOnEnable()
    }

    // MARK: - Menu bar pins

    /// provider별 pin 상한 — Text strip이 provider 값을 2개씩 한 column에 쌓는 렌더링 제약.
    static let maxPinsPerProvider = 2

    func isPinned(_ descriptorID: String) -> Bool {
        registry.descriptor(id: descriptorID) != nil && pinnedMetricIDs.contains(descriptorID)
    }

    func pinnedCount(forProvider providerID: String) -> Int {
        pinnedMetricIDs.count { registry.descriptor(id: $0)?.providerID == providerID }
    }

    /// cap을 깨지 않고 새로 pin 가능한지 — 이미 pin된 id는 true(unpin toggle 유지).
    func canPin(_ descriptorID: String) -> Bool {
        if pinnedMetricIDs.contains(descriptorID) { return true }
        guard let descriptor = registry.descriptor(id: descriptorID), descriptor.pinnable else { return false }
        if pinnedCount(forProvider: descriptor.providerID) >= Self.maxPinsPerProvider { return false }
        return true
    }

    /// 지금 pin 불가한 사유(가능하면 nil) — pin 버튼 tooltip과 거부 클릭 피드백의 단일 source.
    func pinDenialReason(_ descriptorID: String) -> String? {
        guard !canPin(descriptorID) else { return nil }
        if let providerID = registry.descriptor(id: descriptorID)?.providerID,
           pinnedCount(forProvider: providerID) >= Self.maxPinsPerProvider {
            return "Up to \(Self.maxPinsPerProvider) stars per provider"
        }
        return nil
    }

    /// 거부된 pin 시도 기록 — footer가 cap을 설명(수 초 표시 + 매 시도 deny shake).
    func notePinDenied(_ descriptorID: String) {
        guard let reason = pinDenialReason(descriptorID) else { return }
        pinNotice.present(reason)
    }

    /// "Share Screenshot" copy 성공 기록 — floating "Copied to clipboard" pill 표시.
    /// `notePinDenied`의 성공측 대응, 동일 lifecycle.
    func presentShareConfirmation() {
        shareNotice.present(true)
    }

    /// 표시 중인 확인 pill 해제·auto-clear task 취소 — popover 닫힘 시 호출, layout store가 popover보다
    /// 오래 살아 다음 open에 카운트다운 중이던 pill이 stale 재등장하는 것 방지.
    func clearShareConfirmation() {
        shareNotice.clear()
    }

    /// transient in-Customize pill 표시 — `tone`은 green success/orange denial 스타일 선택.
    /// 수 초 후 auto-clear; popover 닫힘 시에는 `clearCustomizationNotice`로 clear.
    func presentCustomizationNotice(_ message: String, tone: CustomizationNoticeTone = .positive) {
        customizeNotice.present(CustomizationNoticeContent(message: message, tone: tone))
    }

    /// 표시 중인 Customize pill 해제·auto-clear task 취소 — 다음 open에 stale 재등장 방지.
    func clearCustomizationNotice() {
        customizeNotice.clear()
    }

    /// 메뉴바 pin/unpin — cap 초과 pin은 no-op이라 `canPin`으로 gate한 호출자는 over-pin 불가.
    /// 다른 레이아웃 action처럼 undoable — no-op guard 덕에 거부·중복 pin은 step 미기록.
    func setPinned(_ pinned: Bool, for descriptorID: String) {
        recordingUndoStep {
            if pinned {
                guard canPin(descriptorID), registry.descriptor(id: descriptorID) != nil else { return }
                guard pinnedMetricIDs.insert(descriptorID).inserted else { return }
            } else {
                guard pinnedMetricIDs.remove(descriptorID) != nil else { return }
            }
            persistPins()
        }
    }

    func togglePin(_ descriptorID: String) {
        setPinned(!isPinned(descriptorID), for: descriptorID)
    }

    /// managed account family의 기존 메뉴바 star를 선택된 카드로 re-target — account-switch 전용 action
    /// (dashboard-picker 아님), 같은 metric kind를 per-provider 상한 내로 이전.
    func retargetMenuBarPins(for family: String, to providerID: String) {
        guard ProviderAccountID.family(of: providerID) == family,
              registry.provider(id: providerID) != nil else {
            return
        }

        let familyPins = pinnedMetricIDs.filter { descriptorID in
            guard let descriptor = registry.descriptor(id: descriptorID) else { return false }
            return ProviderAccountID.family(of: descriptor.providerID) == family
        }
        guard !familyPins.isEmpty else { return }

        let pinnedMetricKinds = Set(familyPins.compactMap { descriptorID in
            registry.descriptor(id: descriptorID).flatMap(Self.accountMetricKind)
        })
        let selectedPins = Set(
            metricOrder(for: providerID)
                .filter { descriptorID in
                    guard let descriptor = registry.descriptor(id: descriptorID), descriptor.pinnable,
                          let kind = Self.accountMetricKind(descriptor) else {
                        return false
                    }
                    return pinnedMetricKinds.contains(kind)
                }
                .prefix(Self.maxPinsPerProvider)
        )

        var updatedPins = pinnedMetricIDs
        updatedPins.subtract(familyPins)
        updatedPins.formUnion(selectedPins)
        guard updatedPins != pinnedMetricIDs else { return }

        pinnedMetricIDs = updatedPins
        persistPins()
    }

    private static func accountMetricKind(_ descriptor: WidgetDescriptor) -> String? {
        let prefix = descriptor.providerID + "."
        guard descriptor.id.hasPrefix(prefix) else { return nil }
        return String(descriptor.id.dropFirst(prefix.count))
    }

    func persistPins() {
        persistence.savePins(pinnedMetricIDs)
    }

    func persistExpanded() {
        persistence.saveExpandedMetrics(expandedMetricIDs)
    }

    func persistExpandOnEnable() {
        persistence.saveExpandOnEnable(defaultExpandedOnEnableIDs)
    }

    private func persistExpandedProviders() {
        persistence.saveExpandedProviders(expandedProviderIDs)
    }

    // MARK: - Mutations

    func add(_ descriptorID: String) {
        guard registry.descriptor(id: descriptorID) != nil else { return }
        guard !placed.contains(where: { $0.descriptorID == descriptorID }) else { return }
        cancelDrag()
        placed.append(PlacedWidget(descriptorID: descriptorID))
        syncPlacedOrder()
    }

    func remove(_ id: UUID) {
        guard let index = placed.firstIndex(where: { $0.id == id }) else { return }
        cancelDrag()
        placed.remove(at: index)
        persist()
    }

    func resetToDefault() {
        cancelDrag()
        // reset은 그 자체로 deliberate action — pre-reset 레이아웃을 가리키는 undo stack 전체 폐기.
        undoHistory.clear()
        placed = defaultMetricIDs
            .filter { registry.descriptor(id: $0) != nil }
            .map { PlacedWidget(descriptorID: $0) }
        providerOrder = registry.providers.map(\.id)
        persistProviderOrder()
        metricOrderByProvider = LayoutOrdering.defaultMetricOrder(registry: registry)
        persistMetricOrder()
        pinnedMetricIDs = Set(defaultPinnedMetricIDs.filter { registry.descriptor(id: $0) != nil })
        persistPins()
        expandedMetricIDs = Set(defaultExpandedMetricIDs.filter { registry.descriptor(id: $0) != nil })
        defaultExpandedOnEnableIDs = []
        persistExpanded()
        persistExpandOnEnable()
        expandedProviderIDs = []
        persistExpandedProviders()
        persistSeededDefaults(Set(LayoutOrdering.knownMetricIDs(defaultMetricIDs, registry: registry)))
        persist()
    }

    /// 한 provider의 customization만 default로 reset(enabled metric·metric 순서·pin·caret membership) —
    /// 다른 provider와 전체 provider 순서는 유지. `resetToDefault`의 per-provider 대응; 미지 provider는 no-op.
    func resetProvider(_ providerID: String) {
        guard registry.provider(id: providerID) != nil else { return }
        cancelDrag()
        // reset은 undoable edit이 아님 — snapshot이 whole-layout이라 per-provider trim 대신 stack 전체 clear.
        undoHistory.clear()

        // 이 provider의 descriptor 전집 — 아래 membership set들의 scope.
        let owned = Set(registry.descriptors(for: providerID).map(\.id))
        func defaults(_ ids: [String]) -> [String] {
            ids.filter { owned.contains($0) && registry.descriptor(id: $0) != nil }
        }

        // enabled metric: 이 provider의 placed 제거 후 default-on set 재seed — 타 provider widget은
        // identity·위치 유지, 마지막 `syncPlacedOrder`가 전체를 provider+metric 순서로 재정렬.
        placed = placed.filter { !owned.contains($0.descriptorID) }
            + defaults(defaultMetricIDs).map { PlacedWidget(descriptorID: $0) }

        // metric 순서는 이 provider만 registry 순서로 복귀.
        metricOrderByProvider[providerID] = registry.descriptors(for: providerID).map(\.id)
        persistMetricOrder()

        // pin·expanded·expand-on-enable carry: 이 provider entry만 default로 교체, 나머지 set 유지.
        pinnedMetricIDs.subtract(owned)
        pinnedMetricIDs.formUnion(defaults(defaultPinnedMetricIDs))
        persistPins()

        expandedMetricIDs.subtract(owned)
        expandedMetricIDs.formUnion(defaults(defaultExpandedMetricIDs))
        defaultExpandedOnEnableIDs.subtract(owned)
        persistExpanded()
        persistExpandOnEnable()

        // default는 collapsed 카드.
        if expandedProviderIDs.remove(providerID) != nil {
            persistExpandedProviders()
        }

        syncPlacedOrder() // `placed` persist 포함
    }

    func cancelDrag() {
        draggingID = nil
    }

    func persist() {
        persistence.savePlaced(placed)
    }

    func persistProviderOrder() {
        persistence.saveProviderOrder(providerOrder)
    }

    func persistMetricOrder() {
        persistence.saveMetricOrder(metricOrderByProvider)
    }

    private func persistSeededDefaults(_ ids: Set<String>) {
        persistence.saveSeededDefaults(ids)
    }

    func metricOrder(for providerID: String) -> [String] {
        let valid = registry.descriptors(for: providerID).map(\.id)
        let saved = metricOrderByProvider[providerID] ?? []
        return LayoutOrdering.normalizedMetricIDs(saved, validIDs: valid)
    }

    func syncPlacedOrder(persistChanges: Bool = true) {
        let byDescriptor = Dictionary(
            placed.map { ($0.descriptorID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var ordered: [PlacedWidget] = []
        for providerID in orderedProviderIDs() {
            ordered.append(contentsOf: metricOrder(for: providerID).compactMap { byDescriptor[$0] })
        }
        let orderedIDs = Set(ordered.map(\.id))
        ordered.append(contentsOf: placed.filter { !orderedIDs.contains($0.id) })
        placed = ordered
        if persistChanges { persist() }
    }

}
