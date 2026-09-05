# Claude

Claude Code 또는 Claude Desktop의 기존 로그인으로 Claude 구독 한도 추적.

## 추적 항목

| 지표 | 의미 |
|---|---|
| Session | 5시간 순환 기간 사용량 |
| Weekly | 7일 기간 사용량 |
| Sonnet | 별도 주간 Sonnet 한도(요금제에 따라 다름) |
| Fable | 별도 주간 Fable 한도(`limits` 배열의 모델 범위 기간) |
| Extra Usage | 월간 상한에서 차감된 추가 사용 크레딧 |
| Today / Yesterday / Last 30 Days | 로컬 지출 — 비용, 토큰 또는 둘 다(아래 참조) |

Claude가 요금제 이름을 보고하면 OpenUsage의 프로바이더 이름 옆에 표시.

## 인증 정보 출처

Claude Code 또는 Claude Desktop에 로그인하면 OpenUsage가 기존 로그인 사용.
구독 사용량을 읽을 수 있는 출처를 우선해 다음 순서로 확인.

1. Claude Code가 관리하는 macOS 키체인 항목(macOS의 기준 저장소)
2. `~/.claude/.credentials.json`(또는 `$CLAUDE_CONFIG_DIR/.credentials.json`)
3. 작동하는 Claude Code 로그인이 없을 때 Claude Desktop의 암호화된 로그인 캐시
4. `CLAUDE_CODE_OAUTH_TOKEN` 환경 변수

[**Settings → Accounts**](/docs/ko/settings.md)에 계정이 등록되어 있거나 커스텀 설정 디렉터리에 다른 Claude 로그인이 있으면 Claude Desktop 대체 경로 미사용 — 다른 계정의 로그인일 수 있으므로 인증 실패를 재로그인 안내로 노출.

Claude Desktop 지원은 읽기 전용.
OpenUsage는 macOS 키체인의 `Claude Safe Storage` 항목으로 현재 유효한 액세스 토큰 복호화.
Desktop의 갱신 토큰은 읽거나 사용하지 않으며 Desktop의 설정, 쿠키, 키체인 항목도 변경하지 않음.
이 방식으로 OpenUsage가 Claude Desktop 세션을 무효화하는 문제 방지.

OpenUsage가 해당 키체인 항목에 접근하기 전 macOS의 최초 1회 확인 필요.
백그라운드 새로 고침에서는 암호 대화상자를 열지 않음: 먼저 수동 새로 고침을 요청하며, **Always Allow** 선택 시 이후 새로 고침은 추가 확인 없이 진행.
Desktop의 단기 토큰이 만료되면 Claude Desktop을 열어 로그인을 갱신한 뒤 OpenUsage 새로 고침.

`CLAUDE_CODE_OAUTH_TOKEN`(대개 수명이 긴 `claude setup-token`)은 모델 실행은 가능하지만 Session과 Weekly 한도 조회는 불가능하며 셸 환경에 오래 남는 경우가 많음.
따라서 실제 키체인 또는 파일 로그인이 있으면 실시간 미터에는 해당 로그인을 사용하고 환경 토큰은 대체 수단으로만 유지 — 환경 토큰 설정만으로 Session/Weekly 미터가 비는 문제 방지.
환경 토큰이 *유일한* 인증 정보인 헤드리스 설정에서는 단독 사용하며 지출 타일은 계속 로컬 로그에서 로드.

한 출처의 토큰이 만료되었거나 "잠김" 상태면 다른 출처로 전환 — 앱 밖에서 `claude`로 재로그인한 결과도 OpenUsage 재시작 없이 다음 새로 고침에 반영.
선택된 관리형 Claude 계정에서는 이 감지를 다시 쓰기 경계로도 사용 — 공유 홈 로그인에서 사용 가능한 프로바이더 신원을 검증하면 해당 계정의 저장 스냅샷과 신원을 새 인증 정보로 교체하고 준비 상태 갱신.
신원이 바뀌어도 계정명과 선택 상태는 유지하며, 완료되지 않았거나 검증할 수 없는 인증 정보는 기록하지 않음.
Claude Code 토큰은 자동 갱신하며, 교체된 토큰은 로그인 후보의 순서와 값이 새로 고침 시작 시점과 여전히 일치할 때만 다시 기록하므로 새로 추가된 상위 우선순위 로그인 우선.
Claude Desktop 토큰은 OpenUsage에서 갱신하거나 기록하지 않음.

## 지출 타일

