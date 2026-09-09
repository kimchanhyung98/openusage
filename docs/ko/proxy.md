# 프록시

OpenUsage는 모든 프로바이더 요청을 선택적 프록시로 보낼 수 있음.

- 지원: `socks5://`, `http://`, `https://`
- 설정 파일: `~/.openusage/config.json`
- 기본값: 꺼짐
- UI: 없음 — 파일로만 설정

## 설정 파일

```json
{
  "proxy": {
    "enabled": true,
    "url": "socks5://127.0.0.1:10808"
  }
}
```

인증이 필요한 프록시는 URL에 인증 정보를 포함:

```json
{
  "proxy": {
    "enabled": true,
    "url": "http://user:pass@proxy.example.com:8080"
  }
}
```

URL에 포트가 없으면 스킴의 기본 포트가 적용(socks5 → 1080, http → 80, https → 443).

## 동작

- 설정은 시작 시 한 번만 읽음 — **파일을 바꾼 뒤에는 OpenUsage를 재시작**.
- `localhost`, `127.0.0.1`, `::1`은 항상 프록시를 우회([로컬 HTTP API](local-http-api.md)는 영향 없음).
- 설정 파일이 없거나 비활성이거나 잘못됐거나 읽을 수 없으면 프록시는 그냥 꺼진 상태.

## 적용 범위

앱이 보내는 프로바이더 사용량 요청, 공개 프로바이더 상태 확인, 일일 [모델 가격](/docs/ko/pricing.md) 새로 고침에 적용.
시스템 전체 프록시는 아님.
