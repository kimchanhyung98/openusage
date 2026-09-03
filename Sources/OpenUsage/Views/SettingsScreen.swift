import AppKit
import Combine
import KeyboardShortcuts
import SwiftUI
import UserNotifications

/// 팝오버 내 Settings 화면 — 대시보드·Customize에 이은 세 번째 모드.
/// 섹션은 Customize 스타일 카드로 단일 시각 언어 유지.
struct SettingsScreen: View {
    @Environment(AppContainer.self) private var container
    @Environment(UpdaterController.self) private var updater

    @State private var launchAtLogin = LaunchAtLoginSetting()
    @State private var commandLineTool = CommandLineToolInstaller()
    @AppStorage(TotalSpendSetting.key) private var showTotalSpend = true
    @AppStorage(AppearanceSetting.key) private var appearance = AppearanceSetting.system
    @AppStorage(TimeFormatSetting.key) private var timeFormat = TimeFormatSetting.fallback
    @AppStorage(DensitySetting.key) private var density = DensitySetting.defaultValue
    @AppStorage(LogLevelSetting.key) private var logLevel = LogLevelSetting.fallback
    /// 로그 경로 복사·파일 열기 실패 시 Advanced 행 아래 표시.
    @State private var logActionError: String?
    /// macOS 알림 권한 상태 — 미허용 + 트리거 on 시 경고 glyph·액션 버튼 노출.
    /// appear·트리거 on·앱 재활성 시 갱신.
    private enum NotificationsAuthState { case authorized, denied, notDetermined }
    @State private var notificationsAuth: NotificationsAuthState = .authorized

    var body: some View {
        PopoverScrollView {
            content
        }
    }

