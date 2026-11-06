import Foundation

/// Pi·OMP 수집 결과를 공유하며 카드 귀속과 가격 계산을 캐시 밖에서 수행.
actor PiUsageScanner: UsageCollecting {
    static let cacheSchemaVersion = 12

    private let environment: EnvironmentReading
    private let home: URL
    private let piScanner: IncrementalJSONLScanner<UsageRecord>
    private let ompCollector: UsageFileCollector?
    private let invalidProfile: Bool

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
        let omp = PiPaths.ompSessionsDirectory(environment: environment, homeDirectory: home)
        invalidProfile = omp == nil
        ompCollector = omp.map { root in
            UsageFileCollector(
                sourceID: "omp", roots: [root], version: Self.cacheSchemaVersion, scanner: incrementalScanner,
                includeFile: { $0.pathExtension == "jsonl" },
                parse: { data, path in try PiSessionParser.parse(data, path: path, sourceID: "omp") }
            )
        }
    }

    func collect(since: Date) async -> UsageCollection? {
        guard !Task.isCancelled else { return nil }
        var result = UsageCollection(records: [])
        var collectors: [UsageFileCollector] = []
        var settingsFailure: ErrorCategory?
        do {
            let pi = try PiPaths.sessionsDirectory(environment: environment, homeDirectory: home)
            let commonRoot = ompCollector?.roots.first.map {
                $0.resolvingSymlinksInPath().path == pi.resolvingSymlinksInPath().path
            } ?? false
            var collector = UsageFileCollector(
                sourceID: "pi", roots: [pi], version: Self.cacheSchemaVersion, scanner: piScanner,
                includeFile: { $0.pathExtension == "jsonl" },
                parse: { data, path in try PiSessionParser.parse(data, path: path, sourceID: commonRoot ? "pi-omp" : "pi") }
            )
            if commonRoot { collector.cacheDiscriminator = "pi-omp" }
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
        if let settingsFailure {
            result.sources.append(.init(sourceID: "pi", failedStores: 1))
            AppDiagnostics.record(.historyScan, result: .degraded, category: settingsFailure,
                                  providerID: "pi", localContext: "session_settings_unavailable")
        }
        if invalidProfile {
            result.sources.append(.init(sourceID: "omp", failedStores: 1))
            AppDiagnostics.record(.historyScan, result: .degraded, category: .decoding,
                                  providerID: "omp", localContext: "invalid_profile")
        }
        result.records = UsageRecordDeduplicator.records(result.records)
        return result
    }

    func flushCache() async {
        await piScanner.flushPendingWrites()
        if let ompCollector { await ompCollector.scanner.flushPendingWrites() }
    }
}
