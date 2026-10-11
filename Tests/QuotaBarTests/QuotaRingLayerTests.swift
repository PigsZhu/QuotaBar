import AppKit
import QuartzCore
import XCTest
@testable import QuotaBar

@MainActor
final class QuotaRingLayerTests: XCTestCase {
    func testCompactLayoutKeepsQuotaCenteredAndRefreshesItsContents() throws {
        let button = NotchButton(frame: CGRect(x: 0, y: 0, width: 297, height: 32))
        button.cameraWidth = 185
        button.remainingPercent = 73
        button.layoutSubtreeIfNeeded()
        let container = try XCTUnwrap(button.layer?.sublayers?.first { layer in
            layer.sublayers?.contains { $0 is QuotaRingLayer } == true
        })
        let ring = try XCTUnwrap(container.sublayers?.compactMap { $0 as? QuotaRingLayer }.first)
        XCTAssertEqual(ring.position.x, 261.64, accuracy: 0.001)
        XCTAssertEqual(ring.position.y, 16)
        XCTAssertEqual(ring.bounds.size, CGSize(width: 16, height: 16))
        XCTAssertEqual(ring.contentsScale, 2)
        let glyph = try XCTUnwrap(ring.sublayers?.first { $0.name == "quotaGlyph" })
        let initial = try XCTUnwrap(glyph.contents) as! CGImage
        XCTAssertEqual(initial.width, 32)
        XCTAssertEqual(initial.height, 32)
        button.remainingPercent = 28
        button.layoutSubtreeIfNeeded()
        let refreshed = try XCTUnwrap(glyph.contents) as! CGImage
        XCTAssertFalse(initial === refreshed)
        XCTAssertEqual(ring.position.x, 261.64, accuracy: 0.001)
        button.cameraWidth = 0
        button.layoutSubtreeIfNeeded()
        XCTAssertTrue(container.isHidden)
    }

