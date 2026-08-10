# 로컬 HTTP API

OpenUsage는 루프백 인터페이스에 읽기 전용 HTTP API를 제공 — 다른 로컬 앱에서도 메뉴 막대와 같은 사용량 데이터 활용 가능.

**기본 URL:** `http://127.0.0.1:6736`

서버는 앱과 함께 자동 시작.
포트가 이미 사용 중이면 해당 세션에서 알림 없이 기능 비활성화.

## 라우트

### `GET /v1/limits`

**활성화된** 모든 프로바이더를 담은 시스템 연동용 응답 객체 반환.
프로바이더와 리소스는 안정적인 ID를 키로 사용하고, 값은 단위를 명시한 원시 스칼라.
새 연동에 권장하는 라우트이자, `openusage` CLI가 출력하는 형식과 정확히 동일.

### `GET /v1/limits/:id`

해당 ID가 가리키는 모든 프로바이더를 담은 같은 응답 객체 반환.
비활성화된 프로바이더에도 동작.
매칭은 단순 문자열 비교 — 정확한 프로바이더 ID는 해당 프로바이더를, 계열 ID(`claude`, `codex`)는 해당 계열의 모든 계정 카드를 가리키며 계정이 하나면 그 카드 하나만 해당.
별칭이나 "올바른 계정 고르기" 로직은 없고, 같은 요청은 항상 같은 프로바이더를 가리킴.

- **200 OK** — 데이터가 있는 매칭 프로바이더를 모두 담은 limits 응답 객체(새로 고침이 실패하면 `errors` 항목 등장, 아직 데이터가 없는 매칭 프로바이더는 항목 자체가 없음).
- **404 Not Found** — 해당 ID가 알려진 프로바이더나 계열을 가리키지 않음.

### `GET /v1/usage`

**활성화된** 모든 프로바이더의 레거시 UI 지향 스냅샷을 대시보드 순서대로 반환.
이 라우트는 폐기 예정이지만 기존 연동은 계속 지원하며, 새 연동은 `/v1/limits` 사용 권장.

두 라우트 모두 렌더링된 같은 프로바이더 스냅샷을 읽음.
따라서 iCloud 동기화가 켜져 있으면 둘 다 대시보드와 같은 iCloud 합산 사용량을 보게 되며, `/v1/usage`는 기존 UI 지향 형태를 반환하고 `/v1/limits`는 그 데이터를 안정적인 리소스 ID와 원시 스칼라 값으로 투영.

- **200 OK** — JSON 배열(아직 아무것도 가져오지 않았으면 빈 `[]`일 수 있음).

### `GET /v1/usage/:id`

해당 ID가 가리키는 모든 프로바이더의 최신 스냅샷 반환(`/v1/limits/:id`와 같은 매칭).
비활성화된 프로바이더에도 동작.

- **200 OK** — JSON 배열, 스냅샷이 있는 매칭 프로바이더당 하나(아직 하나도 없으면 `[]`).
- **404 Not Found** — 해당 ID가 알려진 프로바이더나 계열을 가리키지 않음.

> **하위 호환성이 깨지는 변경:** 이 라우트는 이전에 단일 JSON 객체를 반환했고, 프로바이더에 스냅샷이 없으면 `204` 반환.
> 이제는 항상 배열을 반환하므로, ID가 프로바이더 하나를 가리키든 계정 계열 전체를 가리키든 형태가 동일.

### 그 외 모든 경우

`GET`/`OPTIONS` 이외의 메서드는 **405**, 알 수 없는 라우트는 **404**.
서버가 최대치인 동시 연결 16개를 이미 처리 중이면 요청에 **503** 반환 — 간격을 두고 재시도.

## Limits 응답 형식

```jsonc
{
  "schema": "openusage.limits.v1",
  "generatedAt": "2026-07-13T01:40:00.000Z",
  "providers": {
    "codex": {
      "displayName": "Codex",
      "plan": "Pro 20x",
      "fetchedAt": "2026-07-13T01:39:30.000Z",
      "expiresAt": "2026-07-13T01:44:30.000Z",
      "stale": false,
      "resources": {
        "session": {
          "kind": "consumption",
          "unit": "percent",
          "used": 42,
          "limit": 100,
          "remaining": 58,
          "utilization": 0.42,
          "resetsAt": "2026-07-13T06:00:00.000Z",
          "windowSeconds": 18000
        },
        "credits": {
          "kind": "balance",
          "unit": "credits",
          "available": 821
        }
      }
    }
  },
  "errors": []
}
```

`kind`는 `consumption`(`used`) 또는 `balance`(`available`).
상한이 있는 소비량에는 `limit`, `remaining`, 0–1 범위의 `utilization`도 포함.
초기화·기간·만료 목록·`estimated` 필드는 프로바이더가 해당 개념을 제공할 때만 포함.
현재 값이 없는 프로바이더나 리소스는 0으로 만들어 내지 않고 생략.
`expiresAt`은 항상 `fetchedAt`에 앱·CLI와 동일한 5분 신선도 간격을 더한 값이며, `stale`은 해당 시점의 경과 여부를 표시.
새로 고침에 실패해도 마지막 정상 프로바이더 스냅샷은 계속 사용할 수 있고, 오류는 `errors`에 `{"providerId":"…","message":"…"}` 형태로 포함.
상한이 있는 진행률 리소스에서 `unit`은 프로바이더의 현재 지표 형식을 따름.
예를 들어 Cursor `totalUsage`는 백분율 기반 요금제에서는 `percent`, 요청 기반 Enterprise 요금제에서는 `requests`, Cursor가 달러 풀을 보고할 때는 `usd`.

