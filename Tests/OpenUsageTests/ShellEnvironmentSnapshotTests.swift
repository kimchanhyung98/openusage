import XCTest
@testable import OpenUsage

@MainActor
final class ShellEnvironmentSnapshotTests: XCTestCase {
    func testStoreRoundtripsSnapshot() {
        let defaults = makeScratchDefaults()
        let store = ShellEnvironmentSnapshotStore(defaults: defaults)
        let snapshot = ShellEnvironmentSnapshot(
            values: ["CLAUDE_CONFIG_DIR": "~/.claude-work", "XDG_CONFIG_HOME": "~/.config"],
            capturedAt: Date(timeIntervalSince1970: 1_752_800_000)
        )

        store.save(snapshot)

        XCTAssertEqual(store.load(), snapshot)
    }

    func testUndecodableSnapshotIsDiscarded() {
        let defaults = makeScratchDefaults()
        defaults.set(Data("not json".utf8), forKey: ShellEnvironmentSnapshotStore.storageKey)
        let store = ShellEnvironmentSnapshotStore(defaults: defaults)

        XCTAssertNil(store.load())
        XCTAssertNil(defaults.data(forKey: ShellEnvironmentSnapshotStore.storageKey))
    }

    func testCurrentIsNilWhenCaptureFailed() {
        // 빈 capture는 spawn·parse 실패 의미 — snapshot으로 persist 금지
        let shellEnvironment = LoginShellEnvironment(runner: FixedRunner(stdout: "no markers"))
        XCTAssertFalse(shellEnvironment.ensureCapturedForTesting(), "an empty capture must report failure")
        XCTAssertNil(ShellEnvironmentSnapshot.current(shellEnvironment: shellEnvironment))
    }

    func testCurrentCapturesOnlyDeclaredKeys() {
        let stdout = [
            "__OPENUSAGE_ENV_BEGIN__",
            "CLAUDE_CONFIG_DIR=~/.claude-work",
            "OPENROUTER_API_KEY=sk-or-secret",
            "PATH=/usr/bin",
            "__OPENUSAGE_ENV_END__",
        ].joined(separator: "\0")
        let shellEnvironment = LoginShellEnvironment(runner: FixedRunner(stdout: stdout))
        XCTAssertTrue(shellEnvironment.ensureCapturedForTesting())

        let snapshot = ShellEnvironmentSnapshot.current(shellEnvironment: shellEnvironment)

        // 선언된 비밀 아닌 key만 snapshot에 포함 — API key·token 제외
        XCTAssertEqual(snapshot?.values, ["CLAUDE_CONFIG_DIR": "~/.claude-work"])
    }

    func testShellSnapshotCapturesAllKimiIdentityKeys() {
        let stdout = [
            "__OPENUSAGE_ENV_BEGIN__",
            "KIMI_CODE_HOME=/tmp/kimi-home",
            "KIMI_CODE_BASE_URL=https://api.kimi.example",
            "KIMI_CODE_OAUTH_HOST=https://code-auth.kimi.example",
            "KIMI_OAUTH_HOST=https://auth.kimi.example",
            "KIMI_DISABLE_OAUTH_LOCK=1",
            "PATH=/usr/bin",
            "__OPENUSAGE_ENV_END__",
        ].joined(separator: "\0")
        let shellEnvironment = LoginShellEnvironment(runner: FixedRunner(stdout: stdout))
        XCTAssertTrue(shellEnvironment.ensureCapturedForTesting())

        let snapshot = ShellEnvironmentSnapshot.current(shellEnvironment: shellEnvironment)

        XCTAssertEqual(snapshot?.values, [
            "KIMI_CODE_HOME": "/tmp/kimi-home",
            "KIMI_CODE_BASE_URL": "https://api.kimi.example",
            "KIMI_CODE_OAUTH_HOST": "https://code-auth.kimi.example",
            "KIMI_OAUTH_HOST": "https://auth.kimi.example",
            "KIMI_DISABLE_OAUTH_LOCK": "1",
        ])
    }

