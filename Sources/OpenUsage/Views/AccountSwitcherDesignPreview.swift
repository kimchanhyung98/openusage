import Foundation
import SwiftUI

/// UI-only account switching exploration. The rows and actions are intentionally mock data: this
/// surface answers how profile setup and new-session selection should read before the account stores,
/// login lifecycle, and child-process execution are designed.
struct AccountSwitcherDesignPreview: View {
    @AppStorage(DensitySetting.key) private var density = DensitySetting.defaultValue
    @State private var isCreateProfileFlowPresented = false
    @State private var createProviderID = "claude"
    @State private var editingAccount: AccountSwitcherDesignEditor?
    @State private var profilesByProvider: [String: [AccountSwitcherMockProfile]] =
        AccountSwitcherDesignData.settingsProfiles
    @State private var selectedProfileIDs: [String: String] = [
        "claude": "claude-personal",
        "codex": "codex-personal"
    ]

    private var profileHomesByProvider: [String: [String]] {
        profilesByProvider.mapValues { profiles in profiles.map(\.detail) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            HStack(spacing: 5) {
                Text("Accounts")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Button {
                    beginCreating(providerID: "claude")
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(-6)
                .accessibilityLabel("Account Settings")
            }
            .padding(.horizontal, 8)
            VStack(spacing: 0) {
                providerCard(providerID: "claude", title: "Claude")
                Divider()
                    .padding(.horizontal, 12)
                providerCard(providerID: "codex", title: "Codex")
            }
            .cardSurface()
        }
        .sheet(isPresented: $isCreateProfileFlowPresented) {
            AccountProfileCreationDesignSheet(
                initialProviderID: createProviderID,
                profileHomesByProvider: profileHomesByProvider
            ) { providerID, label, home in
                addProfile(providerID: providerID, label: label, home: home)
            }
        }
        .sheet(item: $editingAccount) { editor in
            AccountProfileManagementDesignSheet(
                providerTitle: editor.providerTitle,
                profile: editor.profile,
                onSave: { label, home in
                    updateProfile(editor.profile.id, providerID: editor.providerID) { profile in
                        profile = AccountSwitcherDesignData.updatedProfile(
                            profile,
                            label: label,
                            detail: home
                        )
                    }
                },
                onSignIn: {
                    updateProfile(editor.profile.id, providerID: editor.providerID) { profile in
                        profile.status = "Ready"
                        profile.isHealthy = true
                    }
                },
                onRemove: {
                    removeProfile(editor.profile.id, providerID: editor.providerID)
                }
            )
        }
    }

    private func providerCard(providerID: String, title: String) -> some View {
        let profiles = profilesByProvider[providerID] ?? []

        return providerSection(title) {
            if providerID == "claude" {
                if let profile = profiles.first {
                    singleProfileRow(profile, providerID: providerID, title: title)
                }
            } else {
                multipleAccountsState(profiles, providerID: providerID, title: title)
            }
        }
    }

    private func providerSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: density.headerPointSize, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.top, density.controlRowPadding)
                .padding(.bottom, 4)
            content()
        }
    }

    private func singleProfileRow(
        _ profile: AccountSwitcherMockProfile,
        providerID: String,
        title: String
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            profileSummary(profile)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                AccountStatusBadge(status: profile.status, isHealthy: profile.isHealthy)
                Button("Manage…") {
                    beginEditing(profile, providerID: providerID, title: title)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, density.controlRowPadding)
    }

    private func multipleAccountsState(
        _ profiles: [AccountSwitcherMockProfile],
        providerID: String,
        title: String
    ) -> some View {
        VStack(spacing: 0) {
            if profiles.count > 1 {
                ForEach(profiles) { profile in
                    multipleProfileRow(profile, providerID: providerID, title: title)
                    if profile.id != profiles.last?.id {
                        Divider()
                            .padding(.horizontal, 12)
                    }
                }
            } else {
                Text("Add a second account to compare profiles.")
                    .font(.system(size: density.planBadgePointSize))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, density.controlRowPadding)
            }
        }
    }

    private func multipleProfileRow(
        _ profile: AccountSwitcherMockProfile,
        providerID: String,
        title: String
    ) -> some View {
        let isSelected = selectedProfileIDs[providerID] == profile.id

        return HStack(alignment: .top, spacing: 8) {
            profileSummary(profile)
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 5) {
                AccountStatusBadge(status: profile.status, isHealthy: profile.isHealthy)
                HStack(spacing: 6) {
                    Button("Manage…") {
                        beginEditing(profile, providerID: providerID, title: title)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Toggle(
                        "",
                        isOn: profileSelectionBinding(providerID: providerID, profileID: profile.id)
                    )
                    .settingsSwitchStyle()
                    .disabled(!profile.isHealthy)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, density.controlRowPadding)
        .accessibilityValue(isSelected ? "Selected" : "Not Selected")
    }

    private func profileSummary(_ profile: AccountSwitcherMockProfile) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(profile.label)
                .font(.system(size: density.headerPointSize, weight: .semibold))
                .lineLimit(1)
            Text(profile.detail)
                .font(.system(size: density.planBadgePointSize))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func profileSelectionBinding(providerID: String, profileID: String) -> Binding<Bool> {
        Binding(
            get: { selectedProfileIDs[providerID] == profileID },
            set: { isSelected in
                if isSelected {
                    selectedProfileIDs[providerID] = profileID
                } else if selectedProfileIDs[providerID] == profileID {
                    selectedProfileIDs[providerID] = nil
                }
            }
        )
    }

    private func beginCreating(providerID: String) {
        createProviderID = providerID
        isCreateProfileFlowPresented = true
    }

    private func beginEditing(
        _ profile: AccountSwitcherMockProfile,
        providerID: String,
        title: String
    ) {
        editingAccount = AccountSwitcherDesignEditor(
            providerID: providerID,
            providerTitle: title,
            profile: profile
        )
    }

    private func addProfile(providerID: String, label: String, home: String) {
        let existingProfiles = profilesByProvider[providerID] ?? []
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let index = existingProfiles.count + 1
        let profile = AccountSwitcherMockProfile(
            id: "\(providerID)-\(UUID().uuidString)",
            label: trimmedLabel.isEmpty ? "Profile \(index)" : trimmedLabel,
            detail: home,
            status: "Ready",
            isSelected: false,
            isHealthy: true
        )
        profilesByProvider[providerID, default: []].append(profile)
    }

    private func updateProfile(
        _ profileID: String,
        providerID: String,
        update: (inout AccountSwitcherMockProfile) -> Void
    ) {
        guard var profiles = profilesByProvider[providerID],
              let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        update(&profiles[index])
        profilesByProvider[providerID] = profiles
    }

    private func removeProfile(_ profileID: String, providerID: String) {
        profilesByProvider[providerID]?.removeAll { $0.id == profileID }
        if selectedProfileIDs[providerID] == profileID {
            selectedProfileIDs[providerID] = nil
        }
    }
}

struct AccountSwitcherMockProfile: Identifiable {
    let id: String
    var label: String
    var detail: String
    var status: String
    var isSelected: Bool
    var isHealthy: Bool
}

struct AccountSwitcherMockPreview {
    let selectedProfileID: String
    let profiles: [AccountSwitcherMockProfile]

    var selectedProfile: AccountSwitcherMockProfile? {
        profiles.first { $0.id == selectedProfileID }
    }
}

enum AccountSwitcherDesignData {
    static let claudeCode = AccountSwitcherMockPreview(
        selectedProfileID: "claude-personal",
        profiles: [
            AccountSwitcherMockProfile(
                id: "claude-personal",
                label: "Personal",
                detail: "~/.claude",
                status: "Ready",
                isSelected: true,
                isHealthy: true
            )
        ]
    )

    static let codex = AccountSwitcherMockPreview(
        selectedProfileID: "codex-personal",
        profiles: [
            AccountSwitcherMockProfile(
                id: "codex-personal",
                label: "Personal",
                detail: "~/.codex",
                status: "Ready",
                isSelected: true,
                isHealthy: true
            ),
            AccountSwitcherMockProfile(
                id: "codex-client",
                label: "Client",
                detail: "~/.codex-alpha",
                status: "Ready",
                isSelected: false,
                isHealthy: true
            )
        ]
    )

    static let settingsProfiles: [String: [AccountSwitcherMockProfile]] = [
        "claude": claudeCode.profiles,
        "codex": codex.profiles
    ]

    static let maxAccountCount = 10
    static let profileSuffixes = [
        "alpha", "beta", "gamma", "delta", "epsilon",
        "zeta", "eta", "theta", "iota"
    ]

    static func nextProfileHome(
        providerID: String,
        reservedHomes: [String],
        fileManager: FileManager = .default
    ) -> String? {
        guard providerID == "claude" || providerID == "codex",
              let defaultHome = defaultHome(providerID: providerID, index: 1) else {
            return nil
        }
        guard reservedHomes.count < maxAccountCount else { return nil }

        var occupiedPaths = Set(
            reservedHomes.map { absolutePath(for: $0, fileManager: fileManager) }
        )
        let defaultPath = absolutePath(for: defaultHome, fileManager: fileManager)
        let defaultExists = fileManager.fileExists(atPath: defaultPath)

        if defaultExists {
            occupiedPaths.insert(defaultPath)
        }

        for existingHome in existingSuffixedHomes(providerID: providerID, fileManager: fileManager) {
            occupiedPaths.insert(absolutePath(for: existingHome, fileManager: fileManager))
        }

        guard occupiedPaths.count < maxAccountCount else { return nil }

        if !occupiedPaths.contains(defaultPath) {
            return defaultHome
        }

        for suffix in profileSuffixes {
            let candidate = suffixedHome(providerID: providerID, suffix: suffix)
            let candidatePath = absolutePath(for: candidate, fileManager: fileManager)
            if !occupiedPaths.contains(candidatePath) {
                return candidate
            }
        }
        return nil
    }

    static func isAvailableProfileHome(
        providerID: String,
        displayPath: String,
        reservedHomes: [String],
        fileManager: FileManager = .default
    ) -> Bool {
        guard providerID == "claude" || providerID == "codex" else { return false }
        let trimmedPath = displayPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return false }

        let candidatePath = absolutePath(for: trimmedPath, fileManager: fileManager)
        guard !fileManager.fileExists(atPath: candidatePath) else { return false }

        var occupiedPaths = Set(
            reservedHomes.map { absolutePath(for: $0, fileManager: fileManager) }
        )
        let defaultHome = defaultHome(providerID: providerID, index: 1)
        if let defaultHome {
            let defaultPath = absolutePath(for: defaultHome, fileManager: fileManager)
            if fileManager.fileExists(atPath: defaultPath) {
                occupiedPaths.insert(defaultPath)
            }
        }
        for existingHome in existingSuffixedHomes(providerID: providerID, fileManager: fileManager) {
            occupiedPaths.insert(absolutePath(for: existingHome, fileManager: fileManager))
        }

        guard occupiedPaths.count < maxAccountCount else { return false }
        return !occupiedPaths.contains(candidatePath)
    }

    static func defaultProfileLabel(for displayPath: String?) -> String {
        guard let displayPath,
              let lastComponent = displayPath.split(separator: "/").last else {
            return "Account"
        }
        let component = String(lastComponent)
        if component == ".claude" || component == ".codex" {
            return "Personal"
        }
        if let suffix = component.split(separator: "-").last, !suffix.isEmpty {
            return String(suffix)
        }
        return "Account"
    }

    static func shellPath(for displayPath: String) -> String {
        if displayPath == "~" {
            return "$HOME"
        }
        if displayPath.hasPrefix("~/") {
            return "$HOME/" + String(displayPath.dropFirst(2))
        }
        return displayPath
    }

    static func signInCommand(providerID: String, displayPath: String) -> String? {
        let trimmedPath = displayPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return nil }
        let scopedHome = shellPath(for: trimmedPath)
        switch providerID {
        case "claude": return "env CLAUDE_CONFIG_DIR=\"\(scopedHome)\" claude login"
        case "codex": return "env CODEX_HOME=\"\(scopedHome)\" codex login"
        default: return nil
        }
    }

    static func updatedProfile(
        _ profile: AccountSwitcherMockProfile,
        label: String,
        detail: String
    ) -> AccountSwitcherMockProfile {
        var updated = profile
        updated.label = label
        updated.detail = detail
        return updated
    }

    static func defaultHome(providerID: String, index: Int) -> String? {
        guard index >= 1 else { return nil }
        if index == 1 {
            switch providerID {
            case "claude": return "~/.claude"
            case "codex": return "~/.codex"
            default: return nil
            }
        }

        let suffixIndex = index - 2
        guard profileSuffixes.indices.contains(suffixIndex) else { return nil }
        return suffixedHome(providerID: providerID, suffix: profileSuffixes[suffixIndex])
    }

    private static func suffixedHome(providerID: String, suffix: String) -> String {
        "~/.\(providerID)-\(suffix)"
    }

    private static func existingSuffixedHomes(
        providerID: String,
        fileManager: FileManager
    ) -> [String] {
        let prefix = ".\(providerID)-"
        let homeURL = fileManager.homeDirectoryForCurrentUser
        guard let names = try? fileManager.contentsOfDirectory(atPath: homeURL.path) else {
            return []
        }

        return names
            .filter { name in
                guard name.hasPrefix(prefix), name.count > prefix.count else { return false }
                return fileManager.fileExists(atPath: homeURL.appendingPathComponent(name).path)
            }
            .map { "~/\($0)" }
    }

    private static func absolutePath(for displayPath: String, fileManager: FileManager) -> String {
        if displayPath == "~" {
            return fileManager.homeDirectoryForCurrentUser.standardizedFileURL.path
        }
        if displayPath.hasPrefix("~/") {
            return fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(String(displayPath.dropFirst(2)))
                .standardizedFileURL
                .path
        }
        return URL(fileURLWithPath: displayPath).standardizedFileURL.path
    }

    static func preview(for providerID: String) -> AccountSwitcherMockPreview? {
        switch providerID {
        case "claude": claudeCode
        case "codex": codex
        default: nil
        }
    }
}

