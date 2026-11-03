import Darwin
import Foundation
import os

/// 독립 기록기·프로세스의 append와 rotation을 동일 lock 파일로 직렬화.
/// `@unchecked Sendable`: 인스턴스 상태는 `NSLock`, 공유 파일은 `flock`으로 보호.
final class LogFile: @unchecked Sendable {
    static let shared = LogFile(directory: defaultDirectory(), fileName: "OpenUsage.log")
    static let url: URL = shared.fileURL
    static let defaultMaxBytes = 10_000_000

    let fileURL: URL
    private let archiveURL: URL
    private let lockURL: URL
    private let directory: URL
    private let maxBytes: Int
    private let fallbackLogger = Logger(subsystem: "OpenUsage", category: "logfile")
    private let lock = NSLock()
    private var lockFD: Int32 = -1
    private var disabled = false

    init(directory: URL, fileName: String, maxBytes: Int = defaultMaxBytes) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent(fileName)
        self.lockURL = directory.appendingPathComponent(fileName + ".lock")
        self.maxBytes = maxBytes
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        let archiveName = ext.isEmpty ? "\(base).1" : "\(base).1.\(ext)"
        self.archiveURL = directory.appendingPathComponent(archiveName)
    }

    deinit {
        if lockFD >= 0 { Darwin.close(lockFD) }
    }

    static func defaultDirectory() -> URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return library.appendingPathComponent("Logs/OpenUsage", isDirectory: true)
    }

    func open() {
        lock.lock()
        defer { lock.unlock() }
        guard !disabled, lockFD < 0 else { return }
        do {
            try prepareLocked()
            try withProcessLock {
                let handle = try appendHandle()
                defer { try? handle.close() }
                if try handle.seekToEnd() > UInt64(maxBytes) { try rotateLocked() }
            }
        } catch { failLocked("open", error: error) }
    }

    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !disabled else { return }
        do {
            try prepareLocked()
            try withProcessLock {
                // rotation로 inode가 바뀌어도 현재 파일을 열어 기록 — 이전 archive handle 재사용 금지.
                var handle = try appendHandle()
                defer { try? handle.close() }
                let data = Data("\(line)\n".utf8)
                if try handle.seekToEnd() + UInt64(data.count) > UInt64(maxBytes) {
                    try handle.close()
                    try rotateLocked()
                    handle = try appendHandle()
                }
                try handle.write(contentsOf: data)
            }
        } catch { failLocked("append", error: error) }
    }

    private func prepareLocked() throws {
        guard lockFD < 0 else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        lockFD = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard lockFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func withProcessLock(_ body: () throws -> Void) throws {
        while flock(lockFD, LOCK_EX) != 0 {
            guard errno == EINTR else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        defer { flock(lockFD, LOCK_UN) }
        try body()
    }

    private func appendHandle() throws -> FileHandle {
        let fd = Darwin.open(fileURL.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    private func rotateLocked() throws {
        if FileManager.default.fileExists(atPath: archiveURL.path) {
            try FileManager.default.removeItem(at: archiveURL)
        }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.moveItem(at: fileURL, to: archiveURL)
        }
        try appendHandle().close()
    }

    private func failLocked(_ operation: String, error: Error) {
        fallbackLogger.error("File log sink disabled: \(operation, privacy: .public), code=\((error as NSError).code)")
        disabled = true
    }
}
