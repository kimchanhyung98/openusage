import Darwin
import Foundation

/// 커널 기반 single-instance lock — `SingleInstanceGuard`(#635/#637)의 snapshot이 놓치는 근접 동시 런치 race 차단.
/// per-bundle 파일의 exclusive `flock`은 커널에서 원자적; holder 종료·crash 시 자동 해제라 stale lock의 재실행 차단 불가.
enum SingleInstanceLock {
    enum Acquisition {
        case acquired(Token)
        case alreadyRunning
        case failed(String)
    }

    /// process 수명 동안 lock 소유 — descriptor를 열어 두어 `flock` 유지. token 해제 시 unlock + close.
    final class Token {
        private let fd: CInt

        fileprivate init(fd: CInt) {
            self.fd = fd
        }

        deinit {
            flock(fd, LOCK_UN)
            Darwin.close(fd)
        }
    }

    /// `Application Support/OpenUsage/<bundle id>.lock` 잠금 — 앱 bundle 위치와 무관하게 안정적인 경로.
    static func acquire(bundleIdentifier: String) -> Acquisition {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return .failed("Application Support directory unavailable")
        }
        let lockURL = appSupport
            .appendingPathComponent("OpenUsage", isDirectory: true)
            .appendingPathComponent("\(bundleIdentifier).lock")
        return acquire(at: lockURL)
    }

    /// 테스트가 temp 파일을 대상으로 lock을 걸 수 있도록 분리한 entry point.
    static func acquire(at lockURL: URL) -> Acquisition {
        do {
            try FileManager.default.createDirectory(
                at: lockURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            return .failed(error.localizedDescription)
        }

        let fd = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
        guard fd >= 0 else {
            return .failed(String(cString: strerror(errno)))
        }

        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            Darwin.close(fd)
            return lockError == EWOULDBLOCK ? .alreadyRunning : .failed(String(cString: strerror(lockError)))
        }

        return .acquired(Token(fd: fd))
    }
}
