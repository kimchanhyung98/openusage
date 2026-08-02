# Copilot

Copilot 도구가 Mac에 남겨 둔 GitHub 토큰을 사용해 GitHub Copilot 할당량을 보여 줍니다.
별도의 로그인 절차나 브라우저 쿠키는 필요하지 않습니다.

## 추적 항목

| 지표 | 의미 |
|---|---|
| Credits | 월간 AI 크레딧 할당량 중 사용한 비율(대표 미터) |
| Extra Usage | 추가 지출이 활성화된 후 포함 크레딧을 초과해 사용한 프리미엄 인터랙션 |
| Org Credits | 조직 전체가 이번 달에 사용한 AI 크레딧(조직 관리 Business/Enterprise 시트) |
| Org Spend | 포함 풀을 초과한 AI 크레딧에 대해 조직에 청구된 달러 금액 |
| Chat | 사용한 채팅 메시지 할당량 |
| Completions | 사용한 코드 완성 할당량 |

Credits와 Extra Usage는 기본적으로 항상 표시이고, Org Credits, Org Spend, Chat, Completions는 카드 캐럿 뒤의 필요 시 표시로 시작합니다. 각 미터는 사용 백분율과, 응답에 포함된 경우 다음 재설정까지의 카운트다운을 보여 줍니다. 요금제 이름(Pro, Business, Free, …)은 프로바이더 옆에 표시됩니다.

2026년 6월부터 GitHub Copilot은 모든 요금제를 **AI 크레딧**으로 청구하므로, 각 계정에 표시되는 내용은 요금제에 따라 다릅니다:

- **유료 요금제**는 크레딧 풀을 계량합니다 — 따라서 Credits가 표시되고(추가 지출을 켰다면 Extra Usage도). 유료 요금제에서 채팅과 완성은 무제한이므로 그 행들은 "No data"로 표시됩니다.
- **무료 요금제**는 크레딧이 없으므로 Credits가 "No data"로 표시되며, 대신 고정된 Chat과 Completions 개수가 캐럿 아래에 표시됩니다.
- **조직이 관리하는 좌석(조직이 할당한 Copilot Business / Enterprise)**은 좌석별 할당량을 반환하지 않으므로 개인 미터에 표시할 값이 없습니다. 이때 OpenUsage는 조직 청구 정보에서 사용량을 조회합니다. 조직을 나열한 뒤 Copilot AI 크레딧 사용량을 보고하는 조직을 찾아 **Org Credits**(이번 달 조직 전체 사용 크레딧)와 **Org Spend**(포함 풀을 초과해 조직에 청구된 금액)를 보여 줍니다. 주의할 점은 두 가지입니다:
  - 숫자는 개인 몫이 아니라 **조직 전체** 수치입니다 — GitHub은 좌석별 사용량을 공개하지 않습니다.
  - 조직 청구 정보를 읽으려면 **조직 소유자 또는 청구 관리자**여야 합니다. 일반 멤버는 기존과 같이 요금제만 표시되고 미터는 "No data"로 표시됩니다.
- Org Credits는 백분율이 아닌 단순 개수로 표시됩니다: 빌링 API는 사용량만 보고하고 조직의 크레딧 할당량은 절대 보고하지 않으며, OpenUsage는 분모를 꾸며내지 않습니다.

달러 크레딧 수치(예: "$12 of $15 used")는 표시되지 않습니다: GitHub은 그것을 로그인된 웹 빌링 페이지를 통해서만 공개하며, 그러려면 브라우저 쿠키를 읽어야 합니다 — OpenUsage는 그렇게 하지 않습니다. VS Code 같은 에디터도 이 엔드포인트에서 달러 금액이 아닌 같은 크레딧 *백분율*을 보여 줍니다.

## 인증 정보 출처

다음 순서로 확인합니다(사용자 확인이 필요 없는 파일을 먼저 보고, 키체인은 마지막에 확인):

1. Copilot 에디터 토큰: `~/.config/github-copilot/apps.json`(이전 `hosts.json`) — VS Code / JetBrains / Neovim Copilot 플러그인이 기록합니다.
2. GitHub CLI 설정: `~/.config/gh/hosts.yml`(`oauth_token`) — `gh`가 토큰을 파일에 저장하는 경우.
3. GitHub CLI 키체인 항목(서비스 `gh:github.com`) — `gh`가 토큰을 시스템 키링에 저장하는 경우.

### 설정

사용량이 나타나지 않으면 GitHub CLI로 인증하세요:

```bash
brew install gh   # if needed
gh auth login     # choose GitHub.com and follow the prompts
```

지원되는 에디터에서 Copilot을 사용하기만 해도 됩니다. 에디터가 토큰을 `apps.json`에 기록합니다.

## 문제 해결

- **"Sign in to GitHub Copilot…"** — 토큰을 찾지 못했습니다. 에디터에서 Copilot에 로그인하거나 `gh auth login`을 실행하세요.
- **"GitHub token invalid or expired"** — 토큰이 거부되었습니다(401/403). `gh auth login`으로 다시 인증하세요.
- **미터에 "No data"가 표시되지만 요금제는 표시됨** — 조직 관리 Copilot Business/Enterprise 시트에서 조직의 소유자나 빌링 관리자가 아닐 때 예상되는 동작입니다(GitHub은 시트별 할당량을 공개하지 않고 조직 빌링은 관리자 전용). 조직 관리자인데도 Org Credits가 보이지 않으면 토큰이 조직을 나열할 수 있는지 확인하세요 — `gh auth login`으로 받은 GitHub CLI 토큰은 가능하지만 일부 에디터 플러그인 토큰은 불가능합니다.

## 내부 동작

표준 Copilot 클라이언트 헤더(API 버전 `2025-04-01`)로 `GET https://api.github.com/copilot_internal/user`를 호출합니다. 응답은 각 버킷을 *남은* 백분율로 보고하며, 미터는 *사용한* 백분율을 보여 줍니다.

조직 관리 시트(해당 응답의 토큰 기반 빌링 플레이스홀더로 식별)의 경우 프로바이더는 공개 REST 빌링 API를 추가로 호출합니다: `GET /user/orgs`로 조직을 나열한 다음 조직마다 `GET /orgs/{org}/settings/billing/usage/summary`를 호출해 Copilot AI 크레딧 사용량을 보고하는 조직을 찾습니다. 일치하는 조직은 기억되므로 정상 상태 새로 고침에서는 추가 호출 한 번만 이루어집니다. 응답하지 않게 되면 자동으로 다시 검색됩니다.
