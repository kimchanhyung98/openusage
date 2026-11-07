import XCTest
@testable import Egasu

final class ZAIDetailMapperTests: XCTestCase {
    func testAggregateBucketsMatchEveryModelAtEachAxisPosition() throws {
        let parsed = try map(buckets: [
            ["modelCode": "cached_input", "totalTokensUsage": [20, 40]],
            ["modelCode": "uncached_input", "tokensUsage": [60, 80]],
            ["modelCode": "output", "totalTokensUsage": [100, 120]]
        ])
        XCTAssertEqual(parsed.days["2026-11-02"]?.tokens, 420)
        XCTAssertEqual(parsed.days["2026-11-02"]?.tokensComplete, true)
        XCTAssertNotNil(parsed.days["2026-11-02"]?.costUSD)
    }

    func testMismatchedBucketAmountsOrAxisLengthsAreRejected() {
        for code in ["cached_input", "uncached_input", "output"] {
            for values in [[999, 999], [1], [20, 40, 60]] {
                XCTAssertThrowsError(try map(buckets: [["modelCode": code, "totalTokensUsage": values]]), code)
            }
        }
        XCTAssertThrowsError(try map(buckets: [
            ["modelCode": "cached_input", "totalTokensUsage": [40, 20]]
        ]))
    }

    private func map(buckets: [[String: Any]]) throws -> ZAIDetailMapper.Parsed {
        let models = ["glm-4.5", "glm-4.5-air"].map { model -> [String: Any] in
            ["modelCode": model, "cachedInputTokensUsage": [10, 20],
             "uncachedInputTokensUsage": [30, 40], "outputTokensUsage": [50, 60]]
        }
        let body = try JSONSerialization.data(withJSONObject: [
            "data": ["modelUsage": ["xTime": ["00:00:00", "01:00:00"], "modelDataList": buckets + models]]
        ])
        return try ZAIDetailMapper.map(
            body, window: ZAIDetailWindow(days: ["2026-11-02"], hourly: true, hourlyThrough: 1),
            pricing: TestPricing.bundled
        )
    }
}
