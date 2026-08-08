import SwiftUI

/// 대시보드 전용 스크롤 콘텐츠.
/// 화면 전환·패널 크기·고정 바·키보드·닫기 처리는 `DashboardView` 소관.
struct DashboardContentView: View {
    let container: AppContainer
    let layout: LayoutStore
    let updater: UpdaterController
    let reorderSpaceName: String
    let horizontalPadding: CGFloat
    let bottomGap: CGFloat

    @Binding var reorderLift: ReorderLift?
    @Binding var scrollPosition: ScrollPosition

    @AppStorage(DensitySetting.key) private var density = DensitySetting.defaultValue
    @AppStorage(TotalSpendSetting.key) private var showTotalSpend = true

    var body: some View {
        PopoverScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let updateVersion = updater.availableUpdateVersion {
                    UpdateBannerCard(version: updateVersion)
                        .padding(.bottom, density.sectionSpacing)
                        .transition(.scale(scale: 0.95).combined(with: .opacity))
                }
                if container.onboarding.isCustomizeHintPending {
                    CustomizeHintCard()
                        .padding(.bottom, density.sectionSpacing)
                        .transition(.scale(scale: 0.95).combined(with: .opacity))
                }
                widgetContent
            }
            .animation(Motion.spring, value: container.onboarding.isCustomizeHintPending)
            .animation(Motion.spring, value: updater.availableUpdateVersion)
            .padding(.horizontal, horizontalPadding)
            .padding(.top, density.contentTopPadding)
            .padding(.bottom, bottomGap)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollPosition($scrollPosition)
    }

    @ViewBuilder
    private var widgetContent: some View {
        // Total Spend 링은 데이터 도착 전이나 모든 메트릭 행이 숨겨진 상태에서도 유지
        if showTotalSpend, layout.hasSpendCapableProvider {
            TotalSpendCard()
                .padding(.bottom, density.sectionSpacing)
        }
        if layout.displayGroups.isEmpty {
            Text("Turn on Customize to choose what to show.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .padding(.horizontal, 16)
        } else {
            WidgetGroupedListView(
                reorderSpaceName: reorderSpaceName,
                reorderLift: $reorderLift
            )
        }
    }
}
