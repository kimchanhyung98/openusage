# Copilot

Copilot 도구가 Mac에 남긴 GitHub 토큰으로 GitHub Copilot 할당량 추적.
Copilot CLI가 남긴 날짜별 사용 이력은 대시보드 상단 비용·토큰 통계에 반영.
별도 로그인 절차나 브라우저 쿠키 불필요.

## 추적 항목

| 지표 | 의미 |
|---|---|
| Credits | 월간 AI 크레딧 할당량 사용 비율, 또는 조직 관리 좌석의 개인 사용 크레딧 수 |
| Extra Usage | 추가 지출 활성화 후 기본 제공 크레딧을 초과해 사용한 프리미엄 인터랙션 |
| Org Credits | 조직 전체가 이번 달 사용한 AI 크레딧(조직 관리 Business/Enterprise 좌석) |
| Org Spend | 기본 제공분을 초과한 AI 크레딧으로 조직에 청구된 달러 금액 |
| Chat | 채팅 메시지 할당량 사용량 |
| Completions | 코드 완성 할당량 사용량 |

Credits와 Extra Usage는 기본적으로 Always Visible이며, Org Credits, Org Spend, Chat, Completions는 카드 캐럿 아래의 On Demand로 시작.
할당량 미터에는 사용 백분율과 응답에 포함된 경우 다음 재설정까지의 카운트다운 표시.
개인·조직 크레딧 수에는 한도나 백분율을 임의로 붙이지 않음.
요금제 이름(Pro, Business, Free, …)은 프로바이더 옆에 표시.

할당량 API의 응답에 따라 계정별 표시 내용이 달라짐.

- **유료 요금제**는 크레딧 풀 사용량을 집계하므로 Credits 표시(추가 지출을 켰으면 Extra Usage도 표시).
  유료 요금제의 Chat과 Completions는 무제한이므로 해당 행에는 "No data" 표시.
- **무료·교육용 요금제**도 응답에 크레딧 할당량이 있으면 Credits 표시.
  Chat과 Completions는 각 할당량이 제공된 경우 표시.
- **조직 관리 좌석(조직에서 할당한 Copilot Business / Enterprise)**은 개인 할당량이 없어도 응답에 양수 개인 사용 크레딧이 있으면 **Credits**에 수치 표시.
  개인 사용 크레딧이 0이거나 제공되지 않으면 기존처럼 "No data" 표시.
  별도로 조직 청구 정보를 조회해 **Org Credits**(이번 달 조직 전체 사용 크레딧)와 **Org Spend**(기본 제공분을 초과해 청구된 금액) 표시.
  두 가지 유의 사항:
  - Org Credits와 Org Spend는 **조직 전체** 사용량이며 개인 Credits에 합산하지 않음.
  - 조직 청구 정보 조회에는 **조직 소유자 또는 청구 관리자** 권한 필요.
    일반 멤버도 응답에 개인 사용 크레딧이 있으면 Credits 표시 가능.
    조직 조회 실패나 권한 부족이 개인 Credits를 지우지 않음.
- Org Credits는 백분율이 아닌 단순 개수로 표시: 청구 API는 사용량만 보고하고 조직의 크레딧 할당량은 제공하지 않으므로 OpenUsage에서 분모를 임의 생성하지 않음.

할당량이 있는 계정의 Credits는 이 엔드포인트가 제공한 크레딧 백분율 사용.
월간 할당량·개인 누적 크레딧·조직 청구 합계를 오늘 비용으로 배정하지 않음.

## 상단 비용·토큰 통계

Copilot CLI의 `~/.copilot/session-store.db`에서 요청별 사용량을 읽기 전용으로 조회.
앱 실행 환경에 `COPILOT_HOME`이 있으면 해당 디렉터리 사용.
CLI의 `assistant_usage_events` 테이블에 기록된 모델·시각·토큰·AI 크레딧 원값만 집계.
대화 본문과 인증 정보는 사용 이력 수집 대상에서 제외.

