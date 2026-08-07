# 아키텍처

코드를 다루는 사람을 위해 OpenUsage의 구성을 한눈에 정리한 문서입니다. 앱이
*무엇을 하는지* 알고 싶다면 먼저 [동작 문서](README.md)를 읽어 보세요.

## 앱의 형태

OpenUsage는 공유 모듈 하나와 얇은 실행 파일 두 개로 이루어진 SwiftPM 패키지이며 Xcode 프로젝트는 없습니다.
메인 실행 파일은 메뉴 막대 앱입니다. AppKit의 메뉴 막대 항목과 패널 안에서 SwiftUI 인터페이스를
호스팅합니다.
코드는 역할별로 묶여 있습니다:

- `App/` — 앱 시작과 AppKit 브리지(메뉴 막대 항목, 패널, 앱 진입점)를 담당합니다.
- `Models/` — 앱의 나머지 부분이 사용하는 작은 값 타입(`MetricLine`, `WidgetData`, 디스크립터)입니다.
- `Providers/` — 프로바이더별 디렉터리입니다(Claude, Codex, Cursor, Devin, Grok, OpenCode 등).
- `Stores/` — UI가 관찰하는 변경 가능한 상태입니다.
- `Services/` — 공통 인프라(HTTP, 로컬 API, 프로세스 실행)입니다.
- `Support/` — 공통 헬퍼(포맷팅, 파싱, 애니메이션)입니다.
- `Views/` — SwiftUI 화면(대시보드, Customize, 설정, 메뉴 막대 스트립)입니다.

## 컴포지션 루트

`AppContainer`가 모든 것을 연결하는 구성 루트입니다. 실행 시 프로바이더 목록을 만들어
`WidgetRegistry`로 변환하고, 스토어를 생성한 뒤 주기적인 새로 고침 루프와 로컬 HTTP API를 시작합니다.
다른 구성 요소는 전역 객체에 직접 접근하지 않고 여기서 필요한 의존성을 받습니다. 덕분에 각 부분을
독립적으로 테스트할 수 있습니다.

`openusage` 실행 파일도 같은 모듈을 임포트합니다. 매 실행마다 시작 account pass를 포함해 표준
`ProviderCatalog`를 구성하고, `ProviderSnapshotCache`를 읽기 전에 없거나 오래된 항목을
`WidgetDataStore`로 새로 고칩니다. `--force`는 5분 캐시 유효성 검사만 건너뜁니다. 프로바이더는 내보내는 스칼라 리소스를 안정적인 limits 계약으로 선언하며, CLI와
`/v1/limits`는 동일한 정규화 스냅샷과 직렬화기를 공유합니다. GUI를 띄우지도 않고
프로바이더, 인증, 가격, 매핑 로직을 중복 구현하지도 않습니다.

## 프로바이더 파이프라인

각 프로바이더는 `ProviderRuntime`을 준수하는 작은 모듈입니다. 새로 고침은 세 부분으로 나뉩니다:

1. **인증 스토어** — Mac에 이미 있는 인증 정보(설정 파일, 키체인)를 읽습니다. OpenUsage는
   사용자에게 토큰을 붙여 넣도록 요구하지 않습니다.
2. **사용량 클라이언트** — 프로바이더 API에 HTTP 요청을 보냅니다.
3. **매퍼** — 프로바이더 응답을 앱의 표현 형식으로 변환합니다. 타입이 지정된 위젯 값(`.progress`,
   `.values`, `.badge`, `.chart`)과, 로컬 API에서는 계속 제공되지만 위젯으로는 렌더링되지 않는
   `.text` 알림을 담은 `ProviderSnapshot`입니다.

모든 프로바이더가 동일하게 정규화된 `MetricLine` 형태를 만들기 때문에, UI는 프로바이더별 세부 사항을
알 필요 없이 모두 같은 방식으로 렌더링합니다. 프로바이더를 추가하려면
[프로바이더 추가](adding-a-provider.md)를 참조하세요.

Claude, Codex, pi는 로컬 JSONL 기록을 읽을 때 `IncrementalJSONLScanner`를 공유합니다.
파일별로 파싱된 이벤트는 경로, 크기, 수정 시각을 키로 버전이 관리되는 Application Support 스토어에 캐시되며 프로바이더와 홈 식별자별로 나뉩니다.
같은 홈을 읽는 프로바이더 인스턴스는 하나의 스캐너 액터를 공유해 카드마다 중복으로 파싱하지 않습니다.
디스크 스토어는 프로세스를 다시 실행한 뒤에도 결과를 재사용하게 합니다.
소스 파일의 수정일이 요청한 기록 기간을 벗어나면 스캔에서 해당 레코드를 제거합니다.
집계와 가격 계산은 새로 고칠 때마다 캐시된 이벤트를 사용해 다시 수행합니다.
시작 시 account pass가 추가 Claude 계정 카드, 로그 경로, 비활성 관리형 계정의 읽기 전용 snapshot 카드를 조립합니다.
Settings의 계정 동작이 그 pass를 다시 실행하므로 앱을 재실행하지 않아도 카드가 계정 변경을 따라갑니다.
대시보드 선택기는 관리형 프로필에 매핑된 카드만 묶습니다.
관련 없는 자동 탐색 config-dir 카드는 독립적으로 유지합니다.
공유 pi 로그는 어느 Claude 로그인이 만든 것인지 확인할 수 없으므로 Claude 계정 카드가 분리된 동안에는 생략합니다.
config dir이 다른 계정으로 다시 로그인되면 reconcile이 해당 source 연결을 새 identity로 옮기고 이전 레코드와 기록은 유지합니다.

