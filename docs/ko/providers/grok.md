# Grok

Grok CLI 로그인 정보를 사용해 Grok Build 크레딧 사용량 추적.

## 추적 항목

| 지표 | 의미 |
|---|---|
| Weekly | 공유 주간 풀 사용률(Grok 통합 결제가 적용하는 한도)과 주간 초기화 카운트다운 |
| Extra Usage | 종량제 상한 상태(예: `2500 cap` 또는 `Disabled`) |
| Today / Yesterday / Last 30 Days | Grok CLI 로그에서 추정한 로컬 비용과 토큰 |

Grok이 구독 등급을 반환하면 프로바이더 이름 옆에 표시.

공유 주간 풀은 Grok이 통합 결제 계정에 적용하는 한도(기존 월간 크레딧 미터는 레거시로 더 이상 표시하지 않음).
통합 결제로 전환되지 않은 계정에는 주간 풀이 없어 Weekly 타일에 "No data" 표시.

## 인증 정보 출처

Grok CLI에서 한 번 로그인(`grok login`)하면 동일한 `~/.grok/auth.json` 사용.
액세스 토큰은 만료 전에 자동 갱신하며, 교체된 토큰은 파일에 다시 기록.

## 지출 타일

Today / Yesterday / Last 30 Days는 Grok CLI 로그(`~/.grok/logs/unified.jsonl` 또는 `$GROK_HOME/logs/unified.jsonl`)에서 **로컬로** 계산하며, OpenUsage가 로그를 직접 읽는 방식.
각 기간은 비용과 토큰을 함께 보여 주는 하나의 타일(`$4.08 · 1.2M tokens`)로, Claude/Codex/Cursor와 동일.
달러 금액은 공유 [모델 가격](/docs/ko/pricing.md)을 사용해 공개 API 요율과 토큰 수로 추정한 값(ⓘ 표시)이며, 토큰 수 자체는 측정값이고 이 추정치는 결제 API가 반환하는 월간 크레딧과 별개.
로그 데이터는 Mac 밖으로 전송되지 않음.
기록된 사용량이 없는 기간에는 오해를 부를 수 있는 `$0.00 · 0 tokens` 대신 "No data"를 표시하며, 다른 모든 지출 추적 프로바이더와 동일.

## 문제 해결

- **"Session expired" / 인증 오류** — `grok login`을 다시 실행한 뒤 새로 고침.
- **Weekly에 "No data" 표시** — 계정이 아직 월간(주간이 아닌) 주기를 반환하며 Grok 통합 주간 결제로 전환되지 않은 상태.
- **지출 타일에 "No data" 표시** — `~/.grok/logs/unified.jsonl`의 Grok CLI 로그가 필요하며, 이전 CLI 버전은 토큰 수를 기록하지 않음.
  Grok CLI 세션을 실행해 로그를 채운 뒤 새로 고침.

## 내부 동작

주간 풀과 종량제 상한에는 Grok CLI 자체와 동일한 `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits` 호출, 요금제 이름에는 `…/v1/settings` 사용, 토큰 갱신은 `auth.x.ai`를 통해 수행.
401/403 응답 시 토큰을 한 번 갱신하고 재시도.
