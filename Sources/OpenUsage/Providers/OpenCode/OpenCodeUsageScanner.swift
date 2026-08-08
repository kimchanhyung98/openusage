import Foundation

/// 로컬 OpenCode scan 결과 — hosted 합산 daily series(spend tile + trend용)와 Go 전용 plan window(meter용).
/// `opencode-go` 흔적이 전혀 없으면 `goWindows`는 `nil` — Zen 전용 사용자는 빈 cap 없이 spend tile만 표시.
struct OpenCodeUsageScan: Sendable {
    var logScan: LogUsageScan
    var goWindows: OpenCodeGoWindows?
}

/// OpenCode 로컬 SQLite 로그(`opencode*.db`, 전체 release channel)에서 provider가 렌더링할 usage 생성.
/// hosted gateway의 메시지별 `cost`는 OpenCode가 기록한 확정값 — 재가격 없이 그대로 합산 (Zen model은 pricing snapshot에 없음).
/// nonisolated async `Sendable` struct — `@MainActor` provider가 `await`하면 SQLite 읽기는 main actor 밖에서 수행.
struct OpenCodeUsageScanner: Sendable {
    /// 추적 대상 OpenCode-hosted providerID — Go 구독과 Zen pay-as-you-go gateway.
    /// 둘 다 확정 `cost` 기록, 그 외 BYO-key providerID는 `cost: 0`이라 범위 밖.
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
        let dir = OpenCodePaths.dataDirectory(
            environment: ProcessEnvironmentReader(),
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        return try OpenCodePaths.databaseFiles(in: dir)
    }

    /// 최근 `daysBack`일 scan — database가 전혀 없을 때만 `nil`("No data" 표시), 있으나 비어 있으면 빈 scan.
    /// database가 존재하는데 하나도 못 읽으면 `databaseUnreadable` throw — 전부 실패한 refresh를 0 사용량으로 렌더링 금지.
    /// 기본 33일은 가장 넓은 meter window(anchored month)+여유분 — tile/trend는 아래에서 31일로 재제한.
    func scan(now: Date, daysBack: Int = 33, hasGoKey: Bool = false) async throws -> OpenCodeUsageScan? {
        let paths: [String]
        do {
            paths = try databasePaths()
        } catch {
            // data directory가 존재하나 열거 불가 — 읽기 불가 database와 동일 실패군, reporter edge-log로 반복 spam 방지
            let marker = "<data directory>"
            let newlyFailing = await readFailureReporter.update(checkedPaths: [marker], failingPaths: [marker])
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

        for path in paths {
            checked.insert(path)
            do {
                if let json = try sqlite.queryValue(path: path, sql: Self.dataSQL(cutoffMs: cutoffMs)) {
                    rows.append(contentsOf: Self.parseRows(json))
                }
            } catch {
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
        let newlyFailing = await readFailureReporter.update(checkedPaths: checked, failingPaths: Set(failures.keys))
        for path in newlyFailing.sorted() {
            AppLog.warn(LogTag.plugin("opencode"), "usage query failed for \(path): \(failures[path] ?? "unknown error")")
        }
        if failures.count == checked.count {
            throw OpenCodeUsageError.databaseUnreadable
        }

        // hosted 합산 daily series(opencode-go + opencode) → spend tile + usage trend, cost가 확정값이라 모든 행을 그대로 accumulator에 투입
        let tileSince = JSONLScanning.sinceDate(daysBack: 30, now: now)
        var accumulator = DailyUsageAccumulator()
        for row in rows {
            let date = Date(timeIntervalSince1970: row.ms / 1000)
            guard date >= tileSince else { continue }
            accumulator.add(
                day: DailyUsageAccumulator.dayKey(from: date),
                tokens: row.tokens, cost: row.cost, model: row.model
            )
        }
        let logScan = accumulator.build()

        // Go 전용 window → Session/Weekly/Monthly cap, 현재 Go 신호(`hasGoKey` 또는 window 내 Go spend)일 때만 표시
        // 과거 사용의 stale anchor가 해지·Zen 전용 사용자에게 cap이나 "Go" plan을 되살리면 안 됨 — anchor는 monthly cycle 경계 설정에만 사용
        let goCosts = rows
            .filter { $0.providerID == Self.goProviderID }
            .map { (ms: $0.ms, cost: $0.cost) }
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

    /// `json_group_array(json_array(...))` payload인 `[time_created, cost, tokensTotal, modelID, providerID]` 배열 parse.
    /// timestamp/cost 누락 또는 비문자열 providerID 행은 이 경계에서 skip.
    private static func parseRows(_ json: String) -> [Row] {
        guard let data = json.data(using: .utf8),
              let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        else { return [] }

        var rows: [Row] = []
        rows.reserveCapacity(parsed.count)
        for element in parsed {
            guard let entry = element as? [Any], entry.count >= 5,
                  let ms = ProviderParse.number(entry[0]),
                  let cost = ProviderParse.number(entry[1]), cost >= 0,
                  let providerID = entry[4] as? String
            else { continue }
            // Int 변환 전 clamp — 손상된 초대형 token 수의 trap 방지(Int.max 초과 Int(Double)은 crash), 1e15는 실제 총량을 크게 상회
            let tokens = Int(min(max(ProviderParse.number(entry[2]) ?? 0, 0), 1e15))
            let model = (entry[3] as? String) ?? ""
            rows.append(Row(
                ms: ms,
                cost: cost,
                tokens: tokens,
                model: model,
                providerID: providerID
            ))
        }
        return rows
    }

    // MARK: - SQL

    /// `hostedProviderIDs`로 만든 SQL literal — 추적 목록의 단일 source of truth 유지.
    private static let providerFilter = "(" + hostedProviderIDs.map { "'\($0)'" }.joined(separator: ",") + ")"

    static func dataSQL(cutoffMs: Int) -> String {
        """
        SELECT json_group_array(json_array(
                 time_created,
                 json_extract(data,'$.cost'),
                 COALESCE(json_extract(data,'$.tokens.total'),0),
                 json_extract(data,'$.modelID'),
                 json_extract(data,'$.providerID')))
        FROM message
        WHERE time_created >= \(cutoffMs)
          AND json_valid(data)
          AND json_extract(data,'$.role') = 'assistant'
          AND json_extract(data,'$.providerID') IN \(providerFilter)
          AND json_type(data,'$.cost') IN ('integer','real');
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
