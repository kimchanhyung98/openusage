import Foundation
import XCTest
@testable import OpenUsage

final class KimiUsageMapperTests: XCTestCase {
    func testMaps300MinuteWindowToSessionAndTopLevelUsageToWeekly() throws {
        let mapped = try KimiUsageMapper.map(Data(fullUsageJSON.utf8))

        XCTAssertEqual(mapped.plan, "Allegro")
        XCTAssertEqual(mapped.lines.map(\.label), ["Session", "Weekly"])

        let session = try XCTUnwrap(kimiProgress(mapped.lines, "Session"))
        XCTAssertEqual(session.used, 25, accuracy: 0.001)
        XCTAssertEqual(session.limit, 100)
        XCTAssertEqual(session.format, .percent)
        XCTAssertEqual(session.periodDurationMs, 18_000_000)
        XCTAssertEqual(session.resetsAt, OpenUsageISO8601.date(from: "2026-08-02T08:00:00Z"))

        let weekly = try XCTUnwrap(kimiProgress(mapped.lines, "Weekly"))
        XCTAssertEqual(weekly.used, 60, accuracy: 0.001)
        XCTAssertEqual(weekly.periodDurationMs, 604_800_000)
        XCTAssertEqual(weekly.resetsAt, OpenUsageISO8601.date(from: "2026-08-09T00:00:00Z"))
    }

    func testClassifiesSessionByDurationRatherThanArrayPosition() throws {
        let root: [String: Any] = [
            "limits": [
                [
                    "window": ["duration": 1, "timeUnit": "TIME_UNIT_DAY"],
                    "detail": ["limit": 100, "used": 99]
                ],
                [
                    "window": ["duration": 5, "timeUnit": "TIME_UNIT_HOUR"],
                    "detail": ["limit": 20, "used": 4]
                ]
            ]
        ]

        let mapped = try KimiUsageMapper.map(root)

        XCTAssertEqual(mapped.lines.map(\.label), ["Session"])
        XCTAssertEqual(kimiProgress(mapped.lines, "Session")?.used ?? -1, 20, accuracy: 0.001)
    }

    func testParsesStringCountsAndDerivesUsedFromRemaining() throws {
        let root: [String: Any] = [
            "limits": [[
                "window": ["duration": "300", "timeUnit": "TIME_UNIT_MINUTE"],
                "detail": [
                    "limit": "80",
                    "remaining": "60",
                    "resetTime": "2026-08-02T08:00:00.123Z"
                ]
            ]],
            "usage": ["limit": "200", "remaining": "50"]
        ]

        let mapped = try KimiUsageMapper.map(root)

        XCTAssertEqual(kimiProgress(mapped.lines, "Session")?.used ?? -1, 25, accuracy: 0.001)
        XCTAssertEqual(kimiProgress(mapped.lines, "Weekly")?.used ?? -1, 75, accuracy: 0.001)
        XCTAssertEqual(
            kimiProgress(mapped.lines, "Session")?.resetsAt,
            OpenUsageISO8601.date(from: "2026-08-02T08:00:00.123Z")
        )
    }

    func testUsedAboveLimitIsNotClamped() throws {
        let mapped = try KimiUsageMapper.map([
            "usage": ["limit": 100, "used": 125]
        ])

        XCTAssertEqual(kimiProgress(mapped.lines, "Weekly")?.used, 125)
    }

    func testRejectsDuplicateSessionCandidates() {
        let session: [String: Any] = [
            "window": ["duration": 300, "timeUnit": "TIME_UNIT_MINUTE"],
            "detail": ["limit": 100, "used": 10]
        ]

        XCTAssertThrowsError(try KimiUsageMapper.map(["limits": [session, session]])) { error in
            XCTAssertEqual(error as? KimiUsageError, .invalidResponse)
        }
    }

    func testRejectsWronglyTypedOrNonpositiveQuota() {
        let invalidRoots: [[String: Any]] = [
            ["limits": "wrong"],
            ["usage": "wrong"],
            ["usage": ["limit": 0, "used": 0]],
            ["usage": ["limit": 100, "used": -1]],
            ["usage": ["limit": true, "used": 1]],
            ["limits": [["window": ["duration": 300, "timeUnit": "TIME_UNIT_MINUTE"], "detail": "wrong"]]]
        ]

        for root in invalidRoots {
            XCTAssertThrowsError(try KimiUsageMapper.map(root)) { error in
                XCTAssertEqual(error as? KimiUsageError, .invalidResponse)
            }
        }
    }

