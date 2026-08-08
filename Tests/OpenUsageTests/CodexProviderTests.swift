import XCTest
@testable import OpenUsage

/// `yyyy-MM-dd` 날의 로컬 정오 — UTC `Z` timestamp가 KST에서 다음 날로 넘어가는 타임존 경계 함정 회피
private func localNoon(_ day: String) -> Date {
    let parts = day.split(separator: "-").compactMap { Int($0) }
    return Calendar.current.date(from: DateComponents(
        year: parts[0], month: parts[1], day: parts[2], hour: 12
    ))!
}

final class CodexAuthStoreTests: XCTestCase {
    func testParsesHexEncodedAuthPayload() {
        let raw = #"{"tokens":{"access_token":"token"},"last_refresh":"2026-01-01T00:00:00.000Z"}"#
        let hex = raw.utf8.map { String(format: "%02x", $0) }.joined()

        let auth = CodexAuthStore.parseAuth(hex)

        XCTAssertEqual(auth?.tokens?.accessToken, "token")
    }

    // MARK: needsRefresh (issue #516 — refresh by JWT exp, not a hardcoded 8-day age)

    func testValidFutureExpAccessTokenDoesNotNeedRefresh() {
        // `exp`가 충분히 미래인 JWT는 `last_refresh`가 오래됐어도 선제 refresh 금지 — 구 8일 규칙의 refresh_token_reused 회귀
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = CodexAuthStore(now: { now })
        let auth = CodexAuth(
            tokens: CodexTokens(accessToken: jwt(exp: now.addingTimeInterval(60 * 60))),
            lastRefresh: nil
        )

        XCTAssertFalse(store.needsRefresh(auth))
    }

    func testNearExpiryAccessTokenNeedsRefresh() {
        // `exp` 5분 window 이내 ⇒ 즉시 refresh
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = CodexAuthStore(now: { now })
        let auth = CodexAuth(
            tokens: CodexTokens(accessToken: jwt(exp: now.addingTimeInterval(60))),
            lastRefresh: nil
        )

        XCTAssertTrue(store.needsRefresh(auth))
    }

    func testNoExpClaimFallsBackToStaleLastRefresh() {
        // `exp` 디코딩 불가 ⇒ 8일 `last_refresh` 규칙으로 fallback; 9일 경과 ⇒ refresh
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = CodexAuthStore(now: { now })
        let nineDaysAgo = OpenUsageISO8601.string(from: now.addingTimeInterval(-9 * 24 * 60 * 60))
        let auth = CodexAuth(
            tokens: CodexTokens(accessToken: "token"),
            lastRefresh: nineDaysAgo
        )

        XCTAssertTrue(store.needsRefresh(auth))
    }

    func testNoExpClaimAndNoLastRefreshDoesNotForceRefresh() {
        // 신규 로그인(`exp`·`last_refresh` 없음)은 강제 refresh 금지 — 구 코드는 첫 실행에 즉시 refresh
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = CodexAuthStore(now: { now })
        let auth = CodexAuth(tokens: CodexTokens(accessToken: "token"), lastRefresh: nil)

        XCTAssertFalse(store.needsRefresh(auth))
    }

