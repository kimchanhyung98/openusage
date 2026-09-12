# OpenCode

Mac에 이미 저장된 OpenCode 자체 로그를 사용해 OpenCode 호스팅 사용량(**Go** 구독과 **Zen** 종량제 게이트웨이) 추적.
데이터는 Mac 밖으로 전송되지 않음.

## 추적 항목

| 지표 | 의미 |
|---|---|
| Session | 5시간 순환 기간의 Go 사용액과 $12 상한, 초기화 카운트다운 포함 |
| Weekly | 이번 주 Go 사용액과 $30 상한(월요일 초기화) |
| Monthly | 이번 월간 주기의 Go 사용액과 $60 상한 |
| Today / Yesterday / Last 30 Days | 모든 OpenCode 호스팅 사용량(Go + Zen)의 로컬 비용과 토큰 |
| Usage Trend | 최근 한 달간 토큰의 일별 스파크라인 |

Go 구독이 있으면 프로바이더 이름 옆에 "Go" 표시.

Session / Weekly / Monthly 미터는 **로컬에서 관측한 사용액**, 즉 *이* Mac에 기록된 사용량을 표시.
다른 기기에서도 OpenCode Go를 사용하거나 OpenCode가 아직 세션을 로컬에 모두 기록하지 않았다면 로컬 수치가 실제 계정 사용량보다 낮을 수 있으므로, 상한은 확정값이 아닌 참고용으로 활용.
(OpenCode가 공식 사용량 API를 출시하면 사용자 측 변경 없이 OpenUsage에서 공식 수치로 전환 가능.)
Zen 종량제 게이트웨이만 사용한다면(Go 구독 없음) 상한 미터는 숨기고 지출 타일만 표시.

## 인증 정보 출처

평소처럼 OpenCode 사용.
OpenCode 로컬 데이터 디렉터리(`~/.local/share/opencode`, 또는 설정한 경우 `$OPENCODE_DATA_DIR` / `$XDG_DATA_HOME`)에서 Go 사용 여부 확인용 `auth.json` Go 키와 수치 계산용 로컬 SQLite 로그를 읽는 방식.
로그인 프롬프트나 붙여 넣을 토큰 불필요.

## 미터와 지출 타일

달러 금액은 OpenCode가 자체 호스팅 게이트웨이에 기록한 메시지별 비용에서 직접 가져오므로, 토큰 수로 환산한 추정치가 아닌 OpenCode 자체 집계값.
각 지출 타일은 Claude / Codex / Cursor와 동일하게 비용과 토큰을 함께 표시(`$4.08 · 1.2M tokens`).
기록된 사용량이 없는 기간에는 오해를 부를 수 있는 `$0.00` 대신 "No data" 표시.
로그 데이터는 Mac 밖으로 전송되지 않음.

OpenUsage에 표시되는 Go 상한은 공개된 요금제 한도인 **5시간 순환 기간당 $12**, **주당 $30**(UTC 월요일), **월당 $60**(월간 주기는 Go를 처음 사용한 날의 일자에 고정).
Zen 사용량은 상한 없는 종량제 크레딧이므로 지출 타일에만 표시.

## 문제 해결

- **모든 항목에 "No data" 표시** — `~/.local/share/opencode/opencode*.db`의 OpenCode 로컬 데이터베이스 필요.
  OpenCode 세션을 실행한 뒤 새로 고침.
  (Go에 로그인된 경우 첫 로컬 메시지 전에도 상한 미터에 $0 표시.)
- **Session / Weekly / Monthly 미터가 없음** — Go 요금제 상한으로, OpenCode Go에 로그인했거나 이 Mac에서 최근 사용한 경우 표시.
  Zen 전용 사용자(또는 구독 만료 사용자)에게는 지출 타일만 표시되며, 과거 Go 사용 기록만으로는 상한이 다시 나타나지 않음.
- **"Couldn't read OpenCode's local database"** — 데이터베이스(또는 데이터 디렉터리)가 있지만 이번 새로 고침에서 읽지 못한 상태.
  OpenCode를 종료하고 새로 고침한 뒤에도 문제가 계속되면 `~/.local/share/opencode` 권한 확인.
- **"Couldn't read OpenCode's auth.json"** — 파일이 있지만 읽을 수 없거나 유효한 JSON이 아닌 상태.
  권한을 확인하거나 OpenCode Go에 다시 로그인해 파일 재작성.
- **수치가 대시보드보다 낮음** — 미터는 로컬에서 관측한 사용액(이 Mac만 해당)으로, 위 설명 참고.

## 내부 동작

데이터 디렉터리의 모든 `opencode*.db`에서 어시스턴트 메시지의 `cost`와 토큰 필드를 읽는 방식(OpenCode는 릴리스 채널별로 데이터베이스 분할 — stable은 `opencode.db`, preview는 `opencode-next.db` — 모든 채널 합산).
Go 상한에는 `opencode-go` 메시지를 합산하고, 지출 타일과 추세에는 `opencode-go`(Go)와 `opencode`(Zen)를 모두 합산.
읽기 전용, 네트워크 미사용.
OpenCode가 제안한 `/zen/go/v1/usage` API가 출시되면 동일한 Go 키를 공식 사용 기간 조회용 bearer 토큰으로 사용.
