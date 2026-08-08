import Foundation
import os

/// 로그 파일 URL 해석과 lock 보호 `FileHandle` appender 소유 — 단일 아카이브 rotation 포함.
/// `@unchecked Sendable`: 모든 가변 상태를 내부 `NSLock`이 보호하므로 어떤 isolation에서도 쓰기 가능.
/// 10 MB 초과 시 `OpenUsage.1.log`로 rotation(디스크 ~20 MB 상한); open/rotation 실패 시 `os.Logger`에 크게 알리고 세션 동안 자체 비활성화.
final class LogFile: @unchecked Sendable {
    /// 공유 production sink — 다른 코드는 `AppLog`를 거쳐 여기에 기록.
    /// `Logs/OpenUsage` 하위 폴더는 literal(bundle-id 미사용)이라 dev/release 빌드가 같은 파일 공유.
    static let shared = LogFile(directory: defaultDirectory(), fileName: "OpenUsage.log")

    /// 외부에 알리는 로그 경로 — 공유 sink에서 파생되어 사용자에게 보이는 경로와 실제 기록 위치가 항상 일치.
    static let url: URL = shared.fileURL

    static let defaultMaxBytes = 10_000_000

    /// 이 sink의 실제 기록 위치 — `url`이 파생하는 단일 소스.
    let fileURL: URL
    private let archiveURL: URL
    private let directory: URL
    private let maxBytes: Int
    private let fallbackLogger = Logger(subsystem: "OpenUsage", category: "logfile")

    private let lock = NSLock()
    private var handle: FileHandle?
    private var size = 0
    private var disabled = false
    private var opened = false

    init(directory: URL, fileName: String, maxBytes: Int = defaultMaxBytes) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent(fileName)
        self.maxBytes = maxBytes
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        let archiveName = ext.isEmpty ? "\(base).1" : "\(base).1.\(ext)"
        self.archiveURL = directory.appendingPathComponent(archiveName)
    }

    static func defaultDirectory() -> URL {
        // `[0]` 대신 `.first` + fallback — `bootstrap()` 중 실행되므로 빈 결과에서도 crash 대신 유효 디렉터리 유지.
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return library.appendingPathComponent("Logs/OpenUsage", isDirectory: true)
    }

    /// 디렉터리·파일 생성, 디스크 기준 size seed, launch-time trim(남은 oversize 파일 1회 rotation). 멱등.
    func open() {
        lock.lock()
        defer { lock.unlock() }
        guard !opened else { return }
        opened = true
        do {
            try openLocked()
        } catch {
            failLocked("open failed: \(error.localizedDescription)")
        }
    }

    /// 포맷 완료된 라인 1줄 append(개행 자동 추가). 상한 초과 예상 시 rotation 선행; sink 비활성화 후에는 no-op.
    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !disabled else { return }
        if !opened {
            opened = true
            do {
                try openLocked()
            } catch {
                failLocked("open failed: \(error.localizedDescription)")
                return
            }
        }
        guard handle != nil else { return }

        let data = Data("\(line)\n".utf8)
        if size + data.count > maxBytes {
            do {
                try rotateLocked()
            } catch {
                failLocked("rotate failed: \(error.localizedDescription)")
                return
            }
        }
        // rotation이 handle을 교체했을 수 있어 재조회.
        guard let liveHandle = handle else { return }
        do {
            try liveHandle.write(contentsOf: data)
            size += data.count
        } catch {
            failLocked("write failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Locked internals (caller holds `lock`)

    private func openLocked() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        self.handle = handle
        self.size = (attributes?[.size] as? Int) ?? 0
        // launch-time trim: 남은 oversize 파일은 첫 write 전 1회 rotation.
        if self.size > maxBytes {
            try rotateLocked()
        } else {
            try handle.seekToEnd()
        }
    }

    private func rotateLocked() throws {
        try handle?.close()
        handle = nil
        if FileManager.default.fileExists(atPath: archiveURL.path) {
            try FileManager.default.removeItem(at: archiveURL)
        }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.moveItem(at: fileURL, to: archiveURL)
        }
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        handle = try FileHandle(forWritingTo: fileURL)
        size = 0
    }

    private func failLocked(_ message: String) {
        fallbackLogger.error("File log sink disabled: \(message, privacy: .public)")
        try? handle?.close()
        handle = nil
        disabled = true
    }
}
