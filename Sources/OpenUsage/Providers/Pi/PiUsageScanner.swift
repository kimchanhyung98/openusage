import Foundation

/// Pi·OMP 수집 결과를 공유하며 카드 귀속과 가격 계산을 캐시 밖에서 수행.
actor PiUsageScanner: UsageCollecting {
    static let cacheSchemaVersion = 13

    private let environment: EnvironmentReading
    private let home: URL
    private let piScanner: IncrementalJSONLScanner<UsageRecord>
    private let ompScanner: IncrementalJSONLScanner<UsageRecord>

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        incrementalScanner: IncrementalJSONLScanner<UsageRecord>? = nil
    ) {
        self.environment = environment
        let home = homeDirectory()
        self.home = home
        piScanner = incrementalScanner ?? IncrementalJSONLScanner(
            logTag: LogTag.plugin("pi"),
            persistence: JSONLScanCachePersistence(namespace: "pi", schemaVersion: Self.cacheSchemaVersion)
        )
        ompScanner = incrementalScanner ?? IncrementalJSONLScanner(
            logTag: LogTag.plugin("omp"),
            persistence: JSONLScanCachePersistence(namespace: "omp", schemaVersion: Self.cacheSchemaVersion)
        )
    }

    func collect(since: Date) async -> UsageCollection? {
        guard !Task.isCancelled else { return nil }
        var result = UsageCollection(records: [])
        var collectors: [UsageFileCollector] = []
        var settingsFailure: ErrorCategory?
        let omp = PiPaths.ompSessionsDirectory(environment: environment, homeDirectory: home)
        let ompCollector = omp.map { root in
            UsageFileCollector(
                sourceID: "omp", roots: [root], version: Self.cacheSchemaVersion, scanner: ompScanner,
                includeFile: { $0.pathExtension == "jsonl" },
                parse: { data, path in try PiSessionParser.parse(data, path: path, sourceID: "omp") }
            )
        }
        do {
            let pi = try PiPaths.sessionsDirectory(environment: environment, homeDirectory: home)
            let commonRoot = ompCollector?.roots.first.map {
                $0.resolvingSymlinksInPath().path == pi.resolvingSymlinksInPath().path
            } ?? false
            let explicitSession = environment.value(for: "PI_CODING_AGENT_SESSION_DIR")?
                .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty != nil
            let explicitAgent = environment.value(for: "PI_CODING_AGENT_DIR")?
                .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty != nil
            let mixed = commonRoot || explicitSession || explicitAgent
            var collector = UsageFileCollector(
                sourceID: "pi", roots: [pi], version: Self.cacheSchemaVersion, scanner: piScanner,
                includeFile: { $0.pathExtension == "jsonl" },
                parse: { data, path in try PiSessionParser.parse(data, path: path, sourceID: mixed ? "pi-omp" : "pi") }
            )
            if mixed { collector.cacheDiscriminator = "pi-omp" }
            collectors.append(collector)
            if !commonRoot, let ompCollector { collectors.append(ompCollector) }
        } catch {
            settingsFailure = error is PiPaths.SettingsError ? .decoding : ErrorCategory.classify(error)
            if let ompCollector { collectors.append(ompCollector) }
        }
        for collector in collectors {
            guard let collection = await collector.collect(since: since), !Task.isCancelled else { return nil }
            result.records += collection.records
            result.sources += collection.sources
        }
        guard !Task.isCancelled else { return nil }
        if let settingsFailure {
            result.sources.append(.init(sourceID: "pi", failedStores: 1))
            AppDiagnostics.record(.historyScan, result: .degraded, category: settingsFailure,
                                  providerID: "pi", localContext: "session_settings_unavailable")
        }
        if omp == nil {
            result.sources.append(.init(sourceID: "omp", failedStores: 1))
            AppDiagnostics.record(.historyScan, result: .degraded, category: .decoding,
                                  providerID: "omp", localContext: "invalid_profile")
        }
        result.records = UsageRecordDeduplicator.records(result.records)
        return result
    }

    func flushCache() async {
        await piScanner.flushPendingWrites()
        await ompScanner.flushPendingWrites()
    }
}
