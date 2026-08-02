import XCTest
@testable import OpenUsage

final class KiroUsageMapperTests: XCTestCase {
    func testMapsSingleCreditBreakdownUsingPrecisionFields() throws {
        let mapped = try KiroUsageMapper.map(kiroUsageData())
        let credits = try XCTUnwrap(progress(mapped.lines, label: "Credits"))

        XCTAssertEqual(credits.used, 10.25, accuracy: 0.0001)
        XCTAssertEqual(credits.limit, 50, accuracy: 0.0001)
        XCTAssertEqual(credits.format, .count(suffix: "credits"))
        XCTAssertEqual(credits.periodDurationMs, KiroUsageMapper.billingPeriodMs)
        XCTAssertEqual(credits.resetsAt?.timeIntervalSince1970, 1_788_134_400)
    }

    func testFallsBackToIntegerFields() throws {
        let data = kiroUsageData(breakdown: [
            "resourceType": "CREDIT",
            "currentUsage": 7,
            "usageLimit": 25,
        ])

        let credits = try XCTUnwrap(progress(try KiroUsageMapper.map(data).lines, label: "Credits"))

        XCTAssertEqual(credits.used, 7)
        XCTAssertEqual(credits.limit, 25)
    }

    func testDoesNotClampUsageAboveLimit() throws {
        let data = kiroUsageData(breakdown: [
            "resourceType": "CREDIT",
            "currentUsageWithPrecision": 75.5,
            "usageLimitWithPrecision": 50,
        ])

        let credits = try XCTUnwrap(progress(try KiroUsageMapper.map(data).lines, label: "Credits"))

        XCTAssertEqual(credits.used, 75.5)
        XCTAssertEqual(credits.limit, 50)
    }

    func testIgnoresNonCreditBreakdowns() throws {
        let data = kiroUsageData(breakdowns: [
            ["resourceType": "REQUEST", "currentUsage": 99, "usageLimit": 100],
            ["resourceType": "CREDIT", "currentUsage": 3, "usageLimit": 50],
            ["resourceType": "TOKEN", "currentUsage": 1, "usageLimit": 10],
        ])

        let mapped = try KiroUsageMapper.map(data)

        XCTAssertEqual(mapped.lines.map(\.label), ["Credits"])
        XCTAssertEqual(progress(mapped.lines, label: "Credits")?.used, 3)
    }

    func testRejectsDuplicateUsableCreditBreakdowns() {
        let data = kiroUsageData(breakdowns: [
            ["resourceType": "CREDIT", "currentUsage": 1, "usageLimit": 10],
            ["resourceType": "credit", "currentUsage": 2, "usageLimit": 20],
        ])

        XCTAssertThrowsError(try KiroUsageMapper.map(data)) {
            XCTAssertEqual($0 as? KiroUsageError, .invalidResponse)
        }
    }

    func testMapsBreakdownResetThenTopLevelResetFallback() throws {
        let breakdownReset = try KiroUsageMapper.map(kiroUsageData(
            topLevelReset: 1_700_000_000,
            breakdown: [
                "resourceType": "CREDIT",
                "currentUsage": 1,
                "usageLimit": 50,
                "nextDateReset": 1_800_000_000,
            ]
        ))
        let fallbackReset = try KiroUsageMapper.map(kiroUsageData(
            topLevelReset: 1_700_000_000,
            breakdown: [
                "resourceType": "CREDIT",
                "currentUsage": 1,
                "usageLimit": 50,
            ]
        ))
        let nullReset = try KiroUsageMapper.map(kiroUsageData(
            topLevelReset: 1_700_000_000,
            breakdown: [
                "resourceType": "CREDIT",
                "currentUsage": 1,
                "usageLimit": 50,
                "nextDateReset": NSNull(),
            ]
        ))

        XCTAssertEqual(progress(breakdownReset.lines, label: "Credits")?.resetsAt?.timeIntervalSince1970, 1_800_000_000)
        XCTAssertEqual(progress(fallbackReset.lines, label: "Credits")?.resetsAt?.timeIntervalSince1970, 1_700_000_000)
        XCTAssertEqual(progress(nullReset.lines, label: "Credits")?.resetsAt?.timeIntervalSince1970, 1_700_000_000)
    }

    func testPreservesSubscriptionTitleAsPlan() throws {
        XCTAssertEqual(try KiroUsageMapper.map(kiroUsageData(plan: "  Kiro Pro  ")).plan, "Kiro Pro")
        XCTAssertNil(try KiroUsageMapper.map(kiroUsageData(plan: "   ")).plan)
    }

