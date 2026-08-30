import Darwin
import Foundation
import SQLite3
import Security

protocol EnvironmentReading: Sendable {
    func value(for name: String) -> String?
}

struct ProcessEnvironmentReader: EnvironmentReading {
    var processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    var shellEnvironment: LoginShellEnvironment = .shared
    var launchSnapshot: @Sendable () -> ShellEnvironmentSnapshot? = { ShellEnvironmentSnapshotStore.launchSnapshot }

    private static let identityKeys = Set(ShellEnvironmentSnapshot.capturedKeys)

    func value(for name: String) -> String? {
        // process 환경 우선(launchd·`launchctl setenv`·터미널 launch), 다음 login-shell 캡처 — Finder/Dock launch에서도 shell profile export 해석.
        if let value = processEnvironment[name]?.nilIfEmpty {
            return value
        }
        // identity 관련 키는 persisted shell-environment snapshot에 세션 내내 고정 — 모든 reader가 같은 home override를 해석해 shared snapshot cache 오염 방지.
        // 변경된 export는 다음 launch부터 적용; 그 외 키는 live 캡처 사용.
        if Self.identityKeys.contains(name),
           let snapshot = launchSnapshot(),
           snapshot.pinnedKeys.contains(name)
        {
            return snapshot.values[name]?.nilIfEmpty
        }
        return shellEnvironment.value(for: name)
    }
}

protocol TextFileAccessing: Sendable {
    func exists(_ path: String) -> Bool
    /// UTF-8 파일 존재 시 read — `nil`은 경로 부재만 의미.
    /// 권한·인코딩 실패는 throw — 저장소 고장을 로그아웃으로 오인 금지.
    func readTextIfPresent(_ path: String) throws -> String?
    func readText(_ path: String) throws -> String
    func writeText(_ path: String, _ text: String) throws
    /// `path` 파일 삭제 — 부재는 에러 아님(이미 목적 달성 상태).
    func remove(_ path: String) throws
}

extension TextFileAccessing {
    /// 테스트 double용 호환 경로 — production accessor는 read 에러를 직접 분류해 exists-then-read race 없음.
    func readTextIfPresent(_ path: String) throws -> String? {
        guard exists(path) else { return nil }
        return try readText(path)
    }
}

struct LocalTextFileAccessor: TextFileAccessing {
    /// credential·token 파일의 타 로컬 계정 읽기 금지 계약.
    /// 목적지 디렉터리의 private 임시 파일에 쓰고 flush 후 rename — 교체는 원자적, 노출 시점부터 mode 0600 보장.
    private static let privateFileMode = mode_t(S_IRUSR | S_IWUSR)

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: expandHome(path))
    }

    func readText(_ path: String) throws -> String {
        try String(contentsOfFile: expandHome(path), encoding: .utf8)
    }

    func readTextIfPresent(_ path: String) throws -> String? {
        do {
            return try readText(path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    func writeText(_ path: String, _ text: String) throws {
        let expanded = expandHome(path)
        let parent = URL(fileURLWithPath: expanded).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let destination = URL(fileURLWithPath: expanded)
        let temporary = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )
        let descriptor = temporary.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, Self.privateFileMode)
        }
        guard descriptor >= 0 else { throw Self.currentPOSIXError() }

        var descriptorIsOpen = true
        var temporaryExists = true
        defer {
            if descriptorIsOpen { _ = Darwin.close(descriptor) }
            if temporaryExists {
                temporary.path.withCString { _ = Darwin.unlink($0) }
            }
        }

        // umask는 생성 시 권한 제거만 가능 — 공개 전 inode에 정확한 private mode 재설정.
        guard Darwin.fchmod(descriptor, Self.privateFileMode) == 0 else {
            throw Self.currentPOSIXError()
        }
        try Self.writeAll(Data(text.utf8), to: descriptor)
        guard Darwin.fsync(descriptor) == 0 else { throw Self.currentPOSIXError() }
        let closeResult = Darwin.close(descriptor)
        descriptorIsOpen = false
        guard closeResult == 0 else { throw Self.currentPOSIXError() }

        let renameResult = temporary.path.withCString { source in
            expanded.withCString { destination in
                Darwin.rename(source, destination)
            }
        }
        guard renameResult == 0 else { throw Self.currentPOSIXError() }
        temporaryExists = false
    }

    func remove(_ path: String) throws {
        let expanded = expandHome(path)
        guard FileManager.default.fileExists(atPath: expanded) else { return }
        try FileManager.default.removeItem(atPath: expanded)
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw currentPOSIXError()
                }
                guard result > 0 else { throw POSIXError(.EIO) }
                offset += result
            }
        }
    }

    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

