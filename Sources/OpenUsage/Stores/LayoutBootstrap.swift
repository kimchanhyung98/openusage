import Foundation

/// owner 승인 기본값과 seed marker 없는 기존 사용자용 legacy baseline 묶음
struct LayoutDefaultSet {
    let metricIDs: [String]
    let migrationBaselineMetricIDs: [String]
    let pinnedMetricIDs: [String]
    let expandedMetricIDs: [String]
}

/// startup 종료 시점에 `LayoutStore`가 필요로 하는 전체 상태와 초기화 후 수행할 migration 쓰기 목록
struct LayoutInitialState {
    let placed: [PlacedWidget]
    let providerOrder: [String]
    let metricOrderByProvider: [String: [String]]
    let pinnedMetricIDs: Set<String>
    let expandedMetricIDs: Set<String>
    let expandedProviderIDs: Set<String>
    let defaultExpandedOnEnableIDs: Set<String>
    let menuBarStyle: MenuBarStyle

    let shouldPersistPlaced: Bool
    let shouldPersistExpanded: Bool
    let shouldPersistExpandOnEnable: Bool
    let shouldPersistPins: Bool
    let shouldPersistMetricOrder: Bool
    let shouldPersistExpandedProviders: Bool
    let seededDefaultsToPersist: Set<String>?
}

/// 신규 설치·기존 사용자용 layout 로드
/// startup·default-upgrade 정책을 한곳에 모으고, 초기화 이후 라이브 액션은 `LayoutStore` 담당
@MainActor
enum LayoutBootstrap {
    static func load(
        registry: WidgetRegistry,
        persistence: LayoutPersistence,
        defaults: LayoutDefaultSet
    ) -> LayoutInitialState {
        let hasStoredLayout = persistence.hasStoredLayout
        // registry에 없는 metric(부재 중 계정 card)도 tombstone으로 유지 — 계정 복귀 시 enabled 상태 복원
        let savedPlaced = persistence.loadPlaced()
        // 저장된 카드 scoped 항목은 family 설정으로 접음 — 한 provider의 카드는 layout 1벌을 공유
        let foldedPlaced = savedPlaced.map(LayoutOrdering.foldingToCanonical)
        let startingPlaced = foldedPlaced ?? defaults.metricIDs
            .filter { registry.hasCanonicalMetric($0) }
            .map { PlacedWidget(descriptorID: $0) }
        let seededResult = seedNewDefaultMetrics(
            into: startingPlaced,
            persistence: persistence,
            hasStoredLayout: hasStoredLayout,
            registry: registry,
            defaults: defaults
        )

        let providerOrder = persistence.loadProviderOrder() ?? registry.providers.map(\.id)
        let savedMetricOrder = persistence.loadMetricOrder()
        let metricOrderByProvider = savedMetricOrder.map {
            LayoutOrdering.normalizedMetricOrder($0, registry: registry)
        } ?? LayoutOrdering.defaultMetricOrder(registry: registry)

        // 저장값(모두 unpin한 빈 배열 포함) 우선, 미지의 저장 id는 부재 중 계정 card용 tombstone으로 보존
        let pinnedMetricIDs: Set<String>
        var shouldPersistPins = false
        if let savedPins = persistence.loadPins() {
            // 카드별 pin은 canonical로 합친 뒤 provider 상한 재적용 — fold가 조용히 상한을 넘기지 않도록
            pinnedMetricIDs = LayoutOrdering.foldingPins(
                savedPins,
                order: metricOrderByProvider,
                limit: LayoutStore.maxPinsPerProvider
            )
            shouldPersistPins = pinnedMetricIDs != Set(savedPins)
        } else {
            pinnedMetricIDs = Set(defaults.pinnedMetricIDs.filter { registry.hasCanonicalMetric($0) })
        }

        // expanded 소속은 신규 설치 전용 default — 기능 도입 전 기존 layout은 전부 caret 위 유지
        var shouldPersistExpanded = false
        var expandedMetricIDs: Set<String>
        if let savedExpanded = persistence.loadExpandedMetrics() {
            // family 설정이 곧 provider 설정 — 카드 scoped 항목은 버림(bare 항목이 승리)
            expandedMetricIDs = Set(savedExpanded.filter { !ProviderAccountID.isAccountCard($0) })
            shouldPersistExpanded = expandedMetricIDs.count != savedExpanded.count
        } else if hasStoredLayout {
            expandedMetricIDs = []
        } else {
            expandedMetricIDs = Set(defaults.expandedMetricIDs.filter { registry.hasCanonicalMetric($0) })
            shouldPersistExpanded = true
        }

        let savedExpandedProviders = persistence.loadExpandedProviders()
        let expandedProviderIDs = Set((savedExpandedProviders ?? []).map(ProviderAccountID.family))
        let shouldPersistExpandedProviders = savedExpandedProviders.map {
            expandedProviderIDs != Set($0)
        } ?? false

        // 새로 배포된 default metric만 caret 아래로 시작 가능 — 사용자가 이미 보던 metric은 숨기지 않는 규칙
        let newlyExpanded = Set(seededResult.newlyPlaced)
            .intersection(defaults.expandedMetricIDs)
            .filter { registry.hasCanonicalMetric($0) }
        if !newlyExpanded.isSubset(of: expandedMetricIDs) {
            expandedMetricIDs.formUnion(newlyExpanded)
            shouldPersistExpanded = true
        }

        // optional default-expanded metric은 최초 enable 시 caret 아래 진입 — 저장 queue 우선으로 사용자 이동 재생성 방지
        let placedIDs = Set(seededResult.placed.map(\.descriptorID))
        let expandedNow = expandedMetricIDs
        let isExpandOnEnableCandidate: (String) -> Bool = { [registry] id in
            registry.hasCanonicalMetric(id) && !expandedNow.contains(id) && !placedIDs.contains(id)
        }
        let savedOnEnable = persistence.loadExpandOnEnable()
        let defaultExpandedOnEnableIDs: Set<String>
        var shouldPersistExpandOnEnable = savedOnEnable == nil
        if let savedOnEnable {
            // 알려진 metric은 유효 후보여야 하나, 미지 id는 부재 중 계정 card 소속일 수 있어 descriptor 복귀까지 보존
            let folded = savedOnEnable.filter { !ProviderAccountID.isAccountCard($0) }
            defaultExpandedOnEnableIDs = Set(folded.filter { id in
                !registry.hasCanonicalMetric(id) || isExpandOnEnableCandidate(id)
            })
            shouldPersistExpandOnEnable = defaultExpandedOnEnableIDs != Set(savedOnEnable)
        } else {
            defaultExpandedOnEnableIDs = Set(defaults.expandedMetricIDs.filter(isExpandOnEnableCandidate))
        }

        return LayoutInitialState(
            placed: seededResult.placed,
            providerOrder: providerOrder,
            metricOrderByProvider: metricOrderByProvider,
            pinnedMetricIDs: pinnedMetricIDs,
            expandedMetricIDs: expandedMetricIDs,
            expandedProviderIDs: expandedProviderIDs,
            defaultExpandedOnEnableIDs: defaultExpandedOnEnableIDs,
            menuBarStyle: persistence.loadMenuBarStyle(),
            shouldPersistPlaced: seededResult.shouldPersistPlaced
                || foldedPlaced.map { $0 != savedPlaced } ?? false,
            shouldPersistExpanded: shouldPersistExpanded,
            shouldPersistExpandOnEnable: shouldPersistExpandOnEnable,
            shouldPersistPins: shouldPersistPins,
            shouldPersistMetricOrder: savedMetricOrder.map { $0 != metricOrderByProvider } ?? false,
            shouldPersistExpandedProviders: shouldPersistExpandedProviders,
            seededDefaultsToPersist: seededResult.shouldPersistSeededDefaults
                ? seededResult.seededDefaults
                : nil
        )
    }

