import SwiftUI

/// 호버 팝오버(모델 분해, 사용 추세)가 공유하는 중앙 정렬 source-note 푸터.
struct PopoverSourceNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }
}
