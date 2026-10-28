# 모델 가격

OpenUsage가 토큰 수를 지출 타일(Claude, Codex, Cursor, Grok)의 추정 달러로 환산하는 방식.
OpenRouter와 OpenCode는 예외 — OpenRouter는 API가 지출 금액을 보고하고, OpenCode는 로컬 로그에 메시지별 비용을 기록하므로 이 문서 내용이 적용되지 않음.

## 가격의 출처

가격은 세 출처를 계층으로 쌓아 쓰며, 같은 모델이 둘 이상에 있으면 상위 계층이 우선:

1. **OpenUsage 가격 보충 파일** — 이 포크에서 관리하고 `openusage.chanhyung.kim`에 게시하는 작은 JSON 파일.
   공개 카탈로그에 없는 모델, 공식 문서와 다른 기존 단가의 보정, Fast 배율, 장문 구간, 모델 별칭을 담당.
2. **LiteLLM** — 커뮤니티가 관리하는 `model_prices_and_context_window.json`으로, API 가격이 매겨진 모델 대부분을 포함.
3. **models.dev** — LiteLLM이 놓친 모델(예: 갓 출시된 모델이나 일부 틈새 모델)을 채우는 보완 출처.

앱은 세 출처의 스냅샷을 함께 넣어 배포하므로 오프라인에서도, 첫 실행에서도 가격 계산이 동작.
실행 중에는 마지막 성공 후 한 시간이 지나면 각 출처를 다시 확인하고(ETag 재검증), `~/Library/Application Support/OpenUsage/pricing/`에 캐시.
연결 실패 시 30분 뒤부터 재시도하며, 앱에서 가격을 읽을 때 갱신 시작.
새로 고침이 사용량 스캔을 막는 일은 없음 — 스캔은 그 시점에 이미 확보한 데이터로 가격을 계산하고 새 응답은 다음 조회부터 반영.

보충 파일은 앱에 포함된 사본과 같은 출처의 캐시 중 갱신일이 최신인 사본 사용.
따라서 앱 업데이트에 더 새로운 가격표가 포함됐다면 오프라인에서도 새 사본 사용.
날짜만 있는 값은 UTC 자정으로 비교하며, 날짜가 없거나 올바르지 않으면 날짜가 확인된 사본 우선.
갱신일이 같거나 양쪽 모두 확인할 수 없으면 캐시 우선.

이전 앱이 저장한 원본 프로젝트의 가격표나 출처를 확인할 수 없는 보충 파일 캐시는 사용하지 않고, 앱에 포함된 포크 가격표로 시작해 새 피드 확인.
LiteLLM·models.dev 캐시는 유지.
포크 피드를 읽는 앱으로 처음 전환할 때는 앱 업데이트 필요.
그 이후 가격표 게시·배포가 완료되면 실행 중인 온라인 앱의 다음 갱신에서 받아가므로 일반 가격 수정에는 별도 앱 업데이트 불필요.
이번 갱신은 `pricing_v2`·`alias_rules_v2` 확장에 포함되므로 앱 업데이트 필요.
새 앱은 v2 단가를 기존 단가 위에 병합하고 v2 별칭을 먼저 적용.
구버전 앱은 확장을 무시하고 기존 `pricing`·`alias_rules`를 계속 사용하므로 Cursor 요율이 API 할인으로 바뀌는 회귀 방지.
`fast_multipliers_exact`를 지원하는 앱은 o3·o4-mini의 새 Fast 배율을 피드 갱신으로 적용.
이 필드를 지원하지 않는 이전 버전은 배율 적용에도 앱 업데이트 필요.

## 모델 이름을 찾아가는 방식

Cursor CSV는 보충 파일의 `cursor/` 전용 항목과 별칭을 먼저 조회.
전용 요율이 없으면 아래 공통 조회 순서 사용.
모델별 내역도 Cursor 전용 별칭으로 묶되 내부 `cursor/` 접두사는 표시하지 않음.
예: Grok 4.5의 캐시 읽기는 Cursor 0.50달러, xAI API 0.30달러 / 100만 토큰으로 구분.

보충 파일에 별칭 규칙이 있으면 연결된 모델 이름으로 먼저 조회.
연결된 이름에서 가격을 찾지 못하면 원래 모델 이름으로 다시 조회.

속도 변형이 없는 모델은 다음 순서로 조회하며, 처음 찾은 가격 사용:

