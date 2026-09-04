# 설정

설정은 팝오버 안에 있음 — 별도 창 없음.
푸터의 **Options** 메뉴 · 팝오버가 열린 상태의 ⌘, 단축키 · 메뉴 막대 아이콘 우클릭 후 Settings 선택 중 하나로 열기.
대시보드가 옆으로 밀리며 설정 화면으로 전환되고, 왼쪽 위에 뒤로 가기 버튼 표시.
해당 버튼, ⌘, 단축키, Esc로 대시보드에 복귀(Esc는 항상 대시보드로 먼저 돌아가며, 한 번 더 누르면 팝오버 닫기).

## 일반

| 설정 | 옵션 | 동작 |
|---|---|---|
| Show Total Spend(총 지출 표시) | 켜기/끄기 | 프로바이더를 합산한 [총 지출](dashboard.md#총-지출) 카드를 대시보드 상단에 표시할지 여부.<br>기본값은 켜기이며, 지출을 추적하는 프로바이더(Claude, Codex, Cursor, Grok, OpenCode)가 하나라도 활성화되어 있으면 카드 등장. |
| Launch at Login(로그인 시 실행) | 켜기/끄기 | 앱을 로그인 항목으로 등록(시스템의 로그인 항목 레지스트리가 기준). |
| Global Shortcut(전역 단축키) | 단축키 기록 | 어디서든 팝오버를 토글하는 전역 단축키.<br>필드를 클릭하고 조합키 입력, ⓧ를 누르면 지워지고 단축키 비활성. |

**레거시(0.7 이전) 에디션에서 업그레이드하는 경우:** 예전 에디션은 자체 런처 파일로 로그인 시 실행을 관리했고, 덮어쓰기 업데이트는 그 파일을 그대로 남겨 둠.
남은 파일 때문에 로그인할 때마다 앱이 두 번 실행될 수 있었고, 시스템 설정 → 로그인 항목에는 OpenUsage가 아닌 서명 회사명("SUNSTORY LLC")으로 표시.
현재는 실행 시 해당 파일이 OpenUsage를 가리키는지 확인한 뒤에만 자동 제거 — 로그인 시 위 Launch at Login 토글이 관리하는 앱 하나만 실행.

## 계정

Accounts 섹션에서 Claude와 Codex 계정 관리.
계정은 프로바이더 로그인을 저장하는 사용자 이름 레코드 — 고를 폴더도, 편집할 경로도 없음.
기존 `~/.claude`와 `~/.codex` 설정(MCP 설정, 메모리, 플러그인, 스킬, 세션 기록)은 항상 그대로.
계정 전환은 새 터미널 세션이 쓰는 로그인만 교체.

`alpha`, `beta` 같은 계정명은 사용자가 관리하는 로컬 제목이며 이메일 주소나 영구 프로바이더 신원이 아님.
검증된 재로그인은 해당 계정명에 현재 저장된 프로바이더 신원과 인증 정보를 교체 가능.
따라서 두 계정명에 같은 프로바이더 신원의 인증 정보가 일시적으로 저장될 수 있으며, 관리형 레코드는 프로바이더 신원이 아니라 계정명으로 구분.
예를 들어 `beta`를 `gamma`로 이름 변경한 뒤 그 계정에서 재로그인하거나, `alpha`를 선택해 기존 `beta`에 저장된 프로바이더 계정으로 로그인한 뒤 예전 `beta` 레코드 제거 가능.

- 추가(+) 버튼으로 계정 추가 흐름 열기.
  이미 로그인된 상태이고 등록된 계정이 아직 없으면 현재 로그인을 바로 가져옴 — 새 브라우저 로그인 없음.
  그 외에는 공식 Claude 또는 Codex 로그인 열림.
  추가 계정은 OpenUsage 소유의 비공개 작업 공간 안에서 로그인하므로, 로그인 중에도 현재 계정과 열려 있는 터미널은 계속 동작.
  로그인을 취소하거나 실패하면 아무것도 등록되지 않음.
- 계정별 인증 정보는 macOS Keychain의 비공개 스냅샷으로 보관.
  저장된 로그인이 실제로 사용 가능하고 현재 프로바이더 신원을 검증할 수 있으면 행 배지는 **Ready**, 그렇지 않으면 **Sign-In Needed**.
  선택된 Claude 계정은 공유 `~/.claude` 홈의 로그인도 사용 가능하고 해당 계정명에 현재 저장된 신원과 일치해야 **Ready** — 검증된 새 로그인은 저장 신원을 교체하며, 저장됐거나 만료된 인증 정보의 존재만으로는 부족.
- 한 프로바이더에 계정이 둘 이상이면 각 행에 새 터미널 세션이 쓸 계정을 고르는 토글 추가.
  전환은 확인 요청.
  승인하면 공유되는 Claude 또는 Codex 설정 홈 하나는 그대로 두고, 그 인증 정보만 선택 계정으로 교체.
  결과는 검증하고, 무엇이든 실패하면 이전 로그인 복원.
  승인 시 로그인 셸 시작 파일(zsh 또는 fish)에 작은 `claude`/`codex` 함수도 설치·갱신하므로, 새 터미널 세션이 전환을 따라감.
  전환에는 zsh 또는 fish 로그인 셸 필요 — 다른 로그인 셸에서는 오류로 중단되고 아무것도 바뀌지 않음.
  자세한 내용은 [CLI](/docs/ko/cli.md) 문서 참조 — `openusage` 명령줄 도구는 필요 없음.
  토글은 해당 행이 **Ready**일 때만 활성.
  등록 계정이 남아 있는 한, 나중에 재로그인이 필요해져도 계정 하나는 선택 상태 유지.
  Ready 상태는 배지와 해당 행으로 전환할 수 있는지를 결정하지만, 선택 계정을 자동으로 바꾸지는 않음.
  이미 실행 중인 세션은 절대 바뀌지 않음.
  선택된 Claude 계정으로 일반 터미널에서 `claude`의 `/login` 또는 `claude auth login`을 실행해 다시 로그인하면, OpenUsage가 공유 홈의 로그인을 검증하고 같은 계정명에 저장된 인증 정보와 프로바이더 신원을 자동 교체.
  이 경로는 **Sign In Again**이나 OpenUsage 재실행이 필요 없으며, UI가 아직 변경을 감지하지 못했을 때는 수동 새로 고침으로 충분.
  이전과 다른 Claude 신원으로 로그인해도 선택된 계정명과 선택 상태를 유지하며, 다른 계정명을 조용히 선택하지 않음.
- Customize에는 Claude 또는 Codex가 한 번만 나오고, 켜기/끄기는 해당 프로바이더 계열의 모든 계정 카드에 적용.
  대시보드의 계정 선택기는 공유 홈의 계정과 여기 등록한 계정을 나열하고, 프로바이더의 단일 카드에 어느 계정의 사용량을 표시할지 선택.
  Settings에서 전환을 확정하면 대시보드 선택기가 같은 계정으로 한 번 이동 — 메뉴 막대 별표는 프로바이더 설정이라 그대로 유지.
  이후 대시보드 선택기 변경은 보기 전용이며 터미널 전환을 다시 실행하지 않음.
  비활성 계정의 사용량은 비공개 Keychain 스냅샷에서 읽음.
  그 스냅샷의 토큰이 만료되면 갱신된 토큰을 같은 스냅샷에 다시 저장 — 공유 홈이나 활성 계정에는 절대 쓰지 않음.
- **Manage…**에서 계정 이름 변경, 세션이 만료된 계정의 공식 로그인 재실행, 계정 제거 처리.
  편집 가능한 필드는 계정명뿐.
  **Sign In Again**은 앱 안의 복구 경로로 계속 제공하지만, 선택된 Claude 계정을 일반 터미널에서 재인증한 경우에는 필수 아님.
  **Sign In Again**은 완전하고 검증 가능한 프로바이더 로그인이면 계정명에 저장된 인증 정보와 프로바이더 신원을 교체.
  프로바이더 신원이 바뀌거나 다른 계정명에도 같은 신원이 저장돼 있어도 계정명을 바꾸거나 다른 계정을 선택하지 않음.
  제거는 그 계정의 OpenUsage 로그인 작업 공간을 먼저, 다음으로 Keychain 스냅샷을 지우고, 마지막에 레코드 등록 해제.
  `~/.claude`와 `~/.codex` 데이터는 절대 건드리지 않음.
  둘 중 하나라도 삭제가 실패하면 다시 시도할 수 있도록 계정 등록 유지.
  작업 공간 삭제가 실패한 경우에는 스냅샷도 전환 가능한 상태로 남김.
  다른 계정이 있는 동안에는 선택된 계정 제거 불가 — 먼저 전환 필요.
- 계정 추가·이름 변경·재로그인·제거는 대시보드 선택기와 카드 제목을 즉시 갱신.
  OpenUsage 재실행 불필요.
- 저장된 계정 레지스트리를 디코딩하거나 검증할 수 없으면 OpenUsage는 원본 데이터를 그대로 둠.
  레지스트리를 빈 목록으로 바꾸는 대신 Accounts에 오류를 표시하고 계정 변경 차단.

## iCloud 동기화

**Sync Across Macs**(Mac 간 동기화)는 기본값 꺼짐.
켜면 앱의 비공개 iCloud 컨테이너로 정규화된 OpenUsage 기록을 공유하고, 같은 iCloud 계정으로 로그인한 Mac들의 로컬 토큰과 지출을 합산.
설정에는 5분 저장 주기와 Mac별 상대 **Updated** 시각이 표시되며, iCloud 사용 불가·불러오기·저장·잘못된 파일 형식 상태도 함께 표시.
무엇이 포함되고 어느 화면이 합산 값을 쓰는지는 [iCloud 동기화](icloud-sync.md) 참조.

## 화면

| 설정 | 옵션 | 동작 |
|---|---|---|
| Icon Style(아이콘 스타일) | Text / Bars | 별표한 지표를 메뉴 막대에 그리는 방식.<br>기본값은 Bars.<br>[메뉴 막대](menu-bar.md) 참조. |
| Theme(테마) | System / Light / Dark | 팝오버에 적용할 앱 전체 화면 스타일 재정의. |
| Density(밀도) | Default / Compact | 새로 설치하면 Compact가 기본값.<br>Default는 여백이 넓고, Compact는 정보 밀도가 높은 모드 — 글자가 한 단계 작아지고, 행과 프로바이더 섹션 간격이 줄며, Customize / Settings 행도 함께 축소.<br>두 모드 모두 연속된 한 줄 지표(Today / Yesterday / …) 간격이 줄며, Compact에서 더 촘촘하게 표시. |
| Time Format(시간 형식) | Auto / 12-hour / 24-hour | 정확한 시각을 읽는 방식(예: "Resets today at 6:38 PM" 대 "18:38").<br>기본값은 24-hour, Auto는 시스템을 따름. |
| Increase Transparency(투명도 높이기) | 끄기 / 켜기 | 끄기(기본값)는 팝오버를 불투명 패널로 유지.<br>켜면 반투명해져 데스크톱이 비치지만, 배경에 맞춰 조정되는 반투명 표면으로 숫자와 Options 컨트롤의 가독성 유지.<br>macOS 손쉬운 사용의 **Reduce Transparency**(투명도 줄이기)나 **Increase Contrast**(대비 증가)를 켜 두면 자동으로 일시 중지하고 이유를 안내하여, 해당 설정과의 충돌 방지. |

## 사용량 표시

| 설정 | 옵션 | 동작 |
|---|---|---|
| Show Usage As(사용량 표시 방식) | Used / Left | 상한이 있는 지표를 "48% used"로 읽을지 "52% left"로 읽을지 — 기본값은 Used이며, 헤드라인 클릭과 같은 토글. |
| Reset Times(초기화 시각 표시) | Countdown / Exact time | "Resets in 3h 25m" 대 "Resets today at 6:38 PM" — 기본값은 Exact Time이며, 리셋 라벨 클릭과 같은 토글. |
| Always Show Pacing(사용 속도 항상 표시) | 끄기 / 켜기 | 켜기(기본값)는 초기화 기간이 있는 모든 지표에 사용 속도 표시 — 정상 궤도인 행에는 예측치("~33% left at reset")와, 꾸준히 썼다면 지금 어디쯤일지 알려 주는 균등 속도 눈금 추가.<br>끄면 한도에 가깝거나 넘긴 지표로만 제한.<br>초기화 기간이 없는 지표에는 보여 줄 속도 자체가 없음. |

## 알림

사용량이 한도에 가까워지는 상태를 지켜보려고 팝오버를 계속 열어 둘 필요 없이, 지표 잔량이 부족해지거나 사용 속도가 나빠지면 OpenUsage가 macOS 알림으로 통지.
알림은 앱이 메뉴 막대에서 실행 중이면 동작하며, 팝오버가 닫혀 있어도 마찬가지.

| 설정 | 옵션 | 동작 |
|---|---|---|
| Almost Out(거의 소진) | 켜기 / 끄기 | 초기화 기간이 없는 잔액까지 포함해, 지표 잔량이 10% 아래로 내려가면 통지. |
| Cutting It Close(한도에 근접) | 켜기 / 끄기 | 이번 기간 종료 시 지표 잔량이 거의 남지 않아 한도에 가깝게 끝날 전망이면 통지. |
| Will Run Out(곧 소진) | 켜기 / 끄기 | 지표가 초기화 전에 소진될 전망이면 통지. |

알림은 새로 임계선을 넘거나 속도가 나빠질 때 발생하고, 그 상태가 그대로인 동안에는 중복을 제거하므로 새로 고침마다 반복되지 않음.
OpenUsage를 실행한 시점에 이미 나쁜 상태인 할당량은 통지 없이 기준선으로만 기록.
회복한 뒤 다시 나빠지면 알림 재활성화, 새 초기화 기간이 시작되면 초기화 기반 기록도 정리.
**Almost Out**은 남은 비중만 기준이라, 초기화 기간이 없는 상한 잔액에도 동작.
**Cutting It Close**와 **Will Run Out**은 초기화 기간의 사용 속도 정보 필요.
데이터를 읽을 수 없는 지표는 알림 제외.
세 알림 조건을 모두 끄면 전체 알림 중지.
여러 알림이 동시에 발생하면 하나의 그룹 배너로 묶임.

세 알림 모두 기본값 꺼짐.
처음 하나를 켤 때 OpenUsage가 알림 권한 요청 — 거절하거나 나중에 시스템 설정에서 OpenUsage 알림을 끄면 알림 섹션 헤더에 경고 표시가 붙고, 다시 켤 수 있도록 토글 아래에 "Open System Settings"(시스템 설정 열기) 버튼 등장.
알림 제목은 알림 이름, 부제목은 프로바이더와 지표, 본문은 쉬운 문장으로 쓴 상태 설명.
알림을 누르면 대시보드 화면으로 팝오버 열기.

## 개인정보

| 설정 | 옵션 | 동작 |
|---|---|---|
| Hide From Screen Share(화면 공유 중 숨기기) | 켜기 / 끄기 | 켜기(기본값)는 화면을 공유하거나 녹화하는 동안 메뉴 막대 스트립을 OpenUsage 아이콘과 워드마크로 교체하고, 캡처가 끝나는 즉시 별표 지표 복원.<br>[메뉴 막대](menu-bar.md#화면-공유-중-사용량-숨기기) 참조. |
| Share Anonymous Usage(익명 사용량 공유) | 켜기 / 끄기 | 기본값은 끄기.<br>켜면 익명 일일 사용량 요약 공유 — 계정 정보, 인증 정보, 사용량 값은 제외.<br>전송 대상과 제외 대상은 [개인정보 및 사용 데이터](privacy.md) 참조. |

## Tokscale CLI 동기화

Tokscale 섹션은 **Terminal Helper**와 같은 레이아웃 언어를 쓰되 상태를 공유하지 않는 별도 소형 카드.
iCloud Sync, Share Anonymous Usage, 프로바이더 활성화, 새로 고침, `openusage` 명령, local API와 독립.

Accounts의 header action과 같은 위치에서 Tokscale 제목 옆에 작은 **Name…** 동작 표시.
선택 시 text field 하나가 있는 **Tokscale Device Name** sheet 열기.
값의 앞뒤 공백을 제거하고 비어 있지 않은 UTF-8 기준 최대 120byte만 허용하며 control character는 거부.
저장 시 command나 network request를 시작하지 않고 이 Mac의 이름을 OpenUsage에 보관하며, 카드에 `m1-max` 같은 저장값 표시.
이후 sync마다 `TOKSCALE_DEVICE_NAME`으로 Tokscale에 전달.
Tokscale의 stable device ID는 유지되므로 이름을 바꿔도 새 기기를 만들지 않고 다음 성공 submit에서 같은 public device 이름 갱신.
**Remove OpenUsage Override**는 Tokscale의 기존 public name을 삭제하지 않고 로컬 override만 제거하며, 이후 sync에서 Tokscale environment나 저장된 device record의 이름을 다시 사용.

동작 전에 정확한 명령, 공개 효과, 공식 [Tokscale Privacy Policy](https://tokscale.ai/privacy) 링크를 카드에 항상 표시:

```sh
bunx tokscale@latest submit
```

**Sync Now**는 provider, date, OpenUsage data argument 없이 해당 명령을 한 번 실행.
포함할 지원 소스와 field는 Tokscale에서 결정.
현재 CLI는 usage, client, model, device, 발견된 MCP server 정보를 검색 결과에 노출될 수 있는 public profile에 포함 가능.
`bunx`에서 `@latest`를 사용하므로 OpenUsage release 이후 동작이 바뀐 최신 package를 내려받아 실행할 수 있음.
Package 해석은 사용자 Bun 설정을 따르며 home directory 아래의 일치 package를 우선할 수 있음.

OpenUsage나 Settings를 여는 것만으로 Tokscale command를 실행하지 않음.
최초 사용 흐름은 사용자가 **Sync Now**를 선택할 때만 시작:

1. App environment, login shell path, Bun의 설정된 install directory에서 사용 가능한 `bunx`와 `bun` executable 탐색.
2. Bun runtime 자체가 없으면 카드에 **Installing Bun…** 표시, Bun 공식 installer 다운로드·실행, installer가 선택한 directory의 `bunx` 검증 뒤 app restart 없이 같은 동작 계속 진행.
3. App과 login shell의 environment를 병합해 `bunx tokscale@latest submit`을 한 번 실행하고 현재 Tokscale package가 지원 source 탐색을 계속 소유.
   `HOME`과 command 작업 directory는 현재 macOS account로 고정하고 알려진 runtime injection 설정, Tokscale test hook, custom Tokscale API endpoint를 제거하며, 저장한 device name은 `TOKSCALE_DEVICE_NAME`만 override.
4. Submit 결과가 검증된 Tokscale 미로그인 응답과 일치할 때만 **Log In…** 표시.
5. Login 시작 전에 Tokscale가 GitHub 신원 정보를 저장하고 이후 public profile에 username·avatar·display name이 표시될 수 있으며, login command에서 `CLI on <hostname>`을 personal token name으로 사용함을 고지.
6. OpenUsage에서 작은 **Log In to Tokscale** sheet를 열고 `bunx tokscale@latest login` 한 번 실행, 승인 대기 중 browser URL과 user code 표시.
7. Login 종료 시 카드에 **Tokscale Login Finished. Sync Has Not Started.** 표시.
8. Login만으로 usage를 자동 submit하지 않으며, 다시 명시적으로 **Sync Now**를 선택할 때 제출 시작.

동시에 Tokscale command 하나만 실행.
카드에서 Bun 설치 중, Tokscale 실행 중, login 필요, 완료, 실패 상태 구분.
Card에서 ANSI/control sequence를 제거한 bounded command output을 완료·실패 뒤에도 다음 operation 또는 app 종료까지 표시하고, login sheet가 열려 있는 동안 같은 login output도 표시.
Exit 0도 제출할 usage가 없다는 뜻일 수 있어 upload 성공을 단정하지 않는 중립적 완료 문구 사용.
그 밖의 nonzero 결과는 일반 실패로 유지.
만료되거나 revoke된 저장 credential은 알려진 제한이며 OpenUsage 밖에서 Tokscale 자체 CLI로 복구.

자동 Bun 경로에서 공식 [Bun installer](https://bun.com/docs/installation)를 사용해 현재 사용자 home 아래의 안전한 `BUN_INSTALL` directory 또는 기본값 `~/.bun`에 설치하며 login shell profile을 갱신할 수 있음.
호환되지 않는 `BUN_INSTALL`은 수정하지 않고 card에서 실패와 수동 설치 안내 표시.
사용 가능한 기존 Bun 설치는 교체하지 않음.
기존 Bun runtime은 있지만 사용 가능한 `bunx`가 없으면 재설치하지 않고 오류 표시.
설치나 검증 실패 시 submit을 시작하지 않고 카드에서 공식 설치 안내를 복구 동작으로 제공.

## 고급

| 설정 | 옵션 | 동작 |
|---|---|---|
| Log Level(로그 레벨) | Error / Warning / Info / Debug | 앱이 로그 파일에 기록하는 상세 수준.<br>기본값은 Info이며 재실행 후에도 유지, 문제를 재현하는 동안에는 Debug로 올리기.<br>즉시 적용. |
| Copy Log Path(로그 경로 복사) | 버튼 | 로그 파일 경로(`~/Library/Logs/OpenUsage/OpenUsage.log`)를 클립보드에 복사. |
| Reveal in Finder(Finder에서 보기) | 버튼 | 로그 파일이 선택된 Finder 창 열기. |

전체 동작 — 서브시스템 태그, 파일 크기 상한, 비밀 값을 절대 기록하지 않는다는 보장 — 은 [로깅](logging.md) 참조.

## 업데이트

업데이트 섹션은 서명된 업데이트 피드를 포함한 공식 패키지 빌드에만 등장.
로컬 개발 빌드에는 없음.

| 설정 | 옵션 | 동작 |
|---|---|---|
| Update Automatically(자동 업데이트) | 켜기 / 끄기 | Sparkle이 백그라운드에서 업데이트를 확인할지 여부.<br>꺼 두어도 수동 확인은 가능. |
| Beta Updates(베타 업데이트) | 켜기 / 끄기 | 받을 수 있는 업데이트에 프리릴리스 빌드 추가.<br>안정 릴리스는 어느 쪽이든 계속 제공. |
| Check for Updates…(업데이트 확인…) | 버튼 | 수동 업데이트 확인을 시작하고 Sparkle 업데이트 창 열기. |

대시보드 배너, 채널, 서명 검증은 [업데이트](updates.md) 참조.

## 버전

앱 버전은 팝오버 푸터에 표시.

설정은 업데이트 후에도 그대로 유지 — 레이아웃, 별표, 환경 설정, 메뉴 막대 단축키 모두 보존.
업데이트로 설정 저장 방식이 바뀌면 실행 시 기존 설정을 제자리에서 업그레이드하고, 중간 버전을 몇 개 건너뛰었다면 해당 단계도 순서대로 적용.
초기화되는 것은 없음.
(초기 베타는 업데이트마다 모든 설정을 지웠지만, 이제는 그렇지 않음.)

켜 둔 프로바이더도 업데이트 후에 그대로 유지 — 사용자 선택을 덮어쓰지 않음.
완전히 새로 설치한 경우에는 Mac의 AI 도구를 감지해 시작 세트 결정([대시보드 § 첫 실행](dashboard.md#첫-실행) 참조).
업데이트로 처음 보는 프로바이더가 들어오면 그 프로바이더에만 같은 로컬 감지를 한 번 실행해 실제로 그 도구가 있을 때만 켜고, 이미 결정해 둔 나머지는 설정한 그대로 유지.
[활성화되는 프로바이더](provider-enablement.md) 참조.
