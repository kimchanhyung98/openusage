import XCTest
@testable import OpenUsage

@MainActor
final class BunInstallerTests: XCTestCase {
    private var temporaryRoots: [URL] = []

    override func tearDown() {
        for root in temporaryRoots {
            try? FileManager.default.removeItem(at: root)
        }
        temporaryRoots.removeAll()
        super.tearDown()
    }

    func testAvailabilityFindsBunAndBunxTogetherOnProcessPath() async throws {
        let fixture = try makeFixture()
        let processBin = fixture.root.appendingPathComponent("process-bin", isDirectory: true)
        try makeExecutable(processBin.appendingPathComponent("bun"))
        try makeExecutable(processBin.appendingPathComponent("bunx"))
        let downloader = BunDownloadStub(download: validDownload())
        let runner = BunProcessStub()
        let installer = makeInstaller(
            fixture: fixture,
            runner: runner,
            downloader: downloader,
            processEnvironment: ["PATH": processBin.path]
        )

        let availability = try await installer.availability()

        guard case .available(let runtime) = availability else {
            return XCTFail("Expected an available Bun runtime")
        }
        XCTAssertEqual(runtime.bunURL, processBin.appendingPathComponent("bun"))
        XCTAssertEqual(runtime.bunxURL, processBin.appendingPathComponent("bunx"))
        XCTAssertEqual(runtime.executionPath, "/usr/bin:/bin:/usr/sbin:/sbin:\(processBin.path)")
        let installedRuntime = try await installer.install(onOutput: { _ in })
        XCTAssertEqual(installedRuntime, runtime)
        XCTAssertEqual(downloader.callCount, 0)
        XCTAssertTrue(runner.requests.isEmpty)
    }

    func testAvailabilitySearchesLoginShellPathAndIgnoresRelativeAndEmptyEntries() async throws {
        let fixture = try makeFixture()
        let shellBin = fixture.root.appendingPathComponent("shell-bin", isDirectory: true)
        try makeExecutable(shellBin.appendingPathComponent("bun"))
        try makeExecutable(shellBin.appendingPathComponent("bunx"))
        let installer = makeInstaller(
            fixture: fixture,
            processEnvironment: ["PATH": "relative::"],
            shellEnvironment: ["PATH": "also-relative::\(shellBin.path)"]
        )

        guard case .available(let runtime) = try await installer.availability() else {
            return XCTFail("Expected the login-shell runtime")
        }
        XCTAssertEqual(runtime.bunURL.deletingLastPathComponent(), shellBin)
    }

    func testAvailabilitySearchesConfiguredInstallDirectory() async throws {
        let fixture = try makeFixture()
        let installRoot = fixture.root.appendingPathComponent("existing-tools/bun", isDirectory: true)
        let bin = installRoot.appendingPathComponent("bin", isDirectory: true)
        try makeExecutable(bin.appendingPathComponent("bun"))
        try makeExecutable(bin.appendingPathComponent("bunx"))
        let installer = makeInstaller(
            fixture: fixture,
            processEnvironment: ["BUN_INSTALL": installRoot.path]
        )

        guard case .available(let runtime) = try await installer.availability() else {
            return XCTFail("Expected the configured runtime")
        }
        XCTAssertEqual(runtime.bunURL, bin.appendingPathComponent("bun"))
    }

    func testBunWithoutSameDirectoryBunxDoesNotInstall() async throws {
        let fixture = try makeFixture()
        let bin = fixture.root.appendingPathComponent("bin", isDirectory: true)
        try makeExecutable(bin.appendingPathComponent("bun"))
        let downloader = BunDownloadStub(download: validDownload())
        let runner = BunProcessStub()
        let installer = makeInstaller(
            fixture: fixture,
            runner: runner,
            downloader: downloader,
            processEnvironment: ["PATH": bin.path]
        )

        let availability = try await installer.availability()
        XCTAssertEqual(availability, .bunxMissing)
        do {
            _ = try await installer.install(onOutput: { _ in })
            XCTFail("Expected the incomplete installation to be preserved")
        } catch {
            XCTAssertEqual(error as? BunInstallerError, .existingBunWithoutBunx)
        }
        XCTAssertEqual(downloader.callCount, 0)
        XCTAssertTrue(runner.requests.isEmpty)
    }

