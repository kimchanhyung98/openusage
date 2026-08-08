extension LayoutStore {
    func provider(id: String) -> Provider? { registry.provider(id: id) }

    func descriptor(for widget: PlacedWidget) -> WidgetDescriptor? {
        registry.descriptor(id: widget.descriptorID)
    }

    private func providerID(of widget: PlacedWidget) -> String? {
        registry.descriptor(id: widget.descriptorID)?.providerID
    }

    var visiblePlaced: [PlacedWidget] {
        placed.filter { widget in
            guard let providerID = providerID(of: widget) else { return true }
            return isProviderEnabled(providerID)
        }
    }

    func isMetricEnabled(_ descriptorID: String) -> Bool {
        registry.descriptor(id: descriptorID) != nil
            && placed.contains { $0.descriptorID == descriptorID }
    }

    /// Total Spend 카드의 capability gate — local spend tile을 제공하는 enabled provider 존재 여부.
    /// registry descriptor 기준(refresh 데이터 무관)이라 데이터 없는 아침에도 "No spend data" 상태로 표시.
    var hasSpendCapableProvider: Bool {
        !spendCapableProviders.isEmpty
    }

    /// local spend tile(`WidgetDescriptor.spendTiles`)을 제공하는 enabled provider(사용자 provider 순서) —
    /// Total Spend가 집계하는 정확한 집합. `displayGroups`가 아닌 이유: metric을 전부 숨긴 provider도
    /// 지출은 계속되므로 포함, 타 provider의 유사 dollar 행(OpenRouter API-spend "Today")은 제외.
    var spendCapableProviders: [Provider] {
        let capableIDs = Set(registry.descriptors.filter(\.isSpendTile).map(\.providerID))
        return orderedProviders().filter { capableIDs.contains($0.id) && isProviderEnabled($0.id) }
    }

    // MARK: - Provider grouping

    /// 저장된 순서의 known provider + 아직 못 본 provider는 registry 순서로 append — 신규 provider도 표시.
    func orderedProviderIDs() -> [String] {
        registry.orderedProviderIDs(savedOrder: providerOrder)
    }

    private func orderedProviders() -> [Provider] {
        orderedProviderIDs().compactMap { registry.provider(id: $0) }
    }

    /// provider별로 묶인 enabled widget(사용자 provider 순서·custom metric 순서) — grouped dashboard
    /// 목록 구동, visible metric 없는 provider는 제외.
    var displayGroups: [ProviderGroup] {
        orderedProviders().compactMap { provider in
            let widgetsByDescriptor = Dictionary(
                visiblePlaced
                    .filter { providerID(of: $0) == provider.id }
                    .map { ($0.descriptorID, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let widgets = metricOrder(for: provider.id).compactMap { widgetsByDescriptor[$0] }
            guard !widgets.isEmpty else { return nil }
            let alwaysShown = widgets.filter { !expandedMetricIDs.contains($0.descriptorID) }
            let expanded = widgets.filter { expandedMetricIDs.contains($0.descriptorID) }
            // enabled metric이 전부 expanded인 provider는 빈 카드+caret이 되므로 always-shown으로 승격.
            if alwaysShown.isEmpty {
                return ProviderGroup(provider: provider, alwaysShownWidgets: expanded, expandedWidgets: [])
            }
            return ProviderGroup(provider: provider, alwaysShownWidgets: alwaysShown, expandedWidgets: expanded)
        }
    }

    /// enabled provider 전체와 각자가 지원하는 *모든* metric(저장된 metric 순서) — enabled/disabled 행
    /// 자리 유지, switch는 가시성만 제어.
    var customizeGroups: [ProviderMetrics] {
        orderedProviders().compactMap { provider in
            guard isProviderEnabled(provider.id) else { return nil }
            let metrics = orderedSupportedMetrics(for: provider.id)
            guard !metrics.isEmpty else { return nil }
            return ProviderMetrics(
                provider: provider,
                alwaysShownMetrics: metrics.filter { !expandedMetricIDs.contains($0.id) },
                expandedMetrics: metrics.filter { expandedMetricIDs.contains($0.id) }
            )
        }
    }

    /// L1 Customize 목록 — enablement 무관 모든 known provider(사용자 순서). disabled provider도 포함해
    /// 재활성·detail 진입 가능(`customizeGroups`와 달리 미필터); 행에 enablement flag와 metric 수 포함.
    var customizeProviderRows: [ProviderRow] {
        orderedProviders().filter { !ProviderAccountID.isAccountCard($0.id) }.map { provider in
            ProviderRow(
                provider: provider,
                isEnabled: isProviderEnabled(provider.id),
                metricCount: metricCount(for: provider.id)
            )
        }
    }

    /// provider가 지원하는 metric 총수 — L1 행 badge 숫자, enabled 수와 무관한 registry descriptor count.
    func metricCount(for providerID: String) -> Int {
        registry.descriptors(for: providerID).count
    }

    /// 한 provider의 L2 Customize detail — "Always Visible"/"On Demand" divider로 분할된 전체 metric.
    /// disabled provider에도 제공(dimmed-but-editable 렌더); 미지 provider·metric 없음이면 nil.
    func customizeDetail(for providerID: String) -> ProviderMetrics? {
        guard let provider = registry.provider(id: providerID) else { return nil }
        let metrics = orderedSupportedMetrics(for: providerID)
        guard !metrics.isEmpty else { return nil }
        return ProviderMetrics(
            provider: provider,
            alwaysShownMetrics: metrics.filter { !expandedMetricIDs.contains($0.id) },
            expandedMetrics: metrics.filter { expandedMetricIDs.contains($0.id) }
        )
    }

    /// custom 순서의 지원 metric — 각 metric의 enabled 여부와 무관.
    func orderedSupportedMetrics(for providerID: String) -> [WidgetDescriptor] {
        metricOrder(for: providerID).compactMap { registry.descriptor(id: $0) }
    }

    func metricOrderWithDivider(for providerID: String, dividerID: String) -> [String] {
        let ordered = orderedSupportedMetrics(for: providerID).map(\.id)
        return ordered.filter { !expandedMetricIDs.contains($0) }
            + [dividerID]
            + ordered.filter { expandedMetricIDs.contains($0) }
    }

    /// provider별로 묶인 pin된 metric(Customize 순서) — 일시 disabled provider는 렌더 그룹에서 빠지되
    /// pin은 유지. 메뉴바 strip 구동.
    var pinnedGroups: [ProviderMetrics] {
        orderedProviders().compactMap { provider in
            guard isProviderEnabled(provider.id) else { return nil }
            // strip 순서를 Customize와 일치 — always-shown pin 먼저, expanded pin 다음.
            let metrics = orderedSupportedMetrics(for: provider.id).filter { pinnedMetricIDs.contains($0.id) }
            return metrics.isEmpty ? nil : ProviderMetrics(
                provider: provider,
                alwaysShownMetrics: metrics.filter { !expandedMetricIDs.contains($0.id) },
                expandedMetrics: metrics.filter { expandedMetricIDs.contains($0.id) }
            )
        }
    }

    /// provider header drag drop으로 provider 전체 reorder — 현재 표시 중(enabled) 순서 기준.
    /// 반환값은 실제 변경 여부(drag gesture의 haptics 키).
    @discardableResult
    func reorderProvider(dragged: String, target: String) -> Bool {
        recordingUndoStep {
            let shown = customizeGroups.map(\.provider.id)
            guard let next = Self.reordered(shown, dragged: dragged, target: target) else { return false }
            // persist된 raw 순서에서 visible slot만 재배열 — unknown id(이 launch registry에 없는 account
            // 카드)와 disabled provider는 정확한 위치를 유지한 채 visible id만 그 사이를 이동.
            let shownSet = Set(shown)
            var replacements = next.makeIterator()
            var rebuilt: [String] = []
            for providerID in providerOrder {
                if shownSet.contains(providerID) {
                    if let replacement = replacements.next() { rebuilt.append(replacement) }
                } else {
                    rebuilt.append(providerID)
                }
            }
            while let replacement = replacements.next() { rebuilt.append(replacement) }
            for providerID in orderedProviderIDs() where !rebuilt.contains(providerID) {
                rebuilt.append(providerID)
            }
            providerOrder = rebuilt
            persistProviderOrder()
            syncPlacedOrder()
            return true
        }
    }

    /// 한 provider 내 metric reorder(둘 다 그 provider의 descriptor id) — 전체 metric 순서에서 동작해
    /// disabled metric도 자리 유지. 다른 section의 행에 drop하면 dragged의 On Demand membership이 target을
    /// 따라감; 저장 순서는 두 section 분할로 재구성. 반환값은 실제 변경 여부(haptics 키).
    @discardableResult
    func reorderMetric(dragged: String, target: String, in providerID: String) -> Bool {
        recordingUndoStep { reorderMetricImpl(dragged: dragged, target: target, in: providerID) }
    }

    private func reorderMetricImpl(dragged: String, target: String, in providerID: String) -> Bool {
        guard dragged != target else { return false }
        let ordered = metricOrder(for: providerID)
        guard ordered.contains(dragged), ordered.contains(target) else { return false }

        var expanded = expandedMetricIDs
        let membershipChanged = expanded.contains(dragged) != expanded.contains(target)
        if expanded.contains(target) {
            expanded.insert(dragged)
        } else {
            expanded.remove(dragged)
        }

        // always-shown section 착지는 명시적 배치 — expand-on-enable default 소비(이후 enable이 caret
        // 아래로 되돌려 이 drag를 override하는 것 방지).
        let consumedExpandOnEnable = !expanded.contains(dragged)
            && defaultExpandedOnEnableIDs.remove(dragged) != nil

        // 렌더 순서(Always Visible → On Demand)대로 배열 후 그 결합 sequence 안에서 target 옆에 dragged 삽입.
        let partitioned = ordered.filter { !expanded.contains($0) } + ordered.filter { expanded.contains($0) }
        guard let next = Self.reordered(partitioned, dragged: dragged, target: target) else {
            guard membershipChanged || consumedExpandOnEnable else { return false }
            metricOrderByProvider[providerID] = partitioned
            expandedMetricIDs = expanded
            persistMetricOrder()
            persistExpanded()
            if consumedExpandOnEnable { persistExpandOnEnable() }
            syncPlacedOrder()
            return true
        }
        metricOrderByProvider[providerID] = next
        expandedMetricIDs = expanded
        persistMetricOrder()
        if membershipChanged { persistExpanded() }
        if consumedExpandOnEnable { persistExpandOnEnable() }
        syncPlacedOrder()
        return true
    }

    /// divider sentinel 하나를 포함한 provider metric 순서 적용 — sentinel 앞은 Always Visible, 뒤는
    /// On Demand. divider는 drag target geometry에만 참여, persistence는 metric-only.
    @discardableResult
    func applyMetricDividerOrder(_ orderedIDsWithDivider: [String], dragged: String, dividerID: String, in providerID: String) -> Bool {
        recordingUndoStep {
            applyMetricDividerOrderImpl(orderedIDsWithDivider, dragged: dragged, dividerID: dividerID, in: providerID)
        }
    }

    private func applyMetricDividerOrderImpl(_ orderedIDsWithDivider: [String], dragged: String, dividerID: String, in providerID: String) -> Bool {
        let validIDs = metricOrder(for: providerID)
        let validSet = Set(validIDs)
        guard orderedIDsWithDivider.contains(dividerID) else { return false }

        var seen = Set<String>()
        var alwaysShown: [String] = []
        var expanded: [String] = []
        var isBelowDivider = false

        for id in orderedIDsWithDivider {
            if id == dividerID {
                isBelowDivider = true
                continue
            }
            guard validSet.contains(id), seen.insert(id).inserted else { continue }
            if isBelowDivider {
                expanded.append(id)
            } else {
                alwaysShown.append(id)
            }
        }

        // dashboard 행은 enabled metric만 렌더 — disabled 행을 이전 section에 merge해 dashboard drag가
        // 숨은 Customize 행을 끝으로 밀지 않도록 유지.
        let desiredAlwaysShown = Set(alwaysShown)
        let desiredExpanded = Set(expanded)
        let previousAlwaysShown = validIDs.filter { !expandedMetricIDs.contains($0) && !desiredExpanded.contains($0) }
        let previousExpanded = validIDs.filter { expandedMetricIDs.contains($0) && !desiredAlwaysShown.contains($0) }
        alwaysShown = Self.mergingMissingMetrics(into: alwaysShown, previous: previousAlwaysShown)
        expanded = Self.mergingMissingMetrics(into: expanded, previous: previousExpanded)

        let nextOrder = alwaysShown + expanded
        let providerExpanded = Set(expanded)
        let providerIDs = Set(validIDs)
        let nextExpanded = expandedMetricIDs.subtracting(providerIDs).union(providerExpanded)
        // dragged metric의 expand-on-enable entry만 소비(명시적 배치) — 목록 전체 clear는 사용자가 옮기지
        // 않은 disabled optional metric의 below-caret default까지 소실. `reorderMetric`과 동일 규칙.
        var nextDefaultExpandedOnEnableIDs = defaultExpandedOnEnableIDs
        let consumedExpandOnEnable = nextDefaultExpandedOnEnableIDs.remove(dragged) != nil
        guard metricOrderByProvider[providerID] != nextOrder || expandedMetricIDs != nextExpanded || consumedExpandOnEnable else {
            return false
        }

        metricOrderByProvider[providerID] = nextOrder
        expandedMetricIDs = nextExpanded
        defaultExpandedOnEnableIDs = nextDefaultExpandedOnEnableIDs
        persistMetricOrder()
        persistExpanded()
        if consumedExpandOnEnable { persistExpandOnEnable() }
        syncPlacedOrder()
        return true
    }

    private static func mergingMissingMetrics(into ordered: [String], previous: [String]) -> [String] {
        let orderedSet = Set(ordered)
        var result: [String] = []
        var emitted = Set<String>()
        var orderedIndex = ordered.startIndex

        func emitDesiredRows(through id: String) {
            while orderedIndex < ordered.endIndex {
                let next = ordered[orderedIndex]
                orderedIndex = ordered.index(after: orderedIndex)
                if emitted.insert(next).inserted {
                    result.append(next)
                }
                if next == id { break }
            }
        }

        for id in previous {
            if orderedSet.contains(id) {
                emitDesiredRows(through: id)
            } else if emitted.insert(id).inserted {
                result.append(id)
            }
        }

        while orderedIndex < ordered.endIndex {
            let next = ordered[orderedIndex]
            orderedIndex = ordered.index(after: orderedIndex)
            if emitted.insert(next).inserted {
                result.append(next)
            }
        }

        return result
    }

    /// 순수 reorder — `dragged` 제거 후 `target` 인접에 재삽입(아래로 이동 시 뒤, 위로 이동 시 앞).
    /// id 누락·동일이면 nil. crafcat7/Peakmon(Apache-2.0)의 검증된 macOS drag-reorder 로직 이식.
    static func reordered(_ ids: [String], dragged: String, target: String) -> [String]? {
        guard dragged != target,
              let from = ids.firstIndex(of: dragged),
              let to = ids.firstIndex(of: target) else { return nil }
        var next = ids
        next.remove(at: from)
        guard let adjusted = next.firstIndex(of: target) else { return nil }
        let insert = from < to ? adjusted + 1 : adjusted
        next.insert(dragged, at: min(insert, next.count))
        return next
    }
}
