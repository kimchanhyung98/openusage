import XCTest
@testable import OpenUsage

// MARK: - CSV parser

final class CursorCSVParserTests: XCTestCase {
    func testParsesQuotedCommasEscapedQuotesEmbeddedNewlinesAndCRLF() {
        let csv = "Date,Model,Note\r\n"
            + "2026-01-01T00:00:00Z,\"composer-1\",\"a, b \"\"quoted\"\" c\"\r\n"
            + "2026-01-02T00:00:00Z,composer-1,\"line one\r\nline two\"\r\n"
        var records: [[String: String]] = []

        let summary = CursorCSVParser.forEachRecord(in: csv) { records.append($0) }

        XCTAssertTrue(summary.isStructurallyComplete)
        XCTAssertEqual(summary.rejectedRecordCount, 0)
        XCTAssertEqual(records.count, 2)
        guard records.count == 2 else { return }
        XCTAssertEqual(records[0]["Note"], #"a, b "quoted" c"#)
        XCTAssertEqual(records[1]["Note"], "line one\r\nline two")
        XCTAssertEqual(records[1]["Model"], "composer-1")
    }

    func testParsesTrailingPartialRowWithoutNewline() {
        let csv = "Date,Model\n2026-01-01T00:00:00Z,composer-1"
        var records: [[String: String]] = []

        let summary = CursorCSVParser.forEachRecord(in: csv) { records.append($0) }

        XCTAssertTrue(summary.isStructurallyComplete)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0]["Date"], "2026-01-01T00:00:00Z")
        XCTAssertEqual(records[0]["Model"], "composer-1")
    }

    func testUsageCSVMapsColumnsToPricedRows() throws {
        let csv = """
        Date,Model,Max Mode,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Cost
        2026-01-01T00:00:00Z,composer-1,No,0,0,0,1000000,Included
        2026-01-01T00:00:00Z,totally-unknown-model-xyz,No,0,100,0,0,Included
        ,skipped-no-date,No,0,0,0,0,Included
        """
        let parsed = try CursorUsageCSV.parse(csv: csv, pricing: TestPricing.bundled)

        XCTAssertEqual(parsed.rows.count, 2)
        XCTAssertEqual(parsed.rejectedRowCount, 1)
        XCTAssertEqual(parsed.rows[0].model, "composer-1")
        XCTAssertEqual(parsed.rows[0].tokens.output, 1_000_000)
        XCTAssertEqual(parsed.rows[0].imputedCostDollars!, 10.0, accuracy: 1e-9)
        XCTAssertEqual(parsed.rows[1].tokens.totalTokens, 100)
        XCTAssertNil(parsed.rows[1].imputedCostDollars)
    }

    func testUsageCSVDoesNotTreatAggregatedRowsAsSingleLongContextRequests() throws {
        var rates = ModelRates(
            inputPerMillion: 3,
            outputPerMillion: 15,
            cacheWritePerMillion: 3.75,
            cacheReadPerMillion: 0.3
        )
        rates.inputAbove200kPerMillion = 6
        rates.outputAbove200kPerMillion = 22.5
        let pricing = ModelPricing(
            supplement: PricingSupplement(),
            primary: PricingCatalog(entries: ["test-model": rates]),
            secondary: PricingCatalog()
        )
        let csv = """
        Date,Model,Max Mode,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Cost
        2026-01-01T00:00:00Z,test-model,No,0,300000,0,100000,Included
        """

        let row = try XCTUnwrap(CursorUsageCSV.parse(csv: csv, pricing: pricing).rows.first)

        // CSV 행은 여러 request의 합산 — 총합만으로 단일 request의 200k 초과를 증명 불가
        XCTAssertEqual(row.imputedCostDollars!, 2.4, accuracy: 0.0001)
    }
}

// MARK: - Range aggregation

