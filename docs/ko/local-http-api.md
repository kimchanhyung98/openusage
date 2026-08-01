# 로컬 HTTP API

OpenUsage는 루프백 인터페이스에서 읽기 전용 HTTP API를 제공합니다. 다른 로컬 앱도 메뉴 막대에
표시되는 것과 같은 사용량 데이터를 읽을 수 있습니다.

**기본 URL:** `http://127.0.0.1:6736`

서버는 앱과 함께 자동으로 시작됩니다. 포트가 이미 사용 중이면 해당 세션에서는 이 기능이 조용히 비활성화됩니다.

## 라우트

### `GET /v1/limits`

모든 **활성화된** 프로바이더를 담은 연동용 응답 객체를 반환합니다. 프로바이더와 리소스는
안정적인 ID로 키가 지정되며, 값은 명시적 단위를 가진 원시 스칼라입니다. 새로운 연동에는
이 라우트를 권장하며, `openusage` CLI가 출력하는 형식과 정확히 동일합니다.

### `GET /v1/limits/:id`

해당 ID가 가리키는 모든 프로바이더를 담은 같은 형식의 응답 객체를 반환합니다. 비활성화된
프로바이더에도 동작합니다. 매칭은 단순 문자열 비교입니다. 정확한 프로바이더 ID는 그
프로바이더를, 패밀리 ID(`claude`, `codex`)는 해당 패밀리의 모든 계정 카드를 가리키며,
계정이 하나라면 그 하나의 카드가 전부입니다. 별칭이나 '올바른 계정 선택' 로직은 없으며,
같은 요청은 항상 같은 프로바이더를 가리킵니다.

- **200 OK** — 데이터가 있는 매칭된 모든 프로바이더를 포함하는 limits 응답 객체(새로 고침에
  실패하면 `errors` 항목이 표시되며, 아직 데이터가 없는 매칭된 프로바이더는 항목 자체가
  없습니다).
- **404 Not Found** — 해당 ID가 알려진 프로바이더나 패밀리를 가리키지 않습니다.

### `GET /v1/usage`

모든 **활성화된** 프로바이더에 대한 레거시 UI 지향 스냅샷을 대시보드 순서대로 반환합니다.
이 라우트는 더 이상 권장되지 않지만(deprecated) 기존 소비자는 계속 지원되며, 새로운
소비자는 `/v1/limits`를 사용해야 합니다.

두 라우트 모두 렌더링된 동일한 프로바이더 스냅샷을 읽습니다. iCloud 동기화가 켜져 있으면
두 라우트 모두 대시보드와 동일한 iCloud 결합 사용량을 보게 됩니다. `/v1/usage`는 기존
UI 지향 형태를 반환하고, `/v1/limits`는 데이터를 안정적인 리소스 ID와 원시 스칼라 값으로
투영합니다.

- **200 OK** — JSON 배열(아직 아무것도 가져오지 않았다면 빈 `[]`일 수 있습니다).

### `GET /v1/usage/:id`

해당 ID가 가리키는 모든 프로바이더의 최신 스냅샷을 반환합니다(`/v1/limits/:id`와 동일한
매칭). 비활성화된 프로바이더에도 동작합니다.

- **200 OK** — JSON 배열. 스냅샷이 있는 매칭된 프로바이더당 하나의 스냅샷(아직 하나도
  없으면 `[]`).
- **404 Not Found** — 해당 ID가 알려진 프로바이더나 패밀리를 가리키지 않습니다.

> **하위 호환성이 깨지는 변경:** 이 라우트는 이전에 단일 JSON 객체를 반환했고,
> 프로바이더에 스냅샷이 없으면 `204`를 반환했습니다. 이제는 항상 배열을 반환하므로,
> ID가 프로바이더 하나를 가리키든 전체 계정 패밀리를 가리키든 형태가 동일하게 유지됩니다.

### 그 외 모든 경우

`GET`/`OPTIONS` 이외의 메서드는 **405**를, 알 수 없는 라우트는 **404**를 반환합니다. 서버가 최대 16개의 동시 연결을 이미 처리 중이면 요청은 **503**을 받습니다. 잠시 후 다시 시도하세요.

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

