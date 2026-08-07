# 명령줄 인터페이스

OpenUsage는 에이전트와 스크립트에서 사용할 수 있는 1회 실행 명령 `openusage`를 제공합니다.
문서에 정의된 [`/v1/limits`](local-http-api.md#get-v1limits) JSON을 출력한 뒤 종료하며,
메뉴 막대 앱을 실행하지도, 프로세스를 남겨 두지도 않습니다. 출력에는 UI 행이나 색상,
부제목, 차트, 지출 내역 타일이 아니라 안정적인 스칼라 한도와 잔액이 담깁니다.

```sh
openusage                 # every enabled provider, refreshing stale cache entries
openusage codex           # one provider, refreshing when its cache is stale
openusage codex --force   # refresh through the shared provider engine, cache, print, exit
```

이 명령과 앱은 같은 프로바이더, 인증 스토어, 가격 정보, 새로 고침 코디네이터,
스냅샷 캐시를 공유합니다. 일반 조회는 5분 이내에 만들어진 스냅샷을 재사용하고,
없거나 오래된 스냅샷만 새로 고칩니다. `--force`는 앱에서 수동 새로 고침을 하는 것과
같은 동작으로, 캐시 유효성 검사를 건너뛰고 성공한 결과를 같은 캐시에 기록합니다.
인증 정보는 로컬에서만 사용되며 출력에 절대 표시되지 않습니다.

프로바이더 인자는 [로컬 HTTP API](local-http-api.md)와 마찬가지로 단순한 문자열
일치로 해석됩니다. 정확한 프로바이더 ID는 해당 프로바이더 하나를 가리키고,
패밀리 ID(`claude`, `codex`)는 해당 패밀리에 속한 모든 계정 카드를 가리킵니다. 계정이
하나뿐이면 그 카드 하나가 전부이므로, 멀티 계정 지원이 추가되어도 기존 사용 방식은
그대로 유지됩니다. 예외가 하나 있습니다: 관리형 비활성 계정의 읽기 전용 snapshot 카드는
credential이 앱이 만든 Keychain 항목에 있어 원샷 CLI가 접근하지 않는 앱 전용 카드입니다.
따라서 CLI의 패밀리 매칭은 디스크 로그인이 있는 카드만 다루며, 앱의 로컬 API는 snapshot
카드도 제공합니다. 응답 객체에는 일치한 모든 프로바이더가 들어갑니다. 어떤 프로바이더도
가리키지 않는 ID를 사용하면 오류로 종료됩니다. 별칭이나 계정 선택 로직은 없습니다.

## `PATH`에 설치

OpenUsage에서 **Settings → Command Line**(설정 → 명령줄)을 열고 **Install…**(설치…)을
클릭합니다. 표준 macOS 관리자 프롬프트를 거치면 새 터미널 세션에서 `openusage`를
전역에서 사용할 수 있습니다. 설치된 심볼릭 링크는 OpenUsage 안에 있는 서명된 헬퍼를
가리키므로, 앱이 제자리에서 업데이트되면 명령도 함께 업데이트됩니다.

종료 코드는 성공 시 `0`, 잘못된 인자나 알 수 없는 프로바이더일 때 `2`, 새로 고침이나
로컬 읽기에 실패하면 `4`입니다.

## 계정

계정 관리는 앱의 [**Settings → Accounts**(설정 → 계정)](/docs/ko/settings.md)에 있습니다.
CLI는 같은 레지스트리를 읽기만 하므로 스크립트에서 GUI와 정확히 같은 상태를 볼 수 있습니다:

```sh
openusage account list [claude|codex] [--json]   # 등록된 계정; *는 선택된 계정 표시
openusage account current [claude|codex]         # 선택된 계정의 이름(스크립트용)
```

`current`에 도구를 생략하면 두 도구를 모두 출력합니다.
도구를 지정하면 계정 이름만 출력하고 선택된 계정이 없으면 아무것도 출력하지 않습니다.
종료 코드는 성공 시 `0`, 사용법 오류는 `2`, 저장된 계정 레지스트리를 읽거나 검증할 수 없는 경우에는 `4`입니다.
이때 CLI는 빈 계정 목록 대신 오류를 출력합니다.

계정에는 사용자에게 보이는 폴더도, 실행 명령도 없습니다.
전환은 공유 설정 홈의 인증 정보를 교체하므로 새 터미널에서 일반 `claude` 또는 `codex`를 실행하면 선택된 계정으로 동작합니다.
`openusage` 명령 설치 여부와는 무관합니다.

설정에서 계정을 전환하면 먼저 확인 팝업을 표시합니다.
승인하면 OpenUsage가 공유 설정 홈의 인증 정보를 교체하고 감지된 로그인 셸의 시작 파일에 작은 `claude`/`codex` 함수를 설치하거나 갱신합니다.
지원하는 시작 파일은 `~/.zshrc`와 `~/.config/fish/config.fish`입니다.
다른 로그인 셸은 지원하지 않으며 전환은 오류로 중단됩니다.
함수는 공유 설정 홈을 `~/.claude` 또는 `~/.codex`로 고정하고 실제 `claude` 또는 `codex`를 직접 실행합니다.
Claude에서는 `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`, `CLAUDE_CODE_OAUTH_REFRESH_TOKEN`, `CLAUDE_CODE_OAUTH_SCOPES`를 제거합니다.
Codex에서는 `OPENAI_API_KEY`, `CODEX_API_KEY`, `CODEX_ACCESS_TOKEN`을 제거하고 파일 credential 저장소를 유지합니다.
함수 자체는 선택된 계정을 읽지 않습니다.
전환은 공유 홈의 인증 정보를 교체하는 방식으로 구현됩니다.
처음 설정한 뒤에는 새 터미널을 열거나 이미 열린 터미널에서 셸 시작 파일을 다시 읽으세요.
