import Foundation

/// The local readiness check behind the Settings account badge and the switch toggle. A profile is
/// **Ready** when its OpenUsage Keychain snapshot carries a usable credential that still proves the
/// profile's own identity — the exact precondition of the switch transaction, checked through the
/// same readers. No provider network call, no shared-home read, no prompt-risk Keychain probing of
/// other apps' items.
struct AccountSignInProbe: Sendable {
    enum State: Equatable, Sendable {
        /// The snapshot proves the profile's account and carries a usable credential shape.
        case ready(identityKey: String, label: String?)
        /// No provable sign-in snapshot for this profile. Never "wrong account" — simply not ready.
        case needsSignIn
    }

    var environment: EnvironmentReading
    var keychain: KeychainAccessing
    var homeDirectory: @Sendable () -> URL

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        keychain: KeychainAccessing = SecurityKeychainAccessor(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser }
    ) {
        self.environment = environment
        self.keychain = keychain
        self.homeDirectory = homeDirectory
    }

    func state(for profile: AccountProfile) -> State {
        let switcher = AccountCredentialSwitcher(
            keychain: keychain,
            environment: environment,
            homeDirectory: homeDirectory()
        )
        guard let entry = try? switcher.loadSnapshot(for: profile),
              let (identityKey, label) = switcher.identity(of: entry, family: profile.family),
              identityKey == profile.identityKey
        else {
            return .needsSignIn
        }
        return .ready(identityKey: identityKey, label: label)
    }
}
