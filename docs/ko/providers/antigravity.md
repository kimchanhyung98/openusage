# Antigravity

앱 또는 `agy` CLI가 Mac에 이미 저장해 둔 인증 정보를 사용해 Antigravity(Google의 AI IDE)의
공유 할당량을 추적합니다.

## 추적 항목

Antigravity에는 공유 할당량 풀이 두 개 있고, 각 풀에는 순환 5시간 기간과 주간 기간이 있습니다:

| 지표 | 의미 |
|---|---|
| Session | 공유 Gemini 풀(Pro와 Flash가 같은 할당량을 사용)의 순환 5시간 기간 |
| Weekly | 같은 Gemini 풀의 주간 기간 |
| Claude | 공유 비Gemini 풀(Claude, GPT-OSS, …)의 순환 5시간 기간 |
| Claude Weekly | 같은 비Gemini 풀의 주간 기간 |

Antigravity가 구독 등급(예: `Pro` 또는 `Ultra`)을 보고하면 OpenUsage가 프로바이더 이름 옆에 표시합니다.

Gemini Pro와 Gemini Flash는 하나의 풀을 공유합니다. 어느 모델을 사용하든 같은 할당량이 줄어들므로,
OpenUsage는 Pro와 Flash 미터를 따로 표시하지 않고 기간마다 하나의 미터만 보여 줍니다. 다른
프로바이더의 행과 맞추기 위해 이 미터의 이름은 Session과 Weekly로 표시합니다. 모든 비Gemini 모델은
두 번째 풀을 공유하며 Claude라는 이름 아래에 표시됩니다(Codex의 Spark 쌍과 같은 방식). 할당량은
남은 비율로 보고되므로(가득 찬 상태 = 0% 사용), 토큰이나 달러 지출 타일은 없습니다.

풀의 순환 5시간 기간에 아직 사용량이 없으면 해당 미터의 뒤쪽 레이블이 초기화 카운트다운 대신
**Not started**(시작 안 함)로 표시됩니다. 마우스를 올리면 첫 메시지를 보낸 뒤 세션이 시작된다는
설명이 나타납니다. 주간 미터는 항상 일반 초기화 카운트다운을 표시합니다.

## 인증 정보 출처

OpenUsage는 토큰을 요구하지 않고 Antigravity가 이미 보관한 인증 정보를 읽습니다.

- **Antigravity 실행 중** — OpenUsage가 앱의 로컬 언어 서버와 통신합니다(가장 풍부한 정보 소스이며 요금제 이름도 여기서 가져옵니다).
- **앱 종료됨** — Antigravity / `agy`가 macOS 키체인에 저장한 OAuth 토큰으로 전환해 Google Cloud Code API를 조회합니다. 만료된 토큰은 자동으로 갱신합니다(OpenUsage는 Antigravity 자체의 키체인 항목에 절대 다시 쓰지 않습니다). 단기 캐시는 같은 키체인 로그인이 존재하고 읽을 수 있을 때만 재사용합니다.

둘 다 사용할 수 없으면 *Start Antigravity or run `agy` and try again.*이 표시됩니다.

## 문제 해결

- **"Start Antigravity or run `agy`…"** — Antigravity 앱에 로그인하거나 `agy`를 실행해 사용 가능한 토큰을 만든 다음 새로 고침하세요.
- **"Couldn't read Antigravity credentials…"** — 키체인을 잠금 해제하거나 Antigravity에 다시 로그인하세요. OpenUsage는 현재 로그인을 확인할 수 있을 때까지 캐시된 액세스 토큰을 사용하지 않습니다.
- **주간 미터에 "No data"가 표시됨** — 사용 중인 Antigravity 빌드가 아직 할당량 요약 엔드포인트를 제공하지 않습니다(새 빌드만 제공). 5시간 미터는 이전 엔드포인트로 계속 동작하며, Antigravity를 업데이트하면 주간 미터가 다시 표시됩니다.
- **미터에 "No data"가 표시됨** — 최신 응답에 해당 풀/사용 기간이 없었습니다(일부 등급은 특정 기간만 보고). 다른 미터는 정상적으로 갱신됩니다.
- **Gemini Pro와 Flash 미터는 어디로 갔나요?** — 병합되었습니다. 두 모델 모두 하나의 공유 Gemini 풀에서 할당량을 사용하며, 이제 단일 Session 미터로 표시됩니다.
- **많이 사용했는데도 할당량이 가득 차 보임** — 5시간 기간은 순환 방식으로, 주간 기간은 주 1회 재설정됩니다. 재설정 시각은 각 미터에 표시됩니다.

## 내부 동작

가장 정확한 소스부터 시도합니다. 먼저 `language_server` / `agy` 프로세스를 찾아 로컬 언어 서버의
CSRF 토큰과 수신 포트를 읽고, 실패하면 필요할 때 Google OAuth로 갱신한 키체인 토큰으로 Google
Cloud Code에 요청합니다. OpenUsage는 단기 갱신 토큰 캐시를 현재 키체인 갱신 인증 정보의 단방향
지문에 연결합니다. 로그아웃, 계정 변경, 레거시 캐시, 만료되거나 손상된 항목은 이전 계정의 액세스
토큰을 재사용할 수 없습니다. 각 소스에서 먼저 할당량 요약 엔드포인트(언어 서버의
`RetrieveUserQuotaSummary`, Cloud Code의 `v1internal:retrieveUserQuotaSummary`)를 요청합니다.
병합된 풀과 주간 기간을 보고하는 유일한 엔드포인트입니다. 이 엔드포인트가 없는 빌드는 레거시
모델별 엔드포인트(로컬에서는 `GetUserStatus` / `GetCommandModelConfigs`, 원격에서는
`fetchAvailableModels` / `retrieveUserQuota`)로 전환합니다. 이 경우 모델별 할당량을 각 풀에서
가장 낮은 잔여 비율을 기준으로 두 풀에 합칩니다. 이 엔드포인트들은 5시간 기간만 제공합니다.
요금제 이름은 상속된 Windsurf 요금제 필드보다 Antigravity 자체의 `userTier`를 우선합니다.

> 앱과 언어 서버 바이너리를 리버스 엔지니어링한 결과이며, 엔드포인트와 저장 방식은 예고 없이 변경될 수 있습니다.
