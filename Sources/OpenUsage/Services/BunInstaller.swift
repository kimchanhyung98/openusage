import Darwin
import Foundation

struct BunRuntime: Sendable, Equatable {
    let bunURL: URL
    let bunxURL: URL
    let executionPath: String
}

enum BunAvailability: Sendable, Equatable {
    case available(BunRuntime)
    case missing
    case bunxMissing
}

protocol BunInstalling: Sendable {
    func availability() async throws -> BunAvailability
    func install(onOutput: @escaping @Sendable (String) -> Void) async throws -> BunRuntime
}

enum BunInstallerError: Error, LocalizedError, Equatable {
    case unsafeInstallDirectory
    case existingBunWithoutBunx
    case installationInProgress
    case downloadFailed
    case invalidHTTPResponse
    case unexpectedHTTPStatus(Int)
    case disallowedRedirect
    case emptyInstaller
    case installerTooLarge
    case invalidInstaller
    case temporaryWorkspaceFailed
    case installerFailed(Int32)
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .unsafeInstallDirectory:
            "BUN_INSTALL must be a shell-safe absolute directory inside your home folder."
        case .existingBunWithoutBunx:
            "Bun is installed, but bunx is unavailable. Repair the existing Bun installation and try again."
        case .installationInProgress:
            "Bun installation is already in progress."
        case .downloadFailed:
            "Bun could not be downloaded. Check your connection and try again."
        case .invalidHTTPResponse:
            "The Bun installer returned an invalid response."
        case .unexpectedHTTPStatus(let status):
            "The Bun installer returned HTTP status \(status)."
        case .disallowedRedirect:
            "The Bun installer redirected to an unsupported address."
        case .emptyInstaller, .invalidInstaller:
            "The downloaded Bun installer is invalid."
        case .installerTooLarge:
            "The downloaded Bun installer is unexpectedly large."
        case .temporaryWorkspaceFailed:
            "A private workspace for the Bun installer could not be created."
        case .installerFailed(let exitCode):
            "Bun installation exited with status \(exitCode)."
        case .verificationFailed:
            "Bun installation finished, but Bun and bunx could not be verified."
        }
    }
}

struct BunInstallerDownload: Sendable, Equatable {
    let data: Data
    let statusCode: Int
    let finalURL: URL
}

protocol BunInstallerDownloading: Sendable {
    func download(from url: URL, maximumBytes: Int) async throws -> BunInstallerDownload
}

struct URLSessionBunInstallerDownloader: BunInstallerDownloading {
    func download(from url: URL, maximumBytes: Int) async throws -> BunInstallerDownload {
        let redirectDelegate = BunInstallerRedirectDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30

        let session = URLSession(configuration: configuration, delegate: redirectDelegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("text/plain", forHTTPHeaderField: "Accept")

        let (bytes, response) = try await session.bytes(for: request)
        if redirectDelegate.blockedRedirect {
            throw BunInstallerError.disallowedRedirect
        }
        guard let response = response as? HTTPURLResponse else {
            throw BunInstallerError.invalidHTTPResponse
        }
        let finalURL = response.url ?? url
        guard BunInstallerRedirectDelegate.isAllowed(finalURL) else {
            throw BunInstallerError.disallowedRedirect
        }
        guard response.statusCode == 200 else {
            throw BunInstallerError.unexpectedHTTPStatus(response.statusCode)
        }
        guard response.expectedContentLength < 0
                || response.expectedContentLength <= Int64(maximumBytes)
        else {
            throw BunInstallerError.installerTooLarge
        }

        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(Int(response.expectedContentLength))
        }
        for try await byte in bytes {
            guard data.count < maximumBytes else {
                throw BunInstallerError.installerTooLarge
            }
            data.append(byte)
        }
        return BunInstallerDownload(data: data, statusCode: response.statusCode, finalURL: finalURL)
    }
}

final class BunInstallerRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private static let allowedHosts = Set(["bun.com", "www.bun.com", "bun.sh", "www.bun.sh"])
    private let lock = NSLock()
    private var didBlockRedirect = false

    var blockedRedirect: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didBlockRedirect
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, Self.isAllowed(url) else {
            lock.lock()
            didBlockRedirect = true
            lock.unlock()
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              allowedHosts.contains(host),
              url.port == nil || url.port == 443
        else { return false }
        return true
    }
}

