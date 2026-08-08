# OpenUsage 문서

앱이 하는 일과 그 동작 방식.
이 문서들은 **화면 모양이 아니라 동작**을 다루며, 그 동작이 바뀔 때 함께 갱신 — 앱과 이 문서가 어긋난다면 그건 버그.

## 앱

- [대시보드](dashboard.md) — 팝오버: 행, 토글, 순서 바꾸기, 키보드 단축키
- [메뉴 막대](menu-bar.md) — 지표를 메뉴 막대에 고정하기
- [설정](settings.md) — 모든 옵션과 각 옵션이 바꾸는 것
- [새로 고침과 캐싱](refreshing.md) — 데이터가 갱신되는 시점과 가져오기 실패 시 일어나는 일
- [iCloud 동기화](icloud-sync.md) — 여러 Mac의 지출 기록을 합치는 방식
- [모델 가격](pricing.md) — 지출 타일이 토큰에 가격을 매기는 방식과 요율의 출처
- [업데이트](updates.md) — 자동 업데이트, 수동 확인, 베타 채널
- [개인정보 및 사용 데이터](privacy.md) — 공유되는 익명 데이터와 끄는 방법

## 통합

- [명령줄 인터페이스](cli.md) — 에이전트와 스크립트를 위한 1회 실행 캐시 조회와 강제 조회
- [로컬 HTTP API](local-http-api.md) — `127.0.0.1:6736`에서 다른 앱이 사용량을 읽는 방법
- [프록시](proxy.md) — 프로바이더 요청을 SOCKS5 또는 HTTP(S)로 라우팅

## 프로바이더

각 프로바이더가 추적하는 항목, 인증 정보의 출처, 오류가 표시될 때 할 일.

- [Antigravity](providers/antigravity.md)
- [Claude](providers/claude.md)
- [Codex](providers/codex.md)
- [Copilot](providers/copilot.md)
- [Cursor](providers/cursor.md)
- [Devin](providers/devin.md)
- [Grok](providers/grok.md)
- [Kimi](providers/kimi.md)
- [Kiro](providers/kiro.md)
- [OpenCode](providers/opencode.md)
- [OpenRouter](providers/openrouter.md)
- [Z.ai](providers/zai.md)

## 개발자용

앱이 어떻게 만들어졌고 어떻게 확장하는지.

- [아키텍처](architecture.md) — 구성 루트, 스토어, 프로바이더 파이프라인, AppKit 브리지
- [프로바이더 추가](adding-a-provider.md) — 지표 계약과 등록/테스트/문서화 단계
- [디버깅과 로그 캡처](debugging.md) — 로컬 빌드 실행과 로그 스트리밍
- [로깅](logging.md) — 파일 로그, 로그 레벨, 서브시스템 태그, 절대 기록되지 않는 것
