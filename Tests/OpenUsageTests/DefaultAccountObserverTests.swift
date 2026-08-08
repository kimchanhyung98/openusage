import XCTest
@testable import OpenUsage

final class DefaultAccountObserverTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/dev")

    private func makeObserver(
        environment: [String: String] = [:],
        files: [String: String] = [:],
        keychainValue: String? = nil
    ) -> DefaultAccountObserver {
        DefaultAccountObserver(
            environment: FakeEnvironment(environment),
            files: FakeFiles(files),
            keychain: FakeKeychain(keychainValue),
            homeDirectory: { [home] in home }
        )
    }

    private func claudeStateJSON(
        uuid: String? = "ACCT-UUID-1",
        email: String? = "dev@example.com",
        orgUuid: String? = nil,
        orgName: String? = nil
    ) -> String {
        var account: [String: String] = [:]
        if let uuid { account["accountUuid"] = uuid }
        if let email { account["emailAddress"] = email }
        if let orgUuid { account["organizationUuid"] = orgUuid }
        if let orgName { account["organizationName"] = orgName }
        let data = try! JSONSerialization.data(withJSONObject: ["oauthAccount": account])
        return String(data: data, encoding: .utf8)!
    }

    // MARK: - Claude

    func testClaudeDefaultHomeResolvesFromUserLevelStateFile() {
        let observer = makeObserver(files: [
            "/Users/dev/.claude.json": claudeStateJSON(),
        ])

        // 기본 `~/.claude`의 state는 dir 안이 아니라 옆의 `~/.claude.json`
        XCTAssertEqual(
            observer.observeClaude(),
            .resolved(identityKey: "acct-uuid-1", label: "dev@example.com", anchor: "/Users/dev/.claude")
        )
    }

    func testClaudeExplicitDefaultHomeReadsIdentityInsideTheConfigDir() {
        let observer = makeObserver(
            environment: ["CLAUDE_CONFIG_DIR": "/Users/dev/.claude"],
            files: [
                "/Users/dev/.claude.json": claudeStateJSON(uuid: "STALE", email: "stale@example.com"),
                "/Users/dev/.claude/.claude.json": claudeStateJSON(),
            ]
        )

        XCTAssertEqual(
            observer.observeClaude(),
            .resolved(identityKey: "acct-uuid-1", label: "dev@example.com", anchor: "/Users/dev/.claude")
        )
    }

    func testClaudeIdentityIsOrgScoped() {
        let observer = makeObserver(files: [
            "/Users/dev/.claude.json": claudeStateJSON(orgUuid: "ORG-9", orgName: "Sunstory"),
        ])

        // 같은 계정 아래 personal Max org와 company Team org 공존 가능 — usage pool이 달라 org id도 identity key에 포함
        XCTAssertEqual(
            observer.observeClaude(),
            .resolved(identityKey: "acct-uuid-1|org-9", label: "dev@example.com (Sunstory)", anchor: "/Users/dev/.claude")
        )
    }

    func testClaudeConfigDirOverrideReadsIdentityInsideTheDir() {
        let observer = makeObserver(
            environment: ["CLAUDE_CONFIG_DIR": "~/claude-work"],
            files: ["/Users/dev/claude-work/.claude.json": claudeStateJSON()]
        )

        XCTAssertEqual(
            observer.observeClaude(),
            .resolved(identityKey: "acct-uuid-1", label: "dev@example.com", anchor: "/Users/dev/claude-work")
        )
    }

    func testManagedClaudePinIgnoresAnAmbientConfigDirOverride() {
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "~/claude-work"]),
            files: FakeFiles([
                "/Users/dev/claude-work/.claude.json": claudeStateJSON(uuid: "OTHER", email: "other@example.com"),
                "/Users/dev/.claude.json": claudeStateJSON(),
            ]),
            keychain: FakeKeychain(nil),
            homeDirectory: { [home] in home },
            pinsClaudeSharedHome: true
        )

        // switch transaction이 `~/.claude` 소유 — observer는 ambient override가 아니라 그 home 기준으로 기술
        XCTAssertEqual(
            observer.observeClaude(),
            .resolved(identityKey: "acct-uuid-1", label: "dev@example.com", anchor: "/Users/dev/.claude")
        )
    }

    func testManagedClaudePinRequiresBothStateFilesToAgree() {
        // switcher 규칙과 동일 — 두 state file 불일치 시 identity ambiguous, 추측 금지
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([
                "/Users/dev/.claude.json": claudeStateJSON(),
                "/Users/dev/.claude/.claude.json": claudeStateJSON(uuid: "OTHER", email: "other@example.com"),
            ]),
            keychain: FakeKeychain(nil),
            homeDirectory: { [home] in home },
            pinsClaudeSharedHome: true
        )

        XCTAssertEqual(
            observer.observeClaude(),
            .unresolved(reason: "shared home state files name different accounts")
        )
    }

    func testManagedClaudePinResolvesFromTheInnerStateFileAlone() {
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles(["/Users/dev/.claude/.claude.json": claudeStateJSON()]),
            keychain: FakeKeychain(nil),
            homeDirectory: { [home] in home },
            pinsClaudeSharedHome: true
        )

        XCTAssertEqual(
            observer.observeClaude(),
            .resolved(identityKey: "acct-uuid-1", label: "dev@example.com", anchor: "/Users/dev/.claude")
        )
    }

    func testClaudeCommaListConfigDirIsUnresolved() {
        // `ClaudeAuthStore`는 env 값을 단일 credential 경로로 취급 — comma list는 단일 identity 부여 불가
        let observer = makeObserver(
            environment: ["CLAUDE_CONFIG_DIR": "~/a,~/b"],
            files: ["/Users/dev/a/.claude.json": claudeStateJSON()]
        )

        XCTAssertEqual(observer.observeClaude(), .unresolved(reason: "CLAUDE_CONFIG_DIR is a comma-separated list"))
    }

    func testClaudeCredentialsWithoutStateFileAreUnresolvedNotAbsent() {
        let observer = makeObserver(files: [
            "/Users/dev/.claude/.credentials.json": "{}",
        ])

        XCTAssertEqual(observer.observeClaude(), .unresolved(reason: "credentials present but no identity file"))
    }

    func testClaudeNoFootprintIsAbsent() {
        XCTAssertEqual(makeObserver().observeClaude(), .absent)
    }

    func testClaudeStateFileNamingNoAccountIsUnresolved() {
        let observer = makeObserver(files: [
            "/Users/dev/.claude.json": #"{"someOtherKey": true}"#,
        ])

        XCTAssertEqual(observer.observeClaude(), .unresolved(reason: "identity file present but names no account"))
    }

    // MARK: - Codex

    private func codexAuthJSON(accountID: String? = "codex-acct-1", idToken: String? = nil) -> String {
        var tokens: [String: String] = ["access_token": "at-1"]
        if let accountID { tokens["account_id"] = accountID }
        if let idToken { tokens["id_token"] = idToken }
        let data = try! JSONSerialization.data(withJSONObject: ["tokens": tokens])
        return String(data: data, encoding: .utf8)!
    }

    private func fakeJWT(payload: [String: Any]) -> String {
        func segment(_ object: [String: Any]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: object)
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(segment(["alg": "none"])).\(segment(payload)).sig"
    }

    func testCodexResolvesFromAccountIDInFirstDefaultHome() {
        let observer = makeObserver(files: [
            "/Users/dev/.codex/auth.json": codexAuthJSON(),
        ])

        XCTAssertEqual(
            observer.observeCodex(),
            .resolved(identityKey: "codex-acct-1", label: nil, anchor: "/Users/dev/.codex")
        )
    }

    func testCodexHomeOverrideWinsAndEmailComesFromIDToken() {
        let idToken = fakeJWT(payload: ["email": "dev@example.com"])
        let observer = makeObserver(
            environment: ["CODEX_HOME": "/opt/codex-alt"],
            files: ["/opt/codex-alt/auth.json": codexAuthJSON(idToken: idToken)]
        )

        XCTAssertEqual(
            observer.observeCodex(),
            .resolved(identityKey: "codex-acct-1", label: "dev@example.com", anchor: "/opt/codex-alt")
        )
    }

    func testCodexFallsBackToChatGPTAccountClaim() {
        // id_token의 ChatGPT account claim은 CLI가 `account_id`로 복사하는 값
        let idToken = fakeJWT(payload: [
            "https://api.openai.com/auth": ["chatgpt_account_id": "CLAIM-ACCT-2"],
        ])
        let observer = makeObserver(files: [
            "/Users/dev/.codex/auth.json": codexAuthJSON(accountID: nil, idToken: idToken),
        ])

        XCTAssertEqual(
            observer.observeCodex(),
            .resolved(identityKey: "claim-acct-2", label: nil, anchor: "/Users/dev/.codex")
        )
    }

    func testCodexNamelessAuthFileIsUnresolvedNeverPathKeyed() {
        // strict identity 규칙 — 계정을 특정 못 하는 auth file은 identity화 금지 (path 유래 fallback 없음)
        let observer = makeObserver(files: [
            "/Users/dev/.codex/auth.json": codexAuthJSON(accountID: nil),
        ])

        XCTAssertEqual(observer.observeCodex(), .unresolved(reason: "credentials present but no account identity"))
    }

    func testCodexNoFootprintIsAbsent() {
        XCTAssertEqual(makeObserver().observeCodex(), .absent)
    }

    func testCodexKeychainCredentialMakesTheFamilyUnresolved() {
        // keychain item 존재 시 auth file identity가 실제 사용 계정임을 보증 불가 — launch 경로에서 keychain secret 미열람
        let observer = makeObserver(
            files: ["/Users/dev/.codex/auth.json": codexAuthJSON()],
            keychainValue: #"{"tokens": {"access_token": "kc-at"}}"#
        )

        XCTAssertEqual(
            observer.observeCodex(),
            .unresolved(reason: "keychain credential present or unverifiable — identity unresolved this launch")
        )
    }

    func testCodexUnverifiableKeychainProbeAlsoMakesTheFamilyUnresolved() {
        // probe 실패(`nil`)도 "item present"와 동일 취급 — wrong-account stamp 위험 방지
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles(["/Users/dev/.codex/auth.json": codexAuthJSON()]),
            keychain: ThrowingKeychain(),
            homeDirectory: { [home] in home }
        )

        XCTAssertEqual(
            observer.observeCodex(),
            .unresolved(reason: "keychain credential present or unverifiable — identity unresolved this launch")
        )
    }

    func testCodexXDGConfigHomeOrderMatchesAuthStore() {
        // `CodexAuthStore.authPaths()`는 `~/.config/codex`를 `~/.codex`보다 먼저 probe — observer도 동일 home에 귀속
        let observer = makeObserver(files: [
            "/Users/dev/.config/codex/auth.json": codexAuthJSON(accountID: "config-home-acct"),
            "/Users/dev/.codex/auth.json": codexAuthJSON(accountID: "legacy-home-acct"),
        ])

        XCTAssertEqual(
            observer.observeCodex(),
            .resolved(identityKey: "config-home-acct", label: nil, anchor: "/Users/dev/.config/codex")
        )
    }
}

private final class ThrowingKeychain: KeychainAccessing, @unchecked Sendable {
    struct Unavailable: Error {}
    func readGenericPassword(service: String) throws -> String? { throw Unavailable() }
    func writeGenericPassword(service: String, value: String) throws { throw Unavailable() }
    func deleteGenericPassword(service: String) throws { throw Unavailable() }
}