protocol SQLiteAccessing: Sendable {
    func queryValue(path: String, sql: String) throws -> String?
    func execute(path: String, sql: String) throws
    /// 값은 SQL 텍스트가 아닌 바인딩으로 전달 — secret의 child process argv 유입 차단.
    func execute(path: String, sql: String, bindings: [String]) throws
}

extension SQLiteAccessing {
    func execute(path: String, sql: String, bindings: [String]) throws {
        guard bindings.isEmpty else { throw SQLiteError.boundParametersUnsupported }
        try execute(path: path, sql: sql)
    }
}

struct SQLiteCLIAccessor: SQLiteAccessing {
    var processRunner: ProcessRunning

    init(processRunner: ProcessRunning = SystemProcessRunner()) {
        self.processRunner = processRunner
    }

    func queryValue(path: String, sql: String) throws -> String? {
        // sqlite3 일반 open은 부재 DB를 생성 가능 — credential probe는 read-only여야 하므로 부재 시 프로세스 실행 전 nil 반환.
        guard try databaseExists(path) else { return nil }
        let result = try run(path: path, sql: sql, readOnly: true)
        guard result.succeeded else {
            throw SQLiteError.queryFailed(result.stderr)
        }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    func execute(path: String, sql: String) throws {
        let result = try run(path: path, sql: sql)
        guard result.succeeded else {
            throw SQLiteError.queryFailed(result.stderr)
        }
    }

    func execute(path: String, sql: String, bindings: [String]) throws {
        guard !bindings.isEmpty else { return try execute(path: path, sql: sql) }
        var handle: OpaquePointer?
        let expanded = expandHome(path)
        // Credential DB 갱신 전용 — 부재 시 schema 없는 빈 DB 생성 대신 실패.
        let openResult = sqlite3_open_v2(expanded, &handle, SQLITE_OPEN_READWRITE, nil)
        guard openResult == SQLITE_OK, let handle else {
            let message = handle.map { lastErrorMessage($0) }
                ?? String(cString: sqlite3_errstr(openResult))
            sqlite3_close_v2(handle)
            throw SQLiteError.queryFailed(message)
        }
        defer { sqlite3_close_v2(handle) }
        sqlite3_busy_timeout(handle, 1000)

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw SQLiteError.queryFailed(lastErrorMessage(handle))
        }
        defer { sqlite3_finalize(statement) }
        let expectedBindingCount = Int(sqlite3_bind_parameter_count(statement))
        guard expectedBindingCount == bindings.count else {
            throw SQLiteError.queryFailed(
                "SQLite statement expected \(expectedBindingCount) bindings but received \(bindings.count)."
            )
        }
        for (index, binding) in bindings.enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 1), binding, -1, Self.transientDestructor) == SQLITE_OK else {
                throw SQLiteError.queryFailed(lastErrorMessage(handle))
            }
        }
        let step = sqlite3_step(statement)
        guard step == SQLITE_DONE || step == SQLITE_ROW else {
            throw SQLiteError.queryFailed(lastErrorMessage(handle))
        }
    }

    private static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func lastErrorMessage(_ handle: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(handle))
    }

    private func run(path: String, sql: String, readOnly: Bool = false) throws -> ProcessResult {
        var arguments = ["-batch", "-noheader"]
        if readOnly { arguments.append("-readonly") }
        arguments += [
            "-cmd", ".timeout 1000",
            expandHome(path),
            sql
        ]
        return try processRunner.run(
            executable: "/usr/bin/sqlite3",
            arguments: arguments,
            environment: [:],
            timeout: 5
        )
    }

    private func databaseExists(_ path: String) throws -> Bool {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: expandHome(path))
            return true
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return false
        }
    }
}

