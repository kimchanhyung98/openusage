import SwiftUI

/// 대시보드 헤더 공용 스크린샷 복사 버튼. 복사 성공 시 체크마크 피드백 후 복귀.
/// `action`이 false 반환 시 피드백 생략.
struct CopyFeedbackButton: View {
    let accessibilityLabel: String
    var isRevealed = true
    let action: () -> Bool

    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button {
            guard action() else { return }

            withAnimation(Motion.spring) { copied = true }
            resetTask?.cancel()
            resetTask = Task {
                try? await Task.sleep(for: .seconds(1.4))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.18)) { copied = false }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(copied ? Color.green : Color.secondary)
                .symbolEffect(.bounce, value: copied)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 음수 padding으로 28pt 히트 영역을 두면서 헤더의 16pt 레이아웃 슬롯 유지
        .padding(-6)
        .opacity(isRevealed || copied ? 1 : 0)
        .allowsHitTesting(isRevealed || copied)
        .animation(.easeOut(duration: 0.12), value: isRevealed)
        .accessibilityLabel(accessibilityLabel)
        .onDisappear {
            resetTask?.cancel()
            resetTask = nil
        }
    }
}
