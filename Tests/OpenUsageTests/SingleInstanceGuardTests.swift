import XCTest
@testable import OpenUsage

@MainActor
final class SingleInstanceGuardTests: XCTestCase {
    func testSoloLaunchYieldsToNobody() {
        XCTAssertNil(SingleInstanceGuard.instanceToYieldTo(myPID: 42, runningPIDs: [42]))
    }

    func testNoRunningAppsYieldsToNobody() {
        XCTAssertNil(SingleInstanceGuard.instanceToYieldTo(myPID: 42, runningPIDs: []))
    }

    func testYieldsToALowerPIDInstance() {
        XCTAssertEqual(SingleInstanceGuard.instanceToYieldTo(myPID: 42, runningPIDs: [7, 42]), 7)
    }

    func testYieldsToTheLowestWhenSeveralAreLower() {
        XCTAssertEqual(SingleInstanceGuard.instanceToYieldTo(myPID: 42, runningPIDs: [20, 9, 42]), 9)
    }

    func testSurvivesWhenWeAreTheLowestPID() {
        XCTAssertNil(SingleInstanceGuard.instanceToYieldTo(myPID: 42, runningPIDs: [42, 99]))
    }

    func testSimultaneousLaunchLeavesExactlyOneSurvivor() {
        let both: [pid_t] = [100, 101]
        let lowerYieldsTo = SingleInstanceGuard.instanceToYieldTo(myPID: 100, runningPIDs: both)
        let higherYieldsTo = SingleInstanceGuard.instanceToYieldTo(myPID: 101, runningPIDs: both)

        XCTAssertNil(lowerYieldsTo)
        XCTAssertEqual(higherYieldsTo, 100)
    }
}
