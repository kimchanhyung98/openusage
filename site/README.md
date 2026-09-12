# site

`https://openusage.chanhyung.kim/` 랜딩 페이지.
Astro 정적 출력이며 한국어 전용.

승인된 화면 구성과 캡처는 [디자인](/site/docs/design.md)에 기록.

## 실행

```sh
cd site
npm ci
npm run dev      # http://localhost:4321 — HMR, CSP 미적용
npm run build    # dist/
npm run preview  # dist/ 미리보기 — CSP·인라인 검사는 여기서만 유효
```

사이트 Node 의존성은 `site/package.json`에서 관리.
루트 npm 프로젝트는 Git 훅 설정용이며 사이트 의존성과 분리.
Node 22.18 이상 필요, CI는 Node 24 사용.
정적 검사에 필요한 Node 타입은 `@types/node` 24 개발 의존성으로 직접 선언.
Astro CLI가 에이전트 환경에서 백그라운드 서버를 시작하면 `npx astro dev status`·`npx astro dev stop`으로 확인·종료.

## 페이지 이동

- 페이지 경계의 세로 입력은 다음·이전 섹션으로 즉시 이동.
- 스크립트가 페이지 이동을 맡는 동안 브라우저의 강제 스크롤 정렬 비활성화. 작은 입력 뒤 원래 위치로 되돌아가는 충돌 방지.
- 고정 내비게이션 아래를 기준으로 섹션마다 최소 한 화면 높이 확보.
- 화면보다 긴 섹션은 내용 끝까지 스크롤한 뒤 다음 화면으로 이동. 이전 화면으로 돌아갈 때는 내용 끝으로 진입.
- 조작 가능한 앱 미리보기 위의 스크롤·스와이프와 앱 내부에 초점이 있는 방향키는 앱 안에서만 처리. 내용 끝이나 고정 헤더·푸터에서도 페이지로 전달하지 않음.
- 앱 바깥에서 스크롤하면 페이지 이동. 기능 탭의 가로 스크롤은 유지.
- 주요 기능은 내비게이션 아래 한 화면 높이로 고정하고, 맥북·팝업 전체가 남는 공간 안에 들어오도록 확대 배율 계산.
- 탭을 바꿔도 기능 섹션의 높이와 페이지 스크롤 위치 유지.
- 주요 기능 안에서는 아래 스크롤로 다음 기능, 위 스크롤로 이전 기능 전환. 첫 기능에서 위로, 마지막 기능에서 아래로 이동할 때만 인접 섹션으로 이동.
- 작아진 휠·트랙패드 관성은 중복 전환 억제. 입력 강도가 유지되면 350ms 이후 다음 단계를 받아 연속 스크롤 진행.
- 약한 입력이 계속되는 경우에도 1.2초 뒤부터 입력 누적 재개. 잠금 해제를 위해 스크롤을 완전히 멈출 필요 없음.
- 애니메이션 완료를 기다리지 않고 다음·이전 기능으로 이동. 반대 방향 입력은 즉시 반영.
- 터치는 한 번의 세로 스와이프당 한 단계 이동. Page Up/Down·위아래 방향키를 누르고 있어도 순서대로 진행.
- 동작 줄이기 설정에서는 부드러운 이동 비활성화.
- 좁은 모바일에서는 상단 버튼 간격과 폭을 줄여 OpenUsage 로고를 한 줄로 유지. 첫 화면 제목도 한 줄 표시.
- 첫 화면 앱 미리보기는 가시 폭이 320px보다 좁으면 전체를 같은 비율로 축소. 가로 스크롤 없이 전체 폭 표시.
- 마지막 화면은 다운로드와 푸터가 한 화면 높이를 나눠 사용. 푸터를 보기 위한 추가 스크롤 없이 함께 표시.
- 푸터 왼쪽 카피라이트 아래에 작은 글씨로 포크 출처와 AI provider 이름·로고 소유 고지 두 줄 표시.

## 기능 시연

