import SwiftUI
import os

/// 호스트 패널 높이를 SwiftUI 애니메이션 클록 단일 클록으로 구동 — AppKit `setFrame` 애니메이션과의 이중 클록 충돌 제거.
/// `animatableData` setter가 프레임마다 보간 높이를 `PanelHeightBridge`로 전달, 높이 0은 "미확정" sentinel로 스킵.
/// `ViewModifier` 대신 `GeometryEffect` 채택 — `body` 구현 시 `@MainActor` 추론으로 `Animatable`의 nonisolated 요구 위반.
struct PanelHeightModifier: GeometryEffect {
    var height: CGFloat

    var animatableData: CGFloat {
        get { height }
        set {
            height = newValue
            PanelHeightBridge.push(newValue)
        }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        PanelHeightBridge.push(height)
        return ProjectionTransform()
    }
}

/// nonisolated `Animatable` setter에서 `@MainActor` 패널 브리지로 보간 높이 전달.
/// main queue hop 필수 — SwiftUI 업데이트 패스 중 동기 `setFrame`은 `_NSDetectedLayoutRecursion` 유발.
/// 버스트는 최신 pending 높이로 병합 — stale 애니메이션 프레임 재생 방지.
enum PanelHeightBridge {
    private struct State {
        var generation = 0
        var pendingHeight: CGFloat?
        var isScheduled = false
    }

    /// 패널 open/close마다 generation 증가 — 예약 시점과 실행 시점이 다르면 stale 높이 폐기.
    /// nonisolated `push`와 main-actor `invalidate`의 동시 접근 대비 `OSAllocatedUnfairLock` 사용.
    private static let state = OSAllocatedUnfairLock(initialState: State())

    /// 진행 중인 모든 높이 무효화. 패널 open/close 시 호출 필수.
    nonisolated static func invalidate() {
        state.withLock {
            $0.generation += 1
            $0.pendingHeight = nil
            $0.isScheduled = false
        }
    }

    nonisolated static func push(_ height: CGFloat) {
        guard height > 0 else { return }
        let (scheduled, shouldSchedule) = state.withLock { state in
            state.pendingHeight = height
            let scheduled = state.generation
            guard !state.isScheduled else { return (scheduled, false) }
            state.isScheduled = true
            return (scheduled, true)
        }
        guard shouldSchedule else { return }
        DispatchQueue.main.async {
            let height = state.withLock { state -> CGFloat? in
                guard state.generation == scheduled else { return nil }
                let height = state.pendingHeight
                state.pendingHeight = nil
                state.isScheduled = false
                return height
            }
            guard let height else { return }
            MainActor.assumeIsolated {
                MenuBarPopover.applyHeight?(height)
            }
        }
    }
}

extension View {
    /// 메뉴바 패널이 `height`를 SwiftUI 애니메이션 클록으로 추종하도록 설정.
    /// body 루트, `.animation(nil, …)` 스코프 밖 부착 필수.
    func drivesPanelHeight(_ height: CGFloat) -> some View {
        modifier(PanelHeightModifier(height: height))
    }
}