    /// 실제 JWT 형태 token 생성: `base64url(header).base64url({"exp":<epoch>}).sig`
    private func jwt(exp date: Date) -> String {
        func b64url(_ string: String) -> String {
            Data(string.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = b64url(#"{"alg":"RS256","typ":"JWT"}"#)
        let payload = b64url(#"{"exp":\#(Int(date.timeIntervalSince1970))}"#)
        return "\(header).\(payload).sig"
    }

    func testUsesCodexHomeAuthPathBeforeDefaultPaths() {
        let files = FakeFiles([
            "/tmp/codex-home/auth.json": #"{"tokens":{"access_token":"token"}}"#
        ])
        let store = CodexAuthStore(
            environment: FakeEnvironment(["CODEX_HOME": "/tmp/codex-home"]),
            files: files,
            keychain: FakeKeychain()
        )

        let candidates = store.loadAuthCandidates()

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.auth.tokens?.accessToken, "token")
    }
}

final class CodexUsageMapperTests: XCTestCase {
    func testFreshSessionWindowPreservesReportedOnePercent() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let body = Data("""
        {
          "rate_limit": {
            "primary_window": {
              "used_percent": 1,
              "limit_window_seconds": 18000,
              "reset_after_seconds": 18000,
              "reset_at": \(Int(now.timeIntervalSince1970) + 18000)
            }
          }
        }
        """.utf8)
        let response = HTTPResponse(statusCode: 200, headers: [:], body: body)
        let mapped = try CodexUsageMapper.mapUsageResponse(response, now: now)
        XCTAssertEqual(progress(mapped.lines, "Session")?.used, 1)
    }

    func testFreshSessionWindowUsesDefaultPeriodWhenLimitWindowIsMissing() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let resetAfterSeconds = CodexUsageMapper.sessionPeriodMs / 1000
        let body = Data("""
        {
          "rate_limit": {
            "primary_window": {
              "used_percent": 1,
              "reset_after_seconds": \(resetAfterSeconds),
              "reset_at": \(Int(now.timeIntervalSince1970) + resetAfterSeconds)
            }
          }
        }
        """.utf8)
        let response = HTTPResponse(statusCode: 200, headers: [:], body: body)

        let mapped = try CodexUsageMapper.mapUsageResponse(response, now: now)

        XCTAssertEqual(progress(mapped.lines, "Session")?.used, 1)
        XCTAssertEqual(progress(mapped.lines, "Session")?.periodDurationMs, CodexUsageMapper.sessionPeriodMs)
    }

    func testMapsLimitWindowSecondsFromAPI() throws {
        let body = Data("""
        {
          "rate_limit": {
            "primary_window": {
              "reset_after_seconds": 60,
              "used_percent": 1,
              "limit_window_seconds": 18000
            }
          }
        }
        """.utf8)
        let response = HTTPResponse(statusCode: 200, headers: [:], body: body)
        let mapped = try CodexUsageMapper.mapUsageResponse(
            response,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        XCTAssertEqual(progress(mapped.lines, "Session")?.periodDurationMs, 18_000_000)
    }

    func testMapsWeeklyOnlyPrimaryWindowByDuration() throws {
        let body = Data("""
        {
          "rate_limit": {
            "primary_window": {
              "used_percent": 5,
              "limit_window_seconds": 604800,
              "reset_after_seconds": 60
            },
            "secondary_window": null
          }
        }
        """.utf8)
        let mapped = try CodexUsageMapper.mapUsageResponse(
            HTTPResponse(statusCode: 200, headers: [:], body: body),
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertNil(progress(mapped.lines, "Session"))
        XCTAssertEqual(progress(mapped.lines, "Weekly")?.used, 5)
        XCTAssertEqual(progress(mapped.lines, "Weekly")?.periodDurationMs, CodexUsageMapper.weeklyPeriodMs)
    }

    func testUnknownWindowDurationKeepsPositionalFallback() throws {
        let body = Data("""
        {
          "rate_limit": {
            "primary_window": { "used_percent": 11, "limit_window_seconds": 86400 },
            "secondary_window": { "used_percent": 22, "limit_window_seconds": 2592000 }
          }
        }
        """.utf8)
        let mapped = try CodexUsageMapper.mapUsageResponse(
            HTTPResponse(statusCode: 200, headers: [:], body: body)
        )

        XCTAssertEqual(progress(mapped.lines, "Session")?.used, 11)
        XCTAssertEqual(progress(mapped.lines, "Weekly")?.used, 22)
    }

    func testMapsWindowsCreditsAndPlan() throws {
        let body = Data("""
        {
          "plan_type": "prolite",
          "rate_limit": {
            "primary_window": { "reset_after_seconds": 60, "used_percent": 10 },
            "secondary_window": { "reset_after_seconds": 120, "used_percent": 20 }
          },
          "credits": { "balance": "100" }
        }
        """.utf8)
        let response = HTTPResponse(
            statusCode: 200,
            headers: [
                "x-codex-primary-used-percent": "25",
                "x-codex-secondary-used-percent": "50"
            ],
            body: body
        )

        let mapped = try CodexUsageMapper.mapUsageResponse(
            response,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(mapped.plan, "Pro 5x")
        XCTAssertEqual(progress(mapped.lines, "Session")?.used, 10)
        XCTAssertEqual(progress(mapped.lines, "Weekly")?.used, 20)
        // Credits는 달러 값(4¢/credit) 선두 + 원시 count — 뒤집힌 가짜 cap 없음
        XCTAssertNil(progress(mapped.lines, "Credits"))
        XCTAssertEqual(values(mapped.lines, "Credits"),
                       [MetricValue(number: 4.0, kind: .dollars), MetricValue(number: 100, kind: .count, label: "credits")])
        XCTAssertNotNil(progress(mapped.lines, "Session")?.resetsAt)
        XCTAssertEqual(progress(mapped.lines, "Session")?.periodDurationMs, CodexUsageMapper.sessionPeriodMs)
    }

    func testHeadersFillMissingWindows() throws {
        let body = Data("""
        {
          "rate_limit": {}
        }
        """.utf8)
        let response = HTTPResponse(
            statusCode: 200,
            headers: [
                "x-codex-primary-used-percent": "25",
                "x-codex-secondary-used-percent": "50"
            ],
            body: body
        )

        let mapped = try CodexUsageMapper.mapUsageResponse(
            response,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(progress(mapped.lines, "Session")?.used, 25)
        XCTAssertEqual(progress(mapped.lines, "Weekly")?.used, 50)
    }

    func testSessionWindowBeatsStaleHeader() throws {
        let body = Data("""
        {
          "rate_limit": {
            "primary_window": { "reset_after_seconds": 60, "used_percent": 0 },
            "secondary_window": { "reset_after_seconds": 120, "used_percent": 7 }
          }
        }
        """.utf8)
        let response = HTTPResponse(
            statusCode: 200,
            headers: [
                "x-codex-primary-used-percent": "99",
                "x-codex-secondary-used-percent": "99"
            ],
            body: body
        )

        let mapped = try CodexUsageMapper.mapUsageResponse(
            response,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(progress(mapped.lines, "Session")?.used, 0)
        XCTAssertEqual(progress(mapped.lines, "Weekly")?.used, 7)
    }

    func testSurfacesSparkLinesFromAdditionalRateLimits() throws {
        // `additional_rate_limits`의 Spark 항목이 Spark(5시간)·Spark Weekly 미터가 됨 — issue #796 회귀
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let nowSec = Int(now.timeIntervalSince1970)
        let body = Data("""
        {
          "rate_limit": {
            "primary_window": { "used_percent": 5, "reset_after_seconds": 60 },
            "secondary_window": { "used_percent": 10, "reset_after_seconds": 120 }
          },
          "additional_rate_limits": [
            {
              "limit_name": "GPT-5.3-Codex-Spark",
              "metered_feature": "codex_bengalfox",
              "rate_limit": {
                "primary_window": {
                  "used_percent": 25,
                  "limit_window_seconds": 18000,
                  "reset_after_seconds": 3600,
                  "reset_at": \(nowSec + 3600)
                },
                "secondary_window": {
                  "used_percent": 40,
                  "limit_window_seconds": 604800,
                  "reset_after_seconds": 86400,
                  "reset_at": \(nowSec + 86400)
                }
              }
            }
          ]
        }
        """.utf8)
        let response = HTTPResponse(statusCode: 200, headers: [:], body: body)

        let mapped = try CodexUsageMapper.mapUsageResponse(response, now: now)

        XCTAssertEqual(progress(mapped.lines, "Spark")?.used, 25)
        XCTAssertEqual(progress(mapped.lines, "Spark")?.periodDurationMs, 18_000_000)
        XCTAssertEqual(progress(mapped.lines, "Spark")?.resetsAt,
                       Date(timeIntervalSince1970: TimeInterval(nowSec + 3600)))
        XCTAssertEqual(progress(mapped.lines, "Spark Weekly")?.used, 40)
        XCTAssertEqual(progress(mapped.lines, "Spark Weekly")?.periodDurationMs, 604_800_000)
        // 새 파싱이 핵심 Session/Weekly window에 영향 없음
        XCTAssertEqual(progress(mapped.lines, "Session")?.used, 5)
        XCTAssertEqual(progress(mapped.lines, "Weekly")?.used, 10)
    }

    func testMapsWeeklyOnlySparkPrimaryWindowByDuration() throws {
        let body = Data("""
        {
          "additional_rate_limits": [{
            "limit_name": "GPT-5.3-Codex-Spark",
            "rate_limit": {
              "primary_window": {
                "used_percent": 7,
                "limit_window_seconds": 604800,
                "reset_after_seconds": 60
              },
              "secondary_window": null
            }
          }]
        }
        """.utf8)
        let mapped = try CodexUsageMapper.mapUsageResponse(
            HTTPResponse(statusCode: 200, headers: [:], body: body),
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertNil(progress(mapped.lines, "Spark"))
        XCTAssertEqual(progress(mapped.lines, "Spark Weekly")?.used, 7)
        XCTAssertEqual(progress(mapped.lines, "Spark Weekly")?.periodDurationMs, CodexUsageMapper.weeklyPeriodMs)
    }

    func testMatchesSparkByMeteredFeatureWhenLimitNameLacksSpark() throws {
        // `limit_name` 문구는 변할 수 있음 — `metered_feature` 매칭으로 행 해석 유지
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let body = Data("""
        {
          "additional_rate_limits": [
            {
              "limit_name": "Research Preview",
              "metered_feature": "codex_spark_preview",
              "rate_limit": { "primary_window": { "used_percent": 12, "reset_after_seconds": 60 } }
            }
          ]
        }
        """.utf8)
        let response = HTTPResponse(statusCode: 200, headers: [:], body: body)

        let mapped = try CodexUsageMapper.mapUsageResponse(response, now: now)

        XCTAssertEqual(progress(mapped.lines, "Spark")?.used, 12)
    }

    func testIgnoresNonSparkAndMalformedAdditionalRateLimits() throws {
        // 비Spark 한도 미노출, null/비dictionary 요소는 sibling 유지한 채 skip, `rate_limit` 없는 Spark는 라인 없음 — throw 금지
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let body = Data("""
        {
          "additional_rate_limits": [
            null,
            { "limit_name": "Some Other Model", "rate_limit": { "primary_window": { "used_percent": 50, "reset_after_seconds": 60 } } },
            { "limit_name": "GPT-5.3-Codex-Spark" }
          ]
        }
        """.utf8)
        let response = HTTPResponse(statusCode: 200, headers: [:], body: body)

        let mapped = try CodexUsageMapper.mapUsageResponse(response, now: now)

        XCTAssertNil(progress(mapped.lines, "Spark"))
        XCTAssertNil(progress(mapped.lines, "Spark Weekly"))
        XCTAssertNil(progress(mapped.lines, "Some Other Model"))
    }

    func testAppendsTokenUsageLines() {
        var lines: [MetricLine] = []
        let usage = DailyUsageSeries(daily: [
            DailyUsageEntry(date: "2026-02-20", totalTokens: 150, costUSD: 0.75),
            DailyUsageEntry(date: "2026-02-01", totalTokens: 300, costUSD: 1.0)
        ])

        SpendTileMapper.appendTokenUsage(
            usage,
            to: &lines,
            now: localNoon("2026-02-20")
        )

        XCTAssertEqual(values(lines, "Today"),
                       [MetricValue(number: 0.75, kind: .dollars, estimated: true),
                        MetricValue(number: 150, kind: .count, label: "tokens")])
        // 어제 usage 없음 → "No data"(백킹 라인 없음), 조작된 "$0.00 · 0 tokens" 아님
        XCTAssertNil(values(lines, "Yesterday"))
        XCTAssertEqual(values(lines, "Last 30 Days"),
                       [MetricValue(number: 1.75, kind: .dollars, estimated: true),
                        MetricValue(number: 450, kind: .count, label: "tokens")])
    }

    func testZeroUsageLeavesTilesUnbacked() {
        // usage 없는 기간은 "No data" — SpendTileMapper에서 한 번 수정되어 모든 provider에 적용, 타일 미추가
        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(
            DailyUsageSeries(daily: [DailyUsageEntry(date: "2026-02-19", totalTokens: 0, costUSD: nil)]),
            to: &lines,
            now: localNoon("2026-02-20")
        )

        XCTAssertTrue(lines.isEmpty, "an all-zero window appends no spend tiles")
    }

    func testUnpricedTokensShowTokensWithoutAFabricatedZeroDollar() {
        // 가격 산정 불가한 날은 달러 생략(cost는 zero가 아닌 unknown) — 라벨된 token count만 표시
        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(
            DailyUsageSeries(daily: [DailyUsageEntry(date: "2026-02-20", totalTokens: 1_200_000, costUSD: nil)]),
            to: &lines,
            now: localNoon("2026-02-20")
        )

        XCTAssertEqual(values(lines, "Today"), [MetricValue(number: 1_200_000, kind: .count, label: "tokens")])
    }

    // 회귀: 달러 금액은 headline(`Formatters.currency`)과 동일하게 천 단위 구분 — 기존 `$%.2f`는 구분자 누락
    func testCreditValuesRenderGroupedThousands() {
        var data = WidgetData(title: "Extra Usage", icon: .providerMark("codex"), kind: .dollars, used: 0, limit: nil)
        data.values = CodexUsageMapper.creditValues(remaining: 30000)
        // 행은 축약("$1.2K · 30K credits"), hover tooltip은 전체 자릿수 유지
        XCTAssertEqual(data.unboundedDetail, "$1.2K · 30K credits")
        XCTAssertEqual(data.unboundedTooltip, "$1,200.00 · 30,000 credits")
    }

    func testShowsRateLimitResetsBeforeCredits() throws {
        let body = Data("""
        {
          "rate_limit_reset_credits": { "available_count": 1 },
          "credits": { "balance": 100 }
        }
        """.utf8)
        let response = HTTPResponse(statusCode: 200, headers: [:], body: body)

        let mapped = try CodexUsageMapper.mapUsageResponse(
            response,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(values(mapped.lines, "Rate Limit Resets"),
                       [MetricValue(number: 1, kind: .count, label: "available")])

        let resetIndex = mapped.lines.firstIndex { $0.label == "Rate Limit Resets" }
        let creditsIndex = mapped.lines.firstIndex { $0.label == "Credits" }
        XCTAssertNotNil(resetIndex)
        XCTAssertNotNil(creditsIndex)
        if let resetIndex, let creditsIndex {
            XCTAssertLessThan(resetIndex, creditsIndex)
        }
    }

    func testShowsZeroRateLimitResets() throws {
        let body = Data(#"{ "rate_limit_reset_credits": { "available_count": 0 } }"#.utf8)
        let response = HTTPResponse(statusCode: 200, headers: [:], body: body)

        let mapped = try CodexUsageMapper.mapUsageResponse(
            response,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(values(mapped.lines, "Rate Limit Resets"),
                       [MetricValue(number: 0, kind: .count, label: "available")])
    }

    func testDedicatedEndpointSuppliesCountAndSortedExpiries() throws {
        // dedicated endpoint의 per-credit expiry 목록 사용 — available만 빠른 순 정렬, non-available 제외
        let usage = HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))
        let resetCredits = HTTPResponse(statusCode: 200, headers: [:], body: Data("""
        {
          "available_count": 2,
          "credits": [
            { "status": "available", "expires_at": "2026-02-20T19:00:00.000Z" },
            { "status": "available", "expires_at": "2026-02-20T17:30:00.000Z" },
            { "status": "consumed", "expires_at": "2026-02-20T16:10:00.000Z" }
          ]
        }
        """.utf8))

        let mapped = try CodexUsageMapper.mapUsageResponse(
            usage,
            resetCredits: resetCredits,
            now: OpenUsageISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        )

        guard case .values(_, let vals, _, let expiriesAt, _, _) = mapped.lines.first(where: { $0.label == "Rate Limit Resets" }) else {
            return XCTFail("expected a Rate Limit Resets values line")
        }
        XCTAssertEqual(vals, [MetricValue(number: 2, kind: .count, label: "available")])
        XCTAssertEqual(expiriesAt, [
            OpenUsageISO8601.date(from: "2026-02-20T17:30:00.000Z")!,
            OpenUsageISO8601.date(from: "2026-02-20T19:00:00.000Z")!
        ])
    }

    func testExpiriesPreservedWhenStatusOmitted() throws {
        // `status`는 optional — `expires_at`만 있는 credit도 expiry 목록에 포함, 명시적 non-available은 제외 (회귀)
        let usage = HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))
        let resetCredits = HTTPResponse(statusCode: 200, headers: [:], body: Data("""
        {
          "available_count": 2,
          "credits": [
            { "expires_at": "2026-02-20T19:00:00.000Z" },
            { "expires_at": "2026-02-20T17:30:00.000Z" },
            { "status": "consumed", "expires_at": "2026-02-20T16:10:00.000Z" }
          ]
        }
        """.utf8))

        let mapped = try CodexUsageMapper.mapUsageResponse(
            usage,
            resetCredits: resetCredits,
            now: OpenUsageISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        )

        guard case .values(_, _, _, let expiriesAt, _, _) = mapped.lines.first(where: { $0.label == "Rate Limit Resets" }) else {
            return XCTFail("expected a Rate Limit Resets values line")
        }
        // status 없는 credit 2건 유지(정렬), "consumed"는 제외
        XCTAssertEqual(expiriesAt, [
            OpenUsageISO8601.date(from: "2026-02-20T17:30:00.000Z")!,
            OpenUsageISO8601.date(from: "2026-02-20T19:00:00.000Z")!
        ])
    }

    func testFallsBackToUsageBodyCountWhenDedicatedFetchUnavailable() throws {
        // dedicated 응답 없음(fetch 실패): count는 usage body의 내장 객체로 fallback, `expiriesAt`은 빈 목록
        let usage = HTTPResponse(statusCode: 200, headers: [:],
                                 body: Data(#"{ "rate_limit_reset_credits": { "available_count": 3 } }"#.utf8))

        let mapped = try CodexUsageMapper.mapUsageResponse(
            usage,
            resetCredits: nil,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        guard case .values(_, let vals, _, let expiriesAt, _, _) = mapped.lines.first(where: { $0.label == "Rate Limit Resets" }) else {
            return XCTFail("expected a Rate Limit Resets values line")
        }
        XCTAssertEqual(vals, [MetricValue(number: 3, kind: .count, label: "available")])
        XCTAssertTrue(expiriesAt.isEmpty)
    }

    func testDedicatedNullCountFallsBackToUsageBodyCount() throws {
        // `available_count`가 JSON null(NSNull, non-nil)인 2xx payload는 source 선택 금지 — usage body count로 fallback
        let usage = HTTPResponse(statusCode: 200, headers: [:],
                                 body: Data(#"{ "rate_limit_reset_credits": { "available_count": 2 } }"#.utf8))
        let resetCredits = HTTPResponse(statusCode: 200, headers: [:],
                                        body: Data(#"{ "available_count": null }"#.utf8))

        let mapped = try CodexUsageMapper.mapUsageResponse(
            usage,
            resetCredits: resetCredits,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(values(mapped.lines, "Rate Limit Resets"),
                       [MetricValue(number: 2, kind: .count, label: "available")])
    }

    func testDedicatedNon2xxFallsBackToUsageBodyCount() throws {
        // non-2xx dedicated 응답은 무시 — count는 usage body로 fallback, 행 누락 금지
        let usage = HTTPResponse(statusCode: 200, headers: [:],
                                 body: Data(#"{ "rate_limit_reset_credits": { "available_count": 1 } }"#.utf8))
        let resetCredits = HTTPResponse(statusCode: 500, headers: [:], body: Data("<html>oops</html>".utf8))

        let mapped = try CodexUsageMapper.mapUsageResponse(
            usage,
            resetCredits: resetCredits,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(values(mapped.lines, "Rate Limit Resets"),
                       [MetricValue(number: 1, kind: .count, label: "available")])
    }

    func testOmitsRateLimitResetsWhenCountMalformed() throws {
        let body = Data(#"{ "rate_limit_reset_credits": { "available_count": null } }"#.utf8)
        let response = HTTPResponse(statusCode: 200, headers: [:], body: body)

        let mapped = try CodexUsageMapper.mapUsageResponse(
            response,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertNil(values(mapped.lines, "Rate Limit Resets"))
    }

    private func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double, resetsAt: Date?, periodDurationMs: Int?)? {
        guard case .progress(_, let used, let limit, _, let resetsAt, let periodDurationMs, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return (used, limit, resetsAt, periodDurationMs)
    }

    private func values(_ lines: [MetricLine], _ label: String) -> [MetricValue]? {
        guard case .values(_, let values, _, _, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return values
    }
}

@MainActor
final class CodexProviderTests: XCTestCase {
    func testNoUsageDataBadgeIsDroppedWhenLocalLogsHaveSpend() async throws {
        let now = localNoon("2026-02-20")
        let turnStart = now.addingTimeInterval(-2 * 3600)
        // live usage API는 매핑 가능한 것 없음(빈 body -> metric 라인 없음)...
        let httpClient = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8)))
        let home = try CodexLogFixture.makeHome(files: [
            "sessions/rollout-1.jsonl": [
                CodexLogFixture.turnContext(
                    timestamp: OpenUsageISO8601.string(from: turnStart), model: "gpt-5.2"
                ),
                CodexLogFixture.tokenCount(
                    timestamp: OpenUsageISO8601.string(from: turnStart.addingTimeInterval(60)),
                    last: CodexLogFixture.usage(input: 100, output: 50)
                )
            ].joined(separator: "\n")
        ])
        let provider = CodexProvider(
            authStore: CodexAuthStore(
                environment: FakeEnvironment(["CODEX_HOME": "/tmp/codex-home"]),
                files: FakeFiles(["/tmp/codex-home/auth.json": #"{"tokens":{"access_token":"token"}}"#]),
                keychain: FakeKeychain()
            ),
            usageClient: CodexUsageClient(http: httpClient),
            logUsageScanner: CodexLogFixture.scanner(home: home),
            now: { now },
            pricing: {
                // 이 픽스처 요율로 150 tokens -> $0.25: (100 x 1000 + 50 x 3000) / 1M
                ModelPricing(
                    supplement: PricingSupplement(),
                    primary: PricingCatalog(entries: ["gpt-5.2": ModelRates(
                        inputPerMillion: 1000, outputPerMillion: 3000,
                        cacheWritePerMillion: 1000, cacheReadPerMillion: 100
                    )]),
                    secondary: PricingCatalog(entries: [:])
                )
            }
        )

        let snapshot = await provider.refresh()

        // ...로컬 스캔 spend 존재 → spend 라인 표시, "No usage data" badge 없음 — badge가 spend보다 먼저 붙던 회귀
        XCTAssertEqual(values(snapshot.lines, "Today"),
                       [MetricValue(number: 0.25, kind: .dollars, estimated: true),
                        MetricValue(number: 150, kind: .count, label: "tokens")])
        XCTAssertFalse(snapshot.lines.contains { line in
            if case .badge(_, let value, _, _) = line { return value == "No usage data" }
            return false
        })
    }

    private func values(_ lines: [MetricLine], _ label: String) -> [MetricValue]? {
        guard case .values(_, let values, _, _, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return values
    }
}

final class CodexUsageClientRefreshTests: XCTestCase {
    func testRefreshFormEncodesReservedCharactersInRequestBody() async throws {
        let http = FakeHTTPClient(response: HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"access_token":"new-token"}"#.utf8)
        ))
        let client = CodexUsageClient(http: http)

        _ = try await client.refreshToken("refresh token&=+/?%")

        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.headers["Content-Type"], "application/x-www-form-urlencoded")
        XCTAssertEqual(
            String(data: try XCTUnwrap(request.body), encoding: .utf8),
            "grant_type=refresh_token&client_id=app_EMoamEEZ73f0CkXaXp7hrann" +
                "&refresh_token=refresh%20token%26%3D%2B%2F%3F%25"
        )
    }

    func testRefreshReportsRequestFailureForUnrecognizedErrorBody() async {
        // non-OAuth body(HTML proxy/WAF 페이지)의 400은 request failure로 노출 — re-login으로 해결 불가한 transport 오류
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 400, headers: [:], body: Data("<html>Bad Gateway</html>".utf8)))
        let client = CodexUsageClient(http: http)
        do {
            _ = try await client.refreshToken("refresh")
            XCTFail("expected refreshToken to throw")
        } catch let error as CodexUsageError {
            XCTAssertEqual(error, .requestFailed(400))
        } catch {
            XCTFail("expected CodexUsageError.requestFailed, got \(error)")
        }
    }

    func testRefreshReportsRequestFailureForNon4xxStatus() async {
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 503, headers: [:], body: Data()))
        let client = CodexUsageClient(http: http)
        do {
            _ = try await client.refreshToken("refresh")
            XCTFail("expected refreshToken to throw")
        } catch let error as CodexUsageError {
            XCTAssertEqual(error, .requestFailed(503))
        } catch {
            XCTFail("expected CodexUsageError.requestFailed, got \(error)")
        }
    }

    func testRefreshStillMapsKnownOAuthCodeToSessionExpired() async {
        let body = Data(#"{"error":{"code":"refresh_token_expired"}}"#.utf8)
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 400, headers: [:], body: body))
        let client = CodexUsageClient(http: http)
        do {
            _ = try await client.refreshToken("refresh")
            XCTFail("expected refreshToken to throw")
        } catch let error as CodexAuthError {
            XCTAssertEqual(error, .sessionExpired)
        } catch {
            XCTFail("expected CodexAuthError.sessionExpired, got \(error)")
        }
    }
}
