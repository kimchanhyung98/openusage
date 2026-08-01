# Codex

Codex CLI의 기존 로그인을 사용해 ChatGPT/Codex 구독 한도를 보여 줍니다.

## 추적 항목

| 지표 | 의미 |
|---|---|
| Session | 5시간 순환 기간의 사용량 |
| Weekly | 7일 기간의 사용량 |
| Spark / Spark Weekly | GPT-5.3-Codex-Spark 모델 한도 — 5시간 기간과 주간 기간. 계정에 해당 한도가 있을 때만 표시되고(없으면 "No data"), 기본적으로 "show more" 캐럿 아래에 숨겨져 있음 |
| Rate Limit Resets | 온디맨드 속도 제한 재설정 크레딧 — 개수로 표시(예: `2 available`), 가장 빠른 만료를 나타내는 색상 점 포함. 값에 마우스를 올리면 각 크레딧의 만료 타임라인 표시 |
| Extra Usage | Flex 크레딧 — 달러 + 크레딧으로 그대로 표시(예: `$31.84 · 796 credits`) |
| Today / Yesterday / Last 30 Days | 로컬 지출 — 비용, 토큰 또는 둘 다(아래 참조) |

Codex가 요금제 이름을 보고하면 OpenUsage가 프로바이더 이름 옆에 표시합니다.

## 인증 정보 출처

Codex CLI(`codex`)로 한 번 로그인하면 됩니다. OpenUsage는 같은 인증 파일(`$CODEX_HOME` 지원)을 읽고,
필요하면 키체인도 확인합니다. 토큰은 자동으로 갱신되며 교체된 토큰은 인증 파일에 다시 기록됩니다.

## 지출 타일

