# 모델 호버 패널 — 네이티브 디자인 방향

> **과거 기록 / 대체됨.** 이 디자인 보고서는 2026-07-04에 출시된 모델 내역 호버 패널을 이끈
> 문서입니다. 현재 동작과 구현은 [대시보드 행](../../dashboard.md#행),
> [`HoverPopoverState.swift`](../../../../Sources/OpenUsage/Views/HoverPopoverState.swift),
> [`ModelUsageDetail.swift`](../../../../Sources/OpenUsage/Views/ModelUsageDetail.swift)을 참조하세요.
> 아래의 참조, 줄 번호, 제안된 컴포넌트 이름은 당시의 설계 결정 기록으로 원문 그대로 유지합니다.

**리서치 보고서 — 2026-07-04**
**질문:** 첨부된 AI 생성 콘셉트("TOP DRIVER" 히어로 카드, 도넛, 순위 모델 목록이 있는 "Models" 플라이아웃)를 고려할 때, Today / Yesterday / Last 30 Days 지출 행의 호버 패널은 어떤 모습이어야 하는가? 콘셉트에 대한 소유자의 평가는 방향은 맞지만 "a bit over the top"(다소 과함)이라는 것이었습니다. 글자 크기가 일관되지 않고 충분히 네이티브하지 않다는 뜻입니다. 목표는 OpenUsage에 어울리고 Cursor / Claude / Codex / Grok에서 동작하며 Cursor 브랜드에 종속되지 않는, Apple 우선의 macOS UI입니다.

---

## 요약

콘셉트의 *정보*(순위 모델 목록, 최대 기여 모델 강조, 모델별 비례 막대, 헤더의 기간 라벨)는 유지하고 *연출*("TOP DRIVER" pill, 과도하게 큰 도넛, 카드 속 카드 중첩, 혼합된 글자 크기 체계, 모델별 프로바이더 로고)은 버립니다. "총량을 기여자별로 분해"하는 Apple의 네이티브 패턴 — 활성 상태 보기의 에너지 탭, 스크린 타임의 앱별 목록, 배터리 메뉴 막대 항목의 앱별 사용량, 시스템 설정 ▸ 저장 공간 — 은 **비례 가로 막대와 조용한 요약 한 줄을 갖춘 평평하고 간결한 순위 목록**이지, 링 차트를 둔 히어로 카드가 아닙니다.

권장 방향: **호버된 지출 행에 앵커된 작은 SwiftUI `.popover`**(앱이 이미 `UsageSparkline` → `UsageTrendDetail`에 사용하는 바로 그 패턴)로, 지출 순으로 정렬된 단일 평면 모델 목록을 담습니다. 각 행은 라벨 + 고정폭 달러 수치 + 얇은 비례 `Capsule` 막대이고, 기간과 최상위 모델을 알려 주는 조용한 헤더가 하나 있습니다. 도넛도, 히어로 카드도, 모델별 아이콘도, 새 의존성도 없습니다. 최대 기여 모델 강조는 떠들썩한 pill이 아니라 **순위 + 선두 행의 단 하나의 세미볼드 "Top" 태그**에서 나옵니다 — 스크린 타임이 가장 많이 쓴 앱을 표시하는 방식처럼요.

---

## 1. 앱의 기존 디자인 언어(구체적 카탈로그)

`Sources/OpenUsage/Views/` + `Sources/OpenUsage/Stores/DensitySetting.swift` + `Sources/OpenUsage/Support/Theme.swift` + `Sources/OpenUsage/Support/LiquidGlassFallbacks.swift`에서 읽어낸 내용입니다. 새 패널은 이와 일치해야 합니다.

### 1.1 타이포그래피 체계(시맨틱 스타일이 아닌 명시적 포인트 크기)

앱은 데이터 행에 시맨틱 `.headline` / `.subheadline` / `.caption`을 사용하지 **않습니다**. "semantic `.headline.weight(.regular)` does not match `.headline` on macOS"(`WidgetRowView.swift:33-36`)이기 때문에 `DensitySetting`을 통해 명시적 포인트 크기를 결정합니다. 모든 크기는 Compact에서 1포인트씩 작아집니다.

| 역할 | Regular | Compact | 굵기 | 전경색 |
|---|---|---|---|---|
| 프로바이더 섹션 헤더(이름) | 14 | 13 | `.semibold` | `.primary` |
| 지표 행 라벨 | ~13(`NSFont.headline` 기준) | 기준 − 1 | `.semibold` | `.primary` |
| 보조 / 상세 / 막대 아래 | 12 | 11 | `.regular` | 값은 `.primary`, 맥락은 `.secondary` |
| 요금제 배지, stale 태그 | 11 | 10 | `.regular` | `.secondary` / `.tertiary` |
| 내비게이션 바 제목(Customize/Settings) | — | — | `.headline`(시맨틱) | — |
| 푸터 식별 정보("OpenUsage 0.7.x", "Next update in 3m") | — | — | `.caption2`(시맨틱) | `.secondary` |
| UsageTrendDetail 헤더 제목 | 13 | — | `.semibold` | `.primary` |
| UsageTrendDetail 수치 / 축 / 노트 | 11 / 10 | — | `.regular` | `.secondary`, `.monospacedDigit()` |
| 툴팁 말풍선 | 12 | — | `.regular` | `.primary` |
| "Copied to clipboard" pill | 12 | — | `.semibold` | `Theme.positive` |

**패널이 따라야 할 규칙:**

- 값(사용자가 팝오버를 열어 읽으려는 숫자)은 `.primary`이고, 그 주변 요소(기간 라벨, 출처 노트, "Top" 태그)는 `.secondary`입니다. `.tertiary`는 글래스 위의 비활성 콘텐츠용으로 예약되어 있습니다(`ProviderSectionHeader.swift:73-80`).
- 숫자는 `.monospacedDigit()`과 `.contentTransition(.numericText())`를 사용해 실시간으로 갱신되는 수치가 떨리지 않게 합니다(`DashboardView.swift:701-709`, `WidgetRowView.swift:226`).
- 한 줄 행에서 라벨과 값은 **같은 포인트 크기**를 공유하며, 굵기만으로 계층을 만듭니다("semibold alone keeps the name/value hierarchy", `WidgetRowView.swift:308-310`). 콘셉트 스크린샷은 이를 위반합니다 — 달러 금액이 모델 이름과 다른 크기/굵기로 읽힙니다.

### 1.2 레이아웃 치수(4pt 그리드)

- **팝오버 너비: 320pt 고정**(`DashboardView.swift:64`). 작업 브리프의 "~360pt"는 실제 패널보다 약간 넓습니다. 호버 패널은 같은 계열로 느껴지도록 320 *이하*에 두어야 합니다. 기존 `UsageTrendDetail`은 240pt로, 편안한 상세 팝오버로 읽힙니다.
- 외곽 패딩: 가로 14pt. 행 가로 패딩: 14pt. 카드 거터: 5pt(Compact 3pt).
- 섹션 간격: 14pt(Compact 8pt). 헤더→카드: 4pt(Compact 2pt).
- 텍스트 행 세로 패딩: 6pt(Compact 4pt). 연속된 텍스트 행은 2pt(Compact 1pt)로 압축되어 Today / Yesterday / Last 30 Days가 **균등 간격의 전체 높이 행이 아니라 하나의 묶음**으로 읽힙니다(`WidgetRowView.swift:60-77`). 이 압축 규칙이 순위 목록과 가장 직접적으로 관련된 선례입니다 — 호버 행도 같은 방식으로 동작해야 합니다.
- 카드 모서리 반경: 12pt, `.continuous`(`Theme.swift:60`). 호버 패널 자체는 시스템 `.popover`이므로 바깥 모서리는 시스템이 그립니다. 패널 내부 카드(유지한다면)는 12pt를 사용합니다.
- 미터 캡슐 높이: 5pt(Compact 4pt) — 두툼한 판이 아니라 의도적으로 얇은 헤어라인입니다("a 10pt bar read as a chunky slab next to them", `DensitySetting.swift:52-54`).
- 스파크라인 높이: 18pt(Compact 14pt). 추세 상세 차트 높이: 너비 240pt에서 76pt.

### 1.3 머티리얼과 색상

- **페이지 표면:** `Theme.traySurface` = `NSColor.textBackgroundColor` — 불투명하고, 라이트 모드에서는 흰색 / 다크 모드에서는 거의 검정색이며, 데스크톱 틴트가 없습니다. 팝오버는 하나의 단단한 패널로 읽힙니다.
- **그룹 카드:** `Theme.cardShape`(RoundedRect r=12)에 `traySurface` 채우기 + `.fill.quaternary` 오버레이 — macOS 시스템 설정의 그룹 박스 룩이며, **테두리 없음**(활성 카드에 스트로크 없음). 헤어라인 `.separator` 스트로크는 떠 있는 단일 행 칩에만 나타납니다(`Theme.swift:83-86`).
- **Liquid Glass는 크롬 전용** — 푸터/상단 바(`barGlass()`)와 컨트롤(`glassButtonStyle`, `interactiveGlass`)에만 쓰이며 데이터 카드에는 절대 쓰이지 않습니다. `Theme.swift:7-9`와 `liquid-glass` 스킬은 명시적으로 말합니다: "keep Liquid Glass out of the content layer and back content with standard materials instead." 어두운 그라디언트 위에 반투명 카드 속 카드를 올린 콘셉트는 이 규칙의 정반대입니다.
- **미터 / 막대 채우기는 시스템 팔레트를 최대 강도로 사용:** 파랑 = `systemBlue`, 노랑 = `systemYellow`, 빨강 = `systemRed`(`Theme.swift:25-31`). 프로바이더 브랜드 그라디언트는 없습니다. 추세 스파크라인은 정상 상태 미터와 같은 파랑을 사용합니다(`Theme.meterFill(.normal)`). 호버 패널의 비례 "점유" 막대도 이 파랑을 사용해야 합니다 — "이것은 사용량 수치다"라는 확립된 색입니다.
- 알림 = 시스템 오렌지, 긍정 = 시스템 그린.

### 1.4 기존 호버 상세 선례(따라 할 패턴)

`UsageSparkline` → `UsageTrendDetail`(`UsageSparkline.swift:38-47`, `UsageTrendDetail.swift`)은 앱에 존재하는 유일한 "행을 호버하면 더 풍부한 내역 표시" 흐름이며, 모델 패널에 적합한 골격입니다:

- SwiftUI `.popover(isPresented:)`와 `arrowEdge: .top`으로 앵커하며, 행 전체가 아니라 **막대 스트립**에 앵커되어 화살표가 차트를 가리킵니다.
- `TrendHoverState`(`@Observable`)가 구동합니다: **400ms 표시 지연**, 커서가 인라인 행에서 팝오버로 이동하는 동안 닫히지 않게 하는 **180ms 유예**. 팝오버가 고아가 되지 않도록 팝오버의 닫기 경로에서 `dismissAll()`이 호출됩니다(`DashboardView.swift:255-258`).
- 너비 240pt, 내부 패딩 12pt. 헤더는 왼쪽 제목 + 오른쪽 고정폭 수치, 그 다음 차트, 축 행, 선택적 10pt 출처 노트 순입니다. 카드 속 카드가 아니라 패딩이 있는 하나의 평면 `VStack`입니다.
- 막대를 호버하면 나머지가 불투명도 0.35로 흐려집니다 — "두 번째 색 없이 선택을 읽게 하는" 트릭입니다. 모델 패널도 호버된 행에 이를 재사용할 수 있습니다.

모델 패널은 막대 차트 자리에 순위 목록을 넣은 **같은 컴포넌트 형태**여야 합니다.

### 1.5 호버 툴팁(더 가벼운 선례, 그리고 여기서는 충분하지 않은 이유)

`.hoverTooltip(_)`(`HoverTooltip.swift`)은 팝오버보다 한 단계 위의 별도 클릭스루 `NonKeyPanel`에 한 줄짜리 텍스트 말풍선을 그립니다. SwiftUI 오버레이는 팝오버 윈도우에 잘리고 툴팁은 자유롭게 떠야 하기 때문에 존재합니다. 하지만 **텍스트 전용**이라 막대가 있는 순위 목록을 담을 수 없습니다. 모델 내역에는 툴팁 경로가 아니라 `.popover` 경로가 필요합니다. (툴팁은 지출 행에서 이미 사용하는 "값 위에 마우스를 올리면 정확한 수치 표시" 상호작용에는 여전히 적합하고, 패널은 그 위에 겹쳐 표시할 수 있습니다.)

---

## 2. 첨부된 콘셉트 스크린샷 비평

### 2.1 유지할 것

- **순위 모델 목록.** 이것이 바로 Apple이 총량을 기여자별로 분해하는 방식입니다(스크린 타임, 저장 공간, 활성 상태 보기 에너지). 순위가 가장 명확한 신호입니다.
- **모델별 비례 막대.** 행당 얇은 비례 막대는 네이티브 관용구입니다 — 스크린 타임의 앱별 목록과 저장 공간의 카테고리별 목록이 모두 이 방식입니다. 이미 미터 캡슐 형태로 앱의 시각 어휘에 들어 있습니다.
- **헤더의 기간 라벨**("Last 30 Days"). 데이터는 호버된 행으로 범위가 정해지므로 패널은 어떤 기간인지 말해야 합니다. 조용하게, 뒤쪽에, `.secondary`로 — 콘셉트는 배치는 맞지만 굵기가 틀렸습니다(제목과 경쟁하고 있음).
- **최대 기여 모델 강조.** 사용자는 "이 기간에 어떤 모델이 지배했는지" 진짜로 알고 싶어 합니다. 강조 자체는 옳습니다. 과한 것은 강조의 *형태*(pill + 도넛 + 히어로 카드)입니다.
- **푸터 출처 한 줄**("From your Cursor usage history"). 앱은 이미 `UsageTrendDetail`에서 이를 수행합니다(`note`, 10pt `.secondary`). 좋습니다 — 단, 패널이 Claude / Codex / Grok에도 쓰이므로 Cursor 브랜딩이 아니라 **프로바이더 중립적**("From your usage history" / "From <provider> logs")이어야 합니다.

### 2.2 버리거나 톤 다운할 것

- **"TOP DRIVER" pill.** 브랜드 블루 pill 안의 전 대문자 배지는 macOS UI가 아니라 마케팅 언어입니다. Apple은 가장 큰 기여자를 **순위 + 조용한 한 마디**(스크린 타임의 "Most used")로 표시하거나, 아무 라벨도 없이 **맨 앞에 두기만** 합니다(저장 공간, 활성 상태 보기). pill은 버립니다.
- **과도하게 큰 58% 도넛.** 세 가지 문제가 있습니다: (1) 도넛은 행별 막대와 중복됩니다 — 둘 다 "전체 중 점유율"을 인코딩하므로 사용자는 같은 사실을 두 번 읽습니다. (2) 58%는 이미 "58% of all model spend"라는 텍스트로 표시되어 *세 번* 나타납니다. (3) 5개 행 내역에 링 차트는 잘못된 차트 형태입니다 — 링은 *전체의 구성 요소를 한눈에* 보여 주기 위한 것이고, 순위 목록이 이미 그것을 더 잘합니다. 스크린 타임, 저장 공간, 배터리 모두 정확히 이 경우에 링을 생략합니다. 도넛은 버립니다.
- **히어로 카드 속 카드.** 팝오버 카드 안에 중첩된 그라디언트 파란 카드는 앱의 평평하고 테두리 없는 그룹 카드 언어와 충돌하는 무거운 시각적 계층입니다. 앱의 카드는 `traySurface` 위에 `.fill.quaternary`이고 스트로크가 없습니다 — 콘셉트의 짙은 파랑 그라디언트 카드는 완전히 다른 디자인 시스템에서 온 것입니다. 히어로 카드는 버리고, 최상위 행이 다른 행들과 같은 목록에 살게 하되 순위 + 조용한 "Top" 태그로만 표시하세요.
- **불일치하는 글자 크기.** 콘셉트는 아주 큰 58%, 작은 TOP DRIVER 라벨, 중간 크기 모델 이름, 그리고 또 다른 굵기의 달러 금액을 섞습니다. 앱의 규칙은 역할당 하나의 포인트 크기, 굵기만으로 계층을 만드는 것입니다. 패널은 **최대 두 가지 크기**만 사용해야 합니다: 행 크기(= `supportingPointSize`, 12/11)와 헤더 크기(= `headerPointSize`, 14/13).
- **모델별 프로바이더 로고.** 콘셉트는 GPT에는 OpenAI 로고를, Claude에는 Anthropic 마크를, Bugbot에는 로봇 등을 그립니다. 앱은 **모델별 브랜드 에셋을 포함하지 않습니다** — *프로바이더*당 하나의 `ProviderIcon`만 포함해 섹션 헤더에 한 번 사용합니다. 모델별 로고를 추가하면 브랜드 부담과 범위, 라이선스 및 유지 관리 부담이 커집니다. "내역의 항목별 아이콘"에 대한 Apple의 네이티브 대안은 **아이콘을 생략하는 것**입니다(스크린 타임은 설치된 앱이라 앱 아이콘을 쓰고, 저장 공간은 카테고리 기호를 쓰며, 활성 상태 보기는 프로세스별 목록에 아이콘을 쓰지 않습니다). 모델에는 **중립적인 첫 글자 모노그램**(작은 보조색 원 안에 표시) 또는 **아이콘 없음**이 네이티브한 선택입니다. 권장: 처음에는 아이콘을 넣지 않고, 모노그램은 부담이 적은 후속 개선으로 남깁니다.
- **모든 행의 오른쪽 셰브론.** 콘셉트는 모든 행이 모델 상세로 탭 가능해 보이게 합니다. 뒤에 모델별 상세 화면이 없다면(범위상 없음), 셰브론은 거짓말입니다. 버리거나, 상세가 계획되어 있다면 최상위 모델에만 추가하세요.
- **제목으로서의 "Models".** 패널은 한 프로바이더의 한 기간 지출로 범위가 정해집니다. 제목은 일반적인 단어 "Models"가 아니라 **기간**("Last 30 Days" / "Today" / "Yesterday")을 담아야 합니다. 프로바이더 이름은 사용자가 호버해 온 섹션 헤더에 이미 있으므로 반복은 중복이지만, *기간*은 호버에 따라 바뀌는 변수로, 사용자가 확인할 수 있어야 하는 대상입니다.

### 2.3 Apple이라면 이렇게 할 것

네 가지 네이티브 레퍼런스를 보세요:

- **활성 상태 보기 ▸ 에너지 ▸ "12 hr Power" 목록** — 프로세스의 평면 순위 목록. 아이콘도, 심지어 막대도 없이 행당 백분율만 있습니다. 가능한 가장 가벼운 처리입니다.
- **스크린 타임 ▸ See All App & Website Activity** — 앱 아이콘, 이름, 사용 시간, 얇은 비례 막대가 있는 순위 목록. 막대는 전체 너비에 저대비이며 각 행 주위에 카드가 없습니다. 최상위 앱은 그냥 목록의 첫 번째입니다.
- **배터리 메뉴 막대 항목 ▸ "Apps Using Significant Energy"** — 평면 목록. 막대도 아이콘도 없이 앱 이름 + "%"만 있습니다. 간결하고, 훑어보기 쉽고, 닫을 수 있습니다.
- **시스템 설정 ▸ 저장 공간** — 크기 순으로 정렬된 카테고리. 각각 작은 글리프 + 이름 + 크기 + 얇은 비례 막대입니다. 상단에 조용한 요약이 하나 있습니다("System Data — 42.3 GB of 512 GB").

공통 형태는 이렇습니다: **총량 + 기간이 있는 헤더 한 줄, 그 다음 평면 순위 목록. 각 행 = 이름 + 숫자 + 선택적 얇은 비례 막대. 히어로 카드도, 도넛도, 전 대문자 배지도 없음.** 이것이 목표입니다.

---

## 3. 세 가지 구체적인 네이티브 방향

세 가지 모두 기존 `.popover(arrowEdge: .top)` + `TrendHoverState` 스타일 호버 코디네이터(400ms 표시 지연, 180ms 유예, 팝오버 닫힘 시 `dismissAll()`)로 호버된 지출 행에 앵커합니다. 차이는 내역을 내부에 그리는 방식입니다.

### 방향 A — 평면 순위 목록(스크린 타임 스타일) **[권장]**

```
┌──────────────────────────────────────┐
│ Last 30 Days              $8.8K · 9B │  ← header: period left, total right (headerPointSize / supportingPointSize, .primary / .secondary)
│ Top model Claude 4.8 Opus    $5.1K  │  ← first row, "Top model" quiet tag, semibold name
│ ─────────────────────────────────── │  ← .separator opacity, full width
│   Claude 4.8 Opus   2.9B    $5.1K ▓▓▓▓▓▓▓▓░░ 58%
│   GPT-5.5           827M    $1.7K ▓▓▓░░░░░░░ 19%
│   Claude Fable 5    412M    $661  ▓░░░░░░░░░  7%
│   Claude 4.7 Opus   294M    $470  ▓░░░░░░░░░  5%
│   Other             181M    $290  ░░░░░░░░░░  3%
│ From your usage history (estimated) │  ← 10pt .secondary source note
└──────────────────────────────────────┘
```

**구조:**

- 하나의 `VStack(alignment: .leading, spacing: 8)`, 패딩 12, 너비 **280pt**(240pt 추세 팝오버와 320pt 메인 팝오버 사이. 막대 + 수치를 담기에 충분히 넓고, 상세로 느껴질 만큼 좁음).
- **헤더 행:** `HStack(firstTextBaseline)`. 왼쪽: 기간 이름("Today" / "Yesterday" / "Last 30 Days"), `headerPointSize`(14/13), `.semibold`, `.primary`. 오른쪽: 기간 합계("$8.8K · 9B tokens"), `supportingPointSize`(12/11), `.monospacedDigit`, `.secondary`. 차트 제목 자리에 기간 이름을 넣은 `UsageTrendDetail.header` 패턴 그대로입니다.
- **최상위 모델 요약 한 줄**(카드가 아닌 한 줄): "Top model Claude 4.8 Opus · $5.1K (58%)", `supportingPointSize`, `.secondary`, 모델 이름과 백분율은 강조를 위해 `.primary`. 스크린 타임의 "Most used" 관용구입니다 — 조용한 한 줄, pill도 도넛도 없음. 선택 사항이며, 목록이 3개 행 이하라면 생략합니다(그때는 순위만으로 충분).
- **구분선:** `Divider().opacity(0.5)` 또는 0.5pt `.separator` 스트로크, 전체 너비.
- **순위 목록:** 행들의 `VStack(spacing: 0)`. 각 행은 다음과 같습니다:

  ```swift
  HStack(alignment: .firstTextBaseline, spacing: 8) {
    Text(model.name)
      .font(.system(size: density.supportingPointSize, weight: .semibold))
      .foregroundStyle(.primary)
      .lineLimit(1)
      .layoutPriority(1)
    Spacer(minLength: 8)
    Text(model.tokensCompact)          // "2.9B" — monospacedDigit, .secondary
    Text(model.spendCompact)           // "$5.1K" — monospacedDigit, .primary, the payload
      .frame(minWidth: 48, alignment: .trailing)
  }
  .font(.system(size: density.supportingPointSize))
  .monospacedDigit()
  // then the proportional bar below the row, full width:
  Capsule().fill(.quaternary)
    .overlay(alignment: .leading) { Capsule().fill(Theme.meterFill(.normal)).frame(width: barWidth) }
    .frame(height: 3)                 // thinner than the meter capsule (5pt) because it's a share, not a limit
  ```

  행 세로 패딩 6pt(Compact 4pt) — 텍스트 행 리듬입니다. 행별 아이콘 없음. 셰브론 없음. 최상위 행은 이름 앞에 조용한 "Top" 태그(`Text("Top").font(.system(size: 10)).foregroundStyle(.tertiary)`)를 붙이거나 아예 태그 없이 둡니다 — 순위가 신호입니다. 호버된 행은 형제 행을 0.35로 흐리게 하는데(`UsageTrendDetail` 선택 트릭), 이는 호버 상호작용을 보완하는 역할도 겸합니다.
- **출처 노트:** 10pt, `.secondary`, 프로바이더의 출처 문자열("From your Claude usage history (estimated)" / "From your Cursor usage export" / "From your Codex logs (estimated)"). `estimated` 플래그는 이미 `SpendTileMapper`에 프로바이더별로 존재합니다.

**글자 크기 체계:** 정확히 두 가지 크기 — `headerPointSize`(헤더)와 `supportingPointSize`(나머지 전부). 굵기만으로 계층 구성: 이름과 기간은 세미볼드, 수치와 출처 노트는 레귤러. 앱의 기존 규칙과 일치하며 콘셉트의 불일치하는 크기를 바로잡습니다.

**차트 처리:** 도넛 없음. 행별 비례 `Capsule`이 차트입니다. 행당 하나의 선택적 "점유율" 숫자("58%")가 유일한 중복이며, 이는 막대가 정확히 라벨할 수 없는 하나의 수치입니다 — 앱이 미터 아래에 "52% left"를 텍스트로 두는 것과 같은 규칙입니다.

**머티리얼:** `.popover`는 시스템이 렌더링합니다(실제 macOS 팝오버 크롬, 화살표, 머티리얼). 내부 배경은 시스템 팝오버 머티리얼입니다 — 목록 뒤에 커스텀 `cardSurface`를 칠하지 **마세요**. 팝오버와 충돌합니다. 목록 행은 `UsageTrendDetail`처럼 테두리가 없습니다. 내부에 Liquid Glass 없음.

**기간 범위 지정:** 헤더 왼쪽 단어가 *곧* 기간("Today" / "Yesterday" / "Last 30 Days")이므로, 범위는 별도 부제목이 아니라 제목 자체로 전달됩니다. 호버된 행의 라벨과 이미 일치하며 — 패널이 이를 확인해 줍니다.

**크기:** 너비 280pt로, 320pt 팝오버 옆/위에 여유 있게 들어갑니다. 높이는 콘텐츠 기반(자동 맞춤)이며, 스크롤되기 전 최대 약 6개 행으로 제한합니다(드문 경우 — 대부분의 사용자는 모델이 5개 이하).

### 방향 B — 헤더 요약 막대 + 목록(저장 공간 스타일)

A와 동일하지만, "Top model …" 요약 한 줄 대신 상위 3~4개 모델의 점유율을 한눈에 보여 주는 **단일 전체 너비 비례 누적 막대**를 헤더에 두고, 그 아래에 순위 목록을 둡니다. 시스템 설정 ▸ 저장 공간 패턴(상단에 한 줄 누적 막대, 그 다음 카테고리 목록)입니다.

```
┌──────────────────────────────────────┐
│ Last 30 Days              $8.8K · 9B │
│ ▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░░░░░░░░ │  ← one stacked bar: Opus | GPT-5.5 | Fable | rest
│ ─────────────────────────────────── │
│   Claude 4.8 Opus   $5.1K  58%      │
│   GPT-5.5           $1.7K  19%      │
│   …                                 │
```

- 누적 막대는 수작업으로 그립니다(`RoundedRectangle` 세그먼트의 `HStack(spacing: 0)` 또는 `Canvas`). 각 세그먼트는 구분되는 **시스템 틴트** 색상(파랑 / 틸 / 인디고 / 회색 — 프로바이더 브랜드 색상 아님)입니다. 콘셉트의 도넛이 노리던 "한눈에 보는" 점유율 파악을 제공하되, Apple이 쓰는 형태로, 행별 막대와 중복 없이 제공합니다.
- 비용: 두 번째 차트 형태(누적 막대 + 행별 막대)와 앱이 현재 하지 않는 모델별 색상 결정. 앱은 지금까지 모델별 색상을 피해 왔습니다(`Theme.meterFill`은 심각도 기반, 행당 하나의 색). 모델별 팔레트 도입은 작지만 실질적인 디자인 시스템 변경입니다.

이 방향은 **A보다 약간 풍부**하고 여전히 네이티브하지만, 모델별 색상 결정과 두 번째 차트를 추가합니다. "한눈에 보는 점유율" 파악이 그 추가 표면을 정당화할 가치가 있을 때만 선택하세요.

### 방향 C — 도넛 + 목록(콘셉트를 정리한 버전)

도넛은 유지하되 네이티브하게 만듭니다: 헤더 오른쪽에 작은(~64pt) 수작업 `Canvas` 도넛을 두고, 최상위 모델은 시스템 블루, 나머지는 `.quaternary`(모델별이 아닌 단일 색상)로 칠합니다. 중앙에는 최상위 모델의 백분율을 `headerPointSize`로 표시합니다. 히어로 카드, pill, 모델별 로고, 셰브론은 버립니다. 아래 목록은 방향 A의 목록입니다.

```
┌──────────────────────────────────────┐
│ Last 30 Days       ╭───╮   $8.8K · 9B│
│                    │58%│             │
│                    ╰───╯             │
│ ─────────────────────────────────── │
│   Claude 4.8 Opus   $5.1K  ▓▓▓▓░░░░ │
│   …                                 │
```

- 장점: 콘셉트가 노리던 "최대 기여 모델" 파악을 간결한 네이티브 형태로 유지합니다.
- 단점: (1) 여전히 행별 막대의 정보와 중복됩니다(도넛 조각과 행 막대가 둘 다 "58%"를 말함). (2) 280pt 팝오버의 도넛은 헤더 공간을 잡아먹고 목록을 아래로 밉니다. (3) `SectorMark`(Swift Charts)는 macOS 26 이상과 `#available` 게이트가 필요하고, 앱은 **현재 Swift Charts 의존성이 없습니다**("No new dependencies without justification", AGENTS.md) — 따라서 수작업 `Canvas`/`Path` 도넛이 되는데, 이는 자신이 중복하는 행별 막대보다 코드가 더 많습니다. (4) 네 가지 네이티브 레퍼런스(활성 상태 보기, 스크린 타임, 배터리, 저장 공간) 중 정확히 이 경우에 도넛을 쓰는 것은 **없습니다**. 세 가지 중 가장 Apple 네이티브답지 않습니다.

---

## 4. 권장 사항

**방향 A — 평면 순위 목록.** 이유는 다음과 같습니다:

1. **네이티브 관용구입니다.** "총량을 기여자별로 분해"하는 네 개의 Apple 레퍼런스는 넷 모두 선택적 얇은 막대가 있는 평면 순위 목록을 쓰고 링 차트는 쓰지 않습니다. 콘셉트의 도넛 + 히어로 카드가 소유자가 "over the top"이라 부른 바로 그것이며, A는 정확히 그것을 제거합니다.
2. **앱의 기존 호버 상세 패턴을 통째로 재사용합니다.** `UsageSparkline` → `UsageTrendDetail`은 이미 `TrendHoverState` 스타일 400ms/180ms 코디네이터가 있는 `.popover(arrowEdge: .top)`, `headerPointSize` 제목 + `supportingPointSize` 고정폭 수치 헤더, 평면 차트 본문, 10pt `.secondary` 출처 노트를 출시했습니다. 모델 패널은 막대 대신 순위 목록을 넣은 같은 골격입니다 — 같은 호버 동작, 같은 닫기, 같은 폰트, 같은 머티리얼. 같은 컴포넌트*이기 때문에* 어울리게 느껴질 것입니다.
3. **앱이 이미 강제하는 디자인 언어 규칙과 일치합니다.** 두 가지 글자 크기, 굵기만으로 계층 구성, 값은 `.primary` / 맥락은 `.secondary`, 얇은 헤어라인 높이의 시스템 블루 `Capsule` 막대, 테두리 없는 행, 콘텐츠 레이어에 Liquid Glass 없음, 배경은 시스템 팝오버 머티리얼. 새 색상도, 새 의존성도, 모델별 브랜드 에셋도 없습니다.
4. **구조적으로 프로바이더 중립적입니다.** 프로바이더 로고도, 제목이나 푸터의 "Cursor"도 없습니다 — 기간 이름이 제목이고 출처 노트가 호버된 프로바이더를 담습니다. Claude / Codex / Cursor / Grok 모두에서 동일하게 동작합니다.
5. **최대 기여 모델 강조는 조용히 살아남습니다.** 순위 + "Top model" 요약 한 줄(스크린 타임의 "Most used" 관용구)이 pill이나 링 없이 콘셉트가 노리던 강조를 전달합니다. 목록이 짧으면(3개 이하) 요약 줄마저 생략됩니다 — 순위만으로 충분합니다.
6. **존재하는 데이터로 만들 수 있습니다.** 모델별 집계는 세 개의 확립된 지출 프로바이더 모두에서 실현 가능합니다: Cursor의 CSV는 행마다 `Model` 컬럼이 있고(`CursorUsageCSV.swift:9`), Claude의 로그 스캐너는 JSONL 줄마다 `Entry.model`을 담으며(`ClaudeLogUsageScanner.swift:44`), Codex의 스캐너는 이벤트마다 `currentModel`을 추적합니다(`CodexLogUsageScanner.swift:42`). 현재 `SpendTileMapper`는 이를 일별 합계로 집계하고 모델별 차원을 버립니다. 새로운 형제 매퍼가 기존 타일을 건드리지 않고 호버된 기간의 모델별 `[ModelShare]`를 만들 수 있습니다. 이는 UI 전용 변경이 아니라 데이터 레이어 추가입니다 — PR 계획에 명시하세요.

### 4.1 구현 전 소유자와 확인할 미결 사항

AGENTS.md에 따르면 지표 기본값(활성화, 주/보조, 고정, 순서)은 소유자 승인이 필요합니다 — 이것은 기존 지출 행의 새로운 호버 상호작용이므로 다음을 확인하세요.

- **트리거:** 호버 전용(사용량 추세와 일치), 아니면 호버 + 클릭? 같은 400ms 지연의 호버 전용을 권장합니다. 그래야 기존 값 툴팁과 충돌하지 않습니다(툴팁은 정확한 수치를, 패널은 내역을 보여 줌).
- **값 툴팁과의 공존:** 지출 행에는 이미 정확한 수치용 `.hoverTooltip(data.unboundedValueTooltip)`이 있습니다. 패널은 **값 텍스트**에 앵커되어야 하며, 표시되면 패널이 툴팁을 대체합니다(패널의 첫 행이 같은 정확한 수치를 보여 줌). 이것이 원하는 레이어링인지 확인하세요.
- **임계값:** 기간 내 모델이 2개 이상일 때만 패널을 표시할까요? 모델이 하나뿐인 기간은 분해할 것이 없으므로 툴팁만으로 충분합니다.
- **"Other" 묶음:** 목록을 이름 있는 모델 5개 + 긴 꼬리용 "Other" 행으로 제한합니다(콘셉트와 일치). 상한과 라벨("Other" / "Other models")을 확인하세요.
- **프로바이더별 출처 노트 문구**("From your Claude usage history (estimated)" vs "From your Cursor usage export" vs "From your Codex logs (estimated)") — 특히 `estimated` 플래그의 출처를 포함해 문구를 확인하세요.
- **밀도:** 패널은 다른 모든 표면처럼 `DensitySetting`(Regular/Compact)을 따라야 합니다 — Compact를 첫날부터 지원할지 뒤로 미룰지 확인하세요.

### 4.2 명시적으로 만들지 *않을* 것

- 모델별 브랜드 아이콘 없음(소유자가 원하면 나중에 모노그램만 출시).
- 도넛 / `SectorMark` / Swift Charts 의존성 없음.
- 히어로 카드, 그라디언트 카드 속 카드, "TOP DRIVER" pill 없음.
- 행에 셰브론 없음(모델별 상세 화면은 범위 밖).
- 팝오버 내부에 Liquid Glass 없음 — 시스템 팝오버 머티리얼만.
- 프로바이더 브랜드 색상 없음 — 모든 점유 막대는 시스템 블루로, 기존 미터/스파크라인 언어와 일치.
