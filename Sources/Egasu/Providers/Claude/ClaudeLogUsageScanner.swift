import Foundation

/// Claude Code 로컬 세션 로그(`<config dir>/projects/**/*.jsonl`) 네이티브 스캔으로 일별 토큰/비용 추정.
/// ccusage Claude adapter 의미론 포팅 — root 해석, 유효성 검사, `(message.id, requestId)` dedup, cost mode "auto".
/// actor로 main actor 밖에서 실행; 파일은 path + size + mtime으로 캐시되어 변경분만 재파싱.
actor ClaudeLogUsageScanner {
    private let environment: EnvironmentReading
    private let homeDirectory: @Sendable () -> URL
    private let scanner: IncrementalJSONLScanner<Entry>
    /// scoped provider 인스턴스의 안정적 parse-source identity — 같은 물리 root를 보는
    /// 계정/시간 필터는 같은 값을 전달해 whole-file 레코드 공유.
    private let cacheIdentityOverride: String?
    /// 추가 계정 카드의 config dir 고정 — 표준 해석 전체를 대체, 다른 계정 로그 유입 금지.
    /// `nil`이면 표준 walk 그대로 유지.
    private let rootsOverride: [URL]?
    /// DEFAULT 카드의 표준 root에 덧붙는 같은 계정 커스텀 config dir — side home의 자기 spend 집계용.
    private let additionalRoots: [URL]
    /// 관리 전환이 `~/.claude` 소유 시 true — 기본 카드 스캔은 ambient `CLAUDE_CONFIG_DIR`를 무시하고 공유 home만 walk.
    nonisolated let pinsSharedHome: Bool

    /// 파싱된 usage 라인 1건 — 토큰은 `TokenBreakdown`으로 정규화, dedup 필드 동반(캐시된 entry 위에서 dedup 실행).
    struct Entry: Codable, Sendable, Equatable {
        var timestamp: Date
        var tokens: TokenBreakdown
        var messageID: String?
        var requestID: String?
        var isSidechain: Bool = false
        /// `speed` 필드 존재 여부(dedup tiebreaker) — "fast" 여부는 `tokens.isFast`.
        var hasSpeed: Bool = false
        var costUSD: Double?
        /// 모델 없음 또는 placeholder `<synthetic>`이면 `nil` — 기록 비용도 없으면 토큰만 집계.
        var model: String?
        /// 손상된 행도 캐시에 남겨 cache hit가 정상 빈 이력으로 바뀌는 현상 방지.
        var invalidNumericValues = false
    }

    /// 같은 Claude home을 읽는 카드들의 공유 actor — 첫 스캔이 캐시를 채우고 나머지는 재사용.
    /// 테스트는 격리된 메모리 전용 scanner 주입.
    /// 도구 인자의 null·compaction 사용량을 누락하던 이전 parse cache의 재사용 방지.
    static let cacheSchemaVersion = 5

    private static let sharedScanner = IncrementalJSONLScanner<Entry>(
        logTag: LogTag.plugin("claude"),
        persistence: JSONLScanCachePersistence(namespace: "claude", schemaVersion: cacheSchemaVersion)
    )

    static func flushPersistentCacheWrites() async {
        await sharedScanner.flushPendingWrites()
    }

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        incrementalScanner: IncrementalJSONLScanner<Entry>? = nil,
        cacheIdentityOverride: String? = nil,
        rootsOverride: [URL]? = nil,
        additionalRoots: [URL] = [],
        pinsSharedHome: Bool = false
    ) {
        precondition(cacheIdentityOverride?.isEmpty != true)
        // scoped root 집합은 자체 parse-source identity 필수 — 기본 카드 캐시 레코드와 충돌 방지.
        precondition(rootsOverride == nil || cacheIdentityOverride != nil)
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.scanner = incrementalScanner ?? Self.sharedScanner
        self.cacheIdentityOverride = cacheIdentityOverride
        self.rootsOverride = rootsOverride
        self.additionalRoots = additionalRoots
        self.pinsSharedHome = pinsSharedHome
    }

    /// 최근 `daysBack`일의 Claude 로그 스캔 — 데이터 dir/로그 파일 부재 시 `nil`("No data" 렌더),
    /// 로그는 있으나 window 내 usage 없음이면 빈 series.
    func scan(daysBack: Int = 30, now: Date = Date(), pricing: ModelPricing) async -> LogUsageScan? {
        let since = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        let cacheIdentity = parseCacheIdentity()
        let roots = claudeRoots()
        let discovery = UsageFileDiscovery.files(under: roots.urls.map { $0.appendingPathComponent("projects") }) {
            $0.pathExtension == "jsonl"
        }
        let discoveryFailures = roots.failures + discovery.failures
        if discoveryFailures > 0 {
            AppDiagnostics.record(
                .historyScan, result: .degraded, category: .storage, providerID: "claude",
                localContext: "source=claude; discovery_failures=\(discoveryFailures)"
            )
        }

        // entry는 경로 정렬 파일 순서로 연결 — dedup keep-first의 결정성 보장.
        guard let result = await scanner.scan(
            from: discovery.files,
            since: since,
            cacheIdentity: cacheIdentity,
            onDiskCacheHit: { UsageLogNumbers.reportRejectedRows($0.filter(\.invalidNumericValues).count, source: "claude") },
            parse: { data, _ in Self.parseFile(data) }
        ), !Task.isCancelled else { return nil }
        let failures = discoveryFailures + result.failedPaths.count
        guard !discovery.files.isEmpty || failures > 0 else { return nil }
        var scan = Self.aggregate(entries: Self.dedup(result.items), since: since, pricing: pricing)
        scan.readFailureCount = failures
        return scan
    }

    /// 발견된 root 목록이 아닌 안정적 source 구성 identity — Cowork 세션 추가 시 기존 캐시 확장(cold-parse 방지),
    /// scoped override는 명시 identity로 home 간 분리 유지.
    private func parseCacheIdentity() -> String {
        if let cacheIdentityOverride { return cacheIdentityOverride }
        let home = homeDirectory().resolvingSymlinksInPath().path
        let configuredRoots: [URL]
        if !pinsSharedHome,
           let raw = environment.value(for: "CLAUDE_CONFIG_DIR")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty
        {
            var url = URL(fileURLWithPath: expandHome(raw))
            if url.lastPathComponent == "projects" { url.deleteLastPathComponent() }
            configuredRoots = [url]
        } else {
            let homeURL = homeDirectory()
            let xdg = environment.value(for: "XDG_CONFIG_HOME")?.nilIfEmpty
                .map { URL(fileURLWithPath: expandHome($0)) }
                ?? homeURL.appendingPathComponent(".config")
            configuredRoots = [
                xdg.appendingPathComponent("claude"),
                homeURL.appendingPathComponent(".claude"),
            ]
        }
        let roots = Set(configuredRoots.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
            .sorted()
            .joined(separator: "\n")
        return "home=\(home)\nroots=\(roots)"
    }

    // MARK: - Root and file discovery

    /// Claude config dir 후보 목록 — `CLAUDE_CONFIG_DIR` 단일 경로 우선,
    /// 없으면 `$XDG_CONFIG_HOME/claude`·`~/.claude`; Cowork 세션 sandbox는 항상 추가.
    private func claudeRoots() -> (urls: [URL], failures: Int) {
        var roots: [URL] = []
        var seen: Set<String> = []

        func add(_ url: URL) {
            guard seen.insert(url.path).inserted else { return }
            roots.append(url)
        }

        // scoped 카드는 자기 config dir만 스캔 — env 해석·Cowork walk 없음(sandbox는 기본 로그인 소속).
        if let rootsOverride {
            for root in rootsOverride { add(root) }
            return (roots, 0)
        }

        if !pinsSharedHome,
           let raw = environment.value(for: "CLAUDE_CONFIG_DIR")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            var url = URL(fileURLWithPath: expandHome(raw))
            // `projects/` dir 자체를 상위 config dir의 alias로 수용.
            if url.lastPathComponent == "projects" { url.deleteLastPathComponent() }
            add(url)
        } else {
            let home = homeDirectory()
            let xdg = environment.value(for: "XDG_CONFIG_HOME")?.nilIfEmpty.map { URL(fileURLWithPath: expandHome($0)) }
                ?? home.appendingPathComponent(".config")
            add(xdg.appendingPathComponent("claude"))
            add(home.appendingPathComponent(".claude"))
        }

        let cowork = Self.coworkClaudeDirs(home: homeDirectory())
        for sandbox in cowork.urls { add(sandbox) }
        // 같은 계정 커스텀 config dir(기본 카드 전용) — side home의 자기 spend.
        for root in additionalRoots {
            add(root)
        }
        return (roots, cowork.failures)
    }

    /// Cowork(desktop agent mode)가 세션마다 만드는 `.claude` dir — `~/.claude`와 같은 세션 로그 보유.
    /// walk는 알려진 level로 한정 — 세션 dir 내부의 전체 sandbox home 재귀 금지.
    private static func coworkClaudeDirs(home: URL) -> (urls: [URL], failures: Int) {
        let base = home
            .appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions")

        var failures = 0
        func subdirectories(of url: URL) -> [URL] {
            do {
                let contents = try FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
                )
                return contents.filter {
                    do { return try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
                    catch { failures += 1; return false }
                }
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                return []
            } catch {
                failures += 1
                return []
            }
        }

        var dirs: [URL] = []
        for group in subdirectories(of: base) {
            for sub in subdirectories(of: group) {
                var sessions = subdirectories(of: sub)
                for holder in sessions where holder.lastPathComponent == "agent" {
                    sessions.append(contentsOf: subdirectories(of: holder))
                }
                for session in sessions {
                    dirs.append(session.appendingPathComponent(".claude"))
                }
            }
        }
        return (dirs.sorted { $0.path < $1.path }, failures)
    }

    // MARK: - Deduplication

    private struct ExactKey: Hashable {
        var messageID: String
        var requestID: String?
    }

    /// 재생된 usage 라인 제거(ccusage 선호 유지) — `(message.id, requestId)` 키 + sidechain 재생 대응
    /// `message.id` 보조 인덱스; message id 없는 entry는 항상 유지.
    static func dedup(_ entries: [Entry]) -> [Entry] {
        var deduped: [Entry] = []
        var exactIndex: [ExactKey: Int] = [:]
        var messageIndex: [String: [Int]] = [:]

        for entry in entries {
            guard let messageID = entry.messageID else {
                deduped.append(entry)
                continue
            }
            let key = ExactKey(messageID: messageID, requestID: entry.requestID)
            let collision = exactIndex[key] ?? messageIndex[messageID]?.first(where: { index in
                entry.isSidechain || deduped[index].isSidechain
            })

            if let index = collision {
                if shouldReplace(candidate: entry, existing: deduped[index]) {
                    let old = deduped[index]
                    if let oldID = old.messageID {
                        exactIndex.removeValue(forKey: ExactKey(messageID: oldID, requestID: old.requestID))
                    }
                    deduped[index] = entry
                    exactIndex[key] = index
                }
                continue
            }

            let index = deduped.count
            deduped.append(entry)
            exactIndex[key] = index
            messageIndex[messageID, default: []].append(index)
        }
        return deduped
    }

    /// 중복 시 선호 순서 — 정상 숫자, non-sidechain(parent), 큰 토큰 합계, `speed` 필드 보유 순.
    static func shouldReplace(candidate: Entry, existing: Entry) -> Bool {
        if candidate.invalidNumericValues != existing.invalidNumericValues {
            return existing.invalidNumericValues
        }
        if candidate.isSidechain != existing.isSidechain {
            return existing.isSidechain
        }
        let candidateTotal = candidate.tokens.totalTokens
        let existingTotal = existing.tokens.totalTokens
        if candidateTotal != existingTotal {
            return candidateTotal > existingTotal
        }
        return candidate.hasSpeed && !existing.hasSpeed
    }

    // MARK: - Aggregation

    /// dedup된 entry의 로컬 달력 일자 집계. cost mode "auto": 라인의 `costUSD` 우선, 없으면 `pricing` 추정.
    /// 가격을 계산할 수 없는 기록도 토큰 유지. 불완전한 날짜·기간 비용은 생략.
    static func aggregate(entries: [Entry], since: Date, pricing: ModelPricing) -> LogUsageScan {
        var accumulator = DailyUsageAccumulator()
        var rejectedNumericRows = 0
        var unsupportedPricingRows = 0

        for entry in entries where entry.timestamp >= since {
            guard !entry.invalidNumericValues else {
                rejectedNumericRows += 1
                continue
            }
            let day = DailyUsageAccumulator.dayKey(from: entry.timestamp)
            // 가격 조회·미확정 모델 목록·모델 내역에 같은 정규화 이름 사용.
            let trimmedModel = entry.model?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let modelName = trimmedModel ?? ModelUsageEntry.unattributedModelName

            let cost: Double?
            if let carried = entry.costUSD {
                cost = carried
            } else if let model = trimmedModel, let estimated = pricing.estimatedCostDollars(model: model, tokens: entry.tokens) {
                cost = estimated
            } else {
                if let model = trimmedModel, entry.tokens.totalTokens > 0 {
                    accumulator.addUnknownModel(day: day, model: model)
                }
                if entry.tokens.totalTokens > 0 { unsupportedPricingRows += 1 }
                cost = nil
            }

            accumulator.add(day: day, tokens: entry.tokens.totalTokens, cost: cost, model: modelName)
        }

        if unsupportedPricingRows > 0 {
            AppDiagnostics.record(.historyScan, result: .degraded, category: .other, providerID: "claude",
                                  localContext: "Claude usage costs are unavailable because model pricing is unresolved")
        }
        return accumulator.build(
            rejectedNumericRows: rejectedNumericRows, source: "claude", unsupportedPricingRows: unsupportedPricingRows
        )
    }
}
