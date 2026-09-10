import Foundation
@testable import OpenUsage

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
