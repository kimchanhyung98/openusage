# 프로바이더 추가

OpenUsage에 새 AI 프로바이더를 추가하는 방법.
아래 구성 요소가 맞물리는 방식을 이해하려면 먼저 [아키텍처 개요](/docs/architecture.md)부터 읽기.

## 프로바이더란

프로바이더는 `Sources/OpenUsage/Providers/<Name>/` 아래에 두는 작은 Swift 모듈.
각 모듈은 `ProviderRuntime`을 구현하며, 주요 역할은 다음 세 가지:

- **인증 스토어** — 사용자 Mac의 설정 파일·키체인에서 인증 정보 읽기.
- **사용량 수집** — 클라이언트로 프로바이더 API 호출 또는 스캐너로 로컬 사용 기록 읽기.
- **매퍼** — 수집한 데이터를 공통 지표 타입으로 변환.

대부분의 프로바이더는 공식 CLI나 앱에 저장된 로그인 정보 사용.
OpenRouter처럼 API 키 관리를 지원하는 프로바이더는 OpenUsage에서 키 입력 가능.
OpenCode처럼 로컬 기록만 수집하는 프로바이더는 사용량 조회용 HTTP 클라이언트 불필요.

모든 프로바이더는 `refresh()`와 `hasLocalCredentials()` 구현 필요.
`hasLocalCredentials()`는 인증 정보나 사용 기록 등 로컬 사용 흔적을 확인하는 저비용 검사.
환경 변수·파일·키체인·로컬 데이터베이스 등 이 Mac의 소스만 확인하며 네트워크 사용 금지.
새 설치에서는 `FirstRunSeeder`가 이 결과로 자동 활성화할 프로바이더 선택.
기존 설치에서는 `NewProviderSeeder`가 새 프로바이더를 처음 인식할 때 같은 검사 실행.
자세한 조건은 [활성화되는 프로바이더](/docs/provider-enablement.md) 참조.
검사에는 `refresh()`가 사용하는 인증 정보 출처와 유효성 필터 재사용.
스레드를 차단하는 읽기는 `loadOffMainActor`로 실행.

## 지표 계약

`refresh()`는 `lines`에 `MetricLine` 값을 담은 `ProviderSnapshot`을 반환.
지표 값의 형태에 따라 다음 케이스 선택:

- **`.progress`** — `used`, `limit`, `format`을 가진 상한 있는 미터:
  - `.percent`: 세션·주간 할당량처럼 백분율로 표시하는 한도에 사용.
  - `.dollars`: 달러로 표시하는 크레딧 한도 등에 사용.
  - `.count(suffix:)`: 주기당 요청 수처럼 횟수 한도에 사용.
  - 초기화 시각이 정해져 있으면 `resetsAt` 추가.
  - 주기 길이를 제공할 수 있으면 `periodDurationMs` 추가.
- **`.values`** — 숫자 하나 이상을 담는 상한 없는 행.
  각 숫자는 값·종류·선택적 단위 레이블을 포함한 `MetricValue`로 표현.
  하루 지출의 달러·토큰, Codex 크레딧의 달러·개수처럼 상한 없는 숫자에 사용.
  표시할 값은 위젯 디스크립터에서 선택.
  숫자 형식은 표시 단계에서 적용하므로 메뉴 막대에서 문자열을 다시 파싱할 필요 없음.
- **`.badge`** — `Disabled`나 종량제 상한 같은 짧은 상태 표시.
  진행률보다 짧은 상태 설명이 적합할 때 사용.
- **`.chart`** — 사용량 추이를 표시할 날짜별 숫자 값.
- **`.text`** — 로컬 API에 보존할 프로바이더 안내 문자열.
  위젯을 렌더링하지 않으므로, 디스크립터 기반 행에는 전부 `.progress`, `.values`, `.badge`, `.chart`를 사용.

프로바이더가 요금제 이름을 제공하면 스냅샷의 `plan`에 설정.
실패 시에는 타입이 지정된 프로바이더 오류로 `ProviderSnapshot.error(provider:error:)` 반환.
이를 통해 진단 이벤트가 실패를 로그인·네트워크 등 고정 범주로 분류 가능.
타입이 지정된 오류가 없을 때만 메시지 전용 팩토리 사용.
조회 실패를 숨기기 위해 오래되거나 빈 데이터를 정상 결과로 반환하는 것은 금지.

스토어는 `refresh()` 대기를 시스템 잠자기를 제외한 2분으로 제한.
시간 초과·앱 종료 시 작업 취소 요청.
작업이 취소에 협조하지 않으면 실제 종료까지 같은 프로바이더의 다음 조회 보류.
긴 루프에서는 `Task.isCancelled` 확인.
네트워크 호출은 취소 가능한 형태로 유지.
자세한 동작은 [새로 고침](/docs/refreshing.md) 참고.

## 단계

1. **먼저 확인.**
   열린 이슈와 `docs/providers/`를 살펴 해당 프로바이더가 이미 요청됐거나 작업 중인지 확인.
2. **모듈 생성.**
   `Sources/OpenUsage/Providers/<Name>/`에 인증 스토어, 사용량 클라이언트 또는 스캐너, 매퍼 추가.
   `ProviderRuntime`의 `refresh()`와 `hasLocalCredentials()` 구현.
   로컬 인증 검사에는 기존 인증 스토어 로더와 유효성 필터 재사용.
   인증 정보를 읽는 별도 경로를 추가하거나 이 검사에서 네트워크를 사용하는 것은 금지.
   JSON·숫자·퍼센트 파싱에는 `ProviderParse`, 시각 처리에는 `OpenUsageISO8601` 재사용.
