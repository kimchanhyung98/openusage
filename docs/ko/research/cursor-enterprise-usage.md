# Cursor Enterprise 포함 사용량과 온디맨드 사용량

## 문제

Cursor Enterprise 계정에서 `GetCurrentPeriodUsage`의 유효한 `planUsage`가 반환되지 않을 수 있음.
이 경우 OpenUsage가 기존 요청 기반 `Requests` 행만 남기고 조기 반환.
해당 행은 선택 항목이며 기본값도 비활성화 상태이므로, `/api/usage`에 유효한 포함 요청 한도가 있어도 활성화된 Cursor 위젯 모두 `No data`로 표시.

기존 대체 경로도 응답 하나만 선택한 뒤 나머지 REST 데이터와 사용 기록을 추가하기 전에 반환하므로, 포함 요청과 온디맨드 지출을 동시에 표시할 수 없음.

## 관찰된 API 형태

식별자와 정확한 계정 합계를 제외하고 2026-07-13에 실제 Enterprise 계정으로 확인한 결과:

- `GetCurrentPeriodUsage`: 청구 주기 필드만 존재하며 `enabled`와 `planUsage` 없음.
- `GetPlanInfo`: `planName = Enterprise`.
- `GET /api/usage`: `gpt-4.numRequests`, 양수인 `gpt-4.maxRequestUsage`, `startOfMonth`.
- `GET /api/usage-summary`: ISO 청구 주기 경계, `membershipType = enterprise`, `limitType = team`, `individualUsage.plan`의 구조화된 백분율, 사용자 범위 `individualUsage.onDemand`, 팀 범위 `teamUsage.onDemand`.
  해당 응답에는 `teamUsage.pooled`와 `individualUsage.overall`이 없음.

## 필수 동작

1. 기존 Enterprise/team 한정 대체 경로에서 usage-summary와 요청 기반 사용량을 모두 조회.
2. 유효한 요청 한도를 기존 기본 `Total Usage` 미터로 사용하고, 선택 항목인 `Requests` 미터는 하위 호환성을 위해 유지.
3. 팀 집계보다 사용자 범위의 온디맨드 사용량을 우선하고, 사용자 버킷을 사용할 수 없을 때만 팀 버킷 사용.
4. `individualUsage.plan`의 구조화된 Auto/API 백분율 매핑.
5. 요청 수를 사용할 수 없으면 알려진 pooled/overall usage-summary 형식으로 대체.
6. 일반 사용량 경로처럼 대체 매핑 후 Cursor 사용 기록 행 추가.
7. 위젯 ID나 레이아웃 기본값 변경 없음.

## 승인 기준

- 실제 응답 형태를 본뜬 Enterprise 픽스처에서 포함 요청 사용량, Auto/API 백분율, 개인 온디맨드 달러 상한을 함께 표시.
- 팀 온디맨드 집계가 유효한 개인 상한을 대체하지 않음.
- pooled usage-summary 픽스처도 계속 Total Usage로 매핑.
- 요청 전용 Enterprise 응답에서 기존 Requests 출력을 유지하면서 기본 Total Usage 위젯도 채움.
- 두 REST 응답 모두 유효한 미터가 없으면 기존 대체 경로의 사용자 친화적 오류를 계속 표시.
- 전체 Swift 테스트 스위트와 릴리스 빌드 통과 후, 실제 Enterprise 계정으로 다시 빌드하고 실행.
