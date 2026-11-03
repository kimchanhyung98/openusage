import SwiftUI

/// 예약 Sparkle 체크가 새 버전을 발견한 동안 노출되는 대시보드 상단 업데이트 배너.
/// 닫기는 snooze — 다음 예약 체크에서 재표시.
struct UpdateBannerCard: View {
    @Environment(UpdaterController.self) private var updater
    /// 발견된 업데이트의 표시 버전 (예: "0.8.1").
    let version: String

    var body: some View {
        DismissableHintCard(
            systemImage: "arrow.down.circle",
            title: L10n.dashboard("Update Available"),
            message: L10n.dashboard("OpenUsage %@ is ready to download.", version),
            buttonTitle: L10n.dashboard("Install Update"),
            action: { updater.installAvailableUpdate() },
            onDismiss: { withAnimation(Motion.spring) { updater.dismissAvailableUpdate() } }
        )
    }
}
