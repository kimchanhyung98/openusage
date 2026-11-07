import SwiftUI

/// 자동 소멸형 확인/알림 캡슐 (공유 "Copied" 필, Customize 액션 알림 공용).
struct TransientPill: View {
    let systemImage: String
    let text: String
    let tint: AnyShapeStyle
    /// 재표시마다 caller가 증가시키는 카운터. `.id` 변경으로 transition 재생.
    let trigger: Int
    var showsShadow = true

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(showsShadow ? 0.12 : 0), radius: 6, y: 2)
        .id(trigger)
        .transition(.scale(scale: 0.85).combined(with: .opacity))
    }
}