- 요청 시각을 이 Mac의 날짜로 변환해 Today·Yesterday·30 Days에 반영.
- 기록된 `total_nano_aiu`를 100,000,000,000으로 나눠 달러로 환산.
  1,000,000,000 nano AIU = 1 AI 크레딧, 1 AI 크레딧 = $0.01.
  구독료나 추가 청구액이 아닌 사용량의 달러 환산값.
- 입력 토큰과 출력 토큰을 합산.
  캐시 토큰은 입력에, 추론 토큰은 출력에 포함되므로 별도 가산하지 않음.
- 컨텍스트 크기와 월간 누적값으로 누락된 요청 사용량을 추정하지 않음.
- 날짜·모델 형식이 잘못되었거나 토큰 수·크레딧 원값이 없거나 유효하지 않은 기록은 비용·토큰 합계에서 제외하고 경고 표시.
  모든 기록이 무효인 경우 마지막 정상 이력 보존.
- 요청의 성공·거절 상태를 별도로 판별하지 않고 기록된 사용량 원값만 집계.
  집계할 기록이 없으면 상단 통계에 값을 만들지 않음.
  할당량 초과로 거절되어 사용량이 기록되지 않은 경우에도 동일.
- 현재 로컬 기록에 계정 식별자가 없으므로 이 Mac의 Copilot CLI 전체 이력으로 취급.
  편집기나 `gh`의 현재 로그인 계정 하나에 귀속하지 않음.

VS Code·JetBrains·GitHub 웹·다른 Mac의 전체 계정 사용량을 자동 복원하는 기능은 아님.
Mac 간 동기화를 켠 경우에만 다른 Mac의 OpenUsage가 수집한 CLI 이력과 합산.
같은 CLI 데이터베이스를 여러 Mac에 복사한 경우 중복 집계 가능.
새 지표 타일이나 탭 없이 기존 상단 통계에 반영하며 Copilot 카드 배치는 유지.

할당량 조회에 실패해도 읽을 수 있는 CLI 이력은 갱신하고 헤더에 오류 안내 표시.
마지막 정상 할당량이 있으면 기존 플랜·할당량·조회 시각 보존.
로컬 이력 갱신을 할당량 조회 성공으로 처리하지 않음.
로컬 기록 읽기 실패는 사용량 0으로 처리하지 않고, 마지막 정상 이력이 있으면 보존.
CLI 사용 이력만 있어도 첫 실행의 로컬 감지 대상에 포함.

