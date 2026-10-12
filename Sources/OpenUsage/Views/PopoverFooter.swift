import SwiftUI

/// 고정 팝오버 푸터 chrome: 앱 정보, 리프레시 상태, 대시보드 액션, 복사 확인.
/// 슬라이드 중 양쪽 페이지가 같은 푸터를 그리도록 목적지 screen 기준 렌더링.
struct PopoverFooter: View {
    @Environment(AppContainer.self) private var container

    let screen: PopoverScreen
    let layout: LayoutStore
    let dataStore: WidgetDataStore
    let horizontalPadding: CGFloat
    let onHeightChange: (PopoverScreen, CGFloat) -> Void

    @ViewBuilder
    var body: some View {
        Group {
            if screen == .customize {
                EmptyView()
            } else {
                HStack(alignment: .center, spacing: 8) {
                    footerIdentity
                    Spacer(minLength: 8)
                    HeaderView(screen: screen)
                }
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .barGlass()
        .onGeometryChange(for: CGFloat.self) { proxy in proxy.size.height } action: { height in
            onHeightChange(screen, height)
        }
        .overlay(alignment: .top) {
            if screen == .dashboard, layout.shareConfirmation {
                shareCopiedPill
                    .offset(y: -34)
            }
        }
        .animation(Motion.spring, value: layout.shareConfirmation)
        .animation(Motion.spring, value: layout.shareConfirmationTrigger)
    }

    private var shareCopiedPill: some View {
        TransientPill(
            systemImage: "checkmark.circle.fill",
            text: "Copied to clipboard",
            tint: Theme.positive,
            trigger: layout.shareConfirmationTrigger
        )
    }

    private var footerIdentity: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("OpenUsage \(AppInfo.version)")
            if let notice = layout.pinLimitNotice {
                Text(notice)
                    .foregroundStyle(Theme.notice)
                    .denyShake(trigger: layout.pinNoticeShakeTrigger, shakeOnAppear: true)
            } else {
                nextUpdateButton
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .animation(Motion.spring, value: layout.pinLimitNotice)
    }

    private var nextUpdateButton: some View {
        Button {
            refreshNow()
        } label: {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 5) {
                    VStack(alignment: .leading, spacing: 2) {
                        if isUpdating { Text("Updating…") }
                        let rows = refreshScheduleRows(now: context.date)
                        ForEach(rows) { row in
                            Text(row.text(at: context.date))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                        }
                        if rows.isEmpty && !isUpdating { Text("Refresh Now") }
                    }
                    if isUpdating {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("r", modifiers: .command)
        .hoverTooltip("Refresh now (⌘R)")
        .disabled(isUpdating)
    }

    private var isUpdating: Bool {
        container.isRefreshingAll || !dataStore.refreshingProviderIDs.isEmpty
            || container.resetWatchCoordinator.isRefreshing
    }

    private func refreshNow() {
        guard !isUpdating else { return }
        Task { await container.refreshAll(force: true) }
    }

    private func refreshScheduleRows(now: Date) -> [RefreshSchedulePresentation.Row] {
        let enabled = dataStore.knownProviderIDs.filter { container.enablement.isEnabled($0) }
        let claudeIDs = enabled.filter { RefreshSetting.cadence(for: $0) == .claude }
        let waiting = claudeIDs.filter { (dataStore.snapshots[$0]?.usageRetryAfter ?? .distantPast) > now }
        let regularClaude = claudeIDs.filter { !waiting.contains($0) }
        return RefreshSchedulePresentation.rows(
            general: enabled.isEmpty ? nil : dataStore.nextGeneralRefreshAt,
            claude: regularClaude.compactMap { dataStore.scheduledRefreshDate(for: $0) }.min(),
            claudeRetry: waiting.compactMap { dataStore.scheduledRefreshDate(for: $0) }.min(),
            resetWatch: container.resetWatchCoordinator.isActive
                ? container.resetWatchCoordinator.nextRefreshAt : nil,
            codexTimer: enabled.contains { ProviderAccountID.family(of: $0) == "codex" }
                ? container.nextCodexTimerCheckAt : nil
        )
    }
}
