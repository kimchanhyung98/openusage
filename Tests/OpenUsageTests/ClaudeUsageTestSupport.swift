import Foundation
import XCTest
@testable import OpenUsage

extension XCTestCase {
    func isolatedClaudeUsageStore(onContention: @escaping @Sendable () -> Void = {}) -> ClaudeUsageStateStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageTests.ClaudeUsage.\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return ClaudeUsageStateStore(directory: directory, onContention: onContention)
    }
}

func claudeUsageTestIdentity(_ account: String = "account-a") -> String {
    String(data: try! JSONSerialization.data(withJSONObject: [
        "oauthAccount": ["accountUuid": account, "organizationUuid": "test-org"]
    ]), encoding: .utf8)!
}
