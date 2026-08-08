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
        // registry에 없는 provider의 widget(부재 중 계정 card)도 tombstone으로 유지 — 계정 복귀 시 enabled 상태 복원
        let savedPlaced = persistence.loadPlaced()
        let startingPlaced = savedPlaced ?? defaults.metricIDs
            .filter { registry.descriptor(id: $0) != nil }
            .map { PlacedWidget(descriptorID: $0) }
        let seededResult = seedNewDefaultMetrics(
            into: startingPlaced,
            persistence: persistence,
            hasStoredLayout: hasStoredLayout,
            registry: registry,
            defaults: defaults
        )

        let providerOrder = persistence.loadProviderOrder() ?? registry.providers.map(\.id)
        let metricOrderByProvider = persistence.loadMetricOrder().map {
            LayoutOrdering.normalizedMetricOrder($0, registry: registry)
        } ?? LayoutOrdering.defaultMetricOrder(registry: registry)

        // 저장값(모두 unpin한 빈 배열 포함) 우선, 미지의 저장 id는 부재 중 계정 card용 tombstone으로 보존
        let pinnedMetricIDs: Set<String>
        if let savedPins = persistence.loadPins() {
            pinnedMetricIDs = Set(savedPins)
        } else {
            pinnedMetricIDs = Set(defaults.pinnedMetricIDs.filter { registry.descriptor(id: $0) != nil })
        }

        // expanded 소속은 신규 설치 전용 default — 기능 도입 전 기존 layout은 전부 caret 위 유지
        var shouldPersistExpanded = false
        var expandedMetricIDs: Set<String>
        if let savedExpanded = persistence.loadExpandedMetrics() {
            expandedMetricIDs = Set(savedExpanded)
        } else if hasStoredLayout {
            expandedMetricIDs = []
        } else {
            expandedMetricIDs = Set(defaults.expandedMetricIDs.filter { registry.descriptor(id: $0) != nil })
            shouldPersistExpanded = true
        }

        let expandedProviderIDs = Set(persistence.loadExpandedProviders() ?? [])

        // 새로 배포된 default metric만 caret 아래로 시작 가능 — 사용자가 이미 보던 metric은 숨기지 않는 규칙
        let newlyExpanded = Set(seededResult.newlyPlaced)
            .intersection(defaults.expandedMetricIDs)
            .filter { registry.descriptor(id: $0) != nil }
        if !newlyExpanded.isSubset(of: expandedMetricIDs) {
            expandedMetricIDs.formUnion(newlyExpanded)
            shouldPersistExpanded = true
        }

        // optional default-expanded metric은 최초 enable 시 caret 아래 진입 — 저장 queue 우선으로 사용자 이동 재생성 방지
        let placedIDs = Set(seededResult.placed.map(\.descriptorID))
        let expandedNow = expandedMetricIDs
        let isExpandOnEnableCandidate: (String) -> Bool = { [registry] id in
            registry.descriptor(id: id) != nil && !expandedNow.contains(id) && !placedIDs.contains(id)
        }
        let savedOnEnable = persistence.loadExpandOnEnable()
        let defaultExpandedOnEnableIDs: Set<String>
        if let savedOnEnable {
            // 알려진 metric은 유효 후보여야 하나, 미지 id는 부재 중 계정 card 소속일 수 있어 descriptor 복귀까지 보존
            defaultExpandedOnEnableIDs = Set(savedOnEnable.filter { id in
                registry.descriptor(id: id) == nil || isExpandOnEnableCandidate(id)
            })
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
            shouldPersistPlaced: seededResult.shouldPersistPlaced,
            shouldPersistExpanded: shouldPersistExpanded,
            shouldPersistExpandOnEnable: savedOnEnable == nil,
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
            seededDefaults = Set(saved)
            shouldPersistSeededDefaults = seededDefaults.count != saved.count
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
            guard registry.descriptor(id: id) != nil, !seen.contains(id) else { return false }
            seen.insert(id)
            return true
        }
    }

    static func defaultMetricOrder(registry: WidgetRegistry) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for provider in registry.providers {
            result[provider.id] = registry.descriptors(for: provider.id).map(\.id)
        }
        return result
    }

    static func normalizedMetricOrder(
        _ saved: [String: [String]],
        registry: WidgetRegistry
    ) -> [String: [String]] {
        // 저장된 provider 전체에서 시작해 부재 중 계정 card의 ordering 유지, 현재 provider는 dedupe 후
        // 신규 metric append — 렌더링 전 live registry 필터링은 `LayoutStore` 담당
        var fallback = saved
        for provider in registry.providers {
            let valid = registry.descriptors(for: provider.id).map(\.id)
            if let savedIDs = saved[provider.id] {
                var seen = Set<String>()
                var retained = savedIDs.filter { seen.insert($0).inserted }
                retained.append(contentsOf: valid.filter { seen.insert($0).inserted })
                fallback[provider.id] = retained
            } else {
                fallback[provider.id] = valid
            }
        }
        return fallback
    }

    static func normalizedMetricIDs(_ saved: [String], validIDs: [String]) -> [String] {
        let validSet = Set(validIDs)
        var seen = Set<String>()
        var ordered = saved.filter { id in
            guard validSet.contains(id), !seen.contains(id) else { return false }
            seen.insert(id)
            return true
        }
        ordered.append(contentsOf: validIDs.filter { !seen.contains($0) })
        return ordered
    }
}
