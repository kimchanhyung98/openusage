# Cursor

Cursor 앱의 로그인으로 Cursor 요금제 사용량 추적.

## 추적 항목

| 지표 | 의미 |
|---|---|
| Credits | 지급 크레딧과 선불 계정 잔액에서 남은 크레딧 |
| Total Usage | 청구 주기의 요금제 사용량(백분율 또는 달러, 요청 기반 Enterprise 계정에서는 포함 요청 수 대비 상한) |
| Requests | 커스텀 레이아웃에서 선택적으로 따로 표시하는 포함 요청 수 대비 상한 |
| Auto Usage | Auto 모델 사용 백분율 |
| API Usage | API 사용 백분율 |
| Extra Usage | 온디맨드 지출 — 가능하면 사용자 단위, 아니면 팀 집계이며 Cursor에서 한도를 반환하면 미터로 표시 |

Cursor가 요금제 이름을 보고하면 OpenUsage의 프로바이더 이름 옆에 표시.

## 인증 정보 출처

Cursor 앱 로그인만 필요.
OpenUsage가 세션 토큰을 얻기 위해 Cursor의 로컬 상태 데이터베이스와 키체인 항목을 읽고 갱신된 토큰을 다시 저장.
추가 설치나 설정 불필요.

## 지출 내역

Today, Yesterday, Last 30 Days, Usage Trend는 Cursor의 사용량 내보내기에서 가져옴.
내보낸 토큰 수와 공유 모델 가격으로 로컬에서 비용 추정.
Cursor의 내보내기가 간혹 늦게 도착하므로 최신 수치가 현재 활동보다 뒤처질 수 있음.
손상된 값을 조용히 0으로 계산하지 않고 개별 손상 행 제외.
다운로드 실패, 잘못된 내보내기 스키마, 손상된 CSV 구조가 발생하면 해당 새로 고침에서 지출 내역 사용 불가.
각 실패는 내보낸 사용량 데이터를 포함하지 않고 진단 로그에 기록.

## 서비스 상태

Cursor가 활성화돼 있으면 실행 시, 5분마다, 대시보드 수동 새로 고침 시 [Cursor Status](https://status.cursor.com/)의 IDE와 cursor.com 컴포넌트 확인.
공개 요청은 인증 없이 실행되며 Cursor 인증 정보나 사용량 데이터를 보내지 않음.
이 제품 컴포넌트는 Cursor 사용량과 가장 가까운 공식 범위이며, 사용량 API 엔드포인트 전용 상태 감시는 아님.
두 컴포넌트 중 하나가 성능 저하, 부분 장애, 중대 장애를 보고하면 서버 해골 표시; 예약된 유지보수와 알 수 없는 결과에는 미표시.

## 문제 해결

- **"Not logged in" / 토큰 오류** — Cursor를 열어 로그인 상태를 확인한 뒤 새로 고침.
- **일부 지표 누락** — Cursor는 요금제 유형에 따라 필드를 생략하며, 누락된 지표에는 "No data" 표시.
- **선택적 조회 실패** — 기본 사용량을 가져왔다면 요금제, 지급 크레딧, 선불 잔액, 요청 대체 경로의 실패는 치명적 오류로 처리하지 않음.
  인증 정보를 포함하지 않은 고정 사유만 진단 로그에 기록.

## 내부 동작

`api2.cursor.sh`의 Connect RPC(대시보드 사용량), Enterprise/팀 계정용 `cursor.com/api/usage`와 `cursor.com/api/usage-summary`의 두 REST 응답을 조합하는 대체 경로, `cursor.com/api/auth/stripe`의 Stripe 잔액, `cursor.com/api/dashboard/export-usage-events-csv`의 사용량 이벤트 CSV 내보내기.
대체 경로는 포함 요청 허용량과 구조화된 백분율 및 사용자 단위 온디맨드 지출을 결합하며, 어느 REST 응답도 단독으로 전체 계정 스냅샷으로 취급하지 않음.
기본 대시보드 사용량 요청은 401/403 후 토큰을 갱신해 한 번 재시도하며, 다른 대체 응답을 사용할 수 있으면 선택적 엔드포인트 실패를 치명적 오류로 처리하지 않고 진단 로그에 기록.
일별 지출 추정에는 공유 [모델 가격](/docs/ko/pricing.md)을 적용한 내보내기 토큰 수 사용; Cursor 전용 모델(`auto`, `composer-*`, …)은 유지관리자가 [Cursor 모델 및 가격](https://cursor.com/docs/models-and-pricing.md)에서 동기화하는 보충 가격 정보에서 가져옴.
