import XCTest
@testable import OpenUsage

final class GrokLogUsageScannerTests: XCTestCase {
    private let since = OpenUsageISO8601.date(from: "2026-06-01T00:00:00.000Z")!

    func testProviderQualifiedGrok46AliasesKeepUsagePriced() throws {
        // 일반 요청은 200k 초과 장문 단가(입력 4 + 출력 12), Fast는 명시 단가(입력 4 + 출력 12) 적용.
        for (model, expected) in [
            ("xai/grok-4.6", 16.0), ("xai/grok-4-6-high", 16.0),
            ("xai/grok-4.6-fast", 16.0), ("xai/grok-4-6-fast-xhigh", 16.0),
            ("xai/grok-4.6-high-fast", 16.0)
        ] {
            let log = """
            {"pid":1,"msg":"model catalog: notifying clients","ctx":{"current_model_id":"\(model)"}}
            {"ts":"2026-06-10T10:00:00Z","pid":1,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000,"completion_tokens":1000000}}
            """
            let usage = GrokLogUsageScanner.parse(log, since: since, pricing: TestPricing.bundled)
            XCTAssertEqual(usage.series.daily.first?.totalTokens, 2_000_000, model)
            XCTAssertEqual(try XCTUnwrap(usage.series.daily.first?.costUSD), expected, accuracy: 1e-9, model)
            XCTAssertTrue(usage.unknownModelsByDay.isEmpty, model)
        }
        for model in ["xai/grok-4.99", "xai/grok-4.6-unknown", "reseller/grok-4.6"] {
            XCTAssertNil(TestPricing.bundled.supplement.canonicalName(for: model), model)
        }
    }

    func testAttributesTokensToPerProcessModelAndPrices() {
        // fixture: pid 100은 grok-build, pid 200은 grok-composer-2.5-fast — token row는 각 process의 현재 model로 가격 산정
        let log = """
        {"ts":"2026-06-10T09:00:00.000Z","pid":100,"msg":"model catalog: notifying clients","ctx":{"current_model_id":"grok-build"}}
        {"ts":"2026-06-10T09:00:00.000Z","pid":200,"msg":"model catalog: notifying clients","ctx":{"current_model_id":"grok-composer-2.5-fast"}}
        {"ts":"2026-06-10T10:00:00.000Z","pid":100,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000,"cached_prompt_tokens":0,"completion_tokens":1000000,"reasoning_tokens":0}}
        {"ts":"2026-06-10T11:00:00.000Z","pid":200,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000,"cached_prompt_tokens":0,"completion_tokens":1000000,"reasoning_tokens":0}}
        """

        let usage = GrokLogUsageScanner.parse(log, since: since, pricing: TestPricing.bundled)

        let day = usage.series.daily.first { $0.date == "2026-06-10" }
        XCTAssertEqual(day?.totalTokens, 4_000_000)
        // grok-build 장문 입력 1M × $2 + 출력 1M × $4 = $6, composer-2.5-fast 입력·출력 합계 $18.
        XCTAssertEqual(day?.costUSD ?? 0, 24.0, accuracy: 0.0001)
        let models = usage.modelUsage?.daily.first { $0.date == "2026-06-10" }?.models ?? []
        XCTAssertEqual(Set(models.map(\.model)), Set(["grok-build", "grok-composer-2.5-fast"]))
    }

    func testTracksMidProcessModelSwitch() {
        let log = """
        {"ts":"2026-06-12T08:00:00.000Z","pid":7,"msg":"model catalog: notifying clients","ctx":{"current_model_id":"grok-build"}}
        {"ts":"2026-06-12T09:00:00.000Z","pid":7,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000,"cached_prompt_tokens":0,"completion_tokens":0,"reasoning_tokens":0}}
        {"ts":"2026-06-12T10:00:00.000Z","pid":7,"msg":"model catalog: notifying clients","ctx":{"current_model_id":"grok-composer-2.5-fast"}}
        {"ts":"2026-06-12T11:00:00.000Z","pid":7,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000,"cached_prompt_tokens":0,"completion_tokens":0,"reasoning_tokens":0}}
        """

        let usage = GrokLogUsageScanner.parse(log, since: since, pricing: TestPricing.bundled)

        // 첫 요청은 grok-build 장문 입력 $2/M, 전환 이후 요청은 composer-2.5-fast 입력 $3/M 적용.
        XCTAssertEqual(usage.series.daily.first?.costUSD ?? 0, 5.0, accuracy: 0.0001)
    }