enum SQLiteError: Error, LocalizedError, Equatable {
    case queryFailed(String)
    case boundParametersUnsupported

    var errorDescription: String? {
        switch self {
        case .queryFailed(let message):
            return message.isEmpty ? "SQLite query failed." : message
        case .boundParametersUnsupported:
            return "This SQLite accessor cannot run statements with bound parameters."
        }
    }
}

protocol KeychainAccessing: Sendable {
    func readGenericPassword(service: String) throws -> String?
    func writeGenericPassword(service: String, value: String) throws
    func deleteGenericPassword(service: String) throws
    func readGenericPasswordForCurrentUser(service: String) throws -> String?
    func writeGenericPasswordForCurrentUser(service: String, value: String) throws
    /// 명시적 account(`-a`) 스코프의 generic password read — 타 앱이 특정 account 이름으로 저장한 item용.
    func readGenericPassword(service: String, account: String) throws -> String?
    /// secret을 읽지 않고 generic password item의 마지막 수정 시각 조회.
    func genericPasswordModificationDate(service: String) throws -> Date?
    func genericPasswordModificationDateForCurrentUser(service: String) throws -> Date?
}

extension KeychainAccessing {
    func readGenericPasswordForCurrentUser(service: String) throws -> String? {
        try readGenericPassword(service: service)
    }

    func writeGenericPasswordForCurrentUser(service: String, value: String) throws {
        try writeGenericPassword(service: service, value: value)
    }

    /// account 미모델 mock용 기본 구현 — service-only 조회 fallback; 실제 `SecurityKeychainAccessor`는 `-a <account>` 전달.
    func readGenericPassword(service: String, account: String) throws -> String? {
        try readGenericPassword(service: service)
    }

    func genericPasswordModificationDate(service: String) throws -> Date? { nil }

    func genericPasswordModificationDateForCurrentUser(service: String) throws -> Date? {
        try genericPasswordModificationDate(service: service)
    }

    /// secret 읽기 없이 `service` item 존재 여부 probe — `nil`은 probe 자체 실패(잠긴 Keychain·거부), 안전한 해석은 caller별 판단.
    /// 기본 구현(mock용)은 read fallback; `SecurityKeychainAccessor`는 in-process attributes-only probe로 override.
    func genericPasswordExists(service: String) -> Bool? {
        do {
            return try readGenericPassword(service: service) != nil
        } catch {
            return nil
        }
    }
}

struct SecurityKeychainAccessor: KeychainAccessing {
    let processRunner: ProcessRunning

    init(processRunner: ProcessRunning = SystemProcessRunner()) {
        self.processRunner = processRunner
    }

    // exit 44(errSecItemNotFound)만 정당한 "credential 없음" — 그 외 non-zero exit는 실제 실패(잠김·거부·prompt 취소), "not signed in"으로 은폐 금지.
    private static let itemNotFoundExitCode: Int32 = 44

    func readGenericPassword(service: String) throws -> String? {
        try readPassword(["find-generic-password", "-s", service, "-w"], service: service)
    }

