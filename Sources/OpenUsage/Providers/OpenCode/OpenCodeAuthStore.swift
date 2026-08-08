import Foundation

/// 머신에 이미 있는 OpenCode Go/Zen credential 읽기 — local 전용, network 접근 없음.
/// `opencode-go` key는 first-run 감지 신호이자 (향후 `/zen/go/v1/usage` API의) Bearer token — 단일 loader로 관리.
struct OpenCodeAuthStore: Sendable {
    var files: TextFileAccessing
    var environment: EnvironmentReading
    var homeDirectory: @Sendable () -> URL

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser }
    ) {
        self.files = files
        self.environment = environment
        self.homeDirectory = homeDirectory
    }

    var dataDirectory: String {
        OpenCodePaths.dataDirectory(environment: environment, homeDirectory: homeDirectory())
    }

    var authFilePath: String {
        OpenCodePaths.authFilePath(dataDirectory: dataDirectory)
    }

    /// `auth.json`의 비어 있지 않은 `opencode-go` API key, 미로그인 시 `nil`.
    /// 해당 entry만 읽고 무관한 sibling entry에는 관대 — 이상 값 하나가 유효 key를 가리지 못하게 함.
    /// 파일이 있는데 읽기·parse 불가면 `credentialsUnreadable` throw — 손상 storage를 logout으로 오인 금지, 파일 부재는 정상 `nil`.
    func goAPIKey() throws -> String? {
        let text: String?
        do {
            text = try files.readTextIfPresent(authFilePath)
        } catch {
            throw OpenCodeUsageError.credentialsUnreadable(detail: error.localizedDescription)
        }
        guard let text else { return nil }
        guard let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            throw OpenCodeUsageError.credentialsUnreadable(detail: "auth.json is not valid JSON")
        }
        guard let entry = object["opencode-go"] as? [String: Any],
              let key = entry["key"] as? String
        else { return nil }
        return key.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}