- 처음에는 맥북 전체 화면 표시.
- 기능 영역에 처음 진입하면 메뉴 막대로 한 번 확대하고, 완료 후 두 줄 설명 표시.
- 설명은 넓은 화면에서 오른쪽, 좁은 세로 화면에서 그래픽 아래에 배치. 탭을 바꿔도 설명 공간 유지.
- 메뉴 막대: 오른쪽 위 사용량 표시로 확대.
- 대시보드: 같은 확대 위치에서 커서가 메뉴 막대를 클릭해 팝업 열기.
- 사용량 통계: 같은 팝업 상단의 `Cost` 요약에 옅은 하늘색이 잠깐 나타났다가 사라짐.
  테두리 없이 1.6초 동안 한 번만 표시.
  `TotalSpendCard`는 Cost·Cost/MTok·Tokens를 제공하므로 탭 이름은 사용량 통계.
- 계정: `Options → Settings → + → Add Account`를 거쳐 빈 목록에 `Account 1 / Ready` 추가.
  첫 계정에서는 계정 전환 토글과 Usage Cards 행 제외.
  마우스 이동·클릭·화면 전환·단계별 대기는 기본 시연의 절반 속도.
- 연동: CLI와 로컬 API 예시, 긴 내용은 키보드로도 내부 스크롤 가능.
- 시연은 첫 화면의 조작 가능한 미리보기와 독립 상태이며 실제 계정·로그인·저장소 변경 없음.
- 새 탭 선택 시 진행 중 시연 취소. 방향키·Home/End로 탭 이동, Escape로 현재 단계의 최종 상태 표시.
- 동작 줄이기에서는 커서·확대 애니메이션 없이 최종 상태 표시.

## 조립·검증

`npm run build`는 페이지만 만듦.
조립 전 `site/`에서 `npm ci` 실행 필요.
배포물은 `gh-pages`의 feed 파일을 보존해야 하므로 조립 스크립트로 출력 검증.
현재 `Deploy Pages`는 `gh-pages` 내용만 배포하며 랜딩 페이지 배포 연결은 별도 작업.

```sh
cd .. # 저장소 루트에서 실행
WITH_FEED=1 ./script/site_assemble.sh /tmp/site-preview "$(git rev-parse --short HEAD)"
(cd site && npx astro preview --outDir /tmp/site-preview --host 127.0.0.1 --port 8080)
./script/site_smoke.sh http://127.0.0.1:8080 /tmp/site-preview
```

- `site_assemble.sh`: 빌드 후 stamp 치환, 출력 단언, 금지 문자열 검사. 인접 임시 폴더에서 모두 통과한 뒤 결과 교체.
- 앱 원문의 `official Claude sign-in`·`official Codex sign-in`은 provider 로그인 안내로만 허용. 사이트의 공식성 주장 차단은 유지.
- 기본 출력은 `.build/site-preview`. 빈 폴더 또는 `.openusage-site-output` 표식이 있는 이전 결과만 교체 가능.
- 소스·상위 폴더·심볼릭 링크 출력과 무관한 기존 폴더는 거부. 빌드·검증 실패 시 이전 결과 보존.
- `WITH_FEED=1`은 라이브 `appcast.xml`·`pricing_supplement.json`을 미리보기용으로만 복사. 배포 경로는 이 파일들을 절대 쓰지 않음.
- `site_smoke.sh`: 배포 후 검증. 두 번째 인자로 해당 배포에 포함된 feed 두 개의 사본 폴더를 필수 지정. 응답이 기준 사본과 바이트 단위로 같은지, appcast에 유효한 정식 릴리스가 있는지, 링크·자산이 응답하는지 확인.
- 링크·자산 URL은 한 항목씩 그대로 요청. 로컬 파일명에 따른 와일드카드 확장 방지.
- 피드 불일치나 기준 누락은 실패. 캐시 전파가 끝난 뒤 같은 기준으로 다시 실행. 검사 중 새 릴리스가 생겨도 기준은 바뀌지 않으며 원격 브랜치를 조회하지 않음.
- 조립 결과는 Astro preview로 제공하여 알 수 없는 경로에도 사이트의 404 페이지 반환.
- 로컬 예제는 조립 결과의 라이브 feed 사본과 비교하는 HTTP 경로 점검. 운영 배포 검증은 검사 대상 서버에서 다시 받은 파일이 아닌 해당 배포 산출물의 원본 사본 사용.