    func testBonusAndOverageFieldsDoNotEmitMetrics() throws {
        let data = kiroUsageData(
            breakdown: [
                "resourceType": "CREDIT",
                "currentUsage": 10,
                "usageLimit": 50,
                "bonuses": [["currentUsage": 1, "usageLimit": 5]],
            ],
            overage: [
                "overageStatus": "ENABLED",
                "currentUsage": 12,
                "usageLimit": 100,
            ]
        )

        let mapped = try KiroUsageMapper.map(data)

        XCTAssertEqual(mapped.lines.map(\.label), ["Credits"])
    }

    func testRejectsWronglyTypedOrMissingCreditBreakdown() {
        let invalidBodies = [
            Data(#"{}"#.utf8),
            Data(#"{"usageBreakdownList":"wrong"}"#.utf8),
            Data(#"{"usageBreakdownList":[42]}"#.utf8),
            Data(#"{"usageBreakdownList":[{"resourceType":"CREDIT","currentUsage":1}]}"#.utf8),
            Data(#"{"usageBreakdownList":[{"resourceType":"CREDIT","currentUsage":-1,"usageLimit":50}]}"#.utf8),
            Data(#"{"usageBreakdownList":[{"resourceType":"CREDIT","currentUsage":1,"usageLimit":0}]}"#.utf8),
        ]

        for body in invalidBodies {
            XCTAssertThrowsError(try KiroUsageMapper.map(body)) {
                XCTAssertEqual($0 as? KiroUsageError, .invalidResponse)
            }
        }
    }

    func testNoCreditBreakdownThrowsQuotaUnavailable() {
        let data = kiroUsageData(breakdowns: [
            ["resourceType": "REQUEST", "currentUsage": 1, "usageLimit": 10]
        ])

        XCTAssertThrowsError(try KiroUsageMapper.map(data)) {
            XCTAssertEqual($0 as? KiroUsageError, .quotaUnavailable)
        }
    }

    func testMalformedSubscriptionInfoThrowsInvalidResponse() {
        let data = kiroUsageData(subscriptionInfo: "wrong")

        XCTAssertThrowsError(try KiroUsageMapper.map(data)) {
            XCTAssertEqual($0 as? KiroUsageError, .invalidResponse)
        }
    }

    private func progress(
        _ lines: [MetricLine],
        label: String
    ) -> (used: Double, limit: Double, format: ProgressFormat, resetsAt: Date?, periodDurationMs: Int?)? {
        guard case .progress(
            _, let used, let limit, let format, let resetsAt, let periodDurationMs, _
        ) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return (used, limit, format, resetsAt, periodDurationMs)
    }
}

private func kiroUsageData(
    plan: String = "Kiro Pro",
    topLevelReset: Double? = nil,
    breakdown: [String: Any] = [
        "resourceType": "CREDIT",
        "currentUsage": 10,
        "currentUsageWithPrecision": 10.25,
        "usageLimit": 50,
        "usageLimitWithPrecision": 50.0,
        "nextDateReset": 1_788_134_400,
        "bonuses": [],
    ],
    overage: [String: Any] = ["overageStatus": "DISABLED"]
) -> Data {
    kiroUsageData(
        subscriptionInfo: ["subscriptionTitle": plan],
        topLevelReset: topLevelReset,
        breakdowns: [breakdown],
        overage: overage
    )
}

private func kiroUsageData(
    breakdowns: [[String: Any]],
    topLevelReset: Double? = nil
) -> Data {
    kiroUsageData(
        subscriptionInfo: ["subscriptionTitle": "Kiro Pro"],
        topLevelReset: topLevelReset,
        breakdowns: breakdowns,
        overage: ["overageStatus": "DISABLED"]
    )
}

private func kiroUsageData(subscriptionInfo: Any) -> Data {
    kiroUsageData(
        subscriptionInfo: subscriptionInfo,
        topLevelReset: nil,
        breakdowns: [["resourceType": "CREDIT", "currentUsage": 1, "usageLimit": 50]],
        overage: ["overageStatus": "DISABLED"]
    )
}

private func kiroUsageData(
    subscriptionInfo: Any,
    topLevelReset: Double?,
    breakdowns: [[String: Any]],
    overage: [String: Any]
) -> Data {
    var object: [String: Any] = [
        "subscriptionInfo": subscriptionInfo,
        "usageBreakdownList": breakdowns,
        "overageConfiguration": overage,
    ]
    if let topLevelReset { object["nextDateReset"] = topLevelReset }
    return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}
