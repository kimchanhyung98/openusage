import Accessibility
import CoreGraphics
import SwiftUI

enum AccountSettingsReorderDirection: Equatable, Sendable {
    case up
    case down

    var scrollAnchor: UnitPoint {
        switch self {
        case .up: .top
        case .down: .bottom
        }
    }
}

struct AccountSettingsDragGate: Equatable, Sendable {
    private(set) var isCancellationLatched = false

    var shouldHandle: Bool { !isCancellationLatched }

    mutating func cancelUntilGestureEnds() {
        isCancellationLatched = true
    }

    mutating func endGesture() {
        isCancellationLatched = false
    }
}

enum AccountSettingsReorder {
    private static let edgeInset: CGFloat = 44
    private static let edgeOvershoot: CGFloat = 24

    static func dragID(family: String, profileID: String) -> String {
        "settings-account:\(family):\(profileID)"
    }

    static func allowsReordering(profileCount: Int) -> Bool {
        profileCount > 1
    }

    static func direction(at location: CGPoint, viewport: CGRect) -> AccountSettingsReorderDirection? {
        guard viewport.width > 0,
              viewport.height > 0,
              location.x >= viewport.minX - edgeOvershoot,
              location.x <= viewport.maxX + edgeOvershoot,
              location.y >= viewport.minY - edgeOvershoot,
              location.y <= viewport.maxY + edgeOvershoot
        else {
            return nil
        }

        let inset = min(edgeInset, viewport.height / 3)
        if location.y <= viewport.minY + inset { return .up }
        if location.y >= viewport.maxY - inset { return .down }
        return nil
    }

    static func adjacentTarget(
        draggedID: String,
        direction: AccountSettingsReorderDirection,
        orderedIDs: [String]
    ) -> String? {
        guard let index = orderedIDs.firstIndex(of: draggedID) else { return nil }
        switch direction {
        case .up:
            guard index > orderedIDs.startIndex else { return nil }
            return orderedIDs[orderedIDs.index(before: index)]
        case .down:
            let next = orderedIDs.index(after: index)
            guard next < orderedIDs.endIndex else { return nil }
            return orderedIDs[next]
        }
    }
}

/// 한 provider family의 계정 순서 편집 surface.
struct AccountSettingsFamilyCard: View {
    @Environment(AppContainer.self) private var container
    @AppStorage(DensitySetting.key) private var density = DensitySetting.defaultValue

    let family: String
    let title: String
    let signInStates: [String: AccountSignInProbe.State]
    let reorderSpaceName: String
    @Binding var reorderLift: ReorderLift?
    let scrollViewportFrame: CGRect
    let scrollToAccount: (String, AccountSettingsReorderDirection) -> Void
    let onManage: (AccountProfile) -> Void
    let selection: (String) -> Binding<Bool>

    @State private var rowFrames: [String: CGRect] = [:]
    @State private var activeAccountID: String?
    @State private var activeProfileID: String?
    @State private var autoScrollDirection: AccountSettingsReorderDirection?
    @State private var autoScrollGeneration = 0
    @State private var autoScrollTask: Task<Void, Never>?
    @State private var dragGate = AccountSettingsDragGate()

    private var store: AccountProfilesStore { container.accountProfiles }

    var body: some View {
        let profiles = container.orderedAccountProfiles(for: family)

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                ProviderIcon(source: .providerMark(family), inset: 0.04)
                    .frame(width: density.headerIconSize, height: density.headerIconSize)
                Text(title)
                    .font(.system(size: density.headerPointSize, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 12)
            .padding(.top, density.controlRowPadding)
            .padding(.bottom, 4)

            ForEach(Array(profiles.enumerated()), id: \.element.id) { index, profile in
                profileRow(profile, position: index, total: profiles.count)
                if index < profiles.count - 1 {
                    Divider()
                        .padding(.horizontal, 12)
                }
            }
        }
        .animation(Motion.spring, value: profiles.map(\.id))
        .onPreferenceChange(ReorderFramePreferenceKey.self) { rowFrames = $0 }
        .onChange(of: store.profiles) {
            if let activeProfileID,
               !store.profiles.contains(where: {
                   $0.id == activeProfileID && $0.family == family && !$0.isArchived
               })
            {
                cancelAccountDrag(latchUntilGestureEnd: true)
            }
        }
        .onChange(of: container.layout.screen) { _, screen in
            if screen == .settings {
                dragGate.endGesture()
            } else {
                cancelAccountDrag(latchUntilGestureEnd: true)
            }
        }
        .onChange(of: container.transparency.popoverShown) { _, shown in
            if shown, container.layout.screen == .settings {
                dragGate.endGesture()
            } else if !shown {
                cancelAccountDrag(latchUntilGestureEnd: true)
            }
        }
        .onChange(of: reorderLift?.id) { _, liftID in
            if activeAccountID != nil, liftID == nil {
                cancelAccountDrag(latchUntilGestureEnd: true)
            }
        }
        .onAppear {
            if container.transparency.popoverShown, container.layout.screen == .settings {
                dragGate.endGesture()
            }
        }
        .onDisappear {
            cancelAccountDrag(latchUntilGestureEnd: true)
        }
    }

