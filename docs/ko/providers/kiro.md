# Kiro

Kiro CLI에 이미 로그인된 계정의 코딩 크레딧을 추적합니다.

## 추적 항목

| 지표 | 의미 |
|---|---|
| Credits | 현재 결제 기간 한도에 대해 사용한 크레딧과 초기화 시각 |

Kiro가 반환한 구독 이름도 표시합니다. 활성 응답 형식이 검증되지 않은 bonus credits와 overage
상세 정보는 표시하지 않습니다.

## 인증 정보 출처

OpenUsage는 `~/Library/Application Support/kiro-cli/data.sqlite3`의 Kiro CLI 데이터베이스를
읽습니다. 액세스 토큰과 프로필은 읽기 전용으로 사용하며, Kiro 인증 정보를 갱신하거나 쓰지
않습니다.

Kiro CLI 소셜 로그인만 지원합니다. Kiro IDE 상태, Builder ID 또는 Identity Center 인증 정보,
`~/.kiro` 아래의 이 Mac 전용 세션 파일은 계정 할당량 소스로 사용하지 않습니다.

## 문제 해결

- **"Not logged in to Kiro"** — `kiro-cli login`을 실행한 뒤 OpenUsage를 새로 고침하세요.
- **"Kiro session expired"** — `kiro-cli login`으로 다시 로그인한 뒤 새로 고침하세요.
- **"Kiro credentials could not be read"** — Kiro CLI 데이터베이스가 존재하고 읽을 수 있는지 확인하세요.

## 내부 동작

저장된 액세스 토큰과 프로필 ARN으로 비공식 CodeWhisperer `GetUsageLimits` 엔드포인트를
호출합니다. 401 또는 403 응답을 받으면 데이터베이스를 한 번 다시 읽고, Kiro CLI가 이미 토큰을
교체한 경우에만 한 번 재시도합니다.
