# 모델 호버 패널: 데이터와 아키텍처 실현 가능성

> **과거 기록 / 대체됨.** 이 실현 가능성 보고서는 2026-07-04 시점의 구현 전 스냅샷입니다.
> 아래에서 제안으로 설명하는 모델별 내역 데이터 경로와 지출 행 호버 패널은 바로 그날
> 출시되었습니다. 현재 구현은 [대시보드 행](../../dashboard.md#행),
> [`SpendTileMapper.swift`](../../../../Sources/OpenUsage/Providers/SpendTileMapper.swift),
> [`HoverPopoverState.swift`](../../../../Sources/OpenUsage/Views/HoverPopoverState.swift),
> [`ModelUsageDetail.swift`](../../../../Sources/OpenUsage/Views/ModelUsageDetail.swift)을
> 참조하세요. 이 분석은 현재 상태 문서가 아니라 과거 기록으로 남아 있습니다.
> 좁은 범위의 구현 참조는 코드가 발전하면서 수정될 수 있습니다.

리서치 날짜: 2026-07-04. 범위: 이 워크트리의 현재 `main` 라인 SwiftPM 앱 아키텍처. 이 문서는 기존 `Today`, `Yesterday`, `Last 30 Days` 지출 행에서 호버로 표시되는 모델별 지출/사용량 내역을 위한 읽기 전용 기술 리서치입니다.

> **상태 업데이트 (2026-07-10):** 이 문서는 리서치 날짜 시점의 구현 전 아키텍처를 기록합니다. 현재 코드는 `ModelUsageSeries`를 통해 모델별 사용량을 전달합니다. Cursor의 경계 파서도 사용할 수 없는 CSV 구조에서 예외를 던지고 `CursorUsageCSVParseResult`(`rows`와 `rejectedRowCount`)를 반환합니다. 현재 사용자 대상 동작은 [Cursor](../../providers/cursor.md)를 참조하세요.

## 핵심 결론

이 기능은 새로운 외부 사용량 API를 추가하지 않고도 Cursor, Claude, Codex에서는, 그리고 Grok에서는 부분적으로, 기술적으로 실현 가능합니다. 원시 프로바이더 입력은 현재 지출 파이프라인이 이를 `DailyUsageSeries`로 축소하기 전에 이미 모델 차원을 담고 있습니다.

주된 문제는 구조적입니다: 현재 지출 행은 일별 합계(`DailyUsageEntry.date`, `totalTokens`, `costUSD`)와 알 수 없는 모델 이름만 받습니다. 어떤 `MetricLine`, `WidgetData`, 캐시된 `ProviderSnapshot`도 현재 호버 패널에 필요한 모델별 행을 담고 있지 않습니다.

권장 형태: 기존 스캐너/CSV 매퍼가 `DailyUsageSeries`를 계산하는 것과 같은 시점에 프로바이더 중립적인 일별·모델별 집계를 계산하고, 이를 `SpendTileMapper`를 통해 전달한 다음, `Today`, `Yesterday`, `Last 30 Days`에 해당하는 `MetricLine.values`에 기간 범위의 내역을 직접 첨부하고, 사용량 기간 행을 위해 `WidgetRowView`에서 SwiftUI 호버 팝오버를 렌더링합니다.

## 현재 지출 데이터 경로

공유 지출 타일은 `Sources/OpenUsage/Providers/SpendTileMapper.swift`에서 생성됩니다.

`SpendTileMapper.appendTokenUsage(_:to:now:estimated:unknownModelsByDay:)`는 세 개의 `.values` 라인을 추가합니다:

- `Today`
- `Yesterday`
- `Last 30 Days`

`Sources/OpenUsage/Models/DailyUsageSeries.swift`의 `DailyUsageSeries`를 소비합니다. 이 타입은 의도적으로 프로바이더 중립적이며 다음만 포함합니다:

- `DailyUsageEntry.date`
- `DailyUsageEntry.totalTokens`
- `DailyUsageEntry.costUSD`

`LogUsageScan`은 현재 보조 채널을 하나만 추가합니다:

- `series: DailyUsageSeries`
- `unknownModelsByDay: [String: Set<String>]`

즉, 현재 지출 행은 총 비용/토큰과 알 수 없는 가격 경고를 표시하기에는 데이터가 충분하지만, 모델별 합계를 표시하기에는 부족합니다.

공유 가격 엔진은 `Sources/OpenUsage/Pricing/`에 있습니다:

- `ModelPricing.resolve(model:)`은 `ModelRates?`를 반환합니다.
- `ModelPricing.estimatedCostDollars(model:tokens:)`는 `TokenBreakdown`의 가격을 계산합니다.
- `TokenBreakdown`은 `input`, `cacheWrite5m`, `cacheWrite1h`, `cacheRead`, `output`, `isFast`를 담습니다.
- `ModelRates.costDollars(for:)`는 백만 토큰당 요율, 캐시 쓰기/캐시 읽기 요율, 1시간 캐시 쓰기 가격, 존재하는 경우 200k 초과 구간, fast 배율을 적용합니다.
- `ModelPricingStore.current()`는 로드된 가장 최신의 가격 스냅샷을 제공하고, 소스 갱신 시점이 되면 백그라운드 새로 고침을 시작합니다. 가격 소스 새로 고침은 대략 하루에 한 번입니다.

## 프로바이더 데이터 가용성

### Cursor: 높은 실현 가능성

현재 지출 소스:

- `CursorProvider.appendSpendLines(to:accessToken:)`은 `CursorUsageClient.fetchUsageCSV(accessToken:start:end:)`를 통해 `https://cursor.com/api/dashboard/export-usage-events-csv`를 가져옵니다.
- 쿼리 윈도우는 로컬 오늘 시작 시점의 29일 전에 시작해 `now`에서 끝나므로, 오늘과 이전 29일(달력 기준)을 포함합니다.
- `CursorUsageCSV.parse(csv:pricing:)`는 CSV를 `[CursorUsageCSVRow]`로 파싱합니다.
- `CursorUsageMapper.appendSpendLines(rows:now:to:)`는 행을 `DailyUsageSeries`로 집계한 다음 `SpendTileMapper.appendTokenUsage(... estimated: false ...)`와 `appendUsageTrend(...)`를 호출합니다.

축소 전에 사용 가능한 모델별 데이터:

- `Sources/OpenUsage/Providers/Cursor/CursorUsageCSV.swift`의 `CursorUsageCSVRow`는 다음을 담습니다:
  - `date: Date`
  - `model: String`
  - `maxMode: Bool`
  - `tokens: TokenBreakdown`
  - `imputedCostDollars: Double?`
- 파서는 CSV 컬럼 `Model`, `Max Mode`, `Input (w/o Cache Write)`, `Input (w/ Cache Write)`, `Cache Read`, `Output Tokens`를 매핑합니다.
- `imputedCostDollars`는 이미 `ModelPricing.estimatedCostDollars(model:tokens:)`를 통해 행별로 계산되어 있습니다.

기존 데이터로 일별·모델별 집계를 만들 수 있는가:

- 가능합니다. `CursorUsageMapper.appendSpendLines`는 현재 모든 행을 순회하며 일별로만 그룹화합니다. 같은 패스에서 `(day, model)`로도 그룹화할 수 있습니다.
- 비용은 기존 동작을 따라야 합니다: 원시 행 비용을 합산하고 행 단위가 아니라 집계 경계에서 한 번만 반올림합니다. 현재 일별 합계는 합산 후 센트 단위로 반올림합니다.
- `imputedCostDollars == nil`인 행도 토큰에는 기여해야 하며, 호버 패널에서는 해당 모델을 가격 미산정/알 수 없음으로 표시해야 합니다. 기존의 알 수 없는 모델 경고도 이미 이 규칙을 사용합니다.
- UI가 나중에 변형을 라벨링하고 싶다면 `maxMode`를 사용할 수 있지만, CSV 행이 집계값이므로 현재 비용 추정에는 별도의 Max Mode 가산을 적용하지 않습니다.

결론: 가장 좋은 시작점입니다. Cursor는 `DailyUsageSeries`가 만들어지기 전에 이미 행 단위의 모델, 토큰, 비용을 갖고 있습니다.

### Claude: 높은 실현 가능성

현재 지출 소스:

- `ClaudeProvider.probe(state:)`는 `ClaudeLogUsageScanner.scan(now:pricing:)`을 호출합니다.
- 스캐너는 `CLAUDE_CONFIG_DIR`, `$XDG_CONFIG_HOME/claude`, `~/.claude`에서 파생된 루트와 Claude Desktop Cowork 로컬 에이전트 모드 세션 디렉터리 아래의 Claude Code 로컬 세션 로그를 읽습니다.
- 로그 파일은 `<config dir>/projects/**/*.jsonl`입니다.
- 스캐너는 `LogUsageScan`을 반환하고, `ClaudeProvider`는 `SpendTileMapper.appendTokenUsage(scan.series, ..., unknownModelsByDay: scan.unknownModelsByDay)`와 `appendUsageTrend(...)`를 호출합니다.

축소 전에 사용 가능한 모델별 데이터:

- `Sources/OpenUsage/Providers/Claude/ClaudeLogUsageScanner.swift`의 `ClaudeLogUsageScanner.Entry`는 다음을 담습니다:
  - `timestamp: Date`
  - `tokens: TokenBreakdown`
  - `costUSD: Double?`
  - `model: String?`
  - `messageID`, `requestID`, `isSidechain`, `hasSpeed` 같은 중복 제거 필드
- `parseLine(_:)`은 `message.model`을 읽고, `<synthetic>`을 `nil`로 매핑하며, 입력/출력/캐시 토큰 버킷을 파싱하고, 로그 라인이 제공하는 경우 `costUSD`를 담습니다.
- `TokenBreakdown.isFast`는 Claude의 `usage.speed == "fast"`에서 설정됩니다.
- `aggregate(entries:since:pricing:)`은 먼저 항목의 중복을 제거한 다음 이벤트별로 가격을 계산합니다:
  - 있는 경우 담겨 온 `costUSD`를 사용
  - 그렇지 않으면 `model + TokenBreakdown`을 `ModelPricing`으로 가격 계산
  - 알 수 없는 모델은 토큰에 기여하고 `unknownModelsByDay`를 채움

기존 데이터로 일별·모델별 집계를 만들 수 있는가:

- 가능합니다. 집계 함수는 이미 타임스탬프, 모델, 토큰 버킷, 비용 출처를 갖춘 중복 제거된 이벤트 수준 `Entry` 레코드를 갖고 있습니다.
- 이 기능은 `tokensByDay`와 `costByDay`로 축소되기 전에 `ClaudeLogUsageScanner.aggregate`를 확장하거나 병렬로 수행해야 합니다.
- `model == nil`인 항목은 현재 `costUSD`를 담고 있는 경우에만 총 일별 지출/토큰에 기여할 수 있습니다. 모델 패널에서는 `Unknown Model` 같은 명시적 표시 버킷이 필요하거나, 주석과 함께 생략해야 합니다. 합계가 어긋나게 되는 경우 이 토큰을 조용히 숨기지 않도록 해야 합니다.

결론: 스캐너 집계 변경만으로 실현 가능하며, 새 API가 필요하지 않습니다.

### Codex: 높은 실현 가능성

현재 지출 소스:

- `CodexProvider.probe(authState:)`는 `CodexLogUsageScanner.scan(now:pricing:)`을 호출합니다.
- 스캐너는 `CODEX_HOME` 또는 `~/.codex`에서 `sessions/`와 `archived_sessions/`를 포함한 Codex CLI 롤아웃/세션 로그를 읽습니다.
- `LogUsageScan`을 반환하고, `CodexProvider`는 `SpendTileMapper.appendTokenUsage(scan.series, ..., unknownModelsByDay: scan.unknownModelsByDay)`와 `appendUsageTrend(...)`를 호출합니다.

축소 전에 사용 가능한 모델별 데이터:

- `Sources/OpenUsage/Providers/Codex/CodexLogUsageScanner.swift`의 `CodexLogUsageScanner.Event`는 다음을 담습니다:
  - `timestamp: Date`
  - `model: String`
  - `input: Int`
  - `cached: Int`
  - `output: Int`
  - `reasoning: Int`
  - `total: Int`
- `parseFile(_:)`은 `turn_context` 레코드에서 현재 모델을 추적하고, `token_count` 이벤트를 처리하며, `resolveModel(...)`을 사용해:
  - 명시적 모델 메타데이터가 있으면 사용
  - 없으면 현재 세션 모델로 대체
  - 모델 메타데이터가 없는 초기 세션은 `gpt-5`로 대체
  - 폐기된 `codex-auto-review`는 날짜별 모델 대체 규칙으로 매핑
- `aggregate(events:since:pricing:fastTier:)`는 복사된 로그 전반의 동일한 이벤트를 중복 제거하고, 일별로 그룹화하고, 모델별로 요율을 해석하고, `CodexLogUsageScanner.cost(rates:event:fastTier:)`로 가격을 계산합니다.

기존 데이터로 일별·모델별 집계를 만들 수 있는가:

- 가능합니다. `Event`는 `(day, model)`로 그룹화하고 토큰/비용을 계산하기에 충분한 데이터를 갖고 있습니다.
- fast/priority 서비스 티어는 스캔 전체에 적용되는 계정 단위 설정으로 `config.toml`에서 읽습니다. 모델별 집계는 합계가 기존 지출 타일과 일치하도록 같은 `fastTier` 플래그와 같은 `cost(rates:event:fastTier:)` 헬퍼를 사용해야 합니다.
- `reasoning` 필드는 `total`에 포함되지만, 현재 비용 계산은 `output`만 청구합니다. 리포트 UI는 토큰 라벨에 주의해야 합니다: 타일과 맞추려면 총 토큰을 표시하거나, 비용 규칙이 명확한 경우에만 확장된 input/cached/output/reasoning 내역을 표시하세요.

결론: 스캐너 집계 변경만으로 실현 가능하며, 새 API가 필요하지 않습니다.

### Grok: 중간 실현 가능성

현재 지출 소스:

- `GrokProvider.probe(state:accessToken:)`는 `GrokLogUsageScanner.scan(daysBack:now:pricing:)`을 호출합니다.
- 스캐너는 하나의 추가 전용 로그 `$GROK_HOME/logs/unified.jsonl` 또는 `~/.grok/logs/unified.jsonl`을 읽습니다.
- `DailyUsageSeries?`를 직접 반환하고, `GrokProvider`는 `SpendTileMapper.appendTokenUsage(tokenUsage, ...)`와 `appendUsageTrend(...)`를 호출합니다.

축소 전에 사용 가능한 모델별 데이터:

- `GrokLogUsageScanner.parse(_:since:pricing:)`는 `modelByPID: [Int: String]`를 추적합니다.
- 모델 변경 이벤트는 다음과 같은 메시지에서 옵니다:
  - `model changed`
  - `model catalog: notifying clients`
  - `backend_search: model switch`
  - `subagent model resolved`
- 토큰 행은 `shell.turn.inference_done` 라인입니다. prompt/completion/reasoning/cache 토큰 수를 포함하지만 모델 id를 직접 포함하지는 않습니다.
- 스캐너는 토큰 행을 해당 프로세스 id의 현재 모델에 귀속시킨 다음 `ModelPricing.estimatedCostDollars(...)`로 가격을 계산합니다.

기존 데이터로 일별·모델별 집계를 만들 수 있는가:

- 대체로 가능하지만 다른 프로바이더보다는 약합니다.
- 현재 파서는 비용을 계산하는 바로 그 시점에 추론된 모델을 갖고 있으므로, 반환하기 전에 `(day, model)`로 그룹화할 수 있습니다.
- 현재 `LogUsageScan`이 아닌 `DailyUsageSeries`만 반환하며 `unknownModelsByDay`를 추적하지 않습니다. 알 수 없거나 귀속되지 않은 Grok 행은 토큰에 기여하지만 비용은 가격 미산정으로 남고, UI에 누락된 모델의 이름을 표시하지 않습니다.
- 토큰 행에 해당 `pid`의 이전 모델 이벤트가 없으면, 기존 일별 합계는 토큰은 세지만 그 행의 가격은 계산하지 않습니다. 모델 패널에는 명확한 `Unattributed` 버킷이나 일부 토큰을 모델에 연결할 수 없었다는 설명 주석이 필요합니다.

결론: 추론된 모델 id가 있는 행에는 실현 가능하지만, Grok을 포함한다면 첫 구현에서 귀속되지 않은 행을 명시적으로 처리하고 알 수 없는 모델 추적을 추가해야 합니다.

## 지출 행 렌더링 경로

지표 식별:

- `Sources/OpenUsage/Models/WidgetDescriptor+Factories.swift`의 `WidgetDescriptor.spendTiles(provider:)`는 세 개의 지출 디스크립터를 선언합니다:
  - `<provider>.today`
  - `<provider>.yesterday`
  - `<provider>.last30`
- 각 디스크립터는 `isUsagePeriod: true`인 `.combined(...)` 행입니다.
- 디스크립터의 `metricLabel`이 제목입니다: `Today`, `Yesterday`, `Last 30 Days`.

레이아웃 기본값:

- `DefaultLayout.metricIDs`는 Claude, Codex, Cursor, Grok의 지출 행을 활성화합니다.
- `DefaultLayout.expandedMetricIDs`는 이 지출 행들을 기본적으로 프로바이더 캐럿 아래에 배치합니다.
- `DefaultLayout.pinnedMetricIDs`는 이 행들을 기본적으로 메뉴 막대에 고정하지 않습니다.

스냅샷에서 뷰로:

- 프로바이더 새로 고침은 `ProviderSnapshot.lines: [MetricLine]`을 생성합니다.
- `WidgetDataStore.data(for:)`는 `snapshot.line(label: descriptor.metricLabel)`을 조회해 `WidgetDescriptor`를 해석합니다.
- `.values` 행의 경우, `WidgetDataStore.resolve`는 원시 `values`, `expiriesAt`, `unknownModels`를 `WidgetData`에 복사한 다음 다음을 적용합니다:
  - 전역 미터 스타일
  - 리셋 표시 모드
  - `alwaysShowPacing`
- `WidgetGroupedListView`는 각 행을 해석하고 `WidgetRowView(data: ...)`를 렌더링합니다.

현재 행 구조:

- `WidgetRowView`에는 세 가지 행 경로가 있습니다:
  - 차트 행: `UsageSparkline(data:)`
  - 상한이 있는 미터 행
  - 상한이 없는 텍스트 행
- 지출 행은 상한이 없는 텍스트 행입니다.
- `unboundedRow`는 다음을 렌더링합니다:
  - `data.title`이 있는 `labelColumn`
  - 선택적 알 수 없는 모델 경고 아이콘
  - 오른쪽 정렬된 `data.unboundedDetail`
  - 선택적 부제
- 지출 행의 기존 호버는 다음으로 제한됩니다:
  - 값 텍스트 `.hoverTooltip(data.unboundedValueTooltip)`
  - 알 수 없는 모델 경고 아이콘 `.hoverTooltip(data.unknownModelTooltip)`
- 라벨에는 의도적으로 툴팁이 없습니다: `WidgetData.unboundedLabelTooltip`은 `nil`을 반환합니다.

## 기존 호버와 오버레이 패턴

`hoverTooltip`:

- `Sources/OpenUsage/Views/HoverTooltip.swift`에 구현되어 있습니다.
- 텍스트를 별도의 테두리 없는, 비활성화, 클릭 통과 `NSPanel`에 표시하는 View modifier입니다.
- 주석에는 팝오버 내부의 SwiftUI 오버레이가 팝오버 윈도우와 스크롤 뷰에 의해 잘린다고 명시되어 있으므로, 툴팁은 별도의 패널을 사용합니다.
- 툴팁 패널은 `.popUpMenu` 한 단계 위에 위치하고, key/main이 되지 않으며, `StatusItemController.hidePanel()`과 `DashboardView.resetTransientState()`에서 닫힙니다.

사용량 추세 호버:

- `Sources/OpenUsage/Views/UsageSparkline.swift`의 `UsageSparkline`은 행 제목 전체가 아니라 막대 스트립에만 호버를 붙입니다.
- `Sources/OpenUsage/Views/UsageTrendDetail.swift`의 `TrendHoverState`를 사용합니다:
  - 400ms 표시 지연(dwell)
  - 인라인 행에서 상세 팝오버로 이동하는 동안 180ms 숨김 유예
  - 티어다운 시 닫기
- SwiftUI `.popover(isPresented:arrowEdge:)`를 통해 `UsageTrendDetail`을 표시합니다.
- `UsageTrendDetail`은 호버된 날짜를 하이라이트하기 위한 자체 내부 막대 호버 상태를 갖습니다.
- `Tests/OpenUsageTests/UsageTrendTests.swift`의 테스트가 열기/닫기/빠른 통과 동작을 다룹니다.

팝오버 제약:

- 앱은 더 이상 기본 `NSPopover`에 의존하지 않습니다. `StatusItemController`는 `.popUpMenu` 레벨의 테두리 없는 비활성화 `MenuBarPanel`(`NSPanel`)을 소유합니다.
- 패널은 고정 너비(`320`)와 동적 높이입니다. `DashboardView`는 콘텐츠 높이를 측정해 `PanelHeightModifier` / `PanelHeightBridge`를 통해 전달합니다.
- `StatusItemController`는 저장되고 클램프된 높이로 패널을 열고, 콘텐츠가 바뀌면 SwiftUI 주도 높이 모프를 적용합니다.
- 호버 상세 패널은 의도된 경우가 아니라면 대시보드의 측정된 콘텐츠 높이를 실수로 바꾸면 안 됩니다. 추세 상세 같은 SwiftUI `.popover`는 메인 패널의 콘텐츠 높이에 기여하지 않아야 하며, 여기서는 그것이 바람직합니다.
- 순수한 윈도우 내 오버레이는 `HoverTooltip.swift`에 문서화된 대로 스크롤 뷰와 루트 패널에서 잘릴 위험이 있습니다.

UI 권장 사항:

- Models 패널에는 `hoverTooltip` 대신 `UsageSparkline` / `TrendHoverState` 패턴을 재사용하세요.
- `hoverTooltip`은 짧은 텍스트 메모에만 사용하세요. 모델 내역은 구조화된 콘텐츠이며 패널 내부에서 상호작용/호버가 필요할 수 있으므로 SwiftUI `.popover`가 더 잘 맞습니다.
- `WidgetGroupedListView`가 아니라 `WidgetRowView`에서 `data.isUsagePeriod && data.modelBreakdown != nil`에 트리거를 연결하세요. `WidgetRowView`가 행 레이아웃을 소유하고 차트/상한 있음/상한 없음 렌더링을 이미 처리하기 때문입니다.
- 호버 대상을 명확히 만드세요. 작업 설명에는 지출 지표 행에 호버하면 패널이 열려야 한다고 되어 있지만, 행 수준 호버는 `WidgetGroupedListView.row`의 드래그/재정렬 히트 테스트를 방해할 수 있습니다. 실용적인 절충안은 `WidgetRowView` 내부의 상한 없는 행 콘텐츠 shape에 호버를 붙이되 외부의 기존 드래그 제스처는 유지하는 것입니다. 빠른 통과와 드래그 시작을 테스트하세요.

## 캐싱과 새로 고침 동작

프로바이더 새로 고침 주기:

- `AppContainer.startPeriodicRefresh`는 실행 시와 매 `RefreshSetting.interval`마다 `WidgetDataStore.refreshAll()`을 호출합니다.
- `RefreshSetting.interval`은 5분으로 고정되어 있습니다.
- 수동 새로 고침은 `dataStore.refreshAll(force: true)`를 사용합니다.
- `WidgetDataStore.refresh(providerID:force:)`는 강제가 아니면 `ProviderSnapshotCache.snapshot(providerID:)`을 따릅니다.
- `ProviderSnapshotCache` TTL은 같은 5분 간격입니다.
- 디스크에서 로드된 스냅샷은 즉시 표시되지만, 실행 후 첫 새로 고침을 게이팅할 때 최신 상태로 간주되지 않습니다.

가격 새로 고침 주기:

- `ModelPricingStore.current()`는 스캐너 관점에서 동기이며 로드된 가격을 즉시 반환합니다.
- 소스 갱신 시점이 되면 백그라운드 새로 고침을 시작합니다.
- 가격 소스는 대략 하루에 한 번 새로 고침되며, 실패한 소스는 30분 후에 재시도합니다.
- 스캐너는 항상 현재 로드된 스냅샷으로 가격을 계산하며, 가격 네트워크 fetch를 기다리며 블로킹하지 않습니다.

프로바이더 스캐너 연산:

- Claude와 Codex 스캐너는 경로, 크기, mtime을 키로 하는 파일별 파스 캐시를 가진 actor입니다. 매 새로 고침마다 변경되지 않은 파싱된 항목/이벤트를 재사용하고 중복 제거 + 집계를 다시 실행합니다.
- Cursor는 프로바이더 새로 고침마다 CSV를 가져와 메모리에서 행을 파싱합니다.
- Grok은 새로 고침마다 단일 통합 로그를 읽고 파싱합니다. 현재 파일별 파스 캐시는 없습니다.

모델 내역에 추가 연산이 필요한가?

- Cursor: 미미합니다. 행은 이미 파싱되고 가격이 계산되어 있습니다. 두 번째 집계 패스를 추가하거나 현재 패스를 확장하면 됩니다.
- Claude: 미미~중간. 중복 제거된 항목이 이미 메모리에 있습니다. 집계하면서 `(day, model)`로 그룹화하면 됩니다.
- Codex: 미미~중간. 중복 제거된 이벤트가 이미 메모리에 있습니다. 집계하면서 `(day, model)`로 그룹화하고 같은 비용 함수를 재사용하면 됩니다.
- Grok: 중간. 파서는 라인 패스 중에 모델을 갖고 있지만 현재는 버립니다. 같은 패스에서 그룹화를 추가하고, 로그가 커질 경우 캐싱 추가를 고려하세요.

자연스러운 데이터 소유권:

- 원시 수집 계층이 UI 소유자가 되어서는 안 됩니다. 일별 합계와 함께 프로바이더 중립적인 모델 집계를 내보내야 합니다.
- `SpendTileMapper`는 이미 기간 선택과 알 수 없는 모델 합집합 동작을 소유하므로, 어떤 집계를 `Today`, `Yesterday`, `Last 30 Days`에 첨부할지 선택하는 최적의 경계입니다.
- `WidgetDataStore`는 리졸버로 남아야 하며, 라벨이나 원시 프로바이더 데이터에서 집계를 다시 계산해서는 안 됩니다.

## 권장 데이터 모델

`DailyUsageSeries` 근처에 프로바이더 중립적인 내부 모델을 추가합니다:

- `ModelUsageEntry`
  - `model: String`
  - `totalTokens: Int`
  - `costUSD: Double?`
  - 첫 UI가 토큰 버킷 상세를 원한다면 선택적 `inputTokens`, `cacheWriteTokens`, `cacheReadTokens`, `outputTokens`
  - 선택적 `isUnpriced: Bool`, 또는 `costUSD == nil`에서 파생
- `DailyModelUsageEntry`
  - `date: String`
  - `models: [ModelUsageEntry]`
- `ModelUsageSeries`
  - `daily: [DailyModelUsageEntry]`

또는 내부적으로 딕셔너리 형태를 사용합니다:

- `[String: [String: ModelUsageAccumulator]]`
- 외부 키: `yyyy-MM-dd`
- 내부 키: 표시/정규 모델 이름

그런 다음 매퍼 경계에서만 정렬된 배열로 정규화합니다.

정렬은 결정적이어야 합니다:

- 가격 산정된 지출 내림차순
- 토큰 수 내림차순
- 모델 표시 이름 오름차순
- 가격 미산정 모델도 계속 표시되어야 하며 `Other`로 합쳐지지 않아야 합니다

비용 반올림:

- 내부적으로는 정확한 합산 비용을 유지합니다.
- 표시되는 모델/기간당 한 번 센트 단위로 반올림하며, Cursor의 기존 일별 합계 전략과 일치시킵니다.
- 기존 지출 행에 표시되는 기간 합계는 별도로 반올림된 모델 합계가 아니라 기존 일별 경로의 합계와 여전히 일치해야 합니다.

알 수 없음/귀속 안 됨 행:

- 알 수 없는 가격 소스는 "모델은 알려져 있지만 요율이 없음"을 의미합니다. 모델을 토큰과 함께 달러 비용 없이 표시하고 경고 문구를 추가합니다.
- 귀속 안 됨은 "토큰을 모델에 연결할 수 없음"을 의미합니다(주로 Grok, Claude의 synthetic 행일 수도 있음). 필요한 경우에만 별도의 `Unattributed` 버킷을 사용하고 패널 주석에서 설명합니다.

## 권장 통합 지점

데이터 경로:

1. `DailyUsageSeries.swift`의 `LogUsageScan`을 확장해 모델 집계를 담게 하거나, `SpendUsageScan` 같은 형제 결과 타입을 도입합니다.
2. 업데이트:
   - `ClaudeLogUsageScanner.aggregate(entries:since:pricing:)`
   - `CodexLogUsageScanner.aggregate(events:since:pricing:fastTier:)`
   - `GrokLogUsageScanner.parse(_:since:pricing:)`
   - `CursorUsageMapper.appendSpendLines(rows:now:to:)`
3. `SpendTileMapper.appendTokenUsage`를 확장해 선택적 모델 집계를 받고 올바른 기간 내역을 첨부합니다:
   - `Today`: 오늘의 모델 목록
   - `Yesterday`: 어제의 모델 목록
   - `Last 30 Days`: 가져오거나 스캔한 윈도우의 모든 날짜를 집계
4. `.values` 라인에 구조화된 필드(예: `modelBreakdown: ModelUsageBreakdown?`)를 추가합니다.
5. 해당 필드를 다음을 통해 연결합니다:
   - `MetricLine` Codable 인코드/디코드
   - `WidgetData`
   - `WidgetDataStore.resolve(_:)`
   - `ProviderSnapshotCache` 스토리지 키 범프
6. `LocalUsageAPI.WireLine`의 로컬 API 동작을 결정합니다.
   - 모델 상세가 UI 전용이라면, 공개 와이어 형태에서 의도적으로 생략하고 그 사실을 문서화합니다.
   - 노출한다면, 내부 `MetricLine` Codable에 의존하는 대신 `docs/local-http-api.md`에 명시적으로 문서화된 필드를 추가합니다.

UI 경로:

1. `UsageTrendDetail`을 본뜬 `ModelUsageDetail` SwiftUI 뷰를 추가합니다.
2. `TrendHoverState`를 본뜬 호버 코디네이터를 추가하거나, `TrendHoverState`를 재사용 가능한 지연 호버 팝오버 상태로 일반화합니다.
3. `WidgetRowView.unboundedRow`에서 `data.isUsagePeriod && data.modelBreakdown != nil`이면 코디네이터와 함께 `.popover`를 붙입니다.
4. 정확한 수치와 알 수 없는 모델 아이콘에는 기존 `hoverTooltip` 동작을 유지합니다. 명시적으로 요청되지 않는 한 모델 패널 내부에 추가 `hoverTooltip` 상호작용을 넣지 마세요.
5. 패널을 320pt 호스트 너비에 맞을 만큼 작게 유지하세요. 추세 상세의 240pt 정도 너비가 적당합니다. 차트를 포함한다면 높이에 상한을 두고 내부 스크롤을 사용해 콘텐츠가 대시보드 패널 높이를 강제하지 않게 하세요.

## 리스크와 제약

Swift 6 엄격 동시성:

- 프로바이더 클래스는 `@MainActor`이고, 스캐너는 actor이거나 `Sendable` struct입니다. 새 집계 타입은 `Sendable`이어야 합니다.
- `MetricLine`과 `ProviderSnapshot`은 `Sendable`이자 `Codable`입니다. 새로 첨부되는 페이로드는 둘 다여야 합니다.
- 스캐너 태스크 그룹 내부에서 Sendable이 아닌 스토어/뷰 상태를 캡처하지 마세요.
- `PanelHeightModifier`는 `Animatable`이 nonisolated 요구 사항을 갖기 때문에 의도적으로 nonisolated `GeometryEffect`를 사용합니다. SwiftUI 레이아웃에서 AppKit을 동기적으로 변경하는 모델 호버 높이 로직을 추가하지 마세요.

팝오버와 호버 동작:

- 큰 윈도우 내 오버레이는 패널이나 스크롤 뷰에 의해 잘릴 수 있습니다. SwiftUI `.popover`나 별도의 비활성화 `NSPanel` 패턴을 사용하세요.
- `hoverTooltip`의 패널은 클릭 통과이며 텍스트 전용입니다. 차트나 내부 호버가 있는 구조화된 Models 패널에는 적합하지 않습니다.
- 행 수준 호버는 `WidgetGroupedListView`의 재정렬 드래그 제스처 및 컨텍스트 메뉴와 공존해야 합니다.
- 대시보드 SwiftUI 트리는 패널이 닫혀도 살아남습니다. 모든 호버 코디네이터는 툴팁/추세 팝오버와 같은 닫기 경로에서 닫혀야 합니다.

성능:

- Cursor CSV 파스 비용은 이미 매 Cursor 새로 고침마다 존재합니다. 모델 그룹화는 네트워크 fetch와 파스에 비해 저렴합니다.
- Claude/Codex의 파일별 파스 캐시는 반복 새로 고침을 저렴하게 유지합니다. 모델 그룹화는 현재의 일별 집계처럼 매 새로 고침마다 캐시된 항목/이벤트 위에서 다시 실행됩니다.
- Grok은 파스 캐시 없이 단일 추가 전용 파일을 스캔합니다. 모델 패널은 파일 읽기가 아니라 집계 상태만 늘리지만, 큰 로그는 Grok을 가장 리스크가 높은 프로바이더로 만들 수 있습니다.

데이터 품질:

- Cursor CSV 지출은 UI에서 "From your Cursor usage history"로 설명됩니다. 내부적으로는 CSV 토큰 행과 `ModelPricing`에서 로컬로 추정되며, 현재 `estimated: false`가 로컬 추정 정보 아이콘을 숨깁니다. 문구에 주의하세요: 현재 코드에서 이 달러는 `Cost` CSV 컬럼에서 직접 청구된 달러가 아닙니다.
- Claude는 일부 로그 라인에 명시적 `costUSD`를 담을 수 있으며, 모델 집계에서도 이 값이 로컬 가격보다 우선해야 합니다.
- Codex 모델 대체 규칙(`gpt-5`)과 `codex-auto-review` 날짜 매핑은 스캐너에서 물려받은 근사치입니다. 패널이 완벽하게 정확한 청구 금액을 암시해서는 안 됩니다.
- Grok 모델 귀속은 프로세스 id별 이전 모델 이벤트에 의존합니다. 누락된 모델 컨텍스트는 조용히 버려지지 말고 귀속되지 않은 사용량으로 보여야 합니다.
- 표시 그룹화는 미해결입니다. 현재 `ModelPricing`은 슬러그를 요율로 해석하지만 사용자 대상 패밀리 표시 이름을 노출하지 않습니다. 첫 버전은 원시 모델/정규 슬러그로 그룹화할 수 있으며, 다듬어진 버전은 보충 메타데이터나 작은 표시 이름 포매터가 필요할 수 있습니다.

## 최종 권장 사항

데이터 기능을 별도의 프로바이더별 위젯이 아니라 공유 지출 스파인의 확장으로 만드세요.

최적의 통합 지점은 다음과 같습니다:

- 각 프로바이더의 기존 스캔/CSV 집계 함수 내부에서, `DailyUsageSeries`가 모델 차원을 잃기 전에 모델별 집계를 계산
- 그 집계를 `SpendTileMapper`로 전달
- `Today`, `Yesterday`, `Last 30 Days`를 뒷받침하는 동일한 `MetricLine.values` 행에 기간별 내역을 첨부
- `UsageSparkline`과 `UsageTrendDetail`을 본뜬 지연 SwiftUI 호버 팝오버를 사용해 `WidgetRowView`에서 렌더링

프로바이더 롤아웃 순서는 Cursor가 먼저, 그다음 Claude와 Codex, 그리고 귀속 안 됨/알 수 없음 처리가 정의되면 Grok이어야 합니다. 이렇게 하면 아키텍처를 처음부터 프로바이더 중립적으로 유지하면서 가장 적은 리스크로 즉각적인 가치를 제공합니다.