1. 보충 파일에서 모델 이름과 정확히 일치하는 가격 조회.
2. LiteLLM에서 모델 이름과 정확히 일치하는 가격 조회.
3. LiteLLM에서 유사한 모델 이름의 가격 조회.
4. models.dev에서 모델 이름과 정확히 일치하는 가격 조회.

LiteLLM의 유사 매칭은 프로바이더 접두사(`anthropic/`, `xai/` 등), 날짜 접미사(`claude-sonnet-4` ↔ `claude-sonnet-4-20250514`), 구분자 차이(`grok-4-3` ↔ `grok-4.3`)를 처리.
models.dev에는 유사 매칭 미적용.

Fast 변형도 보충 파일과 LiteLLM의 정확 일치 가격을 먼저 조회.
해당 가격이 없으면 `-fast`·`.fast`·`@fast` 접미사를 기본 모델 이름으로 해석한 뒤 모델별 Fast 배율 적용.
배율로 계산할 수 없으면 models.dev의 정확 일치 가격 조회.
어떤 출처에도 명시적 가격이 없고 모델별 배율로도 계산할 수 없으면 가격 미확정 처리.
이름에 속도 구간이 없는 모델의 유사 매칭에서 Fast·Ultrafast 전용 항목 제외 — 날짜·설명이 뒤따라도 이미 배율이 반영된 요금을 기본 요금으로 재사용하지 않음.
`grok-code-fast-1-0825`처럼 모델 이름 자체에 `fast`가 포함된 경우에는 프로바이더 접두사가 있는 해당 가격도 조회.
`.`·`@` 구분자를 `-`로 정규화한 이름에도 같은 fast 항목 구분 적용.
Fast·Ultrafast 구분자가 날짜(`-YYYYMMDD`·`-YYYY-MM-DD`) 바로 앞에 있어도 같은 규칙 적용.
말단·날짜 직전의 `FAST`·`Fast` 등 속도 표기도 같은 요금 적용 — 모델 본체의 대소문자는 유지.
Ultrafast 뒤에 추가 설명이 있거나 대소문자가 달라도 명시 단가가 없으면 일반 요금으로 유사 매칭하지 않음.
새 Fast 배율은 등록된 모델·별칭·날짜 변형에만 적용하며, 이름이 비슷한 Audio·Realtime·Search 모델로 상속하지 않음.
공통 가격 조회에서 기본 모델을 유사 매칭으로 찾았더라도, 요청한 모델이 새 배율의 등록 범위 밖이면 그 배율을 적용하지 않음.
GPT-5.4 Mini는 일반·Fast 모두 프로바이더 접두사·대소문자·날짜가 다른 등록 별칭을 같은 모델 내역으로 표시.

어떤 출처로도 가격을 매길 수 없는 모델은 지출 수치에서 아예 제외 — 그 토큰은 그날 타일, Usage Trend, 모델별 내역에 포함되지 않으며, 일부를 빠뜨린 달러 금액 옆에 전체 토큰 수를 붙이면 오해를 부르기 때문.
대신 해당 타일의 경고 삼각형이 가격 미확정 모델을 나열하므로, 수치가 불완전하다는 사실과 그 원인 모델을 파악 가능.
그날 *아무것도* 가격을 매길 수 없었다면 "No data"(데이터 없음)로 표시.

## 추정치에 포함되는 것

