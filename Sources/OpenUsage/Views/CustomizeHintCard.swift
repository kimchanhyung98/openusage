import SwiftUI

/// 신규 설치 첫 실행 시 대시보드 상단에 노출되는 Customize 안내 카드.
/// `OnboardingStore.isCustomizeHintPending`이 설정된 동안만 표시, 닫기 버튼으로만 영구 해제.
/// Customize 화면 방문만으로는 해제되지 않음.
struct CustomizeHintCard: View {
    @Environment(AppContainer.self) private var container
    @Environment(LayoutStore.self) private var layout

    var body: some View {
        DismissableHintCard(
            systemImage: "slider.horizontal.3",
            title: "Welcome to OpenUsage",
            message: "We set you up with the AI tools found on your Mac. Add or hide providers any time.",
            buttonTitle: "Open Customize",
            action: { withAnimation(Motion.modeSwitch) { layout.screen = .customize } },
            onDismiss: { withAnimation(Motion.spring) { container.onboarding.dismissCustomizeHint() } }
        )
    }
}