final class CursorSpendRangeTests: XCTestCase {
    func testAppendSpendLinesBucketsRowsByLocalDay() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: now)
        let startOfLast30 = cal.date(byAdding: .day, value: -29, to: startOfToday)!

        let rows = [
            makeRow(date: now, cost: 1.00, tokens: 100),                                              // 오늘
            makeRow(date: cal.date(byAdding: .day, value: -1, to: now)!, cost: 2.00, tokens: 200),    // 어제
            makeRow(date: startOfLast30, cost: 0.50, tokens: 50),                                     // -29d 경계: last30만 포함
            makeRow(date: cal.date(byAdding: .day, value: -40, to: now)!, cost: 5.00, tokens: 999)    // 오래된 행 (provider가 fetch 범위 제한)
        ]

        var lines: [MetricLine] = []
        CursorUsageMapper.appendSpendLines(rows: rows, now: now, pricing: TestPricing.bundled, to: &lines)

        // token은 Cursor 제공, 달러는 로컬 계산 + estimated 표시
        XCTAssertEqual(values(lines, "Today"), [MetricValue(number: 1.00, kind: .dollars, estimated: true), MetricValue(number: 100, kind: .count, label: "tokens")])
        XCTAssertEqual(values(lines, "Yesterday"), [MetricValue(number: 2.00, kind: .dollars, estimated: true), MetricValue(number: 200, kind: .count, label: "tokens")])
        // Last 30 Days는 fetch된 전체 일자 합산 (provider가 CSV를 30일 window로 제한)
        XCTAssertEqual(values(lines, "Last 30 Days"), [MetricValue(number: 8.50, kind: .dollars, estimated: true), MetricValue(number: 1349, kind: .count, label: "tokens")])
    }

    func testZeroActivityLeavesTilesUnbacked() {
        var lines: [MetricLine] = []
        CursorUsageMapper.appendSpendLines(rows: [], now: Date(), pricing: TestPricing.bundled, to: &lines)

        // fetch 성공 + 행 없음: 모든 기간 idle → spend 타일 미추가, "No data"로 fallback
        XCTAssertNil(values(lines, "Today"))
        XCTAssertNil(values(lines, "Yesterday"))
        XCTAssertNil(values(lines, "Last 30 Days"))
    }

    func testAppendSpendLinesAlsoAppendsUsageTrend() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cal = Calendar.current
        let rows = [
            makeRow(date: now, cost: 1.00, tokens: 100),                                           // 오늘
            makeRow(date: cal.date(byAdding: .day, value: -1, to: now)!, cost: 2.00, tokens: 200)  // 어제
        ]

        var lines: [MetricLine] = []
        CursorUsageMapper.appendSpendLines(rows: rows, now: now, pricing: TestPricing.bundled, to: &lines)

        guard case .chart(let label, let points, let note) = lines.first(where: { $0.label == "Usage Trend" }) else {
            return XCTFail("expected a Usage Trend chart line")
        }
        XCTAssertEqual(label, "Usage Trend")
        // Cursor token은 서버 export 출처 — note가 로컬 로그가 아닌 그 출처를 명시
        XCTAssertEqual(note, "From your Cursor usage export")
        XCTAssertEqual(points.count, 31, "one bar per calendar day across the 31-day window")
        XCTAssertEqual(points.last?.value, 100, "today's tokens land on the last bar")
        XCTAssertEqual(points[29].value, 200, "yesterday's tokens land on the second-to-last bar")
    }

    func testNoRowsLeavesNoUsageTrend() {
        // fetch됐지만 빈 export: trend 그릴 것 없음 → chart 라인 미추가("No data")
        var lines: [MetricLine] = []
        CursorUsageMapper.appendSpendLines(rows: [], now: Date(), pricing: TestPricing.bundled, to: &lines)
        XCTAssertNil(lines.first(where: { $0.label == "Usage Trend" }))
    }

    func testUnknownModelsAttachToTheRightPeriods() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cal = Calendar.current
        let rows = [
            makeRow(date: now, cost: 1.00, tokens: 100, model: "composer-1"),                                  // priced, 오늘
            makeRow(date: now, cost: nil, tokens: 50, model: "totally-unknown-model-xyz"),                      // unknown, 오늘
            makeRow(date: cal.date(byAdding: .day, value: -1, to: now)!, cost: 2.00, tokens: 200, model: "composer-1"), // priced, 어제
            makeRow(date: cal.date(byAdding: .day, value: -3, to: now)!, cost: nil, tokens: 80, model: "another-unknown-abc") // unknown, last30만
        ]

        var lines: [MetricLine] = []
        CursorUsageMapper.appendSpendLines(rows: rows, now: now, pricing: TestPricing.bundled, to: &lines)

        // Today는 자기 unknown model 보유, 완전 priced인 Yesterday는 깨끗, Last 30 Days는 dedup·정렬된 합집합
        XCTAssertEqual(unknown(lines, "Today"), ["totally-unknown-model-xyz"])
        XCTAssertEqual(unknown(lines, "Yesterday"), [])
        XCTAssertEqual(unknown(lines, "Last 30 Days"), ["another-unknown-abc", "totally-unknown-model-xyz"])
    }

    func testUnknownModelWithZeroTokensIsNotFlagged() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // unknown model의 zero-token 행은 cost 불변 → warning 미발생; 같은 날 priced usage로 타일 존재를 보장해 필터링 검증
        let rows = [
            makeRow(date: now, cost: 1.00, tokens: 100, model: "composer-1"),
            makeRow(date: now, cost: nil, tokens: 0, model: "totally-unknown-model-xyz")
        ]

        var lines: [MetricLine] = []
        CursorUsageMapper.appendSpendLines(rows: rows, now: now, pricing: TestPricing.bundled, to: &lines)

        XCTAssertNotNil(values(lines, "Today"), "the priced row keeps the tile present")
        XCTAssertEqual(unknown(lines, "Today"), [])
        XCTAssertEqual(unknown(lines, "Last 30 Days"), [])
    }

    func testAppendSpendLinesAttachesModelBreakdown() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = [
            makeRow(date: now, cost: 1.004, tokens: 100, model: "composer-1"),
            makeRow(date: now, cost: 2.006, tokens: 200, model: "gpt-5.5"),
            makeRow(date: now, cost: nil, tokens: 300, model: "unpriced-cursor-model")
        ]

        var lines: [MetricLine] = []
        CursorUsageMapper.appendSpendLines(rows: rows, now: now, pricing: TestPricing.bundled, to: &lines)

        // unpriced 행은 타일 token·breakdown 모두에서 제외 — unknown-model warning으로만 노출
        XCTAssertEqual(values(lines, "Today"),
                       [MetricValue(number: 3.01, kind: .dollars, estimated: true), MetricValue(number: 300, kind: .count, label: "tokens")])
        XCTAssertEqual(unknown(lines, "Today"), ["unpriced-cursor-model"])
        let breakdown = try XCTUnwrap(modelBreakdown(lines, "Today"))
        XCTAssertEqual(breakdown.sourceNote, "From your Cursor usage export")
        XCTAssertEqual(breakdown.models.map(\.model), ["gpt-5.5", "composer-1"])
        XCTAssertEqual(breakdown.models.map(\.totalTokens), [200, 100])
        XCTAssertEqual(breakdown.models[0].costUSD, 2.01, "model cost rounds once at the displayed aggregate")
    }

    func testModelBreakdownGroupsThinkingEffortSlugsIntoFamilies() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // thinking-effort/fast 조합별 slug를 canonical base model로 그룹핑, 원시 slug는 tooltip variant로 유지
        let rows = [
            makeRow(date: now, cost: 3.00, tokens: 300, model: "claude-opus-4-8-thinking-max"),
            makeRow(date: now, cost: 1.00, tokens: 100, model: "claude-opus-4-8-thinking-high"),
            makeRow(date: now, cost: 2.00, tokens: 200, model: "gpt-5.5-extra-high-fast"),
            makeRow(date: now, cost: 0.50, tokens: 50, model: "gpt-5.5")
        ]

        var lines: [MetricLine] = []
        CursorUsageMapper.appendSpendLines(rows: rows, now: now, pricing: TestPricing.bundled, to: &lines)

        let breakdown = try XCTUnwrap(modelBreakdown(lines, "Today"))
        XCTAssertEqual(breakdown.models.map(\.model), ["claude-opus-4-8", "gpt-5.5"])

        let opus = try XCTUnwrap(breakdown.models.first { $0.model == "claude-opus-4-8" })
        XCTAssertEqual(opus.totalTokens, 400)
        XCTAssertEqual(opus.costUSD, 4.00)
        XCTAssertEqual(opus.variants?.map(\.model), ["claude-opus-4-8-thinking-max", "claude-opus-4-8-thinking-high"],
                       "variants keep the raw slugs, largest spend first")
        XCTAssertEqual(opus.variants?.map(\.costUSD), [3.00, 1.00])

        let gpt = try XCTUnwrap(breakdown.models.first { $0.model == "gpt-5.5" })
        XCTAssertEqual(gpt.variants?.map(\.model), ["gpt-5.5-extra-high-fast", "gpt-5.5"],
                       "a -fast canonical folds into its base family")
    }

    func testUnpricedOnlyDayLeavesTilesUnbacked() {
        // 모든 행이 unpriceable한 날은 타일·trend 없음 — 제외된 usage는 `unknownModelsByDay`에만 존재
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = [
            makeRow(date: now, cost: nil, tokens: 100, model: "totally-unknown-model-xyz")
        ]

        var lines: [MetricLine] = []
        CursorUsageMapper.appendSpendLines(rows: rows, now: now, pricing: TestPricing.bundled, to: &lines)

        XCTAssertNil(values(lines, "Today"))
        XCTAssertNil(values(lines, "Last 30 Days"))
        XCTAssertNil(lines.first(where: { $0.label == "Usage Trend" }))
    }

    private func modelBreakdown(_ lines: [MetricLine], _ label: String) -> ModelUsageBreakdown? {
        guard case .values(_, _, _, _, _, let breakdown) = lines.first(where: { $0.label == label }) else { return nil }
        return breakdown
    }

    private func unknown(_ lines: [MetricLine], _ label: String) -> [String]? {
        guard case .values(_, _, _, _, let unknownModels, _) = lines.first(where: { $0.label == label }) else { return nil }
        return unknownModels
    }

    /// `cost: nil` = 어떤 pricing source도 가격 산정 못한 행 (unknown-model 케이스)
    private func makeRow(date: Date, cost: Double?, tokens: Int, model: String = "composer-1") -> CursorUsageCSVRow {
        CursorUsageCSVRow(
            date: date,
            model: model,
            tokens: TokenBreakdown(input: tokens),
            imputedCostDollars: cost
        )
    }

    private func values(_ lines: [MetricLine], _ label: String) -> [MetricValue]? {
        guard case .values(_, let values, _, _, _, _) = lines.first(where: { $0.label == label }) else { return nil }
        return values
    }
}

