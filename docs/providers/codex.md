# Codex

Codex CLI 로그인으로 ChatGPT/Codex 구독 한도를 추적하고, Codex 로그인 없이 작동하는 선택적 공개 Reset Watch 예측 제공.

## 추적 항목

| 지표 | 의미 |
|---|---|
| Session | 5시간 순환 기간 사용량 |
| Weekly | 7일 기간 사용량 |
| Spark / Spark Weekly | GPT-5.3-Codex-Spark 모델 한도 — 5시간 기간과 주간 기간.<br>계정에 한도가 있을 때만 표시(없으면 "No data")하며 기본적으로 "show more" 캐럿 아래에 배치 |
| Reset Watch | 확률과 기한으로 표시하는 전역 재설정 예측 — 선택적이며 기본값은 꺼짐(아래 참조) |
| Rate Limit Resets | 온디맨드 속도 제한 재설정 크레딧 — 개수로 표시(예: `2 available`)하고 가장 빠른 만료를 색상 점으로 표시하며, 값에 마우스를 올리면 크레딧별 만료 타임라인 제공 |
| Extra Usage | Flex 크레딧 — 달러 + 크레딧 형식 그대로 표시(예: `$31.84 · 796 credits`) |
| Today / Yesterday / Last 30 Days | 로컬 지출 — 비용, 토큰 또는 둘 다(아래 참조) |

Codex가 요금제 이름을 보고하면 OpenUsage의 프로바이더 이름 옆에 표시.

## Reset Watch

