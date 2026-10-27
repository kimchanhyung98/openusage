# 디버깅 및 로그 캡처

로컬 빌드를 실행해 프로바이더 오류나 앱 시작·새로 고침 문제를 확인하는 방법.

## 로컬 빌드 실행

아래 명령은 모두 빌드 전에 실행 중인 `OpenUsage` 프로세스 종료.
프로세스 이름을 기준으로 종료하므로 릴리스 앱도 종료 대상.
리포지토리 루트에서 필요한 명령 하나 실행:

```sh
./script/build_and_run.sh          # dist/의 개발 앱을 빌드하고 실행
./script/build_and_run.sh build    # 빌드·스테이징만, 실행은 하지 않음
./script/build_and_run.sh verify   # 실행 후 프로세스가 살아 있는지 확인
```

스크립트는 서명된 앱 번들을 `dist/`에 생성.
실행 모드에서는 해당 번들을 실행하며 `/Applications`의 앱 번들은 교체하지 않음.
기본 개발 번들 ID는 `com.kimchanhyung98.openusage.dev`.
번들 ID에 속한 앱 설정은 릴리스 빌드와 분리.
프로바이더 인증 파일·공용 Keychain 항목·로그 파일은 릴리스 빌드와 공유할 수 있으므로 별도 테스트 계정 환경으로 간주하면 안 됨.
개발 앱에는 업데이트 피드가 없으므로 업데이트 확인을 실행하지 않음.
업데이트 동작은 서명·공증된 릴리스 빌드로 테스트.
개발 빌드의 익명 분석 기본값은 꺼짐이며 내장 운영 프로젝트 토큰은 무시.
개발 분석을 검증할 때는 별도 테스트 프로젝트의 토큰을 `OPENUSAGE_POSTHOG_TOKEN`으로 지정.

## Worktree 검사

pre-commit 훅은 `make check` 실행 전에 Git의 저장소별 환경 변수 제거.
연결된 작업 트리에서 커밋할 때도 SwiftPM이 각 의존성의 저장소를 올바르게 검사하도록 처리.
검사 실패 시 커밋 차단 유지.

## 로그 스트리밍

개발 앱을 다시 빌드·실행하고 Info 수준까지 로그를 수집하려면 다음 명령 실행:

```sh
./script/build_and_run.sh logs
```

이미 실행 중인 앱에서 로그만 수집하려면 다음 명령 실행:

```sh
log stream --info --style compact --predicate 'process == "OpenUsage"'
```

Debug 로그가 필요하면 먼저 **Settings → Advanced → Log Level**에서 **Debug** 선택.
그다음 Debug 이벤트를 포함하는 명령 실행:

```sh
log stream --level debug --style compact --predicate 'process == "OpenUsage"'
```

최근 10분의 저장된 로그를 확인하려면 다음 명령 실행:

```sh
log show --last 10m --info --debug --predicate 'process == "OpenUsage"'
```

앱에서 기록을 꺼 둔 레벨은 위 명령으로 복구할 수 없음.

## 로그 파일

앱은 통합 로그와 별도로 `~/Library/Logs/OpenUsage/OpenUsage.log`에 파일 로그 기록.
일반적으로 파일당 약 10 MB를 유지하며 `OpenUsage.1.log` 아카이브 하나 보관.
지원 요청에 로그를 첨부하려면 다음 순서로 수집:

1. **Settings → Advanced → Log Level**에서 필요한 상세 수준 선택.
2. 추가 상세 정보가 필요하면 **Debug** 선택 후 문제 재현.
3. 같은 섹션의 **Copy Log Path**로 경로 복사 또는 **Reveal in Finder**로 파일 위치 열기.

로그 레벨·태그·마스킹 범위는 [로깅](/docs/logging.md) 참조.

## 계정 로그 라인

앱 시작 시 Claude/Codex 기본 설정 홈의 로그인 계정을 확인하며 다음 로그 기록:

- `accounts: claude default identity resolved (claude@<hash>)` — 기본 로그인의 계정이 확인된 경우.
  해시는 계정 식별 정보에서 파생되므로 같은 식별 정보를 사용한 실행끼리 비교 가능.
- `accounts: codex default identity unresolved — …` — 로그인은 있지만 이번 실행에서 계정을 확실히 특정할 수 없는 경우(계정 ID가 없는 인증 파일, 또는 실행 시 비밀 값을 읽지 않는 키체인 인증 정보).
  계정 신원을 확인하지 못했다는 의미이며, 이 로그만으로 사용량 조회 성공 여부를 판단할 수 없음.
