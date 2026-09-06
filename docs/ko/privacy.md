# 개인정보 및 사용 데이터

OpenUsage는 앱이 어떻게 쓰이는지 파악하고 문제를 잡아내는 데 도움이 되도록 **익명** 사용 데이터를 공유할 수 있음.
기본값은 꺼짐이며, **Settings → Privacy → Share Anonymous Usage**(설정 → 개인정보 → 익명 사용 데이터 공유)에서 언제든 켜기 가능.

## 익명 분석에서 공유되는 항목

공유가 켜져 있으면 OpenUsage는 작은 일일 요약 두 종류를 전송 — 하루 한 번의 앱 사용 이벤트, 그리고 그날 새로 고친 프로바이더마다 최대 한 개의 프로바이더 새로 고침 이벤트:

- **앱 사용** — 오늘 앱이 활성 상태였다는 사실, 앱과 macOS 버전, 켜 둔 프로바이더와 지표, 메뉴 막대에 고정했거나 "show more"(더 보기) 캐럿 뒤로 넣은 지표.
  사용자나 계정과 연결되지 않은 임의 ID 덕분에 누구도 식별하지 않고 일일 활성 사용자 수를 셀 수 있음.
- **프로바이더 새로 고침** — 프로바이더별로 그날 성공·실패한 새로 고침 횟수, 발생한 오류의 **종류**(예: "not logged in", "network", HTTP 상태 그룹), 직접 실행한 수동 새로 고침 횟수.

또한 앱이 예기치 않게 종료되게 만드는 버그를 찾아 고칠 수 있도록 **크래시**도 보고:

- **크래시 리포트** — OpenUsage가 크래시되면 리포트를 저장해 두고 다음에 앱을 열 때 전송 — 기술적 스택 트레이스(크래시 당시 *OpenUsage 자체 코드*의 어느 부분이 실행 중이었는지)와 앱·macOS 버전.
  계정 정보, 인증 정보, 사용량 값은 들어 있지 않고 앱의 어느 지점에서 크래시가 났는지만 담김.

## 익명 분석에서 공유되지 않는 항목

- 계정 정보, 이름, 이메일, 인증 정보.
- 실제 사용량 **값**(지출 금액, 토큰 수, 한도).
- 오류 **메시지**나 파일 경로 — 대략적인 오류 범주의 횟수만.
- 토글이 꺼져 있는 동안에는 아무것도.

## 이 Mac에 저장된 인증 정보

OpenUsage는 주로 프로바이더 도구가 이미 Mac에 보관 중인 인증 정보를 읽음.
사용자가 제공한 API 키를 쓰거나 갱신된 인증 정보를 저장할 때는 파일을 원자적으로 교체하고 해당 macOS 계정으로 접근을 제한(소유자 읽기·쓰기만).
Antigravity의 수명 짧은 갱신 토큰 캐시는 단방향 지문으로 현재 키체인 로그인에 묶이며, 갱신 인증 정보 자체는 복사하지 않음.
이 캐시는 로그아웃 후, 계정 변경 후, 키체인 접근이 불가능한 동안에는 절대 사용되지 않음.

Claude Desktop 접근은 철저히 읽기 전용.
OpenUsage는 Desktop의 현재 액세스 토큰을 복호화하기 위해 macOS에 `Claude Safe Storage` 키체인 항목 사용 권한을 요청할 수 있음.
Desktop의 자동 교체되는 갱신 토큰은 절대 쓰지 않고, Desktop의 설정·쿠키·키체인 데이터도 절대 수정하지 않음.

관리형 계정 전환([**Settings → Accounts**(설정 → 계정)](/docs/ko/settings.md))은 `OpenUsage Account Authentication`으로 시작하는 서비스 이름 아래, 계정마다 인증 스냅샷 하나를 macOS 키체인에 보관.
이 스냅샷 덕분에 다시 전환할 때 이전 로그인을 복원 가능.
각 스냅샷에는 해당 계정명에 현재 저장된 인증 파일 내용이 담기고, macOS 로그인 키체인에만 비공개로 남으며, 어디에도 전송되지 않음.
선택된 관리형 Claude 계정으로 일반 터미널에서 공식 CLI 로그인을 완료하면, OpenUsage가 공유 홈의 새 인증 정보를 검증하고 해당 계정의 스냅샷과 저장 프로바이더 신원을 교체.
검증된 프로바이더 신원이 바뀌어도 계정명과 선택 상태는 유지하며, 완료되지 않았거나 검증할 수 없는 인증 정보는 복사하지 않음.
추가 계정의 공식 로그인은 `~/Library/Application Support/OpenUsage/AccountSignIn/<provider>/<account-id>/` 아래 앱 소유 작업 공간에서 실행.
작업 공간 디렉터리는 `0700`, 인증 정보 파일은 `0600` 권한 사용.
계정을 제거하면 작업 공간을 먼저 삭제한 다음 Keychain 스냅샷을 삭제.
어느 한쪽 삭제가 실패하면 다시 시도할 수 있도록 계정 등록은 그대로 유지.
`~/.claude`와 `~/.codex` 데이터는 절대 이동하거나 삭제하지 않음.
전환을 확정하면 `~/.zshrc` 또는 `~/.config/fish/config.fish`의 작은 `claude`/`codex` 함수도 갱신.
이 함수는 `>>> OpenUsage` 주석 마커로 감싸여 있어, 표시된 블록을 삭제하면 함수도 제거.

