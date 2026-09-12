# Kimi

Kimi Code에 이미 로그인된 계정의 코딩 할당량 추적.

## 추적 항목

| 지표 | 의미 |
|---|---|
| Session | 5시간 순환 기간의 사용량과 초기화 시각 |
| Weekly | 7일 기간의 사용량과 초기화 시각 |

요금제 레이블은 Kimi 내부 멤버십 등급에 따라 공식 글로벌 요금제명 Adagio, Moderato, Allegretto, Allegro, Vivace 중 하나를 표시.
알 수 없는 등급도 읽기 쉬운 형태로 유지.
지출은 추적하지 않고 선택 사항인 booster wallet도 표시하지 않음.

## 인증 정보 출처

현재 Kimi Code 홈을 먼저 확인:

- `KIMI_CODE_HOME`이 설정된 경우 `$KIMI_CODE_HOME/credentials/kimi-code.json`
- 그 외에는 `~/.kimi-code/credentials/kimi-code.json`

이후 레거시 경로인 `~/.kimi/credentials/kimi-code.json`을 대체 경로로 확인.
기본 Kimi 호스트의 현재 인증 정보는 CLI와 동일한 잠금 프로토콜로 갱신 가능.
레거시 인증 정보는 읽기 전용이며 액세스 토큰이 유효한 동안만 사용 가능.

사용자 지정 API 또는 OAuth 호스트와 범위가 지정된 `kimi-code-env-*.json` 인증 정보는 미지원.
사용자 지정 호스트용 토큰을 Kimi 기본 서비스로 전송하지 않음.

## 문제 해결

- **"Not logged in to Kimi"** — `kimi`를 실행해 로그인을 마친 뒤 OpenUsage 새로 고침.
- **"Kimi session expired"** — `kimi`에서 다시 로그인한 뒤 새로 고침.
- **"Custom Kimi API or OAuth hosts are not supported"** — 이 프로바이더에는 Kimi Code 기본 호스트 사용.

## 내부 동작

Kimi Code의 비공식 `GET https://api.kimi.com/coding/v1/usages` 엔드포인트 호출.
현재 인증 정보 교체가 필요하면 Kimi Code OAuth 엔드포인트를 사용하며, CLI 소유 필드를 버리지 않고 해당 인증 정보 파일 갱신.
