import XCTest
@testable import OpenUsage

final class PopoverTransparencyStyleTests: XCTestCase {
    private func resolve(increase: Bool, secretCode: Bool, drunkMode: Bool,
                         reduceTransparency: Bool, increaseContrast: Bool) -> PopoverTransparencyStyle {
        PopoverTransparencyStyle.resolve(
            increaseTransparency: increase,
            secretCodeActive: secretCode,
            drunkMode: drunkMode,
            reduceTransparency: reduceTransparency,
            increaseContrast: increaseContrast
        )
    }

    func testDefaultIsOpaque() {
        XCTAssertEqual(resolve(increase: false, secretCode: false, drunkMode: false,
                               reduceTransparency: false, increaseContrast: false), .opaque)
    }

    func testProperToggleIncreasesWhenNoSystemFlags() {
        XCTAssertEqual(resolve(increase: true, secretCode: false, drunkMode: false,
                               reduceTransparency: false, increaseContrast: false), .increased)
    }

    func testProperToggleYieldsToReduceTransparency() {
        XCTAssertEqual(resolve(increase: true, secretCode: false, drunkMode: false,
                               reduceTransparency: true, increaseContrast: false), .opaque)
    }

    func testProperToggleYieldsToIncreaseContrast() {
        XCTAssertEqual(resolve(increase: true, secretCode: false, drunkMode: false,
                               reduceTransparency: false, increaseContrast: true), .opaque)
    }

    func testSecretCodeIsPartyEvenWhenProperToggleIsOff() {
        XCTAssertEqual(resolve(increase: false, secretCode: true, drunkMode: false,
                               reduceTransparency: false, increaseContrast: false), .party)
    }

    func testDrunkModeIsDrunk() {
        XCTAssertEqual(resolve(increase: false, secretCode: true, drunkMode: true,
                               reduceTransparency: false, increaseContrast: false), .drunk)
    }

    func testDrunkModeIsIgnoredWithoutTheSecretCode() {
        XCTAssertEqual(resolve(increase: false, secretCode: false, drunkMode: true,
                               reduceTransparency: false, increaseContrast: false), .opaque)
        XCTAssertEqual(resolve(increase: true, secretCode: false, drunkMode: true,
                               reduceTransparency: false, increaseContrast: false), .increased)
    }

    func testEggYieldsToAccessibilityFlags() {
        XCTAssertEqual(resolve(increase: false, secretCode: true, drunkMode: false,
                               reduceTransparency: true, increaseContrast: false), .opaque)
        XCTAssertEqual(resolve(increase: false, secretCode: true, drunkMode: false,
                               reduceTransparency: false, increaseContrast: true), .opaque)
        XCTAssertEqual(resolve(increase: false, secretCode: true, drunkMode: true,
                               reduceTransparency: true, increaseContrast: false), .opaque)
        XCTAssertEqual(resolve(increase: true, secretCode: true, drunkMode: true,
                               reduceTransparency: true, increaseContrast: true), .opaque)
    }

    func testEggRendersWhenAccessibilityFlagsAreOff() {
        XCTAssertEqual(resolve(increase: true, secretCode: true, drunkMode: false,
                               reduceTransparency: false, increaseContrast: false), .party)
        XCTAssertEqual(resolve(increase: true, secretCode: true, drunkMode: true,
                               reduceTransparency: false, increaseContrast: false), .drunk)
    }

    func testSurfaceTreatmentPerStyle() {
        XCTAssertEqual(PopoverTransparencyStyle.opaque.surfaceTreatment, .opaque)
        XCTAssertEqual(PopoverTransparencyStyle.increased.surfaceTreatment, .translucent)
        XCTAssertEqual(PopoverTransparencyStyle.party.surfaceTreatment, .translucent)
        XCTAssertEqual(PopoverTransparencyStyle.drunk.surfaceTreatment, .translucent)
    }

    func testWindowAlphaKeepsPartyReadableAndDrunkFaintest() {
        XCTAssertEqual(PopoverTransparencyStyle.opaque.windowAlpha, 1)
        XCTAssertEqual(PopoverTransparencyStyle.increased.windowAlpha, 1)
        XCTAssertEqual(PopoverTransparencyStyle.party.windowAlpha, 1)
        XCTAssertLessThan(PopoverTransparencyStyle.drunk.windowAlpha,
                          PopoverTransparencyStyle.party.windowAlpha)
    }

    func testShadowDroppedOnlyForDrunk() {
        XCTAssertTrue(PopoverTransparencyStyle.opaque.wantsShadow)
        XCTAssertTrue(PopoverTransparencyStyle.increased.wantsShadow)
        XCTAssertTrue(PopoverTransparencyStyle.party.wantsShadow)
        XCTAssertFalse(PopoverTransparencyStyle.drunk.wantsShadow)
    }

    func testReadableTranslucentStylesReinforceChromeLegibility() {
        XCTAssertFalse(PopoverTransparencyStyle.opaque.needsChromeLegibilityBacking)
        XCTAssertTrue(PopoverTransparencyStyle.increased.needsChromeLegibilityBacking)
        XCTAssertTrue(PopoverTransparencyStyle.party.needsChromeLegibilityBacking)
        XCTAssertFalse(PopoverTransparencyStyle.drunk.needsChromeLegibilityBacking)
    }
}
