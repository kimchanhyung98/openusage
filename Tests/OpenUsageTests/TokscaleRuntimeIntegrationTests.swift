import Darwin
import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class TokscaleRuntimeIntegrationTests: XCTestCase {
    func testRealProcessFlowFiltersEnvironmentAndRequiresAnExplicitSubmitAfterLogin() async throws {
        let fixture = try makeFixture()
        let store = fixture.store
        XCTAssertEqual(store.phase, .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("calls").path))

        try store.saveDeviceName("fixture-mac")
        store.startSubmit()
        store.startSubmit()
        try await waitUntil { store.phase == .loginRequired && !store.isRunning }
        XCTAssertEqual(try fixture.calls(), ["submit"])
        XCTAssertEqual(try fixture.inputEvents(), ["submit:n:EOF"])
        XCTAssertFalse(store.output.contains("\u{1B}"))

        store.startLogin()
        try await waitUntil { store.output.contains("FIXTURE-CODE") }
        XCTAssertEqual(store.phase, .loggingIn)
        XCTAssertTrue(store.isRunning)
        let childPID = try fixture.childPID()
        try Data().write(to: fixture.home.appendingPathComponent("approve"))
        try await waitUntil { store.phase == .loginFinished && !store.isRunning }
        try await assertProcessIsGone(childPID)
        XCTAssertEqual(try fixture.calls(), ["submit", "login"])
        XCTAssertEqual(try fixture.inputEvents(), ["submit:n:EOF", "login:EOF"])

        store.startSubmit()
        try await waitUntil { store.phase == .submitFinished && !store.isRunning }
        XCTAssertEqual(try fixture.calls(), ["submit", "login", "submit"])
        XCTAssertEqual(try fixture.inputEvents(), ["submit:n:EOF", "login:EOF", "submit:n:EOF"])
        XCTAssertEqual(store.output, "No data to submit.\n")
        XCTAssertEqual(
            fixture.defaults.persistentDomain(forName: fixture.suite)?.keys.sorted(),
            [TokscaleSyncStore.deviceNameKey]
        )
    }

    func testCancelLoginStopsTheRealChildAndAllowsAnExplicitRetry() async throws {
        let fixture = try makeFixture()
        try await startPendingLogin(fixture)
        let childPID = try fixture.childPID()

        fixture.store.cancelLogin()
        fixture.store.startSubmit()
        try await waitUntil { !fixture.store.isRunning }
        try await assertProcessIsGone(childPID)
        XCTAssertEqual(fixture.store.phase, .loginRequired)
        XCTAssertTrue(fixture.store.output.isEmpty)
        XCTAssertEqual(try fixture.calls(), ["submit", "login"])

        fixture.store.startLogin()
        try await waitUntil { fixture.store.output.contains("FIXTURE-CODE") }
        XCTAssertEqual(try fixture.calls(), ["submit", "login", "login"])
        await fixture.store.shutdown()
    }

    func testShutdownWaitsForTheRealChildAndClearsTransientState() async throws {
        let fixture = try makeFixture()
        try await startPendingLogin(fixture)
        let childPID = try fixture.childPID()

        await fixture.store.shutdown()

        try await assertProcessIsGone(childPID)
        XCTAssertEqual(fixture.store.phase, .idle)
        XCTAssertFalse(fixture.store.isRunning)
        XCTAssertTrue(fixture.store.output.isEmpty)
        XCTAssertNil(fixture.store.errorMessage)
        XCTAssertEqual(try fixture.calls(), ["submit", "login"])
    }

    func testBunDisappearingBeforeLoginCanRecoverThroughTheNextExplicitSync() async throws {
        let fixture = try makeFixture()
        fixture.store.startSubmit()
        try await waitUntil { fixture.store.phase == .loginRequired && !fixture.store.isRunning }
        let disabled = fixture.bunx.appendingPathExtension("disabled")
        try FileManager.default.moveItem(at: fixture.bunx, to: disabled)

        fixture.store.startLogin()
        try await waitUntil { fixture.store.phase == .failed && !fixture.store.isRunning }
        XCTAssertEqual(fixture.store.failure, .bunxMissing)
        XCTAssertEqual(fixture.store.failure?.offersBunInstallationGuide, true)
        XCTAssertEqual(try fixture.calls(), ["submit"])

        try FileManager.default.moveItem(at: disabled, to: fixture.bunx)
        fixture.store.startSubmit()
        try await waitUntil { fixture.store.phase == .loginRequired && !fixture.store.isRunning }
        fixture.store.startLogin()
        try await waitUntil { fixture.store.output.contains("FIXTURE-CODE") }
        XCTAssertEqual(try fixture.calls(), ["submit", "submit", "login"])
        await fixture.store.shutdown()
    }

    func testDelayedStarPromptReceivesExplicitNoAndFinishesSubmission() async throws {
        let fixture = try makeFixture()
        let store = fixture.store
        try store.saveDeviceName("fixture-mac")
        try Data().write(to: fixture.home.appendingPathComponent("authenticated"))
        try Data().write(to: fixture.home.appendingPathComponent("ask-to-star"))

        store.startSubmit()
        try await waitUntil { store.output.contains("Fixture submission prepared.") }
        XCTAssertEqual(store.phase, .submitting)
        XCTAssertTrue(store.isRunning)
        XCTAssertFalse(store.output.contains("star the project"))

        try Data().write(to: fixture.home.appendingPathComponent("show-star-prompt"))
        try await waitUntil { !store.isRunning }

        XCTAssertEqual(store.phase, .submitFinished, store.output)
        XCTAssertNil(store.failure)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(try fixture.calls(), ["submit"])
        XCTAssertEqual(try fixture.inputEvents(), ["submit:n:EOF"])
        XCTAssertEqual(try Data(contentsOf: fixture.home.appendingPathComponent("star-answer")), Data("n\n".utf8))
        XCTAssertTrue(store.output.contains("Would you like to star the project on GitHub? (Y/n)"))
        XCTAssertTrue(store.output.hasSuffix("Star skipped.\nFixture submission completed.\n"))
    }

    private func startPendingLogin(_ fixture: Fixture) async throws {
        fixture.store.startSubmit()
        try await waitUntil { fixture.store.phase == .loginRequired && !fixture.store.isRunning }
        fixture.store.startLogin()
        try await waitUntil { fixture.store.output.contains("FIXTURE-CODE") }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("OpenUsageTests.TokscaleRuntime.\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let bin = root.appendingPathComponent("runtime/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let executable = bin.appendingPathComponent("fixture-command")
        try Self.commandScript.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let bunx = bin.appendingPathComponent("bunx")
        for name in ["bun", "bunx"] {
            try FileManager.default.createSymbolicLink(
                at: bin.appendingPathComponent(name), withDestinationURL: executable
            )
        }

        let suite = "OpenUsageTests.TokscaleRuntime.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let installer = BunInstaller(
            downloader: NoNetworkDownloader(),
            processEnvironment: ["PATH": "/usr/bin:/bin"],
            loginShellValue: { name in
                guard !Thread.isMainThread else { return nil }
                return name == "PATH" ? bin.path : nil
            },
            homeDirectoryURL: home,
            temporaryDirectoryURL: root
        )
        let runner = TokscaleCommandRunner(
            inheritedEnvironment: [
                "PATH": "/usr/bin:/bin",
                "OPENAI_API_KEY": "synthetic-app-secret",
                "GH_TOKEN": "synthetic-github-secret",
                "HOME": "/must-not-be-used",
            ],
            loginShellEnvironment: {
                guard !Thread.isMainThread else { return nil }
                return [
                    "PATH": bin.path,
                    "TOKSCALE_API_TOKEN": "synthetic-token",
                    "CODEX_HOME": home.appendingPathComponent("fixture-source").path,
                    "ANTHROPIC_API_KEY": "synthetic-shell-secret",
                    "UNREGISTERED_SECRET": "synthetic-unknown-secret",
                ]
            },
            homeDirectoryURL: home
        )
        let store = TokscaleSyncStore(defaults: defaults, bunInstaller: installer, commandRunner: runner)
        addTeardownBlock { await store.shutdown() }
        return Fixture(store: store, home: home, bunx: bunx, defaults: defaults, suite: suite)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw FixtureError.conditionTimedOut
    }

    private func assertProcessIsGone(_ pid: pid_t) async throws {
        try await waitUntil {
            Darwin.kill(pid, 0) == -1 && errno == ESRCH
        }
    }

    private struct Fixture {
        let store: TokscaleSyncStore
        let home: URL
        let bunx: URL
        let defaults: UserDefaults
        let suite: String

        func calls() throws -> [String] {
            try String(contentsOf: home.appendingPathComponent("calls"), encoding: .utf8)
                .split(separator: "\n").map(String.init)
        }

        func inputEvents() throws -> [String] {
            try String(contentsOf: home.appendingPathComponent("input-events"), encoding: .utf8)
                .split(separator: "\n").map(String.init)
        }

        func childPID() throws -> pid_t {
            let text = try String(contentsOf: home.appendingPathComponent("child.pid"), encoding: .utf8)
            return try XCTUnwrap(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
    }

    private enum FixtureError: Error {
        case conditionTimedOut
        case unexpectedDownload
    }

    private struct NoNetworkDownloader: BunInstallerDownloading {
        func download(from url: URL, maximumBytes: Int) async throws -> BunInstallerDownload {
            XCTFail("This fixture must never download or install Bun")
            throw FixtureError.unexpectedDownload
        }
    }

    private static let commandScript = #"""
    #!/bin/sh
    set -e
    case "$0" in */bunx) ;; *) exit 70 ;; esac
    test "$#" -eq 2
    test "$1" = "tokscale@latest"
    test "$HOME" = "$PWD"
    test "$TOKSCALE_API_TOKEN" = "synthetic-token"
    test "$CODEX_HOME" = "$HOME/fixture-source"
    test -z "$OPENAI_API_KEY$GH_TOKEN$ANTHROPIC_API_KEY$UNREGISTERED_SECRET"
    printf '%s\n' "$2" >> "$HOME/calls"
    case "$2" in
      submit)
        if test -f "$HOME/ask-to-star"; then
          printf 'Fixture submission prepared.\n'
          while test ! -f "$HOME/show-star-prompt"; do /bin/sleep 0.02; done
          printf 'Would you like to star the project on GitHub? (Y/n) '
        fi
        answer=
        if ! IFS= read -r answer; then
          printf 'Expected an explicit no response, received EOF.\n' >&2
          exit 72
        fi
        if test "$answer" != n; then
          printf 'Expected an explicit no response.\n' >&2
          exit 73
        fi
        extra=
        if IFS= read -r extra || test -n "$extra"; then
          printf 'Expected EOF after the no response.\n' >&2
          exit 74
        fi
        printf 'submit:%s:EOF\n' "$answer" >> "$HOME/input-events"
        if test ! -f "$HOME/authenticated"; then
          printf '\033[31mNot logged in.\033[0m\n' >&2
          exit 1
        fi
        test "$TOKSCALE_DEVICE_NAME" = "fixture-mac"
        if test -f "$HOME/ask-to-star"; then
          printf '%s\n' "$answer" > "$HOME/star-answer"
          printf 'Star skipped.\nFixture submission completed.\n'
        else
          printf 'No data to submit.\n'
        fi
        ;;
      login)
        test -z "$TOKSCALE_DEVICE_NAME"
        answer=
        if IFS= read -r answer || test -n "$answer"; then
          printf 'Expected immediate EOF for login.\n' >&2
          exit 75
        fi
        printf 'login:EOF\n' >> "$HOME/input-events"
        /bin/sleep 30 &
        printf '%s\n' "$!" > "$HOME/child.pid"
        printf 'Visit https://example.invalid/verify FIXTURE-CODE\n'
        while test ! -f "$HOME/approve"; do /bin/sleep 0.02; done
        /usr/bin/touch "$HOME/authenticated"
        printf 'Login complete.\n'
        ;;
      *) exit 71 ;;
    esac
    """#
}
