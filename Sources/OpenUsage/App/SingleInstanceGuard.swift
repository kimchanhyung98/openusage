import AppKit
import Darwin

/// 런치 시 OpenUsage 중복 실행 거부 (#635) — 재부팅 시 세션 복원과 `SMAppService` login item이 독립 트리거로 동시 발화 가능.
/// 판정 로직은 live-workspace 질의와 분리 — 두 번째 process 없이 단위 테스트 가능.
@MainActor
enum SingleInstanceGuard {
    /// 순수 판정: 양보 대상 인스턴스의 PID, 계속 실행이면 `nil`.
    /// tie-break은 결정적 — 최저 PID 생존. "peer 존재 시 양보" 규칙은 동시 등록에서 양쪽 모두 종료해 zero instance 유발.
    static func instanceToYieldTo(myPID: pid_t, runningPIDs: [pid_t]) -> pid_t? {
        guard let lowestPeer = runningPIDs.filter({ $0 != myPID }).min(), lowestPeer < myPID else {
            return nil
        }
        return lowestPeer
    }

    /// live 체크 + handoff. 다른 인스턴스가 slot 소유 시 focus를 넘기고 `true` 반환 — caller는 port·status item 확보 전에 종료.
    /// 생존자이거나 unbundled(bundle identifier 부재)면 `false`.
    static func deferToExistingInstance() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let me = NSRunningApplication.current
        // stale entry 제거 — corpse에 양보 시 전체 copy 종료 cascade (#874).
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter(isAlive)
        guard let survivorPID = instanceToYieldTo(
            myPID: me.processIdentifier,
            runningPIDs: running.map(\.processIdentifier)
        ) else {
            return false
        }
        // 판정과 동일 snapshot에서 resolve — 생존자 존재 보장.
        running.first { $0.processIdentifier == survivorPID }?.activate()
        return true
    }

    /// 최저-PID 판정 없는 focus handoff — `SingleInstanceLock`이 peer 소유를 알린 경우 사용 (lock 획득 순서 ≠ PID 순서).
    /// best-effort: 생존 결정은 lock 담당, 이 handoff 아님.
    static func activateExistingInstance() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let myPID = NSRunningApplication.current.processIdentifier
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { $0.processIdentifier != myPID && isAlive($0) }?
            .activate()
    }

    /// LaunchServices snapshot의 just-terminated copy 잔류 대응 (#874) — `isTerminated` + `kill(pid, 0)` 커널 확인.
    private static func isAlive(_ app: NSRunningApplication) -> Bool {
        !app.isTerminated && kill(app.processIdentifier, 0) == 0
    }
}
