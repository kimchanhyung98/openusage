import Foundation

struct SoftLimitTask: Hashable, Sendable {
    let providerID: String
    let sessionID: String
    let operationID: String
}

enum SoftLimitCancellationOutcome: Sendable {
    case cancelled
    case alreadyFinished
}

/// adapter가 발급한 exact operation만 취소 — PID·host 종료 interface 없음.
@MainActor
protocol SoftLimitCancelling: AnyObject {
    var providerID: String { get }
    var coverageNotice: String { get }
    func runningTasks() async throws -> [SoftLimitTask]
    func cancel(_ task: SoftLimitTask, isAuthorized: @escaping @MainActor () -> Bool) async throws -> SoftLimitCancellationOutcome
    func disconnect()
}

enum SoftLimitControlError: Error, LocalizedError, Equatable {
    case unavailable
    case unsafeEndpoint
    case disconnected
    case invalidResponse
    case rejected(Int)
    case timedOut
    case wrongProvider

    var errorDescription: String? {
        switch self {
        case .unavailable: "No local cancellation connection. Connect your AI client first."
        case .unsafeEndpoint: "The local control socket has unsafe ownership or permissions."
        case .disconnected: "The cancellation connection closed. Some tasks may still be running."
        case .invalidResponse: "The AI client returned an unsupported control response."
        case .rejected: "The AI client rejected the cancellation control request."
        case .timedOut: "Cancellation was not confirmed in time. Some tasks may still be running."
        case .wrongProvider: "The task does not belong to this provider."
        }
    }
}

struct SoftLimitProviderStatus: Equatable {
    enum Phase: Equatable { case waiting, belowLimit, cancelling, cancelled, noRunningTasks, unsupported, failed }
    var phase: Phase
    var cancelledCount = 0
    var failedCount = 0
    var message: String
}
