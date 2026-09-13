import XCTest
@testable import OpenUsage

final class ZAIQuotaValidationMapperTests: XCTestCase {
    func testCreditAndTokenTypesKeepBothFieldAliasesWithoutDuplicatingEntries() throws {
        for kind in ["CREDIT_LIMIT", "TOKENS_LIMIT"] {
            for fields in [
                ["type": kind], ["name": kind],
                ["type": "FUTURE_LIMIT", "name": kind],
                ["type": kind, "name": "FUTURE_LIMIT"],
                ["type": kind, "name": kind]
            ] {
                var entry: [String: Any] = fields
                entry.merge(["unit": 3, "number": 5, "percentage": "25"]) { _, value in value }
                let body = try JSONSerialization.data(withJSONObject: ["data": ["limits": [entry]]])

                let lines = try ZAIUsageMapper.mapQuota(body)

                XCTAssertEqual(lines, [.progress(label: "Session", used: 25, limit: 100, format: .percent,
                                                periodDurationMs: 18_000_000)], "\(fields)")
            }
        }
    }

    func testMixedCreditTokenAndSearchQuotasKeepSeparateWindows() throws {
        let body = Data(#"""
        {"data":{"limits":[
          {"name":"CREDIT_LIMIT","unit":3,"number":5,"percentage":12},
          {"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":34},
          {"type":"TIME_LIMIT","usage":1000,"currentValue":7}
        ]}}
        """#.utf8)

        XCTAssertEqual(try ZAIUsageMapper.mapQuota(body).map(\.label), ["Session", "Weekly", "Web Searches"])
    }

    func testCreditQuotaRequiresValidPercentageAndWindow() {
        for fields in [
            #""unit":3,"number":5"#,
            #""unit":3,"number":5,"percentage":null"#,
            #""unit":3,"number":5,"percentage":true"#,
            #""unit":3,"number":5,"percentage":"NaN""#,
            #""unit":3,"number":5,"percentage":"Infinity""#,
            #""unit":3,"number":5,"percentage":"invalid""#,
            #""unit":true,"number":5,"percentage":1"#,
            #""unit":3,"number":0,"percentage":1"#,
            #""unit":3,"number":-1,"percentage":1"#,
            #""unit":3,"number":1e300,"percentage":1"#
        ] {
            let body = Data("{\"data\":{\"limits\":[{\"type\":\"CREDIT_LIMIT\",\(fields)}]}}".utf8)
            XCTAssertThrowsError(try ZAIUsageMapper.mapQuota(body), fields) { error in
                XCTAssertEqual(error as? ZAIUsageError, .invalidResponse)
            }
        }
    }

    func testMissingRequiredValuesNeverBecomeZeroUsage() {
        let malformedLimits = [
            #"{"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5}]}}"#,
            #"{"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":true}]}}"#,
            #"{"data":{"limits":[{"type":"TIME_LIMIT","usage":1000}]}}"#,
            #"{"data":{"limits":[{"type":"TIME_LIMIT","currentValue":10}]}}"#,
            #"{"data":{"limits":[{"type":"TIME_LIMIT","currentValue":-1,"usage":1000}]}}"#
        ]

        for body in malformedLimits {
            XCTAssertThrowsError(try ZAIUsageMapper.mapQuota(Data(body.utf8)), body) { error in
                XCTAssertEqual(error as? ZAIUsageError, .invalidResponse, body)
            }
        }
    }

    func testMalformedEnvelopeIsRejectedButExplicitEmptyLimitsRemainValid() throws {
        for body in ["not-json", #"{"data":[]}"#, #"{"data":{}}"#, #"{"data":{"limits":{}}}"#] {
            XCTAssertThrowsError(try ZAIUsageMapper.mapQuota(Data(body.utf8)), body) { error in
                XCTAssertEqual(error as? ZAIUsageError, .invalidResponse, body)
            }
        }

        let lines = try ZAIUsageMapper.mapQuota(Data(#"{"data":{"limits":[]}}"#.utf8))
        XCTAssertNotNil(lines.first { $0.label == "Status" })
    }

    func testUnknownEntriesDoNotHideKnownMeters() throws {
        let body = Data(
            #"{"data":{"limits":[{"type":"FUTURE_LIMIT"},{"type":"TOKENS_LIMIT","unit":99,"number":1,"percentage":70},{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":25}]}}"#.utf8
        )

        let lines = try ZAIUsageMapper.mapQuota(body)

        XCTAssertNotNil(lines.first { $0.label == "Session" })
        XCTAssertNil(lines.first { $0.label == "Weekly" })
    }

    func testOnlyUnknownLimitsRemainForwardCompatibleNoData() throws {
        let body = Data(
            #"{"data":{"limits":[{"type":"FUTURE_LIMIT"},{"type":"TOKENS_LIMIT","unit":99,"number":1,"percentage":70}]}}"#.utf8
        )

        let lines = try ZAIUsageMapper.mapQuota(body)

        XCTAssertNotNil(lines.first { $0.label == "Status" })
    }
}

@MainActor
final class ZAIQuotaValidationProviderTests: XCTestCase {
    func testCreditRefreshSurvivesSubscriptionFailureAndExportsExistingResources() async throws {
        let provider = ZAIProvider(
            authStore: ZAIAuthStore(files: FakeFiles(), environment: FakeEnvironment(["ZAI_API_KEY": "zai-test"])),
            usageClient: ZAIUsageClient(http: RoutingHTTPClient { request in
                guard request.url == ZAIUsageClient.quotaURL else {
                    return HTTPResponse(statusCode: 503, headers: [:], body: Data())
                }
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"""
                {"data":{"limits":[
                  {"type":"CREDIT_LIMIT","unit":3,"number":5,"percentage":0},
                  {"type":"CREDIT_LIMIT","unit":6,"number":1,"percentage":98}
                ]}}
                """#.utf8))
            })
        )

        let snapshot = await provider.refresh()
        let descriptors = provider.widgetDescriptors
        let state = LocalUsageAPI.State(enabledOrderedIDs: ["zai"], knownIDs: ["zai"],
                                        snapshots: ["zai": snapshot], limitDescriptors: ["zai": descriptors])
        let body = try XCTUnwrap(LocalUsageAPI.respond(method: "GET", path: "/v1/limits", state: state).body)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let providers = try XCTUnwrap(root["providers"] as? [String: Any])
        let zai = try XCTUnwrap(providers["zai"] as? [String: Any])
        let resources = try XCTUnwrap(zai["resources"] as? [String: Any])
        for (key, used, duration) in [("session", 0.0, 18_000.0), ("weekly", 98.0, 604_800.0)] {
            let resource = try XCTUnwrap(resources[key] as? [String: Any])
            XCTAssertEqual(resource["unit"] as? String, "percent")
            XCTAssertEqual(resource["used"] as? Double, used)
            XCTAssertEqual(resource["limit"] as? Double, 100)
            XCTAssertEqual(resource["windowSeconds"] as? Double, duration)
            XCTAssertNil(resource["resetsAt"])
        }
        XCTAssertNil(snapshot.plan)
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNil(snapshot.authenticationIssue)
        XCTAssertNil(snapshot.liveQuotaObservedAt)
        XCTAssertEqual(descriptors.first { $0.id == "zai.session" }?.softLimitWindow, .fiveHours)
        XCTAssertEqual(descriptors.first { $0.id == "zai.weekly" }?.softLimitWindow, .weekly)
    }

    func testMissingUsageReportsInvalidResponseInsteadOfZeroMeter() async {
        let provider = ZAIProvider(
            authStore: ZAIAuthStore(
                files: FakeFiles(),
                environment: FakeEnvironment(["ZAI_API_KEY": "zai-test"])
            ),
            usageClient: ZAIUsageClient(http: RoutingHTTPClient { request in
                if request.url == ZAIUsageClient.quotaURL {
                    return HTTPResponse(
                        statusCode: 200,
                        headers: [:],
                        body: Data(#"{"data":{"limits":[{"type":"CREDIT_LIMIT","unit":3,"number":5}]}}"#.utf8)
                    )
                }
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"data":[]}"#.utf8))
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .decoding)
        XCTAssertNil(snapshot.line(label: "Session"))
    }
}
