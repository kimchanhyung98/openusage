# PR #740 발굴 분석: 모델별 사용량 리더보드

> **과거 기록 / 대체됨.**
> 2026-07-04 시점의 저장소 상태를 기록한 보고서.
> 지출 행 호버에 표시되는 프로바이더 중립적 모델별 내역은 2026-07-04에 출시되었고 이후 계속 발전했으며, 현재 동작과 구현은 [대시보드 행](/docs/ko/dashboard.md#행), [`SpendTileMapper.swift`](../../../../Sources/OpenUsage/Providers/SpendTileMapper.swift), [`ModelUsageDetail.swift`](../../../../Sources/OpenUsage/Views/ModelUsageDetail.swift) 참고.
> 아래의 과거 브랜치 분석은 의도적으로 변경 없이 유지.

조사일: 2026-07-04.
PR은 `claude/eager-banach-ecf5a1` 브랜치에서 여전히 **오픈** 및 **미병합** 상태이며 작성 시점 기준 `main`보다 약 106개 커밋 뒤처짐.
모델별 / 모델 호버 UX를 다시 검토할 때 참고할 수 있도록 해당 브랜치와 현재 `main`을 비교한 문서.

## (a) PR #740의 작업 내용

**목표:** 최근 30일의 모델별 사용량을 지출 순으로 보여 주는 옵트인 Cursor **Models** 위젯 — Today / Yesterday / Last 30 Days와 동일한 사용량 CSV 재사용.

**데이터 경로**

- `CursorProvider`에서 지출 타일과 같은 기간의 Cursor 사용량 이벤트 CSV 가져오기.
- 행을 날짜, 모델 슬러그, 토큰 버킷, `imputedCostDollars`로 구성된 `CursorUsageCSVRow`로 파싱.
- **`CursorModelBreakdown`**(cursorcat의 `ModelBreakdownAggregator` 이식): `CursorPricing.family(for:)`와 번들 **`model_manifest.json`**의 `family_id`, `family_display_name`을 이용해 행을 **모델 패밀리**별로 그룹화하고, 토큰과 환산 금액을 합산하고, 패밀리별 센트 단위 보정을 한 번 적용하고, 지출 → 토큰 → 이름 순으로 정렬하고, 지출 비중 **3%** 미만인 꼬리 항목을 **Other**로 묶되 가격 미등록 모델은 제외하고, 호버 상세용 원시 모델별 **변형 항목** 첨부.
- **`CursorUsageMapper.appendModelLeaderboard`**에서 `MetricLine.modelBreakdown(label: "Models", models: entries, note: …)` 방출.

**지표 / UI 연결**

- 새 타입: `ModelUsageEntry`, `ModelVariantUsage`, `MetricLine.modelBreakdown`.
- `WidgetData`: 차트 필드와 병렬 구조인 `isModelList`, `modelEntries`, `modelNote`.
- `WidgetDescriptor.modelBreakdown` → `cursor.models`, **기본 비활성**, **보조**(확장 캐럿 뒤), **`pinnable: false`**.
- 뷰: 상위 3개 패밀리 이름과 순위 배지를 표시하고 금액은 인라인으로 표시하지 않는 **`ModelLeaderboardRow`** + 전체 목록, 지출, 토큰, 변형 항목의 **선제적 `hoverTooltip`**을 보여 주는 호버 팝오버 **`ModelLeaderboardDetail`**(리뷰에서 지적).
- `WidgetDataStore`, `WidgetRowView`, `LocalUsageAPI`의 `type: "models"`까지 연결하고 스냅샷 캐시를 **v5 → v7**로 범프.
- 문서: `docs/dashboard.md`, `docs/providers/cursor.md`; 목록/차트 위젯의 `pinnable: false`를 다룬 짧은 **AGENTS.md** 참고 사항.
- 테스트: `CursorModelBreakdownTests`, `CursorSpendTests` / `LayoutStoreTests` 확장.

**PR 본문에 명시된 후속 작업**

- **Grok**으로 일반화(“model attribution already computed”, 모델 귀속 계산 완료).
- 기존 ccusage 지출 경로에서 `ccusage --breakdown`을 이용해 **Claude / Codex** 지원.

**PR이 실제로 의존한 모델별 입력**

| 소스 | 사용 필드 |
|--------|-------------|
| Cursor 사용량 CSV | 행별 `Model`, 토큰 열, 날짜 |
| 행 가격 | `CursorPricing.estimatedCostDollars` / 행별 `imputedCostDollars`(브랜치에서는 옵셔널이 아닌 `Double`) |
| 패밀리 그룹화 | `model_manifest.json` → 가격 항목별 `family_id`, `family_display_name` |
| 기간 | 지출 타일과 동일한 약 30일 CSV 가져오기(일별 버킷에서 재집계하지 않음) |

---

## (b) 병합되지 않은 이유(논의 / 리뷰)

GitHub에서 PR을 공식적으로 닫은 기록은 없으며 리뷰 이후 정체.
기록된 이유와 정황은 다음과 같음.

1. **제품 / UX 불확실성(소유자)** — [#740 댓글](https://github.com/robinebers/openusage/pull/740#issuecomment-4802994002): Cursor에서 작동하고 다른 프로바이더로 확장할 수도 있지만 *“I wonder if there is a better way to display this.
   Maybe as a chart or something?
   Not sure.”*라는 반응.
   근본적인 집계보다 **리더보드 행 + 호버 팝오버** 패턴에 대한 불만으로 해석되는 대목.

2. **Cursor 전용 제공과 멀티 프로바이더 의도의 불일치** — `CursorModelBreakdown`, `cursor.models`, CSV 전용 경로 등 구현 전체가 Cursor 범위에 한정.
   PR 자체에서도 크로스 프로바이더 확장을 **후속 작업**으로 남겨, 사용자가 이미 확인하던 Claude/Codex/Grok 지출 타일에 비해 협소하게 느껴지는 기능.

3. **리뷰 마찰(작은 부분의 “too many problems”)**
   - **Codex 리뷰(P1):** 모델 행의 선제적 **`hoverTooltip`**이 “only add tooltips when explicitly asked”라는 `AGENTS.md` 규칙과 충돌.
     전체 상세가 이미 호버 팝오버에 있으므로 변형 항목 툴팁은 중복이자 규칙 위반.
   - **Greptile(P1, 브랜치에서 수정):** 문서는 **5%**의 “Other” 임계값을 명시했지만 코드는 **3%** 사용(`tailThresholdFraction = 0.03`).
   - **Greptile / Codex(P2):** 로컬 HTTP API에서 `models` 행을 방출하면서 **`docs/local-http-api.md`**를 갱신하지 않았고, **`WireModel`**에서 `variants`도 누락되어 외부 소비자가 변형 내역을 재구성할 수 없는 상태.

4. **자동 리뷰는 낙관적이었지만 사람은 병합하지 않음** — Greptile/Cursor Bugbot은 diff를 저위험·병합 가능으로 평가했지만 사람이 남긴 승인 리뷰도, `main`이 크게 변하기 전 병합도 없었음(아래 참고).

---

## (c) 이후 `main`의 변경 사항(브랜치가 심각하게 뒤처진 이유)

### PR #827 — 네이티브 로그 스캐너 + 동적 가격 책정(2026-07-02 병합)

가장 큰 단절.
#740은 더 이상 존재하지 않는 **Cursor 전용 가격 책정 스택**을 전제로 함.

| #740 브랜치 | 현재 `main` |
|-------------|----------------|
| `CursorPricing`, `CursorModelManifest`, 번들 **`model_manifest.json`** | **제거됨.**<br>모든 환산을 **`Sources/OpenUsage/Pricing/`**의 `ModelPricing`, `ModelPricingStore`, LiteLLM + models.dev + **`pricing_supplement.json`**을 통해 처리 — **`docs/pricing.md`** 참고. |
| 가격 주입 없는 `CursorUsageCSV.parse(csv:)` | **`CursorUsageCSV.parse(csv:pricing:)`**; `imputedCostDollars`는 **`Double?`**(nil = 가격 미등록). |
| 리더보드 라벨용 `CursorPricing.family(for:)` / `family_display_name` | **보충 파일에 `family_id` 없음.**<br>표시 패밀리가 아닌 **별칭 규칙 → 정규 키**로 그룹화.<br>사람이 읽을 수 있는 이름은 #740에서 추가한 매니페스트 필드가 아닌 다른 곳(슬러그 포매팅 / 카탈로그 메타데이터)에서 도출해야 함. |
| **`CcusageRunner`**를 통한 Claude/Codex 지출; 후속 작업 **`ccusage --breakdown`** | **`CcusageRunner` 삭제됨.**<br>**`ClaudeLogUsageScanner`** / **`CodexLogUsageScanner`**에서 로컬 로그를 읽고 **`DailyUsageSeries`**만 출력(일별 버킷). |
| 매니페스트 가격을 적용한 CSV로 설명한 Cursor 지출 | CSV 소스는 같지만 **`ModelPricing`**으로 행 가격 책정. 지출 타일 경고를 위해 일별로 미등록 모델 추적(**`CursorUsageMapper.appendSpendLines`**의 `unknownModelsByDay`). |

### 리베이스와 관련된 기타 `main` 변경 사항

- `main`에는 **`MetricLine.modelBreakdown`**, `ModelUsageEntry`, `isModelList` / `ModelLeaderboard*` 뷰 모두 없음.
- **스냅샷 캐시 키:** #740에서는 모델 내역과 변형 항목을 위해 **`openusage.providerSnapshots.v7`**로 범프.
  `main`은 지출 타일의 `.values` **`unknownModels`**를 담은 **`v6`**이므로 스키마 흐름이 다르며, 기능을 되살리려면 새로운 범프와 마이그레이션 근거 필요.
- PR 브랜치에 없는 `main`의 **약 106개 커밋**(Copilot, Claude Cowork 로그, 알림, 엔터프라이즈 Cursor 경로, 가격 보충 파일의 잦은 변경 등)으로 인해 Cursor 프로바이더, 매퍼, `MetricLine`, `WidgetDataStore`, 문서에서 대규모 충돌 예상.
- **Grok:** `GrokLogUsageScanner`는 `pid`별 추적으로 각 추론을 모델에 **귀속하지만**, Claude/Codex 스캐너와 마찬가지로 **일별 합계만 집계**하며 기존 `MetricLine`에는 모델별 시계열을 담을 곳이 없음.
  #740의 “Grok already has model attribution”은 스캔 시점에는 여전히 맞지만 현재 UI 파이프라인에는 이를 노출하는 경로가 없는 상태.
- **Claude / Codex:** 스캐너에서 **이벤트별 `model`**(`ClaudeLogUsageScanner.Entry.model`, `CodexLogUsageScanner.Event.model`)을 유지하지만 `DailyUsageSeries` 생성 시 **해당 차원을 폐기** — #740이 Cursor의 일별 버킷화에서 지적했던 구조적 공백이 이제 모든 로그 기반 프로바이더의 공통 패턴으로 확장.

### 가격 보충 파일(운영상 변경)

- **`Sources/OpenUsage/Resources/pricing_supplement.json`**은 GitHub Pages에 게시되며 앱은 릴리스 없이 약 하루 간격으로 갱신.
  패밀리 메타데이터를 위해 **`model_manifest.json`**을 확장하는 #740의 접근 방식은 폐기되었으며, 새 모델/별칭은 **보충 파일**과 **`docs/pricing.md`** 유지 관리 흐름에서 처리.

---

## (d) 재사용 가능 요소와 폐기 대상

### 대부분 폐기(무분별한 체리픽 금지)

- 작성된 그대로의 **`CursorModelBreakdown.swift`** — **`CursorPricing.family`**, **`toCents`**, 옵셔널이 아닌 **`imputedCostDollars`**를 가져오므로 **`ModelPricing`**과 옵셔널 비용에 맞춘 재작성 필요.
- **`CursorModelManifest` / `family_id` 디코딩** — 매니페스트 파일과 타입 모두 `main`에서 제거.
- **`MetricLine.modelBreakdown` + 전체 위젯 파이프라인** — `main`에 대응 요소가 없으며, 소유자 댓글에 따르면 제품 방향도 두 번째 옵트인 위젯보다 **차트 / 지출 행 호버**를 선호할 가능성.
- **캐시 v7 범프, LocalUsageAPI `models` 와이어 타입, `cursor.models` 레이아웃 기본값** — 모두 미출시 상태이며 `main` 문서에도 Models 위젯 설명 없음.
- **`CursorTokenUsage` / 이전 CSV 형태에 맞춘 테스트** — 토큰 구조체는 공유 **`TokenBreakdown`**이며 **`makeRow`** 헬퍼에는 가격 주입 필요.
- **ccusage breakdown 후속 작업** — 경로 삭제.

### 재사용 가능한 개념(현재 아키텍처에서 재구현)

- **집계 의미론:** 패밀리 병합에 필요한 **새 그룹화 정책**(예: 별칭 규칙의 정규 키 또는 보충 파일의 명시적 패밀리 맵), 지출 정렬, 버킷별 센트 단위 보정 1회, 사용량이 0인 행 제외, **3% Other** 꼬리 규칙, 가격 미등록 모델 병합 제외, `-fast` / thinking 슬러그용 변형 하위 행.
- **새 API 없이도 확보 가능한 데이터:**
  - **Cursor:** 파싱 후의 원시 **`[CursorUsageCSVRow]`**(각 행에 모델 차원 유지).
  - **Claude / Codex / Grok:** 일별 집계 전에 **모델별 합계**를 방출하도록 스캐너를 다시 실행하거나 확장(이벤트에 이미 모델 포함).
- **UI 패턴(선택 사항):** **`ModelLeaderboardDetail`**의 측정 높이 기반 스크롤 상한, 호버 표면용 **`TrendHoverState`** dwell/grace, 인라인 순위 / 호버 상세 분리 — 단, 제품에서 명시적으로 원하지 않는 한 **선제적 툴팁은 지양**하고, 전용 위젯 대신 소유자의 “chart?” 의견이나 **기존 지출/추세 호버의 모델 상세**와 맞추는 방안 고려.
- **크로스 프로바이더 관점:** **`SpendTileMapper`**와 **`DailyUsageSeries`**가 공유 지출 골격이며, 모델별 기능은 하나의 가격 엔진과 일관된 미등록 모델 처리 방식을 사용해 지출 환산을 사용하는 **4개** 프로바이더(Claude, Codex, Cursor, Grok) 모두에 동일하게 제공하는 편이 적절.

### 재추진 시 권장 체크리스트

1. UX 결정: 별도 위젯, 기존 행 호버, 차트 중 선택해 #740의 미해결 질문 해소.
2. `family_display_name` 없이 **표시 그룹화** 정의(보충 파일 메타데이터, 슬러그 포매팅, 카탈로그 중 선택).
3. 일별 전용 시계열이 아닌 행/이벤트 스트림을 대상으로 프로바이더 중립적인 **`ModelBreakdownAggregator`** 구현.
4. 선택한 UX에 필요한 경우에만 **`MetricLine` / API** 확장하고, 외부에 노출한다면 **`docs/local-http-api.md`** 갱신.
5. 스키마 변경을 문서화하고 **`ProviderSnapshotCache`** 범프.
6. **AGENTS.md**에 따라 소유자와 지표 배치 기본값 4가지 확인.

---

## 참고 자료

- PR: https://github.com/robinebers/openusage/pull/740
- 가격 개편: https://github.com/robinebers/openusage/pull/827 (병합)
- 현재 가격 문서: `docs/pricing.md`
- 공유 지출 타일: `Sources/OpenUsage/Providers/SpendTileMapper.swift`
- Cursor CSV + 일별 집계(모델 차원은 여전히 폐기): `Sources/OpenUsage/Providers/Cursor/CursorUsageMapper.swift` (`appendSpendLines`)