credential/cache identity와 iCloud history 귀속은 별개입니다.
관리형 bare Claude/Codex runtime은 현재 인증 identity 하나를 가지지만 공유 홈 로그에는 전환한 여러 계정의 세션이 함께 있을 수 있습니다.
따라서 해당 history는 선택 profile identity 없이 family 합계로 내보냅니다.
로그 root가 증명된 계정 하나에 고정된 discovery 카드는 기존 identity 기반 history를 유지합니다.

## 스토어

UI는 몇 개의 관찰 가능한 스토어에서 읽습니다:

- `WidgetDataStore` — 프로바이더별 최신 스냅샷, 새로 고침, 캐싱을 담당합니다. Mac 로컬 캐시
  스냅샷을 렌더링된 스냅샷과 분리해 두어, 다른 Mac의 기록을 다시 기록하는 과정에서 중복 집계되는
  일이 없도록 합니다.
- `LayoutStore` — 어떤 지표를 표시할지, 프로바이더/지표 순서, 메뉴 막대에 고정할 지표를 관리합니다.
- `ProviderEnablementStore` — 사용자가 켜거나 끈 프로바이더를 관리합니다.
- `ProviderAccountsStore` — Claude/Codex 로그인의 안정적인 카드 id, 계정별 소스, 이름 변경을 관리하는 account-first 레지스트리입니다.
  `AccountProfilesStore`는 관리형 계정 레코드와 family별 선택 계정을 저장합니다.
  각 레코드는 안정적인 id, 프로바이더가 증명한 계정 identity, 편집 가능한 계정명을 가집니다.
  `openusage account` CLI는 같은 defaults 도메인을 통해 이 레코드를 읽기 전용으로 공유합니다.
  계정 credential은 계정별 Keychain 스냅샷에 있습니다.
  공식 재로그인은 공유 설정 홈이 아니라 Application Support 아래의 앱 소유 로그인 작업 공간에서 실행됩니다.
  관리형 계정 모델(레지스트리, Keychain 스냅샷, 로그인 작업 공간, 전환 트랜잭션)은 family 중립적이라, 이후 다른 프로바이더의 계정 전환도 별도 체계를 만들지 않고 같은 기반을 확장해 추가합니다.
- `ICloudUsageSyncStore` — Mac별 원자적 기록 파일 하나, iCloud 메타데이터 알림, 화면에 표시할
  기기/오류 상태를 관리합니다. 수명 주기와 실패 상황을 테스트할 수 있도록 파일 접근을 주입받습니다.

새로 고침은 `AppContainer`의 타이머가 실행합니다. 각 순회는 캐시 유효 기간을 확인하므로 스냅샷이
실제로 만료된 경우에만 네트워크를 사용합니다.

지출 타일이 있는 프로바이더는 내보내기 디스크립터와 함께 기록 범위도 명시합니다.
Mac 로컬 소스는 여러 기기의 파일을 합산할 수 있지만, Cursor처럼 계정 전체를 이미 나타내는
소스는 합산하지 않습니다. `WidgetDataStore`는 합쳐진 기록으로 지출 행만 다시 렌더링하고,
할당량과 오류 상태는 이 Mac의 값으로 유지합니다.

## AppKit 브리지

macOS 메뉴 막대 앱은 `NSStatusItem` 안에서 동작합니다. OpenUsage는 `NSPopover` 대신 키 입력을 받을 수
있는 커스텀 `NSPanel`에 콘텐츠를 표시합니다. 팝오버 창은 앱 전체가 활성 상태일 때만 키가 되고, 최근
macOS에서 메뉴 막대(액세서리) 앱을 활성화하는 것은 비동기적이고 불안정하기 때문에, 팝오버는 두 번째
클릭 전까지 키 입력을 받지 못하게 됩니다. 반면 `canBecomeKey`가 `true`인 non-activating(앱을
활성화하지 않는) `NSPanel`은 열리는 순간 키 포커스를 가져오므로, 키보드 탐색과 설정의 단축키
기록기가 첫 입력부터 동작합니다. `App/`이 이 AppKit 계층을 소유하고 그 안에 SwiftUI 뷰를 호스팅하므로,
UI 대부분은 순수 SwiftUI로 유지할 수 있습니다.

## 플랫폼 지원

OpenUsage는 macOS 15 (Sequoia) 이상에서 실행됩니다. 최신 SDK로 빌드하고 하위 배포합니다.
macOS 26 (Tahoe)에서는 시스템의 Liquid Glass 컨트롤을 사용하고, macOS 15에서는 동일한 동작을 하는
표준 컨트롤로 대체합니다(푸터는 여전히 고정되고 버튼 상태도 유지됩니다). 이러한 버전 검사는 모두
`Support/LiquidGlassFallbacks.swift`라는 단일 파일에 모여 있어 뷰에는 `#available` 검사가 없습니다.

릴리스 빌드(`script/release.sh`)는 유니버설 바이너리(arm64 + x86_64)를 제공하므로, DMG 하나로
Apple Silicon과 Intel Mac 모두에서 네이티브로 실행됩니다. 개발 빌드(`script/build_and_run.sh`)는
호스트 아키텍처 전용으로 유지합니다. 유니버설 개발 빌드는 이점 없이 메인테이너의 Mac에서 컴파일
시간만 두 배로 늘리기 때문입니다.

## 로컬 HTTP API

작은 루프백 서버가 `127.0.0.1:6736`에서 현재 사용량을 JSON으로 노출해 다른 로컬 도구가 사용할 수
있게 합니다. 엔드포인트와 개인정보 보호상의 절충점은 [로컬 HTTP API](local-http-api.md)를 참조하세요.
