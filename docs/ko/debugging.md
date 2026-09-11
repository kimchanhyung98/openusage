# 디버깅 및 로그 캡처

로컬 빌드를 실행해 앱의 동작을 관찰하는 방법 — 프로바이더가 오작동할 때나 시작·새로 고침 문제를 추적할 때 유용.

## 로컬 빌드 실행

빌드/실행 루프는 프로젝트 스크립트가 담당.
리포지토리 루트에서:

```sh
./script/build_and_run.sh          # dist/의 개발 앱을 빌드하고 실행
./script/build_and_run.sh build    # 빌드·스테이징만, 실행은 하지 않음
./script/build_and_run.sh verify   # 실행 후 프로세스가 살아 있는지 확인
```

스크립트는 `dist/` 아래에 서명된 앱 번들을 빌드해 그 자리에서 실행 — `/Applications`에는 아무것도 설치하지 않음.
개발 빌드는 자체 번들 ID(`com.kimchanhyung98.openusage.dev`)를 쓰므로 설정과 키체인도 따로 유지하며, 릴리스된 OpenUsage를 건드리지 않음.
업데이트 피드가 없어 업데이트를 확인하지도 않으므로, 업데이트는 실제로 서명·공증된 릴리스 빌드로 테스트.
개발 분석은 기본값 꺼짐이며 내장 운영 프로젝트 토큰 무시.
개발 분석 설정에는 명시적인 `OPENUSAGE_POSTHOG_TOKEN` override만 사용 가능; 별도 테스트 프로젝트 사용.

## 로그 스트리밍

문제를 재현하면서 앱 로그를 실시간으로 보려면:

```sh
./script/build_and_run.sh logs
```

개발 앱을 실행한 뒤 통합 로그를 스트리밍.
내부적으로는 시스템 로그를 앱 프로세스로 필터링하며, 다음과 동일:

```sh
log stream --info --style compact --predicate 'process == "OpenUsage"'
```

실시간이 아니라 *사후에* 로그를 읽으려면 시간 범위를 지정해 `log show` 사용:

```sh
log show --last 10m --info --predicate 'process == "OpenUsage"'
```

## 로그 파일

위의 통합 로그와 별개로, 앱은 `~/Library/Logs/OpenUsage/OpenUsage.log`에 파일 로그를 기록 — 지원 리포트에 첨부할 파일.
용량은 ~10MB로 제한되고 `.1` 아카이브 하나를 유지.
**Settings -> Advanced -> Log Level**(설정 -> 고급 -> 로그 레벨)에서 상세 수준을 올린 뒤(전체 상세 정보는 **Debug**), 같은 섹션의 **Copy Log Path**(로그 경로 복사)나 **Reveal in Finder**(Finder에서 보기)로 파일을 가져오기.
레벨, 서브시스템 태그, 비밀 값 미기록 보장은 [로깅](logging.md) 참조.

## 계정 로그 라인

실행 시 계정 확인 과정(Claude/Codex 기본 홈에 어떤 계정이 로그인돼 있는지)은 로그 파일에 짧은 흔적을 남김:

- `accounts: claude default identity resolved (claude@<hash>)` — 기본 로그인의 계정이 확인된 경우.
  해시는 계정 ID에서 파생되므로, 같은 계정의 두 실행은 항상 일치.
- `accounts: codex default identity unresolved — …` — 로그인은 있지만 이번 실행에서 계정을 확실히 특정할 수 없는 경우(계정 ID가 없는 인증 파일, 또는 실행 시 비밀 값을 읽지 않는 키체인 인증 정보).
  카드는 이전과 똑같이 동작하며, 아직 계정 인식 기능에만 참여하지 못하는 상태.
- `stale account cache discarded for claude` — 실행 사이에 기본 홈의 계정이 바뀌어, 새 로그인 아래에 이전 계정의 캐시 스냅샷을 그리는 대신 폐기한 경우.
- `account identity read skipped for claude, codex: login shell cold and no shell-environment snapshot exists yet` — 첫 실행이 느린 로그인 셸과 경합해 해당 패밀리를 이번 실행에서 읽지 않고 넘긴 경우로, 이후 실행에는 폴백할 영속 스냅샷이 존재.

## 로컬 Telemetry 검증

회귀 테스트는 가짜 인증 정보·격리된 SDK 요청·임시 파일 사용:

```sh
CFFIXED_USER_HOME=/tmp/openusage-telemetry-tests OPENUSAGE_POSTHOG_TOKEN=phc_REPLACE_ME swift test --filter 'Telemetry|LogFile|WidgetDataStoreNotification|CodexResetClaimRouter'
```

최종 SDK payload 마스킹·공유 OFF 이후 대기 이벤트·재시작·집계 날짜 및 버전·로그 동시 기록·계정 전환 검증 포함.
`telemetry event submitted to SDK`는 로컬 제출 의미; 별도 HTTP 응답 로그로 전송 시도와 거부 구분.
두 메시지 모두 운영 대시보드 표시의 증거는 아님.

네이티브 크래시 수집에는 PostHog 프로젝트의 exception autocapture와 디버거가 연결되지 않은 앱 필요.
네이티브 크래시 핸들러 확인 시 동의 변경 후 재시작.
폐기 가능한 테스트 앱·테스트 프로젝트에서 크래시 수집·재실행 전송·심볼 해석 검증.
릴리스 스크립트는 dSYM에 앱 번들 ID·버전·빌드를 기록하며 workflow는 고정 버전의 PostHog CLI로 업로드.
dSYM 생성·업로드 성공만으로 심볼 해석을 보장하지 않음.

## 팁

- **프로바이더에 오류가 표시됨.**
  `logs`를 켠 상태로 재현한 뒤, `docs/providers/`의 해당 프로바이더 페이지에서 오류 상태의 의미와 인증 정보 출처를 확인.
- **아무것도 갱신되지 않음.**
  새로 고침은 타이머로 돌고 캐시를 존중 — 네트워크 호출이 실제로 언제 일어나는지는 [새로 고침 및 캐싱](refreshing.md) 참조.
  강제로 새로 고치려면 행의 컨텍스트 메뉴에서 프로바이더별 "Refresh"(새로 고침) 사용.
- **리빌드마다 권한/키체인 프롬프트가 뜸.**
  스크립트는 권한 ACL이 유지되도록 안정적인 Apple Development 신원으로 서명.
  프롬프트가 반복되면 키체인에 그런 신원이 있는지 확인(애드혹 서명으로 넘어가면 스크립트가 경고).
- **로컬 API 확인.**
  앱이 실행 중일 때 `curl 127.0.0.1:6736/v1/usage`는 UI가 쓰는 것과 동일한 사용량 스냅샷을 보여 주므로, 문제가 가져오기/매핑에 있는지 UI에 있는지 가려내기에 편리.
