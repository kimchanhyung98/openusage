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
| Key Limit | 현재 키 한도 기간의 사용액 — 키에 상한과 유효한 잔여액이 있는 경우 표시 |

반환된 등급(예: "Pay as you go" 또는 "Free tier")을 프로바이더 이름 옆에 표시.

## 인증 정보 출처

OpenUsage의 OpenRouter 조회에는 사용자가 제공한 API 키 필요.
[openrouter.ai/keys](https://openrouter.ai/keys)에서 키 생성.
**Customize → OpenRouter → API Key**에서 Add 선택.
키 입력.
Save 선택.
키는 `~/.config/openusage/openrouter.json`에 저장.
OpenRouter가 꺼져 있으면 Customize의 프로바이더 목록에서 활성화.

다음 방법으로 직접 키를 제공할 수도 있으며, 아래 순서에서 처음 찾은 키 사용:

1. **설정 파일:** `~/.config/openusage/openrouter.json` — API Key 카드에서 저장하는 파일:

   ```json
   { "apiKey": "sk-or-v1-..." }
   ```

   키만 담긴 일반 텍스트 파일 또는 `~/.config/openrouter/key.json`도 사용 가능.

2. **환경 변수:** 셸 프로필(예: `~/.zshrc` 또는 `~/.zprofile`)에 `OPENROUTER_API_KEY` 내보내기 설정 추가.
   설정을 바꾼 뒤 OpenUsage 종료 후 다시 실행.
   앱이 시작할 때 로그인 셸 환경을 읽으므로 Finder나 Dock에서 실행해도 해당 키 사용 가능.
   현재 터미널에서만 실행한 `export`는 이미 실행 중인 앱에 적용되지 않음.
   환경 변수에서 키를 찾으면 API Key 카드에 읽기 전용("From environment")으로 표시.
   별도 키를 저장하려면 "Override With a Custom Key" 선택.

앱에서 저장한 키가 환경 변수 키보다 우선하며(설정 파일을 먼저 확인), 저장한 키를 제거하면 환경 변수 키로 대체하거나 해당 키도 없으면 키 없음 상태로 전환.
앱에서 키를 저장하거나 삭제하면 적용 중인 키로 새로 조회하며, 이전 요청이 진행 중이면 완료를 기다리고 그 결과는 무시.
이전 요청이 대기 한도보다 오래 걸리면 다음 주기 새로 고침에서 현재 키로 재시도.
비활성 프로바이더는 다시 활성화될 때 조회.
새 요청이 진행 중이거나 실패하면 이전에 표시하던 마지막 정상 값 유지.
앱 재실행 시에도 현재 키로 조회하기 전 마지막 값 복원 가능.

## 문제 해결

- **"No OpenRouter API key"** — Customize → OpenRouter → API Key에 키 추가.
  환경 변수를 사용하면 위 설정 절차에 따라 앱 재실행.
- **"API key invalid"** — 키 거부(401/403).
  openrouter.ai/keys에서 확인하거나 다시 생성.
- **"Key Limit is unavailable"** — 키 한도의 잔여액을 확인할 수 없는 상태.
  Key Limit을 생략하고 조회에 성공한 잔액·기간 사용액은 계속 표시하며, 다음 정상 조회에서 경고 해제.
  표시할 다른 값이 하나도 없으면 경고 대신 조회 실패로 처리하고 마지막 정상 값 유지.

## 내부 동작

`https://openrouter.ai/api/v1`에 `Bearer` 토큰을 사용한 REST 호출 두 번 수행:

- `GET /credits` — 계정 전체 `total_credits`와 `total_usage`로, Credits 미터와 Balance의 출처.
  이 호출이 실패해도 `/key`에서 조회한 사용액 표시 가능.
- `GET /key` — 가능한 범위에서 등급, 일간/주간/월간 사용액, 설정된 경우 키별 상한 조회.
  이 호출이 실패해도 `/credits` 결과로 잔액 표시.

기간 사용액 `$0.00`은 "No data"가 아니라 API에서 직접 반환한 실제 측정값 0으로 표시.
Key Limit은 [키의 한도와 잔여 크레딧](https://openrouter.ai/docs/api_reference/limits)의 차이로 계산하며, 전체 기간 누적 사용액은 사용하지 않음.
현재 한도 기간의 초기화 이후에도 남은 한도에 맞는 사용액 표시.
상한이 있는데 잔여액이 누락되거나 유효하지 않으면 0 사용 또는 소진 상태로 추정하지 않음.
크레딧 값은 OpenRouter 측에서 최대 약 60초 지연될 수 있음.