Today / Yesterday / Last 30 Days는 **로컬에서** 계산: OpenUsage가 `~/.claude/projects/`(또는 `$CLAUDE_CONFIG_DIR`) 아래의 Claude Code 세션 로그를 직접 읽으므로 외부 도구 불필요.
심볼릭 링크를 따라가므로 동기화 위치(예: Dropbox 폴더)에 연결된 projects 폴더도 동일하게 읽음.
[pi](https://github.com/earendil-works/pi) 코딩 에이전트의 Claude 사용량도 집계: OpenUsage가 `~/.pi/agent/sessions/`(또는 `$PI_CODING_AGENT_SESSION_DIR`) 아래의 pi 세션 로그를 읽어 그 안의 Claude 사용량을 같은 타일과 추세에 합산하므로 pi를 통해 Claude 구독을 사용한 내역도 여기에 표시.
pi가 자체적으로 기록한 메시지별 비용을 그대로 사용하며 재추정하지 않음.
Cowork(Claude 데스크톱 앱의 에이전트 모드)도 집계: `~/Library/Application Support/Claude/local-agent-mode-sessions/` 아래의 세션별 폴더에 같은 로그를 기록하며, OpenUsage가 함께 스캔하므로 데스크톱 에이전트 세션도 터미널 세션과 함께 타일에 표시.
기록이 남는 `claude -p` 실행도 집계.
`--no-session-persistence` 실행은 Claude가 의도적으로 OpenUsage에서 읽을 세션 로그를 남기지 않으므로 표시 불가.
메시지 안에 기록된 Advisor 작업은 Advisor 자체 모델에서 한 번만 집계하고 부모의 주 모델 합계는 별도 유지하며 일반 반복 세부 정보는 중복 집계하지 않음.
로그에 기록된 fast 또는 standard 속도에 따라 가격 결정, 이벤트 날짜에서 속도를 추론하지 않음.
Mac의 로컬 시간대를 기준으로 날짜를 묶어 사용자의 달력과 일치.
각 기간은 비용과 토큰을 함께 보여 주는 단일 타일(`$4.08 · 1.2M tokens`)이며, 사용량 없는 날은 오해를 부르는 `$0.00 · 0 tokens` 대신 **No data** 표시 — 다른 모든 지출 추적 프로바이더와 같은 방식.
실시간 Session 및 Weekly 미터에는 영향 없음.
달러 금액은 토큰 수에 API 요율과 공유 [모델 가격](/docs/ko/pricing.md)을 적용한 추정치(ⓘ의 의미)이며 토큰 수 자체는 측정값.
로그 데이터는 Mac 밖으로 전송하지 않음.

커스텀 설정 디렉터리에 다른 Claude 로그인이 있으면 pi 로그에서 사용한 Claude 로그인을 식별할 수 없으므로 pi 항목 제외.
공유 로그가 잘못된 계정에 배정되는 문제 방지.
그 외에는 공유 홈의 다른 로그처럼 pi 사용량도 Claude 카드의 타일에 계속 포함.

## 그 밖의 설정 디렉터리 로그인

OpenUsage는 공유 홈(`~/.claude`)에 로그인된 계정과 **Settings → Accounts**에 등록한 계정만 표시 — 그 외에는 표시하지 않음.
커스텀 설정 디렉터리(별도 `CLAUDE_CONFIG_DIR` 홈)에 있는 Claude 로그인은 카드도, 계정 선택기 항목도 아니며 [CLI](/docs/ko/cli.md)·[로컬 API](/docs/ko/local-http-api.md)에도 없음.
표시하려면 Settings에서 해당 계정 등록.

공유 홈과 같은 계정으로 로그인한 커스텀 디렉터리는 예외 — 이미 화면에 있는 계정의 로그이므로 세션 로그를 그 계정의 지출 타일에 합산.

## 관리형 계정 전환

**Settings → Accounts**에서 이름이 지정된 Claude 계정 관리.
첫 계정은 새 로그인 없이 현재 로그인 가져오기.
추가 계정은 앱 소유 작업 공간 안에서 공식 절차로 로그인하므로 활성 로그인에 영향 없음.
전환 시 공유 Claude 설정 디렉터리(`~/.claude`)는 그대로 두고 인증 정보만 교체.
Claude 상태 파일의 인증 정보와 계정 식별 정보는 바뀌지만 MCP 설정, 메모리, 세션, 온보딩은 새 Claude Code 세션에서도 계속 사용 가능.
각 계정의 인증 스냅샷은 macOS 키체인에 저장.
비활성 계정의 사용량 카드는 해당 스냅샷 사용.
비활성 계정 카드는 [로컬 API](/docs/ko/local-http-api.md)에 `claude@profile-…` 같은 ID로 표시.
대시보드 계정 선택기는 표시할 사용량만 바꾸며 새 Claude 세션에서 사용할 계정은 변경하지 않음.
로컬 지출과 추세 로그는 공유 설정 홈에 남고 관리형 계정에는 귀속하지 않음.
따라서 대시보드에서 비활성 스냅샷 계정을 볼 때 해당 행에 **No data** 표시 가능.
계정 추가, 이름 변경, 재로그인, 제거 시 대시보드 즉시 갱신.
선택기에는 공유 홈의 계정과 Settings에 등록한 계정만 표시.
등록 계정명은 두 계정이 현재 같은 프로바이더 신원을 증명해도 선택기에서 각각 유지.

일반 터미널을 선택된 관리형 계정의 공식 재인증 경로로 지원.
새 터미널에서 `claude`를 실행해 `/login`을 사용하거나 `claude auth login`을 실행한 뒤, Settings에서 선택한 계정명에 저장할 유효한 Claude 로그인 완료.
OpenUsage가 공유 `~/.claude` 로그인을 검증하고 해당 계정명의 비공개 Keychain 스냅샷과 저장 프로바이더 신원을 교체 — **Sign In Again**이나 앱 재실행 불필요.
다른 프로바이더 신원으로 로그인해도 계정명을 바꾸거나 다른 관리형 계정을 조용히 선택하지 않음.

## 서비스 상태

Claude가 활성화돼 있으면 실행 시, 5분마다, 대시보드 수동 새로 고침 시 [Claude Status](https://status.claude.com/)의 Claude API와 Claude Code 컴포넌트 확인.
공개 요청은 인증 없이 실행되며 Claude 인증 정보나 사용량 데이터를 보내지 않음.
두 컴포넌트 중 하나가 성능 저하, 부분 장애, 중대 장애를 보고하면 서버 해골 표시; 예약된 유지보수와 알 수 없는 결과에는 미표시.

## 문제 해결

- **"Not logged in"** — 선택된 관리형 계정은 새 터미널에서 `claude`를 실행해 `/login`을 사용하거나 `claude auth login`을 실행한 뒤 해당 계정명에 저장할 로그인을 완료하고 OpenUsage 새로 고침.
  `claude auth status`에서 `loggedIn: true`가 나오고 공유 Claude 홈이 일관된 신원 하나로 해석될 때만 OpenUsage가 관리형 스냅샷을 자동 갱신.
  상태 파일이 서로 다른 계정을 가리키거나, 파싱할 수 없거나, 새 Keychain 인증 정보보다 오래되고 기존 인증 정보 체인에도 속하지 않으면 기존 스냅샷 보존.
  **Settings → Accounts → Manage… → Sign In Again**은 대체 복구 경로로 유지.
- **"Claude Desktop login found"** — 수동으로 새로 고침하고 macOS에서 `Claude Safe Storage` 접근을 요청할 때 **Always Allow** 선택.
- **"Claude Desktop login is stale"** — Claude Desktop을 열어 로그인을 갱신한 뒤 OpenUsage 새로 고침.
- **"Re-login for live usage"**(Claude 헤더의 황색 경고) — 저장된 로그인은 추론 인증이 가능하지만 `user:profile` 접근 권한이 없어 구독 한도 조회 불가(`claude setup-token`에서 발급한 추론 전용 토큰의 동작).
  `claude`를 실행해 Claude 계정으로 재로그인한 뒤 새로 고침; 그동안 지출 타일은 계속 동작.
- **"Updates blocked by Anthropic"**(Claude 헤더의 황색 경고) — 사용량 API가 OpenUsage를 제한하는 상태.
  같은 로그인의 마지막 값을 유지하고 재시도 시각을 표시하며 그동안 재시도 간격을 늘림.
  다른 로그인은 새 캐시와 쿨다운으로 시작.
- **지출 타일에 "No data" 표시** — 지난 30일간 Claude Code 로그를 찾지 못한 상태.
  관리형 계정 전환 외의 경우 로그가 커스텀 위치에 있으면 `CLAUDE_CONFIG_DIR`을 설정해 Claude Code와 OpenUsage가 같은 위치 사용.
  관리형 터미널 전환은 공유 `~/.claude` 홈 사용.
  다른 커스텀 홈에 둔 로그인은 Settings에 등록하기 전까지 아예 표시하지 않음.

## 내부 동작

선택한 OAuth 토큰으로 `GET https://api.anthropic.com/api/oauth/usage` 호출.
Claude Code 토큰은 `platform.claude.com/v1/oauth/token`에서 갱신하고, Claude Desktop 토큰은 읽기 전용이므로 Desktop 자체에서 갱신 필요.
토큰이 만료되거나 폐기되면 오류 보고 전 다음 인증 정보 출처로 재시도.

5시간 세션 기간에 아직 사용량이 없으면 Session 행의 후행 레이블에 **Not started** 표시; 마우스를 올리면 첫 메시지 후 세션이 시작된다는 설명 제공.