Reset Watch는 [codex-resets.com 공개 예측](https://codex-resets.com/)과 해당 [API](https://codex-resets.com/api/docs)를 기반으로 하는 선택적 예측 지표.
전역·비공식 AI 예측이며 OpenAI의 약속이나 보장이 아님.
AI 확률은 같은 활성 watch에 대한 커뮤니티 투표율(전체 응답 중 **Yes** 비율)과 별개로 유지.
어느 수치도 OpenAI의 보장이 아님.

신규 설치와 레이아웃 초기화 시 꺼짐, **On Demand** 배치, 메뉴 막대 별표 없음.
지표 순서는 Rate Limit Resets 바로 앞이며 Customize에서 켜기·이동·별표 가능.

Reset Watch는 Codex 로그인·인증 및 구독 사용량 새로 고침과 독립적으로 작동.
Codex 프로바이더가 켜져 있고 지표가 대시보드에 표시되거나 메뉴 막대에 별표된 동안, OpenUsage가 인증 없는 `GET https://codex-resets.com/api/v1/status` 엔드포인트를 일반 사용량 5분 주기의 3배인 별도 15분 주기로 조회.
인식 가능한 출처 게시물이 있는 활성 예측은 `GET https://codex-resets.com/api/watch/votes`도 조회하며 해당 게시물과 일치하는 집계만 커뮤니티 투표율 계산에 사용.
커뮤니티 투표율 조회용 엔드포인트는 웹사이트 내부용이며 문서화된 공개 API에 포함되지 않아 호환성 변경 가능.
OpenUsage는 커뮤니티 투표율 산출용 집계만 조회하며 투표를 제출하지 않음.
지표를 활성화하거나 활성 상태에서 Codex 프로바이더를 다시 켜면 즉시 조회.
푸터의 수동 Refresh(⌘R)도 활성 예측과 커뮤니티 투표율을 사용량과 함께 조회 — 새 캐시도 재검증하되 재시도 대기는 유지하고 이미 진행 중인 요청은 공유.
자동 15분 일정은 변경하지 않으며 지표 비활성 상태에서는 Reset Watch를 조회하지 않음.
대시보드 표시와 메뉴 막대 별표가 모두 해제되거나 Codex 프로바이더를 끄면 이후 예약 조회 중단 — 이미 진행 중인 Reset Watch 요청은 완료될 수 있음.
Codex 로그인 불필요 — 계정 사용량을 가져올 수 없어도 Reset Watch 갱신 가능하며, 어느 쪽 실패도 다른 쪽 새로 고침을 지연하거나 실패시키지 않음.
요청에는 Codex 토큰, 계정 ID, 사용량 값, 로컬 로그, Cookie를 보내지 않음.
활성 watch의 확률·기한·커뮤니티 투표율은 계정별 값이 아닌 하나의 전역 예측.
**Separate Cards**에서는 대시보드 선택과 관계없이 활성 공유 홈 계정 카드에만 Reset Watch 표시; **Single Card** 동작은 유지.
커뮤니티 투표율은 웹사이트의 실시간 주기가 아닌 동일 조회 시점에 갱신.
커뮤니티 투표율 조회 실패·빈 집계·잘못된 값·게시물 불일치는 AI 예측을 유지하면서 **Vote share unavailable** 표시.
커뮤니티 투표율 조회 실패 시 해당 조회 요청만 연기하며 사용량과 AI 예측은 정상 새로 고침 유지.
커뮤니티 투표율 조회용 엔드포인트의 `Retry-After` 준수, 유효한 대기 시간이 없으면 요청 제한 후 5분·그 외 실패 후 1분 대기.
별도 타이머 없이 대기 시간이 지난 다음 수동 또는 자동 조회에서 커뮤니티 투표율 조회 재시도.
고정 **By** 기한은 사용량 재설정 날짜와 같은 지역화된 `날짜 at 시각` 형식과 앱의 12/24시간 설정 사용.
조회 성공 후 활성 watch가 없거나 확률이 없거나 기한이 지나면 기한·커뮤니티 투표율 없이 **0% chance** 표시.
최근 리셋 이후 등을 포함해 활성 리셋 신호가 없다는 의미이며, API가 측정된 0% 확률을 반환했다는 뜻은 아님.
첫 조회 완료 전에는 **No data** 표시.
조회 실패 시 **Unavailable · Retry later** 표시, 재사용 가능한 예측이 유효하면 **Cached forecast · Refresh failed** 표시.
조회 취소 시 재사용 가능한 캐시와 기존 실패 안내 유지.
다음 조회 성공 시 해당 안내 해제.
`no-store` 응답은 현재 조회에서만 표시, `no-cache` 예측은 조회 실패 후에도 재사용 전에 성공적인 재검증 필요.

막대는 40% 미만에서 중립 상태, 40–59%에서 파랑, 60–69%에서 노란 경고 삼각형, 70% 이상에서 빨간 불꽃 표시.
단계가 높아질수록 예상 재설정 전에 남은 토큰을 먼저 쓰라는 경고 강화.

Reset Watch는 앱 UI에서만 표시.
로컬 API와 일회성 CLI 출력에서는 제외.

## 인증 정보 출처

Codex CLI(`codex`)로 한 번 로그인하면 OpenUsage가 같은 인증 파일을 읽으며(`$CODEX_HOME` 반영), 필요하면 키체인으로 대체.
토큰은 자동 갱신 후 인증 파일에 다시 기록.

## 지출 타일

Today / Yesterday / Last 30 Days는 **로컬에서** 계산: OpenUsage가 `~/.codex/sessions/`와 `archived_sessions/`(또는 `$CODEX_HOME`) 아래의 Codex CLI 세션 롤아웃을 직접 읽으므로 외부 도구 불필요.
심볼릭 링크를 따라가므로 동기화 위치(예: Dropbox 폴더)에 연결된 Codex 홈도 동일하게 읽음.
[pi](https://github.com/earendil-works/pi) 코딩 에이전트의 Codex 사용량도 집계: OpenUsage가 `~/.pi/agent/sessions/`(또는 `$PI_CODING_AGENT_SESSION_DIR`) 아래의 pi 세션 로그를 읽어 그 안의 Codex 사용량을 같은 타일과 추세에 합산.
pi가 자체적으로 기록한 메시지별 비용을 그대로 사용하며 재추정하지 않음.
Mac의 로컬 시간대를 기준으로 날짜를 묶어 사용자의 달력과 일치.
각 기간은 비용과 토큰을 함께 보여 주는 단일 타일(`$4.08 · 1.2M tokens`)이며, 사용량 없는 날은 오해를 부르는 `$0.00 · 0 tokens` 대신 **No data** 표시 — 다른 모든 지출 추적 프로바이더와 같은 방식.
실시간 Session 및 Weekly 미터에는 영향 없음.
달러 금액은 토큰 수에 API 요율과 공유 [모델 가격](/docs/pricing.md)을 적용한 추정치(ⓘ의 의미)이며, 각 세션 로그에서 fast/priority 서비스 티어로 기록된 턴에만 fast 요율 적용.
티어 메타데이터가 없는 오래된 로그와 그 외 모든 항목에는 표준 요율 적용; 현재 `config.toml` 설정은 참조하지 않으므로 티어를 바꿔도 과거 날짜의 가격은 다시 계산하지 않음.
토큰 수 자체는 측정값.
하위 에이전트와 포크된 세션은 부모 세션의 토큰 이력을 자체 로그에 복사하지만, OpenUsage가 복사본을 인식해 하위 에이전트 수와 관계없이 각 토큰을 한 번만 집계.
로그 데이터는 Mac 밖으로 전송하지 않음.

지원되는 GPT-5.4, GPT-5.5, GPT-5.6 모델은 입력 토큰이 272k를 넘는 요청 전체에 OpenAI 긴 컨텍스트 요율 적용.
가격 출처에 캐시 읽기 할인이 있으면 캐시 입력에 해당 할인 적용, 없으면 전체 입력 요율로 추정.
Fast/priority 추정에는 모델별 공개 Codex 배율 적용(예: GPT-5.5는 2.5×); `-fast`로 끝나는 모델 이름은 배율을 한 번 적용하기 전에 배율 적용 전 기본 요율로 정규화.

## 여러 계정

추가 Codex 계정은 [**Settings → Accounts**](/docs/settings.md)에서 등록.
첫 계정은 새 로그인 없이 `~/.codex/auth.json`, 레거시 `~/.config/codex/auth.json`, `Codex Auth` 키체인 항목의 현재 로그인 가져오기.
추가 계정은 앱 소유 작업 공간 안에서 공식 절차로 로그인하므로 활성 로그인에 영향 없음.
**Settings → Accounts**에서 계정을 전환해도 공유 Codex 설정 홈은 그대로 두고 `auth.json`만 교체.
기존 `config.toml`, 스킬, 세션 기록은 계속 공유.
계정을 관리하고 공유 `auth.json`이 존재하는 동안 공유 홈 런타임은 해당 파일만 읽음 — 등록 계정에 연결된 경우에만 그 계정명으로 대시보드에 표시.
Settings 전환 시 해당 파일에 기록하며, 파일 기반 Codex 로그인이 파일을 최신 상태로 유지.
오래된 `Codex Auth` 키체인 항목이 다른 계정을 대신 응답하는 문제 방지.
각 계정의 인증 스냅샷은 macOS 키체인에 저장.
비활성 계정 카드는 해당 스냅샷에서 한도와 재설정 크레딧 조회.
비활성 카드의 재설정 크레딧 **Use**도 해당 스냅샷으로 클레임하며, 활성 로그인이나 새 Codex 세션에서 사용할 계정은 변경하지 않음.
지출 타일은 공유 홈의 세션 로그를 하나의 계열 합계로 집계.
과거 로그는 특정 계정에 귀속하지 않음.
따라서 비활성 스냅샷 카드에는 계정별 로컬 로그가 없으며 **Single Card**에서 지출 및 추세 행에 기존처럼 **No data** 표시 가능.
**Separate Cards**의 **Usage Trend**·**Today**·**Yesterday**·**Reset Watch**는 실제 공유 홈 로그인에 해당하는 활성 계정 카드에서만 기존 지표 설정에 따라 표시하며, 비활성 카드에서는 행 자체를 숨김.

Codex는 **Settings → Accounts**의 공통 **Usage Cards** 설정을 따름.
기본값 **Single Card**는 **Codex** 카드 하나와 기존 계정 선택기를 유지하며, **Separate Cards**는 표시 가능한 계정마다 선택기 없는 카드 하나를 표시.
Separate Cards 제목은 **Codex: Account 2** 같은 고정 형식 **{Provider}: {name}** 사용.
계정 순서는 [설정](/docs/settings.md), 카드 표시·공유 동작은 [대시보드](/docs/dashboard.md) 참조.

Codex 등록 계정이 있으면 대시보드·계정 선택기에 표시 가능한 등록 계정만 표시하며, 공유 홈 카드는 별도 추가하지 않음.
Codex 등록 계정이 없으면 기본 사용량 카드 유지.
계정 이름을 보여 주며 표시할 사용량과 재설정 팝오버 대상 계정만 변경.
로그인, 활성 로그인 전환, 새 Codex 세션에서 사용할 계정은 변경하지 않음.
카드에 재설정 크레딧 행이 있으면 **Use** 동작은 해당 카드의 인증 정보 출처로 클레임.
비활성 계정 카드는 [로컬 API](/docs/local-http-api.md)에 `codex@profile-…` 같은 ID로 표시.
일회성 [CLI](/docs/cli.md) 또는 로컬 API에서 `codex` 요청 시 현재 구성된 모든 Codex 카드 반환.
계정 추가, 이름 변경, 재로그인, 제거 시 대시보드 즉시 갱신.

## 서비스 상태

Codex가 활성화돼 있으면 실행 시, 활성화 시, 5분마다, 대시보드 수동 새로 고침 시 [OpenAI Status](https://status.openai.com/)의 Codex Web과 CLI 컴포넌트 확인.
활성화 시에도 5분 성공 캐시와 서버가 지정한 Retry-After 대기를 존중하며 상태 재확인.
공개 요청은 인증 없이 실행되며 OpenAI 인증 정보나 사용량 데이터를 보내지 않음.
두 컴포넌트 중 하나가 성능 저하, 부분 장애, 전체 장애를 보고하면 서버 해골 표시; 유지보수와 알 수 없는 결과에는 미표시.

## 문제 해결

- **"Not logged in"** — 관리형 계정은 **Settings → Accounts → Manage… → Sign In Again** 사용.
  완전하고 검증 가능한 로그인은 계정명을 바꾸거나 다른 계정을 선택하지 않고 해당 계정명에 저장된 인증 정보와 프로바이더 신원을 교체.
  그 외에는 `codex`를 실행해 로그인한 뒤 새로 고침.
- **API 키만 사용하는 설정**에서는 구독 사용량 조회 불가 — 대신 ChatGPT 계정으로 로그인.
- **지출 타일에 "No data" 표시** — 지난 30일간 Codex 세션 로그를 찾지 못한 상태.
  관리형 계정 전환 외의 경우 Codex 홈이 커스텀 위치에 있으면 `CODEX_HOME`을 설정해 CLI와 OpenUsage가 같은 위치 사용.
  관리형 터미널 전환은 공유 `~/.codex` 홈 사용.

## 내부 동작

Codex OAuth 토큰으로 `GET https://chatgpt.com/backend-api/wham/usage` 호출, `auth.openai.com`에서 갱신.
401/403 응답 시 토큰을 한 번 갱신한 뒤 재시도.
Session과 Weekly는 각 사용 기간의 primary/secondary 슬롯이 아닌 기간 길이로 분류.
Codex가 한도 하나를 일시적으로 제거하고 남은 주간 기간을 primary 슬롯으로 옮기는 경우에 필요한 처리.
기간을 인식할 수 없는 페이로드에는 호환성을 위해 primary를 Session, secondary를 Weekly로 처리하는 대체 규칙을 유지하며, 응답 헤더로 해당 기간의 누락된 백분율 보완.

Spark와 Spark Weekly는 같은 응답의 `additional_rate_limits` 배열에서 가져오며, 기간 기반 Session/Weekly 분류를 재사용하는 모델별 한도.
OpenUsage는 이름으로 GPT-5.3-Codex-Spark를 식별한 항목을 두 미터로 표시하며, 해당 한도가 없는 계정은 항목 자체가 없어 행에 "No data" 표시.
배열의 다른 모델 한도는 표시하지 않음.

OpenUsage는 Codex가 보고한 `used_percent`를 그대로 보존.
API가 사용하지 않은 기간을 1% 사용으로 보고하면 앱에는 99% 남음, 0%로 보고하면 100% 남음 표시.
Codex 행은 별도의 "Not started" 상태를 추정하지 않고 일반 재설정 레이블 사용.
사용 속도 예측은 유의미한 계산이 가능할 만큼 기간이 지난 뒤에만 시작.

"Rate Limit Resets" 행에는 온디맨드 재설정 크레딧 개수(예: `2 available`)와 가장 빠른 만료의 색상 점 표시 — 1주 초과는 파랑, 1주 이내는 노랑, 48시간 이내는 빨강.
OpenUsage는 크레딧별 만료를 나열하는 전용 엔드포인트 `GET https://chatgpt.com/backend-api/wham/rate-limit-reset-credits`도 가능한 범위에서 호출하며, 값에 마우스를 올리면 팝오버에 가장 빠른 순서대로 각 재설정의 타임라인 표시 — 번호가 붙은 색상 점, 정확한 만료 시각(`Jul 12 at 5:30 PM`), 오른쪽 끝의 카운트다운(`12d 18h`).
사용 가능한 크레딧이 없으면 `0 available`, 팝오버에는 `You have no rate limit resets` 표시.
전용 호출 실패 시 사용량 본문의 개수(`rate_limit_reset_credits.available_count`)로 대체; 본문에는 크레딧별 만료 정보가 없으므로, 팝오버에 개수(`N available`)와 만료 시각을 알 수 없다는 안내를 표시해 크레딧이 없는 것으로 오해하지 않도록 처리.

### 팝오버에서 재설정 사용

팝오버에서 재설정 크레딧을 바로 사용할 수 있으며 Codex CLI의 "Usage limit resets" 선택기와 같은 요청 수행.
타임라인의 크레딧에 마우스를 올리면 **Use** 버튼이 나타나고, 클릭 시 해당 크레딧이 인라인 확인 문구("Immediately reset your usage limits. This can't be undone.")와 **Reset** / **Cancel**로 확장.
확인 시 해당 크레딧을 사용해 5시간 및 주간 기간을 즉시 재설정한 뒤 Codex를 새로 고치므로, 성공 문구("Reset claimed. Enjoy!")를 표시하기 전에 미터와 남은 개수에 반영.
사용 요청이나 후속 갱신 중 해당 카드가 제거되거나 계정 신원이 바뀌면 이전 카드 ID로 교체 계정을 갱신하지 않고 남은 후속 작업 생략.
사용한 카드의 알려진 계정 신원이 유지되면 다른 계정 변경은 후속 갱신에 영향 없음.
이미 제출한 사용 요청은 원래 인증 정보를 유지하며, 사용 성공과 후속 갱신은 별도 기록.

되돌릴 수 없는 크레딧 사용을 위한 안전장치:

- 사용은 항상 호버 팝오버 안에서 의도적인 2회 클릭으로만 진행하며 자동 사용 없음.
- 매번 명시한 크레딧 하나를 대상으로 사용 시점의 최신 크레딧 목록과 다시 대조하고 멱등 키를 포함하므로, 네트워크 오류 후 재시도해도 두 번째 크레딧 사용 불가.
- 그사이 크레딧을 다른 곳(CLI 또는 웹)에서 사용했다면 팝오버에 더 이상 사용할 수 없다는 안내 후 새로 고침; 사용량에 재설정이 필요하지 않으면 Codex가 크레딧을 차감하지 않고 거부하며 팝오버에 해당 내용 표시.
  사용량 재설정 후에는 팝오버를 다시 열 때까지 남은 Use 버튼 비활성화("nothing to reset").