    private struct SeededDefaultsResult {
        let placed: [PlacedWidget]
        let seededDefaults: Set<String>
        let shouldPersistPlaced: Bool
        let shouldPersistSeededDefaults: Bool
        let newlyPlaced: [String]
    }

    private static func seedNewDefaultMetrics(
        into placed: [PlacedWidget],
        persistence: LayoutPersistence,
        hasStoredLayout: Bool,
        registry: WidgetRegistry,
        defaults: LayoutDefaultSet
    ) -> SeededDefaultsResult {
        let knownDefaults = LayoutOrdering.knownMetricIDs(defaults.metricIDs, registry: registry)
        let knownDefaultSet = Set(knownDefaults)
        let hasStoredSeededDefaults = persistence.hasStoredSeededDefaults

        let seededDefaults: Set<String>
        var shouldPersistSeededDefaults = false
        if let saved = persistence.loadSeededDefaults() {
            // registry에 provider가 없는 metric의 marker도 유지 — prune하면 card 복귀 시 사용자가 끈 default metric이 신규로 오인되어 재활성화됨
            // 카드 scoped marker는 canonical로 접어 유지 — 접지 않으면 family metric이 신규로 오인됨
            seededDefaults = Set(saved.map(ProviderAccountID.canonicalMetricID))
            shouldPersistSeededDefaults = seededDefaults != Set(saved)
        } else if hasStoredLayout {
            seededDefaults = Set(LayoutOrdering.knownMetricIDs(defaults.migrationBaselineMetricIDs, registry: registry))
            shouldPersistSeededDefaults = true
        } else {
            seededDefaults = knownDefaultSet
            shouldPersistSeededDefaults = true
        }

        let placedIDs = Set(placed.map(\.descriptorID))
        let toAdd = knownDefaults.filter { !seededDefaults.contains($0) && !placedIDs.contains($0) }
        let nextSeededDefaults = seededDefaults.union(knownDefaultSet)
        shouldPersistSeededDefaults = shouldPersistSeededDefaults
            || !hasStoredSeededDefaults
            || nextSeededDefaults != seededDefaults

        return SeededDefaultsResult(
            placed: placed + toAdd.map { PlacedWidget(descriptorID: $0) },
            seededDefaults: nextSeededDefaults,
            shouldPersistPlaced: !toAdd.isEmpty,
            shouldPersistSeededDefaults: shouldPersistSeededDefaults,
            newlyPlaced: toAdd
        )
    }
}

