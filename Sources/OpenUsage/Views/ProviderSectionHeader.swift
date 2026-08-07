import SwiftUI

/// Shared provider section header used by the dashboard and its lifted provider-reorder preview.
/// The provider mark and name lead, followed by the optional plan badge. Dashboard callers supply a
/// screenshot-copy action, revealed at the trailing edge while the header is hovered. Callers can also
/// supply an optional `warning` — the latest refresh error, rendered as a small amber
/// triangle beside the name whose hover tooltip carries the message (e.g. "Not logged in. Run `codex`
/// to authenticate."). The
/// optional `staleness` is the dashboard-only hint that the values shown are an aged snapshot still
/// revalidating: a short "Outdated" tag whose hover tooltip carries the precise age ("Last updated 3h
/// 12m ago"), so fossilized plan/limits never pass for current data.
struct ProviderSectionHeader: View {
    let provider: Provider
    var plan: String?
    var warning: String?
    /// Whether this provider's refresh is currently in flight — drives the small spinner beside the name
    /// so the section shows live feedback while values are being fetched (instead of silently sitting on
    /// the previous, possibly stale, numbers).
    var refreshing: Bool = false
    /// A muted "Outdated" hint shown only when the displayed snapshot has aged past its freshness window
    /// (dashboard only; `nil` in the reorder preview, which never surfaces staleness). Its tooltip carries
    /// the precise age.
    var staleness: StalenessHint?
    /// Dashboard-only screenshot action. The reorder preview omits it, while Customize uses its own
    /// row type and is unaffected by this header.
    var onCopyScreenshot: (() -> Bool)?
    /// Managed account choices. The selector changes only the dashboard's usage view.
    var accountOptions: [AccountUsageOption] = []
    var selectedAccountID: String?
    var onSelectAccount: ((String) -> Void)?
    /// True only for a card attached to a Settings-managed profile. Independently discovered
    /// config-directory cards keep their existing account-derived titles.
    var usesManagedAccountTitle = false
    /// Registered account profiles for this provider family. This can exceed the number of runtime
    /// cards when the selected account is running in the shared configuration home.
    var managedProfileCount = 0

    /// Header type and icon track the density setting like the rows do, so Compact shrinks the
    /// whole section anatomy — not just the rows under it.
    @AppStorage(DensitySetting.key) private var density = DensitySetting.defaultValue
    /// Read for the live card name: a rename lands in the account registry and re-titles the header
    /// without a relaunch (the `Provider`'s own name is baked at launch).
    @Environment(AppContainer.self) private var container
    /// Party easter egg: pulse the provider mark. Off by default everywhere else.
    @Environment(\.popoverPartyMode) private var partyMode
    @State private var isHovered = false

    init(
        provider: Provider,
        plan: String? = nil,
        warning: String? = nil,
        refreshing: Bool = false,
        staleness: StalenessHint? = nil,
        onCopyScreenshot: (() -> Bool)? = nil,
        accountOptions: [AccountUsageOption] = [],
        selectedAccountID: String? = nil,
        onSelectAccount: ((String) -> Void)? = nil,
        usesManagedAccountTitle: Bool = false,
        managedProfileCount: Int = 0
    ) {
        self.provider = provider
        self.plan = plan
        self.warning = warning
        self.refreshing = refreshing
        self.staleness = staleness
        self.onCopyScreenshot = onCopyScreenshot
        self.accountOptions = accountOptions
        self.selectedAccountID = selectedAccountID
        self.onSelectAccount = onSelectAccount
        self.usesManagedAccountTitle = usesManagedAccountTitle
        self.managedProfileCount = managedProfileCount
    }

