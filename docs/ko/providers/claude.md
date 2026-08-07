# Claude

Claude Code 또는 Claude Desktop의 기존 로그인을 사용해 Claude 구독 한도를 보여 줍니다.

## 추적 항목

| 지표 | 의미 |
|---|---|
| Session | 5시간 순환 기간의 사용량 |
| Weekly | 7일 기간의 사용량 |
| Sonnet | 별도의 주간 Sonnet 한도(요금제에 따라 다름) |
| Fable | 별도의 주간 Fable 한도(`limits` 배열의 모델 범위 기간) |
| Extra Usage | 월간 상한에 대해 사용한 추가 사용량 크레딧 |
| Today / Yesterday / Last 30 Days | 로컬 지출 — 비용, 토큰 또는 둘 다(아래 참조) |

Claude가 요금제 이름을 보고하면 OpenUsage가 프로바이더 이름 옆에 표시합니다.

## 인증 정보 출처

Claude Code 또는 Claude Desktop으로 로그인하세요. OpenUsage는 기존 로그인을 읽습니다. 구독 사용량을 읽을 수 있는 소스를 우선하여 다음 소스들을 확인합니다:

1. Claude Code가 관리하는 macOS 키체인 항목(macOS에서의 기준 저장소)
2. `~/.claude/.credentials.json`(또는 `$CLAUDE_CONFIG_DIR/.credentials.json`)
3. 동작하는 Claude Code 로그인이 없을 때 Claude Desktop의 암호화된 로그인 캐시
4. `CLAUDE_CODE_OAUTH_TOKEN` 환경 변수

[**Settings → Accounts**(설정 → 계정)](/docs/ko/settings.md)에 관리형 계정이 등록되어 있거나 자동 탐색된 추가 계정 카드가 있으면 Desktop fallback은 사용하지 않습니다.
그 로그인은 다른 계정의 것일 수 있으므로 인증 실패는 재로그인 안내로 표시됩니다.

Claude Desktop 지원은 읽기 전용입니다. OpenUsage는 macOS 키체인의
`Claude Safe Storage` 항목을 사용해 현재 유효한 액세스 토큰만 복호화합니다. Desktop의 갱신 토큰은 절대 읽거나 사용하지 않으며,
Desktop의 설정, 쿠키, 키체인 항목도 절대 변경하지 않습니다. 이를 통해 OpenUsage가
Claude Desktop의 세션을 무효화하는 일을 방지합니다.

macOS는 OpenUsage가 해당 키체인 항목에 접근하기 전에 한 번 묻습니다. 백그라운드 새로 고침에서는
암호 입력 창이 열리지 않습니다. 먼저 수동 새로 고침을 요청하고, 이때 **Always Allow**(항상 허용)를
선택하면 이후 새로 고침은 조용히 진행됩니다. Desktop의 단기 토큰이 만료되면 Claude Desktop을
열어 로그인을 갱신한 뒤 OpenUsage를 새로 고치세요.

`CLAUDE_CODE_OAUTH_TOKEN`(보통 수명이 긴 `claude setup-token`)은 모델을 실행할 수는 있지만 Session과
Weekly 한도를 읽을 수 없고 셸 환경에 남아 있는 경우도 많습니다. 실제 키체인 또는 파일 로그인이
있으면 OpenUsage는 실시간 미터에 그 로그인을 사용하고 환경 토큰은 보조 수단으로만 사용합니다.
따라서 환경 토큰이 설정되어 있다는 이유만으로 Session/Weekly 미터가 비어 있지 않습니다. 환경 토큰이
*유일한* 인증 정보인 무인 환경에서는 그 토큰만 사용하며, 지출 타일은 계속 로컬 로그에서 읽습니다.

한 소스의 토큰이 만료되었거나 "잠긴" 상태면 OpenUsage는 다음 소스를 시도합니다. 따라서 앱 밖에서
`claude`로 다시 로그인해도 OpenUsage를 재시작하지 않고 다음 새로 고침에서 반영합니다. Claude Code
토큰은 자동으로 갱신합니다. 교체된 토큰은 새로 고침을 시작할 때의 로그인 후보가 여전히 같은 경우에만
다시 기록하므로, 새로 추가된 우선순위 높은 로그인이 우선됩니다. Claude Desktop 토큰은 OpenUsage가
갱신하거나 다시 기록하지 않습니다.

## 지출 타일

