import XCTest
@testable import OpenUsage

final class AntigravityQuotaSummaryTests: XCTestCase {

    // MARK: - Helpers

    private func used(_ line: MetricLine?) -> Double? {
        guard case .progress(_, let used, _, _, _, _, _)? = line else { return nil }
        return used
    }

    private func resetsAt(_ line: MetricLine?) -> Date? {
        guard case .progress(_, _, _, _, let resetsAt, _, _)? = line else { return nil }
        return resetsAt
    }

    private func periodMs(_ line: MetricLine?) -> Int? {
        guard case .progress(_, _, _, _, _, let periodMs, _)? = line else { return nil }
        return periodMs
    }

    /// 네 bucket 전부, group 순서 섞임 — live probe에서 관측된 형태
    private let fullGroupsJSON = """
    "groups":[
      {"displayName":"Claude and other models","buckets":[
        {"bucketId":"3p-weekly","displayName":"Weekly","window":"weekly","remainingFraction":1,"resetTime":"2026-07-06T07:00:00Z"},
        {"bucketId":"3p-5h","displayName":"5-hour","window":"5h","remainingFraction":0.4,"resetTime":"2026-07-02T15:30:00Z"}
      ]},
      {"displayName":"Gemini models","buckets":[
        {"bucketId":"gemini-5h","displayName":"5-hour","window":"5h","remainingFraction":0.75,"resetTime":"2026-07-02T16:00:00Z"},
        {"bucketId":"gemini-weekly","displayName":"Weekly","window":"weekly","remainingFraction":0.9,"resetTime":"2026-07-06T07:00:00Z"}
      ]}
    ]
    """

    // MARK: - Parser

    func testWrappedAndBarePayloadsProduceIdenticalFourLines() {
        let bare = AntigravityUsageMapper.parseQuotaSummary(Data("{\(fullGroupsJSON)}".utf8))
        let wrapped = AntigravityUsageMapper.parseQuotaSummary(Data("{\"response\":{\(fullGroupsJSON)}}".utf8))
        XCTAssertEqual(bare, wrapped)

        guard let lines = bare else { return XCTFail("full summary did not parse") }
        XCTAssertEqual(lines.map(\.label), ["Session", "Weekly", "Claude", "Claude Weekly"])
        XCTAssertEqual(lines.map { used($0) }, [25, 10, 60, 0])
        XCTAssertEqual(resetsAt(lines[0]), OpenUsageISO8601.date(from: "2026-07-02T16:00:00Z"))
        XCTAssertEqual(resetsAt(lines[2]), OpenUsageISO8601.date(from: "2026-07-02T15:30:00Z"))
        XCTAssertEqual(lines.map { periodMs($0) }, [
            MetricPeriod.sessionMs, MetricPeriod.weekMs, MetricPeriod.sessionMs, MetricPeriod.weekMs
        ])
    }

    func testBucketWithoutRemainingFractionDropsItsLineOnly() {
        // 부재 fraction에서 0%/100% 조작 금지 ("full" 기본값 회귀) — 해당 bucket 라인만 drop
        let json = """
        {"groups":[{"buckets":[
          {"bucketId":"gemini-5h","resetTime":"2026-07-02T16:00:00Z"},
          {"bucketId":"gemini-weekly","remainingFraction":0.5,"resetTime":"2026-07-06T07:00:00Z"}
        ]}]}
        """
        let lines = AntigravityUsageMapper.parseQuotaSummary(Data(json.utf8))
        XCTAssertEqual(lines?.map(\.label), ["Weekly"])
        XCTAssertEqual(used(lines?.first), 50)
    }

    func testMalformedBucketDoesNotVoidTheEnvelope() {
        // garbage 요소·잘못된 타입 fraction이 summary 전체를 legacy fallback으로 보내지 않음 — 유효 bucket 생존
        let json = """
        {"groups":[{"buckets":[
          "junk",
          {"bucketId":"3p-5h","remainingFraction":"lots"},
          {"bucketId":"gemini-5h","remainingFraction":0.25,"resetTime":"2026-07-02T16:00:00Z"}
        ]}]}
        """
        let lines = AntigravityUsageMapper.parseQuotaSummary(Data(json.utf8))
        XCTAssertEqual(lines?.map(\.label), ["Session"])
        XCTAssertEqual(used(lines?.first), 75)
    }