actor BunInstaller: BunInstalling {
    static let installerURL = URL(string: "https://bun.com/install")!
    static let maximumInstallerBytes = 1_048_576
    static let installerTimeout: TimeInterval = 5 * 60
    static let verificationTimeout: TimeInterval = 10
    static let outputLimit = 64 * 1024

    private static let systemPathDirectories = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    private static let installerNetworkEnvironmentKeys = [
        "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
        "http_proxy", "https_proxy", "all_proxy", "no_proxy",
        "SSL_CERT_FILE", "SSL_CERT_DIR",
    ]
    private static let automaticInstallPathCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
    )
    private static let supportedInstallerShells = Set(["bash", "fish", "zsh"])

    private let processRunner: any StreamingProcessRunning
    private let downloader: any BunInstallerDownloading
    private let processEnvironment: [String: String]
    private let loginShellValue: @Sendable (String) -> String?
    private let homeDirectoryURL: URL
    private let temporaryDirectoryURL: URL
    private let fileManager: FileManager
    private var isInstalling = false

    init(
        processRunner: any StreamingProcessRunning = StreamingProcessRunner(),
        downloader: any BunInstallerDownloading = URLSessionBunInstallerDownloader(),
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        loginShellValue: @escaping @Sendable (String) -> String? = {
            LoginShellEnvironment.shared.value(for: $0)
        },
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        temporaryDirectoryURL: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) {
        self.processRunner = processRunner
        self.downloader = downloader
        self.processEnvironment = processEnvironment
        self.loginShellValue = loginShellValue
        self.homeDirectoryURL = homeDirectoryURL
        self.temporaryDirectoryURL = temporaryDirectoryURL
        self.fileManager = fileManager
    }

    func availability() async throws -> BunAvailability {
        var foundBun = false
        for directory in pathDirectories() {
            if let runtime = runtime(in: directory) { return .available(runtime) }
            foundBun = foundBun || hasExecutable(named: "bun", in: directory)
        }

        var installRoots: [URL] = []
        if let configured = try configuredDiscoveryRoot() {
            installRoots.append(configured)
        }
        let defaultRoot = try validatedAutomaticInstallRoot(homeDirectoryURL.appendingPathComponent(".bun").path)
        if !installRoots.contains(defaultRoot) {
            installRoots.append(defaultRoot)
        }

        for root in installRoots {
            let directory = root.appendingPathComponent("bin", isDirectory: true)
            if let runtime = runtime(in: directory) { return .available(runtime) }
            foundBun = foundBun || hasExecutable(named: "bun", in: directory)
        }
        return foundBun ? .bunxMissing : .missing
    }

    func install(onOutput: @escaping @Sendable (String) -> Void) async throws -> BunRuntime {
        guard !isInstalling else { throw BunInstallerError.installationInProgress }
        isInstalling = true
        defer { isInstalling = false }

        switch try await availability() {
        case .available(let runtime):
            return runtime
        case .bunxMissing:
            throw BunInstallerError.existingBunWithoutBunx
        case .missing:
            break
        }

        let installRoot = try configuredAutomaticInstallRoot()
            ?? validatedAutomaticInstallRoot(homeDirectoryURL.appendingPathComponent(".bun").path)
        let download: BunInstallerDownload
        do {
            download = try await downloader.download(
                from: Self.installerURL,
                maximumBytes: Self.maximumInstallerBytes
            )
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let error = error as? BunInstallerError { throw error }
            throw BunInstallerError.downloadFailed
        }
        try validate(download)

        let workspace = try makePrivateWorkspace()
        defer { try? fileManager.removeItem(at: workspace) }
        let scriptURL = workspace.appendingPathComponent("install.sh", isDirectory: false)
        do {
            try writePrivateFile(download.data, to: scriptURL)
        } catch {
            throw BunInstallerError.temporaryWorkspaceFailed
        }

        let environment = installerEnvironment(installRoot: installRoot)
        let installRequest = StreamingProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: ["--noprofile", "--norc", scriptURL.path],
            environment: environment,
            currentDirectoryURL: workspace,
            timeout: Self.installerTimeout,
            outputLimit: Self.outputLimit
        )
        let installResult = try await processRunner.run(installRequest, onOutput: onOutput)
        guard installResult.exitCode == 0 else {
            throw BunInstallerError.installerFailed(installResult.exitCode)
        }

        let binDirectory = installRoot.appendingPathComponent("bin", isDirectory: true)
        guard let runtime = runtime(in: binDirectory) else {
            throw BunInstallerError.verificationFailed
        }
        try await verify(runtime.bunURL, environment: verificationEnvironment(environment, runtime: runtime), in: workspace)
        try await verify(runtime.bunxURL, environment: verificationEnvironment(environment, runtime: runtime), in: workspace)
        return runtime
    }

    private func pathDirectories() -> [URL] {
        var result: [URL] = []
        appendPathDirectories(processEnvironment["PATH"], to: &result)
        appendPathDirectories(loginShellValue("PATH"), to: &result)
        return result
    }

    private func appendPathDirectories(_ path: String?, to result: inout [URL]) {
        guard let path else { return }
        for component in path.split(separator: ":", omittingEmptySubsequences: false).map(String.init) {
            guard let directory = safeAbsoluteDirectory(component), !result.contains(directory) else { continue }
            result.append(directory)
        }
    }

    private func safeAbsoluteDirectory(_ path: String) -> URL? {
        guard !path.isEmpty,
              (path as NSString).isAbsolutePath,
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    private func configuredDiscoveryRoot() throws -> URL? {
        if let value = nonempty(processEnvironment["BUN_INSTALL"]) {
            return try absoluteDirectory(value)
        }
        if let value = nonempty(loginShellValue("BUN_INSTALL")) {
            return try absoluteDirectory(value)
        }
        return nil
    }

    private func configuredAutomaticInstallRoot() throws -> URL? {
        guard let configured = try configuredDiscoveryRoot() else { return nil }
        return try validatedAutomaticInstallRoot(configured.path)
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private func absoluteDirectory(_ path: String) throws -> URL {
        guard let candidate = safeAbsoluteDirectory(path) else {
            throw BunInstallerError.unsafeInstallDirectory
        }
        return candidate
    }

    private func validatedAutomaticInstallRoot(_ path: String) throws -> URL {
        let candidate = try absoluteDirectory(path)
        let home = resolvedHomeDirectoryURL
        let resolvedCandidate = try resolvingExistingInstallAncestor(candidate)
        let homeComponents = home.pathComponents
        let candidateComponents = resolvedCandidate.pathComponents
        guard candidateComponents.count > homeComponents.count,
              candidateComponents.starts(with: homeComponents),
              candidateComponents.dropFirst(homeComponents.count).allSatisfy({ component in
                  !component.isEmpty && component.unicodeScalars.allSatisfy {
                      Self.automaticInstallPathCharacters.contains($0)
                  }
              })
        else { throw BunInstallerError.unsafeInstallDirectory }
        return resolvedCandidate
    }

    private func resolvingExistingInstallAncestor(_ candidate: URL) throws -> URL {
        var ancestor = candidate
        var missingComponents: [String] = []
        var metadata = stat()
        // 미생성 하위 경로는 분리하고 실제 존재하는 조상부터 해석. 끊어진 링크는 미생성 폴더로 취급하지 않음.
        while ancestor.path.withCString({ Darwin.lstat($0, &metadata) }) != 0 {
            guard errno == ENOENT, ancestor.pathComponents.count > 1 else {
                throw BunInstallerError.unsafeInstallDirectory
            }
            missingComponents.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        guard let path = ancestor.path.withCString({ Darwin.realpath($0, nil) }) else {
            throw BunInstallerError.unsafeInstallDirectory
        }
        defer { free(path) }
        var resolved = URL(fileURLWithPath: String(cString: path), isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw BunInstallerError.unsafeInstallDirectory
        }
        for component in missingComponents.reversed() {
            resolved.appendPathComponent(component, isDirectory: true)
        }
        return resolved
    }

    private var resolvedHomeDirectoryURL: URL {
        homeDirectoryURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func runtime(in directory: URL) -> BunRuntime? {
        let bunURL = directory.appendingPathComponent("bun", isDirectory: false)
        let bunxURL = directory.appendingPathComponent("bunx", isDirectory: false)
        guard isExecutableFile(bunURL), isExecutableFile(bunxURL) else { return nil }
        return BunRuntime(
            bunURL: bunURL,
            bunxURL: bunxURL,
            executionPath: Self.executionPath(appending: directory.path)
        )
    }

    private func hasExecutable(named name: String, in directory: URL) -> Bool {
        isExecutableFile(directory.appendingPathComponent(name, isDirectory: false))
    }

    private func isExecutableFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else { return false }
        return fileManager.isExecutableFile(atPath: url.path)
    }

    private static func executionPath(appending directory: String) -> String {
        var directories = systemPathDirectories
        if !directories.contains(directory) {
            directories.append(directory)
        }
        return directories.joined(separator: ":")
    }

    private func validate(_ download: BunInstallerDownload) throws {
        guard download.statusCode == 200 else {
            throw BunInstallerError.unexpectedHTTPStatus(download.statusCode)
        }
        guard BunInstallerRedirectDelegate.isAllowed(download.finalURL) else {
            throw BunInstallerError.disallowedRedirect
        }
        guard !download.data.isEmpty else { throw BunInstallerError.emptyInstaller }
        guard download.data.count <= Self.maximumInstallerBytes else {
            throw BunInstallerError.installerTooLarge
        }
        guard let script = String(data: download.data, encoding: .utf8),
              let firstLine = script.split(whereSeparator: \Character.isNewline).first,
              firstLine.hasPrefix("#!"),
              firstLine.lowercased().contains("bash")
        else { throw BunInstallerError.invalidInstaller }
    }

    private func installerEnvironment(installRoot: URL) -> [String: String] {
        var environment: [String: String] = [:]
        for key in Self.installerNetworkEnvironmentKeys {
            if let value = nonempty(processEnvironment[key]) ?? nonempty(loginShellValue(key)) {
                environment[key] = value
            }
        }
        environment["HOME"] = resolvedHomeDirectoryURL.path
        environment["BUN_INSTALL"] = installRoot.path
        environment["PATH"] = Self.systemPathDirectories.joined(separator: ":")
        environment["SHELL"] = validatedShell()
        environment["GITHUB"] = "https://github.com"
        return environment
    }

    private func verificationEnvironment(_ environment: [String: String], runtime: BunRuntime) -> [String: String] {
        var environment = environment
        environment["PATH"] = runtime.executionPath
        return environment
    }

    private func verify(_ executableURL: URL, environment: [String: String], in workspace: URL) async throws {
        let request = StreamingProcessRequest(
            executableURL: executableURL,
            arguments: ["--version"],
            environment: environment,
            currentDirectoryURL: workspace,
            timeout: Self.verificationTimeout,
            outputLimit: 4 * 1024
        )
        let result = try await processRunner.run(request, onOutput: { _ in })
        guard result.exitCode == 0,
              !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw BunInstallerError.verificationFailed }
    }

    private func validatedShell() -> String {
        let candidates = [processEnvironment["SHELL"], loginShellValue("SHELL"), "/bin/zsh"]
        for candidate in candidates {
            guard let candidate,
                  let url = safeAbsoluteDirectory(candidate),
                  Self.supportedInstallerShells.contains(url.lastPathComponent.lowercased()),
                  isExecutableFile(url)
            else { continue }
            return url.path
        }
        return "/bin/bash"
    }

    private func makePrivateWorkspace() throws -> URL {
        let base = temporaryDirectoryURL.standardizedFileURL
        guard base.isFileURL, (base.path as NSString).isAbsolutePath else {
            throw BunInstallerError.temporaryWorkspaceFailed
        }
        var template = Array(base.appendingPathComponent("OpenUsage-BunInstaller.XXXXXX").path.utf8CString)
        let path = template.withUnsafeMutableBufferPointer { buffer -> String? in
            guard let address = buffer.baseAddress, let created = Darwin.mkdtemp(address) else { return nil }
            return String(cString: created)
        }
        guard let path else { throw BunInstallerError.temporaryWorkspaceFailed }
        let chmodResult = path.withCString { Darwin.chmod($0, S_IRWXU) }
        guard chmodResult == 0 else {
            try? fileManager.removeItem(atPath: path)
            throw BunInstallerError.temporaryWorkspaceFailed
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func writePrivateFile(_ data: Data, to url: URL) throws {
        let mode = mode_t(S_IRUSR | S_IWUSR)
        let descriptor = url.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode)
        }
        guard descriptor >= 0 else { throw currentPOSIXError() }
        var isOpen = true
        defer {
            if isOpen { _ = Darwin.close(descriptor) }
            if isOpen { url.path.withCString { _ = Darwin.unlink($0) } }
        }
        guard Darwin.fchmod(descriptor, mode) == 0 else { throw currentPOSIXError() }
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, baseAddress.advanced(by: offset), buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw currentPOSIXError()
                }
                guard written > 0 else { throw POSIXError(.EIO) }
                offset += written
            }
        }
        guard Darwin.fsync(descriptor) == 0 else { throw currentPOSIXError() }
        guard Darwin.close(descriptor) == 0 else { throw currentPOSIXError() }
        isOpen = false
    }

    private func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