    private var content: some View {
        @Bindable var store = container.dataStore
        @Bindable var layout = container.layout
        @Bindable var updater = updater
        @Bindable var transparency = container.transparency
        @Bindable var privacy = container.privacy
        @Bindable var notifications = container.notificationSettings
        @Bindable var softLimit = container.softLimitSettings
        return VStack(alignment: .leading, spacing: density.sectionSpacing) {
            section("General") {
                // 활성 spend-capable 프로바이더 존재 시에만 카드 표시 — 이 토글 단독으로는 미노출
                row("Show Total Spend") {
                    Toggle("", isOn: $showTotalSpend)
                        .settingsSwitchStyle()
                }
                row("Launch at Login") {
                    Toggle("", isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { launchAtLogin.update(to: $0) }
                    ))
                        .settingsSwitchStyle()
                }
                if let launchAtLoginError = launchAtLogin.errorMessage {
                    inlineNotice(launchAtLoginError)
                }
                row("Global Shortcut") {
                    ShortcutRecorderField(name: .togglePopover)
                        .hoverTooltip("Open OpenUsage from anywhere")
                }
            }
            AccountsSettingsSection()
            ICloudSyncSettingsSection(sync: container.iCloudSync)
            section("Appearance") {
                row("Icon Style") {
                    picker($layout.menuBarStyle, options: MenuBarStyle.allCases, label: \.label)
                }
                row("Theme") {
                    picker($appearance, options: AppearanceSetting.allCases, label: \.label)
                        // 팝오버 패널은 preferredColorScheme 무시 — NSApp 수준 적용 필요
                        .onChange(of: appearance) {
                            AppearanceSetting.applyCurrent()
                        }
                }
                row("Density") {
                    picker($density, options: DensitySetting.allCases, label: \.label)
                }
                row("Time Format") {
                    picker($timeFormat, options: TimeFormatSetting.allCases, label: \.label)
                }
                // 시스템 접근성 설정·party easter egg에 양보 — 일시정지 시 아래 notice 표시
                row("Increase Transparency") {
                    Toggle("", isOn: $transparency.increaseTransparency)
                        .settingsSwitchStyle()
                        // party mode가 look 소유 중 — 토글 무효를 dim으로 표시, 저장값은 egg 종료 후 복원
                        .disabled(transparency.secretCodeActive)
                }
                // egg 우선: Party 실행 중엔 접근성 notice보다 party notice 우선
                if transparency.secretCodeActive {
                    inlineNotice("Party mode is on, so this stays paused.")
                } else if transparency.isPaused {
                    inlineNotice("macOS Reduce Transparency or Increase Contrast is on, so this stays paused.")
                }
                // 두 행은 시크릿 코드 입력 후에만 노출. Party Mode off는 egg 종료 (두 행 숨김),
                // Drunk Mode off는 party 유지 — Party off는 Drunk도 함께 해제.
                if transparency.secretCodeActive {
                    row("Party Mode") {
                        Toggle("", isOn: $transparency.partyModeActive)
                            .settingsSwitchStyle()
                    }
                    row("Drunk Mode") {
                        Toggle("", isOn: $transparency.drunkMode)
                            .settingsSwitchStyle()
                    }
                    // egg도 접근성 플래그에 양보 — party가 평범해 보이는 이유 설명
                    if transparency.partyPaused {
                        inlineNotice("macOS Reduce Transparency or Increase Contrast is on, so the party stays paused.")
                    }
                }
            }
            section("Usage Display") {
                row("Show Usage As") {
                    picker($store.meterStyle, options: WidgetDisplayMode.allCases, label: \.label)
                }
                row("Reset Times") {
                    picker($store.resetDisplayMode, options: ResetDisplayMode.allCases, label: \.label)
                }
                row("Always Show Pacing") {
                    Toggle("", isOn: $store.alwaysShowPacing)
                        .settingsSwitchStyle()
                        .hoverTooltip("Show how you're pacing on every metric, not just ones near their limit")
                }
                row("Soft Limit") {
                    Toggle("", isOn: $softLimit.enabled)
                        .settingsSwitchStyle()
                }
                if softLimit.enabled {
                    row("Window") {
                        picker($softLimit.window, options: SoftLimitWindow.allCases, label: \.label)
                    }
                    row("Threshold") {
                        picker(
                            $softLimit.thresholdPercent,
                            options: Array(SoftLimitSettingsStore.thresholdRange),
                            label: { "\($0)%" }
                        )
                    }
                    inlineNotice(
                        "This is an early guide only. Automatic stopping stays off until OpenUsage can safely "
                            + "bind every matching AI app and CLI session to an exact stop control."
                    )
                }
            }
            notificationsSection
            section("Privacy") {
                row("Hide From Screen Share") {
                    Toggle("", isOn: $privacy.hideUsageWhileScreenSharing)
                        .settingsSwitchStyle()
                }
                Text("While your screen is shared or recorded, the menu bar shows “OpenUsage” instead of your usage.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                row("Share Anonymous Usage") {
                    Toggle("", isOn: Binding(
                        get: { container.telemetry.isEnabled },
                        set: { container.telemetry.setEnabled($0) }
                    ))
                    .settingsSwitchStyle()
                }
                Text("Shares anonymous usage counts and error types to help improve OpenUsage. No account details, credentials, or usage values are sent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            commandLineSection
            advancedSection
            // 서명 릴리스 빌드만 feed 보유 — dev 빌드·`swift run`에선 숨김
            if updater.isActive {
                section("Updates") {
                    row("Update Automatically") {
                        Toggle("", isOn: $updater.automaticallyChecksForUpdates)
                            .settingsSwitchStyle()
                    }
                    row("Beta Updates") {
                        Toggle("", isOn: $updater.betaChannelEnabled)
                            .settingsSwitchStyle()
                            .hoverTooltip("Receive pre-release builds before they ship to everyone")
                    }
                    Button { updater.checkForUpdates() } label: {
                        Text("Check for Updates…").frame(maxWidth: .infinity)
                    }
                    .glassButtonStyle()
                    .controlSize(.regular)
                    .disabled(!updater.canCheckForUpdates)
                    .padding(.horizontal, 12)
                    .padding(.vertical, density.controlRowPadding)
                }
            }
            ScreenCrossLinkRow(
                systemImage: "slider.horizontal.3",
                title: "Customize",
                subtitle: "Choose what's visible and where",
                destination: .customize
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .task { await refreshNotificationsAuth() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            commandLineTool.refreshStatus()
            Task { await refreshNotificationsAuth() }
        }
    }

    // MARK: - Notifications

    /// Quota pace 알림 — 트리거별 토글 3개 (마스터 스위치 없음), 기본 전체 off.
    /// 권한 미허용 + 트리거 on 시 헤더 경고 glyph + 액션 행 표시. 첫 트리거 on에 권한 요청.
    private var notificationsSection: some View {
        @Bindable var notifications = container.notificationSettings
        let needsAttention = notificationsAuth != .authorized && anyToggleOn
        return VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            HStack(spacing: 6) {
                Text("Notifications")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if needsAttention {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .hoverTooltip(notificationsAuth == .denied
                            ? "Notifications are turned off for OpenUsage. Enable them in System Settings."
                            : "OpenUsage needs permission to send alerts.")
                }
            }
            .padding(.horizontal, 8)
            VStack(spacing: 0) {
                notifToggleRow(.underTenPercent, isOn: $notifications.underTenPercent)
                notifToggleRow(.healthyToClose, isOn: $notifications.healthyToClose)
                notifToggleRow(.closeToRunningOut, isOn: $notifications.closeToRunningOut)
                if needsAttention {
                    notificationsActionRow
                }
            }
            .cardSurface()
        }
        .onChange(of: anyToggleOn) { _, on in
            if on {
                // 첫 트리거 on 시 권한 요청 (미결정 상태에서만 프롬프트) 후 상태 갱신
                AppNotifications.shared.requestAuthorization()
                Task { await refreshNotificationsAuth() }
            }
        }
    }

    private func notifToggleRow(_ milestone: PaceMilestone, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 6) {
            Text(milestone.settingLabel)
            Image(systemName: "info.circle")
                .imageScale(.small)
                .foregroundStyle(.secondary)
                .hoverTooltip(milestone.tooltip)
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .settingsSwitchStyle()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, density.controlRowPadding)
    }

    /// 권한 거부 시 "Open System Settings", 미결정 시 "Allow Notifications" — 트리거 on일 때만 표시.
    private var notificationsActionRow: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                if notificationsAuth == .denied {
                    AppNotifications.shared.openSystemNotificationsSettings()
                } else {
                    AppNotifications.shared.requestAuthorization()
                    Task { await refreshNotificationsAuth() }
                }
            } label: {
                Text(notificationsAuth == .denied ? "Open System Settings" : "Allow Notifications")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 12)
            .padding(.vertical, density.controlRowPadding)
        }
    }

    private var anyToggleOn: Bool {
        container.notificationSettings.anyEnabled
    }

    /// macOS 권한 상태 조회 — 전 트리거 off면 경고 억제를 위해 authorized 유지.
    private func refreshNotificationsAuth() async {
        guard anyToggleOn else {
            notificationsAuth = .authorized
            return
        }
        let status = await AppNotifications.shared.authorizationStatus()
        switch status {
        case .denied: notificationsAuth = .denied
        case .notDetermined: notificationsAuth = .notDetermined
        default: notificationsAuth = .authorized
        }
    }

    // MARK: - Command Line

    private var commandLineSection: some View {
        section("Command Line") {
            row("Terminal Helper") {
                switch commandLineTool.status {
                case .installed:
                    Button("Uninstall") { commandLineTool.uninstall() }
                case .notInstalled:
                    Button("Install…") { commandLineTool.install() }
                case .conflict:
                    Text("Unavailable")
                        .foregroundStyle(.secondary)
                }
            }
            Text("Adds a global `openusage` command agents can use to monitor limits.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            if commandLineTool.status == .conflict {
                inlineNotice("\(commandLineTool.destinationPath) already exists and wasn't installed by OpenUsage.")
            } else if let errorMessage = commandLineTool.errorMessage {
                inlineNotice(errorMessage)
            }
        }
    }

    // MARK: - Advanced (logging)

    /// 로그 레벨 컨트롤 + 파일 로그 복사/열기. 레벨 변경은 재시작 없이 즉시 적용, 재실행 간 유지.
    private var advancedSection: some View {
        section("Advanced") {
            row("Log Level") {
                picker($logLevel, options: LogLevelSetting.allCases, label: \.label)
                    .onChange(of: logLevel) {
                        // 새 레벨을 파일 sink에 즉시 적용 후 전환 기록
                        AppLog.reloadLevel()
                        AppLog.info(.config, "Log level changed to \(logLevel.rawValue)")
                    }
            }
            logButton("Copy Log Path") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                guard pasteboard.setString(LogFile.url.path, forType: .string) else {
                    logActionError = "Couldn't copy the log path to the clipboard."
                    AppLog.warn(.config, "Copy log path failed")
                    return
                }
                logActionError = nil
            }
            logButton("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([LogFile.url])
                logActionError = nil
            }
            if let logActionError {
                inlineNotice(logActionError)
            }
        }
    }

    private func logButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity)
        }
        .glassButtonStyle()
        .controlSize(.regular)
        .padding(.horizontal, 12)
        .padding(.vertical, density.controlRowPadding)
    }

    // MARK: - Section / row scaffolding

    private func section(
        _ title: String,
        @ViewBuilder rows: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            VStack(spacing: 0) {
                rows()
            }
            .cardSurface()
        }
    }

    private func row(_ label: String, @ViewBuilder control: () -> some View) -> some View {
        HStack(spacing: 10) {
            Text(label)
            Spacer(minLength: 8)
            control()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, density.controlRowPadding)
    }

    private func inlineNotice(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Theme.notice)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func picker<Value: Hashable>(
        _ selection: Binding<Value>,
        options: [Value],
        label: @escaping (Value) -> String
    ) -> some View {
        Picker("", selection: selection) {
            ForEach(options, id: \.self) { option in
                Text(label(option)).tag(option)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }
}