Today / Yesterday / Last 30 Days는 **로컬에서** 계산됩니다: OpenUsage가 `~/.codex/sessions/`와 `archived_sessions/`(또는 `$CODEX_HOME`) 아래의 Codex CLI 세션 롤아웃을 직접 읽습니다 — 외부 도구가 필요 없습니다. 심볼릭 링크를 따라가므로 동기화 위치(예: Dropbox 폴더)로 링크된 Codex 홈도 똑같이 읽습니다. [pi](https://github.com/earendil-works/pi) 코딩 에이전트를 통한 Codex 사용량도 집계됩니다: OpenUsage는 `~/.pi/agent/sessions/`(또는 `$PI_CODING_AGENT_SESSION_DIR`) 아래의 pi 세션 로그를 읽어 그곳의 Codex 사용량을 같은 타일과 추세에 합산합니다. pi는 메시지별 비용을 스스로 기록하므로, 그 달러 금액은 재추정되지 않고 pi에서 그대로 가져옵니다. 날짜는 Mac의 로컬 시간대로 묶이므로 사용자의 달력과 일치합니다. 각 기간은 비용과 토큰을 함께 보여 주는 하나의 타일(`$4.08 · 1.2M tokens`)이며, 사용량이 없는 날은 오해를 부를 `$0.00 · 0 tokens` 대신 **No data**(데이터 없음)로 표시됩니다 — 지출을 추적하는 다른 모든 프로바이더와 동일합니다. 실시간 Session 및 Weekly 미터에는 영향이 없습니다. 달러 금액은 공유 [모델 가격](../pricing.md)을 사용해 토큰 수에서 API 요율로 추정되며(이것이 ⓘ의 의미), 각 세션 로그에 기록된 대로 fast/priority 서비스 티어에서 실행된 세션은 정확히 그 턴에 대해 fast 요율을 사용합니다. 티어 메타데이터가 없는 오래된 로그와 그 외 모든 것은 표준 요율로 가격이 매겨집니다. 현재 `config.toml` 설정은 참조하지 않으므로 티어를 바꿔도 과거 날짜의 가격이 다시 매겨지지 않습니다. 토큰 수 자체는 측정된 값입니다. 서브에이전트 및 포크된 세션은 부모 세션의 토큰 이력을 자신의 로그에 복사하며, OpenUsage는 이러한 복사본을 인식해 세션이 아무리 많은 서브에이전트를 생성하든 각 토큰을 한 번만 계산합니다. 로그 데이터는 Mac 밖으로 나가지 않습니다.

지원되는 GPT-5.4, GPT-5.5, GPT-5.6 모델은 입력 토큰이 272k를 넘는 요청에 OpenAI의 긴 컨텍스트
요율을 요청 전체에 적용합니다. 캐시 입력은 가격 출처에 공개된 캐시 읽기 할인이 있으면 사용하고,
없으면 전체 입력 요율로 계산합니다. fast/priority 추정에는 각 모델에 공개된 Codex 배율을 사용합니다
(예: GPT-5.5는 2.5×). `-fast`로 끝나는 모델 이름은 배율을 적용하기 전에 스케일이 적용되지 않은
기본 요율로 정규화합니다.

## 문제 해결

- **"Not logged in"** — `codex`를 실행해 로그인한 다음 새로 고침하세요.
- **API 키만 사용하는 설정**은 구독 사용량을 읽을 수 없습니다 — 대신 ChatGPT 계정으로 로그인하세요.
- **지출 타일에 "No data"가 표시됨** — OpenUsage가 지난 30일 동안의 Codex 세션 로그를 찾지 못했습니다. Codex 홈이 커스텀 위치에 있다면 `CODEX_HOME`을 설정해 Codex CLI와 OpenUsage가 같은 곳을 보게 하세요.

## 내부 동작

Codex OAuth 토큰으로 `GET https://chatgpt.com/backend-api/wham/usage`를 호출하고, `auth.openai.com`을
통해 갱신합니다. 401/403이 반환되면 토큰을 한 번 갱신한 뒤 재시도합니다. Session과 Weekly는
primary/secondary 슬롯이 아니라 각 사용량 기간의 길이로 분류합니다. Codex가 일시적으로 한도 하나를
제거하고 남은 주간 기간을 primary 슬롯으로 옮길 때도 올바르게 표시하기 위해서입니다. 기간을 인식할
수 없는 응답은 호환성을 위해 primary를 Session, secondary를 Weekly로 처리하며, 응답 헤더로 해당
기간의 누락된 백분율을 보완합니다.

Spark와 Spark Weekly는 같은 응답의 `additional_rate_limits` 배열에서 가져옵니다 — 기간 기반 Session/Weekly 분류를 재사용하는 모델별 한도입니다. OpenUsage는 이름이 GPT-5.3-Codex-Spark를 나타내는 항목을 그 두 미터로 노출합니다. 해당 한도가 없는 계정은 그 항목을 생략하므로 행이 "No data"로 표시됩니다. 배열의 다른 모델 한도는 표시되지 않습니다.

OpenUsage는 Codex가 보고한 `used_percent`를 그대로 사용합니다. API가 사용하지 않은 기간에 1% 사용을
보고하면 앱은 99% 남음으로 표시하고, 0%를 보고하면 100% 남음으로 표시합니다. Codex 행은 특별한
"Not started" 상태를 추정하지 않고 일반 초기화 레이블을 사용합니다. 사용 속도 예측은 유용한 계산을
할 수 있을 만큼 기간이 지난 뒤에만 표시합니다.

"Rate Limit Resets" 행은 온디맨드 재설정 크레딧 개수(예: `2 available`)를 가장 빠른 크레딧 만료의 색상 점과 함께 보여 줍니다 — 1주일 초과는 파랑, 1주일 이내는 노랑, 48시간 이내는 빨강. OpenUsage는 또한 각 크레딧의 만료를 나열하는 전용 엔드포인트인 `GET https://chatgpt.com/backend-api/wham/rate-limit-reset-credits`를 가능한 범위에서 호출하고, 값에 마우스를 올리면 이를 팝오버에 표시합니다: 각 재설정의 타임라인 — 가장 빠른 것부터, 번호가 매겨진 색상 점, 정확한 만료 시각(`Jul 12 at 5:30 PM`), 후행 가장자리의 카운트다운(`12d 18h`). 사용 가능한 크레딧이 없으면 `0 available`로 표시되고 팝오버에는 `You have no rate limit resets`가 표시됩니다. 전용 호출이 실패하면 행은 사용량 본문에 내장된 개수(`rate_limit_reset_credits.available_count`)를 사용합니다. 그 본문에는 크레딧별 만료가 없으므로, 팝오버는 개수(`N available`)를 알리면서 만료 시각은 알 수 없다고 안내하되, 만료 시각이 아예 없다고 암시하지는 않습니다.

### 팝오버에서 재설정 사용하기

그 팝오버에서 바로 재설정 크레딧을 소비할 수도 있습니다 — Codex CLI의 "Usage limit resets" 선택기가 수행하는 것과 같은 클레임입니다. 타임라인의 크레딧에 마우스를 올리면 **Use** 버튼이 나타나고, 클릭하면 해당 크레딧이 인라인 확인("Immediately reset your usage limits. This can't be undone.")으로 확장되며 **Reset** / **Cancel**이 표시됩니다. 확인하면 그 정확한 크레딧을 클레임하고 5시간 및 주간 기간이 즉시 재설정됩니다. 그런 다음 앱이 Codex를 새로 고쳐 성공 메시지("Reset claimed. Enjoy!")가 나타나기 전에 미터와 남은 개수에 반영합니다.

클레임은 되돌릴 수 없으므로 안전장치가 있습니다:

- 클레임은 항상 호버 팝오버 뒤의 의도적인 2회 클릭 흐름입니다 — 자동으로 클레임되는 일은 절대 없습니다.
- 각 클레임은 명시적인 크레딧 하나를 대상으로 하고(클레임 시점에 새 크레딧 목록과 다시 매칭) 멱등 키를 가지므로, 네트워크 오류 후 재시도가 두 번째 크레딧을 소비할 수 없습니다.
- 그 사이 크레딧이 다른 곳(CLI 또는 웹)에서 사용되었다면 팝오버는 더 이상 사용할 수 없다고 알리고 새로 고칩니다. 사용량이 재설정을 필요로 하지 않으면 Codex가 크레딧을 소비하지 않고 거부하며 팝오버가 그렇게 알립니다. 클레임이 사용량을 재설정한 후에는 팝오버를 다시 열 때까지 남은 Use 버튼이 비활성화됩니다("nothing to reset").
