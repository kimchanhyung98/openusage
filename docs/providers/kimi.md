# Kimi

Kimi Code에 이미 로그인된 계정의 코딩 할당량 추적.

## 추적 항목

| 지표 | 의미 |
|---|---|
| Session | 5시간 순환 기간의 사용량과 초기화 시각 |
| Weekly | 7일 기간의 사용량과 초기화 시각 |

요금제 레이블은 Kimi 내부 멤버십 등급에 따라 공식 글로벌 요금제명 Adagio, Moderato, Allegretto, Allegro, Vivace 중 하나를 표시.
알 수 없는 등급도 읽기 쉬운 형태로 유지.
선택 사항인 booster wallet은 표시하지 않음.

## 상단 비용·토큰 통계

Kimi Code CLI의 로컬 사용 기록으로 Today·Yesterday·30 Days의 Tokens 집계.
현재 Mac의 로그 범위이며 계정 전체 사용량이나 Kimi 구독 청구 내역을 뜻하지 않음.
원격 할당량 조회 실패 시 기존 마지막 정상값 유지 및 새 토큰 집계 중단.
할당량 조회가 회복되면 로컬 토큰도 다시 집계.
Cost·Cost/MTok는 선택 기간의 모든 집계 대상 요청에서 모델과 캐시 과금 구분을 확인할 때만 제공.
하나라도 가격을 확인할 수 없으면 해당 기간의 전체 Tokens는 유지하고 비용만 생략.
누락 원인은 공급자 헤더의 경고로 표시하며 사용량이 0인 기록은 경고 대상에서 제외.
비용은 공통 가격 엔진으로 계산한 API 요율 추정값이며 구독료·실제 청구액이 아님.
할당량 비율·구독 quota 배수로 달러 환산하지 않음.
Kimi API 종량제와 Kimi Code 구독은 별도 상품이며 [공식 가격 안내](https://platform.kimi.ai/docs/pricing/chat) 참조.

이력 경로는 `$KIMI_CODE_HOME/sessions/<workspaceId>/<sessionId>/agents/<agentId>/wire.jsonl`.
홈 미설정 시 `~/.kimi-code` 사용.
[공식 데이터 위치](https://github.com/MoonshotAI/kimi-code/blob/a2afdbc7d1fa0737d45d5780cc6c2bd38e477b55/docs/en/configuration/data-locations.md) 기준으로 main·subagent 기록 모두 확인.
요청별 `usage.record`의 일반 입력·캐시 읽기·캐시 쓰기·출력 토큰을 각각 한 번 합산.
`time`의 밀리초 시각을 Mac의 로컬 날짜로 나누고 오늘과 이전 30일 포함.
원격 할당량 응답을 받은 스냅샷 시각으로 Today·Yesterday와 집계 종료 시각 결정.
현재 시각 이후의 기록은 제외.

`kimi-code/` 모델 별칭과 같은 agent의 `llm.request`를 연결하고 아래 명시 모델 ID 또는 `kimi-`로 시작하는 요청만 포함.
일반 요청(`kind: loop`)은 `usageScope: turn`, 백그라운드 압축 요청(`kind: compaction`)은 `usageScope: session`과 연결.
두 요청이 동시에 진행돼도 모델·thinking 설정을 서로 섞지 않음.
요청 종류·사용 범위가 없거나 알 수 없는 기록은 직전 요청의 별칭·모델을 확인해 Tokens만 유지.
다른 공급자 별칭과 GPT·Claude 등을 가리키는 요청은 제외.
별칭은 사용자 설정으로 변경 가능하며 로그에 API 호스트·인증 출처가 없어 실제 구독 계정까지 판별할 수 없음.
현재 설정으로 과거 기록을 다시 귀속하지 않음.

[공식 모델·라우팅 표](https://www.kimi.com/code/docs/en/kimi-code/models.html)에 따른 제한된 가격 대응:

| 요청 모델 ID | 공통 가격 모델 |
|---|---|
| `k3`, `k3-256k` | `kimi-k3` |
| `k3.1-pro` | `kimi-k3.1-pro` |
| `k3.1-pro-highspeed` | `kimi-k3.1-pro-highspeed` |

요청 기록의 `thinkingEffort`가 `on`·`low`·`high`·`max`로 명시된 경우만 가격 계산.
요청 ID는 대소문자를 포함해 정확히 일치해야 하며 캐시 읽기가 있으면 명시된 캐시 읽기 단가도 필요.
thinking이 꺼진 K3 요청은 다른 모델로 처리될 수 있으므로 원래 요청 이름으로 가격을 계산하지 않음.
thinking 기록 누락·알 수 없는 값·변경 가능한 `kimi-for-coding` 계열은 Tokens만 유지.
가격표 이름인 `kimi-k3`를 Code 요청 ID로 보낸 기록도 공식 Code ID 대응을 우회하지 않음.

[공식 캐시 계약](https://platform.kimi.ai/docs/guide/context-caching)은 5분·1시간 캐시 쓰기를 구분하지만 CLI 정규화 기록은 이 구분을 보존하지 않음.
Anthropic 프로토콜은 `inputCacheCreation`이 0일 때만 가격 계산.
OpenAI·Responses 프로토콜은 캐시 쓰기가 일반 입력에 포함될 수 있어 `inputOther`와 `inputCacheCreation`이 모두 0일 때만 가격 계산.
OpenAI·Responses의 [캐시 읽기 필드가 없는 기록](https://github.com/MoonshotAI/kimi-code/blob/444c609e8e6629d43fb7fd571a8db48ce5a41570/packages/agent-core-v2/src/human/llm/builtin/protocol/openai/decode.ts#L176-L188)은 `inputOther`에 전체 입력이 있으므로 Tokens만 집계.
캐시 읽기 필드 생략을 캐시 사용량 0으로 간주하여 비용을 계산하지 않음.
일반 사용 기록은 이 조건을 충족하지 않을 수 있으며, 이 경우 기간 전체 비용을 표시하지 않음.
로그 계약은 Kimi Code 소스 `a2afdbc7`의 [thinking 기록](https://github.com/MoonshotAI/kimi-code/blob/a2afdbc7d1fa0737d45d5780cc6c2bd38e477b55/packages/agent-core-v2/src/agent/loop/requester.ts#L736-L765), [OpenAI 토큰 변환](https://github.com/MoonshotAI/kimi-code/blob/a2afdbc7d1fa0737d45d5780cc6c2bd38e477b55/packages/agent-core-v2/src/human/llm/builtin/protocol/openai/decode.ts#L176-L187), [정규화 저장 전 처리](https://github.com/MoonshotAI/kimi-code/blob/a2afdbc7d1fa0737d45d5780cc6c2bd38e477b55/packages/agent-core-v2/src/human/llm/policy/settle.ts#L30-L36)와 대조.

세션 fork의 `forked` 표시 앞에 복사된 기록은 제외하여 원본과 중복 합산 방지.
원본을 삭제했다면 복사본에만 남은 이전 사용량은 누락 가능.
작성 중인 마지막 불완전 행은 다음 새로 고침에서 처리.
줄바꿈이 없는 마지막 행도 JSON이 완전하면 집계.
잘못된 완료 행은 제외 후 경고 표시하며 파일 읽기 실패도 경고로 표시.
구형 Python Kimi CLI 로그·내보낸 파일·백업 파일은 미지원.

## 인증 정보 출처

현재 Kimi Code 홈을 먼저 확인:

- `KIMI_CODE_HOME`이 설정된 경우 `$KIMI_CODE_HOME/credentials/kimi-code.json`
- 그 외에는 `~/.kimi-code/credentials/kimi-code.json`

현재 인증 파일이 없을 때만 레거시 경로인 `~/.kimi/credentials/kimi-code.json` 확인.
현재 파일의 읽기·형식 오류나 인증 만료 시 레거시 파일로 전환하지 않음.
현재 인증 파일의 토큰 갱신에는 갱신 토큰과 CLI의 OAuth 잠금 사용.
`KIMI_DISABLE_OAUTH_LOCK=1`이면 자동 갱신하지 않음.
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
