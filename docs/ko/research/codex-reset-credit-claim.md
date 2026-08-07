# Codex 레이트 리밋 초기화 크레딧: 사용 방식

Codex "reset credit" 사용 흐름을 조사하고 실계정에서 검증한 기록(2026-07-12)입니다.
이 문서는 앱 내 클레임을 추가하기 위한 프로토콜 참조로 시작되었습니다.
OpenUsage는 현재 [Codex 프로바이더 안내](/docs/ko/providers/codex.md#팝오버에서-재설정-사용하기)에 설명된 2단계 클릭과 카드별 클레임 흐름을 구현했습니다.
아래 엔드포인트 세부 정보는 그 구현의 프로토콜 참조입니다.

출처: 오픈소스 Codex CLI(`openai/codex`, `codex-rs/backend-client/src/client/rate_limit_resets.rs`,
`codex-rs/tui/src/chatwidget/reset_credits.rs`, `codex-rs/tui/src/chatwidget/usage.rs`,
`codex-rs/app-server/src/request_processors/account_processor/rate_limit_resets.rs`), 그리고
실제 계정에서 수행한 종단 간 사용 테스트(만료를 앞둔 크레딧 하나).

## 리셋 크레딧이란

OpenAI는 Codex 사용자에게 가끔 무료 "rate limit resets"를 지급합니다. 하나를 사용하면 계정의
Codex 레이트 리밋 기간이 즉시 초기화됩니다. 유료 요금제에서는 5시간 **및** 주간 기간이
함께(`windows_reset: 2`), Free/Go 요금제에서는 월간 윈도우가 리셋됩니다. 크레딧은 만료되며
(일반적으로 지급 후 30일) 사용되거나 만료되면 사라집니다.

## 엔드포인트

둘 다 ChatGPT 백엔드 베이스 URL(`https://chatgpt.com/backend-api`) 아래에 있습니다. CLI에는
엔터프라이즈/대체 베이스 URL용 `PathStyle::CodexApi` 변형(`/wham/...` 대신 `/api/codex/...`)도
있지만, OpenUsage는 ChatGPT 스타일을 사용합니다.

모든 호출에 포함되는 헤더:

- `Authorization: Bearer <access_token>`(`~/.codex/auth.json`의 ChatGPT OAuth 액세스 토큰)
- `ChatGPT-Account-Id: <account_id>`(같은 파일에서)
- `OpenAI-Beta: codex-1`과 `originator: Codex Desktop` — 리셋 크레딧 엔드포인트가 기대하는
  Codex 데스크톱 클라이언트 헤더이며, OpenUsage의 일반 사용량 조회는 보내지 않습니다
- POST에는 `Content-Type: application/json`

### 목록 조회 (OpenUsage에 이미 구현됨)

`GET /wham/rate-limit-reset-credits`

```json
{
  "credits": [
    {
      "id": "RateLimitResetCredit_…",
      "reset_type": "codex_rate_limits",
      "status": "available",            // available | redeeming | redeemed
      "granted_at": "2026-06-12T03:57:42.677034Z",
      "expires_at": "2026-07-12T03:57:42.677034Z",   // may be null (never expires)
      "redeem_started_at": null,
      "redeemed_at": null,
      "profile_image_url": "https://…/codex-icon-200.png",
      "profile_user_id": "Codex Team",
      "title": "Full reset (Weekly + 5 hr)",
      "description": "Thanks for using Codex! You've been granted one free rate limit reset."
    }
  ],
  "available_count": 4
}
```

참고: 사용되거나 만료된 크레딧은 목록에서 완전히 사라집니다(라이브 클레임 후 목록은 하나가
`redeemed`인 4개가 아니라 3개 항목이었습니다).

### 사용 (클레임)

`POST /wham/rate-limit-reset-credits/consume`

```json
{
  "redeem_request_id": "<client-generated UUID v4>",
  "credit_id": "RateLimitResetCredit_…"
}
```

- `redeem_request_id` — **멱등 키**로, 클라이언트가 발급하는 단순한 UUID v4입니다
  (TUI에서는 `Uuid::new_v4().to_string()`). CLI는 피커에 표시되는 크레딧마다 키를 하나씩
  생성하고 **사용자가 오류 후 재시도할 때 같은 키를 재사용**하므로, 재시도가 두 번째 크레딧을
  소모하는 일은 절대 없습니다. 서버는 `already_redeemed`로 응답하고 CLI는 이를 성공으로 처리합니다.
- `credit_id` — 선택 사항. 있으면 서버가 정확히 그 크레딧을 사용하고, 없으면 서버가 하나를
  고릅니다. CLI는 항상 이 값을 보냅니다(사용 가능한 크레딧을 `expires_at`이 가장 빠른 순으로
  정렬해 사용자가 선택하게 하며, 상세 목록을 가져오지 못했을 때의 대체 경로에서만
  `credit_id`를 생략합니다).

응답(실패를 나타내는 코드도 HTTP 200으로 반환되며 결과는 `code`에 있음):

```json
{
  "code": "reset",
  "credit": {
    "id": "RateLimitResetCredit_…",
    "status": "redeemed",
    "redeem_started_at": "2026-07-12T01:47:04.448019Z",
    "redeemed_at": "2026-07-12T01:47:05.162045Z",
    …
  },
  "windows_reset": 2
}
```

`code` 값(CLI의 `ConsumeRateLimitResetCreditCode`에서):

| code | 의미 | 크레딧 소모 여부 |
|---|---|---|
| `reset` | 성공; `windows_reset` = 리셋된 윈도우 수(2 = 5시간 + 주간) | 예 |
| `already_redeemed` | 같은 `redeem_request_id`가 이미 처리됨 — 성공으로 처리 | 이미 소모됨 |
| `nothing_to_reset` | 현재 사용량은 리셋이 필요하지 않음(CLI는 "Your usage does not need a reset right now."(현재 사용량은 리셋이 필요하지 않습니다) 표시) | 아니요 |
| `no_credit` | 대상 크레딧을 더 이상 사용할 수 없음(경쟁으로 소진 / 만료), 또는 사용 가능한 크레딧이 전혀 없음 | 아니요 |

consume 응답의 `credit` 객체는 CLI 자체 구조체가 디코딩하는 것보다 풍부합니다 — CLI가 무시하는
`redeem_started_at` / `redeemed_at` / `profile_*` 필드를 담고 있습니다.

## 실계정 검증 (2026-07-12, Pro 요금제)

전체 상세 로그(모든 요청/응답, 토큰은 가림 처리)는 저장소에 남기지 않았습니다. 실행에는 강제
안전장치가 있는 일회성 Python 스크립트를 사용했습니다(크레딧은 최대 하나만 사용하고, 만료가 가장 임박한 것만,
4시간 이내에 만료되는 경우만, 명시적 `credit_id`).

- 이전: 크레딧 4개 사용 가능. 5시간 윈도우 96% 사용(약 25분 후 리셋), 주간 52% 사용
  (약 6일 후 리셋). 대상 크레딧은 2.18시간 후 만료 예정.
- 새 UUID + 명시적 `credit_id`로 `POST …/consume` → HTTP 200,
  `code: "reset"`, `windows_reset: 2`, 크레딧 `status: "redeemed"`. 왕복 약 1.1초
  (`redeem_started_at` → `redeemed_at` ≈ 서버 측 0.7초).
- 이후(약 1초 뒤 조회): 5시간 및 주간 윈도우 모두 전체 윈도우 기간
  (`reset_after_seconds` = 18000 / 604800)으로 **0% 사용**으로 표시되고, `available_count` = 3,
  사용된 크레딧은 목록에 더 이상 나타나지 않습니다. 리셋은 `additional_rate_limits` 항목의
  윈도우도 0으로 만들었습니다(모델별 리밋은 이미 0%였으므로 이는 확증이 아닌 시사점입니다).

## OpenUsage가 채택한 구현 참고 사항

- 구현된 클레임은 OpenUsage가 이미 통신하는 인프라에 대한 단일 POST입니다.
  인증, 헤더, 계정 id 처리는 `CodexUsageClient`의 기존 호출과 동일합니다.
- OpenUsage는 `redeem_request_id` UUID를 **사용자에게 클레임 UI가 표시될 때** 크레딧별로 발급합니다.
  상호작용 동안 UUID를 유지하며, 재시도 시 재사용합니다 — CLI와 같은 이중 소모 방지 장치입니다.
- 항상 명시적 `credit_id`를 전달합니다.
  사용자가 타임라인에서 특정 크레딧을 직접 고르며(만료 임박 순 정렬, CLI와 같은 순서),
  클레임은 그 크레딧의 id만 대상으로 하고 클레임 시점의 새 목록과 다시 대조합니다.
- `already_redeemed`는 성공으로 처리하고, `nothing_to_reset`은 크레딧이 소모되지 않으므로 정보성 메시지로 표시합니다.
  `credit_id`와 함께 `no_credit`이 오면 크레딧이 경쟁으로 소진된 것이므로 목록을 새로 고칩니다.
- 이는 되돌릴 수 없고 사용자에게 보이는 희소한 지급분의 소모이므로, UI는 명시적 확인 뒤에 두고 절대 자동으로 클레임하지 않습니다.
- 클레임 성공 후 OpenUsage는 사용량과 크레딧 목록을 즉시 새로 고칩니다.
  두 윈도우가 0%로 떨어지고 개수가 감소하므로 위젯에 바로 반영되어야 합니다.
