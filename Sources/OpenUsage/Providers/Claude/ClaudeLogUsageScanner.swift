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
        /// 모델 없음 또는 placeholder `<synthetic>`이면 `nil`(토큰은 집계, 비용 $0).
        var model: String?
    }

    /// 같은 Claude home을 읽는 카드들의 공유 actor — 첫 스캔이 캐시를 채우고 나머지는 재사용.
    /// 테스트는 격리된 메모리 전용 scanner 주입.
    private static let sharedScanner = IncrementalJSONLScanner<Entry>(
        logTag: LogTag.plugin("claude"),
        persistence: JSONLScanCachePersistence(namespace: "claude", schemaVersion: 1)
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
        guard !roots.isEmpty else {
            _ = await scanner.items(
                from: [], since: since, cacheIdentity: cacheIdentity, parse: Self.parseFile
            )
            return nil
        }

        let files = Self.usageFiles(under: roots)
        guard !files.isEmpty else {
            _ = await scanner.items(
                from: [], since: since, cacheIdentity: cacheIdentity, parse: Self.parseFile
            )
            return nil
        }

        // entry는 경로 정렬 파일 순서로 연결 — dedup keep-first의 결정성 보장.
        guard let entries = await scanner.items(
            from: files,
            since: since,
            cacheIdentity: cacheIdentity,
            parse: Self.parseFile
        ), !Task.isCancelled else { return nil }
        return Self.aggregate(entries: Self.dedup(entries), since: since, pricing: pricing)
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
            configuredRoots = raw.split(separator: ",").compactMap { part in
                let value = part.trimmingCharacters(in: .whitespaces)
                guard !value.isEmpty else { return nil }
                var url = URL(fileURLWithPath: expandHome(value))
                if url.lastPathComponent == "projects" { url.deleteLastPathComponent() }
                return url
            }
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

    /// `projects/`를 실제 포함한 Claude config dir 목록(ccusage 순서) — `CLAUDE_CONFIG_DIR` 우선,
    /// 없으면 `$XDG_CONFIG_HOME/claude`·`~/.claude`; Cowork 세션 sandbox는 항상 추가.
    private func claudeRoots() -> [URL] {
        var roots: [URL] = []
        var seen: Set<String> = []

        func addIfValid(_ url: URL) {
            guard FileManager.default.fileExists(atPath: url.appendingPathComponent("projects").path),
                  seen.insert(url.path).inserted
            else { return }
            roots.append(url)
        }

        // scoped 카드는 자기 config dir만 스캔 — env 해석·Cowork walk 없음(sandbox는 기본 로그인 소속).
        if let rootsOverride {
            for root in rootsOverride { addIfValid(root) }
            return roots
        }

        if !pinsSharedHome,
           let raw = environment.value(for: "CLAUDE_CONFIG_DIR")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            for part in raw.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
                var url = URL(fileURLWithPath: expandHome(part))
                // `projects/` dir 자체를 상위 config dir의 alias로 수용.
                if url.lastPathComponent == "projects", FileManager.default.fileExists(atPath: url.path) {
                    url.deleteLastPathComponent()
                }
                addIfValid(url)
            }
            if roots.isEmpty {
                AppLog.warn(LogTag.plugin("claude"), "CLAUDE_CONFIG_DIR is set but contains no Claude data directory with projects/: \(raw)")
            }
        } else {
            let home = homeDirectory()
            let xdg = environment.value(for: "XDG_CONFIG_HOME")?.nilIfEmpty.map { URL(fileURLWithPath: expandHome($0)) }
                ?? home.appendingPathComponent(".config")
            addIfValid(xdg.appendingPathComponent("claude"))
            addIfValid(home.appendingPathComponent(".claude"))
        }

        for sandbox in Self.coworkClaudeDirs(home: homeDirectory()) {
            addIfValid(sandbox)
        }
        // 같은 계정 커스텀 config dir(기본 카드 전용) — side home의 자기 spend.
        for root in additionalRoots {
            addIfValid(root)
        }
        return roots
    }

    /// Cowork(desktop agent mode)가 세션마다 만드는 `.claude` dir — `~/.claude`와 같은 세션 로그 보유.
    /// walk는 알려진 level로 한정 — 세션 dir 내부의 전체 sandbox home 재귀 금지.
    private static func coworkClaudeDirs(home: URL) -> [URL] {
        let base = home
            .appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions")

        func subdirectories(of url: URL) -> [URL] {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            )) ?? []
            return contents.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
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
        return dirs.sorted { $0.path < $1.path }
    }

    /// 각 root `projects/` 하위의 `*.jsonl` 전부, 경로 정렬 — dedup keep-first 결정성(ccusage와 동일 순서).
    private static func usageFiles(under roots: [URL]) -> [JSONLScanning.DiscoveredFile] {
        roots
            .flatMap { JSONLScanning.jsonlFiles(under: $0.appendingPathComponent("projects")) }
            .sorted { $0.path < $1.path }
    }

    // MARK: - Line parsing

    /// 세션 파일 1개의 모든 usage 라인 파싱 — 날짜 window는 집계 시 적용, window 이동에도 캐시된 파싱 유효.
    static func parseFile(_ data: Data) -> [Entry] {
        let marker = Data(#""usage":{"#.utf8)
        var entries: [Entry] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard line.range(of: marker) != nil else { continue }
            if hasUnsupportedNullField(line) { continue }
            entries.append(contentsOf: parseEntries(Data(line)))
        }
        return entries
    }

    /// JSONL 라인 1개를 `Entry`로 디코드 — ccusage serde 수용 범위와 동일, 손상 라인은 파일 실패 대신 skip.
    static func parseLine(_ data: Data) -> Entry? {
        parseEntries(data).first
    }

    /// top-level usage는 main-model entry 유지, `usage.iterations`의 advisor-message만 별도 entry —
    /// ccusage와 동일, 일반 iteration 재집계 금지.
    private static func parseEntries(_ data: Data) -> [Entry] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let timestampRaw = object["timestamp"] as? String,
              let timestamp = OpenUsageISO8601.date(from: timestampRaw),
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let parsedUsage = tokenBreakdown(from: usage),
              isValidEntry(object, message: message)
        else { return [] }

        let model = (message["model"] as? String).flatMap { $0 == "<synthetic>" ? nil : $0 }
        let parent = Entry(
            timestamp: timestamp,
            tokens: parsedUsage.tokens,
            messageID: message["id"] as? String,
            requestID: object["requestId"] as? String,
            isSidechain: object["isSidechain"] as? Bool ?? false,
            hasSpeed: parsedUsage.hasSpeed,
            costUSD: (object["costUSD"] as? NSNumber)?.doubleValue,
            model: model
        )

        guard let iterations = usage["iterations"] as? [[String: Any]] else { return [parent] }

        var entries = [parent]
        var advisorIndex = 0
        for iteration in iterations {
            guard iteration["type"] as? String == "advisor_message",
                  let advisorModel = iteration["model"] as? String,
                  !advisorModel.isEmpty,
                  let advisorUsage = tokenBreakdown(from: iteration)
            else { continue }

            entries.append(Entry(
                timestamp: parent.timestamp,
                tokens: advisorUsage.tokens,
                messageID: parent.messageID.map { "\($0):advisor:\(advisorIndex)" },
                requestID: parent.requestID,
                isSidechain: parent.isSidechain,
                hasSpeed: advisorUsage.hasSpeed,
                costUSD: nil,
                model: advisorModel
            ))
            advisorIndex += 1
        }
        return entries
    }

    private static func tokenBreakdown(
        from usage: [String: Any]
    ) -> (tokens: TokenBreakdown, hasSpeed: Bool)? {
        guard let input = usage["input_tokens"] as? NSNumber,
              let output = usage["output_tokens"] as? NSNumber
        else { return nil }

        // 알 수 없는 `speed` 값은 미지의 로그 형태 — 라인 skip(ccusage enum 파싱과 동일).
        let speed = usage["speed"] as? String
        if let speed, speed != "fast", speed != "standard" { return nil }

        // cache write: 5m/1h 분리값 우선(1h는 input 2x 과금), 없으면 legacy 합계를 전량 5m 처리.
        var cacheWrite5m = 0
        var cacheWrite1h = 0
        if let cacheCreation = usage["cache_creation"] as? [String: Any] {
            cacheWrite5m = (cacheCreation["ephemeral_5m_input_tokens"] as? NSNumber)?.intValue ?? 0
            cacheWrite1h = (cacheCreation["ephemeral_1h_input_tokens"] as? NSNumber)?.intValue ?? 0
        } else {
            cacheWrite5m = (usage["cache_creation_input_tokens"] as? NSNumber)?.intValue ?? 0
        }

        return (TokenBreakdown(
            input: input.intValue,
            cacheWrite5m: cacheWrite5m,
            cacheWrite1h: cacheWrite1h,
            cacheRead: (usage["cache_read_input_tokens"] as? NSNumber)?.intValue ?? 0,
            output: output.intValue,
            isFast: speed == "fast"
        ), speed != nil)
    }

    /// ccusage 유효성 규칙 — semver 아닌 `version`은 외부 로그 형식, 비어 있는 id/model은 손상 라인.
    private static func isValidEntry(_ object: [String: Any], message: [String: Any]) -> Bool {
        if let version = object["version"] as? String, !isSemverPrefix(version) { return false }
        for value in [object["sessionId"], object["requestId"], message["id"], message["model"]] {
            if let text = value as? String, text.isEmpty { return false }
        }
        return true
    }

    /// `digits.digits.digit…` 형태 — "1.0.24"·pre-release suffix 수용, "unknown" 등 거부.
    static func isSemverPrefix(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        var index = 0
        func digits() -> Bool {
            let start = index
            while index < bytes.count, bytes[index].isASCIIDigit { index += 1 }
            return index > start
        }
        guard digits(), index < bytes.count, bytes[index] == UInt8(ascii: ".") else { return false }
        index += 1
        guard digits(), index < bytes.count, bytes[index] == UInt8(ascii: ".") else { return false }
        index += 1
        return index < bytes.count && bytes[index].isASCIIDigit
    }

    /// Claude가 `null`을 쓰지 않는 필드에 null이 있으면 외부/손상 로그 — ccusage와 byte 단위 동일 기준으로 skip.
    static func hasUnsupportedNullField(_ line: Data.SubSequence) -> Bool {
        let nullMarker = Data(":null".utf8)
        let quote = UInt8(ascii: "\"")
        let bytes = Data(line) // 새 복사본 — 인덱스 0 기준
        var offset = bytes.startIndex
        while let markerRange = bytes.range(of: nullMarker, in: offset..<bytes.endIndex) {
            let start = markerRange.lowerBound
            var fieldEnd = start > 0 ? start - 1 : 0
            if bytes[fieldEnd] != quote {
                while fieldEnd > 0, bytes[fieldEnd] != quote { fieldEnd -= 1 }
            }
            if bytes[fieldEnd] == quote, fieldEnd > 0 {
                var fieldStart = fieldEnd - 1
                while fieldStart > 0, bytes[fieldStart] != quote { fieldStart -= 1 }
                if bytes[fieldStart] == quote {
                    let field = String(decoding: bytes[(fieldStart + 1)..<fieldEnd], as: UTF8.self)
                    if Self.unsupportedNullableFields.contains(field) { return true }
                }
            }
            offset = markerRange.upperBound
        }
        return false
    }

    private static let unsupportedNullableFields: Set<String> = [
        "id", "cwd", "model", "speed", "costUSD", "version", "sessionId", "requestId",
        "isApiErrorMessage", "cache_read_input_tokens", "cache_creation_input_tokens"
    ]

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

    /// 중복 시 선호 순서 — non-sidechain(parent), 큰 토큰 합계, `speed` 필드 보유 순.
    static func shouldReplace(candidate: Entry, existing: Entry) -> Bool {
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
    /// 가격 산정 불가 entry는 모든 표시 합계에서 제외 — unknown 모델명만 `unknownModelsByDay`(경고 삼각형)로 노출.
    static func aggregate(entries: [Entry], since: Date, pricing: ModelPricing) -> LogUsageScan {
        var accumulator = DailyUsageAccumulator()

        for entry in entries where entry.timestamp >= since {
            let day = DailyUsageAccumulator.dayKey(from: entry.timestamp)
            // pricing·unknown 경고·breakdown 키가 하나의 trimmed slug 공유 — 표기 분기 시 경고 삼각형과 hover 패널 불일치.
            let trimmedModel = entry.model?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let modelName = trimmedModel ?? ModelUsageEntry.unattributedModelName

            let cost: Double
            if let carried = entry.costUSD {
                cost = carried
            } else if let model = trimmedModel, let estimated = pricing.estimatedCostDollars(model: model, tokens: entry.tokens) {
                cost = estimated
            } else {
                if let model = trimmedModel, entry.tokens.totalTokens > 0 {
                    accumulator.addUnknownModel(day: day, model: model)
                }
                continue
            }

            accumulator.add(day: day, tokens: entry.tokens.totalTokens, cost: cost, model: modelName)
        }

        return accumulator.build()
    }
}

private extension UInt8 {
    var isASCIIDigit: Bool { self >= UInt8(ascii: "0") && self <= UInt8(ascii: "9") }
}
