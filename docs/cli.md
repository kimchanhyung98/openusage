# 명령줄 인터페이스

OpenUsage는 에이전트와 스크립트용 1회 실행 명령 `openusage`를 제공.
문서에 정의된 [`/v1/limits`](/docs/local-http-api.md#get-v1limits) JSON을 출력한 뒤 종료.
메뉴 막대 앱을 실행하거나 백그라운드 프로세스를 남기지 않음.
출력에는 한도와 잔액 포함.
UI 행, 색상, 부제목, 차트, 지출 내역 타일은 출력 대상에서 제외.
HTTP 라우트와 같은 스키마 사용.
CLI 출력의 `displayName`에는 Claude·Codex 계정명이 포함될 수 있으므로 연동 시 프로바이더 ID로 구분.

```sh
openusage                 # 활성화된 모든 프로바이더, 오래된 캐시 항목만 새로 고침
openusage codex           # 프로바이더 하나, 캐시가 오래됐을 때만 새로 고침
openusage codex --force   # 공유 프로바이더 엔진으로 새로 고침 후 캐시·출력·종료
```

CLI와 앱은 프로바이더 조회·인증·가격 계산·캐시 처리를 공유.
일반 조회는 일반 사용량 5분·Claude 15분 이내의 스냅샷을 재사용하고, 없거나 오래된 것만 새로 고침.
Claude 계정 신원을 확인할 수 없으면 유효 기간 안의 캐시도 재사용하지 않고 새 조회의 확인 실패를 표시.
`--force`는 캐시 유효 기간과 관계없이 새 조회를 요청하고 성공한 결과를 같은 캐시에 기록.
Claude의 계정별 429 대기 상태는 앱과 공유하며 `--force`로도 우회 불가.
앱과 CLI가 같은 Claude 계정·조직의 같은 사용량 API를 동시에 조회하면 파일 잠금으로 요청을 조정하고 완료 결과 공유.
CLI 조회는 Codex 주간 타이머용 메시지를 전송하지 않음.
CLI는 Mac에 저장된 인증 정보로 해당 프로바이더 API를 조회.
토큰과 API 키는 출력 JSON에서 제외.

프로바이더 인자는 [로컬 HTTP API](/docs/local-http-api.md)와 같은 문자열 일치 방식으로 해석.
정확한 프로바이더 ID는 해당 카드 하나를 지정.
패밀리 ID(`claude`, `codex`)는 CLI에서 조회 가능한 해당 프로바이더의 계정 카드 전체를 지정.
비활성 관리형 계정의 인증 스냅샷을 사용하는 카드는 CLI 조회 대상에서 제외.
CLI는 앱이 만든 계정 인증용 Keychain 항목의 존재 여부만 확인하며, 저장된 인증 스냅샷으로 사용량을 조회하지 않음.
앱의 로컬 API에서는 비활성 관리형 계정 카드도 조회 가능.
출력 객체에는 일치한 모든 프로바이더가 담기고, 아무것도 가리키지 않는 ID는 오류로 종료.
별칭이나 계정 선택 로직은 없음.

앱의 Language 선택과 관계없이 CLI의 JSON 필드·지표 ID·단위·오류 원문은 기존 계약 유지.
사용자 계정명은 입력한 원문으로 출력.

## `PATH`에 설치

1. OpenUsage에서 **Settings → Command Line**(설정 → 명령줄) 열기.
2. **Install…**(설치…) 클릭.
3. macOS 관리자 승인 요청 완료.
4. 새 터미널에서 `openusage` 실행.

설치된 심볼릭 링크는 OpenUsage 안의 서명된 헬퍼를 가리키므로, 앱을 제자리 업데이트하면 명령도 함께 갱신.

종료 코드는 성공 `0`, 잘못된 인자나 알 수 없는 프로바이더 `2`, 새로 고침이나 로컬 읽기 실패 `4`.

## 계정

계정 관리는 앱의 [**Settings → Accounts**(설정 → 계정)](/docs/settings.md)에 있음.
CLI는 동일한 등록 계정과 선택된 터미널 계정을 조회:

```sh
openusage account list [claude|codex] [--json]   # 등록된 계정; *는 선택된 계정 표시
openusage account current [claude|codex]         # 선택된 계정의 이름(스크립트용)
```

도구를 생략한 `current`는 두 도구를 모두 출력.
도구를 지정하면 계정 이름만 출력하고, 선택된 계정이 없으면 아무것도 출력하지 않음.
종료 코드는 성공 `0`, 사용법 오류 `2`, 저장된 계정 레지스트리를 읽거나 검증할 수 없을 때 `4`.
이때 CLI는 빈 계정 목록 대신 오류를 출력.
계정 목록은 Settings에 저장한 사용자 지정 표시 순서가 아니라 레지스트리 순서 유지.

계정에는 사용자에게 보이는 폴더도, 실행 명령도 없음.
전환은 공유 설정 홈의 인증 정보를 교체하므로, `openusage` 명령 설치 여부와 무관하게 새 터미널에서 그냥 `claude`나 `codex`를 실행하면 선택된 계정으로 동작.

설정에서 계정을 전환하면 먼저 확인을 요청.
승인하면 OpenUsage가 공유 설정 홈의 인증 정보를 교체하고, 감지된 로그인 셸의 시작 파일에 작은 `claude`/`codex` 함수를 설치하거나 갱신.
지원하는 시작 파일은 `~/.zshrc`와 `~/.config/fish/config.fish`.
다른 로그인 셸은 지원하지 않으며, 전환은 오류로 중단.
이 함수는 공유 설정 홈을 `~/.claude` 또는 `~/.codex`로 고정하고 실제 `claude` 또는 `codex`를 직접 실행.
Claude에서는 `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`, `CLAUDE_CODE_OAUTH_REFRESH_TOKEN`, `CLAUDE_CODE_OAUTH_SCOPES`를 제거.
Codex에서는 `OPENAI_API_KEY`, `CODEX_API_KEY`, `CODEX_ACCESS_TOKEN`을 제거하고 파일 인증 정보 저장소를 유지.
전환 자체가 공유 홈의 인증 정보를 교체하는 방식이므로, 함수는 선택된 계정을 직접 읽지 않음.
처음 설정한 뒤에는 새 터미널을 열거나, 이미 열린 터미널에서 셸 시작 파일을 다시 읽기.

wrapper는 Claude의 공식 인증 명령에도 똑같이 적용.
선택된 관리형 Claude 계정으로 일반 `claude` 세션의 `/login` 또는 `claude auth login`을 실행하면, 결과가 OpenUsage가 관찰하는 같은 공유 홈에 기록.
사용 가능한 프로바이더 신원을 검증한 뒤 OpenUsage가 선택 계정의 Keychain 스냅샷과 저장 신원을 자동 교체 — **Sign In Again**과 앱 재실행 불필요.
새 로그인이 이전과 다른 프로바이더 신원이어도 계정명과 선택 상태는 유지하며, 다른 계정명을 조용히 다시 선택하지 않음.
완료되지 않았거나 신원을 검증할 수 없는 로그인은 기존 스냅샷을 변경하지 않음.
