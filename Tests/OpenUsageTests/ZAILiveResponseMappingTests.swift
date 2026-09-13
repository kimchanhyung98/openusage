import XCTest
@testable import OpenUsage

final class ZAILiveResponseMappingTests: XCTestCase {
    // 실제 quota 응답 캡처본 — PII 제거, mapper가 읽는 필드만 유지
    private let liveQuota = #"""
    {"code":200,"msg":"Operation successful","data":{"limits":[
      {"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":17,"nextResetTime":1782724971179},
      {"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":3,"nextResetTime":1783305486997},
      {"type":"TIME_LIMIT","unit":5,"number":1,"usage":1000,"currentValue":0,"remaining":1000,"percentage":0,"nextResetTime":1785292686976,"usageDetails":[{"modelCode":"search-prime","usage":0},{"modelCode":"web-reader","usage":0},{"modelCode":"zread","usage":0}]}
    ],"level":"pro"},"success":true}
    """#

    private let liveSubscription = #"""
    {"code":200,"msg":"Operation successful","data":[{"productName":"GLM Coding Pro","status":"VALID","nextRenewTime":"2026-07-29","billingCycle":"monthly","inCurrentPeriod":true}],"success":true}
    """#

    func testCreditQuotaPreservesReportedPercentageWindowAndOptionalReset() throws {
        let body = Data(#"""
        {"data":{"limits":[
          {"type":"CREDIT_LIMIT","unit":3,"number":5,"percentage":0},
          {"type":"CREDIT_LIMIT","unit":6,"number":1,"usage":10000,"currentValue":9855,"remaining":145,"percentage":98,"nextResetTime":1786685679998}
        ]}}
        """#.utf8)

        let mapped = try ZAIUsageMapper.map(quotaBody: body, subscriptionBody: nil)

        XCTAssertEqual(mapped.lines.map(\.label), ["Session", "Weekly"])
        XCTAssertNil(mapped.plan)
        XCTAssertEqual(progress(mapped.lines, "Session")?.used, 0)
        XCTAssertEqual(progress(mapped.lines, "Session")?.periodDurationMs, 18_000_000)
        XCTAssertEqual(progress(mapped.lines, "Weekly")?.used, 98)
        XCTAssertEqual(progress(mapped.lines, "Weekly")?.periodDurationMs, 604_800_000)
        guard case .progress(_, _, _, _, let sessionReset, _, _) = mapped.lines.first,
              case .progress(_, _, _, _, let weeklyReset, _, _) = mapped.lines.last else {
            return XCTFail("expected credit quota meters")
        }
        XCTAssertNil(sessionReset)
        XCTAssertEqual(try XCTUnwrap(weeklyReset).timeIntervalSince1970, 1_786_685_679.998, accuracy: 0.001)
    }

    func testMapsLiveResponseToSessionWeeklyAndWebSearches() throws {
        let mapped = try ZAIUsageMapper.map(
            quotaBody: Data(liveQuota.utf8),
            subscriptionBody: Data(liveSubscription.utf8)
        )

        XCTAssertEqual(mapped.plan, "GLM Coding Pro")

        let session = try XCTUnwrap(progress(mapped.lines, "Session"))
        XCTAssertEqual(session.used, 17, accuracy: 0.001)
        XCTAssertEqual(session.periodDurationMs, 5 * 60 * 60 * 1000)

        let weekly = try XCTUnwrap(progress(mapped.lines, "Weekly"))
        XCTAssertEqual(weekly.used, 3, accuracy: 0.001)
        XCTAssertEqual(weekly.periodDurationMs, 7 * 24 * 60 * 60 * 1000)

        let web = try XCTUnwrap(progress(mapped.lines, "Web Searches"))
        XCTAssertEqual(web.used, 0, accuracy: 0.001)
        XCTAssertEqual(web.limit, 1000, accuracy: 0.001)
    }

    private func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double, periodDurationMs: Int?)? {
        guard case .progress(_, let used, let limit, _, _, let period, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return (used, limit, period)
    }
}