    private func profileRow(_ profile: AccountProfile, position: Int, total: Int) -> some View {
        let state = signInStates[profile.id] ?? .needsSignIn
        let dragID = AccountSettingsReorder.dragID(family: family, profileID: profile.id)
        let isSelected = store.preferredProfileID(family: family) == profile.id

        let row = HStack(alignment: .center, spacing: 8) {
            HStack(spacing: 5) {
                Text(displayLabel(profile.label))
                    .lineLimit(1)
                    .accessibilityLabel(profile.label)
                Button {
                    onManage(profile)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Manage \(profile.label) Account")
            }
            Spacer(minLength: 8)
            AccountStatusBadge(state: state)
            if total > 1 {
                Toggle("", isOn: selection(profile.id))
                    .settingsSwitchStyle()
                    .disabled(!state.isReady)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, density.controlRowPadding)

        return reorderableProfileRow(
            row,
            profile: profile,
            position: position,
            total: total,
            isSelected: isSelected
        )
        .opacity(activeAccountID == dragID ? 0 : 1)
        .id(dragID)
        .reorderFrame(id: dragID, in: .named(reorderSpaceName))
    }

    @ViewBuilder
    private func reorderableProfileRow<Content: View>(
        _ row: Content,
        profile: AccountProfile,
        position: Int,
        total: Int,
        isSelected: Bool
    ) -> some View {
        if AccountSettingsReorder.allowsReordering(profileCount: total) {
            row
                .contentShape(Rectangle())
                .highPriorityGesture(accountDragGesture(for: profile, profileCount: total))
                .accessibilityElement(children: .contain)
                .accessibilityLabel(profile.label)
                .accessibilityValue(
                    "\(isSelected ? "Selected" : "Not Selected"), Position \(position + 1) of \(total)"
                )
                .accessibilityActions {
                    if position > 0 {
                        Button("Move Up") {
                            moveAccount(profile, direction: .up, announcesResult: true)
                        }
                    }
                    if position < total - 1 {
                        Button("Move Down") {
                            moveAccount(profile, direction: .down, announcesResult: true)
                        }
                    }
                }
        } else {
            row.accessibilityValue(isSelected ? "Selected" : "Not Selected")
        }
    }

    private func accountDragGesture(for profile: AccountProfile, profileCount: Int) -> some Gesture {
        let dragID = AccountSettingsReorder.dragID(family: family, profileID: profile.id)
        return reorderDragGesture(
            id: dragID,
            coordinateSpaceName: reorderSpaceName,
            rowFrames: rowFrames,
            active: $activeAccountID,
            lift: $reorderLift,
            makeLift: { value in
                ReorderLift.make(
                    id: dragID,
                    payload: .settingsAccountRow(
                        label: displayLabel(profile.label),
                        state: signInStates[profile.id] ?? .needsSignIn,
                        isSelected: store.preferredProfileID(family: family) == profile.id,
                        showsSelectionToggle: profileCount > 1
                    ),
                    value: value,
                    frames: rowFrames
                )
            },
            orderedIDs: { orderedDragIDs },
            reorder: { targetID in
                guard let target = self.profile(forDragID: targetID) else { return false }
                return container.accountCardPresentation.reorder(
                    dragged: profile.id,
                    target: target.id,
                    family: family,
                    profiles: store.profiles(family: family)
                )
            },
            shouldHandle: { dragGate.shouldHandle },
            onChanged: { value in
                activeProfileID = profile.id
                updateAutoScroll(at: value.location, profile: profile)
            },
            onEnded: {
                finishAccountDrag()
            }
        )
    }

    private var orderedDragIDs: [String] {
        container.orderedAccountProfiles(for: family).map {
            AccountSettingsReorder.dragID(family: family, profileID: $0.id)
        }
    }

    private func profile(forDragID dragID: String) -> AccountProfile? {
        container.orderedAccountProfiles(for: family).first {
            AccountSettingsReorder.dragID(family: family, profileID: $0.id) == dragID
        }
    }

    private func displayLabel(_ label: String) -> String {
        label.count > 10 ? "\(label.prefix(10))…" : label
    }

    private func updateAutoScroll(at location: CGPoint, profile: AccountProfile) {
        guard let direction = AccountSettingsReorder.direction(at: location, viewport: scrollViewportFrame),
              AccountSettingsReorder.adjacentTarget(
                  draggedID: profile.id,
                  direction: direction,
                  orderedIDs: container.orderedAccountProfiles(for: family).map(\.id)
              ) != nil
        else {
            stopAutoScroll()
            return
        }
        startAutoScroll(profile: profile, direction: direction)
    }

    private func startAutoScroll(profile: AccountProfile, direction: AccountSettingsReorderDirection) {
        guard autoScrollDirection != direction else { return }
        stopAutoScroll()
        autoScrollDirection = direction
        autoScrollGeneration &+= 1
        let generation = autoScrollGeneration

        autoScrollTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(320))
            } catch {
                return
            }

            while !Task.isCancelled,
                  autoScrollGeneration == generation,
                  activeProfileID == profile.id,
                  autoScrollDirection == direction
            {
                guard moveAccount(profile, direction: direction, announcesResult: false) else { break }
                scrollToAccount(
                    AccountSettingsReorder.dragID(family: family, profileID: profile.id),
                    direction
                )
                do {
                    try await Task.sleep(for: .milliseconds(170))
                } catch {
                    return
                }
            }

            if autoScrollGeneration == generation {
                autoScrollDirection = nil
                autoScrollTask = nil
            }
        }
    }

    @discardableResult
    private func moveAccount(
        _ profile: AccountProfile,
        direction: AccountSettingsReorderDirection,
        announcesResult: Bool
    ) -> Bool {
        let ordered = container.orderedAccountProfiles(for: family)
        guard let targetID = AccountSettingsReorder.adjacentTarget(
            draggedID: profile.id,
            direction: direction,
            orderedIDs: ordered.map(\.id)
        ) else {
            return false
        }

        var moved = false
        withAnimation(Motion.spring) {
            moved = container.accountCardPresentation.reorder(
                dragged: profile.id,
                target: targetID,
                family: family,
                profiles: store.profiles(family: family)
            )
        }
        guard moved else { return false }
        Haptics.snap()

        if announcesResult,
           let position = container.orderedAccountProfiles(for: family).firstIndex(where: { $0.id == profile.id })
        {
            AccessibilityNotification.Announcement(
                "Moved \(profile.label) to position \(position + 1) of \(ordered.count)."
            ).post()
        }
        return true
    }

    private func stopAutoScroll() {
        autoScrollGeneration &+= 1
        autoScrollTask?.cancel()
        autoScrollTask = nil
        autoScrollDirection = nil
    }

    private func finishAccountDrag() {
        stopAutoScroll()
        activeAccountID = nil
        activeProfileID = nil
        reorderLift = nil
        dragGate.endGesture()
    }

    private func cancelAccountDrag(latchUntilGestureEnd: Bool) {
        stopAutoScroll()
        let ownsLift = reorderLift?.id.hasPrefix("settings-account:\(family):") == true
        if activeAccountID != nil || ownsLift { reorderLift = nil }
        activeAccountID = nil
        activeProfileID = nil
        if latchUntilGestureEnd { dragGate.cancelUntilGestureEnds() }
    }
}

struct AccountSettingsLiftRow: View {
    let label: String
    let state: AccountSignInProbe.State
    let isSelected: Bool
    let showsSelectionToggle: Bool

    @AppStorage(DensitySetting.key) private var density = DensitySetting.defaultValue

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(spacing: 5) {
                Text(label)
                    .lineLimit(1)
                Image(systemName: "ellipsis.circle")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            AccountStatusBadge(state: state)
            if showsSelectionToggle {
                Toggle("", isOn: .constant(isSelected))
                    .settingsSwitchStyle()
                    .disabled(!state.isReady)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, density.controlRowPadding)
    }
}
