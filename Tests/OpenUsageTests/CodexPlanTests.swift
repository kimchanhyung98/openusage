import XCTest

@testable import OpenUsage

final class CodexPlanTests: XCTestCase {
    func testMapsProTiersToDisplayNames() throws {
        for (planType, expected) in [
            ("prolite", "Pro Lite"),
            ("pro", "Pro"),
            ("promax", "Pro Max"),
            (" PRO \n", "Pro"),
            ("ProMax", "Pro Max"),
        ] {
            let body = try JSONSerialization.data(withJSONObject: ["plan_type": planType])
            let mapped = try CodexUsageMapper.mapUsageResponse(
                HTTPResponse(statusCode: 200, headers: [:], body: body)
            )

            XCTAssertEqual(mapped.plan, expected, planType)
        }
    }

    func testProTierDoesNotChangeReportedUsageOrReset() throws {
        let resetAt = 1_800_000_000
        let expected: [MetricLine] = [
            .progress(
                label: "Weekly",
                used: 37,
                limit: 100,
                format: .percent,
                resetsAt: Date(timeIntervalSince1970: TimeInterval(resetAt)),
                periodDurationMs: CodexUsageMapper.weeklyPeriodMs
            )
        ]
        for planType in ["prolite", "pro", "promax"] {
            let body = try JSONSerialization.data(withJSONObject: [
                "plan_type": planType,
                "rate_limit": [
                    "primary_window": [
                        "used_percent": 37,
                        "limit_window_seconds": 604_800,
                        "reset_at": resetAt,
                    ]
                ],
            ])
            let mapped = try CodexUsageMapper.mapUsageResponse(
                HTTPResponse(statusCode: 200, headers: [:], body: body)
            )

            XCTAssertEqual(mapped.lines, expected, planType)
        }
    }

    func testOtherPlansKeepTheirNames() {
        for (planType, expected) in [
            ("free", "Free"),
            ("go", "Go"),
            ("plus", "Plus"),
            ("team", "Team"),
            ("business", "Business"),
            ("enterprise", "Enterprise"),
            ("edu", "Edu"),
            ("future_plan", "Future Plan"),
        ] {
            XCTAssertEqual(CodexUsageMapper.formatCodexPlan(planType), expected)
        }
    }

    func testMissingOrInvalidPlanDoesNotInventATier() {
        for value in [nil, NSNull(), "", " \n", 200, ["pro"]] as [Any?] {
            XCTAssertNil(CodexUsageMapper.formatCodexPlan(value))
        }
    }
}