## 제약

- **`/appcast.xml`과 `/pricing_supplement.json`은 어떤 경우에도 이 경로가 건드리지 않음.** Sparkle 업데이트와 가격표가 걸려 있음.
- 외부 요청 0. 폰트·스크립트·이미지 모두 같은 출처.
- 인라인 `<style>`·`style=`·인라인 `<script>` 금지. meta CSP가 막음.
  - 동적 값은 CSSOM(`el.style.setProperty`)이나 클래스로 처리.
- 트래커·쿠키·분석 없음.

## 구조

```text
src/data/         site.ts(브랜드·URL) copy.ts(페이지 문자열) providers.ts(지원 업체)
                  demo.ts(파생 규칙 · Total Spend · 스트립) dashboard.ts(카드 더미 값)
                  metrics.ts(지표 목록) settings.ts(Settings 화면 목록)
                  accounts.ts(공개용 계정 예시) preview-state.ts(설정·계정 상태 규칙) tour.ts(시연 화면 배치)
src/styles/       tokens.css base.css + app-*.css(앱 재현 그래픽)
src/components/   페이지 섹션
src/components/app/  앱 화면 재현 파트. Popover.astro가 화면 여러 장을 담는 껍데기
src/utils/sprite.ts  provider 마크를 인라인 <symbol>로
src/scripts/app.ts   appcast 파서, 리빌, 내비
src/scripts/tour.ts  연속 기능 시연, 카메라 배율, 커서, 중단 처리
src/scripts/tour-scroll.ts  페이지·기능 스크롤·스와이프·키보드 이동과 내부 콘텐츠 경계
src/scripts/nav.ts   팝오버 안 화면 이동과 Customize 조작
src/scripts/menus.ts  메뉴 표시 레이어와 화면 경계 배치
src/scripts/settings.ts  설정 저장·표시 반영·계정 전환
scripts/og.html      OG 이미지 원본
```

`src/utils/`는 원래 `src/lib/`이었으나 루트 `.gitignore`의 `lib/` 규칙에 걸려 이름을 바꿈.

## 앱 화면 재현 그래픽

앱 스크린샷을 싣지 않음.
`Sources/OpenUsage/`의 SwiftUI 소스를 읽어 레이아웃 상수·구성·문자열을 HTML/CSS로 옮김.

- 화면 구성 기준은 [디자인](/site/docs/design.md), 앱 원문과 수치의 근거는 컴포넌트·데이터 코드에서 확인.
- 화면 기준은 v0.11.1과 현재 체크아웃의 앱 코드.
- 밀도 기본값은 Compact, Theme은 System이며 선택한 값에 따라 데모 외관 변경.
- 대시보드, Customize와 지표 상세, Settings의 일반 섹션 전체 포함.
- Settings 순서: General → Accounts → iCloud Sync → Appearance → Usage Display → Notifications → Privacy → Tokscale → Command Line → Advanced → Updates.
- Updates는 업데이트 피드가 포함된 배포판 기준으로 표시.
- Party Mode·Drunk Mode는 실제 앱에서도 시크릿 코드 이후에만 나타나므로 기본 화면에서 제외.
- 계정명은 `accounts.ts`의 `Account 1`, `Account 2` 예시를 Settings와 대시보드가 공유.
- 실제 Mac 계정·인증·사용량은 읽지 않음.
- 지표의 켜짐·섹션·별은 `Stores/DefaultLayout.swift`의 세 배열에서만 판정. 대시보드 행과 L2 스위치가 어긋날 수 없음.
- Codex의 Reset Watch는 기본 배치인 caret 뒤에 표시.
- 화면에 보이는 영어 문자열은 앱이 실제로 출력하는 값 그대로. 한국어로 옮기지 않음.
- 도넛·스트립 예시와 파생 계산은 `demo.ts`, 계정별 카드 예시는 `dashboard.ts`에서 정의.
- OG는 별도 정적 이미지이며 데모 설정 변경을 반영하지 않음.
- 조작 가능한 그래픽은 `role="group"` + `lang="en"`으로 내용 접근 가능.
- 기능 시연의 앱 내부 컨트롤은 비활성 재현이며 탭 이름과 단계 종료 알림으로 동작 전달.
- 심각도·페이스 문구·도넛 라벨은 손으로 적지 않고 `demo.ts`가 앱 규칙대로 계산.
  - 손으로 적으면 상태가 늘 때마다 서로 모순됨.

