import Foundation
@testable import OpenUsage

func isolatedClaudeUsageStore() -> ClaudeUsageStateStore {
    ClaudeUsageStateStore(directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("OpenUsageTests.ClaudeUsage.\(UUID().uuidString)"))
}

func claudeUsageTestIdentity(_ account: String = "account-a") -> String {
    String(data: try! JSONSerialization.data(withJSONObject: [
        "oauthAccount": ["accountUuid": account, "organizationUuid": "test-org"]
    ]), encoding: .utf8)!
}
