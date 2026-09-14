import Foundation

/// 앱 model pricing 데이터의 소유자 — bundled snapshot, Application Support disk cache, live feed(LiteLLM·models.dev·supplement) 시간별 refresh.
/// `current()`는 network 비대기 — 보유한 최신 데이터 제공 후 background 재검증 (stale-while-revalidate).
actor ModelPricingStore {
    static let shared = ModelPricingStore()

    /// 마지막 성공 후 이 간격 경과 시 재fetch.
    private static let refreshInterval: TimeInterval = 60 * 60
    /// 실패 source의 재시도 간격 — provider pass마다 실패 log 반복 방지.
    private static let failureRetryInterval: TimeInterval = 30 * 60

    enum SourceID: String, CaseIterable, Codable, Sendable {
        case litellm
        case modelsDev = "models_dev"
        case supplement
    }

    private struct SourceState: Codable {
        var sourceURL: URL?
        var etag: String?
        var fetchedAt: Date?
        var failedAt: Date?
    }

    /// 출처와 본문을 한 파일에 원자적으로 저장 — state 저장 전 중단되어도 다른 피드의 캐시 수용 금지.
    private struct CachedSupplement: Codable {
        var sourceURL: URL
        var body: Data
    }

    private let http: any HTTPClient
    private let cacheDirectory: URL
    private let now: @Sendable () -> Date
    private let sourceURLs: [SourceID: URL]
    private let bundledData: @Sendable (String) -> Data?

    private var loaded = false
    private var pricing: ModelPricing = .empty
    private var sourceStates: [SourceID: SourceState] = [:]
    private var refreshTask: Task<Void, Never>?

    init(
        http: any HTTPClient = URLSessionHTTPClient(),
        cacheDirectory: URL? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        sourceURLs: [SourceID: URL] = ModelPricingStore.defaultSourceURLs,
        bundledData: @escaping @Sendable (String) -> Data? = ModelPricingStore.bundledResourceData
    ) {
        self.http = http
        self.cacheDirectory = cacheDirectory ?? Self.defaultCacheDirectory
        self.now = now
        self.sourceURLs = sourceURLs
        self.bundledData = bundledData
    }

    static let defaultSourceURLs: [SourceID: URL] = [
        .litellm: URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!,
        .modelsDev: URL(string: "https://models.dev/api.json")!,
        .supplement: URL(string: "https://openusage.chanhyung.kim/pricing_supplement.json")!
    ]

    private static var defaultCacheDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenUsage/pricing", isDirectory: true)
    }

    private static func bundledResourceData(_ resourceName: String) -> Data? {
        guard let url = Bundle.openUsageResources.url(forResource: resourceName, withExtension: "json") else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    /// scan/parse pass에 사용할 pricing snapshot — 기한 도래 source는 background refresh 시작, 결과는 다음 호출에 반영.
    func current() -> ModelPricing {
        loadIfNeeded()
        if refreshTask == nil, SourceID.allCases.contains(where: isDue) {
            refreshTask = Task { await self.refreshDueSources() }
        }
        return pricing
    }

    /// 기한 도래 fetch를 완료까지 수행 — test·결정적 refresh 지점용.
    func refreshNow() async {
        loadIfNeeded()
        if refreshTask == nil {
            refreshTask = Task { await self.refreshDueSources() }
        }
        await refreshTask?.value
    }

    // MARK: - Initial load (bundled + disk cache)

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        sourceStates = readSourceStates()
        if sourceStates[.supplement]?.sourceURL != sourceURLs[.supplement] {
            sourceStates[.supplement] = SourceState(sourceURL: sourceURLs[.supplement])
        }
        rebuildPricing()
    }

    private func rebuildPricing() {
        pricing = ModelPricing(
            supplement: loadSupplement(),
            primary: loadCatalog(.litellm, parse: PricingCatalogCodecs.catalogFromCompact),
            secondary: loadCatalog(.modelsDev, parse: PricingCatalogCodecs.catalogFromCompact)
        )
    }

    private func loadSupplement() -> PricingSupplement {
        let cached = decodedCachedSupplement()
        let bundled = decodedBundledSupplement()
        if cached == nil {
            sourceStates[.supplement]?.etag = nil
            sourceStates[.supplement]?.fetchedAt = nil
        }
        switch (cached, bundled) {
        case (let cached?, let bundled?):
            let cachedDate = Self.supplementDate(cached.updatedAt)
            let bundledDate = Self.supplementDate(bundled.updatedAt)
            if let bundledDate, cachedDate.map({ bundledDate > $0 }) ?? true {
                return bundled
            }
            return cached
        case (let cached?, nil): return cached
        case (nil, let bundled?): return bundled
        case (nil, nil): return PricingSupplement()
        }
    }

    /// 날짜 전용 값은 UTC 자정으로 해석. 누락·비정상 날짜는 가장 오래된 값, 동률은 캐시 우선.
    private static func supplementDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let timestamp = value.count == 10 ? "\(value)T00:00:00Z" : value
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: timestamp), formatter.string(from: date) == timestamp else {
            AppLog.warn("pricing", "Supplement updated_at is not a valid UTC date or timestamp; treating it as undated")
            return nil
        }
        return date
    }

    private func decodedCachedSupplement() -> PricingSupplement? {
        guard let data = readCache(.supplement) else { return nil }
        do {
            let cached = try JSONDecoder().decode(CachedSupplement.self, from: data)
            guard cached.sourceURL == sourceURLs[.supplement] else { return nil }
            return try PricingSupplement.decode(from: cached.body)
        } catch {
            AppLog.warn("pricing", "Cached supplement has no readable source and pricing data; using bundled pricing")
            return nil
        }
    }

    private func decodedBundledSupplement() -> PricingSupplement? {
        guard let bundled = bundledData("pricing_supplement") else {
            AppLog.error("pricing", "bundled pricing_supplement.json missing")
            return nil
        }
        do {
            return try PricingSupplement.decode(from: bundled)
        } catch {
            AppLog.error("pricing", "bundled pricing_supplement.json unreadable: \(error.localizedDescription)")
            return nil
        }
    }

    /// catalog = bundled snapshot 위에 fetch cache merge — cache entry 우선, live feed가 지운 snapshot 전용 model은 생존.
    private func loadCatalog(_ source: SourceID, parse: (Data) throws -> PricingCatalog) -> PricingCatalog {
        var catalog = PricingCatalog()
        let resourceName = source == .litellm ? "pricing_litellm_snapshot" : "pricing_models_dev_snapshot"
        if let bundled = bundledData(resourceName) {
            do {
                catalog = try PricingCatalogCodecs.catalogFromCompact(bundled)
            } catch {
                AppLog.error("pricing", "bundled \(resourceName).json unreadable: \(error.localizedDescription)")
            }
        } else {
            AppLog.error("pricing", "bundled \(resourceName).json missing")
        }
        if let cached = readCache(source) {
            do {
                catalog = catalog.merging(try parse(cached))
            } catch {
                AppLog.warn("pricing", "cached \(source.rawValue) catalog unreadable, using bundled: \(error.localizedDescription)")
            }
        }
        return catalog
    }

    // MARK: - Refresh

    private func isDue(_ source: SourceID) -> Bool {
        let state = sourceStates[source] ?? SourceState()
        if let failedAt = state.failedAt, now().timeIntervalSince(failedAt) < Self.failureRetryInterval {
            return false
        }
        guard let fetchedAt = state.fetchedAt else { return true }
        return now().timeIntervalSince(fetchedAt) >= Self.refreshInterval
    }

    private func refreshDueSources() async {
        defer { refreshTask = nil }
        var changed = false
        for source in SourceID.allCases where isDue(source) {
            if await fetch(source) {
                changed = true
            }
        }
        if changed {
            rebuildPricing()
            AppLog.info("pricing", "pricing refreshed (\(pricing.primary.entries.count) LiteLLM, \(pricing.secondary.entries.count) models.dev, \(pricing.supplement.pricing.count) supplement models)")
        }
        writeSourceStates()
    }

    /// source 1개 fetch 및 cache 파일 갱신 — 새 데이터 저장 시 true.
    private func fetch(_ source: SourceID) async -> Bool {
        guard let url = sourceURLs[source] else { return false }
        let operation: DiagnosticOperation = switch source {
        case .litellm: .pricingLiteLLM
        case .modelsDev: .pricingModelsDev
        case .supplement: .pricingSupplement
        }
        var state = sourceStates[source] ?? SourceState()
        var request = HTTPRequest(method: "GET", url: url, timeout: 30)
        if let etag = state.etag {
            request.headers["If-None-Match"] = etag
        }
        do {
            let response = try await http.send(request)
            switch response.statusCode {
            case 200:
                let validated = try validatedCacheData(source, body: response.body)
                let cacheData = source == .supplement
                    ? try JSONEncoder().encode(CachedSupplement(sourceURL: url, body: validated))
                    : validated
                try writeCache(source, data: cacheData)
                state.etag = response.header("etag")
                state.fetchedAt = now()
                state.failedAt = nil
                sourceStates[source] = state
                AppDiagnostics.record(operation, result: .success)
                return true
            case 304:
                if source == .supplement,
                   request.headers["If-None-Match"] == nil || decodedCachedSupplement() == nil {
                    state.etag = nil
                    throw PricingFetchError.unusableNotModified
                }
                state.fetchedAt = now()
                state.failedAt = nil
                sourceStates[source] = state
                AppDiagnostics.record(operation, result: .success)
                return false
            default:
                throw PricingFetchError.httpStatus(response.statusCode)
            }
        } catch {
            state.failedAt = now()
            sourceStates[source] = state
            AppDiagnostics.failure(operation, error: error,
                                   localContext: "Pricing refresh failed; keeping cached data")
            return false
        }
    }

    /// fetch body 파싱(불량이면 throw — 정상 cache 보호) 후 저장할 바이트 반환 — 대형 catalog은 compact, supplement는 원본 유지.
    private func validatedCacheData(_ source: SourceID, body: Data) throws -> Data {
        switch source {
        case .litellm:
            return try PricingCatalogCodecs.compactData(from: try PricingCatalogCodecs.catalogFromLiteLLM(body))
        case .modelsDev:
            return try PricingCatalogCodecs.compactData(from: try PricingCatalogCodecs.catalogFromModelsDev(body))
        case .supplement:
            _ = try PricingSupplement.decode(from: body)
            return body
        }
    }

    // MARK: - Disk cache

    private func cacheFile(_ source: SourceID) -> URL {
        cacheDirectory.appendingPathComponent("\(source.rawValue).json")
    }

    private var stateFile: URL {
        cacheDirectory.appendingPathComponent("state.json")
    }

    private func readCache(_ source: SourceID) -> Data? {
        try? Data(contentsOf: cacheFile(source))
    }

    private func writeCache(_ source: SourceID, data: Data) throws {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try data.write(to: cacheFile(source), options: .atomic)
    }

    private func readSourceStates() -> [SourceID: SourceState] {
        guard let data = try? Data(contentsOf: stateFile),
              let states = try? JSONDecoder().decode([SourceID: SourceState].self, from: data) else {
            return [:]
        }
        return states
    }

    private func writeSourceStates() {
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(sourceStates)
            try data.write(to: stateFile, options: .atomic)
            AppDiagnostics.record(.pricingCache, result: .success)
        } catch {
            AppDiagnostics.failure(.pricingCache, error: error)
        }
    }
}

private enum PricingFetchError: Error, LocalizedError, CategorizedError {
    var errorCategory: ErrorCategory {
        switch self {
        case .httpStatus(let code): .http(code)
        case .unusableNotModified: .decoding
        }
    }

    case httpStatus(Int)
    case unusableNotModified

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code): return "HTTP \(code)"
        case .unusableNotModified: return "Pricing response did not include a usable supplement"
        }
    }
}