관리형 계정명, 현재 프로바이더 신원 연결, 선택된 계정 상태, 로그인 준비 상태, 인증 스냅샷은 이 Mac에만 있고 iCloud 동기화에 포함되지 않음.
iCloud 대상이 되는 것은 정규화된 사용량 히스토리뿐.
공유 관리형 홈의 히스토리는 현재 선택된 계정이 아니라 프로바이더 패밀리 합계로 동기화.

## 기타 네트워크 요청

벤더 도구가 어차피 수행하는 프로바이더 API 호출 외에, OpenUsage는 공개 [모델 가격 목록](pricing.md)을 약 한 시간에 한 번 가져옴(`raw.githubusercontent.com`, `models.dev`, 이 프로젝트의 GitHub Pages에서).
공개 데이터를 그대로 내려받는 요청이라 사용량·로그·계정 정보가 실리지 않으며, Share Anonymous Usage 설정과 무관하게 실행.
OpenUsage는 로컬 CLI 로그로 Mac에서 지출 타일을 계산하고 일반 새로 고침이나 익명 분석으로 해당 로그를 전송하지 않음.

재실행할 때마다 변경되지 않은 Claude, Codex, pi 로그를 다시 읽지 않도록, OpenUsage는 파싱된 사용 이벤트를 `~/Library/Application Support/OpenUsage/log-scan-cache/`에 보관.
이 레코드에는 로컬 합계에 필요한 사용량 메타데이터(프로바이더가 이미 기록한 이벤트별 비용 포함)가 담기지만, 원시 JSONL 줄이나 대화 텍스트는 담기지 않음.
해당 macOS 계정에만 비공개로 남고, PostHog나 프로바이더, iCloud 어디에도 절대 전송되지 않음.
오래된 소스 파일 레코드는 스캔 범위가 전진하면서 버려지고, 35일 동안 쓰이지 않은 식별 정보 캐시는 제거.
OpenUsage의 가격 엔진은 캐시를 읽은 뒤에 돌기 때문에, 계산된 집계와 합계는 이 캐시에 남지 않음.

[iCloud 동기화](icloud-sync.md)를 직접 켜면, OpenUsage는 사용자의 Mac들이 하나의 결합 요약을 볼 수 있도록 정규화된 일일 토큰, 지출, 모델별 합계를 앱 전용 iCloud 컨테이너에 기록.
인증 정보, 계정 한도, 프로바이더 응답, 원시 로그는 절대 기록하지 않음.
이는 익명 사용 데이터 공유와 별개 — iCloud 동기화는 기본값이 꺼짐이고 사용자의 iCloud 계정을 쓰는 반면, 애널리틱스 토글은 PostHog 이벤트를 제어.

## Tokscale 공개 공유

Tokscale 동작은 세 번째 독립 공유 흐름.
iCloud Sync나 Share Anonymous Usage로 활성화되지 않으며, Tokscale 상태 변경도 두 설정을 바꾸지 않음.
App launch, 새로 고침, background task, widget update, `openusage` CLI 호출, local API 요청으로 Bun 설치나 Tokscale 실행 금지.

Settings의 명시적 **Sync Now**에서만 다음 명령 실행:

```sh
bunx tokscale@latest submit
```

`bunx`가 해석한 Tokscale package에서 지원 소스를 직접 탐색해 검색 engine에 색인될 수 있는 public profile을 갱신하도록 요청하는 명령.
2026-09-04 Tokscale v4.15.1 검토 기준, CLI는 token·cost breakdown, 날짜, client, model, message·timing 통계, device 정보, 발견된 MCP server 이름, Tokscale CLI 버전을 포함 가능.
해당 집계를 계산하기 위해 local session file을 읽을 수 있지만, Tokscale 현재 policy에서는 prompt·response·conversation content, source code, file content·name, AI provider API key·credential을 제출에서 제외.
OpenUsage widget, iCloud history, 익명 분석에서 제출 데이터를 역산하지 않고 OpenUsage provider 설정을 filter로 적용하지 않음.
App과 캡처된 login shell environment를 병합해 OpenUsage provider 목록이 아닌 현재 `@latest` CLI가 source 탐색을 계속 소유.
따라서 child가 해당 environment에 export된 credential과 기타 secret에 접근할 수 있지만 OpenUsage에서 그 값을 검사하거나 기록하지 않음.
알려진 runtime injection 설정, Tokscale test hook, custom Tokscale API endpoint, custom terminal `HOME`은 전달하지 않고 현재 macOS account의 home을 `HOME`과 작업 directory로 사용.
Tokscale 자체 token은 request 인증에 사용하고, Tokscale 현재 policy에서는 AI provider API key와 credential을 제출 usage data에서 제외.

