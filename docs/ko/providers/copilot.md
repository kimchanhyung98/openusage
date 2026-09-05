# Copilot

Copilot 도구가 Mac에 남긴 GitHub 토큰으로 GitHub Copilot 할당량 추적.
별도 로그인 절차나 브라우저 쿠키 불필요.

## 추적 항목

| 지표 | 의미 |
|---|---|
| Credits | 월간 AI 크레딧 할당량 중 사용 비율(대표 미터) |
| Extra Usage | 추가 지출 활성화 후 기본 제공 크레딧을 초과해 사용한 프리미엄 인터랙션 |
| Org Credits | 조직 전체가 이번 달 사용한 AI 크레딧(조직 관리 Business/Enterprise 좌석) |
| Org Spend | 기본 제공분을 초과한 AI 크레딧으로 조직에 청구된 달러 금액 |
| Chat | 채팅 메시지 할당량 사용량 |
| Completions | 코드 완성 할당량 사용량 |

Credits와 Extra Usage는 기본적으로 Always Visible이며, Org Credits, Org Spend, Chat, Completions는 카드 캐럿 아래의 On Demand로 시작.
각 미터에는 사용 백분율과 응답에 포함된 경우 다음 재설정까지의 카운트다운 표시.
요금제 이름(Pro, Business, Free, …)은 프로바이더 옆에 표시.

2026년 6월부터 GitHub Copilot은 모든 요금제를 **AI 크레딧**으로 청구하므로 계정별 표시 내용은 요금제에 따라 다름.

- **유료 요금제**는 크레딧 풀 사용량을 집계하므로 Credits 표시(추가 지출을 켰으면 Extra Usage도 표시).
  유료 요금제의 Chat과 Completions는 무제한이므로 해당 행에는 "No data" 표시.
- **무료 요금제**는 크레딧이 없어 Credits에 "No data"를 표시하고, 대신 고정된 Chat과 Completions 개수를 캐럿 아래에 표시.
- **조직 관리 좌석(조직에서 할당한 Copilot Business / Enterprise)**은 좌석별 할당량을 반환하지 않아 개인 미터에 표시할 값 없음.
  이 경우 OpenUsage가 조직 청구 정보에서 사용량 조회: 조직 목록에서 Copilot AI 크레딧 사용량을 보고하는 조직을 찾아 **Org Credits**(이번 달 조직 전체 사용 크레딧)와 **Org Spend**(기본 제공분을 초과해 청구된 금액) 표시.
  두 가지 유의 사항:
  - 수치는 개인 몫이 아닌 **조직 전체** 사용량 — GitHub에서 좌석별 사용량 미제공.
  - 조직 청구 정보 조회에는 **조직 소유자 또는 청구 관리자** 권한 필요.
    일반 멤버는 기존과 같이 요금제만 표시되고 미터에는 "No data" 표시.
- Org Credits는 백분율이 아닌 단순 개수로 표시: 청구 API는 사용량만 보고하고 조직의 크레딧 할당량은 제공하지 않으므로 OpenUsage에서 분모를 임의 생성하지 않음.

달러 크레딧 수치(예: "$12 of $15 used")는 미표시: GitHub에서 로그인된 웹 청구 페이지를 통해서만 제공하며, 이를 읽으려면 브라우저 쿠키가 필요하므로 OpenUsage에서는 사용하지 않음.
VS Code 같은 편집기도 이 엔드포인트에서 달러 금액이 아닌 동일한 크레딧 *백분율* 표시.

## 인증 정보 출처

다음 순서로 확인(사용자 확인이 필요 없는 파일 우선, 키체인 마지막):

1. Copilot 편집기 토큰: `~/.config/github-copilot/apps.json`(이전 `hosts.json`) — VS Code / JetBrains / Neovim Copilot 플러그인에서 기록
2. GitHub CLI 설정: `~/.config/gh/hosts.yml`(`oauth_token`) — `gh`에서 토큰을 파일에 저장하는 경우
3. GitHub CLI 키체인 항목(서비스 `gh:github.com`) — `gh`에서 토큰을 시스템 키링에 저장하는 경우

### 설정

사용량이 표시되지 않으면 GitHub CLI로 인증:

```bash
brew install gh   # 필요한 경우
gh auth login     # GitHub.com 선택 후 안내에 따라 진행
```

지원되는 편집기에서 Copilot을 사용하면 편집기가 토큰을 `apps.json`에 기록하므로 별도 설정 불필요.

## 서비스 상태

Copilot이 활성화돼 있으면 실행 시, 5분마다, 대시보드 수동 새로 고침 시 [GitHub Status](https://www.githubstatus.com/)의 Copilot 컴포넌트 확인.
공개 요청은 인증 없이 실행되며 GitHub 인증 정보나 사용량 데이터를 보내지 않음.
해당 컴포넌트가 성능 저하, 부분 장애, 중대 장애를 보고하면 서버 해골 표시; 예약된 유지보수와 알 수 없는 결과에는 미표시.

## 문제 해결

- **"Sign in to GitHub Copilot…"** — 토큰을 찾지 못한 상태.
  편집기에서 Copilot에 로그인하거나 `gh auth login` 실행.
- **"GitHub token invalid or expired"** — 토큰이 거부된 상태(401/403).
  `gh auth login`으로 재인증.
- **미터에 "No data"가 표시되지만 요금제는 표시됨** — 조직 관리 Copilot Business/Enterprise 좌석에서 조직 소유자나 청구 관리자가 아닐 때 예상되는 동작(GitHub은 좌석별 할당량을 제공하지 않으며 조직 청구 정보는 관리자 전용).
  조직 관리자인데도 Org Credits가 보이지 않으면 토큰의 조직 목록 조회 가능 여부 확인 — `gh auth login`의 GitHub CLI 토큰은 가능하지만 일부 편집기 플러그인 토큰은 불가능.

## 내부 동작

표준 Copilot 클라이언트 헤더(API 버전 `2025-04-01`)로 `GET https://api.github.com/copilot_internal/user` 호출.
응답은 각 버킷을 *남은* 백분율로 보고하며 미터에는 *사용한* 백분율 표시.

조직 관리 좌석(응답의 토큰 기반 청구 자리표시자로 식별)은 공개 REST 청구 API도 호출: `GET /user/orgs`로 조직 목록을 가져온 뒤 Copilot AI 크레딧 사용량이 나올 때까지 조직별 `GET /orgs/{org}/settings/billing/usage/summary` 호출.
일치하는 조직을 기억해 이후 새로 고침에서는 추가 호출 한 번만 수행하며, 응답하지 않으면 자동으로 다시 탐색.
