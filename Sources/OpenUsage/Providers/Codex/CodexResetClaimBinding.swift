import Foundation

/// 표시한 사용량의 인증 출처·주체를 고정. 신원 미해석 토큰은 같은 인증 사본에만 소비 허용.
struct CodexResetClaimBinding: Hashable, Sendable {
    let source: CodexAuthState.Source
    private let accountID: String?
    private let identity: Identity

    private enum Identity: Hashable, Sendable {
        case account(String)
        case credential(Data)
    }

    init?(authState: CodexAuthState) {
        guard authState.hasUsableAccessToken, let tokens = authState.auth.tokens else { return nil }
        let payloads = [tokens.accessToken, tokens.idToken].compactMap { $0.flatMap(ProviderParse.jwtPayload) }
        let subjects = payloads.compactMap { ($0["sub"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
        let accounts = ([tokens.accountID] + payloads.map { DefaultAccountObserver.chatGPTAccountID(inIDTokenPayload: $0) })
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty?.lowercased() }
        guard Set(subjects).count <= 1, Set(accounts).count <= 1 else { return nil }
        source = authState.source
        accountID = tokens.accountID
        if let account = CodexWeeklyTimerIdentity.accountKey(for: authState.auth) {
            identity = .account(account)
        } else if let fingerprint = CodexWeeklyTimerIdentity.generationFingerprint(for: authState.auth) {
            identity = .credential(fingerprint)
        } else {
            return nil
        }
    }

    func matches(_ authState: CodexAuthState) -> Bool {
        Self(authState: authState) == self
    }
}