    /// launch 경로용 attributes-only 존재 probe — in-process Security framework 쿼리, secret 미요청·UI 금지로 unlock prompt·launch 지연 불가.
    /// probe 실패(잠김·거부)는 `nil`("unknown")로만 보고 — 확정 답 금지.
    func genericPasswordExists(service: String) -> Bool? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        switch SecItemCopyMatching(query as CFDictionary, nil) {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default: return nil
        }
    }

    func readGenericPasswordForCurrentUser(service: String) throws -> String? {
        try readPassword(["find-generic-password", "-a", currentUserAccount(), "-s", service, "-w"], service: service)
    }

    func readGenericPassword(service: String, account: String) throws -> String? {
        try readPassword(["find-generic-password", "-a", account, "-s", service, "-w"], service: service)
    }

    func genericPasswordModificationDate(service: String) throws -> Date? {
        try modificationDate(service: service, account: nil)
    }

    func genericPasswordModificationDateForCurrentUser(service: String) throws -> Date? {
        try modificationDate(service: service, account: currentUserAccount())
    }

    private func modificationDate(service: String, account: String?) throws -> Date? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return (result as? [String: Any])?[kSecAttrModificationDate as String] as? Date
        case errSecItemNotFound:
            return nil
        default:
            AppLog.warn(.keychain, "keychain modification-date read failed (status \(status))")
            throw KeychainError.readFailed("Keychain metadata read failed (status \(status)).")
        }
    }

    private func readPassword(_ arguments: [String], service: String) throws -> String? {
        let result = try processRunner.run(
            executable: "/usr/bin/security",
            arguments: arguments,
            environment: [:],
            timeout: 5
        )
        guard result.succeeded else {
            if result.exitCode == Self.itemNotFoundExitCode { return nil }
            // 잠김·거부 Keychain 진단용 로그 — caller가 `try?`로 nil 처리해도 여기서 기록 필수.
            AppLog.warn(.keychain, "read failed for service '\(service)' (exit \(result.exitCode))")
            throw KeychainError.readFailed(result.stderr)
        }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    func writeGenericPassword(service: String, value: String) throws {
        try writePassword(["add-generic-password", "-U", "-s", service, "-w", value])
    }

    func deleteGenericPassword(service: String) throws {
        // `security` 1회 호출은 item 1개만 삭제 — account-scoped와 unscoped item 공존 가능, not-found까지 반복해 전부 제거.
        for _ in 0..<8 {
            let result = try processRunner.run(
                executable: "/usr/bin/security",
                arguments: ["delete-generic-password", "-s", service],
                environment: [:],
                timeout: 5
            )
            if result.exitCode == Self.itemNotFoundExitCode { return }
            if result.succeeded { continue }
            // 서비스명 로깅 금지 — account-vault 서비스명에 profile id 포함.
            AppLog.warn(.keychain, "keychain delete failed (exit \(result.exitCode))")
            throw KeychainError.deleteFailed("exit \(result.exitCode)")
        }
        AppLog.warn(.keychain, "keychain delete did not converge")
        throw KeychainError.deleteFailed("did not converge")
    }

    func writeGenericPasswordForCurrentUser(service: String, value: String) throws {
        try writePassword(["add-generic-password", "-U", "-a", currentUserAccount(), "-s", service, "-w", value])
    }

    private func writePassword(_ arguments: [String]) throws {
        let result = try processRunner.run(
            executable: "/usr/bin/security",
            arguments: arguments,
            environment: [:],
            timeout: 5
        )
        if !result.succeeded {
            throw KeychainError.writeFailed(result.stderr)
        }
    }

    private func currentUserAccount() -> String {
        ProcessInfo.processInfo.environment["USER"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        ?? NSUserName()
    }
}

enum KeychainError: Error, LocalizedError {
    case writeFailed(String)
    case readFailed(String)
    case deleteFailed(String)

    var errorDescription: String? {
        switch self {
        case .writeFailed(let message):
            return message.isEmpty ? "Keychain write failed." : message
        case .readFailed(let message):
            return message.isEmpty ? "Keychain read failed." : message
        case .deleteFailed(let message):
            return message.isEmpty ? "Keychain delete failed." : message
        }
    }
}

func expandHome(_ path: String) -> String {
    guard path == "~" || path.hasPrefix("~/") else { return path }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if path == "~" { return home }
    return home + String(path.dropFirst())
}
