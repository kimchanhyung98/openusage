import Foundation

/// 동기 credential 검증·쓰기 직렬화 — Credential 잠금 뒤 Native Keychain 잠금 순서 고정, await 금지.
enum AccountCredentialMutation {
    static func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        try AccountCredentialMutationLock.withLock(operation)
    }
}

enum AccountAuthenticationMutationError: LocalizedError, Equatable {
    case busy
    case changed

    var errorDescription: String? {
        switch self {
        case .busy:
            "Another account update is in progress. Wait for it to finish, then try again."
        case .changed:
            "The account selection or saved sign-in changed during this update. Refresh the account list and try again."
        }
    }
}

extension AccountProfilesStore {
    struct AuthenticationContext: Equatable, Sendable {
        struct Binding: Equatable, Sendable {
            let family: String
            let identityKey: String
        }

        let authRevision: Int
        let metadataRevision: Int
        let bindings: [String: Binding]
        let selectedIDs: [String: String]
        let hasUnreadableRegistry: Bool
    }

    struct AuthenticationMutation {
        enum Phase { case preparing, applying, committing }

        let token: UUID
        var phase: Phase
    }

    var isAuthenticationMutationInProgress: Bool { authenticationMutation != nil }
    var isApplyingAuthentication: Bool { authenticationMutation?.phase == .applying }

    func authenticationContext() -> AuthenticationContext {
        AuthenticationContext(
            authRevision: authenticationRevision,
            metadataRevision: authenticationMetadataRevision,
            bindings: Dictionary(uniqueKeysWithValues: profiles.filter { !$0.isArchived }.map {
                ($0.id, AuthenticationContext.Binding(family: $0.family, identityKey: $0.identityKey))
            }),
            selectedIDs: Dictionary(uniqueKeysWithValues: Self.supportedFamilies.compactMap { family in
                preferredProfileID(family: family).map { (family, $0) }
            }),
            hasUnreadableRegistry: hasUnreadableRegistry
        )
    }

    func validateAuthenticationContext(_ context: AuthenticationContext) throws {
        guard !hasUnreadableRegistry else { throw AccountProfileError.registryUnreadable }
        guard authenticationContext() == context else { throw AccountAuthenticationMutationError.changed }
    }

    func beginAuthenticationMutation() throws -> UUID {
        guard !hasUnreadableRegistry else { throw AccountProfileError.registryUnreadable }
        guard authenticationMutation == nil else { throw AccountAuthenticationMutationError.busy }
        let token = UUID()
        authenticationMutation = AuthenticationMutation(token: token, phase: .preparing)
        onAuthenticationMutationStarted?()
        return token
    }

    /// 대기 뒤 메타데이터 검증과 적용 단계 진입을 같은 MainActor turn에서 완료.
    func beginApplyingAuthentication(_ token: UUID, context: AuthenticationContext) throws {
        guard authenticationMutation?.token == token,
              authenticationMutation?.phase == .preparing else { throw AccountAuthenticationMutationError.changed }
        try validateAuthenticationContext(context)
        authenticationMutation?.phase = .applying
    }

    /// credential 적용 후 동기 commit 동안만 메타데이터 쓰기 허용 — 작업 소유권은 종료까지 유지.
    func finishAuthenticationMutation<T>(_ token: UUID, _ commit: () throws -> T) throws -> T {
        guard authenticationMutation?.token == token,
              authenticationMutation?.phase == .applying else { throw AccountAuthenticationMutationError.changed }
        authenticationMutation?.phase = .committing
        defer {
            if authenticationMutation?.token == token { authenticationMutation?.phase = .preparing }
        }
        return try commit()
    }

    func endAuthenticationMutation(_ token: UUID, notifyRefresh: Bool = true) {
        guard authenticationMutation?.token == token else { return }
        onAuthenticationMutationWillEnd?(notifyRefresh)
        authenticationMutation = nil
    }

    func ensureAuthenticationMetadataWritable() throws {
        guard !isApplyingAuthentication else { throw AccountAuthenticationMutationError.busy }
    }
}
