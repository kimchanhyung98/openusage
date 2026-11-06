import Foundation

/// 기록 타입과 무관한 JSONL 파일 탐색과 조회 기간 계산.
enum JSONLScanning {
    /// 빈 행을 생략하고 마지막 무개행 행까지 순차 제공 — 전체 행 배열과 Swift 바이트별 순회 생략.
    static func lines(in data: Data) -> some Sequence<Data> {
        let newline = Data([0x0A])
        return sequence(state: data.startIndex) { start in
            while start < data.endIndex {
                let end = data.range(of: newline, in: start..<data.endIndex)?.lowerBound ?? data.endIndex
                let lower = start
                start = end < data.endIndex ? end + 1 : data.endIndex
                if lower < end { return data[lower..<end] }
            }
            return nil
        }
    }

    /// 발견한 로그 경로와 파싱 캐시 검증용 파일 정보.
    struct DiscoveredFile: Sendable {
        var path: String
        var size: Int
        var mtime: Date
    }

    /// 현재 날짜에서 `daysBack`일 전 자정을 조회 시작 시각으로 사용.
    static func sinceDate(daysBack: Int, now: Date) -> Date {
        let shifted = Calendar.current.date(byAdding: .day, value: -daysBack, to: now) ?? now
        return Calendar.current.startOfDay(for: shifted)
    }

    /// 하위 JSONL 파일을 경로순으로 탐색. 탐색 실패 시 빈 배열 반환.
    static func jsonlFiles(under dir: URL) -> [DiscoveredFile] {
        // 심볼릭 링크 루트도 열거할 수 있도록 실제 경로로 변환.
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