    func testModelRequestDoesNotChangeAttributionUntilApplied() {
        let log = """
        {"pid":7,"sid":"parent","msg":"backend_search: model switch","ctx":{"new_model":"grok-build"}}
        {"ts":"2026-06-12T09:00:00Z","pid":7,"sid":"parent","msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000}}
        {"pid":7,"sid":"parent","msg":"model changed","ctx":{"model":"grok-composer-2.5-fast"}}
        {"ts":"2026-06-12T10:00:00Z","pid":7,"sid":"parent","msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000}}
        {"pid":7,"sid":"parent","msg":"backend_search: model switch","ctx":{"new_model":"grok-composer-2.5-fast"}}
        {"ts":"2026-06-12T11:00:00Z","pid":7,"sid":"parent","msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000}}
        """
        let usage = GrokLogUsageScanner.parse(log, since: since, pricing: TestPricing.bundled)
        XCTAssertEqual(usage.series.daily.first?.totalTokens, 3_000_000)
        XCTAssertEqual(usage.series.daily.first?.costUSD, 7)
        let models = usage.modelUsage?.daily.first?.models ?? []
        XCTAssertEqual(models.first { $0.model == "grok-build" }?.totalTokens, 2_000_000)
        XCTAssertEqual(models.first { $0.model == "grok-composer-2.5-fast" }?.totalTokens, 1_000_000)
        XCTAssertEqual(usage.rejectedMetadataRows, 0)
    }

    func testProcessRestartClearsAmbiguityOnlyForReusedPID() {
        let log = """
        {"pid":7,"msg":"model catalog: notifying clients","ctx":{"current_model_id":"grok-build"}}
        {"ts":"2026-06-12T09:00:00Z","pid":7,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000}}
        {"pid":7,"msg":"subagent model resolved","ctx":{"child_model":"grok-composer-2.5-fast"}}
        {"pid":8,"msg":"model catalog: notifying clients","ctx":{"current_model_id":"grok-build"}}
        {"pid":8,"msg":"subagent model resolved","ctx":{"child_model":"grok-composer-2.5-fast"}}
        {"pid":7,"msg":"process resource limits","ctx":{"nofile":[1024,4096]}}
        {"pid":7,"msg":"model catalog: notifying clients","ctx":{"current_model_id":"grok-composer-2.5-fast"}}
        {"ts":"2026-06-12T10:00:00Z","pid":7,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000}}
        {"ts":"2026-06-12T11:00:00Z","pid":8,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000}}
        """
        let usage = GrokLogUsageScanner.parse(log, since: since, pricing: TestPricing.bundled)
        XCTAssertEqual(usage.series.daily.first?.totalTokens, 2_000_000)
        XCTAssertEqual(usage.series.daily.first?.costUSD, 5)
        XCTAssertEqual(usage.rejectedMetadataRows, 1)
    }

    func testProcessRestartClearsResumedSessionModelAndPreservesOtherPID() {
        let log = """
        {"pid":7,"sid":"same","msg":"backend_search: model switch","ctx":{"new_model":"grok-build"}}
        {"pid":8,"sid":"same","msg":"backend_search: model switch","ctx":{"new_model":"grok-build"}}
        {"pid":7,"msg":"process resource limits"}
        {"pid":7,"msg":"model catalog: notifying clients","ctx":{"current_model_id":"grok-composer-2.5-fast"}}
        {"ts":"2026-06-12T09:00:00Z","pid":7,"sid":"same","msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000}}
        {"ts":"2026-06-12T10:00:00Z","pid":8,"sid":"same","msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000}}
        """
        let usage = GrokLogUsageScanner.parse(log, since: since, pricing: TestPricing.bundled)
        XCTAssertEqual(usage.series.daily.first?.totalTokens, 2_000_000)
        XCTAssertEqual(usage.series.daily.first?.costUSD, 5)
        XCTAssertEqual(usage.modelUsage?.daily.first?.models.count, 2)
        XCTAssertEqual(usage.rejectedMetadataRows, 0)
    }