- `stale account cache discarded for claude` — 실행 사이에 기본 홈의 계정이 바뀌어, 새 로그인 아래에 이전 계정의 캐시 스냅샷을 그리는 대신 폐기한 경우.
- `account identity read skipped for claude, codex: login shell cold and no shell-environment snapshot exists yet` — 로그인 셸 환경 수집이 끝나지 않았고 이전 환경 스냅샷도 없어 해당 프로바이더 계열의 계정 확인을 건너뛴 경우.
  이후 셸 환경 수집에 성공하면 스냅샷을 저장해 다음 실행에 사용.
  수집에 실패하면 새 스냅샷을 저장하지 않으므로 다음 실행에서도 같은 로그가 나올 수 있음.

## 로컬 진단 이벤트 검증

회귀 테스트는 가짜 인증 정보·격리된 SDK 요청·임시 파일 사용:

```sh
CFFIXED_USER_HOME=/tmp/openusage-telemetry-tests OPENUSAGE_POSTHOG_TOKEN=phc_REPLACE_ME swift test --filter 'Telemetry|LogFile|WidgetDataStoreNotification|CodexResetClaimRouter'
```

검증 범위는 SDK에 전달할 데이터의 마스킹, 공유 중지 이후 대기 이벤트, 재시작, 집계 날짜·버전, 로그 동시 기록, 계정 전환.
`telemetry event submitted to SDK`는 로컬 SDK에 이벤트를 전달했다는 의미.
수집 서버의 응답 여부는 별도 HTTP 로그로 확인.
두 메시지 모두 운영 대시보드 표시의 증거는 아님.

네이티브 크래시 수집에는 PostHog 프로젝트의 `exception autocapture` 설정과 디버거가 연결되지 않은 앱 필요.
크래시 수집 동의를 변경한 뒤 네이티브 크래시 핸들러를 검증하려면 앱 재시작.
폐기 가능한 테스트 앱·테스트 프로젝트에서 크래시 수집·재실행 전송·심볼 해석 검증.
릴리스 스크립트는 dSYM에 앱 번들 ID·버전·빌드 기록.
릴리스 워크플로는 고정 버전의 PostHog CLI로 dSYM 업로드.
dSYM 생성·업로드 성공만으로 심볼 해석을 보장하지 않음.

## Codex Soft Limit 연동 검증

테스트 서버의 요청별 집계는 Node.js로 검증:

```sh
node --test script/fixtures/codex_soft_limit_server.test.mjs
```

실제 연동 검증에는 설치된 Codex CLI, Node.js, macOS의 `/usr/bin/expect` 필요:

```sh
OPENUSAGE_RUN_CODEX_CONTROL_TEST=1 swift test --filter CodexSoftLimitNativeTests
```

임시 `CODEX_HOME`과 로컬 응답 서버를 사용하며, 기존 사용자 세션과 인증 정보는 사용하지 않음.
App Server와 터미널에서 시작한 두 사용자 turn의 `thread_id`·`turn_id`로 응답 연결 추적.
각 turn의 응답이 실제로 시작된 뒤 취소하고, 재시도를 포함한 해당 turn의 모든 연결 종료 확인.
제목 생성 같은 보조 요청은 별도 집계하며, 전체 연결 개수만으로 성공 여부를 판단하지 않음.
취소 후 서버·터미널 생존과 대화 보존도 확인.
이 테스트의 성공은 현재 앱에서 차단된 자동 취소 기능을 활성화한다는 의미가 아님.

## 팁

- **프로바이더에 오류가 표시됨.**
  로그 수집을 시작한 뒤 문제 재현.
  `docs/providers/`의 해당 프로바이더 페이지에서 오류 의미와 인증 정보 출처 확인.
- **아무것도 갱신되지 않음.**
  자동 새로 고침은 주기와 캐시·재시도 대기 조건을 따름.
  수동 조회를 요청하려면 행의 컨텍스트 메뉴에서 **Refresh** 사용.
  수동 조회에서도 유지되는 대기 조건은 [새로 고침 및 캐싱](/docs/refreshing.md) 참조.
- **리빌드마다 권한/키체인 프롬프트가 뜸.**
  스크립트는 사용 가능한 Apple Development 서명 신원을 우선 사용해 재빌드 사이의 권한 유지 지원.
  프롬프트가 반복되면 해당 서명 신원이 있는지 확인.
  사용 가능한 신원이 없으면 애드혹 서명으로 전환하며 스크립트가 경고 출력.
- **로컬 API 확인.**
  앱이 실행 중일 때 `curl 127.0.0.1:6736/v1/usage`로 사용량 스냅샷 조회.
  UI와 같은 데이터 스토어의 결과이므로 수집·매핑 문제와 화면 표시 문제를 구분하는 데 사용 가능.