/// startup과 라이브 layout 변경이 공유하는 순수 ordering·default helper
enum LayoutOrdering {
    static func knownMetricIDs(_ ids: [String], registry: WidgetRegistry) -> [String] {
        var seen = Set<String>()
        return ids.filter { id in
            guard registry.hasCanonicalMetric(id), !seen.contains(id) else { return false }
            seen.insert(id)
            return true
        }
    }

    /// 저장된 카드 scoped 항목을 family 설정으로 축약 — 중복은 첫 항목이 위치와 identity를 유지
    static func foldingToCanonical(_ placed: [PlacedWidget]) -> [PlacedWidget] {
        var seen = Set<String>()
        return placed.compactMap { widget in
            let canonicalID = ProviderAccountID.canonicalMetricID(widget.descriptorID)
            guard seen.insert(canonicalID).inserted else { return nil }
            return PlacedWidget(id: widget.id, descriptorID: canonicalID)
        }
    }

    /// 카드별 pin을 family pin으로 합치고 provider 상한을 metric 순서대로 재적용
    static func foldingPins(
        _ pins: [String],
        order: [String: [String]],
        limit: Int
    ) -> Set<String> {
        var byFamily: [String: [String]] = [:]
        var seen = Set<String>()
        for pin in pins {
            let canonicalID = ProviderAccountID.canonicalMetricID(pin)
            guard seen.insert(canonicalID).inserted else { continue }
            let family = ProviderAccountID.family(of: ProviderAccountID.providerID(ofMetric: canonicalID))
            byFamily[family, default: []].append(canonicalID)
        }
        var result = Set<String>()
        for (family, familyPins) in byFamily {
            guard familyPins.count > limit else {
                result.formUnion(familyPins)
                continue
            }
            // 상한 초과분은 metric 순서 앞쪽을 남김 — 메뉴바 strip이 그리는 순서와 동일
            let ranking = order[family] ?? []
            let sorted = familyPins.sorted { lhs, rhs in
                (ranking.firstIndex(of: lhs) ?? Int.max) < (ranking.firstIndex(of: rhs) ?? Int.max)
            }
            result.formUnion(sorted.prefix(limit))
        }
        return result
    }

    static func defaultMetricOrder(registry: WidgetRegistry) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for provider in registry.providers {
            let family = ProviderAccountID.family(of: provider.id)
            result[family] = registry.canonicalMetricIDs(family: family)
        }
        return result
    }

    static func normalizedMetricOrder(
        _ saved: [String: [String]],
        registry: WidgetRegistry
    ) -> [String: [String]] {
        // 저장된 key 전체에서 시작해 부재 중 계정 card의 ordering 유지, 현재 family는 dedupe 후
        // 신규 metric append — 렌더링 전 live registry 필터링은 `LayoutStore` 담당
        var fallback: [String: [String]] = [:]
        for (providerID, ids) in saved {
            let family = ProviderAccountID.family(of: providerID)
            // bare key가 곧 family 설정 — 카드 key는 family 항목이 없을 때만 승격
            if fallback[family] == nil || providerID == family {
                fallback[family] = ids.map(ProviderAccountID.canonicalMetricID)
            }
        }
        for provider in registry.providers {
            let family = ProviderAccountID.family(of: provider.id)
            let valid = registry.canonicalMetricIDs(family: family)
            if let savedIDs = fallback[family] {
                var seen = Set<String>()
                var retained = savedIDs.filter { seen.insert($0).inserted }
                retained.append(contentsOf: valid.filter { seen.insert($0).inserted })
                fallback[family] = retained
            } else {
                fallback[family] = valid
            }
        }
        return fallback
    }

    /// 저장된 canonical 순서를 대상 id 공간(카드 scoped 또는 canonical)으로 투영
    static func normalizedMetricIDs(_ saved: [String], validIDs: [String]) -> [String] {
        var byCanonical: [String: String] = [:]
        for id in validIDs {
            byCanonical[ProviderAccountID.canonicalMetricID(id)] = id
        }
        var seen = Set<String>()
        var ordered: [String] = []
        for id in saved {
            guard let concrete = byCanonical[ProviderAccountID.canonicalMetricID(id)],
                  seen.insert(concrete).inserted else { continue }
            ordered.append(concrete)
        }
        ordered.append(contentsOf: validIDs.filter { !seen.contains($0) })
        return ordered
    }
}
