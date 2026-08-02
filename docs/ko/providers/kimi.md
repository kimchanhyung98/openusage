# Kimi

Kimi Code에 이미 로그인된 계정의 코딩 할당량을 추적합니다.

## 추적 항목

| 지표 | 의미 |
|---|---|
| Session | 롤링 5시간 사용 기간의 사용량과 초기화 시각 |
| Weekly | 7일 사용 기간의 사용량과 초기화 시각 |

Kimi가 반환한 내부 멤버십 등급을 공식 글로벌 요금제명인 Adagio, Moderato, Allegretto,
Allegro, Vivace로 표시합니다. 알 수 없는 등급은 읽기 쉬운 값으로 표시하며, 지출 및 선택적
booster wallet은 표시하지 않습니다.

## 인증 정보 출처

OpenUsage는 현재 Kimi Code 홈을 먼저 확인합니다.

- `KIMI_CODE_HOME`이 설정되어 있으면 `$KIMI_CODE_HOME/credentials/kimi-code.json`
- 그렇지 않으면 `~/.kimi-code/credentials/kimi-code.json`

그다음 기존 경로인 `~/.kimi/credentials/kimi-code.json`을 확인합니다. 기본 Kimi 호스트를 쓰는
현재 인증 정보는 CLI와 같은 잠금 방식으로 갱신할 수 있습니다. 기존 경로의 인증 정보는 읽기
전용이며, 액세스 토큰이 유효한 동안만 사용할 수 있습니다.

사용자 지정 API/OAuth 호스트와 범위가 지정된 `kimi-code-env-*.json` 인증 정보는 지원하지
않습니다. 사용자 지정 호스트용 토큰을 Kimi 기본 서비스로 전송하지 않습니다.

## 문제 해결

- **"Not logged in to Kimi"** — `kimi`를 실행해 로그인한 뒤 OpenUsage를 새로 고침하세요.
- **"Kimi session expired"** — `kimi`에서 다시 로그인한 뒤 새로 고침하세요.
- **"Custom Kimi API or OAuth hosts are not supported"** — 이 프로바이더에는 Kimi Code 기본 호스트를 사용하세요.

## 내부 동작

Kimi Code의 비공식 `GET https://api.kimi.com/coding/v1/usages` 엔드포인트를 호출합니다. 현재
인증 정보를 갱신해야 하면 Kimi Code의 OAuth 엔드포인트를 사용하고, CLI가 소유한 다른 필드는
버리지 않은 채 인증 정보 파일을 갱신합니다.
