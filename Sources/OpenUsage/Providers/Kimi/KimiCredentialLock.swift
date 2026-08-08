import Darwin
import Foundation

actor KimiCredentialLock {
    struct Configuration: Sendable, Equatable {
        var staleInterval: TimeInterval
        var heartbeatInterval: TimeInterval
        var acquisitionBudget: TimeInterval
        var retryDelay: TimeInterval

        static let production = Configuration(
            staleInterval: 5,
            heartbeatInterval: 2.5,
            acquisitionBudget: 10,
            retryDelay: 0.5
        )
    }

    private let configuration: Configuration
    private let now: @Sendable () -> Date

    init(
        configuration: Configuration = .production,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.now = now
    }

    func acquire(target: URL) async throws -> KimiCredentialLockHandle {
        try Self.prepareSentinel(target)
        let lockURL = URL(fileURLWithPath: target.path + ".lock")
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.duration(configuration.acquisitionBudget))
        var staleCandidate: (identity: KimiLockIdentity, observedAt: ContinuousClock.Instant)?

        while true {
            try Task.checkCancellation()
            if Self.makeDirectory(lockURL) {
                guard let identity = Self.identity(of: lockURL), identity.isDirectory else {
                    throw KimiAuthError.credentialLockUnavailable
                }
                let descriptor = Self.openDirectory(lockURL)
                guard descriptor >= 0,
                      Self.identity(of: descriptor) == identity,
                      Self.identity(of: lockURL) == identity
                else {
                    if descriptor >= 0 { _ = Darwin.close(descriptor) }
                    _ = Self.removeDirectory(lockURL, matching: identity)
                    throw KimiAuthError.credentialLockUnavailable
                }
                let handle = KimiCredentialLockHandle(
                    lockURL: lockURL,
                    identity: identity,
                    descriptor: descriptor,
                    heartbeatInterval: configuration.heartbeatInterval
                )
                await handle.startHeartbeat()
                return handle
            }

            guard errno == EEXIST else {
                throw KimiAuthError.credentialLockUnavailable
            }
            guard let existing = Self.identity(of: lockURL) else {
                // EEXIST 결과와 lstat 사이에 owner가 해제 가능한 정상 hand-off race — broken lock 보고 대신 잠시 대기 후 mkdir 재시도
                guard errno == ENOENT, clock.now < deadline else {
                    throw KimiAuthError.credentialLockUnavailable
                }
                let nanoseconds = UInt64(max(configuration.retryDelay, 0.001) * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
                continue
            }
            guard existing.isDirectory else {
                throw KimiAuthError.credentialLockUnavailable
            }
            if now().timeIntervalSince(existing.modifiedAt) >= configuration.staleInterval {
                if let candidate = staleCandidate, candidate.identity == existing,
                   candidate.observedAt.duration(to: clock.now)
                       >= Self.duration(configuration.heartbeatInterval),
                   Self.removeDirectory(lockURL, matching: existing) {
                    staleCandidate = nil
                    continue
                }
                if staleCandidate?.identity != existing {
                    staleCandidate = (existing, clock.now)
                }
            } else {
                staleCandidate = nil
            }
            guard clock.now < deadline else {
                throw KimiAuthError.credentialLockUnavailable
            }
            let nanoseconds = UInt64(max(configuration.retryDelay, 0.001) * 1_000_000_000)
            try await Task.sleep(nanoseconds: nanoseconds)
        }
    }

    private static func prepareSentinel(_ target: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw KimiAuthError.credentialLockUnavailable
        }

        if let existing = identity(of: target) {
            guard existing.isRegularFile else {
                throw KimiAuthError.credentialLockUnavailable
            }
            return
        }

        let descriptor = target.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        }
        if descriptor >= 0 {
            _ = Darwin.close(descriptor)
            return
        }
        guard errno == EEXIST,
              let raced = identity(of: target),
              raced.isRegularFile
        else {
            throw KimiAuthError.credentialLockUnavailable
        }
    }

    fileprivate static func identity(of url: URL) -> KimiLockIdentity? {
        var info = stat()
        let result = url.path.withCString { Darwin.lstat($0, &info) }
        guard result == 0 else { return nil }
        return KimiLockIdentity(info)
    }

    fileprivate static func identity(of descriptor: Int32) -> KimiLockIdentity? {
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0 else { return nil }
        return KimiLockIdentity(info)
    }

    fileprivate static func touch(_ descriptor: Int32) -> Bool {
        Darwin.futimens(descriptor, nil) == 0
    }

    private static func makeDirectory(_ url: URL) -> Bool {
        url.path.withCString { Darwin.mkdir($0, S_IRWXU) == 0 }
    }

    private static func openDirectory(_ url: URL) -> Int32 {
        url.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
    }

    fileprivate static func removeDirectory(_ url: URL, matching expected: KimiLockIdentity) -> Bool {
        let parent = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        let parentDescriptor = parent.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard parentDescriptor >= 0 else { return false }
        defer { _ = Darwin.close(parentDescriptor) }

        var info = stat()
        let matches = name.withCString {
            Darwin.fstatat(parentDescriptor, $0, &info, AT_SYMLINK_NOFOLLOW) == 0
        }
        guard matches, KimiLockIdentity(info) == expected else { return false }
        return name.withCString {
            Darwin.unlinkat(parentDescriptor, $0, AT_REMOVEDIR) == 0
        }
    }

    private static func duration(_ interval: TimeInterval) -> Duration {
        .nanoseconds(Int64(max(interval, 0) * 1_000_000_000))
    }
}