    func testRingResponseStaysCenteredAndInterruptsFromItsVisibleScale() async throws {
        _ = NSApplication.shared
        let panel = NSPanel(contentRect: CGRect(x: -1000, y: -1000, width: 60, height: 32),
                            styleMask: .borderless, backing: .buffered, defer: false)
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 60, height: 32))
        host.wantsLayer = true
        panel.contentView = host
        let ring = QuotaRingLayer()
        ring.update(diameter: 16, remainingPercent: 70)
        ring.position = CGPoint(x: 30, y: 16)
        host.layer?.addSublayer(ring)
        panel.orderFrontRegardless()
        defer { ring.resetResponse(animated: false); panel.orderOut(nil) }
        let glyph = try XCTUnwrap(ring.sublayers?.first { $0.name == "quotaGlyph" })
        ring.respond()
        let response = try XCTUnwrap(glyph.animation(forKey: "quotaResponse") as? CAKeyframeAnimation)
        let scales = try XCTUnwrap(response.values as? [NSNumber]).map(\.doubleValue)
        XCTAssertEqual(scales.first, 1)
        XCTAssertEqual(scales.last, 1)
        XCTAssertLessThanOrEqual(try XCTUnwrap(scales.max()), 1.15)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(scales.min()), 0.98)
        XCTAssertEqual(response.repeatCount, 0)
        XCTAssertEqual(response.repeatDuration, 0)
        XCTAssertTrue(CATransform3DIsIdentity(ring.transform))
        try await Task.sleep(for: .milliseconds(190))
        ring.resetResponse(animated: true)
        let reset = try XCTUnwrap(glyph.animation(forKey: "quotaResponseReset") as? CABasicAnimation)
        let visible = try XCTUnwrap(reset.fromValue as? NSValue).caTransform3DValue
        XCTAssertGreaterThan(visible.m11, 1.01, "An interrupted pulse must return from its visible size")
        XCTAssertEqual(reset.duration, 0.18)
        XCTAssertNil(glyph.animation(forKey: "quotaResponse"))
        XCTAssertEqual(ring.position, CGPoint(x: 30, y: 16))
        XCTAssertTrue(CATransform3DIsIdentity(ring.transform))
        ring.resetResponse(animated: false)
        XCTAssertTrue((glyph.animationKeys() ?? []).isEmpty)
        XCTAssertTrue(CATransform3DIsIdentity(ring.transform))
    }

    func testChargeHoldsFullThenBurstRestoresLatestQuotaAndClearsEffects() async throws {
        let (panel, ring, glyph) = try hostedRing(percent: 63)
        defer { ring.resetResponse(animated: false); panel.orderOut(nil) }
        ring.burst()
        XCTAssertNil(glyph.animation(forKey: "quotaBurstFull"), "Burst needs the preceding charge")
        ring.charge()
        let fill = try XCTUnwrap(glyph.animation(forKey: "quotaChargeFill") as? CAKeyframeAnimation)
        XCTAssertEqual(fill.duration, 0.70)
        XCTAssertFalse(fill.isRemovedOnCompletion, "The fully filled ring must wait for the eye cue")
        XCTAssertEqual(fill.repeatCount, 0)
        XCTAssertEqual(fill.repeatDuration, 0)
        let fullRing = QuotaRingLayer()
        fullRing.update(diameter: 16, remainingPercent: 100)
        let full = try XCTUnwrap(fullRing.sublayers?.first { $0.name == "quotaGlyph" }?.contents) as! CGImage
        let lastFill = try XCTUnwrap(fill.values?.last) as! CGImage
        XCTAssertEqual(imageData(lastFill), imageData(full))
        ring.update(diameter: 16, remainingPercent: 51)
        XCTAssertNotNil(glyph.animation(forKey: "quotaChargeFill"), "A data refresh must not interrupt the visual charge")
        try await Task.sleep(for: .milliseconds(790))
        let held = try XCTUnwrap(glyph.presentation()?.contents) as! CGImage
        XCTAssertEqual(imageData(held), imageData(full))
        ring.burst()
        XCTAssertNil(glyph.animation(forKey: "quotaChargeFill"))
        let sparks = try XCTUnwrap(ring.sublayers?.filter { $0.name?.hasPrefix("quotaBurstSpark") == true })
        XCTAssertEqual(sparks.count, 8)
        for spark in sparks {
            let travel = try XCTUnwrap(spark.animation(forKey: "quotaBurstTravel") as? CABasicAnimation)
            let offset = try XCTUnwrap(travel.toValue as? NSValue).pointValue
            let path = try XCTUnwrap((spark as? CAShapeLayer)?.path)
            let endBounds = path.boundingBoxOfPath.offsetBy(dx: offset.x, dy: offset.y).insetBy(dx: -0.6, dy: -0.6)
            XCTAssertTrue(CGRect(x: -6, y: -6, width: 28, height: 28).contains(endBounds), "Sparks must stay within 14 pt of the ring center")
            XCTAssertEqual(travel.repeatCount, 0)
            XCTAssertEqual(spark.opacity, 0, "Particles must be hidden in the model")
        }
        try await Task.sleep(for: .milliseconds(220))
        ring.update(diameter: 16, remainingPercent: 27)
        let actualRing = QuotaRingLayer()
        actualRing.update(diameter: 16, remainingPercent: 27)
        let actual = try XCTUnwrap(actualRing.sublayers?.first { $0.name == "quotaGlyph" }?.contents) as! CGImage
        try await Task.sleep(for: .milliseconds(840))
        let restored = try XCTUnwrap(glyph.presentation()?.contents) as! CGImage
        XCTAssertEqual(imageData(restored), imageData(actual), "Restore the latest quota, not the value captured before the joke")
        for child in ring.sublayers ?? [] {
            // An offscreen host can retain completed CA animation metadata until
            // its next render. Verify the actual finished presentation and that
            // any retained animation is finite and scheduled for removal.
            for key in child.animationKeys() ?? [] {
                let animation = try XCTUnwrap(child.animation(forKey: key))
                XCTAssertTrue(animation.isRemovedOnCompletion, "The charge's full-ring hold must be gone")
                XCTAssertEqual(animation.repeatCount, 0)
                XCTAssertEqual(animation.repeatDuration, 0)
                XCTAssertLessThanOrEqual(animation.duration, 0.98)
            }
            if child !== glyph { XCTAssertEqual(child.presentation()?.opacity ?? child.opacity, 0) }
        }
        XCTAssertEqual(glyph.presentation()?.opacity ?? glyph.opacity, 1)
        XCTAssertEqual(glyph.presentation()?.transform.m11 ?? glyph.transform.m11, 1, accuracy: 0.001)
        XCTAssertTrue(CATransform3DIsIdentity(glyph.transform))
    }

    func testInterruptedChargeAndBurstReturnWithoutRevivingParticles() async throws {
        let (panel, ring, glyph) = try hostedRing(percent: 25)
        defer { ring.resetResponse(animated: false); panel.orderOut(nil) }
        ring.charge()
        try await Task.sleep(for: .milliseconds(290))
        let current = try XCTUnwrap(glyph.presentation()?.contents) as! CGImage
        ring.resetResponse(animated: true)
        let dissolve = try XCTUnwrap(glyph.animation(forKey: "quotaResetFill") as? CABasicAnimation)
        XCTAssertEqual(imageData(try XCTUnwrap(dissolve.fromValue) as! CGImage), imageData(current))
        XCTAssertEqual(dissolve.duration, 0.18)
        XCTAssertNil(glyph.animation(forKey: "quotaChargeFill"))
        ring.burst()
        XCTAssertNil(glyph.animation(forKey: "quotaBurstFull"), "A cancelled charge must not burst later")
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue((glyph.animationKeys() ?? []).isEmpty)
        ring.charge()
        ring.burst()
        try await Task.sleep(for: .milliseconds(80))
        let firstSpark = try XCTUnwrap(ring.sublayers?.first { $0.name == "quotaBurstSpark0" })
        let liveSpark = try XCTUnwrap(firstSpark.presentation())
        XCTAssertGreaterThan(liveSpark.transform.m41, 0.1, "The visible spark must move radially, not merely fade")
        XCTAssertLessThanOrEqual(liveSpark.transform.m41, 4)
        XCTAssertGreaterThan(liveSpark.opacity, 0)
        ring.resetResponse(animated: false)
        for child in ring.sublayers ?? [] {
            XCTAssertTrue((child.animationKeys() ?? []).isEmpty)
            XCTAssertTrue(CATransform3DIsIdentity(child.transform))
            XCTAssertEqual(child.opacity, child === glyph ? 1 : 0)
        }
    }

    private func hostedRing(percent: Int) throws -> (NSPanel, QuotaRingLayer, CALayer) {
        _ = NSApplication.shared
        let panel = NSPanel(contentRect: CGRect(x: -1000, y: -1000, width: 60, height: 32),
                            styleMask: .borderless, backing: .buffered, defer: false)
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 60, height: 32))
        host.wantsLayer = true
        panel.contentView = host
        let ring = QuotaRingLayer()
        ring.update(diameter: 16, remainingPercent: percent)
        ring.position = CGPoint(x: 30, y: 16)
        host.layer?.addSublayer(ring)
        panel.orderFrontRegardless()
        let glyph = try XCTUnwrap(ring.sublayers?.first { $0.name == "quotaGlyph" })
        return (panel, ring, glyph)
    }

    private func imageData(_ image: CGImage) -> Data? {
        image.dataProvider?.data as Data?
    }
}