    func testProcessRestartClearsPreviousDefaultAndInheritedSession() {
        let log = """
        {"pid":7,"msg":"model catalog: notifying clients","ctx":{"current_model_id":"grok-build"}}
        {"ts":"2026-05-31T09:00:00Z","pid":7,"sid":"parent","msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1}}
        {"pid":7,"msg":"process resource limits"}
        {"ts":"2026-06-12T09:00:00Z","pid":7,"sid":"parent","msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000}}
        {"pid":7,"msg":"model catalog: notifying clients","ctx":{"current_model_id":"grok-composer-2.5-fast"}}
        {"pid":7,"msg":"subagent model resolved","ctx":{"child_model":"grok-build"}}
        {"ts":"2026-06-12T10:00:00Z","pid":7,"sid":"parent","msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000}}
        """
        let usage = GrokLogUsageScanner.parse(log, since: since, pricing: TestPricing.bundled)
        XCTAssertTrue(usage.series.daily.isEmpty)
        XCTAssertNil(usage.usageHistory)
        XCTAssertEqual(usage.rejectedMetadataRows, 2)
    }

    func testSessionsSharingProcessKeepTheirOwnModels() {
        let log = """
        {"pid":7,"sid":"parent","msg":"backend_search: model switch","ctx":{"new_model":"grok-build"}}
        {"pid":7,"sid":"child","msg":"backend_search: model switch","ctx":{"new_model":"grok-composer-2.5-fast"}}
        {"pid":7,"msg":"model catalog: notifying clients","ctx":{"current_model_id":"unknown-default"}}
        {"ts":"2026-06-12T09:00:00Z","pid":7,"sid":"parent","msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000,"completion_tokens":1000000}}
        {"ts":"2026-06-12T10:00:00Z","pid":7,"sid":"child","msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000,"completion_tokens":1000000}}
        """
        let usage = GrokLogUsageScanner.parse(log, since: since, pricing: TestPricing.bundled)
        XCTAssertEqual(usage.series.daily.first?.totalTokens, 4_000_000)
        XCTAssertEqual(usage.series.daily.first?.costUSD, 24)
        let models = usage.modelUsage?.daily.first?.models ?? []
        XCTAssertEqual(models.first { $0.model == "grok-build" }?.costUSD, 6)
        XCTAssertEqual(models.first { $0.model == "grok-composer-2.5-fast" }?.costUSD, 18)
        XCTAssertEqual(usage.rejectedMetadataRows, 0)
    }

    func testProcessModelChangeUpdatesInheritedButNotExplicitSessionModels() {
        let log = """
        {"pid":7,"msg":"model catalog: notifying clients","ctx":{"current_model_id":"grok-build"}}
        {"pid":7,"sid":"explicit","msg":"backend_search: model switch","ctx":{"new_model":"grok-build"}}
        {"ts":"2026-06-12T09:00:00Z","pid":7,"sid":"inherited","msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000}}
        {"pid":7,"msg":"model catalog: notifying clients","ctx":{"current_model_id":"grok-composer-2.5-fast"}}
        {"ts":"2026-06-12T10:00:00Z","pid":7,"sid":"inherited","msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000}}
        {"ts":"2026-06-12T11:00:00Z","pid":7,"sid":"explicit","msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000}}
        """
        let usage = GrokLogUsageScanner.parse(log, since: since, pricing: TestPricing.bundled)
        XCTAssertEqual(usage.series.daily.first?.totalTokens, 3_000_000)
        XCTAssertEqual(usage.series.daily.first?.costUSD, 7)
        let models = usage.modelUsage?.daily.first?.models ?? []
        XCTAssertEqual(models.first { $0.model == "grok-build" }?.totalTokens, 2_000_000)
        XCTAssertEqual(models.first { $0.model == "grok-composer-2.5-fast" }?.totalTokens, 1_000_000)
        XCTAssertEqual(usage.rejectedMetadataRows, 0)
    }