`kind`는 `consumption`(`used`) 또는 `balance`(`available`)입니다. 상한이 있는 소비량에는
`limit`, `remaining`, 0–1 사이의 `utilization`도 포함됩니다. 초기화 시각, 사용 기간, 만료 목록,
`estimated` 필드는 프로바이더가 해당 의미를 제공할 때만 나타납니다. 현재 값이 없는
프로바이더나 리소스는 0으로 만들어 내지 않고 생략됩니다. `expiresAt`은 항상 `fetchedAt`에
앱과 CLI가 사용하는 것과 같은 5분 신선도 간격을 더한 값이며, `stale`은 그 시점이
지났는지를 나타냅니다. 새로 고침 실패는 마지막으로 정상이었던 프로바이더 스냅샷을 계속
사용할 수 있는 상태에서 `errors`에 `{"providerId":"…","message":"…"}` 형태로 표시됩니다.
상한이 있는 진행률 리소스에서 `unit`은 프로바이더의 라이브 지표 형식을 따릅니다. 예를
들어 Cursor `totalUsage`는 백분율 기반 요금제에서는 `percent`, 요청 기반 Enterprise
요금제에서는 `requests`, Cursor가 달러 풀을 보고하는 경우에는 `usd`입니다.

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
| OpenCode | `session`, `weekly`, `monthly` |
| OpenRouter | `credits`, `balance`, `keyLimit` |
| Z.ai | `session`, `weekly`, `webSearches` |

차트, 색상, 부제목, 포맷된 배지, 레이아웃 상태, 과거 지출 기간은 이 계약에 포함되지
않습니다. Codex의 결합된 Credits UI 행은 `credits`와 `creditValue` 두 개의 스칼라
리소스가 됩니다.

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
      "format": { "kind": "percent" },          // or "dollars", or "count" (+ "suffix")
      "resetsAt": "2026-03-26T13:00:00.161Z",   // optional
      "periodDurationMs": 18000000,             // optional
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

라인 타입은 `progress`, `text`, `badge`, `barChart`입니다. `barChart` 라인은 `points` 배열(하루에 하나의 `{ label, value, valueLabel? }`, 가장 오래된 것부터)과 선택적 `note`를 담습니다. `value`는 해당 일의 토큰 수, `valueLabel`은 미리 포맷된 표시 값, `label`은 현지화된 월/일(예: "Mar 25")입니다. `fetchedAt`은 스냅샷을 마지막으로 성공적으로 가져온 시점입니다(ISO 8601).

지출 행에 마우스를 올렸을 때 표시되는 앱 내 모델별 분석은 아직 이 API에 포함되지 않습니다. 지출 행은 계속 같은 `text` 라인으로 직렬화되므로 기존 로컬 연동은 현재 형태를 유지합니다.

두 응답 형식 모두에서 `displayName`은 카드의 현재 이름입니다. 앱에서 카드 이름을 변경했다면
변경된 이름이 여기에도 표시됩니다. 이름이 아니라 `providerId`(또는 응답 객체의 키)로 매칭하세요.

## 오류

```json
{ "error": "provider_not_found" }
```

코드: `provider_not_found`, `not_found`, `method_not_allowed`, `server_busy`.

## CORS 및 개인정보 보호

모든 응답에는 모든 출처를 허용하는 CORS 헤더(`Access-Control-Allow-Origin: *`, 메서드 `GET, OPTIONS`)가 포함됩니다. `OPTIONS` 요청은 프리플라이트에 대해 **204**를 반환합니다.

서버는 루프백 인터페이스(`127.0.0.1`)에서만 수신하므로 네트워크의 다른 Mac에서는 접근할 수 없습니다. 그러나 CORS 헤더가 모든 출처를 허용하므로, 앱이 실행 중일 때 브라우저에 열린 웹 페이지는 이 API에서 사용량 스냅샷을 읽을 수 있습니다. 노출되는 데이터는 메뉴 막대에 표시되는 것과 동일한 사용량 수치이며, 인증 정보나 토큰은 절대 제공되지 않습니다. 이는 원래 앱의 동작과 일치하므로 기존 연동이 계속 작동합니다.

## 캐싱 동작

API는 앱이 표시하는 내용을 그대로 제공합니다. 성공한 가져오기만 데이터를 대체하므로, 새로 고침 실패로 API가 비워지는 일은 없으며 마지막으로 정상이었던 스냅샷을 계속 받게 됩니다. [새로 고침 및 캐싱](refreshing.md)을 참조하세요.
