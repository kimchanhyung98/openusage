# 모델 호버 패널: 데이터와 아키텍처 실현 가능성

> **과거 기록 / 대체됨.**
> 이 실현 가능성 보고서는 2026-07-04 시점의 구현 전 스냅샷.
> 아래에서 제안하는 모델별 내역 데이터 경로와 지출 행 호버 패널은 같은 날 출시됐으며, 현재 구현은 [대시보드 행](/docs/ko/dashboard.md#행), [`SpendTileMapper.swift`](../../../../Sources/OpenUsage/Providers/SpendTileMapper.swift), [`HoverPopoverState.swift`](../../../../Sources/OpenUsage/Views/HoverPopoverState.swift), [`ModelUsageDetail.swift`](../../../../Sources/OpenUsage/Views/ModelUsageDetail.swift) 참고.
> 이 분석은 현재 상태 문서가 아닌 과거 기록이며, 코드 변화에 따라 세부 구현 참조 수정 가능.

조사 날짜: 2026-07-04.
범위: 이 작업 트리의 현재 `main` 개발선 SwiftPM 앱 아키텍처.
기존 `Today`, `Yesterday`, `Last 30 Days` 지출 행에서 호버로 표시되는 모델별 지출·사용량 내역에 관한 읽기 전용 기술 조사.

> **상태 업데이트(2026-07-10):** 이 문서는 조사 날짜 시점의 구현 전 아키텍처 기록.
> 현재 코드는 `ModelUsageSeries`를 통해 모델별 사용량을 전달하며, Cursor 경계 파서는 사용할 수 없는 CSV 구조에서 예외를 던지고 `CursorUsageCSVParseResult`(`rows`와 `rejectedRowCount`) 반환.
> 현재 사용자 대상 동작은 [Cursor](/docs/ko/providers/cursor.md) 참고.

## 핵심 결론

새 외부 사용량 API 추가 없이 Cursor, Claude, Codex에서 기술적으로 실현 가능하고 Grok에서는 부분적으로 가능.
현재 지출 파이프라인이 원시 프로바이더 입력을 `DailyUsageSeries`로 축소하기 전에 이미 모델 차원 존재.

주요 공백은 구조적 문제로, 현재 지출 행은 일별 합계(`DailyUsageEntry.date`, `totalTokens`, `costUSD`)와 알 수 없는 모델 이름만 수신.
호버 패널에 필요한 모델별 행을 담는 `MetricLine`, `WidgetData`, 캐시된 `ProviderSnapshot`은 현재 없음.

권장 구조: 기존 스캐너·CSV 매퍼가 `DailyUsageSeries`를 계산할 때 프로바이더 중립적인 일별·모델별 집계도 함께 계산해 `SpendTileMapper`로 전달하고, `Today`, `Yesterday`, `Last 30 Days`에 대응하는 `MetricLine.values`에 기간별 내역을 직접 첨부한 뒤 사용 기간 행의 SwiftUI 호버 팝오버를 `WidgetRowView`에서 렌더링.

## 현재 지출 데이터 경로

공유 지출 타일 생성 위치는 `Sources/OpenUsage/Providers/SpendTileMapper.swift`.

`SpendTileMapper.appendTokenUsage(_:to:now:estimated:unknownModelsByDay:)`에서 세 개의 `.values` 행 추가:

- `Today`
- `Yesterday`
- `Last 30 Days`

입력은 `Sources/OpenUsage/Models/DailyUsageSeries.swift`의 `DailyUsageSeries`.
의도적으로 프로바이더 중립적인 이 타입의 필드는 다음뿐:

- `DailyUsageEntry.date`
- `DailyUsageEntry.totalTokens`
- `DailyUsageEntry.costUSD`

현재 `LogUsageScan`에서 추가하는 보조 채널은 하나뿐:

- `series: DailyUsageSeries`
- `unknownModelsByDay: [String: Set<String>]`

따라서 현재 지출 행에는 총비용·토큰과 가격을 알 수 없는 모델 경고를 표시할 데이터만 존재해 모델별 합계 표시에는 부족.

공유 가격 엔진 위치는 `Sources/OpenUsage/Pricing/`:

- `ModelPricing.resolve(model:)`에서 `ModelRates?` 반환.
- `ModelPricing.estimatedCostDollars(model:tokens:)`에서 `TokenBreakdown` 가격 계산.
- `TokenBreakdown`에 `input`, `cacheWrite5m`, `cacheWrite1h`, `cacheRead`, `output`, `isFast` 포함.
- `ModelRates.costDollars(for:)`에서 백만 토큰당 요율, 캐시 쓰기·읽기 요율, 1시간 캐시 쓰기 가격, 존재하는 경우 200k 초과 구간, fast 배율 적용.
- `ModelPricingStore.current()`에서 로드된 최신 가격 스냅샷을 제공하고 소스 갱신 시점이면 백그라운드 새로 고침 시작하며, 가격 소스 갱신 주기는 약 하루.

## 프로바이더 데이터 가용성

### Cursor: 높은 실현 가능성

현재 지출 소스:

- `CursorProvider.appendSpendLines(to:accessToken:)`에서 `CursorUsageClient.fetchUsageCSV(accessToken:start:end:)`를 통해 `https://cursor.com/api/dashboard/export-usage-events-csv` 가져오기.
- 쿼리 기간은 현지 시각 오늘 시작 29일 전부터 `now`까지이므로 오늘과 이전 29개 달력일 포함.
- `CursorUsageCSV.parse(csv:pricing:)`에서 CSV를 `[CursorUsageCSVRow]`로 파싱.
- `CursorUsageMapper.appendSpendLines(rows:now:to:)`에서 행을 `DailyUsageSeries`로 집계한 뒤 `SpendTileMapper.appendTokenUsage(... estimated: false ...)`와 `appendUsageTrend(...)` 호출.

축소 전 사용 가능한 모델별 데이터:

- `Sources/OpenUsage/Providers/Cursor/CursorUsageCSV.swift`의 `CursorUsageCSVRow` 필드:
  - `date: Date`
  - `model: String`
  - `maxMode: Bool`
  - `tokens: TokenBreakdown`
  - `imputedCostDollars: Double?`
- 파서에서 CSV 열 `Model`, `Max Mode`, `Input (w/o Cache Write)`, `Input (w/ Cache Write)`, `Cache Read`, `Output Tokens` 매핑.
- `imputedCostDollars`는 이미 `ModelPricing.estimatedCostDollars(model:tokens:)`를 통해 행별 계산됨.

기존 데이터로 일별·모델별 집계 생성 가능 여부:

- 가능.
  현재 `CursorUsageMapper.appendSpendLines`는 모든 행을 순회해 일별로만 그룹화.
  같은 순회에서 `(day, model)` 그룹화도 가능.
- 비용은 기존 동작에 따라 원시 행 비용을 모두 더한 뒤 행마다가 아닌 집계 경계에서 한 번만 반올림.
  현재 일별 합계도 합산 후 센트 단위로 반올림.
- `imputedCostDollars == nil`인 행도 토큰에 포함하고, 호버 패널에서 해당 모델을 가격 미산정·알 수 없음으로 표시 필요.
  기존의 알 수 없는 모델 경고도 같은 규칙 사용.
- 향후 UI에서 변형 라벨에 `maxMode` 사용 가능하지만 CSV 행이 집계값이므로 현재 비용 추정에 별도 Max Mode 할증은 미적용.

결론: 가장 유력한 시작점.
`DailyUsageSeries` 생성 전부터 Cursor에 행별 모델·토큰·비용 존재.

### Claude: 높은 실현 가능성

현재 지출 소스:

- `ClaudeProvider.probe(state:)`에서 `ClaudeLogUsageScanner.scan(now:pricing:)` 호출.
- 스캐너에서 `CLAUDE_CONFIG_DIR`, `$XDG_CONFIG_HOME/claude`, `~/.claude`로부터 파생된 루트와 Claude Desktop Cowork 로컬 에이전트 모드 세션 디렉터리 아래 Claude Code 로컬 세션 로그 읽기.
- 로그 파일은 `<config dir>/projects/**/*.jsonl`.
- 스캐너에서 `LogUsageScan`을 반환한 뒤 `ClaudeProvider`에서 `SpendTileMapper.appendTokenUsage(scan.series, ..., unknownModelsByDay: scan.unknownModelsByDay)`와 `appendUsageTrend(...)` 호출.

축소 전 사용 가능한 모델별 데이터:

- `Sources/OpenUsage/Providers/Claude/ClaudeLogUsageScanner.swift`의 `ClaudeLogUsageScanner.Entry` 필드:
  - `timestamp: Date`
  - `tokens: TokenBreakdown`
  - `costUSD: Double?`
  - `model: String?`
  - `messageID`, `requestID`, `isSidechain`, `hasSpeed` 등의 중복 제거 필드
- `parseLine(_:)`에서 `message.model`을 읽어 `<synthetic>`을 `nil`로 매핑하고 입력·출력·캐시 토큰 버킷을 파싱하며, 로그 행에 있으면 `costUSD` 유지.
- Claude의 `usage.speed == "fast"` 값으로 `TokenBreakdown.isFast` 설정.
- `aggregate(entries:since:pricing:)`에서 항목 중복 제거 후 이벤트별 가격 계산:
  - 전달된 `costUSD`가 있으면 사용
  - 없으면 `ModelPricing`으로 `model + TokenBreakdown` 가격 계산
  - 알 수 없는 모델도 토큰에 포함하고 `unknownModelsByDay`에 추가

기존 데이터로 일별·모델별 집계 생성 가능 여부:

- 가능.
  집계 함수에 타임스탬프, 모델, 토큰 버킷, 비용 출처가 있는 중복 제거된 이벤트 단위 `Entry` 레코드 존재.
- `tokensByDay`와 `costByDay`로 축소하기 전에 `ClaudeLogUsageScanner.aggregate` 확장 또는 병렬 처리 필요.
- `model == nil`인 항목은 `costUSD`가 있을 때만 현재 일별 총지출·토큰에 포함 가능하며, 모델 패널에는 `Unknown Model` 같은 명시적 표시 버킷을 두거나 설명과 함께 생략 필요.
  숨긴 토큰 때문에 합계가 달라지지 않도록 주의.

결론: 스캐너 집계 변경만으로 실현 가능하며 새 API 불필요.

### Codex: 높은 실현 가능성

현재 지출 소스:

- `CodexProvider.probe(authState:)`에서 `CodexLogUsageScanner.scan(now:pricing:)` 호출.
- 스캐너에서 `sessions/`와 `archived_sessions/`를 포함한 `CODEX_HOME` 또는 `~/.codex`의 Codex CLI 롤아웃·세션 로그 읽기.
- `LogUsageScan` 반환 후 `CodexProvider`에서 `SpendTileMapper.appendTokenUsage(scan.series, ..., unknownModelsByDay: scan.unknownModelsByDay)`와 `appendUsageTrend(...)` 호출.

축소 전 사용 가능한 모델별 데이터:

- `Sources/OpenUsage/Providers/Codex/CodexLogUsageScanner.swift`의 `CodexLogUsageScanner.Event` 필드:
  - `timestamp: Date`
  - `model: String`
  - `input: Int`
  - `cached: Int`
  - `output: Int`
  - `reasoning: Int`
  - `total: Int`
- `parseFile(_:)`에서 `turn_context` 레코드의 현재 모델 추적, `token_count` 이벤트 처리, `resolveModel(...)`로 다음 동작 수행:
  - 명시적 모델 메타데이터가 있으면 사용
  - 없으면 현재 세션 모델로 대체
  - 모델 메타데이터가 없는 초기 세션은 `gpt-5`로 대체
  - 폐기된 `codex-auto-review`는 날짜별 대체 모델로 매핑
- `aggregate(events:since:pricing:fastTier:)`에서 복사된 로그 전체의 동일 이벤트 중복 제거, 일별 그룹화, 모델별 요율 확인, `CodexLogUsageScanner.cost(rates:event:fastTier:)`로 가격 계산.

기존 데이터로 일별·모델별 집계 생성 가능 여부:

- 가능.
  `Event`에 `(day, model)` 그룹화와 토큰·비용 계산에 충분한 데이터 존재.
- fast/priority 서비스 티어는 `config.toml`에서 읽는 스캔 전체의 계정 단위 설정이므로, 기존 지출 타일과 합계를 맞추려면 모델별 집계에도 동일한 `fastTier` 플래그와 `cost(rates:event:fastTier:)` 도우미 사용 필요.
- `reasoning` 필드는 `total`에 포함되지만 현재 비용 계산에서는 `output`만 과금.
  리포트 UI의 토큰 라벨에 주의 필요: 타일과 맞도록 총 토큰을 표시하거나 비용 규칙이 명확할 때만 input/cached/output/reasoning 상세 표시.

결론: 스캐너 집계 변경만으로 실현 가능하며 새 API 불필요.

### Grok: 중간 실현 가능성

현재 지출 소스:

- `GrokProvider.probe(state:accessToken:)`에서 `GrokLogUsageScanner.scan(daysBack:now:pricing:)` 호출.
- 스캐너에서 추가 전용 로그 `$GROK_HOME/logs/unified.jsonl` 또는 `~/.grok/logs/unified.jsonl` 하나 읽기.
- `DailyUsageSeries?`를 직접 반환한 뒤 `GrokProvider`에서 `SpendTileMapper.appendTokenUsage(tokenUsage, ...)`와 `appendUsageTrend(...)` 호출.

축소 전 사용 가능한 모델별 데이터:

- `GrokLogUsageScanner.parse(_:since:pricing:)`에서 `modelByPID: [Int: String]` 추적.
- 다음과 같은 메시지에서 모델 변경 이벤트 수집:
  - `model changed`
  - `model catalog: notifying clients`
  - `backend_search: model switch`
  - `subagent model resolved`
- 토큰 행은 `shell.turn.inference_done` 라인.
  prompt/completion/reasoning/cache 토큰 수를 포함하지만 모델 id는 직접 포함하지 않음.
- 스캐너에서 토큰 행을 해당 프로세스 id의 현재 모델에 귀속한 뒤 `ModelPricing.estimatedCostDollars(...)`로 가격 계산.

기존 데이터로 일별·모델별 집계 생성 가능 여부:

- 대부분 가능하지만 다른 프로바이더보다 제약이 큼.
- 현재 파서는 비용 계산 시점에 추론된 모델을 보유하므로 반환 전에 `(day, model)` 그룹화 가능.
- 현재 `LogUsageScan`이 아닌 `DailyUsageSeries`만 반환하고 `unknownModelsByDay`는 미추적.
  알 수 없거나 귀속되지 않은 Grok 행은 토큰에 포함되지만 가격은 미산정 상태이며 UI에 누락 모델 이름도 표시되지 않음.
- 토큰 행보다 앞선 해당 `pid`의 모델 이벤트가 없으면 기존 일별 합계에 토큰은 포함되지만 가격은 계산되지 않음.
  모델 패널에 명확한 `Unattributed` 버킷을 두거나 일부 토큰을 모델에 연결하지 못했다는 설명 필요.

결론: 추론된 모델 id가 있는 행은 실현 가능하지만, Grok을 포함하는 첫 구현에서 귀속되지 않은 행을 명시적으로 처리하고 알 수 없는 모델 추적 추가 필요.

## 지출 행 렌더링 경로

지표 식별:

- `Sources/OpenUsage/Models/WidgetDescriptor+Factories.swift`의 `WidgetDescriptor.spendTiles(provider:)`에서 지출 디스크립터 세 개 선언:
  - `<provider>.today`
  - `<provider>.yesterday`
  - `<provider>.last30`
- 각 디스크립터는 `isUsagePeriod: true`인 `.combined(...)` 행.
- 디스크립터 `metricLabel`이 제목: `Today`, `Yesterday`, `Last 30 Days` 중 하나.

레이아웃 기본값:

- `DefaultLayout.metricIDs`에서 Claude, Codex, Cursor, Grok의 지출 행 활성화.
- `DefaultLayout.expandedMetricIDs`에서 해당 지출 행을 기본적으로 프로바이더 캐럿 아래 배치.
- `DefaultLayout.pinnedMetricIDs`에서 해당 행을 기본적으로 고정하지 않음.

스냅샷에서 뷰까지:

- 프로바이더 새로 고침 결과로 `ProviderSnapshot.lines: [MetricLine]` 생성.
- `WidgetDataStore.data(for:)`에서 `snapshot.line(label: descriptor.metricLabel)`을 조회해 `WidgetDescriptor` 해석.
- `.values` 행의 경우 `WidgetDataStore.resolve`에서 원시 `values`, `expiriesAt`, `unknownModels`를 `WidgetData`에 복사한 뒤 다음 값 설정:
  - 전역 미터 스타일
  - 재설정 표시 모드
  - `alwaysShowPacing`
- `WidgetGroupedListView`에서 각 행을 해석하고 `WidgetRowView(data: ...)` 렌더링.

현재 행 구조:

- `WidgetRowView`의 행 경로 세 가지:
  - 차트 행: `UsageSparkline(data:)`
  - 상한이 있는 미터 행
  - 상한이 없는 텍스트 행
- 지출 행은 상한이 없는 텍스트 행.
- `unboundedRow` 렌더링 항목:
  - `data.title`을 포함한 `labelColumn`
  - 선택적인 알 수 없는 모델 경고 아이콘
  - 오른쪽 정렬 `data.unboundedDetail`
  - 선택적 부제
- 지출 행의 기존 호버 범위:
  - 값 텍스트 `.hoverTooltip(data.unboundedValueTooltip)`
  - 알 수 없는 모델 경고 아이콘 `.hoverTooltip(data.unknownModelTooltip)`
- 라벨에는 의도적으로 툴팁 없음: `WidgetData.unboundedLabelTooltip`에서 `nil` 반환.

## 기존 호버와 오버레이 패턴

`hoverTooltip`:

- 구현 위치는 `Sources/OpenUsage/Views/HoverTooltip.swift`.
- 별도의 테두리 없는 비활성 클릭 통과 `NSPanel`에 텍스트를 표시하는 View 수정자.
- 주석에 따르면 팝오버 내부 SwiftUI 오버레이는 팝오버 윈도우와 스크롤 뷰에서 잘리므로 툴팁은 별도 패널 사용.
- 툴팁 패널은 `.popUpMenu`보다 한 단계 위에 위치하고 key/main 상태가 되지 않으며, `StatusItemController.hidePanel()`과 `DashboardView.resetTransientState()`에서 닫힘.

사용량 추세 호버:

- `Sources/OpenUsage/Views/UsageSparkline.swift`의 `UsageSparkline`은 전체 행 제목이 아닌 막대 영역에만 호버 연결.
- `Sources/OpenUsage/Views/UsageTrendDetail.swift`의 `TrendHoverState` 사용:
  - 400ms 머문 뒤 표시
  - 인라인 행에서 상세 팝오버로 이동하는 동안 180ms 숨김 유예
  - 뷰 해체 시 닫기
- SwiftUI `.popover(isPresented:arrowEdge:)`로 `UsageTrendDetail` 표시.
- `UsageTrendDetail`에 호버한 날짜를 강조하는 자체 내부 막대 호버 상태 존재.
- `Tests/OpenUsageTests/UsageTrendTests.swift`의 테스트에서 열기·닫기·빠른 통과 동작 검증.

팝오버 제약:

- 앱은 더 이상 기본 `NSPopover`에 의존하지 않으며, `StatusItemController`가 `.popUpMenu` 레벨의 테두리 없는 비활성 `MenuBarPanel`(`NSPanel`) 소유.
- 패널 너비는 고정(`320`), 높이는 동적.
  `DashboardView`에서 콘텐츠 높이를 측정해 `PanelHeightModifier` / `PanelHeightBridge`로 전달.
- `StatusItemController`에서 저장된 높이를 허용 범위로 제한해 패널을 열고 콘텐츠 변화에 따라 SwiftUI 주도 높이 전환 적용.
- 의도한 경우가 아니라면 호버 상세 패널이 대시보드의 측정 콘텐츠 높이를 바꾸지 않도록 주의.
  추세 상세 같은 SwiftUI `.popover`는 메인 패널 콘텐츠 높이에 포함되지 않으며, 여기서는 바람직한 동작.
- 순수한 윈도우 내부 오버레이는 `HoverTooltip.swift`에 문서화된 대로 스크롤 뷰와 루트 패널에서 잘릴 위험 존재.

UI 권장 사항:

- Models 패널에는 `hoverTooltip` 대신 `UsageSparkline` / `TrendHoverState` 패턴 재사용.
- `hoverTooltip`은 짧은 텍스트 메모에만 사용하고, 모델 내역은 구조화된 콘텐츠이며 패널 내부의 상호작용·호버가 필요할 수 있어 SwiftUI `.popover`가 더 적합.
- `WidgetGroupedListView`가 아닌 `WidgetRowView`에서 `data.isUsagePeriod && data.modelBreakdown != nil`에 트리거 연결: `WidgetRowView`가 행 레이아웃을 소유하고 차트·상한 있음·상한 없음 렌더링을 이미 처리하기 때문.
- 호버 대상은 의도적으로 지정.
  작업 설명상 지출 지표 행에 호버하면 패널이 열려야 하지만, 행 단위 호버가 `WidgetGroupedListView.row`의 드래그·재정렬 히트 테스트를 방해할 가능성 존재.
  실용적인 절충안은 `WidgetRowView` 내부의 상한 없는 행 content shape에 호버를 연결하면서 외부의 기존 드래그 제스처를 유지하는 방식이며, 빠른 통과와 드래그 시작 테스트 필요.

## 캐싱과 새로 고침 동작

프로바이더 새로 고침 주기:

- `AppContainer.startPeriodicRefresh`에서 실행 시점과 매 `RefreshSetting.interval`마다 `WidgetDataStore.refreshAll()` 호출.
- `RefreshSetting.interval`은 5분으로 고정.
- 수동 새로 고침은 `dataStore.refreshAll(force: true)` 사용.
- `WidgetDataStore.refresh(providerID:force:)`에서 강제 실행이 아니면 `ProviderSnapshotCache.snapshot(providerID:)` 사용.
- `ProviderSnapshotCache` TTL도 동일한 5분.
- 디스크에서 불러온 스냅샷은 즉시 표시되지만 실행 후 첫 새로 고침 여부를 판단할 때 최신으로 간주되지 않음.

가격 새로 고침 주기:

- 스캐너 관점에서 `ModelPricingStore.current()`는 동기식이며 로드된 가격을 즉시 반환.
- 소스 갱신 시점이면 백그라운드 새로 고침 시작.
- 가격 소스는 약 하루마다 갱신하고 실패한 소스는 30분 후 재시도.
- 스캐너는 항상 현재 로드된 스냅샷으로 가격을 계산하고, 가격 네트워크 가져오기를 기다리며 차단하지 않음.

프로바이더 스캐너 연산:

- Claude와 Codex 스캐너는 경로·크기·mtime을 키로 한 파일별 파싱 캐시를 가진 actor.
  새로 고칠 때마다 변경되지 않은 파싱 항목·이벤트를 재사용하고 중복 제거와 집계를 다시 실행.
- Cursor는 프로바이더를 새로 고칠 때마다 CSV를 가져와 메모리에서 행 파싱.
- Grok은 새로 고칠 때마다 단일 통합 로그를 읽고 파싱하며 현재 파일별 파싱 캐시 없음.

모델 내역에 추가 연산 필요 여부:

- Cursor: 최소.
  행은 이미 파싱 및 가격 계산 완료.
  두 번째 집계 과정을 추가하거나 현재 과정 확장.
- Claude: 최소에서 보통.
  중복 제거된 항목이 이미 메모리에 있으므로 집계 중 `(day, model)`로 그룹화.
- Codex: 최소에서 보통.
  중복 제거된 이벤트가 이미 메모리에 있으므로 집계 중 `(day, model)`로 그룹화하고 같은 비용 함수 재사용.
- Grok: 보통.
  파서가 행을 순회할 때 모델을 보유하지만 현재는 폐기.
  같은 순회에서 그룹화를 추가하고 로그가 커지면 캐싱 도입 검토.

자연스러운 데이터 소유권:

- 원시 수집 계층이 UI 소유자가 되어서는 안 됨.
  일별 합계와 함께 프로바이더 중립적인 모델 집계 출력 필요.
- `SpendTileMapper`는 기간 선택과 알 수 없는 모델 합집합 동작을 이미 소유하므로 `Today`, `Yesterday`, `Last 30 Days`에 연결할 집계를 선택하는 최적의 경계.
- `WidgetDataStore`는 리졸버로 유지하고 라벨이나 원시 프로바이더 데이터에서 집계를 다시 계산하지 않음.

## 권장 데이터 모델

`DailyUsageSeries` 근처에 프로바이더 중립적인 내부 모델 추가:

- `ModelUsageEntry`
  - `model: String`
  - `totalTokens: Int`
  - `costUSD: Double?`
  - 첫 UI에 토큰 버킷 상세가 필요하면 선택적 `inputTokens`, `cacheWriteTokens`, `cacheReadTokens`, `outputTokens`
  - 선택적 `isUnpriced: Bool`, 또는 `costUSD == nil`에서 파생
- `DailyModelUsageEntry`
  - `date: String`
  - `models: [ModelUsageEntry]`
- `ModelUsageSeries`
  - `daily: [DailyModelUsageEntry]`

또는 내부적으로 딕셔너리 형태 사용:

- `[String: [String: ModelUsageAccumulator]]`
- 외부 키: `yyyy-MM-dd`
- 내부 키: 표시·정규 모델 이름

이후 매퍼 경계에서만 정렬된 배열로 정규화.

정렬은 결정적이어야 함:

- 가격이 산정된 지출 내림차순
- 토큰 수 내림차순
- 모델 표시 이름 오름차순
- 가격 미산정 모델도 계속 표시하고 `Other`에 통합하지 않음

비용 반올림:

- 내부에서는 정확한 합산 비용 유지.
- 표시 모델·기간마다 한 번 센트 단위로 반올림해 Cursor의 기존 일별 합계 전략과 일치.
- 기존 지출 행에 표시하는 기간 합계는 별도로 반올림한 모델 합계가 아닌 기존 일별 경로의 합계와 계속 일치 필요.

알 수 없음·귀속되지 않음 행:

- 가격 미산정은 모델은 알려져 있지만 요율이 없는 상태를 의미.
  해당 모델의 토큰은 표시하되 달러 비용은 표시하지 않고 경고 문구 제공.
- 귀속되지 않음은 토큰을 모델에 연결할 수 없는 상태를 의미하며 주로 Grok, 경우에 따라 Claude 합성 행에 해당.
  필요할 때만 별도의 `Unattributed` 버킷을 사용하고 패널 설명에 명시.

## 권장 통합 지점

데이터 경로:

1. `DailyUsageSeries.swift`의 `LogUsageScan`을 확장해 모델 집계를 포함하거나 `SpendUsageScan` 같은 별도 결과 타입 도입.
2. 다음 항목 업데이트:
   - `ClaudeLogUsageScanner.aggregate(entries:since:pricing:)`
   - `CodexLogUsageScanner.aggregate(events:since:pricing:fastTier:)`
   - `GrokLogUsageScanner.parse(_:since:pricing:)`
   - `CursorUsageMapper.appendSpendLines(rows:now:to:)`
3. `SpendTileMapper.appendTokenUsage`를 확장해 선택적 모델 집계를 받고 적절한 기간별 내역 첨부:
   - `Today`: 오늘 모델 목록
   - `Yesterday`: 어제 모델 목록
   - `Last 30 Days`: 가져오거나 스캔한 기간의 모든 날짜 집계
4. `.values` 행에 구조화된 필드 추가(예: `modelBreakdown: ModelUsageBreakdown?`).
5. 해당 필드를 다음 경로로 전달:
   - `MetricLine` Codable 인코딩·디코딩
   - `WidgetData`
   - `WidgetDataStore.resolve(_:)`
   - `ProviderSnapshotCache` 저장소 키 버전 증가
6. `LocalUsageAPI.WireLine`의 로컬 API 동작 결정.
   - 모델 상세가 UI 전용이면 공개 와이어 형태에서 의도적으로 제외하고 이를 문서화.
   - 외부에 노출한다면 내부 `MetricLine` Codable에 의존하지 않고 `docs/local-http-api.md`에 명시적인 필드 문서화.

UI 경로:

1. `UsageTrendDetail`을 본뜬 `ModelUsageDetail` SwiftUI 뷰 추가.
2. `TrendHoverState`를 본뜬 호버 코디네이터 추가 또는 `TrendHoverState`를 재사용 가능한 지연 호버 팝오버 상태로 일반화.
3. `WidgetRowView.unboundedRow`에서 `data.isUsagePeriod && data.modelBreakdown != nil`이면 코디네이터와 함께 `.popover` 연결.
4. 정확한 수치와 알 수 없는 모델 아이콘에는 기존 `hoverTooltip` 동작 유지.
   명시적인 요청 없이는 모델 패널 내부에 추가 `hoverTooltip` 상호작용 미추가.
5. 패널 크기를 320pt 호스트 너비에 맞게 제한.
   추세 상세의 240pt 정도 너비가 적절한 후보이며, 차트가 있다면 높이를 제한하고 내부 스크롤을 사용해 콘텐츠가 대시보드 패널 높이를 강제로 늘리지 않도록 처리.

## 위험과 제약

Swift 6 엄격 동시성:

- 프로바이더 클래스는 `@MainActor`, 스캐너는 actor 또는 `Sendable` 구조체.
  새 집계 타입은 `Sendable` 필수.
- `MetricLine`과 `ProviderSnapshot`은 `Sendable`이자 `Codable`이므로 새 첨부 페이로드도 두 프로토콜 준수 필요.
- 스캐너 태스크 그룹에서 Sendable이 아닌 저장소·뷰 상태 캡처 금지.
- `PanelHeightModifier`는 `Animatable`의 nonisolated 요구 사항 때문에 의도적으로 nonisolated `GeometryEffect` 사용.
  SwiftUI 레이아웃에서 AppKit을 동기 변경하는 모델 호버 높이 로직 추가 금지.

팝오버와 호버 동작:

- 큰 윈도우 내부 오버레이는 패널이나 스크롤 뷰에서 잘릴 수 있음.
  SwiftUI `.popover` 또는 별도의 비활성 `NSPanel` 패턴 사용.
- `hoverTooltip` 패널은 클릭 통과 및 텍스트 전용이므로 차트나 내부 호버가 있는 구조화된 Models 패널에는 부적합.
- 행 단위 호버는 `WidgetGroupedListView`의 재정렬 드래그 제스처 및 컨텍스트 메뉴와 공존 필요.
- 패널을 닫아도 대시보드 SwiftUI 트리는 유지되므로 모든 호버 코디네이터를 툴팁·추세 팝오버와 같은 닫기 경로에서 해제 필요.

성능:

- Cursor CSV 파싱 비용은 이미 Cursor를 새로 고칠 때마다 발생.
  모델 그룹화 비용은 네트워크 가져오기와 파싱보다 작음.
- Claude·Codex의 파일별 파싱 캐시 덕분에 반복 새로 고침 비용이 낮고, 모델 그룹화는 현재 일별 집계처럼 새로 고칠 때마다 캐시된 항목·이벤트를 다시 순회.
- Grok은 파싱 캐시 없이 단일 추가 전용 파일 스캔.
  모델 패널은 파일 읽기가 아닌 집계 상태만 늘리지만, 큰 로그에서는 Grok의 위험이 가장 클 수 있음.

데이터 품질:

- Cursor CSV 지출의 UI 설명은 "From your Cursor usage history"이며, 내부에서는 CSV 토큰 행과 `ModelPricing`으로 로컬 추정하고 현재 `estimated: false`가 로컬 추정 정보 아이콘을 숨김.
  문구 작성 시 주의 필요: 현재 코드의 달러 값은 `Cost` CSV 열에서 직접 가져온 청구 금액이 아님.
- 일부 Claude 로그 행에 명시적 `costUSD`가 포함될 수 있으며 모델 집계에서도 로컬 가격보다 우선 사용 필요.
- Codex 모델 대체 규칙(`gpt-5`)과 `codex-auto-review` 날짜 매핑은 스캐너에서 이어진 근사치.
  패널에서 완벽한 청구 정확도를 암시하지 않도록 주의.
- Grok 모델 귀속은 프로세스 id별 이전 모델 이벤트에 의존.
  모델 컨텍스트 누락을 조용히 버리지 않고 귀속되지 않은 사용량으로 표시 필요.
- 표시 그룹화 방식은 미정.
  현재 `ModelPricing`은 슬러그를 요율로 해석하지만 사용자 대상 모델군 표시 이름은 노출하지 않음.
  첫 버전은 원시 모델·정규 슬러그로 그룹화 가능하지만 완성도 높은 버전에는 보충 메타데이터나 간단한 표시 이름 포매터가 필요할 수 있음.

## 최종 권장 사항

데이터 기능을 별도의 프로바이더별 위젯이 아닌 공유 지출 경로의 확장으로 구현.

최적의 통합 지점:

- 각 프로바이더의 기존 스캔·CSV 집계 함수에서 `DailyUsageSeries`가 모델 차원을 잃기 전에 모델별 집계 계산
- 해당 집계를 `SpendTileMapper`로 전달
- `Today`, `Yesterday`, `Last 30 Days`를 뒷받침하는 동일한 `MetricLine.values` 행에 기간별 내역 첨부
- `UsageSparkline`과 `UsageTrendDetail` 패턴을 따른 지연 SwiftUI 호버 팝오버를 사용해 `WidgetRowView`에서 렌더링

프로바이더 출시 순서는 Cursor, Claude·Codex, 귀속되지 않음·알 수 없음 처리를 정의한 뒤 Grok 순서 권장.
아키텍처를 처음부터 프로바이더 중립적으로 유지하면서 최소 위험으로 즉각적인 가치 제공 가능.
