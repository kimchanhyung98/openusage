import XCTest
@testable import OpenUsage

@MainActor
final class PopoverTransparencyStoreTests: XCTestCase {
    private func makeDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.Transparency.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    /// accessibility flag를 고정한 store — host 설정과 무관하게 resolved style 결정적
    private func makeStore(_ name: String,
                           reduceTransparency: Bool = false,
                           increaseContrast: Bool = false) -> PopoverTransparencyStore {
        PopoverTransparencyStore(defaults: makeDefaults(name),
                                 reduceTransparency: reduceTransparency,
                                 increaseContrast: increaseContrast)
    }

    func testIncreaseTransparencyDefaultsOff() {
        let store = PopoverTransparencyStore(defaults: makeDefaults("default"))
        XCTAssertFalse(store.increaseTransparency)
    }

    func testIncreaseTransparencyPersists() {
        let defaults = makeDefaults("persist")
        PopoverTransparencyStore(defaults: defaults).increaseTransparency = true
        XCTAssertTrue(PopoverTransparencyStore(defaults: defaults).increaseTransparency)
    }

    func testIncreaseTransparencyTogglesBackOffAndPersists() {
        let defaults = makeDefaults("toggleBack")
        let store = PopoverTransparencyStore(defaults: defaults)
        store.increaseTransparency = true
        store.increaseTransparency = false
        XCTAssertFalse(PopoverTransparencyStore(defaults: defaults).increaseTransparency)
    }

    func testEggStateIsNeverPersisted() {
        let defaults = makeDefaults("ephemeral")
        let store = PopoverTransparencyStore(defaults: defaults)
        store.toggleSecretCode()
        store.drunkMode = true
        XCTAssertTrue(store.secretCodeActive)
        let reloaded = PopoverTransparencyStore(defaults: defaults)
        XCTAssertFalse(reloaded.secretCodeActive)
        XCTAssertFalse(reloaded.drunkMode)
    }

    func testTurningEggOffClearsDrunkMode() {
        let store = makeStore("drunk")
        store.toggleSecretCode()
        store.drunkMode = true
        store.toggleSecretCode()
        XCTAssertFalse(store.secretCodeActive)
        XCTAssertFalse(store.drunkMode, "Drunk Mode clears when the egg turns off")
    }

    // MARK: - Party Mode toggle / state machine (Normal 1, Increase Transparency 2, Party 3, Drunk 4)

    func testPartyModeToggleMirrorsTheEgg() {
        let store = makeStore("partyMirror")
        XCTAssertFalse(store.partyModeActive)
        store.toggleSecretCode()
        XCTAssertTrue(store.partyModeActive, "Party Mode reads the egg state")
        store.partyModeActive = false
        XCTAssertFalse(store.secretCodeActive)
    }

    func testPartyToggleOffFromState3ReturnsToBase() {
        let store = makeStore("p3base1")
        store.toggleSecretCode()
        XCTAssertEqual(store.effectiveStyle, .party)
        store.partyModeActive = false
        XCTAssertFalse(store.secretCodeActive)
        XCTAssertEqual(store.effectiveStyle, .opaque)
    }

    func testPartyToggleOffFromState4ClearsDrunkAndReturnsToBase() {
        let store = makeStore("p4base1")
        store.toggleSecretCode()
        store.drunkMode = true
        XCTAssertEqual(store.effectiveStyle, .drunk)
        store.partyModeActive = false
        XCTAssertFalse(store.secretCodeActive)
        XCTAssertFalse(store.drunkMode, "can't be drunk without the party")
        XCTAssertEqual(store.effectiveStyle, .opaque)
    }

    func testDrunkToggleOffStaysInPartyState3() {
        let store = makeStore("d4to3")
        store.toggleSecretCode()
        store.drunkMode = true
        store.drunkMode = false
        XCTAssertTrue(store.secretCodeActive, "still in the party")
        XCTAssertEqual(store.effectiveStyle, .party)
    }

    func testBase2PartyRendersAndReturnsToIncreaseTransparency() {
        let store = makeStore("base2party")
        store.increaseTransparency = true
        store.toggleSecretCode()
        XCTAssertEqual(store.effectiveStyle, .party)
        store.partyModeActive = false
        XCTAssertFalse(store.secretCodeActive)
        XCTAssertTrue(store.increaseTransparency, "base 2 restored")
    }

    func testBaseStateIsRememberedAcrossTheEgg() {
        let store = makeStore("remember")
        store.increaseTransparency = true
        store.toggleSecretCode()
        store.drunkMode = true
        store.partyModeActive = false
        XCTAssertFalse(store.secretCodeActive)
        XCTAssertTrue(store.increaseTransparency, "the prior base (Increase Transparency) is restored")
    }

