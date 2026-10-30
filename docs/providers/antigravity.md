# Antigravity

앱 또는 `agy` CLI가 Mac에 이미 저장한 인증 정보로 Antigravity(Google의 AI IDE) 공유 풀 할당량 추적.
이 Mac의 대화 이력으로 토큰과 추정 비용도 집계.

## 추적 항목

Antigravity에는 공유 할당량 풀이 두 개 있으며, 각 풀마다 순환 5시간 기간과 주간 기간 제공.

| 지표 | 의미 |
|---|---|
| Session | 공유 Gemini 풀(Pro와 Flash가 같은 할당량 사용)의 순환 5시간 기간 |
| Weekly | 같은 Gemini 풀의 주간 기간 |
| Claude | 공유 Gemini 외 풀(Claude, GPT-OSS, …)의 순환 5시간 기간 |
| Claude Weekly | 같은 Gemini 외 풀의 주간 기간 |

Antigravity가 `Pro`, `Ultra` 같은 구독 등급을 보고하면 OpenUsage의 프로바이더 이름 옆에 표시.

Gemini Pro와 Gemini Flash는 하나의 풀로, 어느 모델을 사용하든 같은 할당량이 줄어들어 OpenUsage에서는 Pro와 Flash 미터를 따로 두지 않고 기간별로 하나만 표시.
다른 프로바이더 행의 명명 방식에 맞춰 Session과 Weekly로 명명.
모든 Gemini 외 모델은 두 번째 풀을 공유하며 Claude라는 이름으로 표시(Codex의 Spark 쌍과 같은 방식).
할당량은 비율로 보고되며, 가득 찬 상태는 0% 사용을 뜻함.
토큰과 비용은 할당량 비율 대신 로컬 대화 이력으로 계산.

5시간 미터의 사용률이 0%이고 응답의 유효한 재설정 시각이 아직 지나지 않았으면 카운트다운 대신 **Not started** 표시.
마우스를 올리면 첫 메시지 후 세션이 시작된다는 설명 표시.
주간 미터는 응답에 유효한 재설정 시각이 있을 때 카운트다운 표시.

## 로컬 사용량과 비용

앱·CLI·IDE의 `~/.gemini/antigravity/conversations/*.db`, `~/.gemini/antigravity-cli/conversations/*.db`, `~/.gemini/antigravity-ide/conversations/*.db`를 읽기 전용으로 조회.
대화 단계에 기록된 발생 시각·모델·토큰 수를 기존 공통 가격 계산과 일별 집계에 연결.
현재 확보한 모델 가격으로 계산한 사용 가치 추정치이며, 구독료나 실제 청구액과 다름.
가격 산정 방식은 [모델 가격](/docs/pricing.md) 참조.
가격을 확인할 수 없는 모델의 토큰과 비용은 합계에서 제외하고 프로바이더 헤더에 경고 표시.

기존 네 개 할당량 지표는 유지하고, 로컬 사용량은 상단 링의 **Today**·**Yesterday**·**30 Days** 합계에 반영.
선택 기간에 유효한 이력이 없으면 상단 통계의 기존 빈 상태 적용.
이력은 이 Mac의 Antigravity 패밀리 합계로 취급하며, 현재 로그인 계정이나 선택 계정에 임의로 귀속하지 않음.
[Mac 간 동기화](/docs/icloud-sync.md)를 켜면 같은 로컬 이력 합산 규칙 적용.
할당량 조회에 실패해도 유효한 로컬 사용량은 유지하고 조회 실패 경고 표시.

## 인증 정보 출처

OpenUsage는 토큰을 요구하지 않고 Antigravity가 이미 보관한 인증 정보를 읽음.

- **로컬 언어 서버 조회** — 실행 중인 Antigravity 또는 `agy`의 언어 서버에 먼저 요청.
  현재 macOS 사용자 소유의 프로세스와 수신 포트만 탐색해 다른 사용자의 실행 중 계정에 연결하지 않음.
- **로컬 조회 실패** — Antigravity / `agy`가 macOS 키체인에 저장한 OAuth 토큰으로 Google Cloud Code API 조회.
  앱이 종료된 경우에도 이 경로 사용.
  할당량 요약은 production 서버를 먼저 조회하고, 사용량 항목이 빠져 있으면 daily 서버에서 보충.
  만료된 토큰은 자동 갱신(OpenUsage는 Antigravity 자체 키체인 항목에 다시 쓰지 않음).
  단기 캐시는 같은 키체인 로그인이 존재하며 읽을 수 있을 때만 재사용.

