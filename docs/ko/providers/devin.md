# Devin

Devin CLI 또는 Devin 앱의 로그인으로 Devin 할당량을 보여 줍니다.

## 추적 항목

| 지표 | 의미 |
|---|---|
| Weekly | 주간 할당량 사용량(Devin이 주간 할당량을 보고하지 않으면 일간 수치로 대체) |
| Daily | 일간 할당량 사용량(Devin이 일간 할당량을 숨기면 함께 숨겨짐) |
| Extra Balance | 초과/추가 사용 잔액(달러) |

Devin이 요금제 이름을 보고하면 OpenUsage가 프로바이더 이름 옆에 표시합니다.

## 인증 정보 출처

아래 순서로 확인하며, 먼저 정상적으로 읽히는 인증 정보를 사용합니다:

1. Devin CLI 인증 정보: `~/.local/share/devin/credentials.toml` (`windsurf_api_key`를 사용하고, `api_server_url`이 있으면 함께 사용)
2. Devin 앱의 로컬 상태 데이터베이스

CLI 인증 정보를 읽지 못했지만 앱이 다른 계정으로 로그인되어 있다면 앱의 인증 정보를 대신 사용합니다.

## 문제 해결

- **"Not logged in"**(로그인되지 않음) — `devin auth login`을 실행하거나 Devin 앱에 로그인한 후 새로 고침하세요.
- **Weekly에 일간 수치가 표시됨** — Devin이 별도의 주간 할당량을 보고하지 않으면 Weekly 행에 일간 할당량을 표시해 의미를 유지합니다.

## 내부 동작

구성된 API 서버(기본값 `server.codeium.com`)에서 Connect RPC `GetUserStatus`를 호출합니다. 할당량 백분율은 "remaining"(남은 양)으로 전달되며 "used"(사용량)로 뒤집습니다. 토큰 새로 고침은 없으며, 401/403이 발생하면 다음 인증 출처로 전환합니다.
