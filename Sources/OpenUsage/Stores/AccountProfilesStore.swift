import Foundation
import Observation

/// One managed account record for Claude/Codex account switching. A profile is not a folder: it is
/// a stable handle for one provider account, proven by that provider's own credential metadata. The
/// only user-editable field is `label`; authentication lives in the profile's Keychain snapshot and
/// sign-in workspace, both keyed by the immutable `id`.
public struct AccountProfile: Codable, Equatable, Sendable, Identifiable {
    /// Stable id minted at registration (a UUID for new profiles; migrated profiles keep their
    /// original ids). The handle for the Keychain snapshot and the Sign-In Workspace.
    public var id: String
    /// The provider family this account belongs to: `claude` or `codex`. Never changes.
    public var family: String
    /// Display name shown in Settings, the dashboard selector, and the CLI. Freely renameable —
    /// never an identity input. Unique within a family so two rows can't read as one account.
    public var label: String
    /// The provider-proven account identity (Claude: account+org UUIDs; Codex: ChatGPT account id).
    /// Never user-edited; the switch transaction refuses credentials that don't carry it.
    public var identityKey: String
    public var createdAt: Date
    /// Removal is a tombstone: the shared runtime homes are never deleted, and an archived profile
    /// stays out of every picker and preferred selection.
    public var isArchived: Bool

    init(
        id: String,
        family: String,
        label: String,
        identityKey: String,
        createdAt: Date,
        isArchived: Bool = false
    ) {
        self.id = id
        self.family = family
        self.label = label
        self.identityKey = identityKey
        self.createdAt = createdAt
        self.isArchived = isArchived
    }
}

public enum AccountProfileError: Error, Equatable {
    case unknownFamily(String)
    case invalidLabel
    case duplicateLabel(String)
    case duplicateAccount(existingLabel: String)
    case accountLimitReached(Int)
    case profileNotFound(String)
    case ambiguousReference(String)
    case removeSelectedProfile
    case registryUnreadable
}

extension AccountProfileError {
    /// User-facing one-liner, shared by the Settings sheets and the `openusage account` CLI.
    public var userMessage: String {
        switch self {
        case .unknownFamily(let family):
            return "Unknown tool: \(family) (expected claude or codex)"
        case .invalidLabel:
            return "Invalid account name."
        case .duplicateLabel(let label):
            return "An account named '\(label)' already exists. Choose a different name."
        case .duplicateAccount(let existingLabel):
            return "This provider account is already registered as '\(existingLabel)'."
        case .accountLimitReached(let limit):
            return "All \(limit) account slots are in use. Remove an account first."
        case .profileNotFound(let reference):
            return "No account matches '\(reference)'."
        case .ambiguousReference(let reference):
            return "'\(reference)' matches multiple accounts. Use its id from 'openusage account list --json'."
        case .removeSelectedProfile:
            return "This account is currently selected. Select another account before removing it."
        case .registryUnreadable:
            return "OpenUsage couldn't read the saved account list. It was left unchanged. Restart OpenUsage and check the log before trying again."
        }
    }
}

/// The managed account registry (`openusage.accountProfiles.v2`). Lives in the shared defaults
/// domain so the app and the read-only `openusage account` CLI see the same state: the CLI always
/// reads fresh on launch, and the app calls `reloadFromDefaults()` when its panels open. This store
/// holds only profile metadata — credentials live in each profile's Keychain snapshot, and card
/// identity stays in `ProviderAccountsStore`.
@MainActor
@Observable
public final class AccountProfilesStore {
    public static let storageKey = "openusage.accountProfiles.v2"
    public static let maxProfilesPerFamily = 10
    nonisolated static let maxLabelLength = 60

    nonisolated public static let supportedFamilies = ["claude", "codex"]

    nonisolated public static func isSupportedFamily(_ family: String) -> Bool {
        supportedFamilies.contains(family)
    }

    struct Blob: Codable, Equatable {
        var profiles: [AccountProfile]
        var preferredByFamily: [String: String]
    }

    private enum RegistryValidationError: Error {
        case invalidProfile
        case profileLimitExceeded
    }

    private let defaults: UserDefaults

