import AppKit
import QuartzCore
import XCTest
@testable import QuotaBar

@MainActor
final class NotchEyesAnnoyanceBehaviorTests: XCTestCase {
    func testContinuousMovementGetsDeclinedThenAttentionReturnsWithoutRingActions() async throws {
        let eyes = NotchEyesLayer()
        var anger = 0.0
        var ringActions: [String] = []
        var angerTurns = 0
        eyes.onAngerChange = { amount, _ in anger = amount }
        let behavior = NotchEyesBehavior(eyes: eyes, reduceMotion: { false }, idleDelay: { 60 },
            onRingResponse: { ringActions.append("response") },
            onRingCharge: { ringActions.append("charge") },
            onRingBurst: { ringActions.append("burst") },
            onRingReset: { _ in ringActions.append("reset") },
            onAngerTurn: { angerTurns += 1 },
            patienceDuration: 0.25, ignoreDuration: 0.3)
        defer { behavior.stop() }
        try await enterAttention(behavior)
        ringActions.removeAll()
        try await annoy(behavior)
        XCTAssertEqual(anger, 1)
        XCTAssertEqual(angerTurns, 0, "The release wave must wait for the final head turn")

        let whites = try XCTUnwrap(eyes.sublayers as? [CAShapeLayer])
        let glarePaths = whites.compactMap(\.path)
        behavior.pointerMoved(horizontal: -0.4, vertical: -0.3)
        XCTAssertEqual(behavior.state, .annoyed)
        XCTAssertEqual(whites.compactMap(\.path), glarePaths,
                       "Further movement must not replace the angry expression")

        try await waitForState(.ignoring, in: behavior)
        XCTAssertEqual(angerTurns, 1, "The final turn should release exactly one wave")
        let awayPaths = whites.compactMap(\.path)
        behavior.pointerMoved(horizontal: 0.6, vertical: -0.2)
        XCTAssertEqual(behavior.state, .ignoring)
        XCTAssertEqual(whites.compactMap(\.path), awayPaths,
                       "The eyes must keep looking away during the refusal")
        try await waitForState(.recovering, in: behavior)
        try await waitForState(.attentive, in: behavior)
        XCTAssertEqual(anger, 0)
        let expected = NotchEyesPose.looking(horizontal: 0.6, vertical: -0.2)
        for (white, side) in zip(whites, [-1.0, 1.0]) {
            XCTAssertEqual(try XCTUnwrap(white.path), NotchEyesGeometry.path(side: side, pose: expected),
                           "Recovery should follow the most recent pointer position")
        }
        XCTAssertTrue(ringActions.isEmpty, "This emotion must not disturb the quota ring")
        XCTAssertEqual(angerTurns, 1, "Pointer movement and recovery must not repeat the wave")
    }

    func testLeavingDuringAngerOrRefusalRecoversAndStoppingPreventsRevival() async throws {
        for exitState in [NotchEyesBehavior.State.annoyed, .ignoring] {
            let eyes = NotchEyesLayer()
            var anger = 0.0
            eyes.onAngerChange = { amount, _ in anger = amount }
            let behavior = NotchEyesBehavior(eyes: eyes, reduceMotion: { false }, idleDelay: { 60 },
                                            patienceDuration: 0.25, ignoreDuration: 0.5)
            defer { behavior.stop() }
            try await enterAttention(behavior)
            try await annoy(behavior)
            try await waitForState(exitState, in: behavior)

            behavior.pointerExited()
            try await waitForState(.recovering, in: behavior, timeout: 0.4)
            XCTAssertLessThan(anger, 1, "Leaving should begin cooling down without waiting out the refusal")
            behavior.stop()
            XCTAssertEqual(behavior.state, .hidden)
            XCTAssertEqual(anger, 0)
            try assertDefaultEyes(eyes)

            try await Task.sleep(for: .milliseconds(1_200))
            XCTAssertEqual(behavior.state, .hidden, "Cancelled emotion and recovery tasks must not revive hidden eyes")
            XCTAssertEqual(anger, 0)
            try assertDefaultEyes(eyes)
        }
    }

    func testWarmthExpiresWhileRepeatedStationaryEventsNeverTriggerAnger() async throws {
        let eyes = NotchEyesLayer()
        var anger = 0.0
        eyes.onAngerChange = { amount, _ in anger = amount }
        let behavior = NotchEyesBehavior(eyes: eyes, reduceMotion: { false }, idleDelay: { 60 },
                                        patienceDuration: 1, ignoreDuration: 0.3)
        defer { behavior.stop() }
        try await enterAttention(behavior)

        var lastHorizontal = 0.0
        for step in 0..<25 {
            lastHorizontal = step.isMultiple(of: 2) ? -0.7 : 0.7
            behavior.pointerMoved(horizontal: lastHorizontal, vertical: 0.2)
            if anger > 0 { break }
            try await Task.sleep(for: .milliseconds(60))
        }
        XCTAssertEqual(behavior.state, .attentive)
        XCTAssertGreaterThan(anger, 0, "Sustained movement should become visibly warm before refusal")
        XCTAssertLessThan(anger, 1)

        for _ in 0..<12 {
            try await Task.sleep(for: .milliseconds(100))
            behavior.pointerMoved(horizontal: lastHorizontal, vertical: 0.2)
            XCTAssertEqual(behavior.state, .attentive, "Repeated stationary input must not count as continued movement")
        }
        XCTAssertEqual(anger, 0, "One second without effective movement should remove the warmth")

        behavior.pointerMoved(horizontal: -lastHorizontal, vertical: 0.2)
        try await Task.sleep(for: .milliseconds(100))
        behavior.pointerMoved(horizontal: lastHorizontal, vertical: 0.2)
        XCTAssertEqual(behavior.state, .attentive)
        XCTAssertEqual(anger, 0, "New movement should start with a fresh patience interval")
    }