    func testAmbiguousProcessWithoutSessionIDWarnsAndPreservesHistory() {
        let diagnostics = DiagnosticEventRecorder()
        let log = """
        {"pid":7,"msg":"model catalog: notifying clients","ctx":{"current_model_id":"grok-build"}}
        {"pid":7,"msg":"subagent model resolved","ctx":{"child_model":"grok-composer-2.5-fast"}}
        {"ts":"2026-05-31T09:00:00Z","pid":7,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000}}
        {"ts":"2026-06-12T09:00:00Z","pid":7,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000}}
        {"ts":"2026-06-12T10:00:00Z","pid":7,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":0}}
        """
        let usage = GrokLogUsageScanner.parse(log, since: since, pricing: TestPricing.bundled)
        XCTAssertTrue(usage.series.daily.isEmpty)
        XCTAssertEqual(usage.rejectedMetadataRows, 1)
        XCTAssertNotNil(usage.metadataWarning)
        XCTAssertNil(usage.usageHistory)
        XCTAssertEqual(diagnostics.events, [
            DiagnosticEvent(.historyScan, result: .degraded, category: .decoding, providerID: "grok")
        ])
    }

    func testProcessSwitchBeforeUnscopedChildPreservesLatestParentModel() {
        let log = """
        {"pid":7,"msg":"model catalog: notifying clients","ctx":{"current_model_id":"grok-build"}}
        {"ts":"2026-05-31T09:00:00Z","pid":7,"sid":"parent","msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1}}
        {"pid":7,"msg":"model catalog: notifying clients","ctx":{"current_model_id":"grok-composer-2.5-fast"}}
        {"pid":7,"msg":"subagent model resolved","ctx":{"child_model":"grok-build"}}
        {"pid":7,"msg":"model catalog: notifying clients","ctx":{"current_model_id":"grok-build"}}
        {"ts":"2026-06-12T09:00:00Z","pid":7,"sid":"parent","msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000}}
        {"ts":"2026-06-12T10:00:00Z","pid":7,"sid":"unknown-child","msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000}}
        """
        let usage = GrokLogUsageScanner.parse(log, since: since, pricing: TestPricing.bundled)
        XCTAssertEqual(usage.series.daily.first?.totalTokens, 1_000_000)
        XCTAssertEqual(usage.series.daily.first?.costUSD, 3)
        XCTAssertEqual(usage.modelUsage?.daily.first?.models.map(\.model), ["grok-composer-2.5-fast"])
        XCTAssertEqual(usage.rejectedMetadataRows, 1)
    }

    func testSameSessionIDInDifferentProcessesIsIndependent() {
        let log = """
        {"pid":7,"sid":"session","msg":"backend_search: model switch","ctx":{"new_model":"grok-build"}}
        {"pid":8,"sid":"session","msg":"backend_search: model switch","ctx":{"new_model":"grok-composer-2.5-fast"}}
        {"ts":"2026-06-12T09:00:00Z","pid":7,"sid":"session","msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000}}
        {"ts":"2026-06-12T10:00:00Z","pid":8,"sid":"session","msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000}}
        """
        let usage = GrokLogUsageScanner.parse(log, since: since, pricing: TestPricing.bundled)
        XCTAssertEqual(usage.series.daily.first?.totalTokens, 2_000_000)
        XCTAssertEqual(usage.series.daily.first?.costUSD, 5)
    }

    func testUnscopedChildModelCannotChangeParentOrPriceUnknownChild() {
        let log = """
        {"pid":7,"msg":"model catalog: notifying clients","ctx":{"current_model_id":"grok-build"}}
        {"ts":"2026-05-31T09:00:00Z","pid":7,"sid":"parent","msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1}}
        {"pid":7,"msg":"subagent model resolved","ctx":{"child_model":"grok-composer-2.5-fast","parent_model":"grok-build"}}
        {"pid":7,"msg":"model catalog: notifying clients","ctx":{"current_model_id":"grok-composer-2.5-fast"}}
        {"ts":"2026-06-12T09:00:00Z","pid":7,"sid":"parent","msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000}}
        {"ts":"2026-06-12T10:00:00Z","pid":7,"sid":"unknown-child","msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000}}
        """
        let usage = GrokLogUsageScanner.parse(log, since: since, pricing: TestPricing.bundled)
        XCTAssertEqual(usage.series.daily.first?.totalTokens, 1_000_000)
        XCTAssertEqual(usage.series.daily.first?.costUSD, 2)
        XCTAssertEqual(usage.modelUsage?.daily.first?.models.map(\.model), ["grok-build"])
        XCTAssertEqual(usage.rejectedMetadataRows, 1)
        XCTAssertNotNil(usage.metadataWarning)
    }