    var body: some View {
        HStack(spacing: 5) {
            // The provider mark replaces the dashboard's visual drag grip. Reordering still belongs
            // to the whole header at the caller, so the logo itself stays presentational.
            ProviderIcon(source: provider.icon, inset: 0.04)
                .frame(width: density.headerIconSize, height: density.headerIconSize)
                .partyPulse(partyMode)
            // Baseline-aligned pair: the plan badge (and stale tag) are smaller type and sit on the
            // name's text baseline, so the words line up along the bottom rather than floating centered.
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                // Name + plan keep their width and stay on one line; under width pressure (a long plan
                // name like "Super Grok Heavy") the lower-priority stale tag truncates first instead of
                // wrapping the name to a second line.
                Text(Self.headerTitle(
                    for: provider,
                    resolvedDisplayName: container.displayName(for: provider),
                    usesManagedAccountTitle: usesManagedAccountTitle
                ))
                    .font(.system(size: density.headerPointSize, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let plan {
                    ProviderPlanBadge(plan: plan)
                        .layoutPriority(1)
                }
                // Tertiary, below the plan in hierarchy: outdated content, not something the user acts on.
                // Short by design ("Outdated") so it never pushes the plan name onto a second line — the
                // precise age rides in the hover tooltip. Hidden while a refresh is in flight: the spinner
                // already says "working on it".
                if let staleness, !refreshing {
                    Text(staleness.label)
                        .font(.system(size: density.planBadgePointSize))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .hoverTooltip(staleness.tooltip)
                }
            }
            if refreshing {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel("Refreshing")
            } else if let warning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.notice)
                    .hoverTooltip(warning)
                    .accessibilityLabel(warning)
            }
            Spacer(minLength: 8)
            if let onCopyScreenshot {
                CopyFeedbackButton(
                    accessibilityLabel: "Copy \(container.displayName(for: provider)) Screenshot",
                    isRevealed: isHovered,
                    action: onCopyScreenshot
                )
            }
            if Self.shouldShowAccountPicker(
                managedProfileCount: managedProfileCount,
                runtimeOptionCount: accountOptions.count
            ),
               let selectedAccountID,
               let onSelectAccount {
                AccountUsagePicker(
                    options: accountOptions,
                    selectedID: selectedAccountID,
                    onSelect: onSelectAccount
                )
            }
        }
        .padding(.leading, 2)
        .padding(.trailing, 4)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

extension ProviderSectionHeader {
    static func shouldShowAccountPicker(managedProfileCount: Int, runtimeOptionCount: Int) -> Bool {
        managedProfileCount > 1 && runtimeOptionCount > 0
    }

    /// Settings-managed cards are alternate views of one provider and share its family title.
    /// Independently discovered cards preserve the account-derived title they had before managed
    /// switching existed.
    static func headerTitle(
        for provider: Provider,
        resolvedDisplayName: String,
        usesManagedAccountTitle: Bool
    ) -> String {
        guard usesManagedAccountTitle else { return resolvedDisplayName }
        let family = ProviderAccountID.family(of: provider.id)
        return ProviderAccountID.families.contains(family) ? family.capitalized : resolvedDisplayName
    }
}

/// A compact, always-visible managed-account selector.
struct AccountUsageOption: Identifiable, Hashable {
    let id: String
    let title: String
}

private struct AccountUsagePicker: View {
    let options: [AccountUsageOption]
    let selectedID: String
    let onSelect: (String) -> Void

    private var selectedTitle: String {
        options.first(where: { $0.id == selectedID })?.title ?? "Account"
    }

    var body: some View {
        Menu {
            ForEach(options) { option in
                Button {
                    onSelect(option.id)
                } label: {
                    if option.id == selectedID {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(selectedTitle)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("Usage Account")
        .accessibilityValue(selectedTitle)
    }
}

struct ProviderPlanBadge: View {
    let plan: String

    @AppStorage(DensitySetting.key) private var density = DensitySetting.defaultValue

    var body: some View {
        // Plain text — no pill/capsule — for a cleaner header. Secondary (not tertiary): the plan
        // name is information the user reads, and tertiary on glass is reserved for inactive
        // content. The smaller point size alone keeps it subordinate to metric values.
        Text(plan)
            .font(.system(size: density.planBadgePointSize))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

struct ReorderGrip: View {
    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(width: 16, height: 22)
            .contentShape(Rectangle())
    }
}
