import AppKit
import QuartzCore
import XCTest
@testable import QuotaBar

@MainActor
final class NotchEyesBehaviorTests: XCTestCase {
    func testStartupEntranceRunsOnceAndReturnStartsWithExactNeutralHandoff() async throws {
        let eyes = NotchEyesLayer()
        let behavior = NotchEyesBehavior(eyes: eyes, reduceMotion: { false })
        defer { behavior.stop() }
        behavior.activate(arriving: false)
        XCTAssertEqual(behavior.state, .entering)
        XCTAssertTrue(behavior.hasEntered)
        let entrance = try XCTUnwrap(eyes.animation(forKey: "peekEntrance") as? CAKeyframeAnimation)
        let firstTransform = try XCTUnwrap((entrance.values as? [NSValue])?.first).caTransform3DValue
        XCTAssertLessThan(firstTransform.m41, 0)
        XCTAssertLessThan(firstTransform.m42, 0)
        assertFiniteAnimations(in: eyes)

        behavior.stop()
        behavior.activate(arriving: true)
        XCTAssertEqual(behavior.state, .settling)
        XCTAssertNil(eyes.animation(forKey: "peekEntrance"))
        let whites = try XCTUnwrap(eyes.sublayers as? [CAShapeLayer])
        for (white, side) in zip(whites, [-1.0, 1.0]) {
            XCTAssertEqual(try XCTUnwrap(white.path), NotchEyesGeometry.path(side: side),
                           "Return must begin at the closing overlay's exact neutral pose")
        }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(behavior.state, .resting)
        XCTAssertNil(eyes.animation(forKey: "peekEntrance"))
        behavior.stop()
        behavior.activate(arriving: false)
        XCTAssertEqual(behavior.state, .settling)
        XCTAssertNil(eyes.animation(forKey: "peekEntrance"), "Restarting visibility must not replay startup")
    }

    func testPointerReactionsAreFiniteAndStoppingCancelsPendingAttention() async throws {
        _ = NSApplication.shared
        let panel = NSPanel(contentRect: NSRect(x: -1000, y: -1000, width: 60, height: 32),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 60, height: 32))
        panel.contentView!.wantsLayer = true
        let eyes = NotchEyesLayer()
        panel.contentView!.layer!.addSublayer(eyes)
        panel.orderFrontRegardless()
        let behavior = NotchEyesBehavior(eyes: eyes, reduceMotion: { false })
        defer { behavior.stop(); panel.orderOut(nil) }
        behavior.activate(arriving: true)
        try await Task.sleep(for: .milliseconds(500))
        behavior.pointerMoved(horizontal: 1, vertical: 0.5)
        behavior.stop()
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertEqual(behavior.state, .hidden)
        XCTAssertTrue(allAnimations(in: eyes).isEmpty, "Cancelled attention must not revive hidden eyes")

