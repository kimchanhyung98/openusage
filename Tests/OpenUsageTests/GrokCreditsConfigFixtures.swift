import Foundation
@testable import OpenUsage

/// Grok `/v1/billing?format=credits` 응답 fixture — decoder/mapper·provider test 공용
enum GrokCreditsFixtures {
    /// 2026-07-06 실캡처 응답 (percent는 nonzero로 편집 — proto-JSON은 0일 때 필드 생략), 미매핑 필드 포함
    static let capturedResponseBody = Data("""
    {"config":{"creditUsagePercent":99.0,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY",\
    "start":"2026-06-30T21:36:52.140114+00:00","end":"2026-07-07T21:36:52.140114+00:00"},\
    "onDemandCap":{"val":0},"onDemandUsed":{"val":0},"isUnifiedBillingUser":true,\
    "prepaidBalance":{"val":0},"topUpMethod":"TOP_UP_METHOD_SAVED_PAYMENT_METHOD",\
    "billingPeriodStart":"2026-06-30T21:36:52.140114+00:00",\
    "billingPeriodEnd":"2026-07-07T21:36:52.140114+00:00"}}
    """.utf8)

    static let capturedPeriodStart = Date(timeIntervalSince1970: 1_782_855_412 + 0.140114)
    static let capturedPeriodEnd = Date(timeIntervalSince1970: 1_783_460_212 + 0.140114)

    /// decoder가 읽는 필드만 담은 합성 응답 — `percent`/`onDemandCap`에 nil 전달 시 proto-JSON처럼 필드 생략
    static func responseBody(
        periodType: String = "USAGE_PERIOD_TYPE_WEEKLY",
        percent: Any? = 99.0,
        onDemandCap: Any? = nil,
        start: String = "2026-06-30T21:36:52.140114+00:00",
        end: String = "2026-07-07T21:36:52.140114+00:00"
    ) -> Data {
        var config: [String: Any] = [
            "currentPeriod": ["type": periodType, "start": start, "end": end],
            "isUnifiedBillingUser": true
        ]
        if let percent {
            config["creditUsagePercent"] = percent
        }
        if let onDemandCap {
            config["onDemandCap"] = ["val": onDemandCap]
        }
        return try! JSONSerialization.data(withJSONObject: ["config": config])
    }
}
