# Z.ai

코딩 구독용 [Z.ai](https://z.ai)(Zhipu AI) GLM Coding Plan의 사용량과 할당량을 보여 줍니다.

## 추적 항목

| 지표 | 의미 |
|---|---|
| Session | 5시간 순환 기간의 토큰 사용량(백분율) |
| Weekly | 7일 순환 기간의 토큰 사용량(백분율) |
| Web Searches | 월간 웹 검색 / 웹 리더 / Zread 호출 횟수(사용 / 한도) |

Z.ai가 요금제 이름을 보고하면 OpenUsage가 프로바이더 이름 옆에 표시합니다.

## 인증 정보 출처

Z.ai에는 OpenUsage가 인증 정보를 재사용할 수 있는 연동 CLI나 앱이 없으므로 API 키를 직접 제공해야 합니다.
OpenUsage는 아래 순서로 확인해 가장 먼저 찾은 키를 사용합니다:

1. `~/.config/openusage/zai.json` — `{"apiKey":"…"}` (설정이 쓰는 파일)
2. `~/.config/zai/key.json`
3. `ZAI_API_KEY` 환경 변수
4. `GLM_API_KEY` 환경 변수(레거시 Zhipu 이름, 계속 지원됨)

파일을 직접 편집하지 않고 **Settings → API Keys**(설정 → API 키)에서 키를 추가하거나 교체할 수도 있습니다.
어느 방법을 사용하든 Z.ai 자체 구독 UI가 수행하는 것과 같은 API 호출 외에는 Mac 밖으로 정보가 나가지 않습니다.

## 설정

1. [GLM Coding 요금제를 구독](https://z.ai/subscribe)하고 [Z.ai 콘솔](https://z.ai/manage-apikey/apikey-list)에서 API 키를 발급받으세요.
2. **Settings → API Keys**로 키를 추가하거나, 셸에서 다음처럼 내보내세요:

```bash
export ZAI_API_KEY="YOUR_API_KEY"
```

3. 다음 새로 고침부터 Z.ai가 대시보드에 표시됩니다. 지표에 별표를 지정하면 메뉴 막대에도 표시됩니다.

## 내부 동작

Z.ai 자체 구독 UI가 사용하는 비공식 내부 엔드포인트 두 개를 사용합니다(현재는 안정적으로 동작합니다):

- `GET https://api.z.ai/api/biz/subscription/list` — 요금제 이름(가능한 범위에서 가져오며, 이 호출이 실패해도 미터는 비워지지 않음).
- `GET https://api.z.ai/api/monitor/usage/quota/limit` — 할당량 미터.

할당량 응답에는 `limits` 배열이 포함됩니다. 각 `TOKENS_LIMIT` 항목은 토큰 사용 기간이며, 기간 길이가 어느 미터에 반영될지를 결정합니다(하루 미만 → Session, 여러 날 → Weekly). `TIME_LIMIT` 항목은 월간 웹 검색 횟수입니다. 초기화 시각은 epoch 밀리초로 반환됩니다. 필수 사용량 값이 누락된 경우 0으로 표시하는 대신 유효하지 않은 응답으로 보고합니다.

## 문제 해결

- **"No Z.ai API key"**(Z.ai API 키 없음) — Settings → API Keys에서 키를 추가하거나 `ZAI_API_KEY`를 export하세요.
- **"Z.ai API key invalid"**(Z.ai API 키가 유효하지 않음) — 키가 거부되었습니다(401/403). [Z.ai 콘솔](https://z.ai/manage-apikey/apikey-list)에서 키를 다시 생성하세요.
- **"No active GLM Coding Plan"**(활성 GLM Coding Plan 없음)(이름 옆의 황색 안내) — 키는 유효하지만 계정에 GLM Coding Plan이 없어 측정할 것이 없습니다. [z.ai/subscribe](https://z.ai/subscribe)에서 구독하세요. 요금제가 활성화되면 사용량이 표시됩니다.
- **미터에 "No usage data" 표시** — 요금제는 있지만 할당량 엔드포인트가 아직 사용 가능한 한도를 반환하지 않았습니다. [요금제](https://z.ai/manage-apikey/coding-plan/personal/my-plan)를 확인하세요.
