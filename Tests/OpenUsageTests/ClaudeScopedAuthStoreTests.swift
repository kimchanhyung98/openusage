import XCTest
@testable import OpenUsage

final class ClaudeScopedAuthStoreTests: XCTestCase {
    private let scope = ClaudeCredentialScope.configDir(
        path: "/Users/dev/.claude-work",
        keychainLiteral: "~/.claude-work"
    )

    func testScopedStoreReadsOnlyItsOwnCredentialSources() throws {
        let scopedService = ClaudeAuthStore.scopedKeychainServiceName(
            forConfigDirLiteral: "~/.claude-work", environment: FakeEnvironment([:])
        )
        let store = ClaudeAuthStore(
            environment: FakeEnvironment([:]),
            files: FakeFiles([
                // 타 account의 default-home 파일은 scoped card에 비가시
                "~/.claude/.credentials.json": #"{"claudeAiOauth": {"accessToken": "default-at"}}"#,
                "/Users/dev/.claude-work/.credentials.json": #"{"claudeAiOauth": {"accessToken": "work-at"}}"#,
            ]),
            keychain: ServiceKeychain(),
            scope: scope
        )

        XCTAssertEqual(store.keychainServiceCandidates(), [scopedService], "never the bare default service")
        let load = store.loadCredentialSet()
        XCTAssertEqual(load.candidates.map(\.oauth.accessToken), ["work-at"])
        XCTAssertEqual(load.desktopStatus, .notChecked, "a config-dir card never consults Desktop")
    }

    func testPinnedStandardStoreIgnoresAnAmbientConfigDirOverride() {
        let pinned = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/Users/dev/.claude-work"]),
            files: FakeFiles([
                "~/.claude/.credentials.json": #"{"claudeAiOauth": {"accessToken": "shared-at"}}"#,
                "/Users/dev/.claude-work/.credentials.json": #"{"claudeAiOauth": {"accessToken": "other-at"}}"#,
            ]),
            keychain: ServiceKeychain(),
            pinsSharedHome: true
        )
        let overrideFree = ClaudeAuthStore(
            environment: FakeEnvironment([:]),
            files: FakeFiles([:]),
            keychain: ServiceKeychain()
        )

        XCTAssertNil(pinned.claudeHomeOverride())
        XCTAssertEqual(pinned.keychainServiceCandidates(), overrideFree.keychainServiceCandidates(),
                       "the pinned store reads the base service, never the override-scoped item")
        XCTAssertEqual(pinned.loadCredentialSet().candidates.map(\.oauth.accessToken), ["shared-at"],
                       "credentials come from the shared home, not the ambient override directory")
    }

    func testScopedStoreNeverInheritsTheAmbientEnvironmentToken() {
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CODE_OAUTH_TOKEN": "ambient-token"]),
            files: FakeFiles([
                "/Users/dev/.claude-work/.credentials.json": #"{"claudeAiOauth": {"accessToken": "work-at"}}"#,
            ]),
            keychain: ServiceKeychain(),
            scope: scope
        )

        let candidates = store.loadCredentialSet().candidates
        XCTAssertEqual(candidates.map(\.oauth.accessToken), ["work-at"])
        XCTAssertFalse(candidates.contains { $0.source == .environment })
    }

    func testFootprintProbeSeesFileAndKeychainShapesWithoutReadingSecrets() {
        let scopedService = ClaudeAuthStore.scopedKeychainServiceName(
            forConfigDirLiteral: "~/.claude-work", environment: FakeEnvironment([:])
        )
        let fileBacked = ClaudeAuthStore(
            environment: FakeEnvironment([:]),
            files: FakeFiles(["/Users/dev/.claude-work/.credentials.json": "{}"]),
            keychain: ServiceKeychain(),
            scope: scope
        )
        XCTAssertTrue(fileBacked.hasCredentialFootprint())

        let keychainBacked = ClaudeAuthStore(
            environment: FakeEnvironment([:]),
            files: FakeFiles([:]),
            keychain: ServiceKeychain(values: [scopedService: "present"]),
            scope: scope
        )
        XCTAssertTrue(keychainBacked.hasCredentialFootprint())

        let bare = ClaudeAuthStore(
            environment: FakeEnvironment([:]),
            files: FakeFiles([:]),
            keychain: ServiceKeychain(),
            scope: scope
        )
        XCTAssertFalse(bare.hasCredentialFootprint())
    }

    func testStandardStoreDropsDesktopFallbackWhileExtraCardsExist() {
        // CLI login 없음 + Desktop 불허(추가 Claude card 존재) → Desktop 조회 없이 `.notFound` 보고
        let store = ClaudeAuthStore(
            environment: FakeEnvironment([:]),
            files: FakeFiles([:]),
            keychain: ServiceKeychain(),
            allowsDesktopFallback: false
        )

        let load = store.loadCredentialSet(forceDesktopFallback: true)
        XCTAssertEqual(load.desktopStatus, .notFound)
        XCTAssertTrue(load.candidates.isEmpty)
    }
}
