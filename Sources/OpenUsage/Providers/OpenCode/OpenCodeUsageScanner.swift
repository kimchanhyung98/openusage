import Foundation

/// 로컬 OpenCode scan 결과 — hosted 합산 daily series(spend tile + trend용)와 Go 전용 plan window(meter용).
/// `opencode-go` 흔적이 전혀 없으면 `goWindows`는 `nil` — Zen 전용 사용자는 빈 cap 없이 spend tile만 표시.
struct OpenCodeUsageScan: Sendable {
    var logScan: LogUsageScan
    var goWindows: OpenCodeGoWindows?
}

/// OpenCode 로컬 SQLite 로그(`opencode*.db`, 전체 release channel)에서 provider가 렌더링할 usage 생성.
/// OpenCode가 기록한 비용을 재가격 없이 합산. 원본의 카탈로그 추정 비용도 포함 가능.
/// nonisolated async `Sendable` struct — `@MainActor` provider가 `await`하면 SQLite 읽기는 main actor 밖에서 수행.
struct OpenCodeUsageScanner: Sendable {
    /// 추적 대상 OpenCode-hosted providerID — Go 구독과 Zen pay-as-you-go gateway.
    /// BYO-key provider는 OpenCode 호스팅 사용량 범위에서 제외.
    static let hostedProviderIDs = ["opencode-go", "opencode"]
    static let goProviderID = "opencode-go"

    var sqlite: SQLiteAccessing
    var databasePaths: @Sendable () throws -> [String]
    private let readFailureReporter: UsageLogReadFailureReporter

    init(
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(),
        databasePaths: @escaping @Sendable () throws -> [String] = OpenCodeUsageScanner.defaultDatabasePaths,
        readFailureWarning: UsageLogReadFailureReporter.Warning? = nil
    ) {
        self.sqlite = sqlite
        self.databasePaths = databasePaths
        self.readFailureReporter = UsageLogReadFailureReporter(
            logTag: LogTag.plugin("opencode"),
            warning: readFailureWarning
        )
    }

