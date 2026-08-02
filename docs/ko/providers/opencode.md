# OpenCode

Mac에 저장된 OpenCode 로그를 읽어 OpenCode 호스팅 사용량(**Go** 구독과 **Zen** 종량제 게이트웨이)을
보여 줍니다. 로그는 Mac 밖으로 전송되지 않습니다.

## 추적 항목

| 지표 | 의미 |
|---|---|
| Session | 순환 5시간 동안의 Go 사용액($12 상한), 초기화 카운트다운 포함 |
| Weekly | 이번 주 Go 사용액($30 상한, 월요일 초기화) |
| Monthly | 이번 월간 주기의 Go 사용액($60 상한) |
| Today / Yesterday / Last 30 Days | 모든 OpenCode 호스팅 사용량(Go + Zen)의 로컬 비용과 토큰 |
| Usage Trend | 최근 한 달간 토큰의 일별 스파크라인 |

Go 구독이 있으면 OpenUsage가 프로바이더 이름 옆에 "Go"를 표시합니다.

Session / Weekly / Monthly 미터는 **로컬에서 관측한 사용액**, 즉 *이* Mac에 기록된 사용량을 표시합니다.
다른 Mac에서도 OpenCode Go를 사용하거나 OpenCode가 모든 세션을 로컬에 기록하지 않으면 실제 계정 사용량보다
낮을 수 있으므로 상한은 확정값이 아닌 참고용으로 보세요. (OpenCode가 공식 사용량 API를 출시하면
OpenUsage가 사용자 설정을 바꾸지 않고 공식 수치로 전환할 수 있습니다.) Zen만 사용하는 경우(Go 구독 없음)
상한 미터는 숨기고 지출 내역만 표시합니다.

## 인증 정보 출처

평소처럼 OpenCode를 사용하면 됩니다. OpenUsage는 OpenCode의 로컬 데이터 디렉터리(`~/.local/share/opencode`, 설정했다면 `$OPENCODE_DATA_DIR` / `$XDG_DATA_HOME`)를 읽습니다. 사용 여부 감지에는 `auth.json`의 Go 키를, 수치에는 로컬 SQLite 로그를 사용합니다. 로그인 프롬프트도, 붙여넣을 토큰도 없습니다.

## 미터와 지출 타일

달러 수치는 OpenCode가 자체 호스팅 게이트웨이에 대해 기록하는 메시지별 비용에서 그대로 가져오므로, OpenCode 자체 회계이지 토큰 수에서 환산한 추정치가 아닙니다. 각 지출 타일은 비용과 토큰을 함께 표시하며(`$4.08 · 1.2M tokens`), Claude / Codex / Cursor와 동일합니다. 기록된 사용량이 없는 기간은 오해를 부를 수 있는 `$0.00` 대신 "No data"로 표시됩니다. 로그 데이터는 Mac 밖으로 나가지 않습니다.

OpenUsage가 기준으로 삼는 Go 상한은 공개된 요금제 한도입니다: **5시간 순환당 $12**, **주당 $30**(UTC 월요일), **월당 $60**(월간 주기는 Go를 처음 사용한 날짜에 고정됨). Zen 사용량은 상한이 없는 종량제 크레딧이므로 지출 타일에만 표시됩니다.

## 문제 해결

- **모든 항목에 "No data" 표시** — OpenUsage는 `~/.local/share/opencode/opencode*.db`의 OpenCode 로컬 데이터베이스가 필요합니다. OpenCode 세션을 실행한 후 새로 고침하세요. (Go에 로그인되어 있다면 첫 로컬 메시지 전에도 상한 미터가 $0으로 표시됩니다.)
- **Session / Weekly / Monthly 미터가 없음** — 이들은 Go 요금제 상한으로, 이 Mac에서 OpenCode Go에 로그인했거나 최근에 사용한 경우에 표시됩니다. Zen만 사용하는 사용자(또는 구독이 만료된 사용자)는 대신 지출 타일을 보게 되며, 과거 Go 사용 기록만으로는 상한이 다시 나타나지 않습니다.
- **"Couldn't read OpenCode's local database"**(OpenCode 로컬 데이터베이스를 읽을 수 없음) — 데이터베이스(또는 데이터 디렉터리)는 존재하지만 이번 새로 고침에서 읽지 못했습니다. OpenCode를 종료하고 새로 고침하세요. 계속되면 `~/.local/share/opencode`의 권한을 확인하세요.
- **"Couldn't read OpenCode's auth.json"**(OpenCode의 auth.json을 읽을 수 없음) — 파일은 존재하지만 읽을 수 없거나 유효한 JSON이 아닙니다. 권한을 확인하거나, OpenCode Go에 다시 로그인해 파일을 새로 쓰세요.
- **수치가 대시보드보다 낮게 보임** — 미터는 로컬에서 관측된 사용액(이 Mac만 해당)입니다. 위의 설명을 참고하세요.

## 내부 동작

OpenUsage는 데이터 디렉터리의 모든 `opencode*.db`에서 어시스턴트 메시지의 `cost`와 토큰 필드를 읽습니다(OpenCode는 릴리스 채널별로 데이터베이스를 분할합니다 — 스테이블은 `opencode.db`, 프리뷰 라인은 `opencode-next.db` — 따라서 모든 채널을 합산합니다). Go 상한은 `opencode-go` 메시지를 합산하고, 지출 타일과 추세는 `opencode-go`(Go)와 `opencode`(Zen)를 모두 합산합니다. 읽기 전용이며 네트워크를 사용하지 않습니다. OpenCode가 제안한 `/zen/go/v1/usage` API가 출시되면 동일한 Go 키가 공식 사용 기간의 bearer 토큰이 됩니다.
