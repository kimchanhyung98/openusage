# Z.ai

코딩 구독용 [Z.ai](https://z.ai)(Zhipu AI) GLM Coding Plan 사용량 한도 추적.

## 추적 항목

| 지표 | 의미 |
|---|---|
| Session | 5시간 순환 기간의 토큰 사용량(백분율) |
| Weekly | 7일 순환 기간의 토큰 사용량(백분율) |
| Web Searches | 월간 웹 검색 / 웹 리더 / Zread 호출 횟수(사용 / 한도) |

Z.ai가 요금제 이름을 반환하면 프로바이더 이름 옆에 표시.

## 인증 정보 출처

Z.ai에는 OpenUsage가 인증 정보를 재사용할 수 있는 연동 CLI나 앱이 없어 API 키를 직접 제공해야 함.
다음 순서에서 처음 찾은 키 사용:

1. `~/.config/openusage/zai.json` — `{"apiKey":"…"}`(Settings에서 쓰는 파일)
2. `~/.config/zai/key.json`
3. `ZAI_API_KEY` 환경 변수
4. `GLM_API_KEY` 환경 변수(레거시 Zhipu 이름도 계속 지원)

파일을 직접 편집하지 않고 **Settings → API Keys**에서 키를 추가하거나 교체 가능.
어느 방법이든 Z.ai 자체 구독 UI와 동일한 API 호출 외에는 Mac 밖으로 데이터를 전송하지 않음.

## 설정

1. [GLM Coding 요금제를 구독](https://z.ai/subscribe)하고 [Z.ai 콘솔](https://z.ai/manage-apikey/apikey-list)에서 API 키 발급.
2. **Settings → API Keys**에서 OpenUsage에 키를 추가하거나 다음과 같이 내보내기:

```bash
export ZAI_API_KEY="YOUR_API_KEY"
```

3. 다음 새로 고침부터 대시보드에 Z.ai가 나타나며, 지표에 별표를 지정한 뒤에는 메뉴 막대에도 표시.

## 내부 동작

Z.ai 자체 구독 UI가 사용하는 문서화되지 않은 내부 엔드포인트 두 개 사용(실제로 안정적으로 동작):

- `GET https://api.z.ai/api/biz/subscription/list` — 요금제 이름(가능한 범위에서 조회하며, 이 호출이 실패해도 미터는 비워지지 않음).
- `GET https://api.z.ai/api/monitor/usage/quota/limit` — 할당량 미터.

할당량 응답에 `limits` 배열 포함.
각 `TOKENS_LIMIT` 항목은 토큰 사용 기간으로 길이에 따라 반영할 미터가 정해지며(하루 미만 → Session, 여러 날 → Weekly), `TIME_LIMIT` 항목은 월간 웹 검색 횟수.
초기화 시각은 epoch 밀리초로 반환.
필수 사용량 값이 누락되면 0으로 표시하지 않고 유효하지 않은 응답으로 보고.

## 문제 해결

- **"No Z.ai API key"** — Settings → API Keys에서 키를 추가하거나 `ZAI_API_KEY` 환경 변수 내보내기.
- **"Z.ai API key invalid"** — 키 거부(401/403).
  [Z.ai 콘솔](https://z.ai/manage-apikey/apikey-list)에서 다시 생성.
- **"No active GLM Coding Plan"**(이름 옆 황색 안내) — 키는 유효하지만 계정에 GLM Coding Plan이 없어 측정할 항목이 없는 상태.
  [z.ai/subscribe](https://z.ai/subscribe)에서 구독하면 요금제 활성화 후 사용량 표시.
- **미터에 "No usage data" 표시** — 요금제가 있지만 할당량 엔드포인트에서 아직 사용 가능한 한도를 반환하지 않은 상태.
  [요금제](https://z.ai/manage-apikey/coding-plan/personal/my-plan) 확인.