사용량 비교는 Copilot CLI의 `/usage`에서 세션 크레딧과 모델별 토큰 확인.
[CLI 사용량 확인](https://docs.github.com/en/copilot/how-tos/copilot-cli/use-copilot-cli/overview#context-management)과 [AI 크레딧 단가](https://docs.github.com/en/copilot/concepts/billing-and-usage/individuals/billing) 참조.

## 인증 정보 출처

다음 순서로 확인(사용자 확인이 필요 없는 파일 우선, 키체인 마지막):

1. Copilot 편집기 토큰: `~/.config/github-copilot/apps.json`(이전 `hosts.json`) — VS Code / JetBrains / Neovim Copilot 플러그인에서 기록
2. GitHub CLI 설정: `~/.config/gh/hosts.yml`의 `github.com` 바로 아래 `oauth_token` — 활성 계정의 토큰을 파일에 저장하는 경우
3. GitHub CLI 활성 계정의 키체인 항목(서비스 `gh:github.com`) — `gh`에서 토큰을 시스템 키링에 저장하는 경우

처음 읽은 비어 있지 않은 토큰으로 사용량 조회.
이 인증 순서는 원격 할당량 조회에만 적용하며, 로컬 CLI 이력 수집에는 토큰 불필요.
`copilot`이나 `gh` 명령을 실행해 사용량을 수집하지 않음.
해당 토큰이 API에서 거부돼도 다음 출처로 자동 전환하지 않음.
GitHub CLI 인증 사용 시 `gh auth switch`로 바꾼 활성 계정을 다음 새로 고침에 반영.
`users` 아래 다른 계정의 저장 토큰은 선택하지 않음.
편집기 Copilot 토큰을 사용하는 경우에는 GitHub CLI 계정 전환과 별개로 편집기 로그인을 계속 사용.

### 설정

편집기 Copilot 토큰이 없으면 GitHub CLI로 인증 가능:

```bash
brew install gh   # 필요한 경우
gh auth login     # GitHub.com 선택 후 안내에 따라 진행
```

지원되는 편집기에서 Copilot을 사용하면 편집기가 토큰을 `apps.json`에 기록하므로 별도 설정 불필요.

## 서비스 상태

Copilot이 활성화돼 있으면 실행 시, 활성화 시, 5분마다, 대시보드 수동 새로 고침 시 [GitHub Status](https://www.githubstatus.com/)의 Copilot 컴포넌트 확인.
활성화 시에도 5분 성공 캐시와 서버가 지정한 Retry-After 대기를 존중하며 상태 재확인.
공개 요청은 인증 없이 실행되며 GitHub 인증 정보나 사용량 데이터를 보내지 않음.
해당 컴포넌트가 성능 저하, 부분 장애, 중대 장애를 보고하면 서버 해골 표시; 예약된 유지보수와 알 수 없는 결과에는 미표시.
해골을 누르면 GitHub Status를 기본 브라우저로 열기.

## 문제 해결

- **"Sign in to GitHub Copilot…"** — 토큰을 찾지 못한 상태.
  편집기에서 Copilot에 로그인하거나 `gh auth login` 실행.
- **"GitHub token invalid or expired"** — 토큰이 거부된 상태(401/403).
  편집기 토큰을 사용 중이면 해당 편집기에서 Copilot 재로그인.
  GitHub CLI 토큰을 사용 중이면 `gh auth login` 실행.
  편집기 토큰이 남아 있으면 GitHub CLI 재로그인 후에도 편집기 토큰을 먼저 사용.
- **미터에 "No data"가 표시되지만 요금제는 표시됨** — 조직 관리 좌석의 개인 사용 크레딧이 0이거나 제공되지 않고 조직 청구 정보도 조회할 수 없을 때 가능한 상태.
  조직 관리자인데도 Org Credits가 보이지 않으면 현재 사용 중인 토큰의 조직 목록·청구 조회 권한 확인.
  일부 편집기 토큰은 조직 목록 조회 권한이 없으며, 편집기 토큰이 있으면 GitHub CLI 토큰보다 먼저 사용.
- **"Personal Credits are unavailable"** — 개인 사용 크레딧 값이 유효하지 않은 상태.
  개인 Credits만 생략하며 조회한 조직 정보는 유지하고, 다음 정상 조회에서 경고 해제.

## 내부 동작

표준 Copilot 클라이언트 헤더(API 버전 `2025-04-01`)로 `GET https://api.github.com/copilot_internal/user` 호출.
응답은 각 버킷을 *남은* 백분율로 보고하며 미터에는 *사용한* 백분율 표시.
실제 할당량 미터가 없는 조직 관리 좌석은 `premium_interactions.credits_used`의 양수 개인 사용량을 수치로 표시.
개인 수치를 달러로 환산하거나 조직 전체 값과 합산하지 않음.
상단 통계의 달러 환산은 날짜가 있는 CLI 요청 기록에만 적용.

조직 관리 좌석(응답의 토큰 기반 청구 자리표시자로 식별)은 공개 REST 청구 API도 호출: `GET /user/orgs`로 조직 목록을 가져온 뒤 Copilot AI 크레딧 사용량이 나올 때까지 조직별 `GET /orgs/{org}/settings/billing/usage/summary` 호출.
일치하는 조직을 기억해 이후 새로 고침에서는 추가 호출 한 번만 수행.
조직 접근이 불가하거나 사용량이 더 이상 없으면 다시 탐색하며, 일시적 실패에는 기억한 조직을 유지하고 다음 새로 고침에 재시도.