    static let defaultDatabasePaths: @Sendable () throws -> [String] = {
        try OpenCodePaths.databaseFiles(
            environment: ProcessEnvironmentReader(),
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
    }

    /// 최근 `daysBack`일 scan — database가 전혀 없을 때만 `nil`("No data" 표시), 있으나 비어 있으면 빈 scan.
    /// database가 존재하는데 하나도 못 읽으면 `databaseUnreadable` throw — 전부 실패한 refresh를 0 사용량으로 렌더링 금지.
    /// 기본 33일은 가장 넓은 meter window(anchored month)+여유분 — tile/trend는 아래에서 31일로 재제한.
    func scan(now: Date, daysBack: Int = 33, hasGoKey: Bool = false) async throws -> OpenCodeUsageScan? {
        let directoryMarker = "<data directory>"
        let paths: [String]
        do {
            paths = try databasePaths()
        } catch {
            // data directory가 존재하나 열거 불가 — 읽기 불가 database와 동일 실패군, reporter edge-log로 반복 spam 방지
            let newlyFailing = await readFailureReporter.update(
                checkedPaths: [directoryMarker], failingPaths: [directoryMarker]
            )
            if !newlyFailing.isEmpty {
                AppLog.warn(LogTag.plugin("opencode"), "data directory unreadable: \(error.localizedDescription)")
            }
            throw OpenCodeUsageError.databaseUnreadable
        }
        guard !paths.isEmpty else {
            await readFailureReporter.update(checkedPaths: [], failingPaths: [])
            return nil
        }

        let cutoffMs = Int((now.timeIntervalSince1970 - Double(daysBack) * 86_400) * 1000)
        var rows: [Row] = []
        var anchorMs: Double?
        var checked: Set<String> = []
        var failures: [String: String] = [:]
        var rejectedNumericRows = 0

        for path in paths {
            try Task.checkCancellation()
            checked.insert(path)
            do {
                let hasParts = try sqlite.queryValue(path: path, sql: Self.partsProbeSQL) == "part"
                // 집계 조회 성공은 빈 DB도 "[]" 반환 — nil은 발견 후 사라진 DB 등 읽기 불가 상태.
                guard let json = try sqlite.queryValue(path: path, sql: Self.dataSQL(cutoffMs: cutoffMs, hasParts: hasParts)) else {
                    throw OpenCodeUsageError.databaseUnreadable
                }
                let parsed = try Self.parseRows(json)
                rows.append(contentsOf: parsed.rows)
                rejectedNumericRows += parsed.rejectedNumericRows
            } catch {
                if error is CancellationError { throw error }
                failures[path] = error.localizedDescription
                continue
            }
            // monthly cycle anchor는 최초 로컬 Go 사용 시각(무제한 조회라 day-window cutoff와 무관) — best-effort, 실패 시 calendar month fallback
            if let text = (try? sqlite.queryValue(path: path, sql: Self.anchorSQL)) ?? nil,
               let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                anchorMs = Swift.min(anchorMs ?? value, value)
            }
        }
        // 경로별 상세는 새로 실패한 경로만 로그(reporter edge-trigger) — 계속 잠긴 database는 5분마다가 아닌 1회만 경고
        let newlyFailing = await readFailureReporter.update(
            checkedPaths: checked.union([directoryMarker]), failingPaths: Set(failures.keys)
        )
        for path in newlyFailing.sorted() {
            AppLog.warn(LogTag.plugin("opencode"), "usage query failed for \(path): \(failures[path] ?? "unknown error")")
        }
        if failures.count == checked.count {
            throw OpenCodeUsageError.databaseUnreadable
        }

        // 지출 타일·현재 Go 기간에 기여하는 기록 비용만 합산. scan 여유분의 과거 행은 숫자 한도에서 제외.
        let tileSince = JSONLScanning.sinceDate(daysBack: 30, now: now)
        let goRange = OpenCodeGoWindowMath.activeRange(anchorMs: anchorMs, now: now)
        var accumulator = DailyUsageAccumulator()
        var totalCost = 0.0
        var totalTokens = 0
        var goCosts: [(ms: Double, cost: Double)] = []
        for row in rows {
            try Task.checkCancellation()
            let date = Date(timeIntervalSince1970: row.ms / 1000)
            guard date >= tileSince || (row.providerID == Self.goProviderID && goRange.contains(row.ms)) else {
                continue
            }
            // 타일보다 넓은 monthly window까지 같은 유한 비용 집합 사용. 거부한 행은 meter에서도 제외.
            let nextCost = totalCost + row.cost
            let nextTokens = totalTokens.addingReportingOverflow(date >= tileSince ? row.tokens : 0)
            guard nextCost.isFinite, !nextTokens.overflow else {
                accumulator.rejectNumericRow()
                continue
            }
            totalCost = nextCost
            totalTokens = nextTokens.partialValue
            if row.providerID == Self.goProviderID {
                goCosts.append((ms: row.ms, cost: row.cost))
            }
            guard date >= tileSince else { continue }
            accumulator.add(
                day: DailyUsageAccumulator.dayKey(from: date),
                tokens: row.tokens, cost: row.cost, model: row.model
            )
        }
        UsageLogNumbers.reportRejectedRows(rejectedNumericRows, source: "opencode")
        let logScan = accumulator.build(
            rejectedNumericRows: rejectedNumericRows, source: "opencode", readFailureCount: failures.count
        )

        // Go 전용 window → Session/Weekly/Monthly cap, 현재 Go 신호(`hasGoKey` 또는 window 내 Go spend)일 때만 표시
        // 과거 사용의 stale anchor가 해지·Zen 전용 사용자에게 cap이나 "Go" plan을 되살리면 안 됨 — anchor는 monthly cycle 경계 설정에만 사용
        let goWindows: OpenCodeGoWindows? = (hasGoKey || !goCosts.isEmpty)
            ? OpenCodeGoWindowMath.compute(costs: goCosts, anchorMs: anchorMs, now: now)
            : nil

        return OpenCodeUsageScan(logScan: logScan, goWindows: goWindows)
    }

    /// `hasLocalCredentials()`용 저비용 로컬 probe — 추적 database에 numeric cost의 hosted assistant 행 존재 여부 확인.
    /// read-only·network 없음. first-run/new-provider 감지에서만 실행되므로 실패는 throttle 없이 로그.
    /// 읽기 불가 data directory도 OpenCode 흔적으로 취급 — `refresh()`가 실제 에러를 노출하게 함.
    func hasHostedUsage() -> Bool {
        let paths: [String]
        do {
            paths = try databasePaths()
        } catch {
            AppLog.warn(LogTag.plugin("opencode"), "usage probe: data directory unreadable: \(error.localizedDescription)")
            return true
        }
        for path in paths {
            do {
                if let value = try sqlite.queryValue(path: path, sql: Self.probeSQL), !value.isEmpty {
                    return true
                }
            } catch {
                AppLog.warn(LogTag.plugin("opencode"), "usage probe failed for \(path): \(error.localizedDescription)")
            }
        }
        return false
    }

    // MARK: - Parsing

    private struct Row {
        var ms: Double
        var cost: Double
        var tokens: Int
        var model: String
        var providerID: String
    }

    /// SQL이 투영한 시각·비용·토큰·모델·provider·비용 JSON type 검증.
    private static func parseRows(_ json: String) throws -> (rows: [Row], rejectedNumericRows: Int) {
        guard let data = json.data(using: .utf8),
              let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        else { throw OpenCodeUsageError.databaseUnreadable }

        var rows: [Row] = []
        var rejectedNumericRows = 0
        rows.reserveCapacity(parsed.count)
        for element in parsed {
            try Task.checkCancellation()
            guard let entry = element as? [Any], entry.count >= 5,
                  let ms = ProviderParse.number(entry[0]),
                  let providerID = entry[4] as? String
            else { continue }
            guard let cost = ProviderParse.number(entry[1]), cost >= 0,
                  entry.count < 6 || ["integer", "real"].contains(entry[5] as? String ?? ""),
                  let tokens = totalTokens(entry[2]) else {
                rejectedNumericRows += 1
                continue
            }
            let model = (entry[3] as? String) ?? ""
            rows.append(Row(
                ms: ms,
                cost: cost,
                tokens: tokens,
                model: model,
                providerID: providerID
            ))
        }
        return (rows, rejectedNumericRows)
    }

