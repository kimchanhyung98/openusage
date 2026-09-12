# 모델 가격

OpenUsage가 토큰 수를 지출 타일(Claude, Codex, Cursor, Grok)의 추정 달러로 환산하는 방식.
OpenRouter와 OpenCode는 예외 — OpenRouter는 API가 청구 금액을 직접 보고하고, OpenCode는 로컬 로그에 메시지별 비용을 직접 기록하므로 이 문서 내용이 적용되지 않음.

## 가격의 출처

가격은 세 출처를 계층으로 쌓아 쓰며, 같은 모델이 둘 이상에 있으면 상위 계층이 우선:

1. **OpenUsage 가격 보충 파일** — 이 저장소에서 관리하고 GitHub Pages에 게시하는 작은 JSON 파일.
   공개 카탈로그에 없는 모델(`auto`, `composer-*` 같은 Cursor 전용 모델), fast 변형 배율, 프로바이더 로그/CSV 슬러그를 카탈로그 키로 연결하는 별칭 규칙을 담당.
2. **LiteLLM** — 커뮤니티가 관리하는 `model_prices_and_context_window.json`으로, API 가격이 매겨진 모델 대부분을 포함.
3. **models.dev** — LiteLLM이 놓친 모델(예: 갓 출시된 모델이나 일부 틈새 모델)을 채우는 보완 출처.

앱은 세 출처의 스냅샷을 함께 넣어 배포하므로 오프라인에서도, 첫 실행에서도 가격 계산이 동작.
실행 중에는 각 출처를 약 한 시간마다 다시 가져오고(ETag 재검증), `~/Library/Application Support/OpenUsage/pricing/`에 캐시.
새로 고침이 사용량 스캔을 막는 일은 없음 — 스캔은 항상 그 시점에 이미 확보한 가장 최신 데이터로 가격을 계산.

보충 파일은 병합될 때 GitHub Pages에 게시되므로, 가격 수정은 앱 업데이트 없이 약 한 시간 안에 설치된 앱에 도달.

## 모델 이름을 찾아가는 방식

로그와 CSV의 모델 이름이 카탈로그 키와 정확히 일치하는 경우는 드물어서, 다음 순서로 해석을 시도 — 보충 파일의 별칭 규칙, 키 정확 일치, fast 변형 처리(`-fast` 접미사는 기본 모델로 해석한 뒤 그 fast 배율 적용), 그다음 유사 매칭(프로바이더 접두사 `anthropic/`, `xai/` 등, 날짜 접미사 `claude-sonnet-4` ↔ `claude-sonnet-4-20250514`, 구분자 차이 `grok-4-3` ↔ `grok-4.3`).
명시적 가격이나 모델별 배율이 없는 fast 변형은 표준 속도 요금을 슬쩍 적용하는 대신 가격 미확정 상태로 남김.

어떤 출처로도 가격을 매길 수 없는 모델은 지출 수치에서 아예 제외 — 그 토큰은 그날 타일, Usage Trend, 모델별 내역에 포함되지 않으며, 일부를 빠뜨린 달러 금액 옆에 전체 토큰 수를 붙이면 오해를 부르기 때문.
대신 해당 타일의 경고 삼각형이 가격 미확정 모델을 나열하므로, 수치가 불완전하다는 사실과 그 원인 모델을 파악 가능.
그날 *아무것도* 가격을 매길 수 없었다면 "No data"(데이터 없음)로 표시.

## 추정치에 포함되는 것

비용은 사용 이벤트별로 네 가지 토큰 묶음 — 일반 입력, 캐시 쓰기, 캐시 읽기, 출력 — 에 모델의 백만 토큰당 요금을 적용해 계산하며, 1시간 캐시 쓰기 가격, 긴 컨텍스트 구간, fast 변형 배율까지 반영.
Claude 로그는 기본 모델명을 그대로 두고 요청의 `speed` 필드로 fast 모드를 표시할 수 있으므로, `-fast` 별칭뿐 아니라 기본 항목도 그 배율을 함께 가짐.
대부분의 카탈로그 구간은 프롬프트 토큰 200k 초과부터 시작하고, 지원되는 GPT-5.4, GPT-5.5, GPT-5.6 Codex 모델은 입력 토큰 272k 초과에서 전환.
어느 경우든 높은 요금은 요청 전체에 적용.
공개된 캐시 할인이 있으면 사용하고, 출처가 할인을 게시하지 않으면 Codex 캐시 입력은 전체 입력 요금으로 폴백.
Cursor의 내보내기는 여러 요청을 한 행에 합치므로, 그중 하나가 한도를 넘었다고 추측하지 않고 일반 요금을 사용.
Claude 로그 줄에 `costUSD`가 명시돼 있으면 그 값을 그대로 사용.
중첩된 Claude advisor 사용량은 전달받은 비용이 없으므로, advisor 모델을 써서 그 토큰으로 따로 가격을 계산.
결과는 청구서가 아니라 API 요금 기준의 추정 가치 — 구독 요금제는 토큰 단위로 청구하지 않음.

## 개인정보 보호

가격 새로 고침은 공개 가격 목록 세 개를 가져옴(`raw.githubusercontent.com`, `models.dev`, 이 저장소의 GitHub Pages).
이 요청에는 사용량이나 로그 데이터가 실리지 않음 — 사용량에 관한 어떤 것도 Mac을 떠나지 않음.

## 유지 관리자 노트

- **보충 파일 변경**(새 모델, 가격 수정, 새 별칭): `Sources/OpenUsage/Resources/pricing_supplement.json`을 편집하고, Cursor 전용 항목은 [Cursor 모델 및 가격](https://cursor.com/docs/models-and-pricing.md), OpenAI 항목은 [OpenAI API 가격](https://developers.openai.com/api/docs/pricing)에서 동기화한 뒤 `updated_at` 갱신.
  `main`에 병합되면 `.github/workflows/pricing-supplement.yml`이 gh-pages에 게시하고, 설치된 앱은 약 한 시간 안에 이를 받아감.
  번들 사본은 첫 실행을 위해 다음 릴리스에 포함.
  **pricing-update skill**(`.agents/skills/pricing-update/`)은 에이전트가 동기화 전 과정(Cursor 페이지 가져오기, diff, 편집, 검증, PR 열기)을 따라가도록 안내.
- **번들 스냅샷**(`pricing_litellm_snapshot.json`, `pricing_models_dev_snapshot.json`): 가끔(예: 릴리스 전) `script/update_pricing_snapshots.sh`로 재생성.
  오래돼도 무해 — 런타임 가져오기가 덮어씀.
