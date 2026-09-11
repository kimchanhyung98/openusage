import XCTest
@testable import OpenUsage

final class ModelPricingStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pricing-store-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testMalformedRemoteCatalogsAreDecodingFailures() async {
        let diagnostics = DiagnosticEventRecorder()
        let (store, http) = makeStore { request in
            if request.url.absoluteString.contains("litellm") || request.url.host() == "models.dev" {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data("PRIVATE_INVALID_JSON".utf8))
            }
            return Self.respond(to: request)
        }

        await store.refreshNow()

        XCTAssertEqual(http.requests.count, 3)
        let failures = diagnostics.events.filter { $0.operation == .pricingLiteLLM || $0.operation == .pricingModelsDev }
        XCTAssertEqual(failures, [
            DiagnosticEvent(.pricingLiteLLM, result: .failure, category: .decoding),
            DiagnosticEvent(.pricingModelsDev, result: .failure, category: .decoding)
        ])
    }

    func testStructurallyInvalidCatalogsAreDecodingFailuresAndKeepCachedPrices() async throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let later = base.addingTimeInterval(2 * 60 * 60)
        let cases: [(String, PricingCodecError)] = [("[]", .notAnObject), ("{}", .noUsableEntries)]
        for (index, testCase) in cases.enumerated() {
            let cacheDirectory = tempDir.appendingPathComponent("case-\(index)", isDirectory: true)
            let (store, _) = makeStore(handler: { Self.respond(to: $0) }, now: { base }, cacheDirectory: cacheDirectory)
            await store.refreshNow()
            let (body, expectedError) = testCase
            let data = Data(body.utf8)
            for parse in [PricingCatalogCodecs.catalogFromLiteLLM, PricingCatalogCodecs.catalogFromModelsDev] {
                XCTAssertThrowsError(try parse(data)) { XCTAssertEqual($0 as? PricingCodecError, expectedError) }
            }
            let diagnostics = DiagnosticEventRecorder()
            let (aged, http) = makeStore(handler: { request in
                if request.url.absoluteString.contains("litellm") || request.url.host() == "models.dev" {
                    return HTTPResponse(statusCode: 200, headers: [:], body: data)
                }
                return Self.respond(to: request)
            }, now: { later }, cacheDirectory: cacheDirectory)

            await aged.refreshNow()

            XCTAssertEqual(http.requests.count, 3)
            let failures = diagnostics.events.filter { $0.operation == .pricingLiteLLM || $0.operation == .pricingModelsDev }
            XCTAssertEqual(failures, [
                DiagnosticEvent(.pricingLiteLLM, result: .failure, category: .decoding),
                DiagnosticEvent(.pricingModelsDev, result: .failure, category: .decoding)
            ])
            let pricing = await aged.current()
            XCTAssertEqual(pricing.resolve(model: "fetched-model")?.inputPerMillion, 5)
            XCTAssertEqual(pricing.resolve(model: "fetched-dev-model")?.inputPerMillion, 1)
        }
    }

    func testPartiallyValidCatalogsKeepUsableEntries() async {
        let diagnostics = DiagnosticEventRecorder()
        let (store, _) = makeStore { request in
            if request.url.absoluteString.contains("litellm") {
                let body = #"{"good-model":{"input_cost_per_token":0.000005,"output_cost_per_token":0.00001},"bad-model":{}}"#
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
            }
            if request.url.host() == "models.dev" {
                let body = #"{"provider":{"models":{"good-dev-model":{"cost":{"input":1,"output":2}},"bad-dev-model":{}}}}"#
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
            }
            return Self.respond(to: request)
        }

        await store.refreshNow()

        let pricing = await store.current()
        XCTAssertEqual(pricing.resolve(model: "good-model")?.inputPerMillion, 5)
        XCTAssertEqual(pricing.resolve(model: "good-dev-model")?.inputPerMillion, 1)
        XCTAssertNil(pricing.resolve(model: "bad-model"))
        XCTAssertNil(pricing.resolve(model: "bad-dev-model"))
        let events = diagnostics.events.filter { $0.operation == .pricingLiteLLM || $0.operation == .pricingModelsDev }
        XCTAssertEqual(events, [
            DiagnosticEvent(.pricingLiteLLM, result: .success),
            DiagnosticEvent(.pricingModelsDev, result: .success)
        ])
    }

    private static let bundledFixtures: @Sendable (String) -> Data? = { name in
        switch name {
        case "pricing_supplement":
            return Data("""
            {"pricing": {"auto": {"input_per_million": 1.25, "output_per_million": 6.0}},
             "fast_multipliers": {}, "alias_rules": []}
            """.utf8)
        case "pricing_litellm_snapshot":
            return Data(#"{"models": {"bundled-model": {"i": 1, "o": 2, "cw": 1, "cr": 0.1}}}"#.utf8)
        case "pricing_models_dev_snapshot":
            return Data(#"{"models": {"bundled-dev-model": {"i": 3, "o": 4, "cw": 3, "cr": 0.3}}}"#.utf8)
        default:
            return nil
        }
    }

    private static let litellmFeed = """
    {"fetched-model": {"input_cost_per_token": 5e-06, "output_cost_per_token": 1e-05,
                       "cache_read_input_token_cost": 5e-07}}
    """

    private static let modelsDevFeed = """
    {"xai": {"models": {"fetched-dev-model": {"cost": {"input": 1, "output": 2, "cache_read": 0.2}}}}}
    """

    private static let supplementFeed = """
    {"pricing": {"auto": {"input_per_million": 9.0, "output_per_million": 9.0}},
     "fast_multipliers": {}, "alias_rules": []}
    """

    private func makeStore(
        handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse,
        now: @escaping @Sendable () -> Date = Date.init,
        cacheDirectory: URL? = nil
    ) -> (ModelPricingStore, RoutingHTTPClient) {
        let http = RoutingHTTPClient(handler: handler)
        let store = ModelPricingStore(
            http: http,
            cacheDirectory: cacheDirectory ?? tempDir,
            now: now,
            bundledData: Self.bundledFixtures
        )
        return (store, http)
    }

    private static func respond(to request: HTTPRequest) -> HTTPResponse {
        let body: String
        if request.url.absoluteString.contains("litellm") {
            body = litellmFeed
        } else if request.url.host() == "models.dev" {
            body = modelsDevFeed
        } else {
            body = supplementFeed
        }
        return HTTPResponse(statusCode: 200, headers: ["etag": "\"v1\""], body: Data(body.utf8))
    }

    func testServesBundledDataBeforeAnyFetch() async throws {
        let (store, _) = makeStore(handler: { _ in
            throw URLError(.notConnectedToInternet)
        })
        let pricing = await store.current()
        XCTAssertEqual(pricing.resolve(model: "bundled-model")?.inputPerMillion, 1)
        XCTAssertEqual(pricing.resolve(model: "bundled-dev-model")?.inputPerMillion, 3)
        XCTAssertEqual(pricing.resolve(model: "auto")?.inputPerMillion, 1.25)
    }

    func testRefreshFetchesAllSourcesAndAppliesData() async throws {
        let (store, http) = makeStore(handler: { Self.respond(to: $0) })
        await store.refreshNow()
        XCTAssertEqual(http.requests.count, 3)

        let pricing = await store.current()
        XCTAssertEqual(pricing.resolve(model: "fetched-model")?.inputPerMillion, 5)
        XCTAssertEqual(pricing.resolve(model: "fetched-dev-model")?.inputPerMillion, 1)
        XCTAssertEqual(pricing.resolve(model: "auto")?.inputPerMillion, 9, "fetched supplement replaces bundled")
        XCTAssertEqual(pricing.resolve(model: "bundled-model")?.inputPerMillion, 1, "bundled entries survive the merge")
    }

    func testCachePersistsAcrossStoreInstances() async throws {
        let (store, _) = makeStore(handler: { Self.respond(to: $0) })
        await store.refreshNow()

        // 두 번째 store는 network 차단 — cached fetch 결과 그대로 적용
        let (revived, http) = makeStore(handler: { _ in throw URLError(.notConnectedToInternet) })
        let pricing = await revived.current()
        XCTAssertEqual(pricing.resolve(model: "fetched-model")?.inputPerMillion, 5)
        XCTAssertEqual(pricing.resolve(model: "auto")?.inputPerMillion, 9)
        // 신선한 state file — TTL 경과까지 refetch 대상 없음
        await revived.refreshNow()
        XCTAssertTrue(http.requests.isEmpty, "sources within TTL must not refetch")
    }

    func testRefetchAfterTTLSendsETagAndHandles304() async throws {
        let (store, _) = makeStore(handler: { Self.respond(to: $0) })
        await store.refreshNow()

        let later = Date().addingTimeInterval(2 * 60 * 60)
        let (aged, http) = makeStore(
            handler: { request in
                XCTAssertEqual(request.headers["If-None-Match"], "\"v1\"")
                return HTTPResponse(statusCode: 304, headers: [:], body: Data())
            },
            now: { later }
        )
        await aged.refreshNow()
        XCTAssertEqual(http.requests.count, 3, "all sources past TTL revalidate")

        let pricing = await aged.current()
        XCTAssertEqual(pricing.resolve(model: "fetched-model")?.inputPerMillion, 5, "304 keeps cached data")
    }

    func testFetchFailureKeepsServingCachedData() async throws {
        let (store, _) = makeStore(handler: { Self.respond(to: $0) })
        await store.refreshNow()

        let later = Date().addingTimeInterval(2 * 60 * 60)
        let (aged, _) = makeStore(handler: { _ in
            HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }, now: { later })
        await aged.refreshNow()
        let pricing = await aged.current()
        XCTAssertEqual(pricing.resolve(model: "fetched-model")?.inputPerMillion, 5)
        XCTAssertEqual(pricing.resolve(model: "auto")?.inputPerMillion, 9)
    }

    func testGarbageFeedDoesNotReplaceGoodCache() async throws {
        let (store, _) = makeStore(handler: { Self.respond(to: $0) })
        await store.refreshNow()

        let later = Date().addingTimeInterval(2 * 60 * 60)
        let (aged, _) = makeStore(handler: { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: Data("not json".utf8))
        }, now: { later })
        await aged.refreshNow()
        let pricing = await aged.current()
        XCTAssertEqual(pricing.resolve(model: "fetched-model")?.inputPerMillion, 5)
    }

    func testFailureRetryIntervalPreventsHammering() async throws {
        let counter = OSAllocatedUnfairLockedCounter()
        let (store, _) = makeStore(handler: { _ in
            counter.increment()
            throw URLError(.notConnectedToInternet)
        })
        await store.refreshNow()
        XCTAssertEqual(counter.value, 3)
        // 실패 직후에는 재시도 대상 없음
        await store.refreshNow()
        XCTAssertEqual(counter.value, 3)
    }
}

/// Sendable closure 간 request 수 집계용 thread-safe counter
private final class OSAllocatedUnfairLockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}