    func testKnownMembershipLevelsMapToOfficialPlanNames() throws {
        let cases = [
            ("LEVEL_FREE", "Adagio"),
            ("LEVEL_BASIC", "Moderato"),
            ("LEVEL_INTERMEDIATE", "Allegretto"),
            ("LEVEL_ADVANCED", "Allegro"),
            ("LEVEL_STANDARD", "Vivace")
        ]

        for (level, expected) in cases {
            let mapped = try KimiUsageMapper.map([
                "user": ["membership": ["level": level]],
                "usage": ["limit": 100, "used": 1]
            ])
            XCTAssertEqual(mapped.plan, expected)
        }
    }

    func testUnknownMembershipLevelFallsBackToReadableValue() throws {
        let cases = [
            ("LEVEL_TEAM_PRO", "Team Pro"),
            ("level_team_pro", "Team Pro"),
            ("enterprise-custom", "Enterprise Custom"),
            ("UNKNOWN_FUTURE_TIER", "Unknown Future Tier")
        ]

        for (level, expected) in cases {
            let mapped = try KimiUsageMapper.map([
                "user": ["membership": ["level": level]],
                "usage": ["limit": 100, "used": 1]
            ])
            XCTAssertEqual(mapped.plan, expected)
        }
    }

    func testUnspecifiedMembershipLevelHasNoPlan() throws {
        let mapped = try KimiUsageMapper.map([
            "user": ["membership": ["level": "LEVEL_UNSPECIFIED"]],
            "usage": ["limit": 100, "used": 1]
        ])

        XCTAssertNil(mapped.plan)
    }

    func testBoosterWalletIsIgnoredWithoutChangingQuota() throws {
        let root: [String: Any] = [
            "boosterWallet": ["balance": 9_999, "currency": "USD"],
            "usage": ["limit": 100, "used": 20]
        ]

        let mapped = try KimiUsageMapper.map(root)

        XCTAssertEqual(mapped.lines.map(\.label), ["Weekly"])
        XCTAssertEqual(kimiProgress(mapped.lines, "Weekly")?.used, 20)
    }

    func testNoUsableQuotaThrowsQuotaUnavailable() {
        let roots: [[String: Any]] = [
            [:],
            ["user": ["membership": ["level": "LEVEL_TEAM"]]],
            ["limits": [[
                "window": ["duration": 1, "timeUnit": "TIME_UNIT_DAY"],
                "detail": ["limit": 100, "used": 1]
            ]]]
        ]

        for root in roots {
            XCTAssertThrowsError(try KimiUsageMapper.map(root)) { error in
                XCTAssertEqual(error as? KimiUsageError, .quotaUnavailable)
            }
        }
    }

    func testMalformedJSONThrowsInvalidResponse() {
        XCTAssertThrowsError(try KimiUsageMapper.map(Data("not-json".utf8))) { error in
            XCTAssertEqual(error as? KimiUsageError, .invalidResponse)
        }
    }

    private let fullUsageJSON = #"""
    {
      "user": {"membership": {"level": "LEVEL_ADVANCED"}},
      "limits": [
        {
          "window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"},
          "detail": {"limit": 400, "used": 100, "resetTime": "2026-08-02T08:00:00Z"}
        }
      ],
      "usage": {"limit": 1000, "used": 600, "resetTime": "2026-08-09T00:00:00Z"}
    }
    """#
}

private func kimiProgress(
    _ lines: [MetricLine],
    _ label: String
) -> (used: Double, limit: Double, format: ProgressFormat, resetsAt: Date?, periodDurationMs: Int?)? {
    guard case .progress(_, let used, let limit, let format, let resetsAt, let periodDurationMs, _) =
        lines.first(where: { $0.label == label })
    else {
        return nil
    }
    return (used, limit, format, resetsAt, periodDurationMs)
}
