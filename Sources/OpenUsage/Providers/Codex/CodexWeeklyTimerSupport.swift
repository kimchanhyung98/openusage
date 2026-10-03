import CryptoKit
import Foundation

struct CodexWeeklyTimerObservation: Equatable, Sendable {
    static let resetTimeTolerance: TimeInterval = 60

    var accountKey: String
    var usedPercent: Double
    var resetsAt: Date?
    var observedAt: Date
    var rawResetAt: Date? = nil

    static func resetTimesMatch(_ first: Date?, _ second: Date?) -> Bool {
        guard let first, let second else { return false }
        return abs(first.timeIntervalSince(second)) <= resetTimeTolerance
    }
}

struct CodexWeeklyTimerSession: Sendable {
    var observation: CodexWeeklyTimerObservation
    var authState: CodexAuthState
    var authStore: CodexAuthStore
}

struct CodexWeeklyTimerCredentialSelection {
    struct PrecedingSource {
        var source: CodexAuthState.Source
        var generation: Data?
    }

    var accountKey: String
    var source: CodexAuthState.Source
    var precedingSources: [PrecedingSource]
}

enum CodexWeeklyTimerProviderError: Error, LocalizedError, Equatable {
    case accountChanged
    case weeklyQuotaUnavailable
    case credentialsChanged

    var errorDescription: String? {
        switch self {
        case .accountChanged:
            "Weekly timer account changed. Refresh this account and try again."
        case .weeklyQuotaUnavailable:
            "Weekly timer could not verify this account's weekly usage."
        case .credentialsChanged:
            "Weekly timer credentials changed. Refresh this account and try again."
        }
    }
}

enum CodexWeeklyTimerIdentity {
    static func generationFingerprint(for auth: CodexAuth) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let encoded = try? encoder.encode(auth) else { return nil }
        return Data(SHA256.hash(data: encoded))
    }

    /// 인증 주체와 요청 대상 워크스페이스만 해시화. 토큰 회전·카드 이름 변경과 독립적인 식별자.
    static func accountKey(for auth: CodexAuth) -> String? {
        guard let tokens = auth.tokens, tokens.accessToken?.nilIfEmpty != nil else { return nil }
        let accessPayload = tokens.accessToken.flatMap(ProviderParse.jwtPayload)
        let idPayload = tokens.idToken.flatMap(ProviderParse.jwtPayload)
        let subjects = [normalized(accessPayload?["sub"] as? String), normalized(idPayload?["sub"] as? String)]
            .compactMap { $0 }
        let accounts = [
            normalized(tokens.accountID),
            DefaultAccountObserver.chatGPTAccountID(inIDTokenPayload: accessPayload),
            DefaultAccountObserver.chatGPTAccountID(inIDTokenPayload: idPayload)
        ].compactMap { $0 }
        guard Set(subjects).count == 1, let subject = subjects.first,
              Set(accounts).count == 1, let account = accounts.first,
              let encoded = try? JSONEncoder().encode([subject, account])
        else { return nil }
        return SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
    }

    private static func normalized(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

@MainActor
final class CodexProviderOperationGate {
    private var occupied = false
    private var waiters: [(UUID, CheckedContinuation<Bool, Never>)] = []

    func acquire() async -> Bool {
        guard !Task.isCancelled else { return false }
        guard occupied else {
            occupied = true
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            occupied = false
            return
        }
        waiters.removeFirst().1.resume(returning: true)
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(returning: false)
    }
}
