import Foundation

/// Pi·OMP 수집 결과를 공유하며 카드 귀속과 가격 계산을 캐시 밖에서 수행.
actor PiUsageScanner: UsageCollecting {
    static let cacheSchemaVersion = 12

    private let collectors: [UsageFileCollector]
    private let invalidProfile: Bool
    private let settingsFailure: ErrorCategory?

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        incrementalScanner: IncrementalJSONLScanner<UsageRecord>? = nil
    ) {
        let home = homeDirectory()
        let pi: URL?
        do {
            pi = try PiPaths.sessionsDirectory(environment: environment, homeDirectory: home)
            settingsFailure = nil
        } catch {
            pi = nil
            settingsFailure = error is PiPaths.SettingsError ? .decoding : ErrorCategory.classify(error)
        }
        let omp = PiPaths.ompSessionsDirectory(environment: environment, homeDirectory: home)
        invalidProfile = omp == nil
        collectors = [("pi", pi), ("omp", omp)].compactMap { source, root in
            guard let root else { return nil }
            return UsageFileCollector(
                sourceID: source, roots: [root], version: Self.cacheSchemaVersion, scanner: incrementalScanner,
                includeFile: { $0.pathExtension == "jsonl" },
                parse: { data, path in try PiSessionParser.parse(data, path: path, sourceID: source) }
            )
        }
    }

    func collect(since: Date) async -> UsageCollection? {
        var result = UsageCollection(records: [])
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
        for collector in collectors { await collector.scanner.flushPendingWrites() }
    }
}
