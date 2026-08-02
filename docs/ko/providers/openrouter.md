# OpenRouter

계정 API 키로 [OpenRouter](https://openrouter.ai)의 크레딧 잔액과 사용액을 보여 줍니다.

## 추적 항목

| 지표 | 의미 |
|---|---|
| Credits | 구매한 크레딧 대비 누적 사용액(달러 미터) |
| Balance | 남은 선불 크레딧 |
| Today | 오늘 현재까지의 사용액 |
| This Week | 이번 주 현재까지의 사용액 |
| This Month | 이번 달 현재까지의 사용액 |
| Key Limit | 이 키의 상한 대비 사용액 — 키에 상한이 설정된 경우에만 표시 |

OpenUsage는 보고된 등급(예: "Pay as you go" 또는 "Free tier")을 프로바이더 이름 옆에 표시합니다.

## 인증 정보 출처

다른 프로바이더와 달리 OpenRouter에는 Mac에 인증 정보를 남기는 연동 앱이나 CLI가 없으므로 API 키를 직접 제공해야 합니다. [openrouter.ai/keys](https://openrouter.ai/keys)에서 키를 만든 다음 **Settings → API Keys**(설정 → API 키)에 추가하세요(권장). OpenRouter를 펼치고 키를 붙여넣은 뒤 Save(저장)를 누르면 됩니다. 키는 `~/.config/openusage/openrouter.json`에 저장되고 다음 새로 고침부터 사용됩니다.

키는 다음 방법으로도 제공할 수 있습니다(위에서부터 확인해 처음 찾은 키를 사용합니다):

1. **설정 파일:** `~/.config/openusage/openrouter.json` — 설정 카드가 쓰는 파일:

   ```json
   { "apiKey": "sk-or-v1-..." }
   ```

   키만 담긴 일반 텍스트 파일이나 `~/.config/openrouter/key.json`도 사용할 수 있습니다.

2. **환경 변수:** 셸 프로필(예: `~/.zshrc` 또는 `~/.zprofile`)에 `OPENROUTER_API_KEY`를 설정합니다. 앱은 실행 시 로그인 셸의 환경을 읽으므로, 여기에 export된 키는 터미널에서 실행할 때뿐 아니라 Finder나 Dock에서 앱을 시작하더라도 인식됩니다. 여기서 키를 찾으면 API Keys 카드가 이를 읽기 전용("From environment"(환경 변수에서))으로 표시하고, 저장된 키로 덮어쓸 수 있는 체크박스를 제공합니다.

앱에서 저장한 키는 환경 변수보다 우선합니다(설정 파일을 먼저 확인). 저장한 키를 삭제하면 환경 변수의
키를 사용하고, 환경 변수에도 없으면 키 없음 상태가 됩니다.

## 문제 해결

- **"No OpenRouter API key"**(OpenRouter API 키 없음) — Settings → API Keys(또는 설정 파일 / 환경 변수)에서 키를 추가한 후 새로 고침하세요.
- **"API key invalid"**(API 키가 유효하지 않음) — 키가 거부되었습니다(401/403). openrouter.ai/keys에서 키를 확인하거나 다시 생성하세요.

## 내부 동작

`https://openrouter.ai/api/v1`에 `Bearer` 토큰으로 REST 호출을 두 번 수행합니다:

- `GET /credits` — 계정 전체의 `total_credits`와 `total_usage`를 가져오며, Credits 미터와 Balance가 여기서 나옵니다. 사용 가능한 스냅샷에 필수입니다.
- `GET /key` — 가능한 범위에서 등급, 일간/주간/월간 사용액, 선택적 키별 상한을 가져옵니다. 이 호출이
  실패해도 잔액은 `/credits`의 결과로 표시됩니다.

기간 사용액 `$0.00`은 "No data"가 아니라 실제로 측정된 0으로 표시됩니다(API가 직접 보고합니다). 크레딧 값은 OpenRouter 측에서 최대 약 60초 지연될 수 있습니다.
