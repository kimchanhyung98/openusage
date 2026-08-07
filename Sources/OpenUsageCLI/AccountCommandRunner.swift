import Foundation
import OpenUsage

/// Executes a read-only `openusage account` command against the shared profile registry. The app
/// writes the same UserDefaults domain, so a Settings switch and this CLI always agree. The CLI
/// never touches credentials, the Keychain, or the shell setup.
@MainActor
struct AccountCommandRunner {
    private let store: AccountProfilesStore

    init(defaults: UserDefaults) {
        self.store = AccountProfilesStore(defaults: defaults)
    }

    func run(_ command: AccountCommand) throws -> Int32 {
        guard !store.hasUnreadableRegistry else {
            throw AccountProfileError.registryUnreadable
        }
        switch command {
        case .list(let family, let json):
            return try list(family: family, json: json)
        case .current(let family):
            return current(family: family)
        }
    }

    private func list(family: String?, json: Bool) throws -> Int32 {
        let families = family.map { [$0] } ?? AccountProfilesStore.supportedFamilies
        if json {
            struct Row: Codable {
                var id: String
                var family: String
                var label: String
                var selected: Bool
            }
            let rows = families.flatMap { family in
                store.profiles(family: family).map { profile in
                    Row(
                        id: profile.id,
                        family: profile.family,
                        label: profile.label,
                        selected: store.preferredProfileID(family: family) == profile.id
                    )
                }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            FileHandle.standardOutput.write(try encoder.encode(rows))
            FileHandle.standardOutput.write(Data("\n".utf8))
            return 0
        }

        var printedAny = false
        for family in families {
            let profiles = store.profiles(family: family)
            guard !profiles.isEmpty else { continue }
            printedAny = true
            print("\(family):")
            let selectedID = store.preferredProfileID(family: family)
            for profile in profiles {
                let marker = profile.id == selectedID ? "*" : " "
                print("  \(marker) \(profile.label)")
            }
        }
        if !printedAny {
            print("No managed accounts. Add one in OpenUsage Settings.")
        }
        return 0
    }

    private func current(family: String?) -> Int32 {
        guard let family else {
            for family in AccountProfilesStore.supportedFamilies {
                print("\(family): \(store.preferredProfile(family: family)?.label ?? "-")")
            }
            return 0
        }
        // Scriptable spelling: the bare label on stdout, nothing when no account is selected.
        if let profile = store.preferredProfile(family: family) {
            print(profile.label)
        }
        return 0
    }
}

/// User-facing one-liners for store errors (exit 2 — the request was wrong, not the system).
func accountErrorMessage(_ error: AccountProfileError) -> String {
    error.userMessage
}