provider 마크는 사본을 두지 않고 `Sources/OpenUsage/Resources/ProviderIcons/`를 직접 읽음.
앱과 마크가 어긋날 수 없음.

### 상호작용

웹에서 확인할 수 있는 표시 설정과 계정 선택 규칙을 데모에 반영.
로그인·단축키 등록·알림 권한·Tokscale 공유·터미널 도구 설치·로그 파일·업데이트 확인은 Mac 앱 전용 안내 표시.
해당 안내는 실제 로그인·설치·공유·업데이트를 실행하지 않음.

| 누르는 곳 | 결과 | 범위 |
|---|---|---|
| Settings 표시 설정 | Total Spend·Used/Left·Reset Times·Theme·Density·Time Format·Pacing·Transparency 반영 | 전체 데모 |
| Settings 계정 스위치 | 확인 후 활성 계정과 대시보드 선택 이동. 이미 활성화된 계정은 끌 수 없음 | 해당 provider |
| Usage Cards | Single Card ↔ Separate Cards. Separate Cards는 계정명 포함 제목과 고정 카드 표시 | 계정 지원 provider 전체 |
| 카드 헤더 계정 메뉴 | 표시할 계정만 변경. Settings의 활성 계정 유지 | 해당 provider |
| 사용량 헤드라인 | `meterStyle` 전환. 막대가 반전되고 pace 눈금이 미러링됨. 색은 그대로 | 전역 |
| 리셋 라벨 | `resetDisplayMode` 전환. Exact Time ↔ Countdown | 전역 |
| 카드 아래 화살표 | On Demand 지표와 quick links를 폄 | 그 팝오버만 |
| Total Spend 기간·지표 | 기간 3 × 지표 3 조합 중 하나를 보임 | 그 팝오버만 |
| 푸터 Options | 메뉴를 폄. Customize·Settings로 화면 이동 | 그 팝오버만 |
| Customize 행·화살표 | 그 provider의 지표 상세(L2)로 | 그 팝오버만 |
| Customize 스위치 | 행이 0.55로 흐려지고 그 provider 카드가 대시보드에서 사라짐 | 그 팝오버만 |
| L2 지표 스위치 | 그 행이 대시보드에서 사라짐. 다 끄면 카드째 사라짐 | 그 팝오버만 |
| L2 별 | 메뉴 막대 고정 전환. provider당 2개를 넘기면 거절 알림 | 그 팝오버만 |
| 상단 뒤로 가기 | L2→L1, L1→대시보드, Settings→대시보드 | 그 팝오버만 |

상태를 두 축으로 나눔. 앱의 저장 구분을 그대로 따름.

- **설정·계정 선택**은 조작 가능한 데모 사이에서 공유하고 `localStorage`에 저장. 기능 시연에는 반영하지 않음.
- Settings의 Used/Left·Reset Times 변경과 대시보드 직접 클릭은 같은 저장 경로 사용.
- 저장값이 잘못되었거나 저장소 접근이 막히면 콘솔과 화면 안내로 실패 표시.
- **화면 위치**(`screen`·`customizeProviderID`)는 앱에서 팝오버가 닫히면 초기화되므로 팝오버마다 따로 두고 저장하지 않음. hero에서 Customize로 들어가도 다른 그래픽은 그대로.

그 밖에.