actor KimiCredentialLockHandle {
    private let lockURL: URL
    private let heartbeatInterval: TimeInterval
    private var expectedIdentity: KimiLockIdentity
    private var descriptor: Int32?
    private var heartbeatTask: Task<Void, Never>?
    private var valid = true
    private var released = false
    private var releaseResult: Bool?

    fileprivate init(
        lockURL: URL,
        identity: KimiLockIdentity,
        descriptor: Int32,
        heartbeatInterval: TimeInterval
    ) {
        self.lockURL = lockURL
        self.expectedIdentity = identity
        self.descriptor = descriptor
        self.heartbeatInterval = heartbeatInterval
    }

    deinit {
        if let descriptor { _ = Darwin.close(descriptor) }
    }

    fileprivate func startHeartbeat() {
        guard heartbeatTask == nil else { return }
        let interval = heartbeatInterval
        heartbeatTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                let nanoseconds = UInt64(max(interval, 0.001) * 1_000_000_000)
                do {
                    try await Task.sleep(nanoseconds: nanoseconds)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                await self.refreshHeartbeat()
            }
        }
    }

    func isValid() -> Bool {
        validateOwnership()
    }

    func performWhileValid(_ operation: @Sendable () async throws -> Void) async throws {
        guard validateOwnership() else {
            throw KimiAuthError.credentialLockCompromised
        }
        do {
            try await operation()
        } catch {
            guard validateOwnership() else {
                throw KimiAuthError.credentialLockCompromised
            }
            throw error
        }
        guard validateOwnership() else {
            throw KimiAuthError.credentialLockCompromised
        }
    }

    @discardableResult
    func release() -> Bool {
        if let releaseResult { return releaseResult }
        heartbeatTask?.cancel()
        heartbeatTask = nil

        guard valid,
              let descriptor,
              KimiCredentialLock.identity(of: descriptor) == expectedIdentity,
              KimiCredentialLock.identity(of: lockURL) == expectedIdentity
        else {
            valid = false
            released = true
            closeDescriptor()
            releaseResult = false
            return false
        }
        let removed = KimiCredentialLock.removeDirectory(lockURL, matching: expectedIdentity)
        if !removed {
            valid = false
        }
        released = true
        closeDescriptor()
        releaseResult = removed
        return removed
    }

    private func refreshHeartbeat() {
        guard valid, !released,
              let descriptor,
              KimiCredentialLock.identity(of: descriptor) == expectedIdentity,
              KimiCredentialLock.identity(of: lockURL) == expectedIdentity,
              KimiCredentialLock.touch(descriptor),
              let refreshed = KimiCredentialLock.identity(of: descriptor),
              KimiCredentialLock.identity(of: lockURL) == refreshed,
              refreshed.device == expectedIdentity.device,
              refreshed.inode == expectedIdentity.inode,
              refreshed.isDirectory
        else {
            valid = false
            return
        }
        expectedIdentity = refreshed
    }

    private func validateOwnership() -> Bool {
        guard valid, !released,
              let descriptor,
              KimiCredentialLock.identity(of: descriptor) == expectedIdentity,
              KimiCredentialLock.identity(of: lockURL) == expectedIdentity
        else {
            valid = false
            return false
        }
        return true
    }

    private func closeDescriptor() {
        guard let descriptor else { return }
        _ = Darwin.close(descriptor)
        self.descriptor = nil
    }
}

fileprivate struct KimiLockIdentity: Sendable, Equatable {
    var device: UInt64
    var inode: UInt64
    var mode: mode_t
    var modifiedSeconds: Int64
    var modifiedNanoseconds: Int64

    init(_ info: stat) {
        self.device = UInt64(info.st_dev)
        self.inode = UInt64(info.st_ino)
        self.mode = info.st_mode
        self.modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
        self.modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
    }

    var isDirectory: Bool { mode & S_IFMT == S_IFDIR }
    var isRegularFile: Bool { mode & S_IFMT == S_IFREG }
    var modifiedAt: Date {
        Date(timeIntervalSince1970: TimeInterval(modifiedSeconds) + TimeInterval(modifiedNanoseconds) / 1_000_000_000)
    }
}
