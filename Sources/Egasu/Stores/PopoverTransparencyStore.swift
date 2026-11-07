import AppKit
import Observation

/// popover transparency의 단일 출처 — persisted "Increase Transparency" 설정, ephemeral 이스터에그 상태,
/// 둘 다 양보해야 하는 라이브 macOS 접근성 flag 묶음
/// SwiftUI(`surfaceTreatment`)와 AppKit panel(`effectiveStyle`)이 같은 store를 읽어 표면·window 불일치 방지
@MainActor
@Observable
final class PopoverTransparencyStore {
    static let key = "increaseTransparency"

    /// persisted 설정 (기본 off) — view-local `@AppStorage` 대신 여기 저장해 AppKit panel과 값 일치 보장
    /// no-op guard로 불필요한 defaults 쓰기와 `UserDefaults.didChangeNotification` 발생 방지
    var increaseTransparency: Bool {
        didSet {
            guard increaseTransparency != oldValue else { return }
            defaults.set(increaseTransparency, forKey: Self.key)
        }
    }

    /// ephemeral 이스터에그 상태 — 미persist로 종료 시 해제, run 내 panel 열닫음에는 유지
    private(set) var secretCodeActive = false
    /// "Drunk Mode" — `secretCodeActive` 동안만 유효, egg 종료 시 함께 해제
    var drunkMode = false

    /// popover의 현재 on-screen 여부 — runtime 전용, `StatusItemController` show/hide chokepoint에서 설정
    /// SwiftUI egg가 visible 동안만 animation loop를 mount하는 gate
    /// occlusion·window key 상태에서 파생하지 않는 규칙 — Space 전환 중 일시 occlusion이 animation을 얼릴 수 있음
    private(set) var popoverShown = false

    /// 라이브 시스템 접근성 flag — `NSWorkspace`에서 읽고 변경 알림 시 갱신
    private(set) var reduceTransparency: Bool
    private(set) var increaseContrast: Bool

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var accessibilityObservation: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        reduceTransparency: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
        increaseContrast: Bool = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    ) {
        self.defaults = defaults
        self.increaseTransparency = defaults.bool(forKey: Self.key)
        // flag 기본값은 라이브 `NSWorkspace` 값, 테스트에서 접근성 clamp를 결정적으로 검증하도록 주입 가능
        self.reduceTransparency = reduceTransparency
        self.increaseContrast = increaseContrast
        startObservingAccessibility()
    }

    deinit { accessibilityObservation?.cancel() }

    /// 전체 code 입력 시 `TooMuchTransparencyKeyReader`가 호출 — 재입력으로 egg off
    /// 종료 시 base 상태로 복귀, persisted `increaseTransparency`는 그대로 보존
    func toggleSecretCode() {
        setSecretCode(!secretCodeActive)
    }

    /// Settings "Party Mode" toggle (egg 활성 중에만 노출) — `false` 설정은 egg 전체 종료
    /// 진입 경로는 secret code뿐이라 UI에서 `set(true)` 도달 불가, off 시 Drunk Mode도 함께 해제
    var partyModeActive: Bool {
        get { secretCodeActive }
        set { setSecretCode(newValue) }
    }

    /// egg on/off의 단일 지점 — cheat code와 Party Mode toggle이 한 종료 경로 공유, 종료 시 Drunk Mode 해제
    private func setSecretCode(_ active: Bool) {
        guard active != secretCodeActive else { return }
        secretCodeActive = active
        if !active { drunkMode = false }
        AppLog.info(.statusItem, "Too-much-transparency egg \(active ? "enabled" : "disabled")")
    }

    /// `StatusItemController` show/hide chokepoint에서 on-screen flag 반전 — 변경 시에만 반영
    /// `effectiveStyle`과 직교 — SwiftUI egg mount gate만 재렌더, AppKit backdrop crossfade에는 무영향
    func setPopoverShown(_ shown: Bool) {
        guard shown != popoverShown else { return }
        popoverShown = shown
    }

    /// panel과 SwiftUI 표면이 함께 렌더링하는 resolved level
    var effectiveStyle: PopoverTransparencyStyle {
        PopoverTransparencyStyle.resolve(
            increaseTransparency: increaseTransparency,
            secretCodeActive: secretCodeActive,
            drunkMode: drunkMode,
            reduceTransparency: reduceTransparency,
            increaseContrast: increaseContrast
        )
    }

    var surfaceTreatment: PopoverSurfaceTreatment { effectiveStyle.surfaceTreatment }

    /// egg animation loop가 mount되어야 하는 정확한 조건 — popover on-screen이면서 resolved style이 party·drunk
    /// `effectiveStyle`을 읽으므로 접근성 clamp 시 code가 켜져 있어도 animation 없음으로 판정
    var eggAnimationsActive: Bool {
        popoverShown && (effectiveStyle == .party || effectiveStyle == .drunk)
    }

    /// toggle on인데 시스템 접근성 설정이 override 중인 상태 — Settings의 "paused" 안내 근거
    var isPaused: Bool {
        increaseTransparency && (reduceTransparency || increaseContrast)
    }

    /// egg 활성인데 접근성 설정이 opaque로 clamp 중인 상태 — party가 안 보이는 이유를 Settings에서 설명
    var partyPaused: Bool {
        secretCodeActive && (reduceTransparency || increaseContrast)
    }

    /// 접근성 display 옵션은 `NSWorkspace` 자체 notification center에 게시 (`.default` 아님)
    /// payload 없는 알림이라 main actor에서 flag 재독 — Swift 6 strict concurrency의 non-`Sendable` `Notification`도 회피
    private func startObservingAccessibility() {
        let center = NSWorkspace.shared.notificationCenter
        let name = NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
        accessibilityObservation = Task { [weak self] in
            for await _ in center.notifications(named: name) {
                self?.refreshAccessibilityFlags()
            }
        }
    }

    private func refreshAccessibilityFlags() {
        let workspace = NSWorkspace.shared
        reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
        increaseContrast = workspace.accessibilityDisplayShouldIncreaseContrast
    }
}
