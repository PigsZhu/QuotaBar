import AppKit
import QuartzCore
import XCTest
@testable import QuotaBar

@MainActor
final class PanelPresentationAnimatorTests: XCTestCase {
    func testLiveSurfaceOvershootsInsideWindowAndSettles() async throws {
        let panel = makePanel()
        panel.setContentSize(NSSize(width: 388, height: 182))
        let surface = NSView(frame: NSRect(x: 32, y: 32, width: 324, height: 150))
        surface.wantsLayer = true
        panel.contentView!.addSubview(surface)
        let content = NSView(frame: surface.bounds)
        surface.addSubview(content)
        let animator = PanelPresentationAnimator(panel: panel, contentView: content,
                                                  surfaceView: surface, reduceMotion: { false })
        defer { animator.stopImmediately() }
        animator.setPresented(true, anchorX: 194)
        var peak: CGFloat = 1
        for _ in 0..<34 {
            try await Task.sleep(for: .milliseconds(20))
            if let live = surface.layer?.presentation() {
                peak = max(peak, live.transform.m22)
                XCTAssertGreaterThanOrEqual(live.frame.minX, -0.5)
                XCTAssertGreaterThanOrEqual(live.frame.minY, -0.5)
                XCTAssertLessThanOrEqual(live.frame.maxX, 388.5)
            }
        }
        XCTAssertGreaterThan(peak, 1.03, "The real surface must visibly overshoot, not just its mask")
        XCTAssertEqual(surface.layer!.transform.m22, 1, accuracy: 0.001)
        animator.setPresented(false, anchorX: 194)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(panel.isVisible)
    }

    func testClosingKeepsSurfaceOpaqueUntilHandoffBeforeHiding() async throws {
        let panel = makePanel()
        panel.setContentSize(NSSize(width: 388, height: 182))
        let surface = NSView(frame: NSRect(x: 32, y: 32, width: 324, height: 150))
        surface.wantsLayer = true
        panel.contentView!.addSubview(surface)
        let content = NSView(frame: surface.bounds)
        surface.addSubview(content)
        let animator = PanelPresentationAnimator(panel: panel, contentView: content,
                                                  surfaceView: surface, reduceMotion: { false })
        defer { animator.stopImmediately() }
        animator.setPresented(true, anchorX: 194)
        try await Task.sleep(for: .milliseconds(700))

        var handoffState: (isVisible: Bool, alpha: CGFloat)?
        animator.onWillFinishClosing = {
            handoffState = (panel.isVisible, panel.alphaValue)
        }
        let compactY = animator.compactSize.height / surface.bounds.height
        animator.setPresented(false, anchorX: 194)
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertTrue(panel.isVisible, "The shrinking surface must remain visible")
        XCTAssertEqual(panel.alphaValue, 1, accuracy: 0.001,
                       "Closing must shrink the glass without fading the window away")
        let live = try XCTUnwrap(surface.layer?.presentation())
        XCTAssertGreaterThan(live.transform.m22, compactY)
        XCTAssertLessThan(live.transform.m22, 1)
        XCTAssertNil(handoffState, "The handoff must wait until the shrink finishes")

        try await Task.sleep(for: .milliseconds(450))
        let handoff = try XCTUnwrap(handoffState)
        XCTAssertTrue(handoff.isVisible, "The compact notch must take over before the panel hides")
        XCTAssertEqual(handoff.alpha, 1, accuracy: 0.001)
        XCTAssertFalse(panel.isVisible)
    }

