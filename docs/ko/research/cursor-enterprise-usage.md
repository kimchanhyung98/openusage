# Cursor Enterprise의 포함 사용량과 온디맨드 사용량

## 문제

Cursor Enterprise 계정은 `GetCurrentPeriodUsage`에서 사용 가능한 `planUsage`를
반환하지 않을 수 있습니다. 이 경우 OpenUsage는 레거시 요청 기반 `Requests` 라인만으로
일찍 반환합니다. 이 라인은 선택 사항이며 기본적으로 비활성화되어 있으므로, `/api/usage`에
유효한 포함 요청 한도가 있어도 활성화된 Cursor 위젯은 모두 `No data`로 렌더링됩니다.

기존 대체 경로는 하나의 응답만 선택했고, 다른 REST 데이터와 사용량 기록이 추가되기 전에
반환하기 때문에, 포함 요청과 온디맨드 지출을 동시에 표시할 수도 없습니다.

## 관찰된 API 형태

2026-07-13에 실제 Enterprise 계정으로 확인했습니다(식별자와 정확한 계정 총계는 생략):

- `GetCurrentPeriodUsage`: 청구 주기 필드만 있음. `enabled`나 `planUsage` 없음.
- `GetPlanInfo`: `planName = Enterprise`.
- `GET /api/usage`: `gpt-4.numRequests`와 양수인
  `gpt-4.maxRequestUsage`, 그리고 `startOfMonth`.
- `GET /api/usage-summary`: ISO 청구 주기 경계,
  `membershipType = enterprise`, `limitType = team`, `individualUsage.plan`의 구조화된
  백분율, 사용자 스코프의 `individualUsage.onDemand`, 팀 스코프의 `teamUsage.onDemand`.
  이 응답에는 `teamUsage.pooled`나 `individualUsage.overall`이 없었습니다.

## 요구 동작

1. 기존의 엄격한 Enterprise/team 대체 경로에서 usage-summary와 요청 기반 사용량을 모두 가져옵니다.
2. 유효한 요청 한도를 기존 기본 `Total Usage` 미터로 사용하고, 선택 사항인 `Requests` 미터는
   하위 호환성을 위해 유지합니다.
3. 팀 집계보다 사용자 스코프의 온디맨드 사용량을 우선합니다. 사용자 버킷을 사용할 수 없을 때만
   팀 버킷을 사용합니다.
4. `individualUsage.plan`의 구조화된 Auto/API 백분율을 매핑합니다.
5. 요청 수를 사용할 수 없으면 알려진 pooled/overall usage-summary 형식으로 대체합니다.
6. 일반 사용량 경로와 마찬가지로 대체 매핑 후 Cursor 사용량 기록 행을 추가합니다.
7. 위젯 ID를 추가하지 않고 레이아웃 기본값도 변경하지 않습니다.

## 승인 기준

- 실제 형태의 Enterprise 픽스처가 포함 요청 사용량, Auto/API 백분율, 개인 온디맨드 달러
  상한을 함께 렌더링합니다.
- 팀 온디맨드 집계가 유효한 개인 상한을 대체하지 않습니다.
- pooled usage-summary 픽스처도 여전히 Total Usage로 매핑됩니다.
- 요청 전용 Enterprise 응답은 기존 Requests 출력을 유지하면서 기본 Total Usage 위젯도 채웁니다.
- 두 REST 응답 모두 사용 가능한 미터가 없으면 기존의 이해하기 쉬운 대체 오류를 계속 표시합니다.
- 전체 Swift 테스트 스위트와 릴리스 빌드가 통과하고, 이후 실제 Enterprise 계정으로 리빌드 및
  실행합니다.
