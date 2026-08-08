import XCTest
@testable import OpenUsage

final class ClaudeConfigDirDiscoveryTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/dev")

    private func makeDiscovery(
        environment: [String: String] = [:],
        files: [String: String],
        keychainServices: [String: String] = [:],
        subdirectories: [String] = []
    ) -> ClaudeConfigDirDiscovery {
        ClaudeConfigDirDiscovery(
            environment: FakeEnvironment(environment),
            files: FakeFiles(files),
            keychain: ServiceKeychain(values: keychainServices),
            homeDirectory: { [home] in home },
            listSubdirectories: { [home] url in
                subdirectories
                    .map { URL(fileURLWithPath: $0) }
                    .filter { $0.deletingLastPathComponent().path == url.path }
                    .filter { _ in url.path.hasPrefix(home.path) }
            }
        )
    }

    func testAcceptsADirWithIdentityAndFileCredential() throws {
        let discovery = makeDiscovery(
            files: [
                "/Users/dev/.claude-work/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-2", "emailAddress": "work@example.com", "organizationName": "Sunstory"}}"#,
                "/Users/dev/.claude-work/.credentials.json": #"{"claudeAiOauth": {"accessToken": "at-2"}}"#,
            ],
            subdirectories: ["/Users/dev/.claude-work"]
        )

        let result = discovery.run()

        let finding = try XCTUnwrap(result.findings.first)
        XCTAssertEqual(result.findings.count, 1)
        XCTAssertEqual(finding.identityKey, "acct-2")
        XCTAssertEqual(finding.label, "work@example.com (Sunstory)")
        XCTAssertEqual(finding.anchorPath, "/Users/dev/.claude-work")
    }

    func testAcceptsAKeychainBackedDirThroughItsScopedServiceName() throws {
        // Claude Code는 CLAUDE_CONFIG_DIR 문자열 리터럴을 해시 — `~` 표기도 절대 경로와 함께 probe, 일치한 리터럴을 scoped store가 재사용
        let literal = "~/.claude-alt"
        let service = ClaudeAuthStore.scopedKeychainServiceName(
            forConfigDirLiteral: literal, environment: FakeEnvironment([:])
        )
        let discovery = makeDiscovery(
            files: [
                "/Users/dev/.claude-alt/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-3"}}"#,
            ],
            keychainServices: [service: "present"],
            subdirectories: ["/Users/dev/.claude-alt"]
        )

        let result = discovery.run()

        let finding = try XCTUnwrap(result.findings.first)
        XCTAssertEqual(finding.identityKey, "acct-3")
        XCTAssertEqual(finding.keychainLiteral, literal)
    }

    func testRejectsIdentityWithoutCredentialAndCredentialWithoutIdentity() {
        let discovery = makeDiscovery(
            files: [
                // identity만 있고 credential shape 없음: toy/fork state 파일
                "/Users/dev/.claude-toy/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-4"}}"#,
                // credential만 있고 identity 없음: account 라우팅 불가 → card 생성 금지
                "/Users/dev/.claude-anon/.credentials.json": #"{"claudeAiOauth": {"accessToken": "at-5"}}"#,
            ],
            subdirectories: ["/Users/dev/.claude-toy", "/Users/dev/.claude-anon"]
        )

        let result = discovery.run()

        XCTAssertTrue(result.findings.isEmpty)
        XCTAssertEqual(result.notes.count, 1, "the near-miss with an identity enters the support trail")
    }

    func testExcludesTheDefaultHomesIncludingTheEnvOverride() {
        let files = [
            "/Users/dev/.claude-main/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-MAIN"}}"#,
            "/Users/dev/.claude-main/.credentials.json": #"{"claudeAiOauth": {"accessToken": "at"}}"#,
            "/Users/dev/.config/claude/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-XDG"}}"#,
            "/Users/dev/.config/claude/.credentials.json": #"{"claudeAiOauth": {"accessToken": "at"}}"#,
        ]
        let discovery = makeDiscovery(
            environment: ["CLAUDE_CONFIG_DIR": "~/.claude-main"],
            files: files,
            subdirectories: ["/Users/dev/.claude-main", "/Users/dev/.config/claude"]
        )

        // env로 지정된 home은 default card 것이라 제외 → XDG dir이 별개 home이자 정당한 후보
        XCTAssertEqual(discovery.run().findings.map(\.identityKey), ["acct-xdg"])

        // override 없으면 XDG가 다시 default home, env로 지정된 dir이 후보
        let withoutOverride = makeDiscovery(
            files: files,
            subdirectories: ["/Users/dev/.claude-main", "/Users/dev/.config/claude"]
        )
        XCTAssertEqual(withoutOverride.run().findings.map(\.identityKey), ["acct-main"])
    }

    func testScansRegisteredHomesOutsideTheAmbientCandidateShape() throws {
        let discovery = makeDiscovery(
            files: [
                "/Users/dev/accounts/claude-work/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-5"}}"#,
                "/Users/dev/accounts/claude-work/.credentials.json": #"{"claudeAiOauth": {"accessToken": "at-5"}}"#,
            ]
        )

        let result = discovery.run(
            additionalDirectories: [URL(fileURLWithPath: "/Users/dev/accounts/claude-work")]
        )

        let finding = try XCTUnwrap(result.findings.first)
        XCTAssertEqual(finding.identityKey, "acct-5")
        XCTAssertEqual(finding.anchorPath, "/Users/dev/accounts/claude-work")
    }
}
