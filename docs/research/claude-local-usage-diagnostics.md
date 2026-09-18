# Claude 로컬 사용량 누락 검토

## 증거와 한계

제보 화면은 Session·Weekly·Fable 값이 있으나 Today·Yesterday 비용·토큰은 `No data`, 일부 과거 Trend 존재.
제보자의 앱 버전·실제 사용 환경·원본 로그 미확인.
현재 Mac의 Claude 데이터로 제보를 재현하지 않음.

2026-09-17의 PostHog 조회에서 0.12.0 Claude 일일 집계는 성공 898회·실패 7회, 실패 범주는 network.
같은 설치의 여러 프로바이더가 같은 시각에 실패한 기록도 있으나 제보자와 연결할 근거 없음.
이 수치는 당시 수신 이벤트의 집계이며 전체 사용자 장애율이나 제보 해결의 증거 아님.

## 최소 수정

- 수정 전 확인된 문제: 파일 파서가 정확한 `"usage":{` 문자열만 찾아 동등한 공백 포함 JSONL을 제외.
- 후보는 `"usage"` 키로 좁히고 디코딩된 `message.usage`로 최종 검증.
- 금지 null은 디코딩된 필드로 검사해 공백 우회와 문자열 본문 오인 방지.
- Claude 캐시 버전 `3 → 4`; 이전에 빈 배열로 저장된 파일도 재파싱.
- 중복 제거·Advisor 합산·가격 미확정 기록 제외 정책 유지.

## 로그와 PostHog

기존 `AppDiagnostics` → `TelemetryRecorder` → `TelemetryPrivacy` 경로 사용.
`"usage"` 후보의 JSON 디코딩·최상위 객체 변환 실패와, `message.usage`가 객체인 후보의 추가 형식 검증 실패는 `history_scan`, `degraded`, `decoding`으로 기록.
`message.usage`가 없거나 객체가 아닌 유효한 JSON 객체는 진단 없이 제외.
모델명이 있고 토큰이 0보다 크지만 가격 부재로 합계에서 제외한 기록은 `history_scan`, `degraded`, `other`로 기록.
각각 파일 재파싱 또는 집계 호출당 한 번 기록하며, 숫자 손상은 기존 진단 유지.
원격으로 원문·모델명·경로·토큰·비용을 추가 전송하지 않으며 기존 동의·중복 억제·일일 상한 유지.
정상 미사용 이벤트나 기간별 이벤트, 새 원격 필드, 별도 파일 메타데이터 캐시 추가 없음.

배포 후 해당 버전의 `feature_operation_result`·`feature_operation_daily`에서 `operation=history_scan`, `provider_id=claude`와 오류 범주 확인.
즉시 이벤트와 일일 `count`는 중복 계산 금지.
파싱 제외는 파일 재파싱 시에만 진단하므로 캐시 사용 시 기록이 없을 수 있음.
정상 부재와 읽기·파싱·가격 문제는 여전히 제보 시각의 지원 자료와 함께 판단 필요.

## 검증 경계

합성 JSONL의 공백·null·손상 후보·Advisor·부분 집계와 기존 진단 이벤트에 대한 회귀 테스트 유지.
현재 Mac의 실제 Claude 파일·인증·앱 실행은 검증에 사용하지 않음.
초기 검증은 Xcode 라이선스 미동의로 중단.
2026-09-18 리뷰 수정 후 관련 회귀 테스트 7개와 `make check` 통과; 전체 테스트 중 환경 조건에 따른 6개 제외.