    public private(set) var profiles: [AccountProfile] = []
    public private(set) var hasUnreadableRegistry = false
    private var preferredByFamily: [String: String] = [:]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    /// Active profiles of one family, oldest first (registration order is the display order).
    public func profiles(family: String) -> [AccountProfile] {
        profiles
            .filter { $0.family == family && !$0.isArchived }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func profile(id: String) -> AccountProfile? {
        profiles.first { $0.id == id && !$0.isArchived }
    }

    /// The active profile already registered for a provider account, if any — the duplicate gate
    /// for adds and the target of a same-account re-login.
    public func activeProfile(family: String, identityKey: String) -> AccountProfile? {
        profiles(family: family).first { $0.identityKey == identityKey }
    }

    /// The profile whose authentication new sessions use, if the stored selection still points at
    /// an active profile of the family.
    public func preferredProfileID(family: String) -> String? {
        guard let id = preferredByFamily[family],
              profiles.contains(where: { $0.id == id && $0.family == family && !$0.isArchived }) else {
            return nil
        }
        return id
    }

    public func preferredProfile(family: String) -> AccountProfile? {
        preferredProfileID(family: family).flatMap { id in profiles.first { $0.id == id } }
    }

    /// Records the selected profile. A family with active profiles always keeps one selection, so
    /// callers cannot accidentally leave every account toggle off.
    public func setPreferred(family: String, profileID: String?) {
        guard !hasUnreadableRegistry else {
            AppLog.error(.config, "refusing to change account selection while the registry is unavailable")
            return
        }
        if let profileID {
            guard profiles.contains(where: { $0.id == profileID && $0.family == family && !$0.isArchived }) else {
                return
            }
            guard preferredByFamily[family] != profileID else { return }
            preferredByFamily[family] = profileID
        } else {
            guard profiles(family: family).isEmpty else { return }
            guard preferredByFamily.removeValue(forKey: family) != nil else { return }
        }
        persist()
    }

    /// Registers a profile for a proven provider account. The identity key is the dedupe key: one
    /// provider account is one profile, however many times it signs in. `id` lets the sign-in flow
    /// keep the workspace it minted before the official login ran; omitted, a fresh UUID is minted.
    @discardableResult
    public func add(family: String, label: String, identityKey: String, id: String? = nil) throws -> AccountProfile {
        try ensureRegistryWritable()
        guard Self.isSupportedFamily(family) else {
            throw AccountProfileError.unknownFamily(family)
        }
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidLabel(trimmedLabel) else {
            throw AccountProfileError.invalidLabel
        }
        let normalizedIdentity = identityKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedIdentity.isEmpty else {
            throw AccountProfileError.profileNotFound(identityKey)
        }
        if let existing = activeProfile(family: family, identityKey: normalizedIdentity) {
            throw AccountProfileError.duplicateAccount(existingLabel: existing.label)
        }
        guard !hasActiveLabel(trimmedLabel, family: family, excludingProfileID: nil) else {
            throw AccountProfileError.duplicateLabel(trimmedLabel)
        }
        let activeCount = profiles.filter { $0.family == family && !$0.isArchived }.count
        guard activeCount < Self.maxProfilesPerFamily else {
            throw AccountProfileError.accountLimitReached(Self.maxProfilesPerFamily)
        }
        let resolvedID = id ?? UUID().uuidString
        guard Self.isValidID(resolvedID), !profiles.contains(where: { $0.id == resolvedID }) else {
            throw AccountProfileError.profileNotFound(resolvedID)
        }
        let profile = AccountProfile(
            id: resolvedID,
            family: family,
            label: trimmedLabel,
            identityKey: normalizedIdentity,
            createdAt: Date()
        )
        profiles.append(profile)
        selectFirstProfileIfNeeded(family: family)
        persist()
        return profile
    }

    /// Renames a profile. Only the label changes: id, identity, snapshot, workspace, and the
    /// preferred selection are untouched.
    public func rename(profileID: String, to label: String) throws {
        try ensureRegistryWritable()
        guard let index = profiles.firstIndex(where: { $0.id == profileID && !$0.isArchived }) else {
            throw AccountProfileError.profileNotFound(profileID)
        }
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidLabel(trimmedLabel) else {
            throw AccountProfileError.invalidLabel
        }
        guard !hasActiveLabel(trimmedLabel, family: profiles[index].family, excludingProfileID: profileID) else {
            throw AccountProfileError.duplicateLabel(trimmedLabel)
        }
        guard profiles[index].label != trimmedLabel else { return }
        profiles[index].label = trimmedLabel
        persist()
    }

    /// Tombstones a profile. The caller removes the workspace and then the Keychain snapshot FIRST —
    /// this refuses to archive the selected profile while another active profile exists, so a
    /// switchable family can never end up with authentication that no row answers for.
    public func archive(profileID: String) throws {
        try validateArchive(profileID: profileID)
        let index = profiles.firstIndex(where: { $0.id == profileID && !$0.isArchived })!
        let family = profiles[index].family
        profiles[index].isArchived = true
        if preferredByFamily[family] == profileID {
            preferredByFamily.removeValue(forKey: family)
        }
        selectFirstProfileIfNeeded(family: family)
        persist()
    }

    func validateArchive(profileID: String) throws {
        try ensureRegistryWritable()
        guard let profile = profiles.first(where: { $0.id == profileID && !$0.isArchived }) else {
            throw AccountProfileError.profileNotFound(profileID)
        }
        if preferredProfileID(family: profile.family) == profileID,
           profiles(family: profile.family).count > 1 {
            throw AccountProfileError.removeSelectedProfile
        }
    }

    /// Resolves a CLI/UI reference — a profile id or a unique case-insensitive label match.
    public func resolve(reference: String, family: String) throws -> AccountProfile {
        let active = profiles(family: family)
        if let byID = active.first(where: { $0.id == reference }) { return byID }
        let folded = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = active.filter { $0.label.caseInsensitiveCompare(folded) == .orderedSame }
        if matches.count > 1 { throw AccountProfileError.ambiguousReference(reference) }
        guard let match = matches.first else { throw AccountProfileError.profileNotFound(reference) }
        return match
    }

    /// Re-reads the shared domain. The long-lived app calls this when its panels open so writes
    /// from another process show up without a relaunch.
    public func reloadFromDefaults() {
        load()
    }

    private func hasActiveLabel(_ label: String, family: String, excludingProfileID: String?) -> Bool {
        profiles.contains {
            $0.family == family
                && !$0.isArchived
                && $0.id != excludingProfileID
                && $0.label.caseInsensitiveCompare(label) == .orderedSame
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.storageKey) else {
            profiles = []
            preferredByFamily = [:]
            hasUnreadableRegistry = false
            return
        }
        do {
            let blob = try JSONDecoder().decode(Blob.self, from: data)
            var seenIDs = Set<String>()
            var seenIdentities = Set<String>()
            var seenLabels = Set<String>()
            var activeCounts: [String: Int] = [:]
            var sanitized: [AccountProfile] = []
            for var profile in blob.profiles {
                let label = profile.label.trimmingCharacters(in: .whitespacesAndNewlines)
                let identityKey = profile.identityKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard Self.isSupportedFamily(profile.family),
                      Self.isValidID(profile.id),
                      Self.isValidLabel(label),
                      !identityKey.isEmpty,
                      seenIDs.insert(profile.id).inserted,
                      profile.isArchived || seenIdentities.insert("\(profile.family)\u{1F}\(identityKey)").inserted,
                      profile.isArchived || seenLabels.insert("\(profile.family)\u{1F}\(label.lowercased())").inserted
                else {
                    throw RegistryValidationError.invalidProfile
                }
                if !profile.isArchived {
                    guard activeCounts[profile.family, default: 0] < Self.maxProfilesPerFamily else {
                        throw RegistryValidationError.profileLimitExceeded
                    }
                    activeCounts[profile.family, default: 0] += 1
                }
                profile.label = label
                profile.identityKey = identityKey
                sanitized.append(profile)
            }
            profiles = sanitized
            hasUnreadableRegistry = false
            let validIDs = Set(profiles.filter { !$0.isArchived }.map(\.id))
            preferredByFamily = blob.preferredByFamily.filter { family, id in
                Self.isSupportedFamily(family) && validIDs.contains(id)
            }
            let storedPreferred = preferredByFamily
            for family in Self.supportedFamilies {
                selectFirstProfileIfNeeded(family: family)
            }
            if preferredByFamily != storedPreferred {
                persist()
            }
        } catch {
            AppLog.error(.config, "account-profile store was undecodable; preserving it and blocking account writes: \(error.localizedDescription)")
            profiles = []
            preferredByFamily = [:]
            hasUnreadableRegistry = true
        }
    }

    private func persist() {
        guard !hasUnreadableRegistry else {
            AppLog.error(.config, "refusing to overwrite an unavailable account registry")
            return
        }
        let blob = Blob(profiles: profiles, preferredByFamily: preferredByFamily)
        guard let data = try? JSONEncoder().encode(blob) else {
            AppLog.error(.config, "failed to encode account profiles; keeping previous persisted state")
            return
        }
        defaults.set(data, forKey: Self.storageKey)
    }

    private func ensureRegistryWritable() throws {
        if hasUnreadableRegistry {
            throw AccountProfileError.registryUnreadable
        }
    }

    private func selectFirstProfileIfNeeded(family: String) {
        guard preferredProfileID(family: family) == nil,
              let firstProfile = profiles(family: family).first
        else {
            return
        }
        preferredByFamily[family] = firstProfile.id
    }

    nonisolated static func isValidLabel(_ label: String) -> Bool {
        guard !label.isEmpty, label.count <= maxLabelLength else { return false }
        guard !label.contains("/"), !label.contains("\\") else { return false }
        return !label.unicodeScalars.contains {
            $0.properties.generalCategory == .control
        }
    }

    nonisolated private static func isValidID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 128 else { return false }
        guard !id.contains("/"), !id.contains("\\") else { return false }
        return !id.unicodeScalars.contains {
            $0.properties.generalCategory == .control
        }
    }
}
