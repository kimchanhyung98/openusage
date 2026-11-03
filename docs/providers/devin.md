# Devin

Devin CLI 또는 Devin 앱의 로그인으로 Devin 할당량 추적.

## 추적 항목

| 지표 | 의미 |
|---|---|
| Weekly | 주간 할당량 사용량(Devin이 주간 할당량을 보고하지 않으면 일간 수치로 대체) |
| Daily | 일간 할당량 사용량(Devin이 일간 할당량을 숨기면 미표시) |
| Extra Balance | 초과/추가 사용 잔액(달러) |

Devin이 요금제 이름을 보고하면 OpenUsage의 프로바이더 이름 옆에 표시.

## 상단 통계 지원 범위

이 Mac에 저장된 Devin CLI 요청 이력을 Today·Yesterday·Last 30 Days의 Cost·Tokens·Cost/MTok에 반영.
기본 저장소는 `~/.local/share/devin/cli/sessions.db`이며, 파일 저장 모드의 `cli/sessions/<session>/log.jsonl`도 지원.
`DEVIN_SESSIONS_DIR`이 있으면 `$DEVIN_SESSIONS_DIR/cli` 사용.
그 외에는 `$XDG_DATA_HOME/devin/cli` 사용하며, `XDG_DATA_HOME`도 없으면 기본 경로 사용.
앱의 셸 환경 캡처가 끝나기 전에 경로를 고정하지 않고 로컬 이력 조회 시 확인.
SQLite와 세션 파일은 읽기 전용이며 인증 정보·대화 본문을 별도 저장하지 않음.

- 입력·캐시 읽기·캐시 쓰기·출력 토큰을 요청별로 합산.
  현재 컨텍스트 크기는 누적 사용량에 더하지 않음.
  캐시 토큰 값의 누락·`null`은 0으로 처리.
- 요청 ID로 재개·복제·저장소 이동 과정의 중복 기록 제거.
  요청 ID가 없으면 메시지 ID, 두 ID가 모두 없으면 세션·노드 ID 사용.
- 비용은 요청에 기록된 모델과 공통 API 단가로 산정한 추정치.
  캐시 쓰기 유효기간을 담지 않은 기록에는 공통 가격의 기본 캐시 쓰기 단가 적용.
  구독료·ACU 청구액·Extra Balance와 별개이며, 할당량이나 잔액을 차감해 비용으로 만들지 않음.
- 모델이나 단가를 확인할 수 없는 기록이 있으면 해당 기간은 토큰만 표시.
  손상된 행·세션·저장소는 제외하고 읽을 수 있는 나머지 이력과 카드 경고 유지.
  SQLite 조회 실패 시에도 파일 이력 조회를 계속하며, 파일 저장소 실패 시에도 정상 SQLite 이력 유지.
  사용량 메타데이터가 없는 정상 assistant 기록은 집계 대상에서 제외.
- 로컬 자정 기준 날짜 사용.
  Last 30 Days는 기존 통계와 같이 오늘 및 이전 30일 포함.

[공식 CLI](https://docs.devin.ai/cli/reference/commands)의 요청별 사용량을 수집하는 범위.
이 Mac에 기록되지 않은 Cloud·조직 사용량은 포함하지 않음.
할당량 조회 실패 시에도 읽을 수 있는 로컬 통계는 갱신하며 기존 한도·요금제·조회 시각은 보존.
로컬 통계 조회에 실패하면 마지막 통계 수집일이 같은 경우에만 기존 통계 유지.
통계 수집일은 한도 조회일과 별도로 보존하며, 한도 조회 실패 중 수집한 오늘 통계도 같은 기준 적용.
저장소가 사라져 이전 통계를 유지하는 경우에도 카드 경고 표시.
모든 기록을 읽지 못한 결과는 빈 이력으로 취급하지 않음.
정상적인 빈 이력이 확인되거나 마지막 통계 수집일이 다른 경우에는 기존 통계 제거.

## 인증 정보 출처

다음 순서로 확인하며, 먼저 정상 동작하는 인증 정보 사용:

1. Devin CLI 인증 정보: `~/.local/share/devin/credentials.toml`(`windsurf_api_key` 사용, `api_server_url`이 있으면 함께 사용)
2. Devin 앱의 로컬 상태 데이터베이스

CLI 조회가 실패하면 앱의 인증 정보 확인.
앱의 API 키 또는 API 서버가 CLI 설정과 다를 때 앱의 인증 정보로 다시 조회.

## 문제 해결

- **"Not logged in"** — `devin auth login`을 실행하거나 Devin 앱에 로그인한 뒤 새로 고침.
- **Weekly에 일간 수치 표시** — Devin이 별도 주간 할당량을 보고하지 않으면 의미 있는 값을 유지하도록 Weekly 행에 일간 할당량 표시.

## 내부 동작

설정된 API 서버(기본값 `server.codeium.com`)에서 Connect RPC `GetUserStatus` 호출.
할당량 백분율은 "remaining"으로 전달되며 "used"로 변환.
토큰 갱신 없이 401/403 발생 시 다음 인증 출처로 전환.