    func testScopedChildModelIsUsedWhenSessionIsKnown() {
        let log = """
        {"pid":7,"sid":"parent","msg":"backend_search: model switch","ctx":{"new_model":"grok-build"}}
        {"pid":7,"sid":"child","msg":"subagent model resolved","ctx":{"child_model":"grok-composer-2.5-fast"}}
        {"ts":"2026-06-12T09:00:00Z","pid":7,"sid":"child","msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000}}
        {"ts":"2026-06-12T10:00:00Z","pid":7,"sid":"parent","msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000}}
        """
        let usage = GrokLogUsageScanner.parse(log, since: since, pricing: TestPricing.bundled)
        XCTAssertEqual(usage.series.daily.first?.costUSD, 5)
        XCTAssertEqual(usage.rejectedMetadataRows, 0)
    }

    func testUsesCachedReadRateForCachedPromptTokens() {
        // 1M 입력 중 800k는 캐시 읽기 — 캐시를 포함한 요청 전체에 장문 단가 적용.
        let log = """
        {"ts":"2026-06-12T08:00:00.000Z","pid":1,"msg":"model catalog: notifying clients","ctx":{"current_model_id":"grok-build"}}
        {"ts":"2026-06-12T09:00:00.000Z","pid":1,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000,"cached_prompt_tokens":800000,"completion_tokens":0,"reasoning_tokens":0}}
        """

        let usage = GrokLogUsageScanner.parse(log, since: since, pricing: TestPricing.bundled)

        // 일반 입력 200k × $2/M = $0.40, 캐시 읽기 800k × $0.40/M = $0.32.
        XCTAssertEqual(usage.series.daily.first?.costUSD ?? 0, 0.72, accuracy: 0.0001)
    }

    func testSkipsRowsWithoutTokenFieldsAndOutsideWindow() {
        let log = """
        {"ts":"2026-06-10T09:00:00.000Z","pid":1,"msg":"model catalog: notifying clients","ctx":{"current_model_id":"grok-build"}}
        {"ts":"2026-05-30T09:00:00.000Z","pid":1,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000,"completion_tokens":0,"reasoning_tokens":0}}
        {"ts":"2026-06-10T10:00:00.000Z","pid":1,"msg":"shell.turn.inference_done","ctx":{"loop_index":3,"model_elapsed_ms":10}}
        {"ts":"2026-06-10T10:30:00.000Z","pid":1,"sid":"session","msg":"shell.turn.inference_done","ctx":{"prompt_tokens":null,"cached_prompt_tokens":null,"completion_tokens":null,"reasoning_tokens":null}}
        {"ts":"2026-06-10T11:00:00.000Z","pid":1,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":500000,"completion_tokens":0,"reasoning_tokens":0}}
        """

        let usage = GrokLogUsageScanner.parse(log, since: since, pricing: TestPricing.bundled)

        // window 내 token 보유 row만 집계 — window 이전 row·token 없는 row 제외
        XCTAssertEqual(usage.series.daily.count, 1)
        XCTAssertEqual(usage.series.daily.first?.totalTokens, 500_000)
        XCTAssertEqual(usage.rejectedNumericRows, 0)
        XCTAssertNil(usage.numericWarning)
    }

