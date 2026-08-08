# Devin

Devin CLI 또는 Devin 앱의 로그인으로 Devin 할당량 추적.

## 추적 항목

| 지표 | 의미 |
|---|---|
| Weekly | 주간 할당량 사용량(Devin이 주간 할당량을 보고하지 않으면 일간 수치로 대체) |
| Daily | 일간 할당량 사용량(Devin이 일간 할당량을 숨기면 미표시) |
| Extra Balance | 초과/추가 사용 잔액(달러) |

Devin이 요금제 이름을 보고하면 OpenUsage의 프로바이더 이름 옆에 표시.

## 인증 정보 출처

다음 순서로 확인하며, 먼저 정상 동작하는 인증 정보 사용:

1. Devin CLI 인증 정보: `~/.local/share/devin/credentials.toml`(`windsurf_api_key` 사용, `api_server_url`이 있으면 함께 사용)
2. Devin 앱의 로컬 상태 데이터베이스

CLI 인증 정보가 실패해도 앱에서 다른 계정으로 로그인한 상태면 앱의 인증 정보 사용.

## 문제 해결

- **"Not logged in"** — `devin auth login`을 실행하거나 Devin 앱에 로그인한 뒤 새로 고침.
- **Weekly에 일간 수치 표시** — Devin이 별도 주간 할당량을 보고하지 않으면 의미 있는 값을 유지하도록 Weekly 행에 일간 할당량 표시.

## 내부 동작

설정된 API 서버(기본값 `server.codeium.com`)에서 Connect RPC `GetUserStatus` 호출.
할당량 백분율은 "remaining"으로 전달되며 "used"로 변환.
토큰 갱신 없이 401/403 발생 시 다음 인증 출처로 전환.