비용은 사용 이벤트별로 네 가지 토큰 묶음 — 일반 입력, 캐시 쓰기, 캐시 읽기, 출력 — 에 모델의 백만 토큰당 요금을 적용해 계산하며, 1시간 캐시 쓰기 가격, 긴 컨텍스트 구간, fast 변형 배율까지 반영.
Claude 로그는 기본 모델명을 그대로 두고 요청의 `speed` 필드로 fast 모드를 표시할 수 있으므로, `-fast` 별칭뿐 아니라 기본 항목도 그 배율을 함께 가짐.
대부분의 카탈로그 구간은 프롬프트 토큰 200k 초과부터 시작하고, GPT-5.4·GPT-5.5와 해당 Pro 모델, GPT-5.6 Sol·Terra·Luna, GPT-6 Astra·Sol·Luna, GPT-6.1 Sol·Terra의 Codex 요청은 입력 토큰 272k 초과에서 전환.
Codex 로그와 pi의 Codex 추정에는 같은 요청별 규칙을 사용하며, 일반 입력과 캐시 읽기·쓰기를 합친 수로 구간 판정.
Codex 로그는 한 번의 집계 안에서 같은 가격 산정용 모델 이름·Ultrafast 구분의 요율 해석 결과를 재사용하며, 가격 미확정 결과도 포함.
토큰 수·Fast 요청 여부·장문 요금 구간은 이벤트마다 계산.
집계가 끝나면 해석 결과를 폐기하므로, 다음 집계는 그때 확보한 가격표로 다시 결정.
해당 Codex 장문 구간은 현재 기본 단가의 입력·캐시 2배, 출력 1.5배로 계산하므로 기본 단가 갱신도 함께 반영.
GPT-6 Astra와 GPT-6.1 Sol의 Ultrafast는 별도 공개 단가 사용 — 일반 요금의 6배이며 Fast 배율 중복 적용 없음.
Codex의 `ultrafast-fast`처럼 두 속도를 결합한 모델 이름은 가격 미확정 처리.
Codex 로그의 `thread_settings_applied.service_tier` 또는 그 안의 `thread_settings.service_tier`가 `ultrafast`이면 해당 요금 적용.
같은 시각·모델·토큰 수라도 Standard·Fast·Ultrafast 이벤트는 구분하여 집계하고, 같은 티어의 동일 사본만 중복 제거.
모델 이름의 `-ultrafast`·`.ultrafast`·`@ultrafast` 표기도 지원하며, 공개 가격이 없는 Ultrafast 모델은 가격 미확정 처리.
기존 Codex 스캔 캐시는 새 버전에서 다시 파싱하여 과거 로그의 Ultrafast 구분 복원.
pi에 양수 메시지 비용이 있으면 그대로 사용하고, 0이거나 없을 때만 추정.
Claude Haiku 5.5는 입력·캐시 합계 100k 초과 시 요청 전체 5배.
Grok의 API 장문 구간은 200k 초과, Cursor Grok 4.7은 256k 초과로 구분.
Grok 4.7 Fast 장문 요금은 일반 기본 단가의 3배로, Fast 기본 단가의 2배가 아님.
xAI 공식 표의 `≥200k`와 모델 설명의 `>200k`가 달라 정확히 200k에서는 기존 초과 판정 유지.
어느 경우든 높은 요금은 요청 전체에 적용.
공개된 캐시 할인이 있으면 사용하고, 출처가 할인을 게시하지 않으면 Codex 캐시 입력은 전체 입력 요금으로 폴백.
Cursor의 내보내기는 여러 요청을 한 행에 합치므로, 그중 하나가 한도를 넘었다고 추측하지 않고 일반 요금을 사용.
Claude 로그 줄에 `costUSD`가 명시돼 있으면 유효한 비음수 비용만 사용 — 잘못된 비용은 해당 사용량과 함께 제외 및 경고.
중첩된 Claude advisor 사용량은 전달받은 비용이 없으므로, advisor 모델을 써서 그 토큰으로 따로 가격을 계산.
결과는 청구서가 아니라 API 요금 기준의 추정 가치 — 구독 요금제는 토큰 단위로 청구하지 않음.
Batch·Flex 할인과 지역 처리 10% 할증은 현재 수집 로그로 판별하지 않으므로 추정값에 미반영.
OpenAI의 12시간 캐시 쓰기도 로그에서 보존 시간을 식별할 수 없어 미반영.
Cursor의 팀별 Token Rate 추가료·라우팅 모드·500k 창 선택만으로 실제 장문 요청 여부를 추측하지 않음.
DeepSeek의 Cursor 요율은 Cursor 공식 표를 사용하며, 직영 API의 시간대별 할인은 적용하지 않음.
과거 로그도 현재 확보한 가격으로 다시 계산하므로, 가격 갱신이 지난 날짜의 추정값을 바꿀 수 있음.

## 2026-10-28 공식 가격 갱신

지원 provider 12개와 관련 모델의 공식 문서 대조 결과는 [가격 조사 기록](/docs/research/pricing-2026-10-28.md)에 정리.
커뮤니티 카탈로그 전체를 다시 내려받지 않고, 공식 문서로 확인한 누락·차이만 보충 파일에 반영.

- OpenAI: GPT-6.1 Terra, Sol Ultrafast, Rosalind Research·Discovery 추가 및 o3·o4-mini Fast 배율 보완.
- Claude: Opus·Sonnet·Haiku 5.5와 Mythos 5.1 추가, Sonnet 5 인하 단가 반영.
- Grok: 4.7·Fast와 요청별 장문 구간 추가, 4.20 인하 단가·4.5 API 캐시 할인 반영.
- Google: Gemini 4 Argon·3.8 Flash 등 추가, API 할인과 Cursor의 3.5·3.6 요율 분리.
- Kimi·Z.ai·Meta: K3.1 Pro·Highspeed, GLM 5.3 Flash 계열, Muse Wonder 추가.