    func testOnlyAbsentUsageKeepsAValidEmptyHistory() {
        let log = """
        {"pid":1,"msg":"model catalog: notifying clients","ctx":{"current_model_id":"grok-build"}}
        {"ts":"2026-06-10T10:00:00Z","pid":1,"sid":"session","msg":"shell.turn.inference_done","ctx":{"prompt_tokens":null,"cached_prompt_tokens":null,"completion_tokens":null,"reasoning_tokens":null}}
        """
        let usage = GrokLogUsageScanner.parse(log, since: since, pricing: TestPricing.bundled)
        XCTAssertTrue(usage.series.daily.isEmpty)
        XCTAssertEqual(usage.rejectedNumericRows, 0)
        XCTAssertEqual(usage.rejectedMetadataRows, 0)
        XCTAssertNil(usage.numericWarning)
        XCTAssertNotNil(usage.usageHistory)
    }

    func testUnpricedModelIsExcludedFromTotalsButWarns() {
        let log = """
        {"ts":"2026-06-10T09:00:00.000Z","pid":1,"msg":"model catalog: notifying clients","ctx":{"current_model_id":"grok-unknown-model"}}
        {"ts":"2026-06-10T10:00:00.000Z","pid":1,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000,"completion_tokens":0,"reasoning_tokens":0}}
        {"ts":"2026-06-10T11:00:00.000Z","pid":2,"msg":"model catalog: notifying clients","ctx":{"current_model_id":"grok-build"}}
        {"ts":"2026-06-10T12:00:00.000Z","pid":2,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":500000,"completion_tokens":0,"reasoning_tokens":0}}
        """

        let usage = GrokLogUsageScanner.parse(log, since: since, pricing: TestPricing.bundled)

        // 가격 산정 불가 token은 표시 합계에서 제외 — warning triangle로만 노출해 token·달러 정합 유지
        XCTAssertEqual(usage.series.daily.first?.totalTokens, 500_000)
        XCTAssertNotNil(usage.series.daily.first?.costUSD)
        XCTAssertEqual(usage.unknownModelsByDay["2026-06-10"], ["grok-unknown-model"])
        XCTAssertEqual(usage.modelUsage?.daily.first?.models.map(\.model), ["grok-build"])
    }

    func testUnpricedModelOnlyLeavesDayUnbacked() {
        let log = """
        {"ts":"2026-06-10T09:00:00.000Z","pid":1,"msg":"model catalog: notifying clients","ctx":{"current_model_id":"grok-unknown-model"}}
        {"ts":"2026-06-10T10:00:00.000Z","pid":1,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000,"completion_tokens":0,"reasoning_tokens":0}}
        """

        let usage = GrokLogUsageScanner.parse(log, since: since, pricing: TestPricing.bundled)

        // 가격 산정 가능한 항목이 없는 날은 series entry 없음(→ "No data") — unknown-model warning은 제외 대상 명시
        XCTAssertTrue(usage.series.daily.isEmpty)
        XCTAssertEqual(usage.unknownModelsByDay["2026-06-10"], ["grok-unknown-model"])
        XCTAssertEqual(usage.modelUsage?.daily ?? [], [])
    }

    func testUnattributedRowsAreExcludedWithoutWarning() {
        let log = """
        {"ts":"2026-06-10T10:00:00.000Z","pid":1,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000,"completion_tokens":0,"reasoning_tokens":0}}
        """

        let usage = GrokLogUsageScanner.parse(log, since: since, pricing: TestPricing.bundled)

        // model 귀속 불가 token은 전 합계에서 제외 — 경고할 model 이름도 없어 unknown-model entry 없음
        XCTAssertTrue(usage.series.daily.isEmpty)
        XCTAssertTrue(usage.unknownModelsByDay.isEmpty)
        XCTAssertEqual(usage.modelUsage?.daily ?? [], [])
    }

    func testScanReadsGrokHomeOverride() async {
        let files = FakeFiles([
            "/custom/grok/logs/unified.jsonl": """
            {"ts":"2026-06-10T09:00:00.000Z","pid":1,"msg":"model catalog: notifying clients","ctx":{"current_model_id":"grok-build"}}
            {"ts":"2026-06-10T10:00:00.000Z","pid":1,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000,"completion_tokens":0,"reasoning_tokens":0}}
            """
        ])
        let scanner = GrokLogUsageScanner(
            files: files,
            environment: FakeEnvironment(["GROK_HOME": "/custom/grok"]),
            homeDirectory: { URL(fileURLWithPath: "/home/ignored") }
        )

        let usage = await scanner.scan(daysBack: 30, now: OpenUsageISO8601.date(from: "2026-06-18T00:00:00.000Z")!, pricing: TestPricing.bundled)

        XCTAssertEqual(usage?.series.daily.first?.totalTokens, 1_000_000)
    }