    func testSnapshotPredatingKimiKeysDoesNotPinThemAsAbsent() throws {
        let defaults = makeScratchDefaults()
        let oldSnapshot = LegacyShellEnvironmentSnapshot(
            values: ["CODEX_HOME": "/tmp/codex-home"],
            capturedAt: Date(timeIntervalSince1970: 1_752_800_000)
        )
        defaults.set(
            try JSONEncoder().encode(oldSnapshot),
            forKey: ShellEnvironmentSnapshotStore.previousStorageKey
        )
        let store = ShellEnvironmentSnapshotStore(defaults: defaults)
        let stdout = [
            "__OPENUSAGE_ENV_BEGIN__", "KIMI_CODE_HOME=/tmp/kimi-live", "PATH=/usr/bin", "__OPENUSAGE_ENV_END__",
        ].joined(separator: "\0")
        let shellEnvironment = LoginShellEnvironment(runner: FixedRunner(stdout: stdout))
        XCTAssertTrue(shellEnvironment.ensureCapturedForTesting())
        let reader = ProcessEnvironmentReader(
            processEnvironment: [:],
            shellEnvironment: shellEnvironment,
            launchSnapshot: { store.load() }
        )

        let snapshot = try XCTUnwrap(store.load())
        XCTAssertEqual(snapshot.pinnedKeys, Set(ShellEnvironmentSnapshot.legacyCapturedKeys))
        XCTAssertNotNil(defaults.data(forKey: ShellEnvironmentSnapshotStore.storageKey))
        XCTAssertNil(defaults.data(forKey: ShellEnvironmentSnapshotStore.previousStorageKey))
        XCTAssertEqual(reader.value(for: "CODEX_HOME"), "/tmp/codex-home")
        XCTAssertEqual(reader.value(for: "KIMI_CODE_HOME"), "/tmp/kimi-live")
    }

    func testSavingV2SnapshotRemovesV1Snapshot() {
        let defaults = makeScratchDefaults()
        defaults.set(Data("old snapshot".utf8), forKey: ShellEnvironmentSnapshotStore.previousStorageKey)
        let store = ShellEnvironmentSnapshotStore(defaults: defaults)
        let snapshot = ShellEnvironmentSnapshot(
            values: ["KIMI_CODE_HOME": "/tmp/kimi-home"],
            capturedAt: Date(timeIntervalSince1970: 1_752_800_000)
        )

        store.save(snapshot)

        XCTAssertEqual(store.load(), snapshot)
        XCTAssertNil(defaults.data(forKey: ShellEnvironmentSnapshotStore.previousStorageKey))
    }

    func testRefreshTaskPersistsSnapshotAfterCapture() async {
        let defaults = makeScratchDefaults()
        let store = ShellEnvironmentSnapshotStore(defaults: defaults)
        let stdout = [
            "__OPENUSAGE_ENV_BEGIN__", "CODEX_HOME=/tmp/codex-home", "PATH=/usr/bin", "__OPENUSAGE_ENV_END__",
        ].joined(separator: "\0")
        let shellEnvironment = LoginShellEnvironment(runner: FixedRunner(stdout: stdout))

        await store.startRefreshTask(shellEnvironment: shellEnvironment).value

        XCTAssertEqual(store.load()?.values, ["CODEX_HOME": "/tmp/codex-home"])
    }

    func testRefreshTaskKeepsPreviousSnapshotWhenCaptureFails() async {
        let defaults = makeScratchDefaults()
        let store = ShellEnvironmentSnapshotStore(defaults: defaults)
        let previous = ShellEnvironmentSnapshot(values: ["CODEX_HOME": "/tmp/old"], capturedAt: Date())
        store.save(previous)
        let shellEnvironment = LoginShellEnvironment(runner: FixedRunner(stdout: "capture failed"))

        await store.startRefreshTask(shellEnvironment: shellEnvironment).value

        XCTAssertEqual(store.load(), previous)
    }

    // MARK: - ProcessEnvironmentReader layering (process env → snapshot pin for identity keys → live capture)

