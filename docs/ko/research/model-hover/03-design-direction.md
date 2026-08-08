# 모델 호버 패널 — 네이티브 디자인 방향

> **과거 기록 / 대체됨.**
> 2026-07-04에 출시된 모델 내역 호버 패널의 방향을 정한 디자인 보고서.
> 현재 동작과 구현은 [대시보드 행](/docs/ko/dashboard.md#행), [`HoverPopoverState.swift`](../../../../Sources/OpenUsage/Views/HoverPopoverState.swift), [`ModelUsageDetail.swift`](../../../../Sources/OpenUsage/Views/ModelUsageDetail.swift) 참고.
> 아래의 참조, 줄 번호, 제안 컴포넌트 이름은 당시 설계 결정의 기록으로 그대로 유지.

**리서치 보고서 — 2026-07-04**
**질문:** 첨부된 AI 생성 콘셉트("TOP DRIVER" 히어로 카드, 도넛, 순위별 모델 목록을 갖춘 "Models" 플라이아웃)를 고려할 때 Today / Yesterday / Last 30 Days 지출 행의 호버 패널이 갖춰야 할 모습은 무엇인가?
소유자는 콘셉트의 방향은 맞지만 "조금 과하다"고 평가 — 글자 크기가 일관되지 않고 네이티브답지 않다는 판단.
목표는 OpenUsage에 어울리고 Cursor / Claude / Codex / Grok에서 동작하며 Cursor 브랜드에 종속되지 않는 Apple 중심의 네이티브 macOS UI.

---

## 요약

콘셉트의 *정보*(순위별 모델 목록, 최대 기여 모델 강조, 모델별 비례 막대, 헤더의 기간 라벨)는 유지하고 *과한 연출*("TOP DRIVER" 알약형 배지, 과도하게 큰 도넛, 카드 속 카드 중첩, 혼합된 글자 크기 체계, 모델별 프로바이더 로고)은 제거.
총량을 기여자별로 나누는 Apple의 네이티브 패턴은 활성 상태 보기의 에너지 탭, 스크린 타임의 앱별 목록, 배터리 메뉴 막대 항목의 앱별 사용량, 시스템 설정 ▸ 저장 공간에서 보듯 링 차트를 둔 히어로 카드가 아닌 **비례 가로 막대와 차분한 요약 한 줄을 갖춘 단일 계층의 간결한 순위 목록**.

권장 방향은 앱이 `UsageSparkline` → `UsageTrendDetail`에서 이미 사용하는 패턴과 동일한 **호버된 지출 행에 앵커된 작은 SwiftUI `.popover`**로, 내부에는 지출 순으로 정렬된 하나의 모델 목록을 두고 각 행에 라벨 + 고정폭 달러 수치 + 얇은 비례 `Capsule` 막대, 상단에 기간과 최상위 모델을 알리는 차분한 헤더 하나 배치.
도넛, 히어로 카드, 모델별 아이콘, 새 의존성 모두 제외.
최대 기여 모델 강조는 요란한 알약형 배지가 아니라 스크린 타임의 최다 사용 앱 표시처럼 **순위 + 선두 행의 세미볼드 "Top" 태그 하나**로 처리.

---

## 1. 앱의 기존 디자인 언어(구체적 목록)

`Sources/OpenUsage/Views/` + `Sources/OpenUsage/Stores/DensitySetting.swift` + `Sources/OpenUsage/Support/Theme.swift` + `Sources/OpenUsage/Support/LiquidGlassFallbacks.swift`에서 확인한 내용.
새 패널도 이 언어와 일치해야 함.

### 1.1 글자 크기 체계(시맨틱 스타일이 아닌 명시적 포인트 크기)

앱의 데이터 행에서는 시맨틱 `.headline` / `.subheadline` / `.caption` 미사용.
macOS에서 시맨틱 `.headline.weight(.regular)`가 `.headline`과 일치하지 않으므로 `DensitySetting`을 통해 명시적 포인트 크기 결정(`WidgetRowView.swift:33-36`).
Compact에서는 모든 크기를 1포인트씩 축소.

| 역할 | Regular | Compact | 굵기 | 전경색 |
|---|---|---|---|---|
| 프로바이더 섹션 헤더(이름) | 14 | 13 | `.semibold` | `.primary` |
| 지표 행 라벨 | ~13(`NSFont.headline` 기준) | 기준 − 1 | `.semibold` | `.primary` |
| 보조 / 상세 / 막대 아래 | 12 | 11 | `.regular` | 값은 `.primary`, 맥락은 `.secondary` |
| 요금제 배지, 오래된 데이터 태그 | 11 | 10 | `.regular` | `.secondary` / `.tertiary` |
| 내비게이션 바 제목(Customize/Settings) | — | — | `.headline`(시맨틱) | — |
| 푸터 식별 정보("OpenUsage 0.7.x", "Next update in 3m") | — | — | `.caption2`(시맨틱) | `.secondary` |
| UsageTrendDetail 헤더 제목 | 13 | — | `.semibold` | `.primary` |
| UsageTrendDetail 수치 / 축 / 노트 | 11 / 10 | — | `.regular` | `.secondary`, `.monospacedDigit()` |
| 툴팁 말풍선 | 12 | — | `.regular` | `.primary` |
| "Copied to clipboard" 알약형 배지 | 12 | — | `.semibold` | `Theme.positive` |

**패널이 따라야 할 규칙:**

- 값(사용자가 팝오버를 열어 확인하려는 숫자)은 `.primary`, 주변 요소(기간 라벨, 출처 노트, "Top" 태그)는 모두 `.secondary`.
  `.tertiary`는 글래스 위의 비활성 콘텐츠 전용(`ProviderSectionHeader.swift:73-80`).
- 숫자는 `.monospacedDigit()`과 `.contentTransition(.numericText())`를 사용해 실시간 갱신 시 수치의 흔들림 방지(`DashboardView.swift:701-709`, `WidgetRowView.swift:226`).
- 한 줄 행의 라벨과 값에는 **같은 포인트 크기**를 적용하고 굵기만으로 이름과 값의 계층 구성(`WidgetRowView.swift:308-310`).
  콘셉트 스크린샷은 이 규칙을 위반하며, 달러 금액이 모델 이름과 다른 크기와 굵기로 보이는 상태.

### 1.2 레이아웃 치수(4pt 그리드)

- **팝오버 너비: 320pt 고정**(`DashboardView.swift:64`).
  작업 브리프의 "~360pt"는 실제 패널보다 조금 넓으므로, 같은 계열로 느껴지도록 호버 패널의 너비는 320 이하가 적합.
  기존 `UsageTrendDetail`의 너비는 240pt이며 상세 팝오버로 부담 없는 크기.
- 외곽 가로 패딩: 14pt.
  행 가로 패딩: 14pt.
  카드 여백: 5pt(Compact 3pt).
- 섹션 간격: 14pt(Compact 8pt).
  헤더→카드: 4pt(Compact 2pt).
- 텍스트 행 세로 패딩은 6pt(Compact 4pt), 연속된 텍스트 행은 2pt(Compact 1pt)로 줄여 Today / Yesterday / Last 30 Days가 **균일한 간격의 전체 높이 행이 아닌 하나의 묶음**으로 보이도록 구성(`WidgetRowView.swift:60-77`).
  이 압축 규칙은 순위 목록과 가장 직접적으로 관련된 선례이므로 호버 행에도 같은 방식 적용.
- 카드 모서리 반경: 12pt, `.continuous`(`Theme.swift:60`).
  호버 패널 자체는 시스템 `.popover`이므로 바깥 모서리는 시스템이 렌더링하고, 내부 카드를 유지한다면 12pt 적용.
- 미터 캡슐 높이: 5pt(Compact 4pt) — 10pt 막대는 주변 요소 옆에서 두툼한 판처럼 보여 의도적으로 얇은 헤어라인 적용(`DensitySetting.swift:52-54`).
- 스파크라인 높이: 18pt(Compact 14pt).
  너비 240pt의 추세 상세 차트 높이: 76pt.

### 1.3 머티리얼과 색상

- **페이지 표면:** `Theme.traySurface` = `NSColor.textBackgroundColor` — 라이트 모드에서는 흰색, 다크 모드에서는 검정에 가까운 불투명색이며 데스크톱 틴트 없음.
  팝오버 전체가 하나의 불투명 패널로 보이는 구성.
- **그룹 카드:** `Theme.cardShape`(RoundedRect r=12)에 `traySurface` 채우기 + `.fill.quaternary` 오버레이 — macOS 시스템 설정의 그룹 박스 형태이며 **테두리 없음**(실제 카드에 스트로크 미사용).
  헤어라인 `.separator` 스트로크는 떠 있는 단일 행 칩에만 적용(`Theme.swift:83-86`).
- **Liquid Glass는 크롬 전용** — 푸터/상단 바(`barGlass()`)와 컨트롤(`glassButtonStyle`, `interactiveGlass`)에만 사용하고 데이터 카드에는 미사용.
  `Theme.swift:7-9`와 `liquid-glass` 스킬에서 콘텐츠 레이어에 Liquid Glass를 사용하지 않고 표준 머티리얼로 뒷받침하도록 명시.
  어두운 그라디언트 위에 반투명 카드 속 카드를 올린 콘셉트는 이 규칙과 정반대.
- **미터 / 막대 채우기는 시스템 팔레트를 최대 강도로 사용:** 파랑 = `systemBlue`, 노랑 = `systemYellow`, 빨강 = `systemRed`(`Theme.swift:25-31`).
  프로바이더 브랜드 그라디언트 제외.
  추세 스파크라인에는 정상 상태 미터와 같은 파랑 사용(`Theme.meterFill(.normal)`).
  호버 패널의 비례 점유율 막대에도 기존 사용량 색상인 이 파랑 적용.
- 주의 = 시스템 오렌지, 긍정 = 시스템 그린.

### 1.4 기존 호버 상세 선례(따라야 할 패턴)

`UsageSparkline` → `UsageTrendDetail`(`UsageSparkline.swift:38-47`, `UsageTrendDetail.swift`)은 앱에서 유일하게 행 호버로 자세한 내역을 보여 주는 흐름이며 모델 패널에 적합한 골격.

- SwiftUI `.popover(isPresented:)`와 `arrowEdge: .top`으로 앵커하고, 행 전체가 아닌 **막대 스트립**에 연결해 화살표가 차트를 가리키도록 구성.
- `TrendHoverState`(`@Observable`)가 제어: **400ms 표시 대기**, 커서가 인라인 행에서 팝오버로 이동하는 동안 닫힘을 막는 **180ms 유예**, 팝오버가 남지 않도록 닫기 경로에서 `dismissAll()` 호출(`DashboardView.swift:255-258`).
- 너비 240pt, 내부 패딩 12pt, 왼쪽 제목 + 오른쪽 고정폭 수치의 헤더, 차트, 축 행, 선택적 10pt 출처 노트 순서.
  카드 속 카드 없이 패딩을 둔 하나의 평면 `VStack` 구성.
- 막대 하나를 호버하면 나머지 막대의 불투명도를 0.35로 낮춤 — 두 번째 색 없이 선택을 드러내는 방식.
  모델 패널에서도 호버된 행에 재사용 가능.

모델 패널은 막대 차트 자리에 순위 목록을 넣은 **동일한 컴포넌트 형태**여야 함.

### 1.5 호버 툴팁(더 가벼운 선례이지만 이 경우에는 부족한 이유)

`.hoverTooltip(_)`(`HoverTooltip.swift`)은 팝오버보다 한 단계 위의 별도 클릭스루 `NonKeyPanel`에 한 줄짜리 텍스트 말풍선을 렌더링.
SwiftUI 오버레이가 팝오버 윈도우에 잘리는 상황에서 툴팁을 자유롭게 띄우기 위한 구조.
다만 **텍스트 전용**이므로 막대가 있는 순위 목록 표시 불가.
모델 내역에는 툴팁 경로가 아닌 `.popover` 경로 필요.
(툴팁은 기존 지출 행에서 값 호버 시 정확한 수치를 보여 주는 상호작용에 적합하며, 그 위에 패널을 함께 표시할 수 있음.)

---

## 2. 첨부된 콘셉트 스크린샷 비평

### 2.1 유지할 요소

- **순위별 모델 목록.**
  Apple이 총량을 기여자별로 분해하는 방식과 정확히 일치(스크린 타임, 저장 공간, 활성 상태 보기 에너지).
  가장 명확한 신호는 순위.
- **모델별 비례 막대.**
  행별 얇은 비례 막대는 스크린 타임의 앱별 목록과 저장 공간의 카테고리별 목록이 모두 사용하는 네이티브 관용구.
  미터 캡슐 형태로 이미 앱의 시각 언어에 포함된 요소.
- **헤더의 기간 라벨**("Last 30 Days").
  데이터 범위가 호버된 행으로 정해지므로 패널에 기간 표시 필요.
  오른쪽에 차분한 `.secondary`로 배치하는 편이 적합하며, 콘셉트는 배치는 맞지만 제목과 경쟁하는 굵기는 부적절.
- **최대 기여 모델 강조.**
  사용자가 실제로 알고 싶은 정보는 "이 기간에 어느 모델이 지출을 주도했는가"라는 점.
  강조 자체는 적절하지만 알약형 배지 + 도넛 + 히어로 카드라는 *형태*가 과한 상태.
- **푸터 출처 한 줄**("From your Cursor usage history").
  앱의 `UsageTrendDetail`에도 이미 같은 요소 존재(`note`, 10pt `.secondary`).
  단, 패널이 Claude / Codex / Grok에서도 동작하므로 Cursor 브랜드가 아닌 **프로바이더 중립적** 문구("From your usage history" / "From <provider> logs") 필요.

### 2.2 제거하거나 절제할 요소

- **"TOP DRIVER" 알약형 배지.**
  브랜드 블루 알약형 배지 안의 모두 대문자인 문구는 macOS UI가 아닌 마케팅 언어.
  Apple은 가장 큰 기여자를 **순위 + 차분한 단어**(스크린 타임의 "Most used")로 표시하거나 별도 라벨 없이 **첫 번째에 배치**(저장 공간, 활성 상태 보기).
  알약형 배지 제거.
- **과도하게 큰 58% 도넛.**
  문제는 세 가지: (1) 도넛과 행별 막대가 모두 전체 중 점유율을 표현해 같은 정보를 두 번 전달, (2) 58%가 전체 모델 지출의 58%라는 텍스트에도 표시되어 같은 정보를 *세 번* 전달, (3) 전체 구성을 한눈에 볼 때 쓰는 링 차트보다 5개 행의 내역에서는 순위 목록이 더 적합.
  스크린 타임, 저장 공간, 배터리 모두 같은 사례에서 링 미사용.
  도넛 제거.
- **카드 속 히어로 카드.**
  팝오버 카드 안의 파란 그라디언트 카드는 앱의 평평하고 테두리 없는 그룹 카드 언어와 충돌하는 무거운 시각적 계층.
  앱의 카드는 `traySurface` 위에 `.fill.quaternary`를 사용하고 스트로크가 없으므로, 콘셉트의 짙은 파란 그라디언트 카드는 전혀 다른 디자인 시스템.
  히어로 카드를 제거하고 최상위 행도 다른 행과 같은 목록에 배치하되 순위 + 차분한 "Top" 태그로만 표시.
- **일관되지 않은 글자 크기.**
  콘셉트에는 아주 큰 58%, 작은 TOP DRIVER 라벨, 중간 크기 모델 이름, 또 다른 굵기의 달러 금액이 혼재.
  앱의 규칙은 역할별 포인트 크기 하나와 굵기만을 이용한 계층 구성.
  패널의 글자 크기는 **최대 두 가지**로 제한: 행 크기(= `supportingPointSize`, 12/11)와 헤더 크기(= `headerPointSize`, 14/13).
- **모델별 프로바이더 로고.**
  콘셉트에는 GPT의 OpenAI 로고, Claude의 Anthropic 마크, Bugbot 로봇 등 표시.
  앱에는 **모델별 브랜드 에셋이 없고**, *프로바이더*별 `ProviderIcon` 하나만 섹션 헤더에 한 번 사용.
  모델별 로고 추가는 브랜드 부담, 범위 확대, 라이선스와 유지 관리 부담을 초래.
  내역의 항목별 아이콘에 대한 Apple의 네이티브 대안은 **아이콘 없음**(스크린 타임은 설치된 앱이라 앱 아이콘 사용, 저장 공간은 카테고리 기호 사용, 활성 상태 보기는 프로세스별 목록에 아이콘 미사용).
  모델에는 **앞쪽의 중립적 모노그램**(보조색으로 물들인 작은 원 안의 첫 글자) 또는 **아이콘 없음**이 네이티브한 선택.
  권장은 첫 버전에서 아이콘을 빼고 부담이 적은 후속 개선으로 모노그램 검토.
- **모든 행의 오른쪽 셰브론.**
  콘셉트에서는 모든 행이 모델 상세 화면으로 이동 가능한 모습.
  범위 안에 모델별 상세 화면이 없으므로 셰브론은 잘못된 신호.
  제거하거나 상세 화면을 계획한 경우에만 최상위 모델에 추가.
- **제목으로서의 "Models".**
  패널의 범위는 한 프로바이더의 한 기간 지출이므로 일반적인 "Models"보다 **기간**("Last 30 Days" / "Today" / "Yesterday")이 적절한 제목.
  프로바이더 이름은 사용자가 호버한 섹션 헤더에 이미 있어 반복할 필요가 없지만, *기간*은 호버에 따라 바뀌며 확인이 필요한 변수.

### 2.3 Apple 방식

네 가지 네이티브 사례:

- **활성 상태 보기 ▸ 에너지 ▸ "12 hr Power" 목록** — 아이콘과 막대 없이 행별 백분율만 표시하는 프로세스의 평면 순위 목록.
  가능한 가장 가벼운 표현.
- **스크린 타임 ▸ See All App & Website Activity** — 앱 아이콘, 이름, 사용 시간, 얇은 비례 막대를 갖춘 순위 목록.
  막대는 전체 너비의 저대비 표현이며 행별 카드는 없음.
  최상위 앱은 목록의 첫 번째 항목일 뿐.
- **배터리 메뉴 막대 항목 ▸ "Apps Using Significant Energy"** — 막대와 아이콘 없이 앱 이름 + "%"만 표시하는 평면 목록.
  간결하고 빠르게 훑을 수 있으며 쉽게 닫을 수 있는 구성.
- **시스템 설정 ▸ 저장 공간** — 크기 순으로 정렬된 카테고리마다 작은 글리프 + 이름 + 크기 + 얇은 비례 막대 표시.
  상단에는 차분한 요약 하나("System Data — 42.3 GB of 512 GB") 배치.

공통 형태는 **총량 + 기간이 있는 헤더 한 줄, 평면 순위 목록, 이름 + 숫자 + 선택적 얇은 비례 막대로 구성된 각 행, 히어로 카드·도넛·모두 대문자인 배지 없음**.
이 형태가 목표.

---

## 3. 세 가지 구체적인 네이티브 방향

세 방향 모두 기존 `.popover(arrowEdge: .top)` + `TrendHoverState` 스타일 호버 코디네이터(400ms 표시 대기, 180ms 유예, 팝오버 닫힘 시 `dismissAll()`)로 호버된 지출 행에 연결.
차이는 내부에서 내역을 그리는 방식.

### 방향 A — 평면 순위 목록(스크린 타임 스타일) **[권장]**

```
┌──────────────────────────────────────┐
│ Last 30 Days              $8.8K · 9B │  ← 헤더: 왼쪽 기간, 오른쪽 합계(headerPointSize / supportingPointSize, .primary / .secondary)
│ Top model Claude 4.8 Opus    $5.1K  │  ← 첫 행, 차분한 "Top model" 태그, 세미볼드 이름
│ ─────────────────────────────────── │  ← .separator 불투명도, 전체 너비
│   Claude 4.8 Opus   2.9B    $5.1K ▓▓▓▓▓▓▓▓░░ 58%
│   GPT-5.5           827M    $1.7K ▓▓▓░░░░░░░ 19%
│   Claude Fable 5    412M    $661  ▓░░░░░░░░░  7%
│   Claude 4.7 Opus   294M    $470  ▓░░░░░░░░░  5%
│   Other             181M    $290  ░░░░░░░░░░  3%
│ From your usage history (estimated) │  ← 10pt .secondary 출처 노트
└──────────────────────────────────────┘
```

**구조:**

- `VStack(alignment: .leading, spacing: 8)` 하나, 패딩 12, 너비 **280pt**(240pt 추세 팝오버와 320pt 메인 팝오버 사이로, 막대 + 수치를 담기에 충분히 넓고 상세로 보일 만큼 좁은 크기).
- **헤더 행:** `HStack(firstTextBaseline)`.
  왼쪽: 기간 이름("Today" / "Yesterday" / "Last 30 Days"), `headerPointSize`(14/13), `.semibold`, `.primary`.
  오른쪽: 기간 합계("$8.8K · 9B tokens"), `supportingPointSize`(12/11), `.monospacedDigit`, `.secondary`.
  차트 제목 자리에 기간 이름을 넣은 `UsageTrendDetail.header` 패턴 그대로.
- **최상위 모델 요약 한 줄**(카드가 아닌 한 줄): "Top model Claude 4.8 Opus · $5.1K (58%)", `supportingPointSize`, `.secondary`, 모델 이름과 백분율은 강조를 위해 `.primary`.
  스크린 타임의 "Most used" 관용구와 같은 차분한 한 줄이며 알약형 배지와 도넛 없음.
  선택 사항으로, 목록이 3개 행 이하라면 순위만으로 충분하므로 생략.
- **구분선:** `Divider().opacity(0.5)` 또는 0.5pt `.separator` 스트로크, 전체 너비.
- **순위 목록:** 각 행으로 구성된 `VStack(spacing: 0)`:

  ```swift
  HStack(alignment: .firstTextBaseline, spacing: 8) {
    Text(model.name)
      .font(.system(size: density.supportingPointSize, weight: .semibold))
      .foregroundStyle(.primary)
      .lineLimit(1)
      .layoutPriority(1)
    Spacer(minLength: 8)
    Text(model.tokensCompact)          // "2.9B" — 고정폭 숫자, .secondary
    Text(model.spendCompact)           // "$5.1K" — 고정폭 숫자, .primary, 핵심 값
      .frame(minWidth: 48, alignment: .trailing)
  }
  .font(.system(size: density.supportingPointSize))
  .monospacedDigit()
  // 행 아래에 전체 너비 비례 막대 배치:
  Capsule().fill(.quaternary)
    .overlay(alignment: .leading) { Capsule().fill(Theme.meterFill(.normal)).frame(width: barWidth) }
    .frame(height: 3)                 // 한도가 아닌 점유율이므로 미터 캡슐(5pt)보다 얇게
  ```

  행 세로 패딩은 텍스트 행 리듬인 6pt(Compact 4pt).
  행별 아이콘 없음.
  셰브론 없음.
  최상위 행은 이름 앞에 차분한 "Top" 태그(`Text("Top").font(.system(size: 10)).foregroundStyle(.tertiary)`)를 붙이거나 태그를 생략하고 순위만으로 표시.
  한 행을 호버하면 나머지 행의 불투명도를 0.35로 낮추는 `UsageTrendDetail` 선택 방식을 적용해 호버 단서로도 활용.
- **출처 노트:** 10pt, `.secondary`, 프로바이더별 출처 문자열("From your Claude usage history (estimated)" / "From your Cursor usage export" / "From your Codex logs (estimated)").
  `estimated` 플래그는 이미 `SpendTileMapper`에 프로바이더별로 존재.

**글자 크기 체계:** 정확히 두 가지 크기 — `headerPointSize`(헤더)와 `supportingPointSize`(나머지 전체).
굵기만으로 계층 구성: 이름과 기간은 세미볼드, 수치와 출처 노트는 레귤러.
앱의 기존 규칙과 일치하며 콘셉트의 불규칙한 크기를 바로잡는 방식.

**차트 표현:** 도넛 없음.
행별 비례 `Capsule`이 곧 차트.
행별로 선택적으로 표시하는 점유율 숫자("58%") 하나만 중복되며, 막대만으로 정확한 값을 표시할 수 없다는 점을 보완 — 앱이 미터 아래에 "52% left" 텍스트를 두는 방식과 같은 규칙.

**머티리얼:** `.popover`는 시스템이 렌더링(실제 macOS 팝오버 크롬, 화살표, 머티리얼).
내부 배경은 시스템 팝오버 머티리얼이므로 목록 뒤에 커스텀 `cardSurface`를 칠하면 팝오버와 충돌하며 **사용 금지**.
목록 행은 `UsageTrendDetail`처럼 테두리 없음.
내부에 Liquid Glass 없음.

**기간 범위:** 헤더 왼쪽 단어가 곧 기간("Today" / "Yesterday" / "Last 30 Days")이므로 별도 부제목 없이 제목 자체로 범위 전달.
호버된 행의 라벨과 이미 일치하며 패널은 그 범위를 재확인하는 역할.

**크기:** 너비 280pt로, 320pt 팝오버의 옆이나 위에 충분한 여백을 두고 배치 가능.
높이는 콘텐츠에 맞춰 자동 결정하며, 스크롤 없이 약 6개 행까지 표시하고 이후 스크롤 적용(대부분 사용자의 모델이 5개 이하라 드문 상황).

### 방향 B — 헤더 요약 막대 + 목록(저장 공간 스타일)

A와 같지만 "Top model …" 요약 한 줄 대신 상위 3~4개 모델의 점유율을 한눈에 보여 주는 **전체 너비 비례 누적 막대 하나**를 헤더에 배치하고 아래에 순위 목록 구성.
시스템 설정 ▸ 저장 공간 패턴(상단의 한 줄 누적 막대 다음에 카테고리 목록)과 동일.

```
┌──────────────────────────────────────┐
│ Last 30 Days              $8.8K · 9B │
│ ▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░░░░░░░░ │  ← 누적 막대 하나: Opus | GPT-5.5 | Fable | 나머지
│ ─────────────────────────────────── │
│   Claude 4.8 Opus   $5.1K  58%      │
│   GPT-5.5           $1.7K  19%      │
│   …                                 │
```

- 누적 막대는 수작업으로 렌더링(`RoundedRectangle` 조각의 `HStack(spacing: 0)` 또는 `Canvas`)하며, 조각마다 서로 다른 **시스템 틴트** 색상(파랑 / 틸 / 인디고 / 회색 — 프로바이더 브랜드 색상 아님) 적용.
  콘셉트의 도넛이 노린 한눈에 보는 점유율 파악을 Apple이 사용하는 형태로 제공하며 행별 막대와도 중복되지 않는 방식.
- 비용은 두 번째 차트 형태(누적 막대 + 행별 막대)와 현재 앱에 없는 모델별 색상 결정.
  현재까지 앱에서는 모델별 색상을 피했고 `Theme.meterFill`도 심각도에 따라 행마다 색상 하나만 사용.
  모델별 팔레트 도입은 작지만 실질적인 디자인 시스템 변화.

이 방향은 **A보다 조금 풍부**하면서 여전히 네이티브지만, 모델별 색상 결정과 두 번째 차트를 추가.
한눈에 보는 점유율의 가치가 추가 UI 요소를 정당화할 때만 선택.

### 방향 C — 도넛 + 목록(콘셉트를 다듬은 버전)

도넛을 유지하되 네이티브하게 구성: 헤더 오른쪽에 작은(~64pt) 수작업 `Canvas` 도넛을 두고 최상위 모델은 시스템 블루, 나머지는 `.quaternary`로 표시(모델별 색상이 아닌 단일 색상)하며 중앙에는 최상위 모델의 백분율을 `headerPointSize`로 표시.
히어로 카드, 알약형 배지, 모델별 로고, 셰브론 제거.
아래 목록은 방향 A의 목록 사용.

```
┌──────────────────────────────────────┐
│ Last 30 Days       ╭───╮   $8.8K · 9B│
│                    │58%│             │
│                    ╰───╯             │
│ ─────────────────────────────────── │
│   Claude 4.8 Opus   $5.1K  ▓▓▓▓░░░░ │
│   …                                 │
```

- 장점: 콘셉트가 의도한 최대 기여 모델 파악을 간결하고 네이티브한 형태로 유지.
- 단점: (1) 도넛 조각과 행별 막대가 모두 "58%"를 나타내 정보 중복, (2) 280pt 팝오버에서 도넛이 헤더 공간을 차지해 목록을 아래로 밀어냄, (3) `SectorMark`(Swift Charts)는 macOS 26 이상과 `#available` 게이트가 필요하고 앱에는 **현재 Swift Charts 의존성이 없음**("No new dependencies without justification", AGENTS.md) — 따라서 수작업 `Canvas`/`Path` 도넛이 필요하지만 중복되는 행별 막대보다 코드가 많음, (4) 네 가지 네이티브 사례(활성 상태 보기, 스크린 타임, 배터리, 저장 공간) 중 같은 상황에서 도넛을 쓰는 사례 **없음**.
  세 방향 중 Apple 네이티브와 가장 먼 선택.

---

## 4. 권장 사항

**방향 A — 평면 순위 목록.**
이유:

1. **네이티브 관용구.**
   총량을 기여자별로 나누는 네 가지 Apple 사례 모두 선택적 얇은 막대가 있는 평면 순위 목록을 쓰며 링 차트는 미사용.
   소유자가 "over the top"이라고 평가한 콘셉트의 도넛 + 히어로 카드를 A가 정확히 제거.
2. **앱의 기존 호버 상세 패턴을 그대로 재사용.**
   `UsageSparkline` → `UsageTrendDetail`은 이미 `TrendHoverState` 스타일 400ms/180ms 코디네이터가 있는 `.popover(arrowEdge: .top)`, `headerPointSize` 제목 + `supportingPointSize` 고정폭 수치 헤더, 평면 차트 본문, 10pt `.secondary` 출처 노트로 구성.
   모델 패널은 막대 대신 순위 목록을 넣은 같은 골격으로, 호버 동작·닫기·폰트·머티리얼 모두 동일.
   같은 컴포넌트이므로 자연스럽게 앱의 일부로 보이는 결과.
3. **앱이 이미 적용하는 디자인 언어 규칙과 일치.**
   두 가지 글자 크기, 굵기만으로 구성한 계층, 값은 `.primary` / 맥락은 `.secondary`, 얇은 헤어라인 높이의 시스템 블루 `Capsule` 막대, 테두리 없는 행, 콘텐츠 레이어의 Liquid Glass 제외, 배경은 시스템 팝오버 머티리얼.
   새 색상, 새 의존성, 모델별 브랜드 에셋 모두 불필요.
4. **구조 자체가 프로바이더 중립적.**
   프로바이더 로고가 없고 제목과 푸터에 "Cursor"를 넣지 않으며, 기간 이름을 제목으로 사용하고 출처 노트에는 호버된 프로바이더를 표시.
   Claude / Codex / Cursor / Grok에서 모두 동일하게 동작.
5. **최대 기여 모델을 차분하게 강조.**
   순위 + "Top model" 요약 한 줄(스크린 타임의 "Most used" 관용구)로 알약형 배지나 링 없이 콘셉트가 의도한 강조 전달.
   목록이 짧다면(3개 이하) 요약 줄도 생략하고 순위만으로 충분.
6. **기존 데이터로 구현 가능.**
   기존 지출 프로바이더 세 곳 모두 모델별 집계 가능: Cursor CSV는 행마다 `Model` 컬럼 보유(`CursorUsageCSV.swift:9`), Claude 로그 스캐너는 JSONL 줄마다 `Entry.model` 보유(`ClaudeLogUsageScanner.swift:44`), Codex 스캐너는 이벤트마다 `currentModel` 추적(`CodexLogUsageScanner.swift:42`).
   현재 `SpendTileMapper`는 이를 일별 합계로 집계하면서 모델별 차원을 버리지만, 새 형제 매퍼가 기존 타일을 건드리지 않고 호버된 기간의 모델별 `[ModelShare]` 생성 가능.
   UI 전용 변경이 아닌 데이터 레이어 추가이므로 PR 계획에 명시 필요.

### 4.1 구현 전 소유자와 확인할 미결 사항

AGENTS.md에 따르면 지표 기본값(활성화, 주/보조, 고정, 순서)은 소유자 승인이 필요하며, 이 기능은 기존 지출 행에 추가하는 새로운 호버 상호작용이므로 다음 사항 확인 필요.

- **트리거:** Usage Trend와 같은 호버 전용인가, 호버 + 클릭인가?
  기존 값 툴팁과 충돌하지 않도록 같은 400ms 대기 시간을 적용한 호버 전용 권장(툴팁은 정확한 수치, 패널은 내역 표시).
- **값 툴팁과의 공존:** 지출 행에는 정확한 수치를 위한 `.hoverTooltip(data.unboundedValueTooltip)`이 이미 존재.
  패널은 **값 텍스트**에 앵커하고, 표시될 때 같은 정확한 수치를 첫 행에 담아 툴팁을 대체하는 방식이 적합.
  이 레이어링이 원하는 동작인지 확인 필요.
- **임계값:** 해당 기간의 모델이 2개 이상일 때만 패널을 표시할 것인가?
  모델이 하나뿐인 기간에는 분해할 내역이 없으므로 툴팁만으로 충분.
- **"Other" 묶음:** 목록을 이름이 있는 모델 5개 + 긴 꼬리를 위한 "Other" 행으로 제한(콘셉트와 일치).
  상한과 라벨("Other" / "Other models") 확인 필요.
- **프로바이더별 출처 노트 문구**("From your Claude usage history (estimated)" / "From your Cursor usage export" / "From your Codex logs (estimated)") — 문구, 특히 `estimated` 플래그의 근거 확인 필요.
- **밀도:** 다른 모든 표면처럼 패널에도 `DensitySetting`(Regular/Compact) 적용 필요 — 첫 버전부터 Compact를 지원할지 추후 지원할지 확인 필요.

### 4.2 명시적으로 제외할 요소

- 모델별 브랜드 아이콘 제외(소유자가 원할 때만 후속 버전에서 모노그램 검토).
- 도넛 / `SectorMark` / Swift Charts 의존성 제외.
- 히어로 카드, 그라디언트 카드 속 카드, "TOP DRIVER" 알약형 배지 제외.
- 행의 셰브론 제외(모델별 상세 화면은 범위 밖).
- 팝오버 내부 Liquid Glass 제외 — 시스템 팝오버 머티리얼만 사용.
- 프로바이더 브랜드 색상 제외 — 기존 미터/스파크라인 언어에 맞춰 모든 점유율 막대에 시스템 블루 사용.
