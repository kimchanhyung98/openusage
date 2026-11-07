import SwiftUI

/// 팝오버 3개 전체 화면이 공유하는 스크롤 컨테이너 — 콘텐츠 고유 높이를 `ScrollContentHeightKey`로 발행.
/// scroll edge effect 유지를 위해 SwiftUI식 indicator 숨김 대신 `invisibleOverlayScroller()` 사용.
/// 측정 높이는 viewport와 무관한 고유 높이 — auto-fit 피드백 루프 방지.
struct PopoverScrollView<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.vertical) {
            content
                .invisibleOverlayScroller()
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: ScrollContentHeightKey.self, value: proxy.size.height)
                    }
                )
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// `PopoverScrollView`가 발행하는 화면 스크롤 콘텐츠의 고유 높이.
/// 화면 서브트리당 emitter 1개 — reduce는 최근 non-zero 값만 유지.
struct ScrollContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}
