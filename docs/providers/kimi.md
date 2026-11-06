# Kimi

Kimi Code에 이미 로그인된 계정의 코딩 할당량 추적.

## 추적 항목

| 지표 | 의미 |
|---|---|
| Session | 5시간 순환 기간의 사용량과 초기화 시각 |
| Weekly | 7일 기간의 사용량과 초기화 시각 |

[현재 할당량 응답](https://github.com/MoonshotAI/kimi-code/blob/df90d90ec0714db23dcc830acd2db6232f5c7426/packages/oauth/src/managed-usage.ts#L108-L136)의 `usages.limit_5h`·`usages.limit_7d`에서 `used_ratio`와 `reset_time` 사용.
구형 응답의 `limits`·`usage`도 지원.
월간 한도만 있는 응답은 기존 Session·Weekly 지표로 표시하지 않고 할당량 확인 오류로 처리.
`goods_version`으로 요금제 이름이나 새 지표를 추정하지 않음.
신규 요금제는 주간 한도가 없지만 Kimi·Kimi Code가 공유하는 월간 총한도는 유지.
Session 한도가 함께 있어도 월간 총한도는 현재 카드에 표시하지 않음.
월간 총한도 소진 시 초기화나 업그레이드 전까지 구독 사용 중단 가능.
Extra Usage를 활성화하고 사용 가능한 잔액이 있으면 추가 사용 가능.
조건과 확인 경로는 [공식 멤버십 안내](https://www.kimi.ai/help/kimi-code/benefits) 참조.

글로벌 신규 유료 요금제는 Plus·Pro·Max·Ultra이며, 중국에는 Kimi Code를 포함하지 않는 Go도 존재.
지역별 가격과 연간 결제액은 [구독 요금제](/docs/pricing.md#구독-요금제) 참조.
기존 구독은 이름·갱신·한도 유지 가능하므로, 이전 멤버십 등급의 Adagio·Moderato·Allegretto·Allegro·Vivace 매핑 유지.
알 수 없는 등급도 읽기 쉬운 형태로 유지.
선택 사항인 booster wallet은 표시하지 않음.

## 상단 비용·토큰 통계

Kimi Code CLI의 로컬 사용 기록으로 Today·Yesterday·30 Days의 Tokens 집계.
현재 Mac의 로그 범위이며 계정 전체 사용량이나 Kimi 구독 청구 내역을 뜻하지 않음.
원격 할당량 조회 실패 시 기존 마지막 정상값 유지 및 새 토큰 집계 중단.
할당량 조회가 회복되면 로컬 토큰도 다시 집계.
일부 이력 파일만 실패하면 확인된 사용량으로 갱신하고 경고 표시.
사용할 수 있는 기록 없이 이력 전체가 실패하면 같은 날짜의 마지막 정상 통계와 원래 통계 조회 시각 유지.
정상적으로 확인한 빈 이력은 빈 통계로 반영하며 전날 Today 값을 새 날짜에 재사용하지 않음.
Cost·Cost/MTok는 선택 기간의 모든 집계 대상 요청에서 모델과 캐시 과금 구분을 확인할 때만 제공.
하나라도 가격을 확인할 수 없으면 해당 기간의 전체 Tokens는 유지하고 비용만 생략.
모델·캐시 가격을 확인할 수 없는 원인은 진단 로그에만 기록하며 사용량이 0인 기록은 오류 진단에서 제외.
비용은 공통 가격 엔진으로 계산한 API 요율 추정값이며 구독료·실제 청구액이 아님.
할당량 비율·구독 quota 배수로 달러 환산하지 않음.
Kimi API 종량제와 Kimi Code 구독은 별도 상품이며 [공식 가격 안내](https://platform.kimi.ai/docs/pricing/chat) 참조.

이력 경로는 `$KIMI_CODE_HOME/sessions/<workspaceId>/<sessionId>/agents/<agentId>/wire.jsonl`.
홈 미설정 시 `~/.kimi-code` 사용.
로그인 셸에만 설정한 홈도 환경 캡처 후 조회하여 인증과 이력에 같은 홈 적용.
[공식 데이터 위치](https://github.com/MoonshotAI/kimi-code/blob/a2afdbc7d1fa0737d45d5780cc6c2bd38e477b55/docs/en/configuration/data-locations.md) 기준으로 main·subagent 기록 모두 확인.
요청별 `usage.record`의 일반 입력·캐시 읽기·캐시 쓰기·출력 토큰을 각각 한 번 합산.
`time`의 밀리초 시각을 Mac의 로컬 날짜로 나누고 오늘과 이전 30일 포함.
원격 할당량 응답을 받은 스냅샷 시각으로 Today·Yesterday와 집계 종료 시각 결정.
현재 시각 이후의 기록은 제외.

`kimi-code/` 모델 별칭과 같은 agent의 `llm.request`를 연결하고 아래 명시 모델 ID 또는 `kimi-`로 시작하는 요청만 포함.
일반 요청(`kind: loop`)은 `usageScope: turn`, 백그라운드 압축 요청(`kind: compaction`)은 `usageScope: session`과 연결.
두 요청이 동시에 진행돼도 모델·thinking 설정을 서로 섞지 않음.
완료 행의 JSON·`type`을 해석할 수 없거나 요청의 agent를 확인할 수 없으면 이전 요청 연결을 초기화.
다음 정상 요청 전까지 연결할 수 없는 사용량은 진단 로그에 기록한 뒤 제외하고, 이미 집계한 기록은 유지.
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
잘못된 완료 행은 제외 후 진단 로그에 기록하며 파일 읽기 실패는 카드 경고로 표시.
지원하지 않는 wire 형식은 파일 읽기 오류와 구분하여 앱 업데이트 확인 안내.
내보낸 파일·백업 파일은 자동 수집에서 제외.

Kimi Work의 `~/Library/Application Support/kimi-desktop/daimon-share/daimon/runtime/kimi-code/home/sessions/` 아래 `agents/*/wire.jsonl`도 수집.
[공식 Work 안내](https://www.kimi.ai/help/kimi-work/overview)는 Kimi Code 커널 사용만 확인 가능.
위 저장 경로·wire 형식·내장 커널 버전은 공식 공개 계약으로 확인하지 못한 최선 노력 범위.
직접 `conv-*/wire.jsonl`에 저장하는 구형 배치와 별도 프로필·사용자 지정 홈은 검증하지 않음.
Work 사용 기록에 `agentId`·`modelAlias`가 없어도 측정 토큰 유지.
일반 요청과 압축 요청의 `turn`·`session` 사용 범위를 모두 포함.
구형 Python CLI는 `$KIMI_SHARE_DIR/sessions` 또는 `~/.kimi/sessions`의 `StatusUpdate.token_usage` 수집.
같은 메시지의 반복 상태는 더 완전한 값 한 번만 반영하며 subagent 경로도 조회.
Python fork는 원본 wire를 복사하지만 원본 계보를 기록하지 않음.
서로 다른 세션의 같은 메시지 ID만으로 같은 호출을 확정할 수 없어 사본 토큰이 원본 수집 결과에 남을 수 있음.
[Python CLI는 여러 공급자를 지원](https://github.com/MoonshotAI/kimi-cli/blob/9ab1286b8fe4e6bcd116949a27ce5e0ac3389c82/docs/en/configuration/providers.md)하지만 `StatusUpdate`에는 모델·과금 공급자 정보가 없음.
측정된 원본 토큰은 보존하되 공급자를 확인할 수 없는 Python 기록은 Kimi 통계에 합산하지 않음.
현재 설정이나 인증 파일로 과거 기록의 공급자를 추정하지 않음.
Python 압축 사용량은 wire의 `StatusUpdate`에 기록되지 않을 수 있어 복원하지 않음.
Work·Python CLI의 모델 라우팅·캐시 가격은 현재 설정으로 추정하지 않음.
Work의 캐시 읽기 토큰이 없으면 입력 전체를 확인할 수 없으므로 원본의 확인된 토큰을 보존하고 일별 합계에서는 제외.
이 경우 불완전 이력으로 진단하며 카드 경고로 표시하지 않음.
보충 wire도 작성 중인 마지막 불완전 행은 보류하고 정상 행을 유지.
완료된 손상 행은 진단 로그에 남기고 해당 행만 제외.
`KIMI_CODE_HOME`이 Work 저장 홈을 가리키면 실제 파일 경로와 사용량 식별자가 같은 기록은 한 번만 집계.
native 파서가 실제로 집계한 행만 보충 집계에서 제외하며 같은 파일의 별칭 없는 Work 기록은 유지.

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