// MARK: - Provider integration + render shape

@MainActor
final class CursorSpendProviderTests: XCTestCase {
    func testSpendTrackingDownloadsCSVExposesSpendTilesAndFlagsUnknownModels() async {
        // usage CSV 다운로드 → spend 타일 + trend descriptor 노출, unknown model은 타일 warning용으로 이름 전달
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let iso = ISO8601DateFormatter()
        let todayStr = iso.string(from: now)
        let yesterdayStr = iso.string(from: Calendar.current.date(byAdding: .day, value: -1, to: now)!)
        // 오늘 priced + unknown model 사용, 어제는 priced 행
        let csv = """
        Date,Model,Max Mode,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Cost
        \(todayStr),composer-1,No,0,1000000,0,0,Included
        \(todayStr),totally-unknown-model-xyz,No,0,500000,0,0,Included
        \(yesterdayStr),composer-1,No,0,200000,0,0,Included
        """

        let accessToken = makeCursorJWT(sub: "google-oauth2|user_abc123")
        let http = RoutingHTTPClient { request in
            let url = request.url.absoluteString
            if url.contains("export-usage-events-csv") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(csv.utf8))
            }
            if url.contains("GetCurrentPeriodUsage") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data("""
                {
                  "enabled": true,
                  "billingCycleEnd": 1772592000000,
                  "planUsage": { "limit": 40000, "remaining": 32000, "totalPercentUsed": 20 }
                }
                """.utf8))
            }
            if url.contains("GetPlanInfo") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"planInfo":{"planName":"pro plan"}}"#.utf8))
            }
            if url.contains("GetCreditGrantsBalance") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"hasCreditGrants":false}"#.utf8))
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        let provider = CursorProvider(
            authStore: CursorAuthStore(
                sqlite: FakeSQLite(values: [CursorAuthStore.accessTokenKey: accessToken]),
                keychain: FakeKeychain()
            ),
            usageClient: CursorUsageClient(http: http),
            now: { now },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertTrue(http.requests.contains { $0.url.absoluteString.contains("export-usage-events-csv") },
                      "Cursor refresh must download the usage CSV for spend metrics")
        // live quota 미터 유지, spend 타일 + trend 존재
        XCTAssertTrue(snapshot.lines.contains { $0.label == "Total usage" })
        for label in ["Today", "Yesterday", "Last 30 Days", "Usage Trend"] {
            XCTAssertNotNil(snapshot.lines.first { $0.label == label }, "\(label) line must be present")
        }
        let ids = Set(provider.widgetDescriptors.map(\.id))
        for id in ["cursor.today", "cursor.yesterday", "cursor.last30", "cursor.trend"] {
            XCTAssertTrue(ids.contains(id), "\(id) descriptor must be present")
        }

        // unknown model은 Today(및 Last 30 Days 합집합)에 부착, 완전 priced인 Yesterday는 깨끗
        XCTAssertEqual(unknownModels(snapshot.lines, "Today"), ["totally-unknown-model-xyz"])
        XCTAssertEqual(unknownModels(snapshot.lines, "Yesterday"), [])
        XCTAssertEqual(unknownModels(snapshot.lines, "Last 30 Days"), ["totally-unknown-model-xyz"])
    }

    private func unknownModels(_ lines: [MetricLine], _ label: String) -> [String]? {
        guard case .values(_, _, _, _, let unknownModels, _) = lines.first(where: { $0.label == label }) else { return nil }
        return unknownModels
    }

    func testSpendTileRendersCombinedCostAndTokensWithValueTooltip() async {
        let cursor = CursorProvider()
        let descriptor = try! XCTUnwrap(cursor.widgetDescriptors.first { $0.id == "cursor.today" })

        // 결합 타일은 달러 + 라벨된 token count — 실제 $0.00 보고(예: OpenRouter)는 숨기지 않고 "$0.00 · 0 tokens"로 렌더
        let cases: [(Double, Int, String, String)] = [
            (12.34, 891_000, "$12.34", "$12.34 · 891K tokens"),
            (0.0, 0, "$0.00", "$0.00 · 0 tokens")
        ]
        for (dollars, tokens, expectedValue, expectedDetail) in cases {
            let runtime = TestProviderRuntime(
                provider: cursor.provider,
                descriptors: [descriptor],
                snapshot: ProviderSnapshot(
                    providerID: cursor.provider.id,
                    displayName: cursor.provider.displayName,
                    lines: [.values(label: "Today", values: [
                        MetricValue(number: dollars, kind: .dollars, estimated: true),
                        MetricValue(number: Double(tokens), kind: .count, label: "tokens")
                    ])]
                )
            )
            let defaults = isolatedDefaults("render-\(expectedValue)")
            let store = WidgetDataStore(
                registry: WidgetRegistry(providers: [cursor.provider], descriptors: [descriptor]),
                providers: [runtime],
                cache: isolatedCache(defaults),
                defaults: defaults
            )
            await store.refreshAll()

            store.meterStyle = .remaining
            let remaining = store.data(for: descriptor)
            store.meterStyle = .used
            let used = store.data(for: descriptor)

            XCTAssertTrue(remaining.hasData)
            XCTAssertEqual(remaining.valueText, expectedValue)
            XCTAssertEqual(remaining.unboundedDetail, expectedDetail)
            XCTAssertEqual(remaining.infoNote, WidgetData.localEstimateNote)
            // unbounded: 두 meter style에서 동일
            XCTAssertEqual(used.valueText, remaining.valueText)
            XCTAssertEqual(used.unboundedDetail, remaining.unboundedDetail)
            XCTAssertEqual(used.infoNote, remaining.infoNote)
        }
    }

    // MARK: helpers

    private func isolatedDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.CursorSpend.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func isolatedCache(_ defaults: UserDefaults) -> ProviderSnapshotCache {
        ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() })
    }
}