    func testMissingResetTimeYieldsNilResetsAt() {
        let json = #"{"groups":[{"buckets":[{"bucketId":"gemini-5h","remainingFraction":0.5}]}]}"#
        let lines = AntigravityUsageMapper.parseQuotaSummary(Data(json.utf8))
        XCTAssertEqual(lines?.count, 1)
        XCTAssertEqual(used(lines?.first), 50)
        XCTAssertNil(resetsAt(lines?.first))
    }

    func testUnknownOrAbsentBucketIDIsSkippedNeverPooledByDisplayName() {
        // 미래 bucket(gemini-image-5h)·id 없는 bucket은 displayName으로 pool 합류 금지 — 알려진 bucketId만 바인딩
        let json = """
        {"groups":[{"buckets":[
          {"bucketId":"gemini-image-5h","displayName":"Session","window":"5h","remainingFraction":0.1},
          {"displayName":"Session","window":"5h","remainingFraction":0.2},
          {"bucketId":"gemini-5h","remainingFraction":0.75}
        ]}]}
        """
        let lines = AntigravityUsageMapper.parseQuotaSummary(Data(json.utf8))
        XCTAssertEqual(lines?.map(\.label), ["Session"])
        XCTAssertEqual(used(lines?.first), 25)
    }

    func testWeeklyOnlyAndSessionOnlyShapes() {
        // free tier는 5h bucket 부재 가능, Ultra는 weekly 부재 가능 — 둘 다 유효한 summary
        let weeklyOnly = """
        {"response":{"groups":[{"buckets":[
          {"bucketId":"gemini-weekly","remainingFraction":0.8},
          {"bucketId":"3p-weekly","remainingFraction":0.6}
        ]}]}}
        """
        let weeklyLines = AntigravityUsageMapper.parseQuotaSummary(Data(weeklyOnly.utf8))
        XCTAssertEqual(weeklyLines?.map(\.label), ["Weekly", "Claude Weekly"])
        XCTAssertEqual(weeklyLines?.compactMap { periodMs($0) }, [MetricPeriod.weekMs, MetricPeriod.weekMs])

        let sessionOnly = """
        {"groups":[{"buckets":[
          {"bucketId":"gemini-5h","remainingFraction":0.8},
          {"bucketId":"3p-5h","remainingFraction":0.6}
        ]}]}
        """
        let sessionLines = AntigravityUsageMapper.parseQuotaSummary(Data(sessionOnly.utf8))
        XCTAssertEqual(sessionLines?.map(\.label), ["Session", "Claude"])
        XCTAssertEqual(sessionLines?.compactMap { periodMs($0) }, [MetricPeriod.sessionMs, MetricPeriod.sessionMs])
    }

