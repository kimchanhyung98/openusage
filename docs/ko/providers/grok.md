# Grok

Grok CLI의 기존 로그인으로 Grok Build 크레딧 사용량을 보여 줍니다.

## 추적 항목

| 지표 | 의미 |
|---|---|
| Weekly | 공유 주간 풀의 사용률(Grok 통합 결제가 적용하는 한도), 주간 초기화 카운트다운 포함 |
| Extra Usage | 종량제 상한을 상태로 표시(예: `2500 cap` 또는 `Disabled`) |
| Today / Yesterday / Last 30 Days | Grok CLI 로그에서 추정한 로컬 비용과 토큰 |

Grok이 구독 등급을 보고하면 OpenUsage가 프로바이더 이름 옆에 표시합니다.

주간 공유 풀은 Grok이 통합 결제 계정에 적용하는 한도입니다(기존 월간 크레딧 미터는 더 이상 표시하지 않습니다). 통합 결제로 이전되지 않은 계정에는 주간 풀이 없으므로 Weekly 타일에 "No data"(데이터 없음)가 표시됩니다.

## 인증 정보 출처

Grok CLI로 한 번 로그인하면(`grok login`) OpenUsage가 동일한 `~/.grok/auth.json`을 읽습니다. 액세스 토큰은 만료 전에 자동으로 갱신되며, 로테이션된 토큰은 파일에 다시 기록됩니다.

## 지출 내역

Today / Yesterday / Last 30 Days는 Grok CLI 로그(`~/.grok/logs/unified.jsonl` 또는 `$GROK_HOME/logs/unified.jsonl`)에서 **로컬로** 계산됩니다 — OpenUsage가 로그를 직접 읽습니다. 각 기간은 비용과 토큰을 함께 보여주는 하나의 타일(`$4.08 · 1.2M tokens`)로, Claude/Codex/Cursor와 동일합니다. 달러 금액은 공유 [모델 가격](../pricing.md)을 사용해 공개 API 요금 기준으로 토큰 수에서 추정한 값이며(ⓘ가 이를 나타냅니다), 토큰 수 자체는 측정된 값이고 이 추정치는 결제 API가 보고하는 월간 크레딧과는 별개입니다. 로그 데이터는 Mac 밖으로 나가지 않습니다. 기록된 사용량이 없는 기간은 오해를 부를 수 있는 `$0.00 · 0 tokens` 대신 "No data"로 표시됩니다 — 지출을 추적하는 다른 모든 프로바이더와 동일합니다.

## 문제 해결

- **"Session expired"**(세션 만료) / 인증 오류 — `grok login`을 다시 실행한 후 새로 고침하세요.
- **Weekly에 "No data" 표시** — 계정이 아직 월간(주간이 아닌) 주기를 보고하고 있으며, Grok의 통합 주간 결제로 아직 이전되지 않았다는 의미입니다.
- **지출 타일에 "No data" 표시** — `~/.grok/logs/unified.jsonl`의 Grok CLI 로그가 필요합니다. 이전 CLI 버전은 토큰 수를 기록하지 않았습니다. Grok CLI 세션을 실행해 로그를 채운 후 새로 고침하세요.

## 내부 동작

주간 풀과 종량제 상한에는 `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits`(Grok CLI 자체가 수행하는 것과 동일한 호출), 요금제 이름에는 `…/v1/settings`를 사용하며, 토큰 갱신은 `auth.x.ai`를 통해 이루어집니다. 401/403이 발생하면 토큰을 한 번 갱신하고 재시도합니다.
