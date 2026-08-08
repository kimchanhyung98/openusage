import Foundation

/// incremental scan 기계장치의 `Item` 비의존 절반: 파일 discovery와 scan window 하한.
/// non-generic namespace — window 계산만 필요한 provider(Grok)가 generic actor 없이 공유.
enum JSONLScanning {
    /// 발견한 로그 파일 + parse cache의 key가 되는 stat 필드.
    struct DiscoveredFile: Sendable {
        var path: String
        var size: Int
        var mtime: Date
    }

    /// `now`에서 `daysBack`일 전 날의 시작 — scan window의 하한.
    static func sinceDate(daysBack: Int, now: Date) -> Date {
        let shifted = Calendar.current.date(byAdding: .day, value: -daysBack, to: now) ?? now
        return Calendar.current.startOfDay(for: shifted)
    }

    /// `dir` 아래(재귀) 모든 `*.jsonl` regular file — keep-first dedup이 결정적이도록 경로 정렬. enumeration 불가 시 빈 배열.
    static func jsonlFiles(under dir: URL) -> [DiscoveredFile] {
        // `FileManager.enumerator`는 `dir` 자체가 symlink면 조용히 아무것도 내놓지 않음 — 먼저 resolve.
        let dir = dir.resolvingSymlinksInPath()
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: keys, options: []
        ) else { return [] }
        var files: [DiscoveredFile] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { continue }
            files.append(DiscoveredFile(
                path: url.path,
                size: values.fileSize ?? 0,
                mtime: values.contentModificationDate ?? .distantPast
            ))
        }
        return files.sorted { $0.path < $1.path }
    }
}

