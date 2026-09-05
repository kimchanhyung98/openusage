import AppKit
import SwiftUI

/// 대시보드 푸터 trailing의 Options 메뉴 버튼 (Liquid Glass 캡슐).
/// glass 처리는 컨테이너 소유 — `Menu` 위의 `.buttonStyle(.glass)`는 자체 chrome에 밀려 flat 렌더.
/// 단축키는 상시 `PopoverKeyReader`가 처리, 메뉴 항목은 열림 중에만 발화 — 이중 발화 없음. ⌘Q만 항목 소유.
struct HeaderView: View {
    @Environment(AppContainer.self) private var container
    @Environment(LayoutStore.self) private var layout
    @Environment(WidgetDataStore.self) private var dataStore
    @Environment(UpdaterController.self) private var updater
    @Environment(PopoverTransparencyStore.self) private var transparency
    @Environment(\.colorScheme) private var colorScheme
    /// 현재 화면. `.dashboard`일 때만 이 컨트롤 표시.
    let screen: PopoverScreen

    private static let controlHeight: CGFloat = 28

    var body: some View {
        leadingControl
    }

    @ViewBuilder
    private var leadingControl: some View {
        if screen == .dashboard {
            optionsButton
                .fixedSize()
                .interactiveGlass(
                    in: Capsule(),
                    reinforced: transparency.effectiveStyle.needsChromeLegibilityBacking
                )
        }
    }

    /// `.menuStyle(.button)` + `.buttonStyle(.plain)`으로 메뉴 chrome 제거 — `interactiveGlass`가 표면 소유.
    private var optionsButton: some View {
        Menu {
            menuItems
        } label: {
            HStack(spacing: 5) {
                Text("Options")
                    .font(.system(size: 13, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(.leading, 14)
            .padding(.trailing, 12)
            .frame(height: Self.controlHeight)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// 메뉴 항목. Check for Updates는 Sparkle 체크 불가 시 자체 비활성 (`autoenablesItems`의 SwiftUI 부재 대응).
    /// 메뉴 열림 중엔 항목이 단축키 처리, 닫힘 중엔 `PopoverKeyReader`가 선점 소비 — 이중 발화 방지.
    @ViewBuilder
    private var menuItems: some View {
        Button { toggle(.customize) } label: {
            Label("Customize", systemImage: "slider.horizontal.3")
        }
        .keyboardShortcut(.return, modifiers: [])

        Button { toggle(.settings) } label: {
            Label("Settings", systemImage: "gearshape")
        }
        .keyboardShortcut(",")

        Divider()

        shareScreenshotMenu

        Button { updater.checkForUpdates() } label: {
            Label("Check for Updates…", systemImage: "arrow.triangle.2.circlepath")
        }
        .disabled(!updater.canCheckForUpdates)

        Divider()

        Button { AboutPanel.present() } label: {
            Label("About OpenUsage", systemImage: "info.circle")
        }
        Button(role: .destructive) { NSApplication.shared.terminate(nil) } label: {
            Label("Quit OpenUsage", systemImage: "power")
        }
        .keyboardShortcut("q") // ⌘Q — 다른 소유자 없음, 항목 등록 안전
    }

    /// 대시보드와 동일한 카드 목록·순서·제목의 "Share Screenshot" 서브메뉴.
    /// 우클릭 공유와 동일 렌더 경로 — 브랜드 PNG 클립보드 복사.
    @ViewBuilder
    private var shareScreenshotMenu: some View {
        let groups = container.presentedAccountGroups()
        Menu {
            if groups.isEmpty {
                // 스크린샷 대상 없음 — 빈 서브메뉴 대신 비활성 항목 표시
                Button("No Enabled Providers") {}
                    .disabled(true)
            } else {
                ForEach(groups) { group in
                    Button(container.accountCardTitle(for: group.provider)) { shareCard(group) }
                }
            }
        } label: {
            Label("Share Screenshot", systemImage: "square.and.arrow.up")
        }
    }

    /// 프로바이더 공유 카드 렌더 후 PNG 클립보드 복사.
    /// appearance는 팝오버 자체 `colorScheme` 사용 — `NSApp.effectiveAppearance` 추정 대신 화면 표시와 일치 보장.
    private func shareCard(_ group: ProviderGroup) {
        ShareCardRenderer.share(
            group: group,
            dataStore: dataStore,
            layout: layout,
            appearance: colorScheme,
            displayName: container.accountCardTitle(for: group.provider)
        )
    }

    private func toggle(_ screen: PopoverScreen) {
        withAnimation(Motion.modeSwitch) {
            layout.screen = layout.screen == screen ? .dashboard : screen
        }
    }
}