- 상태 조합은 빌드 시 전부 렌더해 두고 JS는 보이기만 바꿈. 그래서 JS가 없어도 앱 기본값(Used · Exact Time · Today · Cost)이 그대로 나옴.
- 화면도 같은 방식 — 전부 그려 두고 `hidden`만 바꿈. JS가 없으면 각 그래픽의 시작 화면 하나만 보임.
- Customize에서 켤 수 있는 모든 지표를 미리 준비. 예시 값이 없는 지표는 한도나 사용량을 꾸며 넣지 않고 `No data` 텍스트 표시.
- Always Visible 지표를 모두 끄면 남은 On Demand 지표를 바로 표시하여 빈 카드 방지.
- 기본 비활성 provider는 JavaScript가 꺼져 있어도 숨김.
- 펼친 카드의 Status·Dashboard는 해당 서비스 링크로 이동. 동작 없는 복사 아이콘은 표시하지 않음.
- Show Usage As·Reset Times는 헤드라인·리셋 라벨과 같은 상태. 어느 쪽에서 바꿔도 반대쪽 표시가 따라옴.
- JS가 없으면 눌러도 반응하지 않는 컨트롤(확장 화살표, 지표 메뉴 표시, Options·뒤로·열기 버튼)은 감춤.
- Options 메뉴는 앱의 8줄을 그대로 두되 화면을 옮기는 두 개만 동작하고, 나머지는 `aria-disabled`로 흐리게 둠.
- 계정·Settings·Options·Total Spend 메뉴는 앱의 스크롤 영역 밖에 겹쳐 표시. 화면 가장자리에서는 안쪽으로 이동하거나 위아래 방향 전환.
- 메뉴는 선택된 항목 또는 첫 항목에 초점이 가고 ↑↓·Home·End로 이동. Esc로 닫으면 여는 버튼으로 초점 복귀.
- Settings·계정·지표 선택 후에도 여는 버튼으로 초점 복귀. Total Spend 기간은 방향키로 순환 선택하며 선택된 항목만 Tab 이동 대상.
- 메뉴 밖 클릭·초점 이동, 본문·페이지 스크롤, 화면 크기 변경 시 닫힘.
- 메뉴를 열기 전에 발생해 뒤늦게 전달된 스크롤은 새 메뉴를 닫지 않음.
- 긴 안내 문구는 앱 너비 안에서 줄바꿈. 앱 좌우 12px 여백을 남겨 잘림 방지.
- 첫 화면의 조작 가능한 팝오버 높이는 `min(내용, 560)`. 앱도 패널을 화면 85%로 자르고 넘치면 내부 스크롤함(`PanelHeightController.swift:139`·`:152`).
  - 상단 바·푸터는 고정이고 가운데 본문만 스크롤. 막대는 앱처럼 숨김.
  - 상한 덕에 화면을 옮겨도 페이지가 움직이지 않음. 상한 아래에서 바뀔 때는 CSS가 0.22s로 이어 줌.
- `app-scale.css`의 유틸 이름에는 반드시 `am-` 접두사. 접두사가 없던 `.h1`이 히어로의 `<h1 class="h1">`을 덮어 높이를 1%로 만든 적 있음.

## 데모 검증

```sh
cd site # 저장소 루트 기준
npm ci
npx playwright install chromium firefox webkit
npm run verify # 타입 검사 + Node 검사 + 빌드 + E2E
```