/// Claude·Codex·pi 로그 scanner가 공유하는 incremental scan actor: `*.jsonl` 중 변경된 파일만 재파싱(path+size+mtime key의 per-file cache)해 파일 순서대로 반환.
/// provider는 discovery·per-file parser·후처리 dedup만 제공. actor라 parse cache가 refresh 주기 사이에 main actor 밖에서 유지 — parser당 하나를 scanner 인스턴스들이 공유, `Item`은 그 parser의 row.
actor IncrementalJSONLScanner<Item: Codable & Sendable> {
    private typealias CachedFile = JSONLScanCachedFile<Item>

    private struct IdentityWaiter {
        var id: UUID
        var continuation: CheckedContinuation<Bool, Never>
    }

    /// provider/home identity당 in-memory partition 하나 — 같은 home의 multi-account 카드는 재사용, disjoint home끼리는 서로의 파일을 prune하지 못하게 분리.
    private var caches: [String: [String: CachedFile]] = [:]
    private var persistedMetadata: [String: [String: JSONLScanCacheFileMetadata]] = [:]
    private var dirtyUpsertPaths: [String: Set<String>] = [:]
    private var dirtyRemovals: [String: [String: JSONLScanCacheFileMetadata]] = [:]
    private var invalidPersistenceIdentities: Set<String> = []
    private var loadedIdentities: Set<String> = []
    private var activeIdentities: Set<String> = []
    private var identityWaiters: [String: [IdentityWaiter]] = [:]
    private var writeTasks: [String: Task<Void, Never>] = [:]
    private var writeGenerations: [String: Int] = [:]
    private let maxConcurrentParses: Int
    private let parsePermitPool: JSONLParsePermitPool
    private let readFailureReporter: UsageLogReadFailureReporter
    private let persistence: JSONLScanCachePersistence?

    init(
        maxConcurrentParses: Int = 8,
        logTag: String = LogTag.refresh.rawValue,
        readFailureWarning: UsageLogReadFailureReporter.Warning? = nil,
        persistence: JSONLScanCachePersistence? = nil
    ) {
        precondition(maxConcurrentParses > 0)
        self.maxConcurrentParses = maxConcurrentParses
        self.parsePermitPool = JSONLParsePermitPool(limit: maxConcurrentParses)
        self.readFailureReporter = UsageLogReadFailureReporter(logTag: logTag, warning: readFailureWarning)
        self.persistence = persistence
        if let persistence {
            let cutoff = Date().addingTimeInterval(-JSONLScanCachePaths.staleIdentityRetention)
            Task.detached(priority: .utility) {
                await JSONLScanCacheWriter.shared.pruneStaleIdentities(
                    persistence: persistence,
                    before: cutoff
                )
            }
        }
    }

    /// window 안 파일 재파싱(path+size+mtime 불변이면 cache 재사용) 후 입력 순서대로 이어붙여 반환 — 호출자가 경로 정렬 목록을 넘겨 keep-first dedup 유지.
    /// mtime이 `since` 이전인 파일은 skip, 읽기 실패 파일은 cache에 남기지 않아 일시적 오류가 고착되지 않음.
    /// `nil`은 취소를 의미 — 완료된 scan의 빈 결과는 `[]`이므로 취소와 "정말 빈 데이터"가 섞이지 않음.
    func items(
        from files: [JSONLScanning.DiscoveredFile],
        since: Date,
        cacheIdentity: String = "default",
        parse: @Sendable @escaping (Data) -> [Item]?
    ) async -> [Item]? {
        precondition(!cacheIdentity.isEmpty)
        guard await acquire(cacheIdentity) else { return nil }
        defer { release(cacheIdentity) }
        guard !Task.isCancelled else { return nil }

        await loadCacheIfNeeded(identity: cacheIdentity)
        guard !Task.isCancelled else { return nil }
        let currentCache = caches[cacheIdentity] ?? [:]
        // 같은 parser의 다른 scan 파일들도 window에서 벗어날 때까지 shared partition에 유지 — disjoint root의 multi-account 카드가 한 actor를 안전하게 공유. 반환은 현재 호출의 입력 경로만.
        var nextCache = currentCache.filter { $0.value.mtime >= since }
        var toParse: [JSONLScanning.DiscoveredFile] = []
        for file in files {
            guard file.mtime >= since else { continue }
            if let cached = currentCache[file.path], cached.size == file.size, cached.mtime == file.mtime {
                nextCache[file.path] = cached
            } else {
                nextCache[file.path] = nil
                toParse.append(file)
            }
        }
        let parseResults = await Self.parseFiles(
            toParse,
            maxConcurrentParses: maxConcurrentParses,
            permitPool: parsePermitPool,
            parse: parse
        )
        guard !Task.isCancelled else { return nil }
        let checkedPaths = Set(parseResults.lazy.map(\.file.path))
        let unreadablePaths = Set(parseResults.lazy.filter(\.readFailed).map(\.file.path))
        await readFailureReporter.update(checkedPaths: checkedPaths, failingPaths: unreadablePaths)
        guard !Task.isCancelled else { return nil }
        var parsedPaths: Set<String> = []
        for result in parseResults {
            let (file, parsed) = (result.file, result.items)
            guard let parsed else { continue }
            nextCache[file.path] = CachedFile(size: file.size, mtime: file.mtime, items: parsed)
            parsedPaths.insert(file.path)
        }
        for (path, cached) in currentCache where nextCache[path] == nil {
            dirtyRemovals[cacheIdentity, default: [:]][path] = JSONLScanCacheFileMetadata(
                size: cached.size,
                mtime: cached.mtime,
                recordFileName: JSONLScanCachePaths.recordFileName(path: path)
            )
        }
        caches[cacheIdentity] = nextCache
        dirtyUpsertPaths[cacheIdentity, default: []].formUnion(parsedPaths)
        if !dirtyUpsertPaths[cacheIdentity, default: []].isEmpty
            || !dirtyRemovals[cacheIdentity, default: [:]].isEmpty
            || invalidPersistenceIdentities.contains(cacheIdentity)
        {
            scheduleWrite(identity: cacheIdentity)
        }

        var items: [Item] = []
        for file in files {
            guard let cached = nextCache[file.path] else { continue }
            items.append(contentsOf: cached.items)
        }
        return Task.isCancelled ? nil : items
    }

    /// debounce된 실제 task를 우회하지 않고 대기 — 테스트가 짧은 debounce로 persistence 완료를 검증하는 용도.
    func waitForPendingWritesForTesting() async {
        for task in Array(writeTasks.values) {
            await task.value
        }
    }

    /// 최신 snapshot 즉시 commit — one-shot 프로세스가 종료 전 호출. 장수 앱은 평소의 debounce 경로 유지.
    func flushPendingWrites() async {
        var identities = Set(writeTasks.keys)
        identities.formUnion(dirtyUpsertPaths.compactMap { $0.value.isEmpty ? nil : $0.key })
        identities.formUnion(dirtyRemovals.compactMap { $0.value.isEmpty ? nil : $0.key })
        identities.formUnion(invalidPersistenceIdentities)
        for identity in identities {
            writeTasks[identity]?.cancel()
            writeTasks[identity] = nil
            // 진행 중인 encoding/writer 작업을 세대 교체로 대체 — dirty 상태는 이 명시적 drain이 commit하도록 남김.
            let generation = writeGenerations[identity, default: 0] + 1
            writeGenerations[identity] = generation
            await persistCache(identity: identity, generation: generation)
        }
    }

    func cacheRecordURLForTesting(identity: String, filePath: String) -> URL? {
        guard let persistence else { return nil }
        return JSONLScanCachePaths.recordURL(
            persistence: persistence,
            identity: identity,
            fileName: JSONLScanCachePaths.recordFileName(path: filePath)
        )
    }

    func queuedScanCountForTesting(identity: String) -> Int {
        identityWaiters[identity]?.count ?? 0
    }

    // MARK: - Same-identity scan serialization

    /// actor는 `await parseFiles`에서 reentrant — 이 gate가 없으면 동시 실행된 두 카드가 같은 home을 중복 cold-parse 후 cache 교체를 경합.
    /// 같은 identity만 첫 parse 뒤에 줄 세워 cache hit 유도, 다른 identity는 독립.
    private func acquire(_ identity: String) async -> Bool {
        guard activeIdentities.contains(identity) else {
            activeIdentities.insert(identity)
            return true
        }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    identityWaiters[identity, default: []].append(
                        IdentityWaiter(id: waiterID, continuation: continuation)
                    )
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(identity: identity, waiterID: waiterID) }
        }
    }

    private func cancelWaiter(identity: String, waiterID: UUID) {
        guard var waiters = identityWaiters[identity],
              let index = waiters.firstIndex(where: { $0.id == waiterID })
        else { return }
        let waiter = waiters.remove(at: index)
        identityWaiters[identity] = waiters.isEmpty ? nil : waiters
        waiter.continuation.resume(returning: false)
    }

    private func release(_ identity: String) {
        guard var waiters = identityWaiters[identity], !waiters.isEmpty else {
            activeIdentities.remove(identity)
            identityWaiters[identity] = nil
            return
        }
        let next = waiters.removeFirst()
        identityWaiters[identity] = waiters.isEmpty ? nil : waiters
        next.continuation.resume(returning: true)
    }

    // MARK: - Persistence

    private func loadCacheIfNeeded(identity: String) async {
        guard loadedIdentities.insert(identity).inserted, let persistence else { return }
        do {
            guard let snapshot = try JSONLScanCacheWriter.shared.load(
                persistence: persistence,
                identity: identity,
                itemType: Item.self
            ) else { return }
            let manifest = snapshot.manifest
            guard manifest.formatVersion == JSONLScanCachePaths.formatVersion,
                  manifest.schemaVersion == persistence.schemaVersion,
                  manifest.identity == identity
            else {
                AppLog.info(.cache, "\(persistence.namespace) log parse cache schema changed; rebuilding")
                invalidPersistenceIdentities.insert(identity)
                return
            }
            persistedMetadata[identity] = manifest.files
            caches[identity] = snapshot.files
            dirtyRemovals[identity, default: [:]].merge(snapshot.invalidRecords) { _, new in new }
            if !snapshot.invalidRecords.isEmpty {
                AppLog.warn(
                    .cache,
                    "\(persistence.namespace) log parse cache has \(snapshot.invalidRecords.count) unreadable file records; reparsing"
                )
            }
            AppLog.debug(
                .cache,
                "loaded \(snapshot.files.count) \(persistence.namespace) log files from parse cache"
            )
        } catch {
            invalidPersistenceIdentities.insert(identity)
            AppLog.warn(
                .cache,
                "\(persistence.namespace) log parse cache unreadable; rebuilding: \(error.localizedDescription)"
            )
        }
    }

    private func scheduleWrite(identity: String) {
        guard let persistence else { return }
        let generation = writeGenerations[identity, default: 0] + 1
        writeGenerations[identity] = generation
        writeTasks[identity]?.cancel()
        writeTasks[identity] = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: persistence.writeDebounce)
            } catch {
                await self.finishWriteTask(identity: identity, generation: generation)
                return
            }
            guard !Task.isCancelled else { return }
            await self.persistCache(identity: identity, generation: generation)
            await self.finishWriteTask(identity: identity, generation: generation)
        }
    }

    private func finishWriteTask(identity: String, generation: Int) {
        guard writeGenerations[identity] == generation else { return }
        writeTasks[identity] = nil
    }

    private func persistCache(identity: String, generation: Int) async {
        guard let persistence,
              writeGenerations[identity] == generation,
              let files = caches[identity]
        else { return }

        let manifestFiles = metadata(for: files)
        let pathsToWrite = dirtyUpsertPaths[identity, default: []]
        let records = pathsToWrite.compactMap {
            path -> (path: String, metadata: JSONLScanCacheFileMetadata, record: JSONLScanCacheRecord<Item>)? in
            guard let cached = files[path], let metadata = manifestFiles[path] else { return nil }
            return (
                path,
                metadata,
                JSONLScanCacheRecord(path: path, size: cached.size, mtime: cached.mtime, items: cached.items)
            )
        }
        let removalSnapshot = dirtyRemovals[identity, default: [:]]
        do {
            // 변경된 per-source record만 encode — O(30일 전체 이력) 재작성 회피. 작은 merged manifest는 writer가 lock 안에서 구성.
            let upserts = try await Task.detached(priority: .utility) {
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                return try Dictionary(uniqueKeysWithValues: records.map { input in
                    (
                        input.path,
                        JSONLScanCacheUpsert(
                            metadata: input.metadata,
                            recordData: try encoder.encode(input.record)
                        )
                    )
                })
            }.value
            guard !Task.isCancelled, writeGenerations[identity] == generation else { return }
            let result = try await JSONLScanCacheWriter.shared.commit(
                JSONLScanCacheWriteBatch(
                    persistence: persistence,
                    identity: identity,
                    upserts: upserts,
                    removals: removalSnapshot
                )
            )
            guard writeGenerations[identity] == generation else { return }
            persistedMetadata[identity] = result.manifest.files
            dirtyUpsertPaths[identity, default: []].subtract(result.acceptedUpsertPaths)
            for path in removalSnapshot.keys {
                dirtyRemovals[identity]?[path] = nil
            }
            invalidPersistenceIdentities.remove(identity)
            AppLog.debug(
                .cache,
                "persisted \(result.acceptedUpsertPaths.count) changed / \(result.manifest.files.count) retained \(persistence.namespace) log files"
            )
        } catch is CancellationError {
            return
        } catch {
            AppLog.warn(
                .cache,
                "could not persist \(persistence.namespace) log parse cache: \(error.localizedDescription)"
            )
        }
    }

    private func metadata(for files: [String: CachedFile]) -> [String: JSONLScanCacheFileMetadata] {
        var result: [String: JSONLScanCacheFileMetadata] = [:]
        result.reserveCapacity(files.count)
        for (path, cached) in files {
            result[path] = JSONLScanCacheFileMetadata(
                size: cached.size,
                mtime: cached.mtime,
                recordFileName: JSONLScanCachePaths.recordFileName(path: path)
            )
        }
        return result
    }

    /// 변경 파일을 상한 내에서 병렬 read + parse. 결과는 입력 순서로 키잉, `nil` item 목록은 읽기 실패 표시.
    private static func parseFiles(
        _ files: [JSONLScanning.DiscoveredFile],
        maxConcurrentParses: Int,
        permitPool: JSONLParsePermitPool,
        parse: @Sendable @escaping (Data) -> [Item]?
    ) async -> [(file: JSONLScanning.DiscoveredFile, items: [Item]?, readFailed: Bool)] {
        await withTaskGroup(
            of: (Int, [Item]?, Bool).self,
            returning: [(file: JSONLScanning.DiscoveredFile, items: [Item]?, readFailed: Bool)].self
        ) { group in
            func addTask(at index: Int) {
                let file = files[index]
                group.addTask {
                    guard await permitPool.acquire() else { return (index, nil, false) }
                    let result: (Int, [Item]?, Bool)
                    if Task.isCancelled || !FileManager.default.fileExists(atPath: file.path) {
                        result = (index, nil, false)
                    } else if let data = FileManager.default.contents(atPath: file.path) {
                        result = (index, parse(data), false)
                    } else {
                        result = (index, nil, true)
                    }
                    await permitPool.release()
                    return result
                }
            }

            var nextIndex = 0
            let initialCount = min(maxConcurrentParses, files.count)
            for index in 0..<initialCount where !Task.isCancelled {
                addTask(at: index)
                nextIndex += 1
            }

            var results = files.map { (file: $0, items: Optional<[Item]>.none, readFailed: false) }
            for await (index, items, readFailed) in group {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                results[index] = (files[index], items, readFailed)
                if nextIndex < files.count {
                    addTask(at: nextIndex)
                    nextIndex += 1
                }
            }
            return results
        }
    }
}