Today / Yesterday / Last 30 Days는 **로컬에서** 계산됩니다: OpenUsage가 `~/.claude/projects/`(또는 `$CLAUDE_CONFIG_DIR`) 아래의 Claude Code 세션 로그를 직접 읽습니다 — 외부 도구가 필요 없습니다. 심볼릭 링크를 따라가므로 동기화 위치(예: Dropbox 폴더)로 링크된 projects 폴더도 똑같이 읽습니다. [pi](https://github.com/earendil-works/pi) 코딩 에이전트를 통한 Claude 사용량도 집계됩니다: OpenUsage는 `~/.pi/agent/sessions/`(또는 `$PI_CODING_AGENT_SESSION_DIR`) 아래의 pi 세션 로그를 읽어 그곳의 Claude 사용량을 같은 타일과 추세에 합산하므로, pi를 통해 구동된 Claude 구독도 여기에 표시됩니다. pi는 메시지별 비용을 스스로 기록하므로, 그 달러 금액은 재추정되지 않고 pi에서 그대로 가져옵니다. Cowork(Claude 데스크톱 앱의 에이전트 모드)도 집계됩니다: Cowork는 `~/Library/Application Support/Claude/local-agent-mode-sessions/` 아래의 세션별 폴더에 같은 로그를 기록하며, OpenUsage는 이들도 스캔하므로 데스크톱 에이전트 세션이 터미널 세션과 나란히 타일에 표시됩니다. 세션이 저장되는 `claude -p` 실행도 집계됩니다. `--no-session-persistence`로 실행된 것은 Claude가 의도적으로 OpenUsage가 읽을 세션 로그를 남기지 않으므로 나타날 수 없습니다. 메시지 안에 기록된 Advisor 작업은 Advisor 자체 모델 아래 한 번만 집계되고, 부모의 메인 모델 합계는 별도로 유지되며, 일반적인 반복 세부 사항은 다시 집계되지 않습니다. 로그에 기록된 fast 또는 standard 속도가 가격을 결정하며, OpenUsage는 이벤트 날짜로 속도를 추론하지 않습니다. 날짜는 Mac의 로컬 시간대로 묶이므로 사용자의 달력과 일치합니다. 각 기간은 비용과 토큰을 함께 보여 주는 하나의 타일(`$4.08 · 1.2M tokens`)이며, 사용량이 없는 날은 오해를 부를 `$0.00 · 0 tokens` 대신 **No data**(데이터 없음)로 표시됩니다 — 지출을 추적하는 다른 모든 프로바이더와 동일합니다. 실시간 Session 및 Weekly 미터에는 영향이 없습니다. 달러 금액은 공유 [모델 가격](../pricing.md)을 사용해 토큰 수에서 API 요율로 추정되며(이것이 ⓘ의 의미), 토큰 수 자체는 측정된 값입니다. 로그 데이터는 Mac 밖으로 나가지 않습니다.

자동 탐색된 config-dir Claude 카드가 있으면 pi 로그는 어느 Claude 로그인이 만든 것인지 알 수 없으므로 pi 항목을 생략합니다.
이렇게 하면 공유 로그를 잘못된 계정에 배정하지 않습니다.
관리형 계정만 있을 때는 공유 홈의 다른 로그처럼 pi 사용량도 공유 family 카드의 타일에 계속 합산됩니다.

## 자동 탐색된 설정 디렉터리 계정

커스텀 설정 디렉터리(각각 자체 로그인을 가진 별도의 `CLAUDE_CONFIG_DIR`
홈)를 사용해 이 Mac에 Claude 로그인을 두 개 이상 유지하는 경우, OpenUsage는 시작 시 이들을 찾아 각 **계정**에 자체
카드를 부여하며, 그 홈에서 읽은 자체 한도, 요금제, 지출 타일을 갖습니다. 메인 로그인과 같은
계정으로 로그인된 커스텀 디렉터리는 두 번째 카드가 되지 않습니다 — 그 세션 로그는 메인
카드의 지출 타일에 합산될 뿐입니다.

추가 카드는 계정 이름으로 명명됩니다("Claude — Acme Corp").
카드를 우클릭해 **Rename…**(이름 변경)을 선택하거나 Customize의 Name 필드를 사용해 원하는 이름을 지을 수 있습니다.
카드는 해당 로그인이 이 Mac에서 계속 발견되는 동안에만 표시됩니다.
로그아웃하거나 디렉터리를 삭제하면 카드가 사라지지만 다시 돌아올 경우를 대비해 커스터마이징과 기록은 유지됩니다.
Customize에는 Claude가 한 번만 표시됩니다.
켜기/끄기는 자동 탐색 카드 하나를 개별적으로 끄는 대신 모든 Claude 계정 카드에 함께 적용됩니다.

[CLI](../cli.md)와 [로컬 API](../local-http-api.md)에서 추가 카드는
`claude@ab12cd34` 같은 id로 나타나며, `claude`를 요청하면 모든 Claude 카드가 반환됩니다.

## 관리형 계정 전환

**Settings → Accounts**(설정 → 계정)는 이름이 지정된 Claude 계정을 관리합니다.
첫 계정은 새 로그인 없이 현재 로그인을 그대로 가져옵니다.
추가 계정은 앱 소유 작업 공간 안에서 공식 로그인 절차로 로그인하므로 활성 로그인은 방해받지 않습니다.
전환은 공유 Claude 설정 디렉터리(`~/.claude`)를 유지한 채 인증 정보만 교체합니다.
Claude 상태 파일의 credential과 계정 identity는 바뀌지만 MCP 설정·메모리·세션·온보딩은 새 Claude Code 세션에서도 그대로 사용할 수 있습니다.
각 계정의 인증 스냅샷은 macOS Keychain에 보관됩니다.
비활성 계정의 사용량 카드는 그 스냅샷을 읽습니다.
비활성 계정 카드는 [로컬 API](/docs/ko/local-http-api.md)에서 `claude@profile-…` 같은 id로 나타납니다.
대시보드의 계정 선택은 어느 계정의 사용량을 표시할지만 바꾸며 새 Claude 세션이 사용할 계정은 바꾸지 않습니다.
로컬 지출과 추세 로그는 공유 설정 홈에 남고 관리형 계정에 귀속되지 않습니다.
따라서 대시보드가 비활성 스냅샷 계정을 보여 줄 때 이 행들은 **No data**로 표시될 수 있습니다.
계정을 추가·이름 변경·재로그인·제거하면 대시보드가 즉시 갱신됩니다.
선택기에는 Settings에 등록된 계정만 나옵니다.
독립적으로 자동 탐색된 커스텀 설정 디렉터리 계정은 기존 카드를 유지합니다.
등록 계정과 같은 identity임이 확인될 때만 중복 없이 한 번 표시됩니다.

## 문제 해결

- **"Not logged in"** — 관리형 계정은 **Settings → Accounts → Manage… → Sign In Again**을 사용하세요.
  그 외에는 `claude`를 실행해 로그인한 다음 새로 고침하세요.
- **"Claude Desktop login found"** — 수동으로 새로 고침하고 macOS가 `Claude Safe Storage` 접근을 요청할 때 **Always Allow**를 선택하세요.
- **"Claude Desktop login is stale"** — Claude Desktop을 열어 로그인을 갱신하게 한 다음 OpenUsage를 새로 고침하세요.
- **"Re-login for live usage"**(Claude 헤더의 황색 경고) — 저장된 로그인은 추론 인증은 가능하지만 `user:profile` 접근 권한이 없어 구독 한도를 읽을 수 없습니다(`claude setup-token`에서 나온 추론 전용 토큰이 가진 것이 바로 이것입니다). `claude`를 실행해 Claude 계정으로 다시 로그인한 다음 새로 고침하세요. 그동안 지출 타일은 계속 동작합니다.
- **"Updates blocked by Anthropic"**(Claude 헤더의 황색 경고) — 사용량 API가 OpenUsage를 스로틀링하고 있습니다. OpenUsage는 같은 로그인의 마지막 값을 유지하고, 재시도 시각을 보여 주며, 그동안 백오프합니다. 다른 로그인은 새 캐시와 쿨다운으로 시작합니다.
- **지출 타일에 "No data"가 표시됨** — OpenUsage가 지난 30일 동안의 Claude Code 로그를 찾지 못했습니다.
  관리형 계정 전환을 사용하지 않는 경우 로그가 커스텀 위치에 있다면 `CLAUDE_CONFIG_DIR`을 설정해 Claude Code와 OpenUsage가 같은 곳을 보게 하세요.
  관리형 터미널 전환은 공유 `~/.claude` 홈을 사용합니다.
  독립적으로 자동 탐색된 커스텀 홈은 자체 카드를 유지합니다.

## 내부 동작

선택된 OAuth 토큰으로 `GET https://api.anthropic.com/api/oauth/usage`를 호출합니다. Claude Code 토큰은 `platform.claude.com/v1/oauth/token`을 통해 갱신됩니다. Claude Desktop 토큰은 읽기 전용이며 Desktop 자체가 갱신해야 합니다. 토큰이 만료되거나 폐기된 경우 OpenUsage는 오류를 보고하기 전에 다음 인증 정보 소스로 재시도합니다.

5시간 세션 기간에 아직 사용량이 없으면 Session 행의 후행 레이블에 **Not started**가 표시됩니다. 마우스를 올리면 첫 메시지 이후에 세션이 시작된다는 설명이 나타납니다.
