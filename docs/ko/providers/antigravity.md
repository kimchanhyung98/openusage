# Antigravity

앱 또는 `agy` CLI가 Mac에 이미 저장한 인증 정보로 Antigravity(Google의 AI IDE) 공유 풀 할당량 추적.

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
할당량은 비율로 보고되므로(가득 참 = 0% 사용) 토큰 또는 달러 지출 타일 없음.

풀의 순환 5시간 기간에 아직 사용량이 없으면 해당 미터의 후행 레이블에 재설정 카운트다운 대신 **Not started** 표시, 마우스를 올리면 첫 메시지 후 세션이 시작된다는 설명 제공.
주간 미터에는 항상 일반 재설정 카운트다운 표시.

## 인증 정보 출처

OpenUsage는 토큰을 요구하지 않고 Antigravity가 이미 보관한 인증 정보를 읽음.

- **Antigravity 실행 중** — 앱의 로컬 언어 서버와 통신(가장 풍부한 정보 출처이자 요금제 이름의 출처).
- **앱 종료됨** — Antigravity / `agy`가 macOS 키체인에 저장한 OAuth 토큰으로 전환해 Google Cloud Code API 조회.
  만료된 토큰은 자동 갱신(OpenUsage는 Antigravity 자체 키체인 항목에 다시 쓰지 않음).
  단기 캐시는 같은 키체인 로그인이 존재하며 읽을 수 있을 때만 재사용.

두 출처 모두 사용할 수 없으면 *Start Antigravity or run `agy` and try again.* 표시.

## 문제 해결

- **"Start Antigravity or run `agy`…"** — Antigravity 앱에 로그인하거나 `agy`를 실행해 사용 가능한 토큰을 만든 뒤 새로 고침.
- **"Couldn't read Antigravity credentials…"** — 키체인 잠금 해제 또는 Antigravity 재로그인.
  현재 로그인을 확인하기 전까지 캐시된 액세스 토큰 사용 안 함.
- **주간 미터에 "No data" 표시** — 사용 중인 Antigravity 빌드가 아직 할당량 요약 엔드포인트를 제공하지 않는 상태(최신 빌드만 제공).
  5시간 미터는 이전 엔드포인트로 계속 동작하며, Antigravity 업데이트 시 주간 미터 복구.
- **미터에 "No data" 표시** — 최신 응답에 해당 풀/기간이 없는 상태(일부 등급은 특정 기간만 보고).
  다른 미터는 계속 갱신.
- **Gemini Pro와 Flash 미터가 보이지 않는다면?** — 두 모델이 하나의 공유 Gemini 풀을 사용하므로 단일 Session 미터로 병합.
- **많이 사용했는데도 할당량이 가득 차 보임** — 5시간 기간은 순환 방식, 주간 기간은 주 1회 재설정되며 각 미터에 재설정 시각 표시.

## 내부 동작

우선순위가 높은 출처부터 시도: `language_server` / `agy` 프로세스를 탐색해 로컬 언어 서버를 찾고 CSRF 토큰과 수신 포트를 읽은 뒤, 실패하면 필요할 때 Google OAuth로 갱신한 키체인 토큰을 사용해 Google Cloud Code 호출.
OpenUsage는 갱신된 액세스 토큰의 단기 캐시를 현재 키체인 갱신 인증 정보의 단방향 지문에 연결.
로그아웃, 계정 변경, 레거시 캐시, 만료되거나 손상된 항목으로는 이전 계정의 액세스 토큰 재사용 불가.
각 출처에서 먼저 할당량 요약 엔드포인트(언어 서버의 `RetrieveUserQuotaSummary`, Cloud Code의 `v1internal:retrieveUserQuotaSummary`) 요청 — 병합된 풀과 주간 기간을 보고하는 유일한 엔드포인트.
이 엔드포인트가 없는 빌드는 레거시 모델별 엔드포인트(로컬의 `GetUserStatus` / `GetCommandModelConfigs`, 원격의 `fetchAvailableModels` / `retrieveUserQuota`)로 전환하고, 모델별 할당량 중 풀마다 가장 낮은 잔여 비율을 기준으로 두 풀에 병합 — 이 엔드포인트들은 5시간 기간만 제공.
요금제 이름은 상속된 Windsurf 요금제 필드보다 Antigravity 자체 `userTier` 우선.

> 앱과 언어 서버 바이너리의 리버스 엔지니어링 결과로, 엔드포인트와 저장 방식은 예고 없이 변경될 수 있음.
