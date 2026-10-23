import AppKit
import Observation

@MainActor
@Observable
final class AppRelauncher {
    private(set) var isRestarting = false
    private(set) var errorMessage: String?
    private let scheduleRelaunch: @MainActor () throws -> Void
    private let terminate: @MainActor () -> Void

    init(
        scheduleRelaunch: (@MainActor () throws -> Void)? = nil,
        terminate: @escaping @MainActor () -> Void = { NSApplication.shared.terminate(nil) }
    ) {
        self.scheduleRelaunch = scheduleRelaunch ?? {
            guard Bundle.main.bundleURL.pathExtension == "app" else {
                throw CocoaError(.executableNotLoadable)
            }
            try Self.makeRelaunchProcess(
                bundleURL: Bundle.main.bundleURL,
                processIdentifier: ProcessInfo.processInfo.processIdentifier
            ).run()
        }
        self.terminate = terminate
    }

    func restart() {
        guard !isRestarting else { return }
        errorMessage = nil
        do {
            try scheduleRelaunch()
            isRestarting = true
            AppLog.info(.lifecycle, "Restart requested to apply the language change")
            terminate()
        } catch {
            errorMessage = L10n.settings("Couldn't restart OpenUsage. Quit and reopen the app to apply the language change.")
            AppDiagnostics.failure(.appRestart, error: error)
        }
    }

    /// 정상 종료와 single-instance lock 해제까지 대기. 경로는 셸 코드에 삽입하지 않고 인자로 전달.
    static func makeRelaunchProcess(
        bundleURL: URL,
        processIdentifier: Int32,
        openExecutable: URL = URL(fileURLWithPath: "/usr/bin/open")
    ) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", """
            while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.1; done
            "$3" -n "$2"
            status=$?
            if [ "$status" -ne 0 ]; then
                /usr/bin/logger -p user.err -t OpenUsage "Restart failed (open exit $status)"
            fi
            exit "$status"
            """,
            "openusage-relaunch", String(processIdentifier), bundleURL.path, openExecutable.path,
        ]
        process.standardInput = FileHandle.nullDevice
        return process
    }
}
