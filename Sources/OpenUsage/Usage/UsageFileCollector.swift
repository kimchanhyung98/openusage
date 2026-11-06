import Foundation

struct UsageFileCollector: UsageCollecting {
    typealias Parser = @Sendable (Data, String) throws -> [UsageRecord]?

    let sourceID: String
    var providerID: String? = nil
    let roots: [URL]
    let includeFile: @Sendable (URL) -> Bool
    let parse: Parser
    let scanner: IncrementalJSONLScanner<UsageRecord>

    init(
        sourceID: String, providerID: String? = nil, roots: [URL], version: Int = 1,
        scanner: IncrementalJSONLScanner<UsageRecord>? = nil,
        includeFile: @escaping @Sendable (URL) -> Bool,
        parse: @escaping Parser
    ) {
        self.sourceID = sourceID
        self.providerID = providerID
        self.roots = roots
        self.includeFile = includeFile
        self.parse = parse
        self.scanner = scanner ?? IncrementalJSONLScanner(
            logTag: LogTag.plugin(sourceID),
            persistence: JSONLScanCachePersistence(namespace: sourceID, schemaVersion: version)
        )
    }

    func collect(since: Date) async -> UsageCollection? {
        let discovery = UsageFileDiscovery.files(under: roots, matching: includeFile)
        let identity = roots.map { $0.resolvingSymlinksInPath().path }.sorted().joined(separator: "\n")
        guard let result = await scanner.scan(
            from: discovery.files, since: since, cacheIdentity: identity,
            onDiskCacheHit: UsageRecordDiagnostics.report,
            parse: { data, path in
                let records = try parse(data, path)
                if let records { UsageRecordDiagnostics.report(records) }
                return records
            }
        ), !Task.isCancelled else { return nil }
        if discovery.failures > 0 {
            AppDiagnostics.record(
                .historyScan, result: .degraded, category: .storage, providerID: sourceID,
                localContext: "source=\(sourceID); discovery_failures=\(discovery.failures)"
            )
        }
        return UsageCollection(records: result.items, sources: [UsageSourceState(
            sourceID: sourceID, providerID: providerID, completedStores: result.completedFiles,
            failedStores: discovery.failures + result.failedPaths.count
        )])
    }

    func flushCache() async { await scanner.flushPendingWrites() }
}

enum UsageFileDiscovery {
    struct Result {
        var files: [JSONLScanning.DiscoveredFile] = []
        var failures = 0
    }

    static func files(under roots: [URL], matching include: (URL) -> Bool) -> Result {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        var result = Result()
        var seen: Set<String> = []
        func append(_ url: URL) {
            guard include(url) else { return }
            let canonical = url.resolvingSymlinksInPath()
            guard seen.insert(canonical.path).inserted else { return }
            do {
                let values = try canonical.resourceValues(forKeys: keys)
                guard values.isRegularFile == true else { return }
                result.files.append(.init(
                    path: canonical.path, size: values.fileSize ?? 0,
                    mtime: values.contentModificationDate ?? .distantPast
                ))
            } catch {
                result.failures += 1
            }
        }
        for root in Set(roots.map { $0.resolvingSymlinksInPath() }) {
            do {
                let values = try root.resourceValues(forKeys: keys)
                guard values.isDirectory == true else { append(root); continue }
                guard let enumerator = FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: Array(keys), options: [],
                    errorHandler: { _, _ in result.failures += 1; return true }
                ) else { result.failures += 1; continue }
                for case let url as URL in enumerator { append(url) }
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                continue
            } catch {
                result.failures += 1
            }
        }
        result.files.sort { $0.path < $1.path }
        return result
    }
}

enum UsageRecordDiagnostics {
    static func report(_ records: [UsageRecord]) {
        for (source, rows) in Dictionary(grouping: records, by: \.sourceID) {
            UsageLogNumbers.reportRejectedRows(rows.filter { $0.issues.contains(.invalidNumbers) }.count, source: source)
            let invalid = rows.filter { !$0.issues.subtracting([.invalidNumbers]).isEmpty }.count
            guard invalid > 0 else { continue }
            AppDiagnostics.record(
                .historyScan, result: .degraded, category: .decoding, providerID: source,
                localContext: "source=\(source); incomplete_records=\(invalid)"
            )
        }
    }
}