### 공개 리소스

| 프로바이더 | 리소스 키 |
| --- | --- |
| Claude | `session`, `weekly`, `sonnet`, `fable`, `extraUsage` |
| Codex | `session`, `weekly`, `spark`, `sparkWeekly`, `credits`, `creditValue`, `rateLimitResets` |
| Cursor | `totalUsage`, `autoUsage`, `apiUsage`, `onDemand`, `requests`, `credits` |
| Antigravity | `geminiSession`, `geminiWeekly`, `nonGeminiSession`, `nonGeminiWeekly` |
| Copilot | `premiumCredits`, `extraUsage`, `orgCredits`, `orgSpend`, `chat`, `completions` |
| Devin | `daily`, `weekly`, `extraUsageBalance` |
| Grok | `weekly` |
| Kimi | `session`, `weekly` |
| Kiro | `credits` |
| OpenCode | `session`, `weekly`, `monthly` |
| OpenRouter | `credits`, `balance`, `keyLimit` |
| Z.ai | `session`, `weekly`, `webSearches` |

차트, 색상, 부제목, 형식화된 배지, 레이아웃 상태, 과거 지출 기간은 이 계약에서 제외.
Codex의 결합된 Credits UI 행은 `credits`와 `creditValue` 두 스칼라 리소스로 분리.

## 레거시 Usage 응답 형식

```jsonc
{
  "providerId": "claude",
  "displayName": "Claude",
  "plan": "Team 5x",
  "lines": [
    {
      "type": "progress",
      "label": "Session",
      "used": 42.0,
      "limit": 100.0,
      "format": { "kind": "percent" },          // "dollars" 또는 "count"(+ "suffix")도 가능
      "resetsAt": "2026-03-26T13:00:00.161Z",   // 선택 사항
      "periodDurationMs": 18000000,             // 선택 사항
      "color": null
    },
    {
      "type": "text",
      "label": "Today",
      "value": "$5.17 · 9.2M tokens",
      "color": null,
      "subtitle": null
    },
    {
      "type": "badge",
      "label": "Pay as you go",
      "text": "2500 cap",
      "color": "#22c55e",
      "subtitle": null
    },
    {
      "type": "barChart",
      "label": "Usage Trend",
      "points": [
        { "label": "Mar 25", "value": 1200000.0, "valueLabel": "1.2M tokens" },
        { "label": "Mar 26", "value": 2400000.0, "valueLabel": "2.4M tokens" }
      ],
      "note": "Estimated from local Claude logs at API rates.",
      "color": null
    }
  ],
  "fetchedAt": "2026-03-26T11:16:29.000Z"
}
```

행 타입은 `progress`, `text`, `badge`, `barChart`.
`barChart` 행은 날짜별 `{ label, value, valueLabel? }`를 오래된 순으로 담은 `points` 배열과 선택적 `note`를 포함 — `value`는 해당 날의 토큰 수, `valueLabel`은 미리 형식화한 표시 값, `label`은 현지화한 월/일(예: "Mar 25").
`fetchedAt`은 스냅샷을 마지막으로 성공적으로 가져온 시점(ISO 8601).

지출 행에 마우스를 올렸을 때 나오는 앱 내 모델별 내역은 아직 이 API에 없음.
지출 행은 계속 동일한 `text` 행으로 직렬화되므로 기존 로컬 연동의 현재 형태 유지.

두 응답 형식 모두에서 `displayName`은 카드의 현재 이름 — Claude·Codex 계정은 그 계정에서 파생한 이름.
매칭은 이름이 아니라 `providerId`(또는 응답 객체의 키) 기준.

## 오류

```json
{ "error": "provider_not_found" }
```

코드: `provider_not_found`, `not_found`, `method_not_allowed`, `server_busy`.

## CORS 및 개인정보

모든 응답에 허용적인 CORS 헤더 포함(`Access-Control-Allow-Origin: *`, 메서드 `GET, OPTIONS`).
`OPTIONS` 요청은 프리플라이트로 **204** 반환.

서버는 루프백 인터페이스(`127.0.0.1`)에서만 수신하므로 네트워크의 다른 기기에서는 접근 불가.
다만 CORS 헤더가 허용적이라, 앱이 실행 중이면 브라우저에 열린 웹 페이지가 이 API에서 사용량 스냅샷을 읽을 수 있음.
노출되는 데이터는 메뉴 막대와 같은 사용량 수치뿐이며, 인증 정보나 토큰은 절대 제공하지 않음.
이는 원래 앱의 동작과 같으므로 기존 연동도 계속 동작.

## 캐싱 동작

API는 앱이 표시하는 그대로 제공 — 가져오기에 성공한 경우에만 데이터를 교체하므로 새로 고침 실패로 API가 비는 일은 없고, 마지막 정상 스냅샷을 계속 받음.
[새로 고침 및 캐싱](refreshing.md) 참조.