    func testEnablingReducedMotionDuringAngerCancelsToStaticDefaultEyes() async throws {
        let eyes = NotchEyesLayer()
        var reducedMotion = false
        var anger = 0.0
        eyes.onAngerChange = { amount, _ in anger = amount }
        let behavior = NotchEyesBehavior(eyes: eyes, reduceMotion: { reducedMotion }, idleDelay: { 60 },
                                        patienceDuration: 0.25, ignoreDuration: 0.3)
        defer { behavior.stop() }
        try await enterAttention(behavior)
        try await annoy(behavior)
        XCTAssertEqual(anger, 1)

        reducedMotion = true
        try await waitForState(.resting, in: behavior)
        XCTAssertEqual(anger, 0)
        try assertDefaultEyes(eyes)
        behavior.pointerMoved(horizontal: -1, vertical: 1)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(behavior.state, .resting)
        try assertDefaultEyes(eyes)
    }

    func testStoppingDuringTheAnticipationDoesNotLaunchALateRedBloom() async throws {
        let eyes = NotchEyesLayer()
        var pressed = false
        var angerTurns = 0
        eyes.onAngerChange = { amount, _ in if amount >= 1 { pressed = true } }
        let behavior = NotchEyesBehavior(eyes: eyes, reduceMotion: { false }, idleDelay: { 60 },
                                        onAngerTurn: { angerTurns += 1 },
                                        patienceDuration: 0.15)
        defer { behavior.stop() }
        try await enterAttention(behavior)
        for step in 0..<15 {
            behavior.pointerMoved(horizontal: step.isMultiple(of: 2) ? -0.8 : 0.8, vertical: 0)
            if behavior.state == .annoyed { break }
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTAssertEqual(behavior.state, .annoyed)
        XCTAssertFalse(pressed, "The lid press must follow the brief anticipation")
        behavior.stop()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(pressed, "Opening or hiding during anticipation must cancel the pending bloom")
        XCTAssertEqual(angerTurns, 0, "Cancelling the gesture must also cancel the pending release wave")
        XCTAssertEqual(behavior.state, .hidden)
        try assertDefaultEyes(eyes)
    }

    private func enterAttention(_ behavior: NotchEyesBehavior) async throws {
        behavior.activate(arriving: true)
        try await waitForState(.resting, in: behavior)
        behavior.pointerMoved(horizontal: -0.6, vertical: 0.2)
        try await waitForState(.attentive, in: behavior)
    }

    private func annoy(_ behavior: NotchEyesBehavior) async throws {
        for step in 0..<15 {
            behavior.pointerMoved(horizontal: step.isMultiple(of: 2) ? -0.8 : 0.8, vertical: 0.2)
            if behavior.state == .annoyed {
                // Wait for the intentional 100 ms pause before the lid press.
                try await Task.sleep(for: .milliseconds(140))
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Sustained effective pointer movement did not trigger annoyance")
        throw StateWaitError.timedOut
    }

    private func waitForState(_ expected: NotchEyesBehavior.State, in behavior: NotchEyesBehavior,
                              timeout: Double = 2, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = CACurrentMediaTime() + timeout
        while CACurrentMediaTime() < deadline {
            if behavior.state == expected { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for \(expected); current state is \(behavior.state)", file: file, line: line)
        throw StateWaitError.timedOut
    }

    private func assertDefaultEyes(_ eyes: NotchEyesLayer, file: StaticString = #filePath,
                                   line: UInt = #line) throws {
        let whites = try XCTUnwrap(eyes.sublayers as? [CAShapeLayer], file: file, line: line)
        XCTAssertEqual(whites.count, 2, file: file, line: line)
        for (white, side) in zip(whites, [-1.0, 1.0]) {
            XCTAssertEqual(try XCTUnwrap(white.path, file: file, line: line), NotchEyesGeometry.path(side: side),
                           file: file, line: line)
            XCTAssertEqual(white.fillColor, NotchEyesAppearance.whiteColor(anger: 0), file: file, line: line)
        }
        XCTAssertFalse(hasAnimations(eyes), "Static or hidden eyes must not retain emotion animations", file: file, line: line)
    }

    private func hasAnimations(_ layer: CALayer) -> Bool {
        if !(layer.animationKeys() ?? []).isEmpty { return true }
        if let mask = layer.mask, hasAnimations(mask) { return true }
        return (layer.sublayers ?? []).contains { hasAnimations($0) }
    }

    private enum StateWaitError: Error { case timedOut }
}
