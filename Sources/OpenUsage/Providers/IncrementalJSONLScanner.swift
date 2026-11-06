import Foundation

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
    private var unreportedRestoredPaths: [String: Set<String>] = [:]
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
    private let workQueue: BackgroundWorkQueue

    init(
        maxConcurrentParses: Int = 1,
        logTag: String = LogTag.refresh.rawValue,
        readFailureWarning: UsageLogReadFailureReporter.Warning? = nil,
        persistence: JSONLScanCachePersistence? = nil,
        workQueue: BackgroundWorkQueue = .shared
    ) {
        precondition(maxConcurrentParses > 0)
        self.maxConcurrentParses = maxConcurrentParses
        self.parsePermitPool = JSONLParsePermitPool(limit: maxConcurrentParses)
        self.readFailureReporter = UsageLogReadFailureReporter(logTag: logTag, warning: readFailureWarning)
        self.persistence = persistence
        self.workQueue = workQueue
        if let persistence {
            let cutoff = Date().addingTimeInterval(-JSONLScanCachePaths.staleIdentityRetention)
            Task.detached(priority: .utility) {
                await workQueue.run("log-cache:prune") {
                    await JSONLScanCacheWriter.shared.pruneStaleIdentities(
                        persistence: persistence,
                        before: cutoff
                    )
                }
            }
        }
    }

    /// window 안 파일 재파싱(path+size+mtime 불변이면 cache 재사용) 후 입력 순서대로 이어붙여 반환 — 호출자가 경로 정렬 목록을 넘겨 keep-first dedup 유지.
    /// mtime이 `since` 이전인 파일은 skip, 읽기 실패 파일은 cache에 남기지 않아 일시적 오류가 고착되지 않음.
    /// 디스크에서 복원한 파일을 실제 재사용할 때만 `onDiskCacheHit` 1회 호출 — 반복 메모리 hit·다른 카드 조회는 재보고하지 않음.
    /// `nil`은 취소를 의미 — 완료된 scan의 빈 결과는 `[]`이므로 취소와 "정말 빈 데이터"가 섞이지 않음.
    struct ScanResult: Sendable {
        var items: [Item]
        var completedFiles: Int
        var failedPaths: Set<String>
    }

    func items(
        from files: [JSONLScanning.DiscoveredFile],
        since: Date,
        cacheIdentity: String = "default",
        onDiskCacheHit: (@Sendable ([Item]) -> Void)? = nil,
        parse: @Sendable @escaping (Data) -> [Item]?
    ) async -> [Item]? {
        await scan(
            from: files, since: since, cacheIdentity: cacheIdentity, onDiskCacheHit: onDiskCacheHit,
            parse: { data, _ in parse(data) }
        )?.items
    }

    /// 파일 메타데이터와 읽기·파싱 실패를 필요한 수집 호출자에게 함께 반환.
    func scan(
        from files: [JSONLScanning.DiscoveredFile],
        since: Date,
        cacheIdentity: String = "default",
        canReuseCachedFile: (@Sendable (String) -> Bool)? = nil,
        onDiskCacheHit: (@Sendable ([Item]) -> Void)? = nil,
        parse: @Sendable @escaping (Data, String) throws -> [Item]?
    ) async -> ScanResult? {
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
            if let cached = currentCache[file.path], cached.size == file.size, cached.mtime == file.mtime,
               canReuseCachedFile?(file.path) ?? true {
                nextCache[file.path] = cached
                if let onDiskCacheHit, unreportedRestoredPaths[cacheIdentity]?.remove(file.path) != nil {
                    onDiskCacheHit(cached.items)
                }
            } else {
                unreportedRestoredPaths[cacheIdentity]?.remove(file.path)
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
        let checkedPaths = Set(parseResults.lazy.filter(\.readAttempted).map(\.file.path))
        let unreadablePaths = Set(parseResults.lazy.filter(\.readFailed).map(\.file.path))
        await readFailureReporter.update(checkedPaths: checkedPaths, failingPaths: unreadablePaths)
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
        unreportedRestoredPaths[cacheIdentity]?.formIntersection(nextCache.keys)
        dirtyUpsertPaths[cacheIdentity, default: []].formUnion(parsedPaths)
        if !dirtyUpsertPaths[cacheIdentity, default: []].isEmpty
            || !dirtyRemovals[cacheIdentity, default: [:]].isEmpty
            || invalidPersistenceIdentities.contains(cacheIdentity)
        {
            scheduleWrite(identity: cacheIdentity)
        }
        // 전체 집계는 폐기하되 취소 전에 완료한 파일은 재사용 — 대용량 cold scan의 반복 시간 초과 방지.
        guard !Task.isCancelled, parseResults.allSatisfy(\.readAttempted) else {
            AppLog.info(.cache, "cancelled \(persistence?.namespace ?? "local") scan; cached \(parsedPaths.count) completed files for retry")
            return nil
        }

        var items: [Item] = []
        for file in files {
            guard let cached = nextCache[file.path] else { continue }
            items.append(contentsOf: cached.items)
        }
        let failures = Set(parseResults.filter { $0.readAttempted && $0.items == nil }.map(\.file.path))
        let completed = files.filter { $0.mtime >= since && nextCache[$0.path] != nil }.count
        return Task.isCancelled ? nil : ScanResult(items: items, completedFiles: completed, failedPaths: failures)
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
            await queueWrite(identity: identity, generation: generation)
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
            unreportedRestoredPaths[identity] = Set(snapshot.files.keys)
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
            await self.queueWrite(identity: identity, generation: generation)
            await self.finishWriteTask(identity: identity, generation: generation)
        }
    }

    private func finishWriteTask(identity: String, generation: Int) {
        guard writeGenerations[identity] == generation else { return }
        writeTasks[identity] = nil
    }

    private func queueWrite(identity: String, generation: Int) async {
        await workQueue.run("log-cache:write") {
            await self.persistCache(identity: identity, generation: generation)
        }
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

    /// 변경 파일을 상한 내에서 병렬 read + parse. 결과는 입력 순서로 키잉, 읽기 시도·실패 여부는 parser 결과와 분리.
    private static func parseFiles(
        _ files: [JSONLScanning.DiscoveredFile],
        maxConcurrentParses: Int,
        permitPool: JSONLParsePermitPool,
        parse: @Sendable @escaping (Data, String) throws -> [Item]?
    ) async -> [(file: JSONLScanning.DiscoveredFile, items: [Item]?, readAttempted: Bool, readFailed: Bool)] {
        await withTaskGroup(
            of: (Int, [Item]?, Bool, Bool).self,
            returning: [(file: JSONLScanning.DiscoveredFile, items: [Item]?, readAttempted: Bool, readFailed: Bool)].self
        ) { group in
            func addTask(at index: Int) {
                let file = files[index]
                group.addTask {
                    guard await permitPool.acquire() else { return (index, nil, false, false) }
                    let result: (Int, [Item]?, Bool, Bool)
                    if Task.isCancelled {
                        result = (index, nil, false, false)
                    } else if let data = FileManager.default.contents(atPath: file.path) {
                        do {
                            let parsed = try parse(data, file.path)
                            result = (index, Task.isCancelled ? nil : parsed, true, false)
                        } catch is CancellationError {
                            result = (index, nil, false, false)
                        } catch {
                            result = Task.isCancelled ? (index, nil, false, false) : (index, nil, true, true)
                        }
                    } else {
                        result = Task.isCancelled ? (index, nil, false, false) : (index, nil, true, true)
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

            var results = files.map { (file: $0, items: Optional<[Item]>.none, readAttempted: false, readFailed: false) }
            for await (index, items, readAttempted, readFailed) in group {
                results[index] = (files[index], items, readAttempted, readFailed)
                if Task.isCancelled || group.isCancelled || !readAttempted {
                    group.cancelAll()
                    continue
                }
                if nextIndex < files.count {
                    addTask(at: nextIndex)
                    nextIndex += 1
                }
            }
            return results
        }
    }
}
