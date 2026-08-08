# Codex 레이트 리밋 재설정 크레딧: 클레임 방식

Codex "reset credit" 클레임 흐름 조사 및 실계정 검증 기록(2026-07-12).
앱 내 클레임 추가를 위한 프로토콜 참조로 시작.
현재 OpenUsage에 [Codex 프로바이더 안내](/docs/ko/providers/codex.md#팝오버에서-재설정-사용)의 2단계 클릭 방식과 카드별 클레임 흐름 구현 완료.
아래 엔드포인트 세부 정보는 해당 구현의 프로토콜 참조로 유지.

출처: 오픈 소스 Codex CLI(`openai/codex`, `codex-rs/backend-client/src/client/rate_limit_resets.rs`, `codex-rs/tui/src/chatwidget/reset_credits.rs`, `codex-rs/tui/src/chatwidget/usage.rs`, `codex-rs/app-server/src/request_processors/account_processor/rate_limit_resets.rs`)와 실제 계정에서 수행한 전체 클레임 검증(만료를 몇 시간 앞둔 크레딧 하나).

## 재설정 크레딧의 의미

OpenAI에서 Codex 사용자에게 가끔 무료 "rate limit resets"를 지급.
하나를 사용하면 계정의 Codex 레이트 리밋 기간을 즉시 재설정하며, 유료 요금제에서는 5시간 **및** 주간 기간을 함께 재설정(`windows_reset: 2`), Free/Go 요금제에서는 월간 기간 재설정.
일반적으로 지급 후 30일인 만료 기한이 있으며, 사용하거나 만료되면 소멸.

## 엔드포인트

둘 다 ChatGPT 백엔드 기본 URL(`https://chatgpt.com/backend-api`) 아래에 위치.
CLI에는 Enterprise/대체 기본 URL용 `PathStyle::CodexApi` 변형(`/wham/...` 대신 `/api/codex/...`)도 있지만, OpenUsage에서는 ChatGPT 방식 사용.

모든 호출의 헤더:

- `Authorization: Bearer <access_token>`(`~/.codex/auth.json`의 ChatGPT OAuth 액세스 토큰)
- `ChatGPT-Account-Id: <account_id>`(같은 파일에서 확인)
- `OpenAI-Beta: codex-1`과 `originator: Codex Desktop` — 재설정 크레딧 엔드포인트에서 요구하는 Codex 데스크톱 클라이언트 헤더이며 OpenUsage의 일반 사용량 조회에서는 전송하지 않음
- POST의 `Content-Type: application/json`

### 목록 조회(OpenUsage에 이미 구현)

`GET /wham/rate-limit-reset-credits`

```json
{
  "credits": [
    {
      "id": "RateLimitResetCredit_…",
      "reset_type": "codex_rate_limits",
      "status": "available",            // available | redeeming | redeemed
      "granted_at": "2026-06-12T03:57:42.677034Z",
      "expires_at": "2026-07-12T03:57:42.677034Z",   // null 가능(만료 없음)
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

참고: 사용되거나 만료된 크레딧은 목록에서 완전히 제외되며, 실제 클레임 후에도 하나가 `redeemed`인 4개가 아니라 3개 항목만 반환.

### 사용(클레임)

`POST /wham/rate-limit-reset-credits/consume`

```json
{
  "redeem_request_id": "<client-generated UUID v4>",
  "credit_id": "RateLimitResetCredit_…"
}
```

- `redeem_request_id` — 클라이언트가 발급하는 단순 UUID v4인 **멱등 키**(TUI의 `Uuid::new_v4().to_string()`).
  CLI에서 선택기에 표시된 크레딧마다 키 하나를 생성하고 **사용자가 오류 후 재시도할 때 같은 키를 재사용**하므로 재시도로 두 번째 크레딧이 소모될 수 없으며, 서버의 `already_redeemed` 응답도 성공으로 처리.
- `credit_id` — 선택 사항.
  값이 있으면 서버에서 해당 크레딧을 정확히 사용하고, 없으면 서버에서 하나를 선택.
  CLI에서는 항상 이 값을 전송하며 사용 가능한 크레딧을 가장 이른 `expires_at` 순으로 정렬해 사용자가 선택하도록 구성하고, 세부 목록을 가져오지 못한 대체 경로에서만 `credit_id` 생략.

응답(`code`에 결과를 담으므로 실패 코드도 HTTP 200으로 반환):

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

`code` 값(CLI의 `ConsumeRateLimitResetCreditCode` 기준):

| code | 의미 | 크레딧 소모 여부 |
|---|---|---|
| `reset` | 성공 — `windows_reset` = 재설정된 기간 수(2 = 5시간 + 주간) | 소모 |
| `already_redeemed` | 같은 `redeem_request_id`가 이미 처리된 상태 — 성공으로 처리 | 이미 소모 |
| `nothing_to_reset` | 현재 사용량에 재설정이 불필요한 상태(CLI에서 "Your usage does not need a reset right now." 표시) | 미소모 |
| `no_credit` | 대상 크레딧이 경쟁 상황이나 만료로 더 이상 유효하지 않거나, 사용 가능한 크레딧이 전혀 없는 상태 | 미소모 |

consume 응답의 `credit` 객체에는 CLI 자체 구조체에서 무시하는 `redeem_started_at`, `redeemed_at`, `profile_*` 필드까지 포함.

## 실계정 검증(2026-07-12, Pro 요금제)

모든 요청과 응답을 담은 상세 로그는 토큰을 가린 뒤 저장소 밖에 보관했으며, 실행에는 크레딧 최대 하나, 만료가 가장 임박한 항목, 4시간 이내 만료, 명시적 `credit_id` 조건을 강제한 일회성 Python 스크립트 사용.

- 이전: 크레딧 4개 사용 가능, 5시간 기간 96% 사용(약 25분 후 재설정), 주간 기간 52% 사용(약 6일 후 재설정).
  대상 크레딧의 남은 유효 시간은 2.18시간.
- 새 UUID와 명시적 `credit_id`로 `POST …/consume` 전송 → HTTP 200, `code: "reset"`, `windows_reset: 2`, 크레딧 `status: "redeemed"`.
  왕복 약 1.1초(`redeem_started_at` → `redeemed_at` 기준 서버 측 약 0.7초).
- 약 1초 뒤 조회 결과: 5시간 및 주간 기간 모두 전체 기간(`reset_after_seconds` = 18000 / 604800)으로 **0% 사용**, `available_count` = 3, 사용한 크레딧은 목록에서 제외.
  `additional_rate_limits` 항목의 기간별 사용량도 0%로 재설정되었지만, 모델별 리밋은 이미 0%였으므로 확증이 아닌 정황.

## OpenUsage에 반영된 구현 참고 사항

- 현재 클레임 구현은 OpenUsage에서 이미 사용하는 인프라를 향한 단일 POST.
  인증, 헤더, 계정 ID 처리는 `CodexUsageClient`의 기존 호출과 동일.
- OpenUsage에서 크레딧별 `redeem_request_id` UUID를 **사용자에게 클레임 UI를 표시할 때** 발급.
  상호작용 동안 UUID를 유지하고 재시도에도 재사용해 CLI와 같은 방식으로 중복 소모 방지.
- 항상 명시적 `credit_id` 전달.
  사용자가 CLI와 같은 만료 임박 순서의 타임라인에서 특정 크레딧을 선택하고, 클레임 시점에 새 목록과 다시 대조한 정확한 ID만 대상에 포함.
- `already_redeemed`는 성공으로 처리하고, 크레딧이 소모되지 않는 `nothing_to_reset`은 정보성 메시지로 표시.
  `credit_id`와 함께 `no_credit`이 오면 경쟁 상황으로 크레딧이 사라진 경우이므로 목록 새로 고침.
- 수량이 제한된 지급 크레딧을 되돌릴 수 없게 소모하는 사용자 동작이므로, UI에서 명시적 확인을 거치며 자동 클레임 금지.
- 클레임 성공 후 OpenUsage에서 사용량과 크레딧 목록을 즉시 새로 고침.
  두 기간의 사용량이 0%로 내려가고 개수가 감소한 결과를 위젯에 즉시 반영.
