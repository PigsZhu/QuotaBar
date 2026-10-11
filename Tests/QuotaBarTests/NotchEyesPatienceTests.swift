import XCTest
@testable import QuotaBar

final class NotchEyesPatienceTests: XCTestCase {
    func testContinuousMovementReachesFullProgressAfterThreeSeconds() {
        var patience = NotchEyesPatience()

        for step in 0...6 {
            let time = Double(step) * 0.5
            XCTAssertTrue(patience.record(horizontal: Double(step % 2) * 0.5, vertical: 0, at: time))
            XCTAssertEqual(patience.progress, time / 3, accuracy: 0.000_001)
        }

        XCTAssertTrue(patience.record(horizontal: 0.5, vertical: 0, at: 3.5))
        XCTAssertEqual(patience.progress, 1)
    }

    func testStationaryEventsNeitherAccumulateTimeNorRenewMovement() {
        var patience = NotchEyesPatience()
        XCTAssertTrue(patience.record(horizontal: 0, vertical: 0, at: 0))
        XCTAssertTrue(patience.record(horizontal: 0.5, vertical: 0, at: 0.5))
        XCTAssertGreaterThan(patience.progress, 0)

        XCTAssertFalse(patience.record(horizontal: 0.5, vertical: 0, at: 1))
        XCTAssertEqual(patience.progress, 0.5 / 3, accuracy: 0.000_001)
        XCTAssertFalse(patience.record(horizontal: 0.5, vertical: 0, at: 1.6))
        XCTAssertEqual(patience.progress, 0)
        XCTAssertFalse(patience.record(horizontal: 0.5, vertical: 0, at: 20))
        XCTAssertEqual(patience.progress, 0)
    }

    func testSmallMovementsAccumulateRelativeToTheLastEffectivePoint() {
        var patience = NotchEyesPatience()
        XCTAssertTrue(patience.record(horizontal: 0, vertical: 0, at: 0))
        XCTAssertFalse(patience.record(horizontal: 0.02, vertical: 0, at: 0.2))
        XCTAssertFalse(patience.record(horizontal: 0.04, vertical: 0, at: 0.4))
        XCTAssertEqual(patience.progress, 0)
        XCTAssertTrue(patience.record(horizontal: 0.04, vertical: 0.04, at: 0.6))
        XCTAssertEqual(patience.progress, 0.6 / 3, accuracy: 0.000_001)
    }

    func testBriefPausesContinueButExceedingTheInactivityLimitStartsOver() {
        var patience = NotchEyesPatience()
        XCTAssertTrue(patience.record(horizontal: 0, vertical: 0, at: 0))
        XCTAssertTrue(patience.record(horizontal: 0.5, vertical: 0, at: 0.9))
        XCTAssertEqual(patience.progress, 0.9 / 3, accuracy: 0.000_001)
        XCTAssertTrue(patience.record(horizontal: 0, vertical: 0, at: 1.9))
        XCTAssertEqual(patience.progress, 1.9 / 3, accuracy: 0.000_001,
                       "A gap of exactly one second remains continuous")

        XCTAssertTrue(patience.record(horizontal: 0.5, vertical: 0, at: 3))
        XCTAssertEqual(patience.progress, 0)
        XCTAssertTrue(patience.record(horizontal: 0, vertical: 0, at: 3.5))
        XCTAssertEqual(patience.progress, 0.5 / 3, accuracy: 0.000_001)
    }

    func testMovementBeyondTheEyePoseClampStillAccumulates() {
        var patience = NotchEyesPatience()
        for second in 0...3 {
            XCTAssertTrue(patience.record(horizontal: 2 + Double(second), vertical: -3, at: Double(second)))
        }
        XCTAssertEqual(patience.progress, 1)
    }

    func testResetClearsProgressAndThePreviousPosition() {
        var patience = NotchEyesPatience(duration: 2, inactivityLimit: 0.5)
        for step in 0...4 {
            XCTAssertTrue(patience.record(horizontal: Double(step), vertical: 0, at: Double(step) * 0.5))
        }
        XCTAssertEqual(patience.progress, 1)

        patience.reset()
        XCTAssertEqual(patience.progress, 0)
        XCTAssertTrue(patience.record(horizontal: 4, vertical: 0, at: 10))
        XCTAssertEqual(patience.progress, 0)
        XCTAssertTrue(patience.record(horizontal: 5, vertical: 0, at: 10.5))
        XCTAssertEqual(patience.progress, 0.25)
    }
}