`npm run check`는 Astro·TypeScript 정적 검사, `npm test`는 Node 검사, `npm run test:e2e`는 새 프로덕션 빌드의 브라우저 검사.
E2E는 Chromium·Firefox·WebKit 데스크톱과 Chromium·WebKit 모바일 에뮬레이션 사용.
모바일 WebKit의 자동화 API는 휠 입력을 지원하지 않아, 두 휠 검사는 같은 390px 폭의 데스크톱 WebKit 프로젝트로 분리.
총 6개 프로젝트이며 실제 휴대폰 터치·트랙패드 하드웨어 검증은 별도.
독립 포트 4391에서 해당 실행의 새 서버를 띄우며 기존 개발 서버를 재사용하지 않음.
포트 충돌 시 `SITE_E2E_PORT`로 변경 가능.
각 검사는 새 브라우저 컨텍스트와 가짜 appcast 사용. 실제 다운로드·설치·사용자 저장소 변경 없음.
기본 동작 줄이기 검사와 실제 계정 추가 애니메이션·빠른 취소 검사 병행.
실패 시 `test-results/`에 스크린샷·trace, `playwright-report/`에 HTML 보고서 저장.
런타임 오류와 예상하지 않은 CSP 오류는 실패 처리.
잘못된 XML 검사에서만 Chromium 자체 `parsererror` 스타일의 두 CSP 차단 메시지를 정확한 해시로 검증.
`.github/workflows/site.yml`은 GitHub Actions의 Playwright 공식 Docker 이미지에서 같은 검증과 조립 수행. 배포 동작 없음.
이미지는 `mcr.microsoft.com/playwright:v1.63.0-noble`, Node는 24 사용.
브라우저·시스템 라이브러리는 이미지에 포함되어 CI의 별도 `playwright install` 단계 생략. 프로젝트 의존성은 `npm ci`로 설치.
컨테이너는 GitHub Actions 홈 디렉터리와 같은 UID 1001로 실행하여 Firefox의 root·홈 소유권 충돌 방지.
사이트 빌드·미리보기 서버·E2E가 같은 컨테이너 안에서 실행되므로 호스트 포트 공개 불필요.
`@playwright/test`를 갱신할 때 workflow의 이미지 버전도 함께 갱신.
Docker 안의 WebKit 검사는 Linux 환경이며 실제 macOS Safari·iPhone 검증과 별개.
구성 기준은 [Playwright Docker 안내](https://playwright.dev/docs/docker)와 [GitHub Actions 컨테이너 예제](https://playwright.dev/docs/ci#via-containers).

`npm test`로 앱 코드의 Settings 섹션·행·옵션과 데모 목록 대조.
계정 선택과 활성 계정의 분리, 카드 표시 방식 전환, 설정 저장·복원, 잘못된 저장값 거부, 시간 표시 회귀 검사 포함.
기능 시연의 전체 화면·확대 화면이 짧거나 좁은 뷰포트를 벗어나지 않는 배치 검사 포함.
기능 앞뒤 이동, 관성 중복 전환 방지, 첫·마지막 단계 이탈, 섹션 진입과 터치 제스처 회귀 검사 포함.
작은 휠 입력의 페이지 이동, 연속 입력·키 누름 진행, 긴 페이지와 앱 내부 스크롤 경계 검사 포함.
메뉴의 화면 가장자리 정렬과 위아래 방향 전환 검사 포함.
브라우저에서는 섹션 정렬, 팝업 하단 잘림, 단계 간 확대 위치 유지, 빈 계정부터 추가 완료까지의 흐름, 빠른 탭 전환 취소와 키보드 이동 확인.
계정·설정·Options·지표 메뉴는 모서리 항목의 실제 클릭 가능 여부와 앱 높이 유지, 스크롤·Esc 닫힘 확인.
조립 실패·금지 문자열·feed 충돌 시 기존 결과 보존과 무관한 폴더 보호 검사 포함.
E2E에 Customize 반영, 설정 저장 차단·잘못된 저장값, 내부 스크롤 경계, 404 복귀, 로컬 자산·CSP·중복 ID 검사 포함.

## 다운로드 정보

같은 출처 `/appcast.xml`에서 채널이 없고 `숫자.숫자.숫자` 형식인 정식 버전만 선택.
양의 안전한 정수인 `sparkle:version`이 가장 큰 항목 우선, 동률이면 발행일 비교.
다운로드 URL은 원문과 정규화 결과가 모두 이 포크의 `releases/download/` 아래여야 함.
선택한 정식 릴리스의 버전을 마지막 다운로드 버튼 안에 표시.
응답 본문을 포함해 5초 제한 적용.
HTTP·XML·본문 시간 초과 등 실패는 콘솔에 기록하고 기본 GitHub 릴리스 페이지 링크 유지.
E2E는 정식 버전 선택·잘못된 빌드/URL과 각 실패 경로 검사.

## OG 이미지

`public/og.png`는 `scripts/og.html`을 1200×630으로 캡처한 결과.

- 재생성: 브라우저나 헤드리스 캡처 도구로 `scripts/og.html`을 열고 뷰포트 1200×630, DPR 1로 스크린샷.
- 시스템 폰트를 사용하므로 캡처 환경에 따라 글꼴 차이 발생 가능.
- provider 마크 path는 앱 리소스에서 붙여 넣은 값. 마크가 바뀌면 같이 갱신.
