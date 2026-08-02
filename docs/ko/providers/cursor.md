# Cursor

Cursor 앱의 기존 로그인을 사용해 Cursor 요금제 사용량을 보여 줍니다.

## 추적 항목

| 지표 | 의미 |
|---|---|
| Credits | 그랜트와 선불 계정 잔액에서 남은 크레딧 잔액 |
| Total Usage | 청구 주기의 요금제 사용량(백분율 또는 달러, 요청 기반 Enterprise 계정에서는 포함 요청 수 대비 상한) |
| Requests | 커스텀 레이아웃을 위한 포함 요청 수 대비 상한의 선택적 복사본 |
| Auto Usage | Auto 모델 사용량 백분율 |
| API Usage | API 사용량 백분율 |
| Extra Usage | 온디맨드 지출 — 가능하면 사용자 범위, 아니면 팀 집계. Cursor가 한도를 반환하면 미터로 표시 |

Cursor가 요금제 이름을 보고하면 OpenUsage가 프로바이더 이름 옆에 표시합니다.

## 인증 정보 출처

Cursor 앱에 로그인되어 있기만 하면 됩니다. OpenUsage는 세션 토큰을 얻기 위해 Cursor의 로컬 상태 데이터베이스(및 키체인 항목)를 읽고, 갱신된 토큰은 다시 저장됩니다. 추가로 설치하거나 설정할 것이 없습니다.

## 지출 내역

Today, Yesterday, Last 30 Days, Usage Trend는 Cursor의 사용량 내보내기에서 가져옵니다. OpenUsage는
내보낸 토큰 수와 공통 모델 가격을 사용해 Mac에서 비용을 추정합니다. Cursor의 내보내기가 늦게
도착하면 최신 수치가 현재 활동보다 뒤처질 수 있습니다. 값이 깨졌을 때 0으로 조용히 바꾸지 않고,
문제가 있는 행만 제외합니다. 다운로드 실패, 잘못된 내보내기 형식, 손상된 CSV 구조가 발생하면 해당
새로 고침에서는 지출 내역을 사용할 수 없으며, 내보낸 사용량 데이터는 포함하지 않은 채 진단 로그에
기록됩니다.

## 문제 해결

- **"Not logged in" / 토큰 오류** — Cursor를 열어 로그인되어 있는지 확인한 다음 새로 고침하세요.
- **일부 지표 누락** — Cursor는 요금제 유형에 따라 필드를 생략합니다. 누락된 지표는 단순히 "No data"로 표시됩니다.
- **선택적 조회 실패** — 요금제, 크레딧 그랜트, 선불 잔액, 요청 대체 경로를 읽지 못해도 기본 사용량을 가져왔다면 치명적인 오류로 처리하지 않습니다. OpenUsage는 각 실패의 구체적인 사유를 진단 로그에 기록합니다.

## 내부 동작

`api2.cursor.sh`의 Connect RPC(대시보드 사용량), Enterprise/팀 계정을 위한 `cursor.com/api/usage`와 `cursor.com/api/usage-summary`의 결합 REST 대체 경로, `cursor.com/api/auth/stripe`의 Stripe 잔액, `cursor.com/api/dashboard/export-usage-events-csv`의 사용량 이벤트 CSV 내보내기. 대체 경로는 포함 요청 허용량을 구조화된 백분율 및 사용자 범위 온디맨드 지출과 결합하며, 어느 REST 응답도 그 자체로 전체 계정 스냅샷으로 취급되지 않습니다. 기본 대시보드 사용량 요청은 401/403 후 토큰을 갱신하고 한 번 재시도합니다. 선택적 엔드포인트 실패는 다른 대체 경로 응답을 사용할 수 있을 때 치명적이지 않으며 진단 로그에 기록됩니다. 일별 지출 산정은 공유 [모델 가격](../pricing.md)을 통해 가격이 매겨진 내보낸 토큰 수를 사용합니다. Cursor 전용 모델(`auto`, `composer-*`, …)은 보충 레이어에서 가져오며, 유지관리자가 [Cursor 모델 및 가격](https://cursor.com/docs/models-and-pricing.md)에서 동기화합니다.
