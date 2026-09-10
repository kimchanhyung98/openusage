import Foundation

/// 고정된 SDK 3.64.5의 큐 파일만 관리 — 인증·다른 앱 데이터 삭제 금지.
struct TelemetrySDKStorage {
    let root: URL
    let project: URL
    private let fileManager = FileManager.default
    private static let queueNames = [
        "posthog.queueFolder.uuid", "posthog.queueFolder", "posthog.queue.plist",
        "posthog.replayFolder.uuid", "posthog.replayFolder", "posthog.replayBufferFolder", "posthog.logsFolder",
    ]

    init(token: String, root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.posthog.unknown")
        self.project = self.root.appendingPathComponent(token)
    }

    func prepare() throws {
        let marker = project.appendingPathComponent("openusage.payload-schema")
        if (try? String(contentsOf: marker, encoding: .utf8)) != "2" {
            // 이전 SDK 큐는 beforeSend를 다시 거치지 않으므로, 새 개인정보 계약 적용 전에 폐기.
            try discardQueues()
            try fileManager.createDirectory(at: project, withIntermediateDirectories: true)
            try Data("2".utf8).write(to: marker, options: .atomic)
        }
    }

    func discardQueues() throws {
        for directory in [root, project] {
            for name in Self.queueNames {
                let path = directory.appendingPathComponent(name)
                if fileManager.fileExists(atPath: path.path) { try fileManager.removeItem(at: path) }
            }
        }
    }
}