기존 사용 기록이 참조하는 모델은 유지.
현행 공식 표에서 단가를 다시 확인할 수 없는 Auto·Composer 1/1.5/2·Bugbot의 기존 값도 보존하며, 최신 확인 완료로 간주하지 않음.
GPT-5.6 Sol 할인은 최소 2026-11-21까지, Gemini 4 Argon은 2026-11-30까지, Gemini 3.6·3.8 Flash는 2026-12-31까지로 공표.
만료 후에는 공식 표를 다시 확인해 갱신 필요.

## 개인정보 보호

가격 새로 고침은 공개 가격 목록 세 개를 가져옴(`raw.githubusercontent.com`, `models.dev`, `openusage.chanhyung.kim`).
가격 조회 요청에는 사용량이나 로그 데이터를 포함하지 않음.
[iCloud 사용량 동기화](/docs/icloud-sync.md)는 별도 설정에 따라 동작.

## 유지 관리자 노트

릴리스·가격표·사이트 게시 작업은 같은 대기열에서 한 번에 하나씩 실행.
[GitHub Actions 대기열](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency)의 `queue: max`와 `cancel-in-progress: false`를 세 게시 workflow에 함께 적용해, 새 사이트 게시가 대기 중인 가격표나 릴리스를 취소하지 않도록 보존.
대기는 최대 100개이며 도착 순서가 배포 버전 순서를 보장하지는 않으므로, 게시·후속 Pages 배포의 실패 및 취소 여부 확인 필요.

- **보충 파일 변경**(새 모델, 가격 수정, 새 별칭): `Sources/OpenUsage/Resources/pricing_supplement.json`을 편집하고, Cursor 전용 항목은 [Cursor 모델 및 가격](https://cursor.com/docs/models-and-pricing.md), OpenAI 항목은 [OpenAI API 가격](https://developers.openai.com/api/docs/pricing)에서 동기화한 뒤 `updated_at` 갱신.
  신규 Fast 배율은 `fast_multipliers_exact`에 등록하고, 구버전의 넓은 이름 매칭을 사용하는 `fast_multipliers`는 유지.
  장문·공급 경로별 처리가 필요한 값과 새 단가는 `pricing_v2`·`alias_rules_v2`에 등록.
  기존 `pricing`·`alias_rules`는 구버전 앱이 계속 읽으므로 호환성을 확인하지 않고 변경하지 않음.
  게시 시 `pricing`·`pricing_v2`의 기본 입력·출력 단가는 유한한 비음수 필수이며 불리언은 거부.
  기본 캐시 쓰기·읽기 단가는 누락·`null`을 허용하되, 값이 있으면 같은 조건으로 검증.
  장문 요율은 선택적 `long_context` 객체의 `threshold_tokens`와 입력·출력·캐시 쓰기·읽기 네 단가로 등록.
  경계는 양의 정수, 단가는 유한한 비음수 필수이며 잘못된 장문 객체는 로딩·게시 단계에서 거부.
  Cursor 전용 단가는 `cursor/` 키와 전용 별칭으로 등록하고, 공급자의 API 단가와 별도로 검증.
  새 게시 파일의 `updated_at`은 실제로 유효한 UTC 날짜·시각 `YYYY-MM-DDTHH:MM:SSZ` 형식 필수.
  `main` 병합 후 가격표 게시와 Pages 배포가 완료되면 포크 피드를 읽는 앱의 다음 갱신에서 반영.
  번들 사본은 첫 실행을 위해 다음 릴리스에 포함.
  **pricing-update skill**(`.agents/skills/pricing-update/`)은 에이전트가 동기화 전 과정(Cursor 페이지 가져오기, diff, 편집, 검증, PR 열기)을 따라가도록 안내.
- **번들 스냅샷**(`pricing_litellm_snapshot.json`, `pricing_models_dev_snapshot.json`): 가끔(예: 릴리스 전) `script/update_pricing_snapshots.sh`로 재생성.
  온라인 갱신에 성공하면 받은 가격을 다음 조회부터 사용.
  갱신 전이나 갱신 실패 시에는 번들·캐시의 기존 가격 사용.
  오래된 번들 가격이 추정값에 영향을 줄 수 있으므로 릴리스 전 갱신 여부 확인.
