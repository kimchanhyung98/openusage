import SwiftUI

/// Dashboard 본문 — provider별 inset group(System Settings 스타일), 헤더 아래 rounded 카드에 metric 행 배치.
/// 재정렬은 여기서 직접 가능(metric 행/provider 헤더 drag) — Customize와 동일한 로컬 gesture/geometry helper를
/// 공유해 system drag/drop 세션 없이 popover 안에서 동작.
struct WidgetGroupedListView: View {
    @Environment(AppContainer.self) private var container
    @Environment(LayoutStore.self) private var layout
    @Environment(WidgetDataStore.self) private var dataStore
    @Environment(\.colorScheme) private var colorScheme
    let reorderSpaceName: String
    @Binding var reorderLift: ReorderLift?

    @State private var rowFrames: [String: CGRect] = [:]
    @State private var activeProviderID: String?
    @State private var activeMetricID: String?
    @AppStorage(DensitySetting.key) private var density = DensitySetting.defaultValue
    @AppStorage(DashboardUsageAccountSelection.claudeKey) private var selectedClaudeUsageAccountID = ""
    @AppStorage(DashboardUsageAccountSelection.codexKey) private var selectedCodexUsageAccountID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: density.sectionSpacing) {
            ForEach(dashboardGroups) { group in
                section(group)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onPreferenceChange(ReorderFramePreferenceKey.self) { rowFrames = $0 }
        .animation(Motion.spring, value: dashboardGroups.map(\.provider.id))
    }

    private var dashboardGroups: [ProviderGroup] {
        let groups = layout.displayGroups
        let visible = Set(container.collapsingAccountCards(
            groups.map(\.provider.id),
            selectionByFamily: storedUsageAccountIDs
        ))
        return groups.filter { visible.contains($0.provider.id) }
    }

    private let accountFamilies = ["claude", "codex"]

    private func accountFamily(for providerID: String) -> String? {
        let family = ProviderAccountID.family(of: providerID)
        return accountFamilies.contains(family) ? family : nil
    }

    private func accountGroups(for family: String, in groups: [ProviderGroup]) -> [ProviderGroup] {
        groups.filter { ProviderAccountID.family(of: $0.provider.id) == family }
    }

    private func selectedAccountID(for family: String, groups: [ProviderGroup]) -> String {
        container.visibleAccountCardID(
            for: family,
            among: groups.map(\.provider.id),
            stored: storedUsageAccountID(for: family)
        ) ?? ""
    }

    /// `@AppStorage` 값을 읽는 지점 — picker 변경이 dashboard 재계산을 트리거.
    private var storedUsageAccountIDs: [String: String] {
        ["claude": selectedClaudeUsageAccountID, "codex": selectedCodexUsageAccountID]
    }

    private func storedUsageAccountID(for family: String) -> String {
        storedUsageAccountIDs[family] ?? ""
    }

    private func selectUsageAccount(_ providerID: String, for family: String) {
        switch family {
        case "claude": selectedClaudeUsageAccountID = providerID
        case "codex": selectedCodexUsageAccountID = providerID
        default: break
        }
    }

    private func section(_ group: ProviderGroup) -> some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            header(group)
            container(group)
        }
        .opacity(activeProviderID == group.provider.id ? 0 : 1)
        .reorderFrame(id: group.provider.id, in: .named(reorderSpaceName))
    }

    private func header(_ group: ProviderGroup) -> some View {
        let allGroups = layout.displayGroups
        let family = accountFamily(for: group.provider.id)
        let familyGroups = family.map { self.accountGroups(for: $0, in: allGroups) } ?? []
        let isAccountFamilyGroup = familyGroups.contains { $0.provider.id == group.provider.id }
        // 등록 profile 수가 런타임 카드 수를 넘을 수 있음(여러 계정이 공유 home 하나를 쓰는 경우).
        let accountCount = isAccountFamilyGroup
            ? max(familyGroups.count, family.map { container.accountProfiles.profiles(family: $0).count } ?? 0)
            : 0
        let options = isAccountFamilyGroup ? familyGroups.map {
            AccountUsageOption(
                id: $0.provider.id,
                title: container.accountOptionTitle(for: $0.provider.id)
            )
        } : []
        return ProviderSectionHeader(
            provider: group.provider,
            plan: dataStore.plan(for: group.provider.id),
            warning: dataStore.headerNotice(for: group.provider.id),
            refreshing: dataStore.refreshingProviderIDs.contains(group.provider.id),
            staleness: dataStore.stalenessHint(for: group.provider.id),
            onCopyScreenshot: { shareCard(group) },
            accountOptions: options,
            selectedAccountID: isAccountFamilyGroup
                ? family.map { selectedAccountID(for: $0, groups: familyGroups) }
                : nil,
            onSelectAccount: isAccountFamilyGroup ? family.map { family in
                { providerID in
                    selectUsageAccount(providerID, for: family)
                    // periodic refresh가 이 카드를 이미 소유했을 수 있음 — plain `refresh`는 skip되어
                    // 선택 계정이 다음 주기까지 stale.
                    Task { await dataStore.refreshAfterAccountSelection(providerID: providerID) }
                }
            } : nil,
            accountCount: accountCount
        )
        .padding(.horizontal, 8)
        .highPriorityGesture(providerDragGesture(for: group))
        .contextMenu {
            let name = container.displayName(for: group.provider)
            // provider section 전체 숨김(Customize provider 리스트에서 복구) — per-metric "Hide"의 상위 버전.
            Button("Hide \(name)") {
                container.setProviderEnabled(false, for: group.provider.id)
            }
            Divider()
            Button("Refresh \(name)") {
                Task { await container.refresh(providerID: group.provider.id, force: true) }
            }
            Button("Customize…") {
                openCustomize(for: group.provider.id)
            }
            Divider()
            Button("Share Screenshot") { _ = shareCard(group) }
        }
    }

    /// provider의 branded share card를 렌더링해 PNG를 clipboard에 복사 — appearance는 popover 자신의
    /// `colorScheme`을 사용해 화면의 카드와 일치.
    private func shareCard(_ group: ProviderGroup) -> Bool {
        ShareCardRenderer.share(
            group: group,
            dataStore: dataStore,
            layout: layout,
            appearance: colorScheme,
            displayName: container.displayName(for: group.provider)
        )
    }

    /// 행의 widget + 해석된 descriptor/data 묶음 — `dataStore.data(for:)`를 렌더당 1회만 계산해
    /// condensing 규칙과 행이 공유. `ForEach` identity는 `PlacedWidget` 기준 유지.
    private struct ResolvedRow: Identifiable {
        let widget: PlacedWidget
        let descriptor: WidgetDescriptor
        let data: WidgetData
        var id: PlacedWidget.ID { widget.id }
    }

    private enum DashboardMetricCardRow: Identifiable {
        case metric(ResolvedRow)
        case divider
        /// provider quick-link 버튼들(#596) — caret과 함께 접히는 expander의 일부.
        case links([ProviderLink])

        var id: String {
            switch self {
            case .metric(let row):
                "metric:\(row.descriptor.id)"
            case .divider:
                "expanded-divider"
            case .links:
                "provider-links"
            }
        }
    }

    private func container(_ group: ProviderGroup) -> some View {
        // 행별 descriptor + data를 렌더당 1회 해석해 condensing 규칙과 행이 재사용.
        let providerID = group.provider.id
        let isExpanded = layout.isProviderExpanded(providerID)
        let alwaysRows = resolvedRows(group.alwaysShownWidgets)
        let expandedRows = resolvedRows(group.expandedWidgets)
        // caret이 Always Visible/On Demand를 가르므로 text-row condensing은 caret을 넘지 않음 — 같은 쪽 행끼리만 tighten.
        let condensedIDs = visibleCondensedTextRowIDs(alwaysRows: alwaysRows, expandedRows: isExpanded ? expandedRows : [])
        let cardRows = metricCardRows(
            alwaysRows: alwaysRows,
            expandedRows: expandedRows,
            hasExpandedMetrics: group.hasExpandedMetrics,
            isExpanded: isExpanded,
            links: group.provider.visibleLinks
        )
        // lifted preview와 동일한 card builder — floating chip이 live 카드와 어긋나지 않음.
        return DashboardMetricCard {
            // 하나의 안정된 리스트로 drag 중인 행을 caret 경계 너머에서도 유지 — 분리 loop면 `onEnded` 전에
            // 해체되어 lift overlay가 잔존.
            ForEach(cardRows) { cardRow in
                switch cardRow {
                case .metric(let entry):
                    row(entry.descriptor, data: entry.data, in: providerID,
                        condensedTop: condensedIDs.contains(entry.descriptor.id))
                case .links(let links):
                    ProviderLinksView(links: links)
                case .divider:
                    expandToggle(providerID: providerID, isExpanded: isExpanded)
                }
            }
        }
    }

    private func resolvedRows(_ widgets: [PlacedWidget]) -> [ResolvedRow] {
        widgets.compactMap { widget -> ResolvedRow? in
            guard let descriptor = layout.descriptor(for: widget) else { return nil }
            return ResolvedRow(widget: widget, descriptor: descriptor, data: dataStore.data(for: descriptor))
        }
    }

    private func metricCardRows(
        alwaysRows: [ResolvedRow],
        expandedRows: [ResolvedRow],
        hasExpandedMetrics: Bool,
        isExpanded: Bool,
        links: [ProviderLink]
    ) -> [DashboardMetricCardRow] {
        // quick-link 버튼은 접히는 expanded section 안 최하단(#596) — links만 있는 provider도 caret을 얻음.
        let hasLinks = !links.isEmpty
        let hasExpandedContent = hasExpandedMetrics || hasLinks
        return alwaysRows.map(DashboardMetricCardRow.metric)
            + (hasExpandedContent ? [.divider] : [])
            + (isExpanded && !expandedRows.isEmpty ? expandedRows.map(DashboardMetricCardRow.metric) : [])
            + (isExpanded && hasLinks ? [.links(links)] : [])
    }

    /// 카드 하단 중앙 caret — On Demand metric과 quick link를 펼치고 접음.
    private func expandToggle(providerID: String, isExpanded: Bool) -> some View {
        Button {
            withAnimation(Motion.spring) {
                _ = layout.setProviderExpanded(!isExpanded, for: providerID)
            }
        } label: {
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 14)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .reorderFrame(id: expandedDividerID(for: providerID), in: .named(reorderSpaceName))
        .accessibilityLabel(isExpanded ? "Show less" : "Show more")
    }

    private func expandedDividerID(for providerID: String) -> String {
        "\(providerID)::dashboard-expanded-divider"
    }

    private func visibleCondensedTextRowIDs(alwaysRows: [ResolvedRow], expandedRows: [ResolvedRow]) -> Set<String> {
        condensedTextRowIDs(alwaysRows).union(condensedTextRowIDs(expandedRows))
    }

    /// 이웃 인식 규칙(share-card export와 공유) — 다른 text-only 행 바로 아래의 text-only 행 ID들.
    /// segment별 호출이라 expand caret을 넘지 않음.
    private func condensedTextRowIDs(_ rows: [ResolvedRow]) -> Set<String> {
        let offsets = WidgetData.condensedTextRowOffsets(in: rows.map(\.data))
        return Set(offsets.map { rows[$0].descriptor.id })
    }

    private func row(_ descriptor: WidgetDescriptor, data: WidgetData, in providerID: String,
                     condensedTop: Bool) -> some View {
        let isActive = activeMetricID == descriptor.id
        return WidgetRowView(
            data: data,
            onToggleResetDisplay: { dataStore.resetDisplayMode.toggle() },
            onToggleMeterStyle: { dataStore.meterStyle.toggle() },
            condensedTop: condensedTop
        )
            .contentShape(Rectangle())
            .opacity(isActive ? 0 : 1)
            .highPriorityGesture(metricDragGesture(for: descriptor, providerID: providerID))
            .contextMenu { rowMenu(descriptor, providerID: providerID) }
            .reorderFrame(id: descriptor.id, in: .named(reorderSpaceName))
    }

    /// 단일 metric의 context menu — Hide, star, provider refresh, Customize 진입.
    @ViewBuilder
    private func rowMenu(_ descriptor: WidgetDescriptor, providerID: String) -> some View {
        Button("Hide") {
            layout.setMetricEnabled(descriptor.id, false)
        }
        if descriptor.pinnable {
            Button(layout.isPinned(descriptor.id) ? "Unstar" : "Star for menu bar") {
                if layout.isPinned(descriptor.id) {
                    layout.setPinned(false, for: descriptor.id)
                } else if layout.canPin(descriptor.id) {
                    layout.setPinned(true, for: descriptor.id)
                } else {
                    layout.notePinDenied(descriptor.id)
                }
            }
        }
        Divider()
        if let provider = layout.provider(id: providerID) {
            Button("Refresh \(container.displayName(for: provider))") {
                Task { await container.refresh(providerID: providerID, force: true) }
            }
        }
        Button("Customize…") {
            openCustomize(for: providerID)
        }
    }

    /// dashboard에서 해당 provider의 Customize metric(L2)으로 직행 — provider 리스트를 거치지 않음.
    /// 계정 카드는 family 화면으로 — metric 설정은 provider 단위 1벌이라 카드별 화면이 없음.
    private func openCustomize(for providerID: String) {
        withAnimation(Motion.modeSwitch) {
            layout.customizeProviderID = ProviderAccountID.family(of: providerID)
            layout.isEditing = true
        }
    }

    private func providerDragGesture(for group: ProviderGroup) -> some Gesture {
        reorderDragGesture(
            id: group.provider.id,
            coordinateSpaceName: reorderSpaceName,
            rowFrames: rowFrames,
            active: $activeProviderID,
            lift: $reorderLift,
            makeLift: { makeProviderLift(for: group, value: $0) },
            orderedIDs: { layout.displayGroups.map(\.provider.id) },
            reorder: { layout.reorderProvider(dragged: group.provider.id, target: $0) }
        )
    }

    private func metricDragGesture(for descriptor: WidgetDescriptor, providerID: String) -> some Gesture {
        reorderDragGesture(
            id: descriptor.id,
            coordinateSpaceName: reorderSpaceName,
            rowFrames: rowFrames,
            active: $activeMetricID,
            lift: $reorderLift,
            makeLift: { makeMetricLift(for: descriptor, value: $0) },
            orderedIDs: { metricTargetIDs(for: providerID) },
            reorder: { target in
                let current = metricTargetIDs(for: providerID)
                if current.contains(expandedDividerID(for: providerID)) {
                    guard let next = LayoutStore.reordered(current, dragged: descriptor.id, target: target) else {
                        return false
                    }
                    return layout.applyMetricDividerOrder(
                        next,
                        dragged: descriptor.id,
                        dividerID: expandedDividerID(for: providerID),
                        in: providerID
                    )
                }
                return layout.reorderMetric(dragged: descriptor.id, target: target, in: providerID)
            }
        )
    }

    private func metricTargetIDs(for providerID: String) -> [String] {
        guard let group = layout.displayGroups.first(where: { $0.provider.id == providerID }) else {
            return []
        }
        let alwaysShown = group.alwaysShownWidgets.compactMap { layout.descriptor(for: $0)?.id }
        // caret은 expanded section이 열려 있으면(links-only 포함) drop target — metric을 caret 아래로 끌어 내릴 수 있음.
        let hasExpandedContent = group.hasExpandedMetrics || !group.provider.visibleLinks.isEmpty
        guard hasExpandedContent, layout.isProviderExpanded(providerID) else { return alwaysShown }
        let expanded = group.expandedWidgets.compactMap { layout.descriptor(for: $0)?.id }
        return alwaysShown + [expandedDividerID(for: providerID)] + expanded
    }

    private func makeProviderLift(for group: ProviderGroup, value: DragGesture.Value) -> ReorderLift? {
        // floating preview는 카드 표시와 일치 — caret이 열려 있지 않으면 always-shown 행만.
        let visibleWidgets = layout.isProviderExpanded(group.provider.id) ? group.widgets : group.alwaysShownWidgets
        let rows = visibleWidgets.compactMap { widget -> WidgetData? in
            guard let descriptor = layout.descriptor(for: widget) else { return nil }
            return dataStore.data(for: descriptor)
        }
        return ReorderLift.make(
            id: group.provider.id,
            payload: .dashboardProvider(
                provider: group.provider,
                plan: dataStore.plan(for: group.provider.id),
                rows: rows
            ),
            value: value,
            frames: rowFrames
        )
    }

    private func makeMetricLift(for descriptor: WidgetDescriptor, value: DragGesture.Value) -> ReorderLift? {
        ReorderLift.make(
            id: descriptor.id,
            payload: .dashboardMetric(data: dataStore.data(for: descriptor)),
            value: value,
            frames: rowFrames
        )
    }
}
