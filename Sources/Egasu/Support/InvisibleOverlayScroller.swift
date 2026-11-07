import SwiftUI
import AppKit

extension View {
    /// scroll edge effect를 유지한 채 감싸는 `NSScrollView`의 scrollbar 숨김 — `ScrollView` 내부 콘텐츠에 적용.
    /// `.scrollIndicators(.hidden)`은 scroller 제거로 edge effect까지 없애므로 기존 overlay scroller의 alpha만 0으로 설정.
    /// `verticalScroller` 교체 금지 — custom `NSScroller` 할당은 legacy 스타일 전환으로 ~17pt gutter를 예약함.
    func invisibleOverlayScroller() -> some View {
        background(InvisibleOverlayScroller())
    }
}

/// 감싸는 `NSScrollView`의 overlay scroller 투명화.
/// 시스템 scroller 스타일 변경 시 재적용 — AppKit이 scroller를 재생성하며 alpha를 리셋할 수 있음.
private struct InvisibleOverlayScroller: NSViewRepresentable {
    func makeNSView(context: Context) -> ScrollerView { ScrollerView() }

    func updateNSView(_ nsView: ScrollerView, context: Context) {
        nsView.apply()
    }

    final class ScrollerView: NSView {
        private var styleObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let styleObserver {
                NotificationCenter.default.removeObserver(styleObserver)
                self.styleObserver = nil
            }
            guard window != nil else { return }
            apply()
            // `enclosingScrollView`는 현재 layout pass가 commit되기 전까지 연결되지 않을 수 있음.
            DispatchQueue.main.async { [weak self] in self?.apply() }
            styleObserver = NotificationCenter.default.addObserver(
                forName: NSScroller.preferredScrollerStyleDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply() }
            }
        }

        /// 멱등 — `updateNSView`와 스타일 변경 observer에서 반복 호출 가능.
        func apply() {
            guard let scrollView = enclosingScrollView else { return }
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            scrollView.scrollerStyle = .overlay
            scrollView.verticalScroller?.alphaValue = 0
        }
    }
}