3. **위젯 선언.**
   `WidgetDescriptor+Factories.swift`의 팩토리(`percent`, `boundedDollars`, `spend`, `tokenSpend`, `combined`, `values`, `badge` 등)로 프로바이더의 지표를 `WidgetDescriptor`로 노출.
4. **기본 배치 확인.**
   지표별 기본 활성화 여부, Always Visible/On Demand 위치, 메뉴 막대 고정 여부, 표시 순서를 소유자와 확인.
   확인한 값을 `DefaultLayout.metricIDs`, `DefaultLayout.expandedMetricIDs`, `DefaultLayout.pinnedMetricIDs`와 `widgetDescriptors` 선언 순서에 반영.
   접기 버튼이 필요하면 활성 지표 중 하나 이상을 Always Visible로 유지.
   활성 지표가 전부 On Demand이면 대시보드가 모든 지표를 항상 표시하는 방식으로 처리.
5. **등록.**
   `ProviderCatalog.make()`의 앱·CLI 공용 목록에 프로바이더 추가.
   Claude·Codex·Cursor를 앞에 유지하고, 새 프로바이더는 나머지 목록에 표시 이름의 알파벳순으로 배치.
6. **테스트.**
   샘플 API 응답을 넣고 결과 지표 행을 검사하는 매퍼 테스트를 포함해, `Tests/OpenUsageTests/` 아래에 집중적인 테스트를 추가.
   로컬 기록을 수집하는 프로바이더는 샘플 기록으로 수집·매핑 결과 검사.
7. **문서화.**
   추적 항목, 인증 정보 출처, API 엔드포인트 또는 로컬 기록 위치, 오류 상태의 의미를 `docs/providers/` 아래에 문서화.
8. **실행.**
   `./script/build_and_run.sh`로 앱 빌드·재실행.
   프로바이더 표시와 지표 기본 배치 확인.

## 컨벤션

- 검증은 경계(API 응답)에서만, 앱 내부 타입은 신뢰.
- 숫자를 알아보기 쉽도록 프로바이더 자체 대시보드가 쓰는 지표 레이블과 단위에 맞추기.
- 프로바이더의 **빠른 링크**는 `Provider` 값(`links:`)에 선언.
  각 링크는 카드 확장 영역에 버튼으로 렌더링되는 `ProviderLink(label:url:)`이며, 기본 브라우저에서 URL을 여는 방식.
  프로바이더 자체 Status / Console / Dashboard 페이지가 있으면 포함하고, 없는 프로바이더는 `links` 생략(기본값은 비어 있음).
  프로바이더당 링크는 최대 **두 개**(레이블 예: Status, Dashboard, API Keys, Usage).
  레이블이 비어 있지 않은 `http(s)` URL만 렌더링.

## 선택적 서버 상태 지원

공식 서버 상태는 `ProviderRuntime`과 분리된 선택 기능.
프로바이더가 안정적인 식별자를 가진 공개 HTTPS 컴포넌트 피드를 제공할 때만 상태 카탈로그 항목 추가.
엔드포인트, 상태 값, 컴포넌트 ID와 이름을 정확히 기록.
컴포넌트를 부분적인 이름 일치만으로 선택하는 것은 금지.
사용량 새로 고침 오류만으로 서버 장애를 추론하는 것도 금지.
카탈로그 항목이 없는 프로바이더는 상태 요청을 보내지 않음.

상태 요청에는 인증 정보·계정 정보·사용량 데이터 포함 금지.
같은 프로바이더 계열의 계정 카드는 상태 조회 결과 하나를 공유.
관련·무관 컴포넌트, 유지보수, 알 수 없는 상태, 잘못된 응답, 문서화된 장애 심각도별 테스트 추가.
상태 조회 동작은 해당 프로바이더의 한국어 문서에 반영.

## 사용자 제공 API 키

대부분의 프로바이더는 연동 CLI·앱의 세션이나 키체인에서 기존 인증 정보 사용.
OpenRouter처럼 사용자 제공 API 키가 필요한 프로바이더는 `APIKeyManaging` 구현.
그러면 **Customize → 해당 프로바이더** 화면에 공용 API 키 관리 카드 표시.
프로바이더별 입력 UI를 별도로 만들 필요 없음.

- 인증 스토어의 `keyStatus()`는 `notSet` / `fromEnvironment` / `saved` / `overrideActive` 중 현재 상태 반환.
- `currentAPIKey()`는 사용자가 키 표시를 선택했을 때 현재 키 제공.
- `saveAPIKey(_:)`와 `deleteAPIKey()`는 인증 스토어가 읽는 설정 파일의 저장 키 관리.
  설정 파일이 환경 변수보다 우선하므로 저장된 키가 환경 변수의 키를 대체.
- 프로바이더는 위 동작을 인증 스토어에 위임.
- `AppContainer`는 `APIKeyManaging` 프로바이더를 `apiKeyProviders`로 수집.
  Customize의 프로바이더 상세 화면은 이 목록에서 해당 프로바이더를 찾아 카드 표시.

키는 인증 스토어가 이미 확인하는 파일에 저장.
사용자가 같은 파일을 직접 편집할 수 있도록 별도 저장소 도입 금지.
