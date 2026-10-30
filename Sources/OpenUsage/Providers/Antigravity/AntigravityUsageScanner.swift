import Foundation

/// 로컬 Antigravity 대화 기록을 일별 API 가격 상당 사용량으로 집계.
actor AntigravityUsageScanner {
    static let shared = AntigravityUsageScanner()

    private struct FileStamp: Equatable {
        var size: UInt64
        var modified: Date
        var inode: UInt64
    }

    private struct Signature: Equatable {
        var database: FileStamp
        var wal: FileStamp?
    }

    private struct CachedDatabase {
        var signature: Signature
        var since: Date
        var records: [AntigravityUsageRecord]
    }

    private let databasePaths: @Sendable () throws -> [String]
    private var cache: [String: CachedDatabase] = [:]

    init(databasePaths: @escaping @Sendable () throws -> [String] = AntigravityUsageScanner.defaultDatabasePaths) {
        self.databasePaths = databasePaths
    }

    static let defaultDatabasePaths: @Sendable () throws -> [String] = {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini")
        var paths: [String] = []
        for name in ["antigravity", "antigravity-cli", "antigravity-ide"] {
            let directory = root.appendingPathComponent(name).appendingPathComponent("conversations")
            do {
                paths += try FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil
                ).filter { $0.pathExtension == "db" }.map(\.path)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                continue
            }
        }
        return paths.sorted()
    }

    func scan(now: Date, pricing: ModelPricing) async throws -> LogUsageScan? {
        do {
            return try collect(now: now, pricing: pricing)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AntigravityUsageScanError.unreadable
        }
    }

    private func collect(now: Date, pricing: ModelPricing) throws -> LogUsageScan? {
        let paths = Set(try databasePaths().map {
            URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path
        }).sorted()
        cache = cache.filter { paths.contains($0.key) }
        let since = JSONLScanning.sinceDate(daysBack: 30, now: now)
        var foundDatabase = false
        var seen: Set<AntigravityUsageRecord.Identity> = []
        var accumulator = DailyUsageAccumulator()

        for path in paths {
            try Task.checkCancellation()
            guard let signature = try signature(path) else {
                cache.removeValue(forKey: path)
                continue
            }
            foundDatabase = true
            let records: [AntigravityUsageRecord]
            if let cached = cache[path], cached.signature == signature, cached.since <= since {
                records = cached.records
            } else {
                records = try AntigravityUsageDatabase(path: path).records(since: since)
                // 읽는 동안 기록 파일이 바뀌면 이번 일관된 스냅샷만 사용하고 다음 refresh에서 재조회.
                if try self.signature(path) == signature {
                    cache[path] = CachedDatabase(signature: signature, since: since, records: records)
                } else {
                    cache.removeValue(forKey: path)
                }
            }
            for record in records where record.date >= since {
                guard seen.insert(record.identity).inserted else { continue }
                let day = DailyUsageAccumulator.dayKey(from: record.date)
                if let cost = pricing.estimatedCostDollars(model: record.model, tokens: record.tokens, source: .api) {
                    accumulator.add(day: day, tokens: record.tokens.totalTokens, cost: cost, model: record.model)
                } else {
                    accumulator.addUnknownModel(day: day, model: record.model)
                }
            }
        }
        return foundDatabase ? accumulator.build(source: "antigravity") : nil
    }

    private func signature(_ path: String) throws -> Signature? {
        guard let database = try stamp(path) else { return nil }
        return Signature(database: database, wal: try stamp(path + "-wal"))
    }

    private func stamp(_ path: String) throws -> FileStamp? {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date,
              let inode = attributes[.systemFileNumber] as? NSNumber
        else { throw AntigravityUsageScanError.unreadable }
        return FileStamp(size: size.uint64Value, modified: modified, inode: inode.uint64Value)
    }
}

enum AntigravityUsageScanError: LocalizedError {
    case unreadable

    var errorDescription: String? {
        "Antigravity usage history could not be read. Try again later."
    }
}