로컬 조회에 실패하고 사용할 로그인 정보도 없으면 *Start Antigravity or run `agy` and try again.* 표시.
인증 만료, 키체인 접근 실패, 일시적 API 장애는 각각 별도 오류로 안내.

## 문제 해결

- **"Start Antigravity or run `agy`…"** — Antigravity 앱에 로그인하거나 `agy`를 실행해 사용 가능한 토큰을 만든 뒤 새로 고침.
- **"Couldn't read Antigravity credentials…"** — 키체인 잠금 해제 또는 Antigravity 재로그인.
  현재 로그인을 확인하기 전까지 캐시된 액세스 토큰 사용 안 함.
- **주간 미터에 "No data" 표시** — 주간 데이터를 받지 못한 상태.
  요약 API 미지원, 일시적 조회 실패 또는 응답 내 주간 항목 누락 가능.
  Antigravity 업데이트 후 새로 고침.
  5시간 데이터만 조회되면 주간 미터는 계속 "No data" 표시.
- **특정 미터에 "No data" 표시** — 최신 응답에 해당 풀·기간이 없거나 사용 가능한 값이 없는 상태.
  유효한 값이 있는 다른 미터는 계속 갱신.
- **Gemini Pro와 Flash 미터가 보이지 않는다면?** — 두 모델이 하나의 공유 Gemini 풀을 사용하므로 단일 Session 미터로 병합.
- **많이 사용했는데도 할당량이 가득 차 보임** — 미터의 집계 기간과 재설정 시각 확인.
  재설정 시각은 응답에 포함된 경우에만 표시.

## 내부 동작

우선순위가 높은 출처부터 시도: `language_server` / `agy` 프로세스를 탐색해 로컬 언어 서버를 찾고 CSRF 토큰과 수신 포트를 읽은 뒤, 실패하면 필요할 때 Google OAuth로 갱신한 키체인 토큰을 사용해 Google Cloud Code 호출.
OpenUsage는 갱신된 액세스 토큰의 단기 캐시를 현재 키체인 갱신 인증 정보의 단방향 지문에 연결.
로그아웃, 계정 변경, 레거시 캐시, 만료되거나 손상된 항목으로는 이전 계정의 액세스 토큰 재사용 불가.
각 출처에서 먼저 할당량 요약 엔드포인트(언어 서버의 `RetrieveUserQuotaSummary`, Cloud Code의 `v1internal:retrieveUserQuotaSummary`) 요청 — 병합된 풀과 주간 기간을 보고하는 유일한 엔드포인트.
Cloud Code 요약은 production 서버 우선 조회.
기존 네 개 풀·기간에 모두 유효한 잔여 비율이 있으면 추가 조회 없이 종료.
항목이 누락되거나 조회에 실패하면 daily 서버도 조회해 같은 `bucketId`의 잔여 비율과 재설정 시각을 각각 첫 유효값으로 병합.
재설정 시각이 있어도 끝까지 유효한 잔여 비율이 없으면 해당 항목 제외.
정상 요약을 하나라도 받으면 다른 서버의 인증 오류나 일시 장애 때문에 해당 사용량을 버리지 않음.
요약 API 미지원, 일시적 조회 실패 또는 응답 해석 실패 시 이전 모델별 엔드포인트 시도.
두 서버 모두에서 정상 요약을 얻지 못하고 인증 오류가 있으면 이전 엔드포인트 대신 인증 갱신 절차로 진행.
이전 모델별 엔드포인트의 인증 오류도 인증 갱신 대상으로 처리.
로컬에서는 `GetUserStatus` / `GetCommandModelConfigs`, 원격에서는 `fetchAvailableModels` / `retrieveUserQuota` 사용.
Cloud Code의 요금제·이전 할당량 요청은 기존처럼 daily 서버 우선 조회.
이전 엔드포인트의 모델별 할당량은 풀마다 가장 낮은 잔여 비율로 합쳐 표시.
이 경로에서는 5시간 데이터만 표시.
요약 응답을 정상적으로 해석한 경우에는 항목이 비어 있어도 이전 엔드포인트로 전환하지 않음.
요금제 이름은 상속된 Windsurf 요금제 필드보다 Antigravity 자체 `userTier` 우선.
Cloud Code 요금제 요청에는 Antigravity 클라이언트 정보 포함.
응답의 알려진 `paidTier.id`를 먼저 해석하고, 해당하지 않으면 `paidTier.name`과 `currentTier.name` 순서로 확인.
요금제를 확인하지 못해도 정상 사용량은 유지하며, 원인은 로그에 기록.

> 앱과 언어 서버 바이너리의 리버스 엔지니어링 결과로, 엔드포인트와 저장 방식은 예고 없이 변경될 수 있음.
