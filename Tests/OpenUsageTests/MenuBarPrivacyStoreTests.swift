import XCTest
@testable import OpenUsage

@MainActor
final class MenuBarPrivacyStoreTests: XCTestCase {
    private func makeDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.MenuBarPrivacy.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    /// capture probe를 `captured`에 고정하고 notification을 stub — 실제 window server 미접촉
    private func makeStore(
        _ name: String,
        defaults: UserDefaults? = nil,
        captured: @escaping @MainActor () -> Bool
    ) -> MenuBarPrivacyStore {
        MenuBarPrivacyStore(
            defaults: defaults ?? makeDefaults(name),
            probe: captured,
            installChangeNotifications: { _ in }
        )
    }

    func testDefaultsOnAndConcealsActiveCapture() {
        let store = makeStore("default", captured: { true })
        XCTAssertTrue(store.hideUsageWhileScreenSharing)
        XCTAssertTrue(store.screenIsCaptured)
        XCTAssertTrue(store.concealUsage)
    }

    func testCaptureAloneDoesNotConceal() {
        let defaults = makeDefaults("captureOnly")
        defaults.set(false, forKey: MenuBarPrivacyStore.key)
        let store = makeStore("captureOnly", defaults: defaults, captured: { true })
        store.refreshCaptureState()
        XCTAssertFalse(store.concealUsage, "A capture with the setting off must not conceal")
    }

    func testSettingAloneDoesNotConceal() {
        let store = makeStore("settingOnly", captured: { false })
        store.hideUsageWhileScreenSharing = true
        XCTAssertFalse(store.concealUsage, "The setting without an active capture must not conceal")
    }

    func testEnablingDuringCaptureConcealsImmediately() {
        let store = makeStore("enableDuringCapture", captured: { true })
        store.hideUsageWhileScreenSharing = true
        XCTAssertTrue(store.screenIsCaptured, "Enabling runs an immediate check, not just the poll")
        XCTAssertTrue(store.concealUsage)
    }

    func testConcealFollowsCaptureTransitions() {
        // strict concurrency에서 captured local 변경 경고를 피하려 reference box 사용
        final class CaptureFlag { var isOn = false }
        let capture = CaptureFlag()
        let store = makeStore("transitions", captured: { capture.isOn })
        store.hideUsageWhileScreenSharing = true
        XCTAssertFalse(store.concealUsage)

        capture.isOn = true
        store.refreshCaptureState()
        XCTAssertTrue(store.concealUsage)

        capture.isOn = false
        store.refreshCaptureState()
        XCTAssertFalse(store.concealUsage)
    }

    func testDisablingClearsCaptureStateImmediately() {
        let store = makeStore("disableClears", captured: { true })
        store.hideUsageWhileScreenSharing = true
        XCTAssertTrue(store.concealUsage)

        store.hideUsageWhileScreenSharing = false
        XCTAssertFalse(store.screenIsCaptured, "Opting out must drop the wordmark without waiting for a poll")
        XCTAssertFalse(store.concealUsage)
    }

    func testExplicitOffPersistsAcrossStores() {
        let defaults = makeDefaults("persist")
        makeStore("persistFirst", defaults: defaults, captured: { true }).hideUsageWhileScreenSharing = false

        // 동일 defaults의 새 store는 default-on fallback보다 저장된 opt-out 우선
        let relaunched = makeStore("persistSecond", defaults: defaults, captured: { true })
        XCTAssertFalse(relaunched.hideUsageWhileScreenSharing)
        XCTAssertFalse(relaunched.concealUsage)
    }

    func testStaleNotificationAfterDisableCannotReconceal() {
        let store = makeStore("staleEvent", captured: { true })
        store.hideUsageWhileScreenSharing = true
        store.hideUsageWhileScreenSharing = false
        // opt-out 이후 도착한 window-server notification이 재은닉하지 못하도록 설정 gate가 차단
        store.refreshCaptureState()
        XCTAssertFalse(store.concealUsage)
    }
}