    func testClosingLandsNarrowThenElasticallyWidensToCompactSize() async throws {
        let panel = makePanel()
        panel.setContentSize(NSSize(width: 420, height: 218))
        let surface = NotchSurfaceView(frame: NSRect(x: 32, y: 32, width: 356, height: 186))
        panel.contentView!.addSubview(surface)
        let animator = PanelPresentationAnimator(panel: panel, surfaceView: surface,
                                                  reduceMotion: { false })
        animator.compactSize = NSSize(width: 297, height: 32)
        animator.cameraWidth = 185
        defer { animator.stopImmediately() }
        animator.setPresented(true, anchorX: 210)
        try await Task.sleep(for: .milliseconds(700))
        animator.setPresented(false, anchorX: 210)

        let animation = try XCTUnwrap(
            surface.layer?.animation(forKey: "QuotaBar.surfaceScale") as? CAKeyframeAnimation
        )
        let values = try XCTUnwrap(animation.values as? [NSValue])
        let keyTimes = try XCTUnwrap(animation.keyTimes)
        XCTAssertEqual(values.count, keyTimes.count)
        let transforms = values.map(\.caTransform3DValue)
        let compactX = animator.compactSize.width / surface.bounds.width
        let compactY = animator.compactSize.height / surface.bounds.height
        let tolerance: CGFloat = 0.00001
        let narrowIndex = try XCTUnwrap(transforms.indices.min {
            transforms[$0].m11 < transforms[$1].m11
        })
        let absorptionIndex = try XCTUnwrap(keyTimes.firstIndex { $0.doubleValue >= 0.4 })
        let absorption = Array(transforms[absorptionIndex...])
        let widthPeakIndex = try XCTUnwrap(absorption.indices.max {
            absorption[$0].m11 < absorption[$1].m11
        })
        let heightPeakIndex = try XCTUnwrap(absorption.indices.max {
            absorption[$0].m22 < absorption[$1].m22
        })

        XCTAssertEqual(transforms[0].m11 * surface.bounds.width, 356, accuracy: 0.01)
        XCTAssertEqual(keyTimes[narrowIndex].doubleValue, 0.4, accuracy: 0.001,
                       "The card must first land on the narrower notch")
        XCTAssertEqual(transforms[narrowIndex].m11 * surface.bounds.width, 249.48, accuracy: 0.5)
        XCTAssertLessThanOrEqual(transforms[narrowIndex].m11, compactX * 0.86,
                                 "The narrow landing must make the following widening visible")
        XCTAssertGreaterThan(absorption[heightPeakIndex].m22, compactY * 1.15,
                             "Absorbing the card must visibly swell the notch vertically")
        XCTAssertGreaterThan(absorption[widthPeakIndex].m11, compactX * 1.005,
                             "Widening must carry slightly past the resting width")
        XCTAssertLessThan(absorption[widthPeakIndex].m11, compactX * 1.02,
                          "The final recoil must remain gentle")
        XCTAssertLessThan(heightPeakIndex, widthPeakIndex,
                          "The vertical swell must lead the sideways stretch")
        let finalTransform = try XCTUnwrap(absorption.last)
        XCTAssertEqual(finalTransform.m11, compactX, accuracy: tolerance)
        XCTAssertEqual(finalTransform.m22, compactY, accuracy: tolerance)
        for transform in transforms {
            XCTAssertGreaterThanOrEqual(transform.m11 * surface.bounds.width - 2 * 16,
                                        animator.cameraWidth - tolerance,
                                        "Even the narrow landing must cover the physical camera after shoulder insets")
            XCTAssertGreaterThanOrEqual(transform.m22, compactY - tolerance,
                                        "Closing must never undershoot the compact height")
        }
        for index in transforms.indices.dropFirst() where index <= narrowIndex {
            XCTAssertLessThanOrEqual(transforms[index].m11, transforms[index - 1].m11 + tolerance,
                                     "The card must shrink continuously into the narrow landing")
        }
        var stretchesWhileHeightRecovers = false
        for (index, transform) in absorption.enumerated() {
            guard index > 0 else { continue }
            let previous = absorption[index - 1]
            if index <= widthPeakIndex {
                XCTAssertGreaterThanOrEqual(transform.m11, previous.m11 - tolerance,
                                            "The notch must stretch in one continuous rise")
            } else {
                XCTAssertLessThanOrEqual(transform.m11, previous.m11 + tolerance,
                                         "The notch must return without another reversal")
            }
            if index <= heightPeakIndex {
                XCTAssertGreaterThanOrEqual(transform.m22, previous.m22 - tolerance,
                                            "The notch must swell in one continuous rise")
            } else {
                XCTAssertLessThanOrEqual(transform.m22, previous.m22 + tolerance,
                                         "The swell must recover without another vertical bounce")
                if transform.m11 > previous.m11 + tolerance,
                   transform.m22 < previous.m22 - tolerance {
                    stretchesWhileHeightRecovers = true
                }
            }
        }
        XCTAssertTrue(stretchesWhileHeightRecovers,
                      "Width must keep stretching while height recovers in the same motion")
        XCTAssertEqual(animation.duration, 0.54, accuracy: 0.001,
                       "The coupled absorption must preserve the existing close handoff timing")
    }

    private func makePanel() -> NSPanel {
        _ = NSApplication.shared
        let panel = NSPanel(contentRect: NSRect(x: -1000, y: -1000, width: 324, height: 150),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 324, height: 150))
        return panel
    }

    func testOpenCloseKeepsLayoutAndRemovesWindowAfterShrink() async throws {
        let panel = makePanel()
        let animator = PanelPresentationAnimator(panel: panel, reduceMotion: { false })
        defer { animator.stopImmediately() }
        let frame = panel.frame
        animator.setPresented(true, anchorX: 20)
        XCTAssertTrue(animator.isPresented)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.alphaValue, 1)
        XCTAssertEqual(panel.frame, frame)
        XCTAssertNil(panel.contentView!.layer!.mask)
        animator.setPresented(false, anchorX: 20)
        XCTAssertTrue(panel.isVisible, "Closing must remain rendered until the animation finishes")
        // Leave scheduling headroom after the 0.54 s close and recoil.
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(panel.ignoresMouseEvents)
    }

    func testReopenCancelsStaleCloseCompletion() async throws {
        let panel = makePanel()
        let animator = PanelPresentationAnimator(panel: panel, reduceMotion: { false })
        defer { animator.stopImmediately() }
        animator.setPresented(true, anchorX: 20)
        try await Task.sleep(for: .milliseconds(40))
        animator.setPresented(false, anchorX: 20)
        try await Task.sleep(for: .milliseconds(40))
        animator.setPresented(true, anchorX: 20)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertTrue(animator.isPresented)
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.alphaValue, 1)
        XCTAssertFalse(panel.ignoresMouseEvents)
    }

    func testRapidAlternationEndsClosed() async throws {
        let panel = makePanel()
        let animator = PanelPresentationAnimator(panel: panel, reduceMotion: { false })
        defer { animator.stopImmediately() }
        for index in 0..<8 {
            animator.setPresented(index.isMultiple(of: 2), anchorX: 290)
            try await Task.sleep(for: .milliseconds(25))
        }
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(animator.isPresented)
        XCTAssertFalse(panel.isVisible)
    }

    func testReducedMotionOnlyFades() async throws {
        let panel = makePanel()
        let animator = PanelPresentationAnimator(panel: panel, reduceMotion: { true })
        defer { animator.stopImmediately() }
        animator.setPresented(true, anchorX: 20)
        XCTAssertNil(panel.contentView!.layer!.mask)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(panel.isVisible)
        animator.setPresented(false, anchorX: 20)
        XCTAssertNil(panel.contentView!.layer!.mask)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(panel.isVisible)
    }
}
