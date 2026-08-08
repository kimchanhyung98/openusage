# Kiro

Kiro CLI에 이미 로그인된 계정의 코딩 크레딧 추적.

## 추적 항목

| 지표 | 의미 |
|---|---|
| Credits | 현재 결제 기간 한도 대비 사용한 크레딧과 초기화 시각 |

Kiro가 반환한 구독 이름도 표시.
보너스 크레딧과 초과 사용 상세 정보는 활성 응답 형식이 검증되지 않아 표시하지 않음.

## 인증 정보 출처

`~/Library/Application Support/kiro-cli/data.sqlite3`의 Kiro CLI 데이터베이스를 읽음.
액세스 토큰과 프로필은 읽기 전용이며, Kiro 인증 정보를 갱신하거나 쓰지 않음.

Kiro CLI 소셜 로그인만 지원.
Kiro IDE 상태, Builder ID 또는 Identity Center 인증 정보, `~/.kiro` 아래의 기기 로컬 세션 파일은 계정 할당량 소스로 사용하지 않음.

## 문제 해결

- **"Not logged in to Kiro"** — `kiro-cli login`을 실행한 뒤 OpenUsage 새로 고침.
- **"Kiro session expired"** — `kiro-cli login`을 다시 실행한 뒤 새로 고침.
- **"Kiro credentials could not be read"** — Kiro CLI 데이터베이스가 존재하고 읽기 가능한지 확인.

## 내부 동작

저장된 액세스 토큰과 프로필 ARN을 비공식 CodeWhisperer `GetUsageLimits` 엔드포인트로 전송.
401 또는 403 응답 후 데이터베이스를 한 번 다시 읽고, Kiro CLI가 이미 토큰을 교체한 경우에만 재시도.
