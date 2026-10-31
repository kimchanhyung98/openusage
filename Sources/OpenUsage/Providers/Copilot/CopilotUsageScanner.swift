import Foundation

enum CopilotHistoryError: Error, LocalizedError, CategorizedError, UserPresentableError {
    case databaseUnreadable
    case malformedData

    var errorDescription: String? {
        "Couldn't read Copilot CLI usage history. Update Copilot CLI or check the local database permissions."
    }

    var errorCategory: ErrorCategory {
        switch self {
        case .databaseUnreadable: .storage
        case .malformedData: .decoding
        }
    }

    var presentationMessage: LocalizedMessage {
        .init(errorDescription!)
    }
}

/// Copilot CLI 요청별 사용 이력의 읽기 전용 스캔. 로그인 계정과 무관한 이 Mac의 패밀리 합계.
struct CopilotUsageScanner: Sendable {
    var sqlite: SQLiteAccessing
    var databasePath: @Sendable () -> String?
    private let readFailureReporter: UsageLogReadFailureReporter

    init(
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(),
        databasePath: @escaping @Sendable () -> String? = CopilotUsageScanner.defaultDatabasePath
    ) {
        self.sqlite = sqlite
        self.databasePath = databasePath
        self.readFailureReporter = UsageLogReadFailureReporter(logTag: LogTag.plugin("copilot"))
    }

    static let defaultDatabasePath: @Sendable () -> String? = {
        let path = resolvedDatabasePath(
            environment: ProcessInfo.processInfo.environment,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        do {
            _ = try FileManager.default.attributesOfItem(atPath: path)
            return path
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            // 접근 실패도 흔적 유지. 실제 스캔에서 읽기 오류를 노출.
            return path
        }
    }

    static func resolvedDatabasePath(environment: [String: String], homeDirectory: URL) -> String {
        let configured = environment["COPILOT_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let directory: URL
        if let configured, !configured.isEmpty {
            directory = URL(fileURLWithPath: (configured as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            directory = homeDirectory.appendingPathComponent(".copilot", isDirectory: true)
        }
        return directory.appendingPathComponent("session-store.db").path
    }

    func hasLocalUsageStore() -> Bool {
        databasePath() != nil
    }

    /// 정상 빈 DB는 빈 이력, 부재는 nil, 존재하는 DB의 읽기·스키마 실패는 오류로 구분.
    func scan(now: Date) async throws -> LogUsageScan? {
        try Task.checkCancellation()
        guard let path = databasePath() else { return nil }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let since = calendar.date(byAdding: .day, value: -UsageHistoryWindow.previousDays, to: today)!

        do {
            guard let json = try sqlite.queryValue(path: path, sql: Self.dataSQL(since: since)) else {
                throw CopilotHistoryError.databaseUnreadable
            }
            try Task.checkCancellation()
            let scan = try Self.aggregate(json: json, now: now, calendar: calendar)
            await readFailureReporter.update(checkedPaths: [path], failingPaths: [])
            return scan
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let newlyFailing = await readFailureReporter.update(checkedPaths: [path], failingPaths: [path])
            if !newlyFailing.isEmpty {
                AppLog.warn(LogTag.plugin("copilot"), "local usage history read failed: \(error.localizedDescription)")
            }
            throw (error as? CopilotHistoryError) ?? .databaseUnreadable
        }
    }

    /// SQL이 만든 행 배열만 해석. NULL 비용은 미지원 기록이며 0달러로 대체하지 않음.
    static func aggregate(json: String, now: Date, calendar: Calendar = .current) throws -> LogUsageScan {
        guard let data = json.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[Any]]
        else { throw CopilotHistoryError.malformedData }

        let days = UsageHistoryWindow.dayKeys(through: now, calendar: calendar)
        var accumulator = DailyUsageAccumulator()
        var unsupportedPricingRows = 0
        var rejectedMetadataRows = 0
        for row in rows {
            try Task.checkCancellation()
            guard row.count == 5 else { throw CopilotHistoryError.malformedData }
            guard let rawDate = row[0] as? String,
                  let timestamp = OpenUsageISO8601.date(from: rawDate)
            else {
                rejectedMetadataRows += 1
                continue
            }
            let day = DailyUsageAccumulator.dayKey(from: timestamp, calendar: calendar)
            guard timestamp <= now, days.contains(day) else { continue }
            guard let model = row[1] as? String else {
                rejectedMetadataRows += 1
                continue
            }
            guard let input = UsageLogNumbers.count(row[2]),
                  let output = UsageLogNumbers.count(row[3]),
                  let tokens = UsageLogNumbers.sum(input, output)
            else {
                accumulator.rejectNumericRow()
                continue
            }
            guard !(row[4] is NSNull) else {
                unsupportedPricingRows += 1
                continue
            }
            guard let nanoAIU = UsageLogNumbers.count(row[4]) else {
                accumulator.rejectNumericRow()
                continue
            }
            // 입력에는 캐시, 출력에는 추론 토큰 포함. 10억 nano AIU = 1 AI 크레딧 = 0.01달러.
            let cost = Double(nanoAIU) / 100_000_000_000
            let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
            accumulator.add(
                day: day, tokens: tokens, cost: cost,
                model: name.isEmpty ? ModelUsageEntry.unattributedModelName : name
            )
        }
        if unsupportedPricingRows > 0 {
            AppDiagnostics.record(
                .historyScan, result: .degraded, category: .decoding, providerID: "copilot",
                localContext: "source=copilot; unsupported_pricing_rows=\(unsupportedPricingRows)"
            )
        }
        if rejectedMetadataRows > 0 {
            AppDiagnostics.record(
                .historyScan, result: .degraded, category: .decoding, providerID: "copilot",
                localContext: "source=copilot; invalid_metadata_rows=\(rejectedMetadataRows)"
            )
        }
        return accumulator.build(
            source: "copilot", unsupportedPricingRows: unsupportedPricingRows,
            rejectedMetadataRows: rejectedMetadataRows
        )
    }

    static func dataSQL(since: Date) -> String {
        """
        BEGIN;
        SELECT json_group_array(json_array(
            created_at, model, input_tokens, output_tokens, total_nano_aiu
        ))
        FROM assistant_usage_events
        WHERE julianday(created_at) >= julianday(\(since.timeIntervalSince1970), 'unixepoch')
           OR julianday(created_at) IS NULL;
        COMMIT;
        """
    }
}