// MARK: - Client request contract

final class CursorUsageClientRequestTests: XCTestCase {
    // client 레벨의 request 계약 고정 — endpoint, epoch-ms 범위, `strategy=tokens`, session cookie, `Accept: text/csv`
    func testFetchUsageCSVBuildsTokenStrategyRequestWithSessionCookie() async throws {
        let accessToken = makeCursorJWT(sub: "google-oauth2|user_abc123")
        let http = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: Data("Date,Model\n".utf8))
        }

        let response = try await CursorUsageClient(http: http).fetchUsageCSV(
            accessToken: accessToken,
            start: Date(timeIntervalSince1970: 1_000),   // 밀리초 변환값 1_000_000
            end: Date(timeIntervalSince1970: 2_000)      // 밀리초 변환값 2_000_000
        )

        XCTAssertEqual(response?.statusCode, 200)
        // session이 nil이면 HTTP 호출 자체를 skip — 기록된 request 요구로 아래 assertion의 실제 실행 보장
        let request = try XCTUnwrap(http.requests.first, "fetchUsageCSV must issue a request")
        let url = request.url.absoluteString
        XCTAssertTrue(url.contains("export-usage-events-csv"), "hits the CSV export endpoint")
        XCTAssertTrue(url.contains("startDate=1000000"), "start as epoch-ms query param")
        XCTAssertTrue(url.contains("endDate=2000000"), "end as epoch-ms query param")
        XCTAssertTrue(url.contains("strategy=tokens"), "token strategy")
        XCTAssertEqual(request.headers["Cookie"], "WorkosCursorSessionToken=user_abc123%3A%3A\(accessToken)")
        XCTAssertEqual(request.headers["Accept"], "text/csv")
    }
}

// MARK: - Shared test helpers (file-private; mirror CursorProviderTests)

private func makeCursorJWT(sub: String = "google-oauth2|user", exp: Double = 9_999_999_999) -> String {
    let payload = #"{"sub":"\#(sub)","exp":\#(exp)}"#
    let encoded = Data(payload.utf8).base64EncodedString()
        .replacingOccurrences(of: "=", with: "")
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
    return "a.\(encoded).c"
}

private final class FakeSQLite: SQLiteAccessing, @unchecked Sendable {
    var values: [String: String]
    init(values: [String: String] = [:]) { self.values = values }
    func queryValue(path: String, sql: String) throws -> String? {
        for (key, value) in values where sql.contains(key) { return value }
        return nil
    }
    func execute(path: String, sql: String) throws {}
}
