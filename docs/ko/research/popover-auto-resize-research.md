# 커스텀 메뉴 막대 패널의 부드러운 콘텐츠 기반 자동 크기 조절

> **과거 기록 / 대체됨.** 이 2026-06-25 리서치는 조정된 콘텐츠 기반 패널 크기 조절보다
> 앞선 것으로, 그 기능은 그날 늦게 출시되고 이후 계속 다듬어졌습니다. 현재의
> [AppKit 브리지](../architecture.md#appkit-브리지),
> [`DashboardView.swift`](../../../Sources/OpenUsage/Views/DashboardView.swift),
> [`PanelHeightCoordinator.swift`](../../../Sources/OpenUsage/Views/PanelHeightCoordinator.swift) 및
> [`PanelHeightController.swift`](../../../Sources/OpenUsage/App/PanelHeightController.swift)를 참조하세요.
> 아래의 기각된 접근법과 제안된 파일 맵은 현재 설정 지침이 아니라 과거 리서치로
> 보존됩니다.

**리서치 보고서 — 2026-06-25**
**질문:** 실제 macOS 앱은 *커스텀하고 키보드 입력 가능한* 팝오버를 콘텐츠에 맞춰 어떻게 부드럽게 자동 크기 조절하는가 — (a) 크기 조절 지연/끊김과 (b) 화면 슬라이드와 윈도우 크기 조절이 동시에 실행될 때의 "대각선" 잔킹 없이 — OpenUsage가 키보드 단축키를 위해 커스텀 `NSPanel`을 유지해야 한다는 조건에서?

---

## 요약

발생한 두 가지 실패 모두 **하나의 근본 원인, 즉 서로 다른 두 애니메이션 타이밍이 충돌한 것**에서 비롯됩니다. 콘텐츠/슬라이드는 SwiftUI 엔진이 애니메이션하고, 윈도우 프레임은 AppKit이 애니메이션했습니다(`KVO(preferredContentSize) → animated setFrame`). 서로 다른 커브를 가진 두 타임라인이 약간 다른 시점에 시작되면 끊김(두 타이밍이 프레임마다 어긋남)과 "대각선"(수평 SwiftUI 커브와 수직 AppKit 커브가 합성됨)이 발생합니다.

해결책은 더 나은 AppKit 크기 조절 애니메이션이 아니라 **윈도우를 SwiftUI가 소유한 단일 높이 값의 수동적 추종자로 만드는 것**입니다. 어려운 부분은 이미 작동하고 있습니다. 드래그 크기 조절이 매우 부드러운 이유는 SwiftUI의 `DragGesture`에서 오는 높이 스트림을 `setFrame(display:false)`로 동기적으로, 프레임마다 전달하기 때문입니다. 이 경로를 **그대로 일반화**해 높이 스트림을 손가락 대신 SwiftUI의 *애니메이션 엔진*(보간된 값)에서 가져오면 됩니다. 그러면 타이밍이 하나뿐이므로 충돌도 없습니다.

이것은 실제로 까다로운 문제이며 **이를 위한 기성 API는 없습니다** — 실제 앱들을 조사해 확인했습니다: 잘 다듬어진 SwiftUI 메뉴 막대 앱 **FontSwitch**는 동일한 `canBecomeKey` 패널을 사용하면서도 자동 맞춤을 포기하고 *고정* 크기로 출시했습니다 [16]. 경쟁 앱인 **Claude-Usage-Tracker**는 `NSPopover`를 사용해야만 부드러운 자동 크기 조절을 얻었고(`animates` 프로퍼티가 네이티브로 크기 조절 [13]), 그 대가로 바로 그 "not legal to call `-layoutSubtreeIfNeeded` on a view which is already being laid out" 재귀 경고를 치렀습니다 [9]. `NSPopover`는 문서화된 이유(`LSUIElement` 앱에서 macOS 26+부터 윈도우가 안정적으로 key가 되지 않아 Esc/Return/⌘R과 기록기가 깨짐)로 선택지에서 제외된 상태를 유지합니다. 따라서 부드러운 크기 조절 기능을 패널 위에 직접 만들어야 합니다. 드래그용 기능은 이미 있으므로 이를 재사용할 수 있습니다.

**권장 사항:** `MenuBarPanel`을 유지하고, 사용자가 원하지 않았던 수동 드래그 크기 조절 모델은 삭제한 뒤 자동 맞춤을 *단일 타이밍 추종자*로 복원합니다. `onGeometryChange`로 콘텐츠의 이상적인 높이를 측정하고, 기존 동기 브리지를 통해 패널에 전달하며, 화면 전환에 따른 높이 변경을 슬라이드를 구동하는 **같은** `withAnimation` 안에서 처리합니다(조정된 "모프"). 보수적인 대체 방법으로는 `withAnimation(completionCriteria:completion:)`을 이용한 순차 크기 조절이 있습니다. 둘 다 최소 지원 버전 범위 안의 macOS 15+ API입니다.

---

## 1. 이 특정 조합이 어려운 이유 (현황)

SwiftUI 메뉴 막대 표면에는 세 가지 실현 가능한 형태가 있고, 각 앱은 세 가지 속성 중 두 가지를 선택합니다 — *키보드 key 윈도우*, *부드러운 네이티브 콘텐츠 크기 조절*, *커스텀 크기 조절 코드 없음*:

- **`NSPopover`**는 별도 구현 없이 부드러운 네이티브 콘텐츠 크기 조절을 제공합니다: "Changes to the content size of the popover will cause the popover to animate while it is shown if the `animates` property is YES" [13][12]. 하지만 윈도우는 전체 앱이 활성 상태일 때만 key가 되고, `LSUIElement` 앱을 활성화하는 것은 비동기적이며(macOS 26+부터는 거부될 수도 있음), 그래서 키 입력이 메뉴 막대 항목 버튼으로 향합니다 — OpenUsage가 이를 포기한 문서화된 이유입니다. 그 트레이드오프를 받아들이는 앱조차 마찰과 싸웁니다: Claude-Usage-Tracker의 NSPopover+SwiftUI 통합은 레이아웃 패스 중 `NSHostingController` 생성, 레이아웃 중간의 `withAnimation` 변경, `GeometryReader`+`.animation` 충돌, 고정 `contentSize`와 동적 SwiftUI 콘텐츠의 충돌로 인한 레이아웃 재귀 경고를 던집니다 [9].

- **커스텀 `NSPanel`(`canBecomeKey = true`, `.nonactivatingPanel`)**은 앱을 활성화하지 않고도 진짜 key 윈도우를 제공합니다 — 키보드가 첫 시도에 작동합니다. 이것이 OpenUsage의 패널이며, FontSwitch가 사용하는 것과 같습니다("We become key when using the search bar to receive keyboard input" — `FocusablePanel: NSPanel { override var canBecomeKey: Bool { true } }`, 그다음 `panel.makeKey()`) [16]. 대가는 `NSPopover.animates`를 잃는 것입니다. FontSwitch의 답은 **고정** 패널입니다(저장된 `panelSize`로 `panel.setFrame(frame, display: true)`) [16] — OpenUsage가 PR #717에서 도착한 바로 그 지점입니다.

- **SwiftUI `Window` / `MenuBarExtra(.window)` 씬**은 콘텐츠에 맞춰 자동 크기를 조절할 수 있습니다(콘텐츠 크기를 상태에 바인딩하고 `withAnimation`으로 감싸면 SwiftUI의 레이아웃 엔진이 윈도우 크기를 조절) [6]. 하지만 `.window` 스타일은 `NSPopover`와 같은 비-key 제한이 있으므로 같은 이유로 제외됩니다.

**결론:** "커스텀 key 윈도우 패널"**과** "부드러운 콘텐츠 자동 크기 조절"을 별도 구현 없이 함께 얻을 수는 없습니다. 크기 조절을 직접 재구현해야 합니다. 다행히 부드러운 드래그 크기 조절 기능은 이미 있으므로, 새로 만드는 것이 아니라 일반화하면 됩니다.

---

## 2. 이전 모든 시도의 근본 원인 매핑

기억과 코드에는 시도했다가 실패한 다섯 가지가 기록되어 있습니다. 각각은 두 애니메이션 타이밍이 충돌했다는 진단으로 깔끔하게 설명됩니다:

1. **`KVO(preferredContentSize) → setFrame`, "화면 전환마다 끊겼음."** `NSHostingController.preferredContentSize`는 SwiftUI의 프레임별 애니메이션 타이밍이 아니라 AppKit의 주기로 업데이트됩니다(제약에서 파생된 크기 [2][5]). 그리고 윈도우를 *별도의* AppKit 애니메이션으로 애니메이션했습니다. 두 타이밍이 어긋나므로 끊김이 생깁니다. 더 나쁜 것은, 측정과 재레이아웃이 레이아웃 패스 내부에서 일어났다는 점입니다 — Claude-Usage-Tracker가 문서화한 것과 같은 재귀 함정입니다 [9].

2. **`animator().setFrame` / `NSAnimationContext` 애니메이션 크기 조절, "잔키."** `layerContentsRedrawPolicy`가 올바르게 설정되지 않으면 AppKit의 암시적 레이어 경계 애니메이션은 애니메이션 중 레이어의 *캐시된* 콘텐츠를 늘리고, 레이어 친화적이지 않은 설정은 **메인 스레드**에서 반복적인 `-setFrame:`으로 구동되는데, 여기서는 "animation performance degrades extremely quickly"입니다 [1]. 완벽하게 하더라도 여전히 SwiftUI 슬라이드와 충돌하는 *두 번째 타이밍*이 남습니다.

3. **`setFrame(display:false)`, "즉시, 미끄러짐 없음."** 맞습니다 — 단순한 `setFrame`에는 애니메이션 드라이버가 없습니다. 미끄러짐은 높이를 보간하는 *무언가*에서 와야 합니다. 올바른 프리미티브는 갖고 있었지만 그것에 공급할 보간된 소스가 없었습니다. 이것이 핵심 깨달음입니다: 프리미티브가 고장 난 것이 아니라, 커브 대신 계단 함수가 공급되고 있었을 뿐입니다.

4. **설정 열기에서의 "대각선".** 슬라이드는 스프링 위의 SwiftUI `.offset`이고, 크기 조절은 AppKit `setFrame`이었습니다. 수평 SwiftUI 커브와 수직 AppKit 커브가 한 박자 차이로 시작해 비뚤게 도착하는 대각선이 생겼습니다. 순수하게 두 애니메이션 타이밍이 간섭한 결과입니다.

5. **드래그 크기 조절: 부드러움.** 유일한 성공. 왜일까요? `DragGesture.onChanged`는 (레이아웃 패스 내부가 아닌) *이벤트* 콜백이며, `setFrame(display:false)` + `layoutSubtreeIfNeeded()` + `displayIfNeeded()`를 동기적으로, 틱당 하나의 높이로 푸시합니다. 손가락의 움직임이 유일한 시간 기준이 되고, 윈도우는 정확히 따라갑니다. **이것이 전체 해결책의 템플릿입니다.**

---

## 3. 권장 아키텍처: 단일 타이밍 추종자

패널 높이를 *SwiftUI가 소유한 값의 순수 함수*로 만들고, SwiftUI의 애니메이션 엔진만이 애니메이션하는 유일한 존재가 되게 합니다. 윈도우는 스스로 애니메이션하지 않습니다. SwiftUI가 현재 프레임에 대해 계산한 정확한 크기로 다시 그려질 뿐입니다.

### 3.1 프리미티브 (드래그 일반화)

드래그가 이미 부드러운 경로를 증명합니다:

```swift
// StatusItemController.updateGripResize(by:) — the proven-smooth path
panel.setFrame(rect, display: false)
panel.contentView?.layoutSubtreeIfNeeded()
panel.displayIfNeeded()
```

이 브리지를 유지하세요. *누가 높이를 공급하는지*만 바꿉니다: 손가락의 `MenuBarPopover.resizeBy(translation)` 대신 SwiftUI 보간 값의 `applyHeight(_:)`를 공급합니다.

### 3.2 콘텐츠의 이상적인 높이 측정

피드백 루프가 없도록 윈도우의 현재 높이와 무관하게 **콘텐츠의 자연 높이**를 측정합니다. 현대적이고 레이아웃 안전한 API는 `onGeometryChange`(macOS 15+, 최소 지원 버전 범위 안)입니다 [10][17]. 단순한 `GeometryReader`처럼 레이아웃을 확장하지 않고 지오메트리를 모니터링합니다:

```swift
// Measure the SCROLL CONTENT (inner VStack), not the viewport, so the value
// is the ideal height and does not depend on the window height → no feedback loop.
scrollContent
    .onGeometryChange(for: CGFloat.self) { proxy in proxy.size.height }
        action: { ideal in layout.idealHeight[screen] = ideal }
```

너비가 320으로 고정되어 있고 카드가 콘텐츠에 맞춰 크기 조절되므로, 콘텐츠에 *더 많은* 수직 공간을 제공해도 이 측정값은 절대 바뀌지 않습니다 — 루프는 구조적으로 끊어집니다. (만약 필요한 경우의 macOS 15 이전 대체 경로: `.background(GeometryReader { Color.clear.preference(...) })` [17].)

### 3.3 클램프 + 스크롤 대체 경로 (NSPopover의 contentSize-as-max 재구현)

```
target = clamp(idealHeight, minHeight, maxPanelHeight())   // you already have maxPanelHeight()
```

`ideal ≤ maxScreen`이면 윈도우가 콘텐츠에 정확히 맞고 `ScrollView`는 비활성입니다. `ideal > maxScreen`이면 윈도우는 `maxPanelHeight()`에서 상한에 걸리고 스크롤이 작동합니다 — 이것이 바로 `NSPopover.contentSize`의 동작 방식입니다("if your SwiftUI view requests more space than contentSize allows, the bottom is clipped" [12]). 다만 여기서는 잘리는 대신 스크롤됩니다. `maxPanelHeight()`와 상단 앵커링을 현재 그대로 유지하세요(origin.y = `anchorTopLeft.y - height`, 패널이 메뉴 막대 항목에서 아래로 커집니다).

### 3.4 SwiftUI 애니메이션 타이밍을 추종자에 공급

이것이 핵심입니다. 두 번째 타이밍 없이 *보간된* 높이(계단이 아닌 커브)를 얻으려면, 대상 높이를 SwiftUI가 프레임을 애니메이션하는 비용 없는 뷰에 미러링하고 진행 중인 값을 읽습니다:

```swift
// A 0×target probe. When `target` changes inside withAnimation, SwiftUI
// interpolates this frame height every render tick and fires the action
// with the interpolated value — the same clock that drives the slide.
Color.clear
    .frame(height: animatedTarget)
    .onGeometryChange(for: CGFloat.self) { $0.size.height }
        action: { h in MenuBarPopover.applyHeight?(h) }   // → the synchronous bridge
```

`applyHeight`가 패널로 푸시합니다. 높이가 `animatedTarget`의 SwiftUI 보간에서 오므로, 윈도우는 SwiftUI의 커브와 타이밍을 정확히 추적합니다 — 드래그가 손가락을 추적하는 것과 동일합니다. `NSAnimationContext`도, `animator()`도, 불일치할 AppKit 타이밍도 없습니다.

> 동등한 메커니즘: `animatableData`가 높이이고 setter가 `applyHeight`를 호출하는 커스텀 `Animatable` modifier — 고전적인 "SwiftUI 애니메이션에서 NSWindow 구동" 트릭. 더 읽기 깔끔한 쪽을 선택하면 됩니다. 둘 다 SwiftUI가 애니메이션 타이밍을 단독으로 제어하게 합니다.

---

## 4. "대각선" 문제 해결 — 이제 가능해진 두 가지 깔끔한 옵션

윈도우가 수동적 추종자가 되면 슬라이드와 크기 조절은 더 이상 두 개의 타이밍으로 나뉘지 않습니다 — 문제는 순수하게 *설계*가 됩니다: 함께 움직여야 하는가, 순차적으로 움직여야 하는가?

**옵션 A — 조정된 모프 (권장).** `slideProgress`를 구동하는 **동일한 `withAnimation` 안에서** 높이 대상을 목적지 화면의 이상적인 높이로 설정합니다. 두 페이지 모두 이미 슬라이드 `HStack`에 마운트되어 있으므로 두 이상 높이를 모두 알고 있습니다. 그러면 수평 오프셋과 윈도우 높이가 하나의 스프링에서 애니메이션됩니다. 새 화면이 슬라이드되어 들어오면서 패널이 *모프*됩니다(커지거나 작아짐) — 하나의 일관된 움직임. 옛 "대각선"은 두 축의 타이밍이 달랐기 때문에 추했을 뿐입니다. 하나의 타이밍으로 통합하면 의도된 움직임으로 읽힙니다(시스템 표면이 모프되는 방식). 추가 지연 없음.

```swift
withAnimation(Motion.spring) {
    slideProgress = 1
    animatedTarget = idealHeight[destinationScreen] ?? animatedTarget
}
```

**옵션 B — 순차 (보수적 대체 경로).** 일정한 높이로 슬라이드한 다음 크기 조절 — 네이티브 완료 API(macOS 14+, 최소 지원 버전 범위 안) 사용 [14][7][15]:

```swift
withAnimation(.spring, completionCriteria: .removed) {
    slideProgress = 1
} completion: {
    withAnimation { animatedTarget = idealHeight[destinationScreen] ?? animatedTarget }
}
```

슬라이드 중간에 잘리는 것을 피하려면, 목적지가 더 크면 슬라이드 *전에* 키우고, 더 작으면 *후에* 줄입니다. 더 신중하고 약간 느립니다. 글래스 카드에서 모프가 너무 번잡하게 느껴지면 이것을 선택하세요.

**화면 내 콘텐츠 변경**(프로바이더 로드, 행 확장, 지출 행 토글)은 순수한 경우입니다: 슬라이드 없이 `withAnimation { animatedTarget = newIdeal }`뿐. 팔로워가 동일하게 처리합니다 — 이것이 사용자들이 실제로 되돌려 달라고 요청하는 자동 크기 조절입니다.

---

## 5. 파일에 매핑된 코드 스케치

| 파일 | 변경 |
|---|---|
| `Support/PopoverDismissReader.swift` | `MenuBarPopover` 브리지에 `static var applyHeight: ((CGFloat) -> Void)?` 추가(`beginResize`/`resizeBy`/`dismissHandler`와 같은 패턴). |
| `App/StatusItemController.swift` | `applyHeight`를 구현해 `maxPanelHeight()`로 클램프하고 **기존** 동기 `setFrame(display:false)` 경로를 호출(콜백에서 `layoutSubtreeIfNeeded`를 강제하지 않음 — §6 참조). 자동 맞춤이 출시되면 `PanelHeightStore`/드래그 배관을 제거. |
| `Views/DashboardView.swift` | `Color.clear.frame(height:).onGeometryChange` 프로브(또는 `Animatable` modifier) 추가. 각 화면의 이상 높이를 스크롤 콘텐츠에서 측정. 기존 슬라이드 `withAnimation` 안에서 높이 대상 설정(옵션 A) 또는 순차 실행(옵션 B). 자동 맞춤이 입증되면 `resizeDragger`와 `resizingPanel`/`.frame(maxHeight:.infinity)` 채우기를 제거. |
| `Stores/LayoutStore.swift` | `idealHeight: [PopoverScreen: CGFloat]` 보유(또는 `DashboardView`의 간단한 `@State` 두 개). |

정리 대상으로 이미 표시된 ~120줄의 죽은 자동 크기 기계 장치(`animatedPopoverHeight`, `ScreenHeightReader`, `contentHeight` 바인딩)는 되살리지 말고 삭제해야 합니다 — 새 경로가 더 작고 애니메이션 타이밍도 하나로 통합되어 있습니다.

---

## 6. 반드시 물리게 될 함정 하나: 레이아웃 재진입

경쟁 앱의 재귀 경고 — *"It's not legal to call `-layoutSubtreeIfNeeded` on a view which is already being laid out"* — 는 레이아웃 패스 *도중에* 레이아웃 작업을 해서 발생했습니다 [9]. `onGeometryChange`의 액션(및 `Animatable` setter)은 SwiftUI 레이아웃 *내부에서* 발화할 수 있습니다. 드래그가 안전한 이유는 `DragGesture.onChanged`가 레이아웃 시점 콜백이 아닌 이벤트 콜백이기 때문입니다 — 그래서 거기서 동기 `layoutSubtreeIfNeeded()`는 괜찮습니다. 공급이 애니메이션 주도일 때 안전을 유지하려면:

- `applyHeight`에서 `panel.setFrame(rect, display: false)`를 호출하고 콜백 내부에서 `panel.contentView?.layoutSubtreeIfNeeded()`를 강제하지 **마세요**. 고정 너비의 상단 앵커 콘텐츠에서는 윈도우를 키우는 것이 이미 레이아웃된 콘텐츠를 *드러낼* 뿐입니다 — 재레이아웃할 것이 없으므로 동기 레이아웃 호출(재진입 위험이 있는 부분)은 여기서 불필요합니다. `displayIfNeeded()` / 정상적인 CA 드로우 사이클이 그리게 하세요.
- 윈도우 경계를 *프레임마다 명시적으로* 설정하고(암시적 `animator()` 애니메이션 없이), Core Animation이 오래된 캐시된 레이어를 늘리지 않게 하세요 [1] — 매 프레임 레이어는 이미 올바른 콘텐츠를 가진 올바른 크기입니다.
- 크기 조절/레이아웃 중에 `NSHostingController`를 지연 생성하지 마세요(시작 시 한 번 생성합니다 — 그대로 유지) [9].
- `applyHeight`를 재진입 플래그(`isApplyingHeight`)로 보호해 프레임 변경이 재귀적으로 다른 변경을 트리거하지 못하게 하세요.

---

## 7. 검토 후 기각된 대안

- **손쉬운 부드러운 크기 조절을 위해 `NSPopover`로 회귀.** 기각: `LSUIElement` 앱에서 macOS 26+부터 윈도우가 안정적으로 key가 되지 않고(문서화된 근본 원인), 이것이 키보드를 깨뜨립니다 — `MenuBarPanel`이 존재하는 전체 이유. NSPopover+SwiftUI는 자체적인 레이아웃 재귀 마찰도 가져옵니다 [9]. 키보드 불타협은 NSPopover 불가를 의미합니다.

- **AppKit Core-Animation 크기 조절(`NSAnimationContext` + `animator().setFrame`, `layerContentsRedrawPolicy = .onSetNeedsDisplay`).** 단독으로는 부드럽게 만드는 것이 *가능합니다* [1]. 하지만 두 번째 타이밍입니다 — SwiftUI의 스프링과 커브를 맞출 수 없으므로 대각선을 다시 도입합니다. 슬라이드도 AppKit에서 구동하는 경우에만 실행 가능한데, 그것은 원하지 않습니다. 단일 SwiftUI 타이밍을 위해 기각.

- **수동 드래그 핸들 유지.** 기각: 사용자가 싫어했던 것이며, 자동 맞춤이 돌아오면 중복입니다. (미래의 "최대 높이 고정" 파워 유저 옵션은 브리지를 재사용할 수 있지만, 핵심 요구에는 필요하지 않습니다.)

- **손쉬운 자동 크기 조절을 위한 `MenuBarExtra(.window)` / SwiftUI `Window` 씬** [6]. 기각: NSPopover와 같은 비-key 키보드 제한.

---

## 8. 검증 계획

팝오버는 여기서 자동으로 열거나 스크린샷할 수 없으므로 직접 확인이 필요하지만, 객관적으로 만드세요:

1. **화면 내 크기 조절**(대시보드에서 프로바이더의 지출 행 토글): 패널이 하나의 부드러운 움직임으로 커지거나 작아지고, 상단 가장자리 고정, 카드 늘어남이나 한 프레임 잘림 없음.
2. **화면 전환**(대시보드 → 설정, 큰 화면): 옵션 A에서는 슬라이드 + 커짐이 단일 모프로 읽혀야 하고, 옵션 B에서는 깔끔한 두 박자여야 합니다. 대각선 없음, 흔들림 없음.
3. **화면 상한 경우**(매우 큰 콘텐츠 / 짧은 디스플레이): 윈도우가 `maxPanelHeight()`에서 상한에 걸리고 내부 `ScrollView`가 레이아웃 충돌 없이 작동.
4. **재진입:** Xcode/Console에서 실행해 빠른 화면 전환 연타 중 "not legal to call `-layoutSubtreeIfNeeded`…" 경고가 **0건**인지 확인 [9].
5. **글래스:** 크기 조절 중 `.quaternary` 카드에 화이트 플래시가 없는지 확인 — 크기 조절은 순수한 경계 변경(불투명도 없음)이므로, 이미 의존하고 있는 '트랜지션이 아닌 오프셋' 규칙이 그대로 유지됩니다.
6. 적합한 곳에 회귀 테스트 추가(AGENTS.md에 따라): `applyHeight`가 `[minHeight, maxPanelHeight()]`로 클램프하는지, 높이 대상이 상한 아래에서 측정된 이상 값과 같은지 단언.

---

## 9. 한계와 주의 사항

이 보고서는 실제 코드(소스 탐색으로 매핑)와 권위 있는 AppKit/SwiftUI 문서, 1차 소스 개발자 블로그, 직접 유사한 두 개의 오픈 소스 앱에 근거합니다. 중심 주장 — SwiftUI 보간 값이 동기 `setFrame` 브리지에 공급되면 드래그만큼 부드러울 것이라는 — 은 (a) 드래그가 바로 그 브리지를 통해 이미 부드럽다는 점과 (b) 단일 타이밍 원칙에서 나온 강한 추론이며, 측정된 결과가 **아닙니다**. 디바이스에서 검증해야 합니다(§8). 재진입 완화(§6)가 가장 리스크가 높은 세부 사항입니다: 콜백에서 동기 `layoutSubtreeIfNeeded`를 제거했을 때 빠른 애니메이션 중 감지 가능한 한 프레임 콘텐츠 지연이 발생한다면, 대체 경로는 그것을 유지하되 플래그로 재진입을 방어하거나 푸시를 레이아웃 패스 밖으로 넘기는 것입니다 — 약간 더 복잡해지는 대가를 치르면서. 애니메이션 중 `onGeometryChange`의 정확한 발화 주기는 공식 문서화되어 있지 않습니다 [10][17]. 너무 거칠다고 판명되면 `Animatable`-modifier 메커니즘이 프레임 고정 업데이트를 제공합니다. 이 중 어느 것도 아키텍처를 바꾸지 않습니다 — 어떤 노브를 돌릴지만 바뀝니다.

---

## 참고 문헌

[1] Jonathan Willing. "A short guide to OS X animations." https://jwilling.com/blog/osx-animations/ — `layerContentsRedrawPolicy`(`NSViewLayerContentsRedrawDuringViewResize` vs `OnSetNeedsDisplay`); 메인 스레드 `-setFrame:` 성능 저하; 백그라운드 스레드에서의 CA.

[2] Apple. "setFrame(_:display:animate:) — NSWindow." https://developer.apple.com/documentation/appkit/nswindow/1419519-setframe

[3] Jonathan Willing. "JNWAnimatableWindow." https://github.com/jwilling/JNWAnimatableWindow — 레이어 기반 NSWindow 애니메이션.

[4] Apple. "sizingOptions — NSHostingController." https://developer.apple.com/documentation/swiftui/nshostingcontroller/sizingoptions

[5] Apple. "preferredContentSize — NSHostingController." https://developer.apple.com/documentation/swiftui/nshostingcontroller/preferredcontentsize

[6] Itsuki. "SwiftUI/MacOS: Auto Window/Panel Resizing Based on Some State." https://medium.com/@itsuki.enjoy/swiftui-macos-auto-window-panel-resizing-based-on-some-state-a8f8ffc4182f

[7] Antoine van der Lee. "withAnimation completion callback with animatable modifiers." https://www.avanderlee.com/swiftui/withanimation-completion-callback/

[8] Michael Tsai (Brian Webster 인용). "How NSHostingView Determines Its Sizing." https://mjtsai.com/blog/2023/08/03/how-nshostingview-determines-its-sizing/

[9] hamed-elfayome / Claude-Usage-Tracker, Discussion #64. "Fix: Layout recursion warning in NSPopover/SwiftUI integration." https://github.com/hamed-elfayome/Claude-Usage-Tracker/discussions/64 — `-layoutSubtreeIfNeeded` 재진입; 레이아웃 중 NSHostingController 생성; 패스 중간 `withAnimation`; GeometryReader+`.animation`; 고정 `contentSize` vs 동적 콘텐츠.

[10] Fatbobman. "4 Ways to Get View Size in SwiftUI: From GeometryReader to onGeometryChange." https://fatbobman.com/en/snippet/how-to-obtain-view-dimensions-in-swiftui/

[11] Apple. "NSPopover." https://developer.apple.com/documentation/appkit/nspopover

[12] Apple. "contentSize — NSPopover." https://developer.apple.com/documentation/appkit/nspopover/1524677-contentsize

[13] Apple. "animates — NSPopover." https://developer.apple.com/documentation/appkit/nspopover/1526527-animates — `animates`가 YES일 때 표시 중 콘텐츠 크기 변경이 애니메이션됨.

[14] Apple. "withAnimation(_:completionCriteria:_:completion:)." https://developer.apple.com/documentation/swiftui/withanimation(_:completioncriteria:_:completion:)

[15] Paul Hudson. "How to run a completion callback when an animation finishes." https://www.hackingwithswift.com/quick-start/swiftui/how-to-run-a-completion-callback-when-an-animation-finishes

[16] JPToroDev / FontSwitch. https://github.com/JPToroDev/FontSwitch — `canBecomeKey = true`, `panel.makeKey()`, 고정 `panel.setFrame(frame, display: true)`를 가진 `FocusablePanel: NSPanel`; 고정 패널 크기로 출시하는 유사한 SwiftUI+AppKit key 윈도우 메뉴 막대 앱.

[17] Apple. "View.onGeometryChange(for:of:action:)." https://developer.apple.com/documentation/swiftui/view/ongeometrychange(for:of:action:)

[18] Cindori. "Make a floating panel in SwiftUI for macOS." https://cindori.com/developer/floating-panel — `FloatingPanel<Content>: NSPanel`, `.nonactivatingPanel`, `canBecomeKey` 오버라이드; 고정 `contentRect` 크기 조절.

[19] Fazm. "SwiftUI Menu Bar App With a Floating Window: Best Practices." https://fazm.ai/blog/swiftui-menu-bar-app-floating-window-best-practices — 라이브 크기 조절 중 프레임별 NSHostingView 재레이아웃; 텍스트 필드를 위한 `makeKey()`; 메뉴 막대 항목 위치 지정.

[20] Apple Developer Forums, thread 665638. "Animating popover size changes." https://developer.apple.com/forums/thread/665638 — 확인된 증상: 팝오버 프레임은 즉시 바뀌는데 내부 컨트롤은 어색하게 애니메이션됨; SwiftUI `.popover`는 `withAnimation` 하에서도 프레임을 애니메이션하지 않음.

[21] dboydor / PopoverResize. https://github.com/dboydor/PopoverResize — 크기 조절 가능한 NSPopover 래퍼(최소/최대 + 크기 조절 콜백).

[22] codestudy.net. "SwiftUI: How to Animate View Frame Resize (Transition Between Known Dimensions)." https://www.codestudy.net/blog/swiftui-animate-resize-of-a-view-frame/
