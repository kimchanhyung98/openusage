# PR #740 변경 이력: 모델별 사용량 리더보드

> **과거 기록 / 대체됨.** 이 보고서는 2026-07-04 시점의 저장소 상태를 기록합니다. 지출 행 호버에 대한
> 프로바이더 중립적인 모델별 내역이 2026-07-04에 출시되었고 이후 계속 발전해 왔습니다. 현재 동작과 구현은
> [대시보드 행](../../dashboard.md#행),
> [`SpendTileMapper.swift`](../../../../Sources/OpenUsage/Providers/SpendTileMapper.swift),
> [`ModelUsageDetail.swift`](../../../../Sources/OpenUsage/Views/ModelUsageDetail.swift)을 참조하세요.
> 아래의 과거 브랜치 분석은 의도적으로 원문 그대로 유지합니다.

조사일: 2026-07-04. 이 PR은 `claude/eager-banach-ecf5a1` 브랜치에서 여전히 **오픈** 상태이며 **병합되지 않았습니다**(작성 시점 기준 `main`보다 약 106개 커밋 뒤처짐). 이 노트는 모델별 / 모델 호버 UX를 다시 검토하는 사람을 위해 해당 브랜치와 현재 `main`을 비교합니다.

## (a) PR #740이 한 일

**목표:** 옵트인 방식의 Cursor **Models** 위젯 — 최근 30일간 지출 순으로 정렬된 모델별 리더보드로, Today / Yesterday / Last 30 Days와 동일한 사용량 CSV를 재사용합니다.

**데이터 경로**

- `CursorProvider`에서 Cursor의 사용량 이벤트 CSV를 가져옵니다(지출 타일과 동일한 기간).
- 행을 `CursorUsageCSVRow`로 파싱합니다(날짜, 모델 슬러그, 토큰 버킷, `imputedCostDollars`).
- **`CursorModelBreakdown`**(cursorcat `ModelBreakdownAggregator` 이식): `CursorPricing.family(for:)`와 번들 **`model_manifest.json`**(`family_id`, `family_display_name`)으로 행을 **모델 패밀리**별로 그룹화하고, 토큰과 환산 달러를 합산하고, 패밀리당 한 번 센트로 스냅하고, 지출 → 토큰 → 이름 순으로 정렬하고, 지출 비중 **3%** 미만의 꼬리는 **Other**로 합치되(가격 미등록 모델은 절대 합치지 않음), 호버 상세를 위해 원시 모델별 **variants**를 첨부합니다.
- **`CursorUsageMapper.appendModelLeaderboard`**가 `MetricLine.modelBreakdown(label: "Models", models: entries, note: …)`을 방출합니다.

**지표 / UI 연결**

- 새 타입: `ModelUsageEntry`, `ModelVariantUsage`, `MetricLine.modelBreakdown`.
- `WidgetData`: `isModelList`, `modelEntries`, `modelNote`(차트 필드와 병렬).
- `WidgetDescriptor.modelBreakdown` → `cursor.models`, **기본 비활성**, **보조**(확장 캐럿), **`pinnable: false`**.
- 뷰: **`ModelLeaderboardRow`**(상위 3개 패밀리 이름 + 순위 배지, 달러는 인라인 표시 없음) + 호버 팝오버 **`ModelLeaderboardDetail`**(전체 목록, 지출, 토큰, variants에 **선제적 `hoverTooltip`** — 리뷰에서 지적됨).
- `WidgetDataStore`, `WidgetRowView`, `LocalUsageAPI`(`type: "models"`)를 거쳐 연결하고, 스냅샷 캐시 **v5 → v7** 범프.
- 문서: `docs/dashboard.md`, `docs/providers/cursor.md`; 목록/차트 위젯의 `pinnable: false`에 대한 짧은 **AGENTS.md** 노트.
- 테스트: `CursorModelBreakdownTests`, `CursorSpendTests` / `LayoutStoreTests` 확장.

**PR 본문에 명시된 후속 작업**

- **Grok**으로 일반화("모델 귀속은 이미 계산됨").
- 기존 ccusage 지출 경로에서 `ccusage --breakdown`으로 **Claude / Codex** 확장.

**PR이 실제로 의존한 모델별 입력**

| 소스 | 사용한 필드 |
|--------|-------------|
| Cursor 사용량 CSV | 행별 `Model`, 토큰 컬럼, 날짜 |
| 행 가격 책정 | `CursorPricing.estimatedCostDollars` / 행별 `imputedCostDollars`(브랜치에서는 non-optional `Double`) |
| 패밀리 그룹화 | `model_manifest.json` → 가격 항목별 `family_id`, `family_display_name` |
| 기간 | 지출 타일과 동일한 약 30일 CSV 가져오기(일별 버킷에서 재집계하지 않음) |

---

## (b) 병합되지 않은 이유(논의 / 리뷰)

GitHub에서 공식적으로 PR을 닫은 것은 아니며, 리뷰 이후 교착 상태에 빠졌습니다. 기록된 이유와 신호는 다음과 같습니다.

1. **제품 / UX 불확실성(소유자)** — [#740 코멘트](https://github.com/robinebers/openusage/pull/740#issuecomment-4802994002): Cursor에서는 동작하고 다른 프로바이더로도 확장할 수 있지만, *"I wonder if there is a better way to display this. Maybe as a chart or something? Not sure."*(더 좋은 표시 방법이 있을까? 차트 같은 것으로? 잘 모르겠다.) 이는 근본적인 집계가 아니라 **리더보드 행 + 호버 팝오버** 패턴에 대한 불만으로 읽힙니다.

2. **Cursor 전용 제공 vs 멀티 프로바이더 의도** — 구현이 전적으로 Cursor 범위에 한정되어 있습니다(`CursorModelBreakdown`, `cursor.models`, CSV 전용). PR 자체도 크로스 프로바이더 확장을 **후속 작업**으로 남겨 두었기에, 사용자가 이미 보고 있는 Claude/Codex/Grok 지출 타일에 비해 기능이 좁게 느껴졌습니다.

3. **리뷰 마찰(자잘한 부분의 "문제가 너무 많음")**
   - **Codex 리뷰(P1):** 모델 행의 선제적 **`hoverTooltip`**이 `AGENTS.md`와 충돌("명시적으로 요청된 경우에만 툴팁 추가"). 전체 상세는 이미 호버 팝오버에 있으므로 variant 툴팁은 중복이며 컨벤션 위반이었습니다.
   - **Greptile(P1, 브랜치에서 수정됨):** 문서는 **5%** "Other" 임계값이라고 했지만 코드는 **3%**를 사용(`tailThresholdFraction = 0.03`).
   - **Greptile / Codex(P2):** 로컬 HTTP API가 `models` 라인을 방출하지만 **`docs/local-http-api.md`**가 업데이트되지 않았고, **`WireModel`**에 `variants`가 누락됨(외부 소비자가 variant 내역을 재구성할 수 없음).

4. **자동화 리뷰어는 낙관적, 사람은 병합하지 않음** — Greptile/Cursor Bugbot은 이 diff를 저위험, 병합 가능으로 평가했지만, 승인하는 사람 리뷰는 없었고 `main`이 크게 앞서 나가기 전에 병합도 이루어지지 않았습니다(아래 참조).

---

## (c) 이후 `main`에서 바뀐 것(브랜치가 심각하게 구식인 이유)

### PR #827 — 네이티브 로그 스캐너 + 동적 가격 책정(2026-07-02 병합됨)

가장 큰 단절입니다. #740은 더 이상 존재하지 않는 **Cursor 로컬 가격 책정 스택**을 전제로 합니다.

| #740 브랜치 | 현재 `main` |
|-------------|----------------|
| `CursorPricing`, `CursorModelManifest`, 번들 **`model_manifest.json`** | **제거됨.** 모든 환산은 **`Sources/OpenUsage/Pricing/`**을 통해 이루어짐(`ModelPricing`, `ModelPricingStore`, LiteLLM + models.dev + **`pricing_supplement.json`**) — **`docs/pricing.md`** 참조. |
| 가격 주입 없는 `CursorUsageCSV.parse(csv:)` | **`CursorUsageCSV.parse(csv:pricing:)`**; `imputedCostDollars`는 **`Double?`**(nil = 가격 미등록). |
| 리더보드 라벨용 `CursorPricing.family(for:)` / `family_display_name` | **supplement에 `family_id` 없음.** 그룹화는 표시 패밀리가 아니라 **별칭 규칙 → 정규 키**로 이루어짐. 사람이 읽을 수 있는 이름은 #740이 추가한 매니페스트 필드가 아니라 다른 곳(슬러그 포매팅 / 카탈로그 메타데이터)에서 도출해야 함. |
| **`CcusageRunner`**를 통한 Claude/Codex 지출; 후속 작업 **`ccusage --breakdown`** | **`CcusageRunner` 삭제됨.** **`ClaudeLogUsageScanner`** / **`CodexLogUsageScanner`**가 로컬 로그를 읽음. 출력은 **`DailyUsageSeries`**뿐(일별 버킷). |
| Cursor 지출은 매니페스트 가격 적용 CSV로 기술됨 | CSV 소스는 동일하지만 행은 **`ModelPricing`**으로 가격이 매겨짐. 미등록 모델은 지출 타일 경고를 위해 일별로 추적(**`CursorUsageMapper.appendSpendLines`**의 `unknownModelsByDay`). |

### 리베이스와 관련된 기타 `main` 변경 사항

- `main`에는 **`MetricLine.modelBreakdown`**도, `ModelUsageEntry`도, `isModelList` / `ModelLeaderboard*` 뷰도 없습니다.
- **스냅샷 캐시 키:** #740은 **`openusage.providerSnapshots.v7`**로 범프합니다(모델 내역 + variants). `main`은 **`v6`**입니다(지출 타일의 `.values` **`unknownModels`**). 스키마 경로가 다르므로, 부활하려면 새로운 범프와 마이그레이션 근거가 필요합니다.
- PR 브랜치에 없는 `main`의 **약 106개 커밋**(Copilot, Claude Cowork 로그, 알림, 엔터프라이즈 Cursor 경로, 가격 supplement 변경 등) — Cursor 프로바이더, 매퍼, `MetricLine`, `WidgetDataStore`, 문서에서 심각한 충돌이 예상됩니다.
- **Grok:** `GrokLogUsageScanner`는 각 추론을 모델에 귀속**하기는 하지만**(`pid`별 추적), Claude/Codex 스캐너처럼 **일별 합계로만 집계합니다** — 기존 `MetricLine` 중 모델별 시계열을 담는 것이 없습니다. #740의 "Grok은 이미 모델 귀속이 있다"는 주장은 스캔 시점에는 여전히 사실이지만, 오늘날 UI 파이프라인에는 이를 노출하는 경로가 없습니다.
- **Claude / Codex:** 스캐너는 **이벤트별 `model`**(`ClaudeLogUsageScanner.Entry.model`, `CodexLogUsageScanner.Event.model`)을 보존하지만 `DailyUsageSeries`를 만들 때 **이 차원을 버립니다** — #740이 Cursor 일별 버킷팅에서 지적한 것과 동일한 구조적 공백이 이제 모든 로그 기반 프로바이더의 공통 패턴이 되었습니다.

### 가격 supplement(운영상 변경)

- **`Sources/OpenUsage/Resources/pricing_supplement.json`**은 GitHub Pages에 게시되며, 앱은 릴리스 없이 거의 매일 새로 고침합니다. 패밀리 메타데이터를 위해 **`model_manifest.json`**을 확장하는 #740의 접근 방식은 폐기되었습니다. 새 모델/별칭은 **supplement**와 **`docs/pricing.md`** 유지 관리 흐름에 속합니다.

---

## (d) 재사용 가능 vs 폐기

### 대부분 폐기(무분별한 체리픽 금지)

- 작성된 그대로의 **`CursorModelBreakdown.swift`** — **`CursorPricing.family`**, **`toCents`**, non-optional **`imputedCostDollars`**를 임포트하므로 **`ModelPricing`**과 옵셔널 비용에 맞춰 다시 작성해야 합니다.
- **`CursorModelManifest` / `family_id` 디코딩** — 매니페스트 파일과 타입이 `main`에서 제거되었습니다.
- **`MetricLine.modelBreakdown` + 위젯 파이프라인 전체** — `main`에 대응물이 없습니다. 제품 방향은 두 번째 옵트인 위젯보다 **차트 / 지출 행 호버**를 선호할 수 있습니다(소유자 코멘트 기준).
- **캐시 v7 범프, LocalUsageAPI `models` wire 타입, `cursor.models`의 레이아웃 기본값** — 어느 것도 출시되지 않았으며, `main`의 문서는 Models 위젯을 다룬 적이 없습니다.
- **`CursorTokenUsage` / 구형 CSV 형태에 맞춰진 테스트** — 토큰 구조체는 공유 **`TokenBreakdown`**이며 **`makeRow`** 헬퍼에 가격 주입이 필요합니다.
- **ccusage breakdown 후속 작업** — 경로가 삭제되었습니다.

### 살릴 수 있는 개념(현재 아키텍처에서 재구현)

- **집계 의미론:** 패밀리 병합(**새 그룹화 정책 필요** — 예: 별칭 규칙의 정규 키 또는 supplement의 명시적 패밀리 맵), 지출 정렬, 버킷당 한 번 센트 스냅, 사용량 0인 행 건너뛰기, **3% Other** 꼬리 규칙, 가격 미등록 모델은 절대 합치지 않기, `-fast` / thinking 슬러그용 variant 하위 행.
- **새 API 없이도 여전히 확보 가능한 데이터:**
  - **Cursor:** 파싱 후의 원시 **`[CursorUsageCSVRow]`**(각 행에 모델 차원이 여전히 존재).
  - **Claude / Codex / Grok:** 일별 집계 전에 **모델별 합계**를 방출하도록 스캐너를 재실행하거나 확장(이벤트에 이미 모델이 있음).
- **UI 패턴(선택 사항):** **`ModelLeaderboardDetail`**의 측정 높이 기반 스크롤 상한, 호버 표면용 **`TrendHoverState`** dwell/grace, 순위 인라인 / 호버 상세 분리 — 단, 제품에서 명시적으로 원하지 않는 한 **선제적 툴팁은 피할 것**. 전용 위젯 대신 소유자의 "차트?" 직관이나 **기존 지출/추세 호버 위의 모델 상세**에 맞추는 것을 고려하세요.
- **크로스 프로바이더 관점:** **`SpendTileMapper`**와 **`DailyUsageSeries`**가 공유 지출 골격입니다. 모델별 기능은 하나의 가격 엔진과 일관된 미등록 모델 처리를 사용해 **4개** 환산 프로바이더(Claude, Codex, Cursor, Grok) 모두에 동등하게 제공하는 것이 바람직합니다.

### 부활 체크리스트(추진하는 경우)

1. UX 결정: 별도 위젯 vs 기존 행 호버 vs 차트(#740의 미해결 질문 해결).
2. `family_display_name` 없이 **표시 그룹화** 정의(supplement 메타데이터 vs 슬러그 포매팅 vs 카탈로그).
3. 일별 전용 시계열이 아닌 행/이벤트 스트림 위에서 **`ModelBreakdownAggregator`**(프로바이더 비종속) 구현.
4. 선택한 UX에 필요한 경우에만 **`MetricLine` / API** 확장. 노출한다면 **`docs/local-http-api.md`** 업데이트.
5. 문서화된 스키마 변경과 함께 **`ProviderSnapshotCache`** 범프.
6. **AGENTS.md**에 따라 소유자와 지표 배치 기본값 확인(4가지 결정 사항).

---

## 참고 자료

- PR: https://github.com/robinebers/openusage/pull/740
- 가격 개편: https://github.com/robinebers/openusage/pull/827 (병합됨)
- 현재 가격 문서: `docs/pricing.md`
- 공유 지출 타일: `Sources/OpenUsage/Providers/SpendTileMapper.swift`
- Cursor CSV + 일별 집계(모델은 여전히 버려짐): `Sources/OpenUsage/Providers/Cursor/CursorUsageMapper.swift` (`appendSpendLines`)
