# OpenRouter

계정 API 키로 [OpenRouter](https://openrouter.ai) 크레딧 잔액과 사용액 추적.

## 추적 항목

| 지표 | 의미 |
|---|---|
| Credits | 구매한 크레딧 대비 누적 사용액(달러 미터) |
| Balance | 남은 선불 크레딧 |
| Today | 오늘 현재까지의 사용액 |
| This Week | 이번 주 현재까지의 사용액 |
| This Month | 이번 달 현재까지의 사용액 |
| Key Limit | 키 상한 대비 사용액 — 키에 상한이 설정된 경우에만 표시 |

반환된 등급(예: "Pay as you go" 또는 "Free tier")을 프로바이더 이름 옆에 표시.

## 인증 정보 출처

다른 프로바이더와 달리 OpenRouter에는 기기에 인증 정보를 남기는 연동 앱이나 CLI가 없어 API 키를 직접 제공해야 함.
[openrouter.ai/keys](https://openrouter.ai/keys)에서 키를 만든 뒤 **Settings → API Keys**에 추가 권장: OpenRouter를 펼치고 키를 붙여 넣은 뒤 Save 선택.
키는 `~/.config/openusage/openrouter.json`에 저장되며 다음 새로 고침부터 사용.

다음 방법으로 직접 키를 제공할 수도 있으며, 아래 순서에서 처음 찾은 키 사용:

1. **설정 파일:** `~/.config/openusage/openrouter.json` — Settings 카드가 쓰는 파일:

   ```json
   { "apiKey": "sk-or-v1-..." }
   ```

   키만 담긴 일반 텍스트 파일 또는 `~/.config/openrouter/key.json`도 사용 가능.

2. **환경 변수:** 셸 프로필(예: `~/.zshrc` 또는 `~/.zprofile`)에 `OPENROUTER_API_KEY` 설정.
   앱 시작 시 로그인 셸 환경을 읽으므로 해당 위치에서 내보낸 키는 터미널뿐 아니라 Finder나 Dock에서 앱을 시작해도 인식.
   이 위치에서 키를 찾으면 API Keys 카드에 읽기 전용("From environment")으로 표시하고, 저장된 키로 재정의하는 체크박스 제공.

앱에서 저장한 키가 환경 변수 키보다 우선하며(설정 파일을 먼저 확인), 저장한 키를 제거하면 환경 변수 키로 대체하거나 해당 키도 없으면 키 없음 상태로 전환.

## 문제 해결

- **"No OpenRouter API key"** — Settings → API Keys, 설정 파일 또는 환경 변수에 키를 추가한 뒤 새로 고침.
- **"API key invalid"** — 키 거부(401/403).
  openrouter.ai/keys에서 확인하거나 다시 생성.

## 내부 동작

`https://openrouter.ai/api/v1`에 `Bearer` 토큰을 사용한 REST 호출 두 번 수행:

- `GET /credits` — 계정 전체 `total_credits`와 `total_usage`로, Credits 미터와 Balance의 출처.
  사용 가능한 스냅샷에 필수.
- `GET /key` — 가능한 범위에서 등급, 일간/주간/월간 사용액, 설정된 경우 키별 상한 조회.
  이 호출이 실패해도 `/credits` 결과로 잔액 표시.

기간 사용액 `$0.00`은 "No data"가 아니라 API에서 직접 반환한 실제 측정값 0으로 표시.
크레딧 값은 OpenRouter 측에서 최대 약 60초 지연될 수 있음.