**Name…**에서 저장한 device name은 Tokscale profile에서 기기를 식별할 수 있는 public label.
OpenUsage에 로컬로 보관하고 submit process에만 `TOKSCALE_DEVICE_NAME`으로 전달하며, `m1-max` 같은 값은 다음 성공 submit에서 같은 stable device의 표시 이름을 교체.
이름 저장이나 변경만으로 network request를 실행하지 않음.
Override 제거로 Tokscale의 기존 public name을 삭제하지 않으며, 이후 submit에서 Tokscale environment나 저장된 device record의 이름을 다시 사용.

Submit 명령에서 검증된 미로그인 결과를 받으면 OpenUsage에서 별도 **Log In…** 동작을 제공하고 `bunx tokscale@latest login` 실행.
Login 자체는 usage를 제출하지 않으며, 완료 뒤에도 submit을 자동 시작하지 않음.
현재 login 흐름에서 Tokscale는 GitHub numeric ID, username, display name, avatar URL, email을 저장 가능.
새 login 중 command에서 `CLI on <hostname>`을 personal token name으로도 전송하며, 이 token name은 public submission device label과 별개이고 **Name…**으로 변경되지 않음.
이후 submit에서 public profile을 생성·갱신하며 GitHub username, avatar, display name을 표시할 수 있음.

명시적 **Sync Now**에서 사용 가능한 Bun runtime을 찾지 못하면 OpenUsage에서 Bun 공식 installer를 다운로드·실행한 뒤 계속 진행.
Installer는 현재 사용자 home 아래의 안전한 `BUN_INSTALL` directory 또는 기본값 `~/.bun`에 file을 생성·갱신하고 login shell profile에 Bun path 설정을 추가할 수 있으며 administrator 권한은 불필요.
Installer child에는 binary download용으로 export된 proxy·certificate 설정을 전달하지만 그 밖의 login-shell 값은 전달하지 않음.
OpenUsage는 이 경계 밖의 호환되지 않는 `BUN_INSTALL`을 수정하지 않고 수동 설치 안내 제공.
변경 가능한 Bun installer와 `@latest`가 고지 경계에 포함 — OpenUsage update 없이 바뀐 Bun 또는 Tokscale code를 내려받아 실행할 수 있음.
정확한 `bunx` command는 사용자 Bun 설정을 따르며 home directory 아래의 일치 package를 우선할 수 있음.
공식 [Tokscale Privacy Policy](https://tokscale.ai/privacy), [Bun 설치 안내](https://bun.com/docs/installation), [Bun `bunx` 문서](https://bun.com/docs/pm/bunx) 참조.

Installer와 command output에는 username, browser URL, authorization code, local path, model 이름, profile URL, usage 값이 포함될 수 있음.
OpenUsage에서는 bounded memory 사본을 Settings card와 login sheet에 표시하고 완료·실패 output도 다음 command 또는 app 종료까지 유지하며, OpenUsage log, telemetry, UserDefaults, file, clipboard에 자동 기록하지 않음.
OpenUsage에서 Tokscale credential file을 읽거나 복사하지 않으며 Tokscale logout, disconnect, remote data 삭제 UI도 제공하지 않음.

## 익명 분석 동작 방식

- 익명 분석 데이터는 완전히 익명 — OpenUsage는 분석 서비스에 사용자를 식별시키지 않고 사용자 프로필도 만들지 않음.
- 크래시 리포트도 **같은** Share Anonymous Usage 스위치를 사용 — 끄면 크래시 보고도 함께 꺼지고, 따로 찾아야 할 설정은 없음.
  꺼져 있는 동안에는 크래시 리포트를 기록하지도, 보내지도 않음.
- 횟수는 로컬에서 모아 일일 요약으로 전송하므로, 앱의 일반적인 5분 새로 고침이 네트워크 호출 폭주로 번지지 않음.
- 사용자의 선택과 익명 ID는 앱의 나머지 설정과 분리해 저장하므로, 설정 마이그레이션이나 업데이트가 공유를 다시 켜거나 ID를 바꾸지 않음.

## 익명 분석 공유 설정

**Settings → Privacy**를 열고 **Share Anonymous Usage**를 켜면 공유에 참여.
끄면 공유가 즉시 중단.