    func testEffectiveStyleFollowsEgg() {
        let store = makeStore("style")
        store.toggleSecretCode()
        XCTAssertEqual(store.effectiveStyle, .party)
        XCTAssertEqual(store.surfaceTreatment, .translucent)
        store.drunkMode = true
        XCTAssertEqual(store.effectiveStyle, .drunk)
        store.toggleSecretCode()
        XCTAssertEqual(store.effectiveStyle, .opaque)
        XCTAssertEqual(store.surfaceTreatment, .opaque)
    }

    // MARK: - Accessibility clamp (the egg yields to Reduce Transparency / Increase Contrast)

    func testEggYieldsToReduceTransparency() {
        let store = makeStore("eggA11yReduce", reduceTransparency: true)
        store.toggleSecretCode()
        XCTAssertTrue(store.secretCodeActive, "the egg is active as state")
        XCTAssertEqual(store.effectiveStyle, .opaque, "but it renders opaque, yielding to the flag")
        XCTAssertEqual(store.surfaceTreatment, .opaque)
        store.drunkMode = true
        XCTAssertEqual(store.effectiveStyle, .opaque, "drunk is clamped too — no window fade")
    }

    func testEggYieldsToIncreaseContrast() {
        let store = makeStore("eggA11yContrast", increaseContrast: true)
        store.toggleSecretCode()
        XCTAssertEqual(store.effectiveStyle, .opaque)
    }

    func testPartyPausedReflectsAccessibility() {
        let clear = makeStore("partyPausedClear")
        clear.toggleSecretCode()
        XCTAssertFalse(clear.partyPaused)
        let reduced = makeStore("partyPausedReduce", reduceTransparency: true)
        reduced.toggleSecretCode()
        XCTAssertTrue(reduced.partyPaused)
        let noEgg = makeStore("partyPausedNoEgg", increaseContrast: true)
        XCTAssertFalse(noEgg.partyPaused)
    }

    // MARK: - Egg animation gate (no animation work while the popover is hidden — PR #784)

    func testEggAnimationsInactiveWhileHidden() {
        let store = makeStore("animHidden")
        store.toggleSecretCode()
        XCTAssertEqual(store.effectiveStyle, .party)
        XCTAssertFalse(store.eggAnimationsActive, "no animation while the popover is hidden")
        store.drunkMode = true
        XCTAssertEqual(store.effectiveStyle, .drunk)
        XCTAssertFalse(store.eggAnimationsActive, "drunk doesn't animate while hidden either")
    }

    func testEggAnimationsActiveOnInPlaceActivation() {
        let store = makeStore("animInPlace")
        store.setPopoverShown(true)
        XCTAssertFalse(store.eggAnimationsActive, "no egg yet")
        store.toggleSecretCode()
        XCTAssertTrue(store.eggAnimationsActive, "party animates the moment it's switched on while shown")
        store.drunkMode = true
        XCTAssertTrue(store.eggAnimationsActive, "drunk animates in place too")
    }

    func testEggAnimationsStopWhenPopoverHides() {
        let store = makeStore("animHide")
        store.setPopoverShown(true)
        store.toggleSecretCode()
        XCTAssertTrue(store.eggAnimationsActive)
        store.setPopoverShown(false)
        XCTAssertFalse(store.eggAnimationsActive, "closing the popover stops the animation")
    }

    func testEggAnimationsInactiveWithoutTheEgg() {
        let store = makeStore("animNoEgg")
        store.setPopoverShown(true)
        XCTAssertFalse(store.eggAnimationsActive, "a normal popover never animates")
        store.increaseTransparency = true
        XCTAssertFalse(store.eggAnimationsActive, "Increase Transparency is static, not animated")
    }

    func testEggAnimationsYieldToAccessibilityClamp() {
        for store in [makeStore("animReduce", reduceTransparency: true),
                      makeStore("animContrast", increaseContrast: true)] {
            store.setPopoverShown(true)
            store.toggleSecretCode()
            store.drunkMode = true
            XCTAssertEqual(store.effectiveStyle, .opaque)
            XCTAssertFalse(store.eggAnimationsActive, "a clamped egg renders opaque, so nothing animates")
        }
    }

    func testPopoverShownIsNeverPersisted() {
        let defaults = makeDefaults("shownEphemeral")
        let store = PopoverTransparencyStore(defaults: defaults)
        store.setPopoverShown(true)
        XCTAssertTrue(store.popoverShown)
        XCTAssertFalse(PopoverTransparencyStore(defaults: defaults).popoverShown, "not persisted")
    }
}
