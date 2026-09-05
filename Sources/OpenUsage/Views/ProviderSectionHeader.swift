import SwiftUI

/// 대시보드·프로바이더 재정렬 프리뷰가 공유하는 프로바이더 섹션 헤더.
/// 선택 요소: 호버 노출 스크린샷 복사, `warning`(최근 refresh 오류 삼각형), `staleness`("Outdated" 태그).
struct ProviderSectionHeader: View {
    let provider: Provider
    var title: String?
    var plan: String?
    var warning: String?
    var refreshing: Bool = false
    /// 신선도 창을 넘긴 스냅샷의 "Outdated" 힌트 (대시보드 전용, 프리뷰는 `nil`). 정확한 경과는 tooltip.
    var staleness: StalenessHint?
    var onCopyScreenshot: (() -> Bool)?
    /// 계정 선택지 — selector는 대시보드 사용량 뷰만 변경.
    var accountOptions: [AccountUsageOption] = []
    var selectedAccountID: String?
    var onSelectAccount: ((String) -> Void)?
    /// 프로바이더 패밀리의 계정 수 — 공유 config home 사용 시 런타임 카드 수 초과 가능.
    var accountCount = 0

    @AppStorage(DensitySetting.key) private var density = DensitySetting.defaultValue
    /// 카드 rename 반영용 — `Provider` 자체 이름은 launch 시 고정.
    @Environment(AppContainer.self) private var container
    @Environment(\.popoverPartyMode) private var partyMode
    @State private var isHovered = false

    init(
        provider: Provider,
        title: String? = nil,
        plan: String? = nil,
        warning: String? = nil,
        refreshing: Bool = false,
        staleness: StalenessHint? = nil,
        onCopyScreenshot: (() -> Bool)? = nil,
        accountOptions: [AccountUsageOption] = [],
        selectedAccountID: String? = nil,
        onSelectAccount: ((String) -> Void)? = nil,
        accountCount: Int = 0
    ) {
        self.provider = provider
        self.title = title
        self.plan = plan
        self.warning = warning
        self.refreshing = refreshing
        self.staleness = staleness
        self.onCopyScreenshot = onCopyScreenshot
        self.accountOptions = accountOptions
        self.selectedAccountID = selectedAccountID
        self.onSelectAccount = onSelectAccount
        self.accountCount = accountCount
    }

    var body: some View {
        HStack(spacing: 5) {
            // 프로바이더 마크가 시각적 drag grip 대체 — 재정렬은 호출자 소유, 로고는 표시 전용
            ProviderIcon(source: provider.icon, inset: 0.04)
                .frame(width: density.headerIconSize, height: density.headerIconSize)
                .partyPulse(partyMode)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                // 폭 압박 시 우선순위 낮은 stale 태그부터 truncate — 이름의 2줄 래핑 방지
                Text(title ?? container.displayName(for: provider))
                    .font(.system(size: density.headerPointSize, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let plan {
                    ProviderPlanBadge(plan: plan)
                        .layoutPriority(1)
                }
                // refresh 진행 중엔 숨김 — 스피너가 이미 작업 중 신호
                if let staleness, !refreshing {
                    Text(staleness.label)
                        .font(.system(size: density.planBadgePointSize))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .hoverTooltip(staleness.tooltip)
                }
            }
            if refreshing {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel("Refreshing")
            } else if let warning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.notice)
                    .hoverTooltip(warning)
                    .accessibilityLabel(warning)
            }
            Spacer(minLength: 8)
            if let onCopyScreenshot {
                CopyFeedbackButton(
                    accessibilityLabel: "Copy \(title ?? container.displayName(for: provider)) Screenshot",
                    isRevealed: isHovered,
                    action: onCopyScreenshot
                )
            }
            if Self.shouldShowAccountPicker(
                accountCount: accountCount,
                runtimeOptionCount: accountOptions.count
            ),
               let selectedAccountID,
               let onSelectAccount {
                AccountUsagePicker(
                    options: accountOptions,
                    selectedID: selectedAccountID,
                    onSelect: onSelectAccount
                )
            }
        }
        .padding(.leading, 2)
        .padding(.trailing, 4)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

extension ProviderSectionHeader {
    /// 계정이 둘 이상이면 selector 노출 — 공유 config home 때문에 런타임 카드가 하나로 접힌 경우도 포함.
    static func shouldShowAccountPicker(accountCount: Int, runtimeOptionCount: Int) -> Bool {
        accountCount > 1 && runtimeOptionCount > 0
    }
}

/// 관리 계정 selector의 선택지 항목.
struct AccountUsageOption: Identifiable, Hashable {
    let id: String
    let title: String
}

private struct AccountUsagePicker: View {
    let options: [AccountUsageOption]
    let selectedID: String
    let onSelect: (String) -> Void

    private var selectedTitle: String {
        options.first(where: { $0.id == selectedID })?.title ?? "Account"
    }

    var body: some View {
        Menu {
            ForEach(options) { option in
                Button {
                    onSelect(option.id)
                } label: {
                    if option.id == selectedID {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(selectedTitle)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("Usage Account")
        .accessibilityValue(selectedTitle)
    }
}

struct ProviderPlanBadge: View {
    let plan: String

    @AppStorage(DensitySetting.key) private var density = DensitySetting.defaultValue

    var body: some View {
        Text(plan)
            .font(.system(size: density.planBadgePointSize))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

struct ReorderGrip: View {
    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(width: 16, height: 22)
            .contentShape(Rectangle())
    }
}