    func testReaderPrefersTheProcessEnvironment() {
        let reader = ProcessEnvironmentReader(
            processEnvironment: ["CODEX_HOME": "/tmp/exported"],
            shellEnvironment: LoginShellEnvironment(runner: FixedRunner(stdout: "unused")),
            launchSnapshot: { ShellEnvironmentSnapshot(values: ["CODEX_HOME": "/tmp/persisted"], capturedAt: Date()) }
        )

        XCTAssertEqual(reader.value(for: "CODEX_HOME"), "/tmp/exported")
    }

    func testReaderServesSnapshotFactsWhileTheCaptureIsCold() {
        // main-thread 읽기는 capture를 유발하지 않아 cold shell layer는 "unknown" 응답
        let cold = LoginShellEnvironment(runner: FixedRunner(stdout: "unused"))
        let snapshot = ShellEnvironmentSnapshot(values: ["CODEX_HOME": "/tmp/persisted"], capturedAt: Date())
        let reader = ProcessEnvironmentReader(
            processEnvironment: [:],
            shellEnvironment: cold,
            launchSnapshot: { snapshot }
        )

        XCTAssertEqual(reader.value(for: "CODEX_HOME"), "/tmp/persisted")
        // snapshot에 명확히 없는 key는 "override 없음"으로 pin
        XCTAssertNil(reader.value(for: "CLAUDE_CONFIG_DIR"))
    }

    func testReaderPinsIdentityKeysToTheSnapshotEvenAfterTheCaptureLands() {
        let stdout = [
            "__OPENUSAGE_ENV_BEGIN__", "CODEX_HOME=/tmp/changed", "MY_API_KEY=sk-live", "PATH=/usr/bin", "__OPENUSAGE_ENV_END__",
        ].joined(separator: "\0")
        let warm = LoginShellEnvironment(runner: FixedRunner(stdout: stdout))
        XCTAssertTrue(warm.ensureCapturedForTesting())
        let reader = ProcessEnvironmentReader(
            processEnvironment: [:],
            shellEnvironment: warm,
            launchSnapshot: { ShellEnvironmentSnapshot(values: ["CODEX_HOME": "/tmp/pinned"], capturedAt: Date()) }
        )

        XCTAssertEqual(reader.value(for: "CODEX_HOME"), "/tmp/pinned")
        // identity 외 key는 기존대로 live capture 참조
        XCTAssertEqual(reader.value(for: "MY_API_KEY"), "sk-live")
    }

    func testReaderFallsToTheLiveCaptureWhenNoSnapshotExists() {
        let stdout = ["__OPENUSAGE_ENV_BEGIN__", "CODEX_HOME=/tmp/live", "__OPENUSAGE_ENV_END__"].joined(separator: "\0")
        let warm = LoginShellEnvironment(runner: FixedRunner(stdout: stdout))
        XCTAssertTrue(warm.ensureCapturedForTesting())
        let reader = ProcessEnvironmentReader(
            processEnvironment: [:],
            shellEnvironment: warm,
            launchSnapshot: { nil }
        )

        XCTAssertEqual(reader.value(for: "CODEX_HOME"), "/tmp/live")
    }

    private func makeScratchDefaults() -> UserDefaults {
        let suiteName = "OpenUsageTests.ShellEnvironmentSnapshot.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }
}

private struct LegacyShellEnvironmentSnapshot: Codable {
    var values: [String: String]
    var capturedAt: Date
}

private final class FixedRunner: ProcessRunning, @unchecked Sendable {
    let stdout: String

    init(stdout: String) { self.stdout = stdout }

    func run(executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval) throws -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: stdout, stderr: "")
    }
}

private extension LoginShellEnvironment {
    /// `ensureCaptured`가 main thread에서 spawn을 거부하므로 off-main으로 우회해 강제 capture
    func ensureCapturedForTesting() -> Bool {
        let done = DispatchSemaphore(value: 0)
        var result = false
        DispatchQueue.global().async {
            result = self.ensureCaptured()
            done.signal()
        }
        done.wait()
        return result
    }
}