    func testScanReturnsNilWhenLogMissing() async {
        let warnings = GrokWarningRecorder()
        let scanner = GrokLogUsageScanner(
            files: FakeFiles(),
            environment: FakeEnvironment(),
            homeDirectory: { URL(fileURLWithPath: "/home/none") },
            readFailureWarning: warnings.record
        )

        let usage = await scanner.scan(pricing: TestPricing.bundled)
        XCTAssertNil(usage)
        XCTAssertEqual(warnings.counts, [])
    }

    func testMissingLogDoesNotRecoverAnEarlierReadFailure() async {
        let diagnostics = DiagnosticEventRecorder()
        let files = FailingTextFiles(path: "/custom/grok/logs/unified.jsonl")
        let warnings = GrokWarningRecorder()
        let scanner = GrokLogUsageScanner(
            files: files,
            environment: FakeEnvironment(["GROK_HOME": "/custom/grok"]),
            readFailureWarning: warnings.record
        )

        _ = await scanner.scan(pricing: TestPricing.bundled)
        files.isPresent = false
        let missing = await scanner.scan(pricing: TestPricing.bundled)
        files.isPresent = true
        _ = await scanner.scan(pricing: TestPricing.bundled)

        XCTAssertNil(missing)
        XCTAssertEqual(warnings.counts, [1])
        XCTAssertEqual(diagnostics.events, [
            DiagnosticEvent(.historyScan, result: .degraded, category: .storage, providerID: "grok")
        ])

        files.shouldFail = false
        let recovered = await scanner.scan(pricing: TestPricing.bundled)
        files.shouldFail = true
        _ = await scanner.scan(pricing: TestPricing.bundled)

        XCTAssertNotNil(recovered)
        XCTAssertEqual(warnings.counts, [1, 1])
        XCTAssertEqual(diagnostics.events, [
            DiagnosticEvent(.historyScan, result: .degraded, category: .storage, providerID: "grok"),
            DiagnosticEvent(.historyScan, result: .success, providerID: "grok"),
            DiagnosticEvent(.historyScan, result: .degraded, category: .storage, providerID: "grok")
        ])
    }

    func testUnreadableLogWarnsOnceUntilItRecovers() async {
        let path = "/custom/grok/logs/unified.jsonl"
        let files = FailingTextFiles(path: path)
        let warnings = GrokWarningRecorder()
        let scanner = GrokLogUsageScanner(
            files: files,
            environment: FakeEnvironment(["GROK_HOME": "/custom/grok"]),
            homeDirectory: { URL(fileURLWithPath: "/home/ignored") },
            readFailureWarning: warnings.record
        )

        _ = await scanner.scan(pricing: TestPricing.bundled)
        _ = await scanner.scan(pricing: TestPricing.bundled)
        XCTAssertEqual(warnings.counts, [1])

        files.shouldFail = false
        _ = await scanner.scan(pricing: TestPricing.bundled)
        files.shouldFail = true
        _ = await scanner.scan(pricing: TestPricing.bundled)
        XCTAssertEqual(warnings.counts, [1, 1])
    }
}

private final class GrokWarningRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCounts: [Int] = []

    var counts: [Int] { lock.withLock { recordedCounts } }

    func record(_ count: Int) {
        lock.withLock { recordedCounts.append(count) }
    }
}

private final class FailingTextFiles: TextFileAccessing, @unchecked Sendable {
    let path: String
    var shouldFail = true
    var isPresent = true

    init(path: String) {
        self.path = path
    }

    func exists(_ path: String) -> Bool { isPresent && path == self.path }

    func readText(_ path: String) throws -> String {
        if shouldFail { throw TestError.unreadable }
        return ""
    }

    func writeText(_ path: String, _ text: String) throws {}
    func remove(_ path: String) throws {}

    private enum TestError: Error {
        case unreadable
    }
}