    func testInstallUsesExactRequestPrivateFilesNetworkEnvironmentAndPostVerification() async throws {
        let fixture = try makeFixture()
        let installRoot = fixture.home.appendingPathComponent("managed-bun", isDirectory: true)
        let downloader = BunDownloadStub(download: validDownload())
        let runner = BunProcessStub(createRuntimeOnInstall: true)
        let installer = makeInstaller(
            fixture: fixture,
            runner: runner,
            downloader: downloader,
            processEnvironment: [
                "BUN_INSTALL": installRoot.path,
                "PATH": "/untrusted/bin",
                "SHELL": "/bin/zsh",
                "HTTPS_PROXY": "https://process-proxy.example",
                "SSL_CERT_FILE": "/certs/process.pem",
                "BASH_ENV": "/secret/bootstrap",
                "TOKSCALE_API_TOKEN": "secret",
            ],
            shellEnvironment: [
                "HTTPS_PROXY": "https://shell-proxy.example",
                "NO_PROXY": "localhost,127.0.0.1",
                "SSL_CERT_DIR": "/certs/shell",
            ]
        )

        let runtime = try await installer.install(onOutput: { _ in })

        XCTAssertEqual(downloader.callCount, 1)
        XCTAssertEqual(downloader.requestedURL, BunInstaller.installerURL)
        XCTAssertEqual(downloader.maximumBytes, BunInstaller.maximumInstallerBytes)
        XCTAssertEqual(runtime.bunURL, installRoot.appendingPathComponent("bin/bun"))
        XCTAssertEqual(runtime.bunxURL, installRoot.appendingPathComponent("bin/bunx"))

        let requests = runner.requests
        XCTAssertEqual(requests.count, 3)
        let installRequest = requests[0]
        XCTAssertEqual(installRequest.executableURL.path, "/bin/bash")
        XCTAssertEqual(Array(installRequest.arguments.prefix(2)), ["--noprofile", "--norc"])
        XCTAssertEqual(installRequest.arguments.count, 3)
        XCTAssertNotEqual(installRequest.arguments[2], "-c")
        XCTAssertEqual(installRequest.currentDirectoryURL, runner.installObservation?.workspaceURL)
        XCTAssertEqual(runner.installObservation?.workspacePermissions, 0o700)
        XCTAssertEqual(runner.installObservation?.scriptPermissions, 0o600)
        XCTAssertEqual(
            installRequest.environment,
            [
                "HOME": fixture.home.path,
                "BUN_INSTALL": installRoot.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "SHELL": "/bin/zsh",
                "GITHUB": "https://github.com",
                "HTTPS_PROXY": "https://process-proxy.example",
                "NO_PROXY": "localhost,127.0.0.1",
                "SSL_CERT_FILE": "/certs/process.pem",
                "SSL_CERT_DIR": "/certs/shell",
            ]
        )
        XCTAssertNil(installRequest.environment["BASH_ENV"])
        XCTAssertNil(installRequest.environment["TOKSCALE_API_TOKEN"])

        let verifyRequest = requests[1]
        XCTAssertEqual(verifyRequest.executableURL, runtime.bunURL)
        XCTAssertEqual(verifyRequest.arguments, ["--version"])
        XCTAssertEqual(verifyRequest.outputLimit, 4 * 1024)
        XCTAssertEqual(verifyRequest.environment["PATH"], runtime.executionPath)
        XCTAssertEqual(requests[2].executableURL, runtime.bunxURL)
        XCTAssertEqual(requests[2].arguments, ["--version"])
        let observation = try XCTUnwrap(runner.installObservation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: observation.workspaceURL.path))
    }

    func testInstallUsesDefaultHomeBunDirectory() async throws {
        let fixture = try makeFixture()
        let downloader = BunDownloadStub(download: validDownload())
        let runner = BunProcessStub(createRuntimeOnInstall: true)
        let installer = makeInstaller(fixture: fixture, runner: runner, downloader: downloader)

        let runtime = try await installer.install(onOutput: { _ in })

        let expectedRoot = fixture.home.appendingPathComponent(".bun", isDirectory: true)
        XCTAssertEqual(runtime.bunxURL, expectedRoot.appendingPathComponent("bin/bunx"))
        XCTAssertEqual(runner.requests.first?.environment["BUN_INSTALL"], expectedRoot.path)
    }

    func testUnsafeConfiguredInstallDirectoriesFailBeforeDownload() async throws {
        let fixture = try makeFixture()
        let outside = fixture.root.appendingPathComponent("symlink-target", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = fixture.home.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let paths = [
            "relative/bun",
            fixture.root.appendingPathComponent("outside").path,
            fixture.home.path,
            fixture.home.appendingPathComponent("dollar$path").path,
            fixture.home.appendingPathComponent("back`tick").path,
            fixture.home.appendingPathComponent("back\\slash").path,
            fixture.home.appendingPathComponent("double\"quote").path,
            fixture.home.appendingPathComponent("bang!path").path,
            fixture.home.appendingPathComponent("single'quote").path,
            fixture.home.appendingPathComponent("semi;colon").path,
            fixture.home.appendingPathComponent("space path").path,
            fixture.home.appendingPathComponent("amp&path").path,
            fixture.home.appendingPathComponent("pipe|path").path,
            fixture.home.appendingPathComponent("glob*path").path,
            fixture.home.appendingPathComponent("(subshell)").path,
            fixture.home.appendingPathComponent("new\nline").path,
            link.appendingPathComponent("bun").path,
        ]
        for path in paths {
            let downloader = BunDownloadStub(download: validDownload())
            let installer = makeInstaller(
                fixture: fixture,
                downloader: downloader,
                processEnvironment: ["BUN_INSTALL": path]
            )

            do {
                _ = try await installer.install(onOutput: { _ in })
                XCTFail("Expected unsafe BUN_INSTALL to fail: \(path)")
            } catch {
                XCTAssertEqual(error as? BunInstallerError, .unsafeInstallDirectory)
            }
            XCTAssertEqual(downloader.callCount, 0)
        }
    }

    func testRejectsInvalidDownloadBoundariesBeforeWritingOrRunning() async throws {
        let fixture = try makeFixture()
        let oversized = Data(repeating: 0x61, count: BunInstaller.maximumInstallerBytes + 1)
        let cases: [(BunInstallerDownload, BunInstallerError)] = [
            (.init(data: validInstallerData, statusCode: 503, finalURL: BunInstaller.installerURL), .unexpectedHTTPStatus(503)),
            (.init(data: Data(), statusCode: 200, finalURL: BunInstaller.installerURL), .emptyInstaller),
            (.init(data: Data([0xFF]), statusCode: 200, finalURL: BunInstaller.installerURL), .invalidInstaller),
            (.init(data: oversized, statusCode: 200, finalURL: BunInstaller.installerURL), .installerTooLarge),
            (.init(data: Data("plain text".utf8), statusCode: 200, finalURL: BunInstaller.installerURL), .invalidInstaller),
            (.init(data: validInstallerData, statusCode: 200, finalURL: URL(string: "https://example.com/install")!), .disallowedRedirect),
        ]

        for (download, expectedError) in cases {
            let runner = BunProcessStub()
            let installer = makeInstaller(
                fixture: fixture,
                runner: runner,
                downloader: BunDownloadStub(download: download)
            )
            do {
                _ = try await installer.install(onOutput: { _ in })
                XCTFail("Expected invalid installer response to fail")
            } catch {
                XCTAssertEqual(error as? BunInstallerError, expectedError)
            }
            XCTAssertTrue(runner.requests.isEmpty)
        }
    }

    func testDownloadTransportFailureIsMappedWithoutSensitiveDetails() async throws {
        let fixture = try makeFixture()
        let downloader = BunDownloadStub(error: TestFailure.secret("token-value"))
        let installer = makeInstaller(fixture: fixture, downloader: downloader)

        do {
            _ = try await installer.install(onOutput: { _ in })
            XCTFail("Expected download failure")
        } catch {
            XCTAssertEqual(error as? BunInstallerError, .downloadFailed)
            XCTAssertFalse(error.localizedDescription.contains("token-value"))
        }
    }

    func testNonzeroInstallerExitCleansOnlyPrivateWorkspace() async throws {
        let fixture = try makeFixture()
        let sentinel = fixture.root.appendingPathComponent("sentinel")
        try Data("keep".utf8).write(to: sentinel)
        let runner = BunProcessStub(installExitCode: 17)
        let installer = makeInstaller(
            fixture: fixture,
            runner: runner,
            downloader: BunDownloadStub(download: validDownload())
        )

        do {
            _ = try await installer.install(onOutput: { _ in })
            XCTFail("Expected installer failure")
        } catch {
            XCTAssertEqual(error as? BunInstallerError, .installerFailed(17))
        }
        let workspace = try XCTUnwrap(runner.installObservation?.workspaceURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
    }

    func testExitZeroWithoutRuntimeFailsPostVerificationAndCleansWorkspace() async throws {
        let fixture = try makeFixture()
        let runner = BunProcessStub(createRuntimeOnInstall: false)
        let installer = makeInstaller(
            fixture: fixture,
            runner: runner,
            downloader: BunDownloadStub(download: validDownload())
        )

        do {
            _ = try await installer.install(onOutput: { _ in })
            XCTFail("Expected post-install verification failure")
        } catch {
            XCTAssertEqual(error as? BunInstallerError, .verificationFailed)
        }
        let workspace = try XCTUnwrap(runner.installObservation?.workspaceURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path))
    }

    func testVersionCommandMustSucceedAndReturnOutput() async throws {
        let fixture = try makeFixture()
        for result in [
            StreamingProcessResult(exitCode: 1, output: "failure"),
            StreamingProcessResult(exitCode: 0, output: "  \n"),
        ] {
            let runner = BunProcessStub(createRuntimeOnInstall: true, verificationResult: result)
            let installer = makeInstaller(
                fixture: fixture,
                runner: runner,
                downloader: BunDownloadStub(download: validDownload())
            )
            do {
                _ = try await installer.install(onOutput: { _ in })
                XCTFail("Expected version verification failure")
            } catch {
                XCTAssertEqual(error as? BunInstallerError, .verificationFailed)
            }
            try? FileManager.default.removeItem(at: fixture.home.appendingPathComponent(".bun"))
        }
    }

    func testBunxVersionCommandMustSucceed() async throws {
        let fixture = try makeFixture()
        let runner = BunProcessStub(
            createRuntimeOnInstall: true,
            bunxVerificationResult: .init(exitCode: 1, output: "failure")
        )
        let installer = makeInstaller(
            fixture: fixture,
            runner: runner,
            downloader: BunDownloadStub(download: validDownload())
        )

        do {
            _ = try await installer.install(onOutput: { _ in })
            XCTFail("Expected bunx verification failure")
        } catch {
            XCTAssertEqual(error as? BunInstallerError, .verificationFailed)
        }
        XCTAssertEqual(runner.requests.last?.executableURL.lastPathComponent, "bunx")
    }

    func testUnsupportedLoginShellFallsBackToZshForBunxSetup() async throws {
        let fixture = try makeFixture()
        let unsupportedShell = fixture.root.appendingPathComponent("nu")
        try makeExecutable(unsupportedShell)
        let runner = BunProcessStub(createRuntimeOnInstall: true)
        let installer = makeInstaller(
            fixture: fixture,
            runner: runner,
            downloader: BunDownloadStub(download: validDownload()),
            processEnvironment: ["SHELL": unsupportedShell.path]
        )

        _ = try await installer.install(onOutput: { _ in })

        XCTAssertEqual(runner.requests.first?.environment["SHELL"], "/bin/zsh")
    }

    func testRedirectAllowlistRequiresOfficialHTTPSHostsAndPort() {
        XCTAssertTrue(BunInstallerRedirectDelegate.isAllowed(URL(string: "https://bun.com/install")!))
        XCTAssertTrue(BunInstallerRedirectDelegate.isAllowed(URL(string: "https://bun.sh/install")!))
        XCTAssertTrue(BunInstallerRedirectDelegate.isAllowed(URL(string: "https://www.bun.com/install")!))
        XCTAssertFalse(BunInstallerRedirectDelegate.isAllowed(URL(string: "http://bun.com/install")!))
        XCTAssertFalse(BunInstallerRedirectDelegate.isAllowed(URL(string: "https://bun.com.evil.test/install")!))
        XCTAssertFalse(BunInstallerRedirectDelegate.isAllowed(URL(string: "https://bun.com:444/install")!))
    }

    private var validInstallerData: Data {
        Data("#!/usr/bin/env bash\necho installing bun\n".utf8)
    }

    private func validDownload() -> BunInstallerDownload {
        BunInstallerDownload(data: validInstallerData, statusCode: 200, finalURL: BunInstaller.installerURL)
    }

    private func makeFixture() throws -> BunFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsage-BunInstallerTests-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let temporary = root.appendingPathComponent("temporary", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        temporaryRoots.append(root)
        return BunFixture(root: root, home: home, temporary: temporary)
    }

    private func makeInstaller(
        fixture: BunFixture,
        runner: any StreamingProcessRunning = BunProcessStub(),
        downloader: any BunInstallerDownloading = BunDownloadStub(
            download: BunInstallerDownload(
                data: Data("#!/usr/bin/env bash\necho installing bun\n".utf8),
                statusCode: 200,
                finalURL: BunInstaller.installerURL
            )
        ),
        processEnvironment: [String: String] = [:],
        shellEnvironment: [String: String] = [:]
    ) -> BunInstaller {
        BunInstaller(
            processRunner: runner,
            downloader: downloader,
            processEnvironment: processEnvironment,
            loginShellValue: { shellEnvironment[$0] },
            homeDirectoryURL: fixture.home,
            temporaryDirectoryURL: fixture.temporary
        )
    }

    private func makeExecutable(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}

private struct BunFixture {
    let root: URL
    let home: URL
    let temporary: URL
}

private enum TestFailure: Error {
    case secret(String)
    case missingValue
}

private final class BunDownloadStub: BunInstallerDownloading, @unchecked Sendable {
    private let lock = NSLock()
    private let downloadResult: Result<BunInstallerDownload, Error>
    private var calls: [(URL, Int)] = []

    init(download: BunInstallerDownload) {
        self.downloadResult = .success(download)
    }

    init(error: Error) {
        self.downloadResult = .failure(error)
    }

    var callCount: Int { synchronized { calls.count } }
    var requestedURL: URL? { synchronized { calls.last?.0 } }
    var maximumBytes: Int? { synchronized { calls.last?.1 } }

    func download(from url: URL, maximumBytes: Int) async throws -> BunInstallerDownload {
        synchronized { calls.append((url, maximumBytes)) }
        return try downloadResult.get()
    }

    private func synchronized<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class BunProcessStub: StreamingProcessRunning, @unchecked Sendable {
    struct InstallObservation: Sendable {
        let workspaceURL: URL
        let workspacePermissions: Int
        let scriptPermissions: Int
    }

    private let lock = NSLock()
    private let installExitCode: Int32
    private let createRuntimeOnInstall: Bool
    private let verificationResult: StreamingProcessResult
    private let bunxVerificationResult: StreamingProcessResult
    private var recordedRequests: [StreamingProcessRequest] = []
    private var recordedObservation: InstallObservation?

    init(
        installExitCode: Int32 = 0,
        createRuntimeOnInstall: Bool = false,
        verificationResult: StreamingProcessResult = .init(exitCode: 0, output: "1.4.0\n"),
        bunxVerificationResult: StreamingProcessResult? = nil
    ) {
        self.installExitCode = installExitCode
        self.createRuntimeOnInstall = createRuntimeOnInstall
        self.verificationResult = verificationResult
        self.bunxVerificationResult = bunxVerificationResult ?? verificationResult
    }

    var requests: [StreamingProcessRequest] { synchronized { recordedRequests } }
    var installObservation: InstallObservation? { synchronized { recordedObservation } }

    func run(
        _ request: StreamingProcessRequest,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> StreamingProcessResult {
        record(request)
        if request.executableURL.path == "/bin/bash" {
            try observeInstallerRequest(request)
            if createRuntimeOnInstall, installExitCode == 0 {
                try createRuntime(installRoot: request.environment["BUN_INSTALL"])
            }
            let result = StreamingProcessResult(exitCode: installExitCode, output: "installer output")
            onOutput(result.output)
            return result
        }
        let result = request.executableURL.lastPathComponent == "bunx"
            ? bunxVerificationResult
            : verificationResult
        onOutput(result.output)
        return result
    }

    private func record(_ request: StreamingProcessRequest) {
        synchronized { recordedRequests.append(request) }
    }

    private func observeInstallerRequest(_ request: StreamingProcessRequest) throws {
        guard let workspace = request.currentDirectoryURL, let scriptPath = request.arguments.last else {
            throw TestFailure.missingValue
        }
        let observation = InstallObservation(
            workspaceURL: workspace,
            workspacePermissions: try permissions(at: workspace.path),
            scriptPermissions: try permissions(at: scriptPath)
        )
        synchronized { recordedObservation = observation }
    }

    private func createRuntime(installRoot: String?) throws {
        guard let root = installRoot else { throw TestFailure.missingValue }
        let bin = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in ["bun", "bunx"] {
            let url = bin.appendingPathComponent(name)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    private func permissions(at path: String) throws -> Int {
        guard let value = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        else { throw TestFailure.missingValue }
        return value.intValue & 0o777
    }

    private func synchronized<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
