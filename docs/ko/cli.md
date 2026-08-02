# 명령줄 인터페이스

OpenUsage는 에이전트와 스크립트에서 사용할 수 있는 1회 실행 명령 `openusage`를 제공합니다.
문서에 정의된 [`/v1/limits`](local-http-api.md#get-v1limits) JSON을 출력한 뒤 종료하며,
메뉴 막대 앱을 실행하지도, 프로세스를 남겨 두지도 않습니다. 출력에는 UI 행이나 색상,
부제목, 차트, 지출 내역 타일이 아니라 안정적인 스칼라 한도와 잔액이 담깁니다.

```sh
openusage                 # every enabled provider, refreshing stale cache entries
openusage codex           # one provider, refreshing when its cache is stale
openusage codex --force   # refresh through the shared provider engine, cache, print, exit
```

이 명령과 앱은 같은 프로바이더, 인증 스토어, 가격 정보, 새로 고침 코디네이터,
스냅샷 캐시를 공유합니다. 일반 조회는 5분 이내에 만들어진 스냅샷을 재사용하고,
없거나 오래된 스냅샷만 새로 고칩니다. `--force`는 앱에서 수동 새로 고침을 하는 것과
같은 동작으로, 캐시 유효성 검사를 건너뛰고 성공한 결과를 같은 캐시에 기록합니다.
인증 정보는 로컬에서만 사용되며 출력에 절대 표시되지 않습니다.

프로바이더 인자는 [로컬 HTTP API](local-http-api.md)와 마찬가지로 단순한 문자열
일치로 해석됩니다. 정확한 프로바이더 ID는 해당 프로바이더 하나를 가리키고,
패밀리 ID(`claude`, `codex`)는 해당 패밀리에 속한 모든 계정 카드를 가리킵니다. 계정이
하나뿐이면 그 카드 하나가 전부이므로, 멀티 계정 지원이 추가되어도 기존 사용 방식은
그대로 유지됩니다. 응답 객체에는 일치한 모든 프로바이더가 들어갑니다. 어떤 프로바이더도
가리키지 않는 ID를 사용하면 오류로 종료됩니다. 별칭이나 계정 선택 로직은 없습니다.

## `PATH`에 설치

OpenUsage에서 **Settings → Command Line**(설정 → 명령줄)을 열고 **Install…**(설치…)을
클릭합니다. 표준 macOS 관리자 프롬프트를 거치면 새 터미널 세션에서 `openusage`를
전역에서 사용할 수 있습니다. 설치된 심볼릭 링크는 OpenUsage 안에 있는 서명된 헬퍼를
가리키므로, 앱이 제자리에서 업데이트되면 명령도 함께 업데이트됩니다.

종료 코드는 성공 시 `0`, 잘못된 인자나 알 수 없는 프로바이더일 때 `2`, 새로 고침이나
로컬 읽기에 실패하면 `4`입니다.