    private static func totalTokens(_ value: Any) -> Int? {
        guard let tokens = value as? [String: Any] else { return nil }
        let cache: [String: Any]
        if let value = tokens["cache"] {
            guard let object = value as? [String: Any] else { return nil }
            cache = object
        } else {
            cache = [:]
        }
        guard let input = UsageLogNumbers.count(tokens["input"], missing: 0),
              let output = UsageLogNumbers.count(tokens["output"], missing: 0),
              let reasoning = UsageLogNumbers.count(tokens["reasoning"], missing: 0),
              let read = UsageLogNumbers.count(cache["read"], missing: 0),
              let write = UsageLogNumbers.count(cache["write"], missing: 0),
              let sum = UsageLogNumbers.sum(input, output, reasoning, read, write) else { return nil }
        return UsageLogNumbers.count(tokens["total"], missing: sum)
    }

    // MARK: - SQL

    /// `hostedProviderIDs`로 만든 SQL literal — 추적 목록의 단일 source of truth 유지.
    private static let providerFilter = "(" + hostedProviderIDs.map { "'\($0)'" }.joined(separator: ",") + ")"

    private static let partsProbeSQL = "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'part' LIMIT 1;"

    static func dataSQL(cutoffMs: Int, hasParts: Bool = false) -> String {
        let usageQuery = hasParts ? """
            SELECT r.time_created, p.data AS usage_data, r.data AS message_data
            FROM retained r JOIN part p ON p.message_id = r.id AND p.session_id = r.session_id
            WHERE json_valid(p.data) AND json_extract(p.data,'$.type') = 'step-finish'
            UNION ALL
            SELECT r.time_created, r.data AS usage_data, r.data AS message_data
            FROM retained r
            WHERE NOT EXISTS (
                SELECT 1 FROM part p
                WHERE p.message_id = r.id AND p.session_id = r.session_id
                  AND json_valid(p.data) AND json_extract(p.data,'$.type') = 'step-finish'
            )
            """ : "SELECT time_created, data AS usage_data, data AS message_data FROM retained"
        // 세션 내 동일 기록의 순번으로 fork 사본을 대응. 완료 상태 변경과 원본 삭제 후에도 소비 건수 보존.
        return """
        WITH hosted AS (
            SELECT m.id, m.session_id, m.time_created, m.data, s.project_id,
                   CASE WHEN m.time_created < s.time_created THEN 1 ELSE 0 END AS inherited,
                   json_remove(m.data,'$.id','$.sessionID','$.parentID',
                               '$.time.completed','$.finish','$.error','$.structured') AS fingerprint
            FROM message m LEFT JOIN session s ON s.id = m.session_id
            WHERE m.time_created >= \(cutoffMs)
              AND json_valid(m.data)
              AND json_extract(m.data,'$.role') = 'assistant'
              AND json_extract(m.data,'$.providerID') IN \(providerFilter)
              AND json_type(m.data,'$.cost') IN ('integer','real')
        ), numbered AS (
            SELECT *, ROW_NUMBER() OVER (
                PARTITION BY project_id, time_created, fingerprint, session_id ORDER BY id
            ) AS message_rank
            FROM hosted
        ), ranked AS (
            SELECT *,
                   MIN(inherited) OVER (PARTITION BY project_id, time_created, fingerprint, message_rank) AS only_copies,
                   ROW_NUMBER() OVER (PARTITION BY project_id, time_created, fingerprint, message_rank ORDER BY id) AS copy_rank
            FROM numbered
        ), retained AS (
            SELECT * FROM ranked
            WHERE inherited = 0 OR (only_copies = 1 AND copy_rank = 1)
        ), usage AS (
            \(usageQuery)
        )
        SELECT json_group_array(json_array(
                 time_created,
                 json_extract(usage_data,'$.cost'),
                 json_extract(usage_data,'$.tokens'),
                 json_extract(message_data,'$.modelID'),
                 json_extract(message_data,'$.providerID'),
                 json_type(usage_data,'$.cost')))
        FROM usage;
        """
    }

    static let anchorSQL = """
        SELECT MIN(time_created) FROM message
        WHERE json_valid(data)
          AND json_extract(data,'$.role') = 'assistant'
          AND json_extract(data,'$.providerID') = '\(goProviderID)'
          AND json_type(data,'$.cost') IN ('integer','real');
        """

    static let probeSQL = """
        SELECT 1 FROM message
        WHERE json_valid(data)
          AND json_extract(data,'$.role') = 'assistant'
          AND json_extract(data,'$.providerID') IN \(providerFilter)
          AND json_type(data,'$.cost') IN ('integer','real')
        LIMIT 1;
        """
}
