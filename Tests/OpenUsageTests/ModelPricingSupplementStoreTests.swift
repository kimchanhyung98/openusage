import XCTest
@testable import OpenUsage

final class ModelPricingSupplementStoreTests: XCTestCase {
    private static let oldSource = URL(string: "https://old.example/pricing.json")!
    private static let newSource = URL(string: "https://new.example/pricing.json")!
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("supplement-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testDefaultSupplementBelongsToFork() {
        XCTAssertEqual(ModelPricingStore.defaultSourceURLs[.supplement]?.absoluteString,
                       "https://openusage.chanhyung.kim/pricing_supplement.json")
    }

    func testSourceChangeDiscardsCacheETagAndFreshTTL() async throws {
        let (old, _) = makeStore(source: Self.oldSource, response: Self.supplement(rate: 9))
        await old.refreshNow()
        let (changed, http) = makeStore(response: Self.supplement(rate: 3))

        let initial = await changed.current()
        XCTAssertEqual(initial.resolve(model: "auto")?.inputPerMillion, 1)
        await changed.refreshNow()

        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(http.requests.first?.url, Self.newSource)
        XCTAssertNil(http.requests.first?.headers["If-None-Match"])
        let refreshed = await changed.current()
        XCTAssertEqual(refreshed.resolve(model: "auto")?.inputPerMillion, 3)

        let (revived, nextHTTP) = makeStore()
        await revived.refreshNow()
        XCTAssertTrue(nextHTTP.requests.isEmpty)
        let cached = await revived.current()
        XCTAssertEqual(cached.resolve(model: "auto")?.inputPerMillion, 3)
    }

    func testSourceChangeIgnoresOldFailureBackoffButPersistsNewBackoff() async {
        let (old, _) = makeStore(source: Self.oldSource)
        await old.refreshNow()
        let (changed, http) = makeStore()
        await changed.refreshNow()
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertNil(http.requests.first?.headers["If-None-Match"])

        let (revived, nextHTTP) = makeStore()
        await revived.refreshNow()
        XCTAssertTrue(nextHTTP.requests.isEmpty)
        let pricing = await revived.current()
        XCTAssertEqual(pricing.resolve(model: "auto")?.inputPerMillion, 1)
    }

