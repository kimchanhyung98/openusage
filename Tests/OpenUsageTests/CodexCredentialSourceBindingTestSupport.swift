import Foundation
@testable import OpenUsage

enum CodexBindingTestFixture {
    static let home = "/Users/source-binding-test"
    static let instant = Date(timeIntervalSince1970: 1_800_000_000)

    static func auth(
        token: String, accountID: String? = nil, refreshToken: String? = nil, idToken: String? = nil
    ) -> String {
        let auth = CodexAuth(tokens: CodexTokens(
            accessToken: token, refreshToken: refreshToken, idToken: idToken, accountID: accountID
        ))
        return String(decoding: try! JSONEncoder().encode(auth), as: UTF8.self)
    }

    static func jwt(accountID: String? = nil, expiresIn: TimeInterval = 3_600) -> String {
        var claims: [String: Any] = ["exp": instant.addingTimeInterval(expiresIn).timeIntervalSince1970]
        if let accountID { claims["https://api.openai.com/auth"] = ["chatgpt_account_id": accountID] }
        let payload = try! JSONSerialization.data(withJSONObject: claims)
        let encoded = payload.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "e30.\(encoded).signature"
    }

    static func quota(used: Double = 25) -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: Data("""
        {"rate_limit":{"primary_window":{"used_percent":\(used),"limit_window_seconds":18000}}}
        """.utf8))
    }

    static var resetCredits: HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"available_count":0}"#.utf8))
    }

    @MainActor
    static func provider(
        files: CodexBindingFiles,
        keychain: CodexBindingKeychain = CodexBindingKeychain(),
        environment: [String: String] = [:],
        binding: CodexAccountBinding? = nil,
        http: any HTTPClient
    ) -> CodexProvider {
        CodexProvider(
            authStore: CodexAuthStore(
                environment: FakeEnvironment(environment), files: files, keychain: keychain,
                scope: binding.map { .home(path: $0.home) } ?? .standard,
                expectedIdentityKey: binding?.identityKey, now: { instant }
            ),
            usageClient: CodexUsageClient(http: http),
            logUsageScanner: CodexLogUsageScanner(cacheIdentityOverride: "source-binding-tests", rootsOverride: []),
            includePiUsage: false, now: { instant }, pricing: { .empty }
        )
    }
}

final class CodexBindingFiles: TextFileAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    private var readQueues: [String: [String]] = [:]
    private var recordedWrites: [String] = []

    init(_ initial: [String: String] = [:]) {
        values = Dictionary(initial.map { (Self.canonical($0.key), $0.value) }, uniquingKeysWith: { _, last in last })
    }

    var savedPaths: [String] { lock.withLock { recordedWrites } }

    func set(_ text: String, at path: String) { lock.withLock { values[Self.canonical(path)] = text } }

    func text(at path: String) -> String? { lock.withLock { values[Self.canonical(path)] } }

    func queueReads(_ texts: [String], at path: String) {
        lock.withLock { readQueues[Self.canonical(path)] = texts }
    }

    func exists(_ path: String) -> Bool { lock.withLock { values[Self.canonical(path)] != nil } }

    func readText(_ path: String) throws -> String {
        lock.withLock {
            let path = Self.canonical(path)
            if var queue = readQueues[path], !queue.isEmpty {
                let value = queue.removeFirst()
                readQueues[path] = queue
                values[path] = value
                return value
            }
            return values[path] ?? ""
        }
    }

    func writeText(_ path: String, _ text: String) throws {
        lock.withLock {
            let path = Self.canonical(path)
            values[path] = text
            recordedWrites.append(path)
        }
    }

    func remove(_ path: String) throws { _ = lock.withLock { values.removeValue(forKey: Self.canonical(path)) } }

    private static func canonical(_ path: String) -> String {
        path.hasPrefix("~/") ? CodexBindingTestFixture.home + String(path.dropFirst()) : path
    }
}

final class CodexBindingKeychain: KeychainAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    private let presence: Bool?
    private var reads: [String] = []
    private var probes: [String] = []

    init(value: String? = nil, presence: Bool? = false) {
        self.value = value
        self.presence = presence
    }

    var readServices: [String] { lock.withLock { reads } }
    var probeServices: [String] { lock.withLock { probes } }

    func genericPasswordExists(service: String) -> Bool? {
        lock.withLock {
            probes.append(service)
            return presence
        }
    }

    func readGenericPassword(service: String) throws -> String? {
        lock.withLock {
            reads.append(service)
            return service == CodexAuthStore.keychainService ? value : nil
        }
    }

    func writeGenericPassword(service: String, value: String) throws { lock.withLock { self.value = value } }

    func deleteGenericPassword(service: String) throws { lock.withLock { value = nil } }
}