    func testUndecodableOrGrouplessBodyIsNotASummary() {
        XCTAssertNil(AntigravityUsageMapper.parseQuotaSummary(Data("not json".utf8)))
        XCTAssertNil(AntigravityUsageMapper.parseQuotaSummary(Data("{}".utf8)))
        XCTAssertNil(AntigravityUsageMapper.parseQuotaSummary(Data(#"{"response":{}}"#.utf8)))
    }

    func testEmptyGroupsParseAsAuthoritativeEmptySummary() {
        // 비nil 빈 배열 = "summary 응답, 사용 가능한 bucket 없음" — 100%-used를 조작하는 legacy 체인 진입 금지
        XCTAssertEqual(AntigravityUsageMapper.parseQuotaSummary(Data(#"{"groups":[]}"#.utf8)), [])
        XCTAssertEqual(AntigravityUsageMapper.parseQuotaSummary(Data(#"{"response":{"groups":[]}}"#.utf8)), [])
    }

    // MARK: - Label binding (metricLabel == MetricLine.label, exact string)

    @MainActor
    func testDescriptorLabelsMatchMapperEmittedLabels() {
        let descriptorLabels = Set(AntigravityProvider().widgetDescriptors.map(\.metricLabel))
        XCTAssertEqual(Set(AntigravityUsageMapper.summaryBuckets.map(\.label)), descriptorLabels)

        let summaryLines = AntigravityUsageMapper.parseQuotaSummary(Data("{\(fullGroupsJSON)}".utf8)) ?? []
        XCTAssertEqual(Set(summaryLines.map(\.label)), descriptorLabels)

        // legacy 경로는 5h pool 라벨 2개만 방출 — descriptor의 진부분집합
        let legacyLabels = Set(AntigravityUsageMapper.buildLines([
            AntigravityModelConfig(label: "Gemini 3 Pro", modelID: "a", remainingFraction: 1, resetTime: nil),
            AntigravityModelConfig(label: "Claude Opus", modelID: "b", remainingFraction: 1, resetTime: nil)
        ]).map(\.label))
        XCTAssertEqual(legacyLabels, ["Session", "Claude"])
        XCTAssertTrue(legacyLabels.isSubset(of: descriptorLabels))
    }

    // MARK: - Provider integration: Cloud Code transport

    @MainActor
    private func makeCloudCodeProvider(routing: RoutingHTTPClient) -> AntigravityProvider {
        let inner = #"{"token":{"access_token":"ya29.kc","refresh_token":"1//r","expiry":"2099-01-01T00:00:00Z"}}"#
        let wrapped = "go-keyring-base64:" + Data(inner.utf8).base64EncodedString()
        return AntigravityProvider(
            authStore: AntigravityAuthStore(keychain: FakeKeychain(wrapped), files: FakeFiles()),
            usageClient: AntigravityUsageClient(lsHTTP: routing, http: routing),
            discovery: LanguageServerDiscovery(processRunner: NoProcessRunner())
        )
    }

    @MainActor
    func testCloudCodeSummaryProducesFourMetersAndPlan() async {
        let groupsJSON = fullGroupsJSON
        let routing = RoutingHTTPClient { request in
            let path = request.url.path
            if path.contains("retrieveUserQuotaSummary") {
                // remote endpoint는 payload를 bare로 반환 ("response" wrapper 없음)
                return HTTPResponse(statusCode: 200, headers: [:], body: Data("{\(groupsJSON)}".utf8))
            }
            if path.contains("loadCodeAssist") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"paidTier":{"name":"Google AI Pro"}}"#.utf8))
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        let provider = makeCloudCodeProvider(routing: routing)

        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly", "Claude", "Claude Weekly"])
        XCTAssertEqual(snapshot.lines.map { used($0) }, [25, 10, 60, 0])
        XCTAssertFalse(routing.requests.contains { $0.url.path.contains("fetchAvailableModels") },
                       "a parsed summary must not touch the legacy model endpoints")
    }

    @MainActor
    func testCloudCodeAuthoritativeEmptySummarySkipsLegacyChain() async {
        // bucket 0개인 200 summary도 답 — 빈 라인의 정상 snapshot 반환, fetchAvailableModels/retrieveUserQuota 호출 금지
        let routing = RoutingHTTPClient { request in
            if request.url.path.contains("retrieveUserQuotaSummary") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"groups":[]}"#.utf8))
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        let provider = makeCloudCodeProvider(routing: routing)

        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertTrue(snapshot.lines.isEmpty)
        XCTAssertNil(snapshot.plan)
        XCTAssertFalse(routing.requests.contains { $0.url.path.contains("fetchAvailableModels") })
        XCTAssertFalse(routing.requests.contains { $0.url.path == AntigravityUsageClient.retrieveQuotaPath })
    }

    // MARK: - Provider integration: language-server transport

    @MainActor
    private func makeLSProvider(routing: RoutingHTTPClient) -> AntigravityProvider {
        AntigravityProvider(
            authStore: AntigravityAuthStore(keychain: FakeKeychain(nil), files: FakeFiles()),
            usageClient: AntigravityUsageClient(lsHTTP: routing, http: routing),
            discovery: LanguageServerDiscovery(processRunner: FakeLSProcessRunner())
        )
    }

    @MainActor
    func testLSWrappedSummaryWinsOverLegacyEndpointsAndTakesPlanFromUserStatus() async {
        let groupsJSON = fullGroupsJSON
        let routing = RoutingHTTPClient { request in
            let path = request.url.path
            if path.hasSuffix("/RetrieveUserQuotaSummary") {
                // LS는 payload를 {"response": ...}로 감쌈
                return HTTPResponse(statusCode: 200, headers: [:], body: Data("{\"response\":{\(groupsJSON)}}".utf8))
            }
            if path.hasSuffix("/GetUserStatus") {
                let body = """
                {"userStatus":{"userTier":{"name":"Google AI Pro"},
                "cascadeModelConfigData":{"clientModelConfigs":[
                  {"label":"Gemini 3 Pro","quotaInfo":{"remainingFraction":0.99}}
                ]}}}
                """
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
            }
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }
        let provider = makeLSProvider(routing: routing)

        let snapshot = await provider.refresh()
        // summary 값이 승 — legacy GetUserStatus config가 pool할 1%-used 단일 라인 아님
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly", "Claude", "Claude Weekly"])
        XCTAssertEqual(snapshot.lines.map { used($0) }, [25, 10, 60, 0])
        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertFalse(routing.requests.contains { $0.url.path.hasSuffix("/GetCommandModelConfigs") })
    }

    @MainActor
    func testLSAuthoritativeEmptySummaryStopsProbeEvenWhenPlanCallFails() async {
        let routing = RoutingHTTPClient { request in
            if request.url.path.hasSuffix("/RetrieveUserQuotaSummary") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"response":{"groups":[]}}"#.utf8))
            }
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }
        let provider = makeLSProvider(routing: routing)

        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertTrue(snapshot.lines.isEmpty)
        XCTAssertNil(snapshot.plan)
        XCTAssertFalse(routing.requests.contains { $0.url.path.hasSuffix("/GetCommandModelConfigs") })
        // authoritative 답이 첫 endpoint에서 probe 중단 — 다른 LS port·Cloud Code fallback 없음
        XCTAssertTrue(routing.requests.allSatisfy { $0.url.host == "127.0.0.1" && $0.url.port == 52168 })
    }

    @MainActor
    func testLSSummary404FallsBackToLegacyMergedPools() async {
        // RPC 없는 빌드는 404 — legacy GetUserStatus 흐름이 source 유지 (5h 전용)
        let routing = RoutingHTTPClient { request in
            let path = request.url.path
            if path.hasSuffix("/RetrieveUserQuotaSummary") {
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
            if path.hasSuffix("/GetUserStatus") {
                let body = """
                {"userStatus":{"userTier":{"name":"Google AI Pro"},
                "cascadeModelConfigData":{"clientModelConfigs":[
                  {"label":"Gemini 3 Pro","quotaInfo":{"remainingFraction":0.5}},
                  {"label":"Claude Sonnet 4.6","quotaInfo":{"remainingFraction":0.8}}
                ]}}}
                """
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
            }
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }
        let provider = makeLSProvider(routing: routing)

        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Claude"])
        XCTAssertEqual(snapshot.lines.map { used($0) }, [50, 20])
        XCTAssertEqual(snapshot.plan, "Pro")
    }
}

/// 모든 subprocess에 빈 출력 반환 — LS discovery가 아무것도 못 찾아 Cloud Code 경로를 결정적으로 검증
private struct NoProcessRunner: ProcessRunning {
    func run(executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval) throws -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }
}

/// 실행 중인 Antigravity `language_server`(pid 4276, listening port 52168) fake — 실제 subprocess 없이 LS probe 검증
private struct FakeLSProcessRunner: ProcessRunning {
    func run(executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval) throws -> ProcessResult {
        if executable.hasSuffix("/ps") {
            let ps = "4276 /Applications/Antigravity.app/Contents/Resources/bin/language_server --standalone --override_ide_name antigravity --csrf_token tok --app_data_dir antigravity\n"
            return ProcessResult(exitCode: 0, stdout: ps, stderr: "")
        }
        let lsof = "language_ 4276 user 6u IPv4 0x0 0t0 TCP 127.0.0.1:52168 (LISTEN)\n"
        return ProcessResult(exitCode: 0, stdout: lsof, stderr: "")
    }
}