    func testLegacyCacheAndStateDoNotSuppressForkFetchOrChangeCatalogCaches() async throws {
        let legacy = Self.supplement(rate: 99, date: "2099-01-01")
        try legacy.write(to: directory.appendingPathComponent("supplement.json"))
        let state: [String: Any] = ["etag": "old", "fetchedAt": Self.now.timeIntervalSinceReferenceDate,
                                    "failedAt": Self.now.timeIntervalSinceReferenceDate]
        let states: [Any] = ["supplement", state, "litellm", state, "models_dev", state]
        try JSONSerialization.data(withJSONObject: states).write(to: directory.appendingPathComponent("state.json"))
        let catalog = Data(#"{"models":{"catalog-only":{"i":7,"o":8,"cw":7,"cr":0.7}}}"#.utf8)
        for file in ["litellm.json", "models_dev.json"] {
            try catalog.write(to: directory.appendingPathComponent(file))
        }
        let http = RoutingHTTPClient { _ in throw URLError(.notConnectedToInternet) }
        let store = ModelPricingStore(http: http, cacheDirectory: directory, now: { Self.now },
                                      bundledData: { name in
            name == "pricing_supplement" ? Self.supplement(rate: 1) : Data(#"{"models":{}}"#.utf8)
        })

        await store.refreshNow()

        XCTAssertEqual(http.requests.map(\.url), [ModelPricingStore.defaultSourceURLs[.supplement]!])
        let pricing = await store.current()
        XCTAssertEqual(pricing.resolve(model: "auto")?.inputPerMillion, 1)
        XCTAssertEqual(pricing.resolve(model: "catalog-only")?.inputPerMillion, 7)
        for file in ["litellm.json", "models_dev.json"] {
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(file)), catalog)
        }
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with:
            Data(contentsOf: directory.appendingPathComponent("state.json"))) as? [Any])
        for source in ["litellm", "models_dev"] {
            let index = try XCTUnwrap(saved.firstIndex { ($0 as? String) == source })
            let preserved = try XCTUnwrap(saved[index + 1] as? [String: Any])
            XCTAssertEqual(preserved["etag"] as? String, "old")
            XCTAssertEqual(preserved["fetchedAt"] as? Double, Self.now.timeIntervalSinceReferenceDate)
            XCTAssertEqual(preserved["failedAt"] as? Double, Self.now.timeIntervalSinceReferenceDate)
        }
    }

    func testBodyProvenanceRejectsCacheEvenWhenStateClaimsCurrentSource() async throws {
        let (old, _) = makeStore(source: Self.oldSource, response: Self.supplement(rate: 99))
        await old.refreshNow()
        let oldBody = try Data(contentsOf: directory.appendingPathComponent("supplement.json"))
        let (changed, _) = makeStore(response: Self.supplement(rate: 3))
        await changed.refreshNow()
        try oldBody.write(to: directory.appendingPathComponent("supplement.json"))
        let (revived, http) = makeStore()

        await revived.refreshNow()

        XCTAssertEqual(http.requests.count, 1)
        XCTAssertNil(http.requests.first?.headers["If-None-Match"])
        let pricing = await revived.current()
        XCTAssertEqual(pricing.resolve(model: "auto")?.inputPerMillion, 1)
    }

    func testSameSourceSelectsNewestValidDateAndCacheWinsTies() async throws {
        let cases: [(String?, String?, Double)] = [
            ("2026-09-01", "2026-09-02", 2),
            ("2026-09-02", "2026-09-01", 9),
            ("2026-09-02", "2026-09-02", 9),
            ("2026-09-02", "2026-09-02T12:00:00Z", 2),
            ("2026-09-02T12:00:00Z", "2026-09-02T13:00:00Z", 2),
            ("2026-09-02T13:00:00Z", "2026-09-02T12:00:00Z", 9),
            ("2026-09-02", "2026-09-02T00:00:00Z", 9),
            (nil, "2026-09-02", 2), ("2026-09-02", nil, 9), (nil, nil, 9),
            ("not-a-date", "2026-09-02", 2), ("2026-09-02", "not-a-date", 9),
            ("2026-02-30", "2026-09-02", 2), ("9999", "2026-09-02", 2),
            ("2026-09-02T12:00:00+00:00", "2026-09-02", 2),
            ("2026-09-02T12:00:00.500Z", "2026-09-02", 2)
        ]
        for (index, entry) in cases.enumerated() {
            let path = directory.appendingPathComponent("case-\(index)", isDirectory: true)
            let (seed, _) = makeStore(response: Self.supplement(rate: 9, date: entry.0), path: path)
            await seed.refreshNow()
            let (revived, http) = makeStore(bundle: Self.supplement(rate: 2, date: entry.1), path: path)

            await revived.refreshNow()

            XCTAssertTrue(http.requests.isEmpty)
            let pricing = await revived.current()
            XCTAssertEqual(pricing.resolve(model: "auto")?.inputPerMillion, entry.2, "case \(index)")
        }
    }

    func testSameDay200ReplacesCacheWhileOlderFeedDoesNotDisplaceNewerBundle() async {
        let date = "2026-09-02"
        let (seed, _) = makeStore(response: Self.supplement(rate: 9, date: date))
        await seed.refreshNow()
        let later = Self.now.addingTimeInterval(3_601)
        let (refreshed, http) = makeStore(bundle: Self.supplement(rate: 2, date: date),
                                         response: Self.supplement(rate: 3, date: date), now: later)
        await refreshed.refreshNow()
        XCTAssertEqual(http.requests.first?.headers["If-None-Match"], "\"v1\"")
        let sameDay = await refreshed.current()
        XCTAssertEqual(sameDay.resolve(model: "auto")?.inputPerMillion, 3)

        let (newBundle, _) = makeStore(bundle: Self.supplement(rate: 4, date: "2026-09-03"),
                                       response: Self.supplement(rate: 5, date: date),
                                       now: later.addingTimeInterval(3_601))
        await newBundle.refreshNow()
        let pricing = await newBundle.current()
        XCTAssertEqual(pricing.resolve(model: "auto")?.inputPerMillion, 4)
    }

    func testOfflineNewerBundleAndSameSource304KeepCorrectSnapshot() async {
        let (seed, _) = makeStore(response: Self.supplement(rate: 9, date: "2026-09-01"))
        await seed.refreshNow()
        let later = Self.now.addingTimeInterval(3_601)
        let bundle = Self.supplement(rate: 2, date: "2026-09-02")
        let (offline, _) = makeStore(bundle: bundle, now: later)
        await offline.refreshNow()
        let initial = await offline.current()
        XCTAssertEqual(initial.resolve(model: "auto")?.inputPerMillion, 2)

        let (notModified, http) = makeStore(bundle: bundle, status: 304, now: later.addingTimeInterval(1_801))
        await notModified.refreshNow()
        XCTAssertEqual(http.requests.first?.headers["If-None-Match"], "\"v1\"")
        let pricing = await notModified.current()
        XCTAssertEqual(pricing.resolve(model: "auto")?.inputPerMillion, 2)
    }

    func testCorruptOrMissingCacheForcesUnconditionalRequestWithoutReplacingBundle() async throws {
        for corrupt in [false, true] {
            let folder = directory.appendingPathComponent("corrupt-\(corrupt)", isDirectory: true)
            let (seed, _) = makeStore(response: Self.supplement(rate: 9), path: folder)
            await seed.refreshNow()
            let path = folder.appendingPathComponent("supplement.json")
            if corrupt { try Data("invalid".utf8).write(to: path) }
            else { try FileManager.default.removeItem(at: path) }
            let (revived, http) = makeStore(path: folder)
            await revived.refreshNow()
            XCTAssertEqual(http.requests.count, 1)
            XCTAssertNil(http.requests.first?.headers["If-None-Match"])
            let pricing = await revived.current()
            XCTAssertEqual(pricing.resolve(model: "auto")?.inputPerMillion, 1)
        }
    }

    func testCorruptBundleUsesMatchingCacheAndBothCorruptYieldEmpty() async throws {
        let (seed, _) = makeStore(response: Self.supplement(rate: 9))
        await seed.refreshNow()
        for bundle in [nil, Data("invalid".utf8)] {
            let (revived, _) = makeStore(bundle: bundle)
            let pricing = await revived.current()
            XCTAssertEqual(pricing.resolve(model: "auto")?.inputPerMillion, 9)
            await revived.refreshNow()
        }
        try Data("invalid".utf8).write(to: directory.appendingPathComponent("supplement.json"))
        let (empty, _) = makeStore(bundle: Data("invalid".utf8))
        await empty.refreshNow()
        let pricing = await empty.current()
        XCTAssertNil(pricing.resolve(model: "auto"))
    }

    func testInvalidRemoteBodyPreservesGoodCacheAndRecordsDecodingFailure() async throws {
        let (seed, _) = makeStore(response: Self.supplement(rate: 9))
        await seed.refreshNow()
        let before = try Data(contentsOf: directory.appendingPathComponent("supplement.json"))
        let diagnostics = DiagnosticEventRecorder()
        let (invalid, _) = makeStore(response: Data("invalid".utf8), now: Self.now.addingTimeInterval(3_601))
        await invalid.refreshNow()
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("supplement.json")), before)
        let pricing = await invalid.current()
        XCTAssertEqual(pricing.resolve(model: "auto")?.inputPerMillion, 9)
        XCTAssertEqual(diagnostics.events.filter { $0.operation == .pricingSupplement },
                       [DiagnosticEvent(.pricingSupplement, result: .failure, category: .decoding)])
    }

    func testUnsolicited304IsFailureAndNextRequestRemainsUnconditional() async {
        let diagnostics = DiagnosticEventRecorder()
        let (notModified, _) = makeStore(status: 304)
        await notModified.refreshNow()
        XCTAssertEqual(diagnostics.events.filter { $0.operation == .pricingSupplement },
                       [DiagnosticEvent(.pricingSupplement, result: .failure, category: .decoding)])
        let (retry, http) = makeStore(response: Self.supplement(rate: 3), now: Self.now.addingTimeInterval(1_801))
        await retry.refreshNow()
        XCTAssertNil(http.requests.first?.headers["If-None-Match"])
        let pricing = await retry.current()
        XCTAssertEqual(pricing.resolve(model: "auto")?.inputPerMillion, 3)
    }

    private func makeStore(
        source: URL = newSource,
        bundle: Data? = supplement(rate: 1),
        response: Data? = nil,
        status: Int = 200,
        now: Date = now,
        path: URL? = nil
    ) -> (ModelPricingStore, RoutingHTTPClient) {
        let http = RoutingHTTPClient { _ in
            if response == nil, status == 200 { throw URLError(.notConnectedToInternet) }
            return HTTPResponse(statusCode: status, headers: ["etag": "\"v1\""], body: response ?? Data())
        }
        let store = ModelPricingStore(http: http, cacheDirectory: path ?? directory, now: { now },
                                      sourceURLs: [.supplement: source], bundledData: { name in
            name == "pricing_supplement" ? bundle : Data(#"{"models":{}}"#.utf8)
        })
        return (store, http)
    }

    private static func supplement(rate: Double, date: String? = nil) -> Data {
        var value: [String: Any] = [
            "pricing": ["auto": ["input_per_million": rate, "output_per_million": rate]],
            "alias_rules": []
        ]
        value["updated_at"] = date
        return try! JSONSerialization.data(withJSONObject: value)
    }
}