        behavior.activate(arriving: true)
        try await Task.sleep(for: .milliseconds(500))
        behavior.pointerMoved(horizontal: -1, vertical: 0.5)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(behavior.state, .attentive)
        XCTAssertFalse(allAnimations(in: eyes).isEmpty)
        assertFiniteAnimations(in: eyes)
        behavior.pointerMoved(horizontal: 1, vertical: -0.5)
        XCTAssertEqual(behavior.state, .attentive)
        assertFiniteAnimations(in: eyes)
        behavior.pointerExited()
        try await Task.sleep(for: .milliseconds(250))
        behavior.pointerExited()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(behavior.state, .resting)
        assertFiniteAnimations(in: eyes)
        behavior.stop()
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertTrue(allAnimations(in: eyes).isEmpty)
    }

    func testReducedMotionUsesStaticEyesForStartupReturnAndPointer() async throws {
        let eyes = NotchEyesLayer()
        let behavior = NotchEyesBehavior(eyes: eyes, reduceMotion: { true }, idleDelay: { 0.3 })
        defer { behavior.stop() }
        for arriving in [false, true] {
            behavior.activate(arriving: arriving)
            XCTAssertTrue(behavior.hasEntered)
            XCTAssertEqual(behavior.state, .resting)
            behavior.pointerMoved(horizontal: 1, vertical: -1)
            behavior.pointerExited()
            try await Task.sleep(for: .milliseconds(400))
            XCTAssertEqual(behavior.state, .resting)
            XCTAssertTrue(allAnimations(in: eyes).isEmpty)
        }
    }

    func testIdleExpressionYieldsToPointerAndCannotReviveAfterStopping() async throws {
        _ = NSApplication.shared
        let panel = NSPanel(contentRect: NSRect(x: -1000, y: -1000, width: 60, height: 32),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 60, height: 32))
        panel.contentView!.wantsLayer = true
        let eyes = NotchEyesLayer()
        panel.contentView!.layer!.addSublayer(eyes)
        panel.orderFrontRegardless()
        let behavior = NotchEyesBehavior(eyes: eyes, reduceMotion: { false }, idleDelay: { 0.3 })
        defer { behavior.stop(); panel.orderOut(nil) }

        behavior.activate(arriving: true)
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(behavior.state, .expressing, "Idle eyes should animate without pointer input")
        let whites = try XCTUnwrap(eyes.sublayers as? [CAShapeLayer])
        XCTAssertNotEqual(try XCTUnwrap(whites[0].path), NotchEyesGeometry.path(side: -1))
        assertFiniteAnimations(in: eyes)

        behavior.pointerMoved(horizontal: -1, vertical: 0.3)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(behavior.state, .attentive)
        // Wait past the longest first idle step. Its cancelled continuation
        // must not replace the pointer's pose or launch the next gesture.
        try await Task.sleep(for: .milliseconds(1_400))
        XCTAssertEqual(behavior.state, .attentive)
        let pointerPose = NotchEyesPose.looking(horizontal: -1, vertical: 0.3)
        for (white, side) in zip(whites, [-1.0, 1.0]) {
            XCTAssertEqual(try XCTUnwrap(white.path), NotchEyesGeometry.path(side: side, pose: pointerPose))
        }

        behavior.pointerExited()
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(behavior.state, .expressing, "Idle expressions should resume after attention ends")
        behavior.stop()
        try await Task.sleep(for: .milliseconds(1_400))
        XCTAssertEqual(behavior.state, .hidden)
        XCTAssertTrue(allAnimations(in: eyes).isEmpty)
        for (white, side) in zip(whites, [-1.0, 1.0]) {
            XCTAssertEqual(try XCTUnwrap(white.path), NotchEyesGeometry.path(side: side))
        }
    }

    func testBriefPointerVisitDoesNotCancelIdlePermanently() async throws {
        let eyes = NotchEyesLayer()
        let behavior = NotchEyesBehavior(eyes: eyes, reduceMotion: { false }, idleDelay: { 0.3 })
        defer { behavior.stop() }
        behavior.activate(arriving: true)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(behavior.state, .resting)
        behavior.pointerMoved(horizontal: 1, vertical: 0)
        try await Task.sleep(for: .milliseconds(30))
        behavior.pointerExited()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(behavior.state, .expressing,
                       "Leaving before the 100 ms attention delay must restore idle scheduling")
    }

    func testQuotaInspectionLooksBeforeRingRespondsThenWinksAndRests() async throws {
        let eyes = NotchEyesLayer()
        let whites = try XCTUnwrap(eyes.sublayers as? [CAShapeLayer])
        var ringResponses: [Double] = []
        let behavior = NotchEyesBehavior(eyes: eyes, reduceMotion: { false }, idleDelay: { 0.3 },
                                        onRingResponse: { ringResponses.append(CACurrentMediaTime()) },
                                        initialQuotaInteraction: .inspect)
        defer { behavior.stop() }
        behavior.activate(arriving: true)
        try await waitForEyeState { behavior.state == .expressing }
        XCTAssertTrue(ringResponses.isEmpty, "The eyes must initiate the interaction")
        XCTAssertGreaterThan(try XCTUnwrap(whites[0].path).boundingBoxOfPath.midX,
                             NotchEyesGeometry.path(side: -1).boundingBoxOfPath.midX + 5,
                             "The eyes must visibly look toward the right-side ring")
        try await waitForEyeState { !ringResponses.isEmpty }
        let responseTime = try XCTUnwrap(ringResponses.first)
        let openHeight = try XCTUnwrap(whites[1].path).boundingBoxOfPath.height
        try await waitForEyeState { (whites[1].path?.boundingBoxOfPath.height ?? openHeight) < openHeight * 0.3 }
        XCTAssertGreaterThanOrEqual(CACurrentMediaTime() - responseTime, 0.72,
                                    "The ring should finish responding before the acknowledging wink")
        try await waitForEyeState { behavior.state == .resting }
        XCTAssertEqual(ringResponses.count, 1)
        for (white, side) in zip(whites, [-1.0, 1.0]) {
            XCTAssertEqual(try XCTUnwrap(white.path), NotchEyesGeometry.path(side: side))
        }
    }

    func testPointerAndHidingCancelPendingRingResponse() async throws {
        let eyes = NotchEyesLayer()
        var responses = 0
        var resets: [Bool] = []
        let behavior = NotchEyesBehavior(eyes: eyes, reduceMotion: { false }, idleDelay: { 0.3 },
                                        onRingResponse: { responses += 1 },
                                        onRingCharge: { responses += 1 },
                                        onRingBurst: { responses += 1 },
                                        onRingReset: { resets.append($0) })
        defer { behavior.stop() }
        behavior.activate(arriving: true)
        try await waitForEyeState { behavior.state == .expressing }
        behavior.pointerMoved(horizontal: -0.5, vertical: 0)
        XCTAssertEqual(resets.last, true, "An interrupted response must settle smoothly")
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(behavior.state, .attentive)
        XCTAssertEqual(responses, 0, "The cancelled inspection must not trigger a late ring response")
        behavior.stop()
        XCTAssertEqual(resets.last, false, "Hidden rings must reset immediately for the next handoff")
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(behavior.state, .hidden)
        XCTAssertEqual(responses, 0)
    }

    func testOverchargeSqueezesEyesFillsBeforeBurstAndReturnsToRest() async throws {
        let eyes = NotchEyesLayer()
        let panel = host(eyes)
        let whites = try XCTUnwrap(eyes.sublayers as? [CAShapeLayer])
        var chargedAt: Double?
        var burstAt: Double?
        var effortActiveAtBurst = false
        var chargeHeights: [CGFloat] = []
        let behavior = NotchEyesBehavior(eyes: eyes, reduceMotion: { false }, idleDelay: { 0.3 },
            onRingCharge: {
                chargedAt = CACurrentMediaTime()
                chargeHeights = whites.compactMap { $0.path?.boundingBoxOfPath.height }
            }, onRingBurst: {
                burstAt = CACurrentMediaTime()
                effortActiveAtBurst = eyes.animation(forKey: "effortShake") != nil
            })
        defer { behavior.stop(); panel.orderOut(nil) }
        behavior.activate(arriving: true)
        try await waitForEyeState { chargedAt != nil }
        XCTAssertNil(burstAt)
        XCTAssertEqual(chargeHeights.count, 2)
        for (height, side) in zip(chargeHeights, [-1.0, 1.0]) {
            XCTAssertLessThan(height, NotchEyesGeometry.path(side: side).boundingBoxOfPath.height * 0.3,
                              "Both eyes must visibly squeeze while the ring charges")
        }
        try await waitForEyeState { eyes.animation(forKey: "effortShake") != nil }
        let effortSeenAt = CACurrentMediaTime()
        XCTAssertNil(burstAt, "Effort must happen before the ring explodes")
        XCTAssertGreaterThanOrEqual(try effortSeenAt - XCTUnwrap(chargedAt), 1.25,
                                    "The longer squeeze must settle before the effort starts")
        let effort = try XCTUnwrap(eyes.animation(forKey: "effortShake") as? CAKeyframeAnimation)
        let transforms = try XCTUnwrap(effort.values as? [NSValue]).map(\.caTransform3DValue)
        XCTAssertTrue(CATransform3DIsIdentity(try XCTUnwrap(transforms.first)))
        XCTAssertTrue(CATransform3DIsIdentity(try XCTUnwrap(transforms.last)))
        XCTAssertEqual(effort.duration, 0.48, accuracy: 0.001)
        for transform in transforms {
            XCTAssertLessThanOrEqual(abs(transform.m41), 1.801)
            XCTAssertLessThanOrEqual(abs(transform.m42), 0.561)
        }
        assertFiniteAnimations(in: eyes)
        for (index, white) in whites.enumerated() {
            let peakHeight = try XCTUnwrap(white.path).boundingBoxOfPath.height
            XCTAssertLessThan(peakHeight, chargeHeights[index],
                              "Effort should shake the tightest squeeze, not open the eyes")
            let visibleHeight = try XCTUnwrap(white.presentation()?.path).boundingBoxOfPath.height
            XCTAssertEqual(visibleHeight, peakHeight, accuracy: 0.15,
                           "The visible lids must already be settled at peak effort")
        }
        try await waitForEyeState { burstAt != nil }
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(burstAt) - XCTUnwrap(chargedAt), 1.80,
                                    "The full squeeze and effort must precede the burst")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(burstAt) - effortSeenAt, 0.44,
                                    "The effort must finish before the burst, allowing for polling latency")
        XCTAssertFalse(effortActiveAtBurst, "The burst must not overlap the effort shake")
        try await Task.sleep(for: .milliseconds(170))
        // Check the rendered reaction during its pause, not just target values.
        var reactionBounds = CGRect.null
        for (white, side) in zip(whites, [-1.0, 1.0]) {
            let visible = try XCTUnwrap(white.presentation()?.path).boundingBoxOfPath
            var ordinary = NotchEyesIdleExpression.overchargeQuota.steps[4].pose
            ordinary.surprise = 0
            XCTAssertGreaterThan(visible.height,
                                 NotchEyesGeometry.path(side: side, pose: ordinary).boundingBoxOfPath.height * 1.15,
                                 "The burst should visibly widen both eyes before looking back")
            reactionBounds = reactionBounds.union(visible)
        }
        XCTAssertLessThan(reactionBounds.midX, 8 - 3,
                          "The eyes should recoil away from the ring before checking it again")
        try await waitForEyeState { behavior.state == .resting }
        for (white, side) in zip(whites, [-1.0, 1.0]) {
            XCTAssertEqual(try XCTUnwrap(white.path), NotchEyesGeometry.path(side: side))
        }
    }

    func testInterruptingEffortSettlesEyesAndCancelsTheExplosion() async throws {
        let eyes = NotchEyesLayer()
        let panel = host(eyes)
        var charges = 0, bursts = 0
        var resets: [Bool] = []
        let behavior = NotchEyesBehavior(eyes: eyes, reduceMotion: { false }, idleDelay: { 0.3 },
            onRingCharge: { charges += 1 }, onRingBurst: { bursts += 1 },
            onRingReset: { resets.append($0) })
        defer { behavior.stop(); panel.orderOut(nil) }
        behavior.activate(arriving: true)
        try await waitForEyeState { eyes.animation(forKey: "effortShake") != nil }
        XCTAssertEqual(charges, 1)
        try await Task.sleep(for: .milliseconds(55))
        behavior.pointerMoved(horizontal: -0.8, vertical: 0)
        XCTAssertEqual(resets.last, true)
        XCTAssertNil(eyes.animation(forKey: "effortShake"), "Pointer attention must stop the effort immediately")
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(behavior.state, .attentive)
        XCTAssertEqual(bursts, 0, "A cancelled charge must not explode after attention takes over")
        XCTAssertTrue(CATransform3DIsIdentity(eyes.transform))
        XCTAssertTrue(CATransform3DIsIdentity(try XCTUnwrap(eyes.presentation()).transform))
        // An offscreen panel can retain completed CA metadata. The presentation
        // must be at rest, and any retained reset must have finite cleanup.
        if let reset = eyes.animation(forKey: "effortReset") {
            XCTAssertEqual(reset.duration, 0.12, accuracy: 0.001)
            XCTAssertEqual(reset.repeatCount, 0)
            XCTAssertEqual(reset.repeatDuration, 0)
            XCTAssertTrue(reset.isRemovedOnCompletion)
        }
        behavior.stop()
        XCTAssertEqual(resets.last, false)
        XCTAssertEqual(behavior.state, .hidden)
        XCTAssertTrue(allAnimations(in: eyes).isEmpty)
    }

    func testInterruptingBurstReactionRestoresNormalEyesForPointerAttention() async throws {
        let eyes = NotchEyesLayer()
        let panel = host(eyes)
        var bursts = 0
        let behavior = NotchEyesBehavior(eyes: eyes, reduceMotion: { false }, idleDelay: { 0.3 },
                                        onRingBurst: { bursts += 1 })
        defer { behavior.stop(); panel.orderOut(nil) }
        behavior.activate(arriving: true)
        try await waitForEyeState { bursts == 1 }
        try await Task.sleep(for: .milliseconds(60))
        behavior.pointerMoved(horizontal: -0.4, vertical: 0.2)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(behavior.state, .attentive)
        XCTAssertEqual(bursts, 1)
        let expected = NotchEyesPose.looking(horizontal: -0.4, vertical: 0.2)
        for (white, side) in zip(try XCTUnwrap(eyes.sublayers as? [CAShapeLayer]), [-1.0, 1.0]) {
            XCTAssertEqual(try XCTUnwrap(white.path), NotchEyesGeometry.path(side: side, pose: expected),
                           "Interrupting surprise must restore ordinary eye proportions")
            XCTAssertEqual(try XCTUnwrap(white.presentation()?.path).boundingBoxOfPath.height,
                           NotchEyesGeometry.path(side: side, pose: expected).boundingBoxOfPath.height, accuracy: 0.01)
        }
        behavior.stop()
        XCTAssertTrue(allAnimations(in: eyes).isEmpty)
    }

    private func host(_ eyes: NotchEyesLayer) -> NSPanel {
        _ = NSApplication.shared
        let panel = NSPanel(contentRect: NSRect(x: -1000, y: -1000, width: 60, height: 32),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 60, height: 32))
        panel.contentView!.wantsLayer = true
        panel.contentView!.layer!.addSublayer(eyes)
        panel.orderFrontRegardless()
        return panel
    }

    private func waitForEyeState(_ condition: () -> Bool) async throws {
        for _ in 0..<125 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTFail("Timed out waiting for the eye interaction")
    }

    private func assertFiniteAnimations(in layer: CALayer, file: StaticString = #filePath, line: UInt = #line) {
        for animation in allAnimations(in: layer) {
            XCTAssertTrue(animation.duration.isFinite, file: file, line: line)
            XCTAssertGreaterThan(animation.duration, 0, file: file, line: line)
            XCTAssertEqual(animation.repeatCount, 0, "Eye reactions must never run as a repeating movie", file: file, line: line)
            XCTAssertEqual(animation.repeatDuration, 0, file: file, line: line)
        }
    }

    private func allAnimations(in layer: CALayer) -> [CAAnimation] {
        var animations = (layer.animationKeys() ?? []).compactMap { layer.animation(forKey: $0) }
        for child in layer.sublayers ?? [] { animations += allAnimations(in: child) }
        if let mask = layer.mask { animations += allAnimations(in: mask) }
        return animations
    }
}
