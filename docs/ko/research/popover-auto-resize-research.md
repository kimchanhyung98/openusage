# 커스텀 메뉴 막대 패널의 부드러운 콘텐츠 기반 자동 크기 조절

> **과거 기록 / 대체됨.**
> 이 2026-06-25 연구는 같은 날 뒤이어 출시되고 이후 계속 다듬어진 조율된 콘텐츠 기반 패널 크기 조절에 앞선 내용.
> 현재 구현은 [AppKit 브리지](/docs/ko/architecture.md#appkit-브리지), [`DashboardView.swift`](../../../Sources/OpenUsage/Views/DashboardView.swift), [`PanelHeightCoordinator.swift`](../../../Sources/OpenUsage/Views/PanelHeightCoordinator.swift), [`PanelHeightController.swift`](../../../Sources/OpenUsage/App/PanelHeightController.swift) 참조.
> 아래의 기각된 접근 방식과 제안 파일 구성은 현재 설정 지침이 아닌 과거 연구 기록으로 보존.

**연구 보고서 — 2026-06-25**
**질문:** OpenUsage가 키보드 단축키를 위해 커스텀 `NSPanel`을 유지해야 하는 조건에서, 실제 macOS 앱이 (a) 크기 조절 지연·끊김과 (b) 화면 슬라이드와 윈도우 크기 조절 동시 실행 시 발생하는 "대각선" 움직임 없이 *커스텀 키보드 지원* 팝오버를 콘텐츠에 맞춰 부드럽게 자동 조절하는 방법은 무엇인가?

---

## 요약

두 문제의 **근본 원인은 하나, 서로 충돌하는 두 애니메이션 타이밍.**
콘텐츠와 슬라이드는 SwiftUI 엔진이 애니메이션하고, 윈도우 프레임은 AppKit이 애니메이션한 구조(`KVO(preferredContentSize) → animated setFrame`).
서로 다른 곡선을 따르는 두 독립 타임라인이 약간 다른 시점에 시작하면서 끊김(두 타이밍의 프레임별 불일치)과 "대각선" 움직임(수평 SwiftUI 곡선과 수직 AppKit 곡선의 합성) 발생.

해결책은 더 나은 AppKit 크기 조절 애니메이션이 아니라 **윈도우를 SwiftUI가 소유한 단일 높이 값의 수동적 추종자로 만드는 것.**
어려운 핵심은 이미 작동 중: SwiftUI `DragGesture`의 높이 흐름을 프레임마다 `setFrame(display:false)`에 동기 전달해 매우 부드럽게 작동하는 드래그 크기 조절.
손가락 대신 SwiftUI *애니메이션 엔진*의 보간 값에서 높이 흐름을 가져오도록 **동일한 경로의 일반화** 권장.
타이밍이 하나뿐이므로 충돌 불가.

실제 앱 조사로 확인한 **기성 API가 없는** 까다로운 문제: 완성도 높은 SwiftUI 메뉴 막대 앱 **FontSwitch**도 동일한 `canBecomeKey` 패널을 사용하면서 자동 맞춤을 포기하고 *고정* 크기로 출시 [16], 경쟁 앱 **Claude-Usage-Tracker**는 네이티브 크기 조절을 제공하는 `animates` 속성 [13]의 `NSPopover`를 사용해야만 부드러운 자동 크기 조절을 확보하는 대신 "not legal to call `-layoutSubtreeIfNeeded` on a view which is already being laid out" 재귀 경고 발생 [9].
`LSUIElement` 앱에서 macOS 26+부터 윈도우가 안정적으로 key가 되지 않아 Esc/Return/⌘R과 기록기가 깨진다는 문서화된 이유로 계속 제외되는 `NSPopover`.
따라서 패널용 부드러운 크기 조절 기능을 직접 구현해야 하며, 드래그용 구현은 이미 존재.

**권장 사항:** `MenuBarPanel` 유지, 사용자가 원하지 않았던 수동 드래그 크기 조절 모델 삭제, 자동 맞춤을 *단일 타이밍 추종자*로 복원 — `onGeometryChange`로 콘텐츠의 이상적인 높이를 측정하고 기존 동기 브리지를 통해 패널에 전달하며, 화면 전환 높이 변경을 슬라이드를 구동하는 **같은** `withAnimation` 안에서 처리하는 조정된 "모프" 방식과 보수적 대안인 `withAnimation(completionCriteria:completion:)` 기반 순차 크기 조절.
둘 다 최소 지원 범위에 포함되는 macOS 15+ API.

---

## 1. 이 조합이 특히 어려운 이유 (현황)

SwiftUI 메뉴 막대 표면의 실현 가능한 형태는 세 가지이며, 각 앱은 *키보드 key 윈도우*, *부드러운 네이티브 콘텐츠 크기 조절*, *커스텀 크기 조절 코드 없음* 중 두 가지 선택:

- **`NSPopover`**는 별도 구현 없이 부드러운 네이티브 콘텐츠 크기 조절 제공: "Changes to the content size of the popover will cause the popover to animate while it is shown if the `animates` property is YES" [13][12].
  다만 전체 앱이 활성화된 동안에만 윈도우가 key 상태이며, `LSUIElement` 앱 활성화는 비동기적이거나 macOS 26+에서 거부되므로 키 입력이 상태 항목 버튼으로 전달 — OpenUsage가 포기한 문서화된 이유.
  이 절충안을 받아들인 앱에도 문제 존재: 레이아웃 패스 중 `NSHostingController` 생성, 레이아웃 도중 `withAnimation` 변경, `GeometryReader`+`.animation` 충돌, 고정 `contentSize`와 동적 SwiftUI 콘텐츠 간 충돌로 레이아웃 재귀 경고가 발생하는 Claude-Usage-Tracker의 NSPopover+SwiftUI 통합 [9].

- **커스텀 `NSPanel`(`canBecomeKey = true`, `.nonactivatingPanel`)**은 앱 활성화 없이 실제 key 윈도우를 제공하므로 첫 시도부터 키보드 작동.
  OpenUsage가 사용 중인 패널이자 FontSwitch와 동일한 구성("We become key when using the search bar to receive keyboard input" — `FocusablePanel: NSPanel { override var canBecomeKey: Bool { true } }`, 이후 `panel.makeKey()`) [16].
  대가는 `NSPopover.animates` 상실.
  FontSwitch의 해결책은 저장된 `panelSize`로 `panel.setFrame(frame, display: true)`를 호출하는 **고정** 패널 [16] — OpenUsage가 PR #717에서 도달한 지점과 동일.

- **SwiftUI `Window` / `MenuBarExtra(.window)` 장면**은 콘텐츠 크기를 상태에 바인딩하고 `withAnimation`으로 감싸 SwiftUI 레이아웃 엔진이 윈도우를 조절하므로 별도 구현 없이 콘텐츠 자동 맞춤 가능 [6].
  다만 `.window` 스타일도 `NSPopover`와 동일한 비-key 제약이 있으므로 같은 이유로 제외.

**결론:** 별도 구현 없이 함께 얻을 수 없는 "커스텀 key 윈도우 패널"**과** "부드러운 콘텐츠 자동 크기 조절" 조합.
크기 조절 재구현 필요.
이미 부드럽게 작동하는 드래그 기능이 있으므로 처음부터 새로 만드는 작업이 아닌 일반화 작업.

---

## 2. 이전 시도별 근본 원인

기억과 코드에 기록된 다섯 가지 실패 사례.
모두 두 애니메이션 타이밍의 충돌로 설명 가능:

1. **`KVO(preferredContentSize) → setFrame`, "stuttered on every screen switch."**
   `NSHostingController.preferredContentSize`는 SwiftUI의 프레임별 애니메이션 타이밍이 아닌 AppKit 주기로 갱신되는 제약 기반 크기 [2][5].
   이후 윈도우를 *별도의* AppKit 애니메이션으로 처리.
   두 타이밍으로 인한 끊김.
   더 큰 문제는 레이아웃 패스 내부에서 측정과 재레이아웃이 일어나 Claude-Usage-Tracker가 기록한 것과 같은 재귀 함정에 빠진 점 [9].

2. **`animator().setFrame` / `NSAnimationContext` 애니메이션 크기 조절, "janky."**
   `layerContentsRedrawPolicy`가 올바르지 않으면 AppKit의 암시적 레이어 경계 애니메이션이 *캐시된* 레이어 콘텐츠를 늘리고, 레이어에 적합하지 않은 구성은 "animation performance degrades extremely quickly"인 **메인 스레드**의 반복 `-setFrame:` 호출로 구동 [1].
   완벽히 구현해도 SwiftUI 슬라이드와 충돌하는 *두 번째* 타이밍으로 남는 구조.

3. **`setFrame(display:false)`, "instant, no glide."**
   애니메이션 구동기가 없는 단순 `setFrame`의 당연한 결과.
   부드러운 움직임에는 높이를 보간하는 *무언가* 필요.
   올바른 프리미티브는 있었지만 보간된 입력 소스 부재.
   핵심은 프리미티브 고장이 아니라 곡선 대신 계단 함수를 입력한 점.

4. **설정 열기 시 "diagonal".**
   슬라이드는 스프링 기반 SwiftUI `.offset`, 크기 조절은 AppKit `setFrame` 구성.
   한 박자 차이로 시작한 수평 SwiftUI 곡선 × 수직 AppKit 곡선으로 비뚤게 도착하는 대각선 발생.
   두 타이밍 간 간섭 그 자체.

5. **드래그 크기 조절: 부드러움.**
   유일한 성공 사례.
   이유는 무엇인가?
   `DragGesture.onChanged`는 레이아웃 패스 내부가 아닌 *이벤트* 콜백이며, 틱마다 하나의 높이를 `setFrame(display:false)` + `layoutSubtreeIfNeeded()` + `displayIfNeeded()`에 동기 전달.
   손가락이 타이밍 기준이고 윈도우가 정확히 추종.
   **전체 해결책의 기준이 되는 구현.**

---

## 3. 권장 아키텍처: 단일 타이밍 추종자

패널 높이를 *SwiftUI 소유 값의 순수 함수*로 만들고 SwiftUI 애니메이션 엔진만 애니메이션을 담당하도록 구성.
윈도우 자체는 애니메이션하지 않고 SwiftUI가 현재 프레임에 계산한 정확한 크기로 다시 그리기만 수행.

### 3.1 프리미티브 (드래그 일반화)

이미 부드러운 경로를 입증한 드래그:

```swift
// StatusItemController.updateGripResize(by:) — 부드러운 움직임이 검증된 경로
panel.setFrame(rect, display: false)
panel.contentView?.layoutSubtreeIfNeeded()
panel.displayIfNeeded()
```

이 브리지 유지.
손가락의 `MenuBarPopover.resizeBy(translation)` 대신 SwiftUI 보간 값의 `applyHeight(_:)`를 사용하도록 *높이 공급 주체*만 변경.

### 3.2 콘텐츠의 이상적인 높이 측정

피드백 루프 방지를 위해 윈도우의 현재 높이와 무관한 **콘텐츠의 자연 높이** 측정.
단순 `GeometryReader`처럼 레이아웃을 확장하지 않고 지오메트리를 관찰하는 현대적이고 레이아웃 안전한 API는 최소 지원 범위에 포함되는 macOS 15+의 `onGeometryChange` [10][17]:

```swift
// 뷰포트가 아닌 스크롤 콘텐츠(내부 VStack) 측정.
// 이상 높이가 윈도우 높이와 무관해 피드백 루프 방지.
scrollContent
    .onGeometryChange(for: CGFloat.self) { proxy in proxy.size.height }
        action: { ideal in layout.idealHeight[screen] = ideal }
```

너비가 320으로 고정되고 카드가 콘텐츠에 맞춰 크기를 정하므로, 콘텐츠에 *더 많은* 수직 공간을 제공해도 변하지 않는 측정값 — 구조적으로 차단된 루프.
(필요할 경우 macOS 15 이전 대안: `.background(GeometryReader { Color.clear.preference(...) })` [17].)

### 3.3 클램프 + 스크롤 대안 (NSPopover의 최대 contentSize 재구현)

```
target = clamp(idealHeight, minHeight, maxPanelHeight())   // 기존 maxPanelHeight() 재사용
```

`ideal ≤ maxScreen`이면 윈도우가 콘텐츠에 정확히 맞고 `ScrollView`는 비활성.
`ideal > maxScreen`이면 윈도우가 `maxPanelHeight()`에서 제한되고 스크롤 작동 — "if your SwiftUI view requests more space than contentSize allows, the bottom is clipped"처럼 동작하는 `NSPopover.contentSize` [12]와 같지만, 여기서는 잘림 대신 스크롤 사용.
현재의 `maxPanelHeight()`와 상단 고정 방식 유지(origin.y = `anchorTopLeft.y - height`, 상태 항목에서 아래쪽으로 커지는 패널).

### 3.4 SwiftUI 애니메이션 타이밍에서 추종자에 값 공급

핵심 지점.
두 번째 타이밍 없이 계단이 아닌 곡선 형태의 *보간된* 높이를 얻으려면 대상 높이를 SwiftUI가 프레임 애니메이션하는 비용 없는 뷰에 반영하고 진행 중인 값 읽기:

```swift
// 0×target 프로브.
// `withAnimation` 안의 `target` 변경 시 매 렌더링 틱마다 프레임 높이 보간 후 액션 호출.
// 슬라이드와 동일한 타이밍에서 보간 값 전달.
Color.clear
    .frame(height: animatedTarget)
    .onGeometryChange(for: CGFloat.self) { $0.size.height }
        action: { h in MenuBarPopover.applyHeight?(h) }   // → 동기 브리지
```

`applyHeight`에서 패널로 값 전달.
높이가 `animatedTarget`의 SwiftUI 보간에서 나오므로 드래그가 손가락을 추적하듯 윈도우가 SwiftUI의 곡선과 타이밍을 정확히 추적.
불일치할 `NSAnimationContext`, `animator()`, AppKit 타이밍 모두 제거.

> 동등한 방식: 높이를 `animatableData`로 사용하고 setter에서 `applyHeight`를 호출하는 커스텀 `Animatable` modifier — 고전적인 "drive an NSWindow from a SwiftUI animation" 기법.
> 읽기 쉬운 방식을 선택하면 되며, 둘 다 SwiftUI가 단독으로 타이밍 제어.

---

## 4. "대각선" 문제 해결 — 새로 가능해진 두 가지 선택지

윈도우가 수동적 추종자라면 슬라이드와 크기 조절은 더 이상 두 타이밍으로 분리되지 않으며, 함께 움직일지 순서대로 움직일지만 정하는 순수한 *설계* 문제.

**선택지 A — 조정된 모프 (권장).**
`slideProgress`를 구동하는 **동일한 `withAnimation` 안에서** 높이 대상을 목적지 화면의 이상적인 높이로 설정.
두 페이지가 이미 슬라이드 `HStack`에 마운트되어 있어 두 화면의 이상 높이를 모두 아는 상태.
이후 하나의 스프링에서 수평 오프셋과 윈도우 높이가 애니메이션되며, 새 화면이 들어올 때 패널이 커지거나 작아지는 하나의 일관된 *모프* 연출.
기존 "대각선"이 부자연스러웠던 이유는 두 축의 타이밍이 달랐기 때문이며, 하나로 통합하면 시스템 표면의 모프처럼 의도된 움직임으로 표현.
추가 지연 없음.

```swift
withAnimation(Motion.spring) {
    slideProgress = 1
    animatedTarget = idealHeight[destinationScreen] ?? animatedTarget
}
```

**선택지 B — 순차 실행 (보수적 대안).**
최소 지원 범위에 포함되는 macOS 14+ 네이티브 완료 API [14][7][15]로 일정한 높이에서 슬라이드한 뒤 크기 조절:

```swift
withAnimation(.spring, completionCriteria: .removed) {
    slideProgress = 1
} completion: {
    withAnimation { animatedTarget = idealHeight[destinationScreen] ?? animatedTarget }
}
```

슬라이드 도중 잘림 방지를 위해 목적지가 더 크면 슬라이드 *전에* 확대하고, 더 작으면 *후에* 축소.
더 신중하지만 약간 느린 방식으로, 글래스 카드의 모프가 지나치게 복잡할 경우 선택.

**화면 내 콘텐츠 변경**(프로바이더 로드, 행 확장, 지출 행 토글)은 슬라이드 없이 `withAnimation { animatedTarget = newIdeal }`만 필요한 단순한 사례.
추종자가 같은 방식으로 처리하며, 사용자가 실제로 복원을 요청한 자동 크기 조절에 해당.

---

## 5. 파일별 코드 구성안

| 파일 | 변경 |
|---|---|
| `Support/PopoverDismissReader.swift` | `MenuBarPopover` 브리지에 `static var applyHeight: ((CGFloat) -> Void)?` 추가(`beginResize`/`resizeBy`/`dismissHandler`와 동일한 패턴). |
| `App/StatusItemController.swift` | `applyHeight`에서 값을 `maxPanelHeight()`로 제한하고 **기존** 동기 `setFrame(display:false)` 경로 호출(콜백에서 `layoutSubtreeIfNeeded` 강제 호출 제외 — §6 참조).<br>자동 맞춤 출시 후 `PanelHeightStore`/드래그 연결 제거. |
| `Views/DashboardView.swift` | `Color.clear.frame(height:).onGeometryChange` 프로브 또는 `Animatable` modifier 추가.<br>각 화면의 이상 높이를 스크롤 콘텐츠에서 측정.<br>기존 슬라이드 `withAnimation` 안에서 높이 대상 설정(선택지 A) 또는 순차 실행(선택지 B).<br>자동 맞춤 검증 후 `resizeDragger`와 `resizingPanel`/`.frame(maxHeight:.infinity)` 채우기 제거. |
| `Stores/LayoutStore.swift` | `idealHeight: [PopoverScreen: CGFloat]` 보관 또는 `DashboardView`에 간단한 `@State` 두 개 사용. |

이미 정리 대상으로 표시된 약 120줄의 사용하지 않는 자동 크기 조절 코드(`animatedPopoverHeight`, `ScreenHeightReader`, `contentHeight` 바인딩)는 되살리지 않고 삭제 — 더 작고 단일 타이밍으로 통합된 새 경로.

---

## 6. 주의할 함정: 레이아웃 재진입

경쟁 앱의 재귀 경고 *"It's not legal to call `-layoutSubtreeIfNeeded` on a view which is already being laid out"*은 레이아웃 패스 *도중* 레이아웃 작업을 수행해 발생 [9].
SwiftUI 레이아웃 *내부에서* 실행될 수 있는 `onGeometryChange` 액션과 `Animatable` setter.
`DragGesture.onChanged`는 레이아웃 시점이 아닌 이벤트 콜백이므로 동기 `layoutSubtreeIfNeeded()` 호출에도 안전한 드래그 방식.
애니메이션 기반 값 공급 시 안전 수칙:

- `applyHeight`에서 `panel.setFrame(rect, display: false)`를 호출하고 콜백 내부의 `panel.contentView?.layoutSubtreeIfNeeded()` 강제 호출은 **제외**.
  고정 너비와 상단 고정 콘텐츠에서 윈도우 확장은 이미 레이아웃된 콘텐츠를 *드러내는* 작업일 뿐이므로 재레이아웃 불필요하며, 재진입 위험이 있는 동기 레이아웃 호출도 불필요.
  `displayIfNeeded()` 또는 일반 CA 그리기 주기에 렌더링 위임.
- 암시적 `animator()` 애니메이션 없이 *프레임마다 명시적으로* 윈도우 경계를 설정해 Core Animation이 오래된 캐시 레이어를 늘리지 않도록 구성 [1] — 각 프레임의 레이어가 이미 올바른 크기와 콘텐츠 보유.
- 크기 조절이나 레이아웃 중 `NSHostingController` 지연 생성 금지 — 시작 시 한 번만 생성하는 현재 방식 유지 [9].
- 프레임 변경이 다른 변경을 재귀적으로 유발하지 않도록 `applyHeight`를 재진입 플래그 `isApplyingHeight`로 보호.

---

## 7. 검토 후 기각한 대안

- **별도 구현 없는 부드러운 크기 조절을 위해 `NSPopover`로 복귀.**
  기각: `LSUIElement` 앱에서 macOS 26+부터 윈도우가 안정적으로 key 상태가 되지 않아 키보드가 깨지는 문서화된 근본 원인 — `MenuBarPanel`이 존재하는 이유.
  자체 레이아웃 재귀 문제도 유발하는 NSPopover+SwiftUI [9].
  키보드를 양보할 수 없으므로 NSPopover 사용 불가.

- **AppKit Core Animation 크기 조절(`NSAnimationContext` + `animator().setFrame`, `layerContentsRedrawPolicy = .onSetNeedsDisplay`).**
  단독으로는 부드럽게 구현 *가능* [1]하나 SwiftUI 스프링과 곡선을 맞출 수 없는 두 번째 타이밍이므로 대각선 문제 재발.
  슬라이드까지 AppKit에서 구동할 경우에만 가능하지만 원하지 않는 구성.
  단일 SwiftUI 타이밍을 위해 기각.

- **수동 드래그 핸들 유지.**
  사용자가 원하지 않았고 자동 맞춤 복원 후 중복이므로 기각.
  (향후 "최대 높이 고정" 고급 옵션에서 브리지를 재사용할 수 있지만 핵심 요구에는 불필요.)

- **별도 구현 없는 자동 크기 조절을 위한 `MenuBarExtra(.window)` / SwiftUI `Window` 장면** [6].
  NSPopover와 동일한 비-key 키보드 제약으로 기각.

---

## 8. 검증 계획

여기서는 팝오버를 자동으로 열거나 캡처할 수 없으므로 직접 확인이 필요하되, 객관적 기준 사용:

1. **화면 내 크기 조절**(대시보드에서 프로바이더의 지출 행 전환): 패널이 한 번의 부드러운 움직임으로 확대·축소되고 상단 가장자리가 고정되며, 카드 늘어남이나 한 프레임 잘림 없음.
2. **화면 전환**(대시보드 → 더 높은 설정 화면): 선택지 A에서는 슬라이드와 확대가 단일 모프로 표현되고, 선택지 B에서는 깔끔한 두 단계로 표현.
   대각선과 흔들림 없음.
3. **화면 높이 상한**(매우 긴 콘텐츠 또는 짧은 디스플레이): 윈도우가 `maxPanelHeight()`에서 제한되고 내부 `ScrollView`가 레이아웃 충돌 없이 작동.
4. **재진입:** Xcode/Console에서 실행하고 화면을 빠르게 반복 전환하는 동안 "not legal to call `-layoutSubtreeIfNeeded`…" 경고가 **0건**인지 확인 [9].
5. **글래스:** 크기 조절 중 `.quaternary` 카드의 흰색 깜빡임 없음 — 크기 조절은 불투명도 변경 없는 순수 경계 변경이므로 기존의 전환이 아닌 오프셋 규칙 유지.
6. AGENTS.md에 따라 적절한 회귀 테스트 추가: `applyHeight`가 `[minHeight, maxPanelHeight()]`로 제한되는지, 상한 아래에서 높이 대상이 측정한 이상 값과 같은지 검증.

---

## 9. 한계와 주의 사항

실제 코드를 소스 탐색으로 분석한 결과와 권위 있는 AppKit/SwiftUI 문서, 1차 출처 개발자 블로그, 직접 유사한 오픈 소스 앱 두 개를 바탕으로 한 보고서.
SwiftUI 보간 값을 동기 `setFrame` 브리지에 공급하면 드래그만큼 부드러울 것이라는 핵심 주장은 (a) 동일한 브리지에서 이미 부드럽게 작동하는 드래그와 (b) 단일 타이밍 원칙에 따른 강한 추론이며, 측정 결과가 **아니므로** 기기 검증 필요(§8).
재진입 완화(§6)가 가장 위험한 세부 사항: 콜백에서 동기 `layoutSubtreeIfNeeded`를 제거한 뒤 빠른 애니메이션 중 눈에 띄는 한 프레임 콘텐츠 지연이 발생한다면, 플래그로 재진입을 막으면서 호출을 유지하거나 레이아웃 패스 밖으로 전달하는 대안 필요 — 약간의 복잡성 증가.
애니메이션 중 `onGeometryChange`의 정확한 호출 주기는 공식 문서에 없으며 [10][17], 너무 성기다면 `Animatable` modifier 방식으로 프레임에 고정된 갱신 가능.
어느 경우에도 아키텍처는 그대로이며 조정 지점만 변경.

---

## 참고 문헌

[1] Jonathan Willing. "A short guide to OS X animations." — `layerContentsRedrawPolicy`(`NSViewLayerContentsRedrawDuringViewResize`와 `OnSetNeedsDisplay`); 메인 스레드 `-setFrame:` 성능 저하; 백그라운드 스레드의 CA.

[2] Apple. "setFrame(_:display:animate:) — NSWindow." https://developer.apple.com/documentation/appkit/nswindow/1419519-setframe

[3] Jonathan Willing. "JNWAnimatableWindow." — 레이어 기반 NSWindow 애니메이션.

[4] Apple. "sizingOptions — NSHostingController." https://developer.apple.com/documentation/swiftui/nshostingcontroller/sizingoptions

[5] Apple. "preferredContentSize — NSHostingController." https://developer.apple.com/documentation/swiftui/nshostingcontroller/preferredcontentsize

[6] Itsuki. "SwiftUI/MacOS: Auto Window/Panel Resizing Based on Some State."

[7] Antoine van der Lee. "withAnimation completion callback with animatable modifiers."

[8] Michael Tsai(Brian Webster 인용). "How NSHostingView Determines Its Sizing."

[9] hamed-elfayome / Claude-Usage-Tracker, Discussion #64. "Fix: Layout recursion warning in NSPopover/SwiftUI integration." — `-layoutSubtreeIfNeeded` 재진입; 레이아웃 도중 NSHostingController 생성; 패스 도중 `withAnimation`; GeometryReader+`.animation`; 고정 `contentSize`와 동적 콘텐츠.

[10] Fatbobman. "4 Ways to Get View Size in SwiftUI: From GeometryReader to onGeometryChange."

[11] Apple. "NSPopover." https://developer.apple.com/documentation/appkit/nspopover

[12] Apple. "contentSize — NSPopover." https://developer.apple.com/documentation/appkit/nspopover/1524677-contentsize

[13] Apple. "animates — NSPopover." https://developer.apple.com/documentation/appkit/nspopover/1526527-animates — `animates`가 YES일 때 표시 중인 콘텐츠 크기 변경을 애니메이션으로 처리.

[14] Apple. "withAnimation(_:completionCriteria:_:completion:)." https://developer.apple.com/documentation/swiftui/withanimation(_:completioncriteria:_:completion:)

[15] Paul Hudson. "How to run a completion callback when an animation finishes."

[16] JPToroDev / FontSwitch. — `canBecomeKey = true`인 `FocusablePanel: NSPanel`, `panel.makeKey()`, 고정 `panel.setFrame(frame, display: true)`; 고정 패널 크기로 출시된 유사한 SwiftUI+AppKit key 윈도우 메뉴 막대 앱.

[17] Apple. "View.onGeometryChange(for:of:action:)." https://developer.apple.com/documentation/swiftui/view/ongeometrychange(for:of:action:)

[18] Cindori. "Make a floating panel in SwiftUI for macOS." — `FloatingPanel<Content>: NSPanel`, `.nonactivatingPanel`, `canBecomeKey` 재정의; 고정 `contentRect` 크기.

[19] Fazm. "SwiftUI Menu Bar App With a Floating Window: Best Practices." — 라이브 크기 조절 중 NSHostingView의 프레임별 재레이아웃; 텍스트 필드용 `makeKey()`; 상태 항목 위치 지정.

[20] Apple Developer Forums, 스레드 665638. "Animating popover size changes." https://developer.apple.com/forums/thread/665638 — 확인된 증상: 내부 컨트롤은 부자연스럽게 애니메이션되는 동안 팝오버 프레임은 즉시 변경; `withAnimation`을 사용해도 SwiftUI `.popover`는 프레임을 애니메이션하지 않음.

[21] dboydor / PopoverResize. — 크기 조절 가능한 NSPopover 래퍼(최솟값/최댓값 + 크기 조절 콜백).

[22] codestudy.net. "SwiftUI: How to Animate View Frame Resize (Transition Between Known Dimensions)."