private struct AccountSwitcherDesignEditor: Identifiable {
    let providerID: String
    let providerTitle: String
    let profile: AccountSwitcherMockProfile

    var id: String { profile.id }
}

struct AccountSwitcherPreviewMenu: View {
    /// Dashboard-only usage preview. This selection is intentionally local to the menu and never
    /// changes the Settings toggle that controls the profile used for new sessions.
    let preview: AccountSwitcherMockPreview
    @State private var selectedProfileID: String

    init(preview: AccountSwitcherMockPreview) {
        self.preview = preview
        _selectedProfileID = State(initialValue: preview.selectedProfileID)
    }

    private var selectedProfile: AccountSwitcherMockProfile? {
        preview.profiles.first { $0.id == selectedProfileID }
    }

    private var connectedProfiles: [AccountSwitcherMockProfile] {
        preview.profiles.filter(\.isHealthy)
    }

    @ViewBuilder
    var body: some View {
        if connectedProfiles.count > 1 {
            Menu {
                ForEach(connectedProfiles) { profile in
                    Button {
                        selectedProfileID = profile.id
                    } label: {
                        if profile.id == selectedProfileID {
                            Label(profile.label, systemImage: "checkmark")
                        } else {
                            Text(profile.label)
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(selectedProfile?.label ?? "Choose")
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel("Switch Account")
            .accessibilityValue(selectedProfile?.label ?? "None")
        }
    }
}
