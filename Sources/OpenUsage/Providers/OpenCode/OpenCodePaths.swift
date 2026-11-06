import Foundation

/// OpenCode의 로컬 데이터 경로 해석 — auth store(`auth.json`)와 usage scanner(SQLite 로그)가 공유.
/// OpenUsage 전용 `OPENCODE_DATA_DIR` override가 없으면 OpenCode의 XDG data 경로 사용.
enum OpenCodePaths {
    static func dataDirectory(environment: EnvironmentReading, homeDirectory: URL) -> String {
        if let override = environment.value(for: "OPENCODE_DATA_DIR")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return expandedHome(override, homeDirectory: homeDirectory).trimmingTrailingSlashes
        }
        if let xdg = environment.value(for: "XDG_DATA_HOME")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return expandedHome(xdg, homeDirectory: homeDirectory).trimmingTrailingSlashes + "/opencode"
        }
        return homeDirectory.appendingPathComponent(".local/share/opencode").path
    }

    static func authFilePath(dataDirectory: String) -> String {
        dataDirectory.trimmingTrailingSlashes + "/auth.json"
    }

    static func databaseFiles(environment: EnvironmentReading, homeDirectory: URL) throws -> [String] {
        let directory = dataDirectory(environment: environment, homeDirectory: homeDirectory)
        guard let override = environment.value(for: "OPENCODE_DB")?.nilIfEmpty else {
            return try databaseFiles(in: directory)
        }
        guard override != ":memory:" else { return [] }
        let path = override.hasPrefix("/") ? override
            : URL(fileURLWithPath: directory).appendingPathComponent(override).path
        do {
            _ = try FileManager.default.attributesOfItem(atPath: path)
            return [path]
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
    }

    /// data dir의 모든 `opencode*.db` — release channel별 분할 DB(`opencode.db`, `opencode-<channel>.db`)를 전부 glob.
    /// `.db` suffix로 `-wal`/`-shm` sidecar 제외, 결정적 순회를 위해 경로 정렬.
    /// 디렉토리 부재는 정상 미사용으로 `[]`, 존재하나 열거 불가면 rethrow — 접근 불가를 부재로 오인 금지.
    static func databaseFiles(in dataDirectory: String) throws -> [String] {
        let dir = expandHome(dataDirectory)
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: dir)
        } catch {
            guard FileManager.default.fileExists(atPath: dir) else { return [] }
            throw error
        }
        return names
            .filter { $0.hasPrefix("opencode") && $0.hasSuffix(".db") }
            .sorted()
            .map { dir.trimmingTrailingSlashes + "/" + $0 }
    }

    private static func expandedHome(_ path: String, homeDirectory: URL) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return homeDirectory.path + String(path.dropFirst())
    }
}
