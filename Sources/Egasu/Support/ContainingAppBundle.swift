import Foundation

/// 실행 파일을 담고 있는 `.app` 탐색 — `PATH`의 symlink로 호출된 helper 포함.
public enum ContainingAppBundle {
    public static func url(for executableURL: URL) -> URL? {
        var candidate = executableURL.resolvingSymlinksInPath().standardizedFileURL
        while candidate.path != "/" {
            if candidate.pathExtension == "app" { return candidate }
            candidate.deleteLastPathComponent()
        }
        return nil
    }
}
