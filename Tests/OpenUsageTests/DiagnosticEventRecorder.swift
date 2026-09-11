import Foundation
@testable import OpenUsage

/// AppDiagnostics 단일 구독을 독점하는 테스트 수집기 — 다른 수집기·TelemetryRecorder와 동시 사용 금지.
final class DiagnosticEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [DiagnosticEvent] = []
    private var observer: UUID?

    init() {
        observer = AppDiagnostics.observe { [weak self] event, _ in
            guard let self else { return }
            self.lock.withLock { self.recorded.append(event) }
        }
    }

    deinit {
        if let observer { AppDiagnostics.removeObserver(observer) }
    }

    var events: [DiagnosticEvent] { lock.withLock { recorded } }
}
