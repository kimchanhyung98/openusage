import Foundation

/// 도구별 수집기를 순차 실행하고 원본 식별자로 중복 제거. 계정 인증과 별도로 원장 관리.
actor UsageCollectionCoordinator: UsageCollecting {
    static let shared = UsageCollectionCoordinator()
    private var collectors: [any UsageCollecting]?
    private let environment: EnvironmentReading
    private let home: URL

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        collectors: [any UsageCollecting]? = nil
    ) {
        self.collectors = collectors
        self.environment = environment
        self.home = home
    }

    func collect(since: Date) async -> UsageCollection? {
        if collectors == nil { collectors = UsageSourceCollectors.make(environment: environment, home: home) }
        let collectors = collectors ?? []
        var completed: [UsageCollection] = []
        for collector in collectors {
            guard !Task.isCancelled, let collection = await collector.collect(since: since) else { return nil }
            completed.append(collection)
        }
        guard !Task.isCancelled else { return nil }
        return UsageCollection(
            records: UsageRecordDeduplicator.records(completed.flatMap(\.records)),
            sources: completed.flatMap(\.sources)
        )
    }

    func scan(
        providerID: String, daysBack: Int = 30, now: Date = Date(), pricing: ModelPricing,
        costEstimator: UsageHistoryBuilder.CostEstimator? = nil, allowEstimates: Bool = true
    ) async -> LogUsageScan? {
        let since = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        guard let collection = await collect(since: since), !Task.isCancelled else { return nil }
        return UsageHistoryBuilder.scan(
            collection, providerID: providerID, since: since, until: now, pricing: pricing,
            costEstimator: costEstimator, allowEstimates: allowEstimates
        )
    }

    func flushCache() async {
        for collector in collectors ?? [] { await collector.flushCache() }
    }
}
