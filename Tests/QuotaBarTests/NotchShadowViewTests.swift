import AppKit
import QuartzCore
import XCTest
@testable import QuotaBar

@MainActor
final class NotchShadowViewTests: XCTestCase {
    func testClosingShadowTracksContourAndDisappearsBeforeCompactRebound() async throws {
        let (panel, surface, shadow, animator) = makePresentation()
        defer { animator.stopImmediately() }
        animator.setPresented(true, anchorX: 210)
        try await Task.sleep(for: .milliseconds(700))
        let restingOpacity = try XCTUnwrap(shadow.layer).shadowOpacity
        var opacityAtHandoff: Float?
        animator.onWillFinishClosing = {
            opacityAtHandoff = shadow.layer?.presentation()?.shadowOpacity ?? shadow.layer?.shadowOpacity
        }
        animator.setPresented(false, anchorX: 210)

        let surfaceAnimation = try XCTUnwrap(
            surface.layer?.animation(forKey: "QuotaBar.surfaceScale") as? CAKeyframeAnimation
        )
        let scales = try XCTUnwrap(surfaceAnimation.values as? [NSValue]).map(\.caTransform3DValue)
        let keyTimes = try XCTUnwrap(surfaceAnimation.keyTimes)
        let pathAnimation = try animation("shadowPath", on: shadow)
        let paths = try XCTUnwrap(pathAnimation.values as? [CGPath])
        let opacityAnimation = try animation("shadowOpacity", on: shadow)
        let opacities = try XCTUnwrap(opacityAnimation.values as? [NSNumber]).map(\.floatValue)
        let radiusAnimation = try animation("shadowRadius", on: shadow)
        let radii = try XCTUnwrap(radiusAnimation.values as? [NSNumber]).map(\.doubleValue)

        XCTAssertTrue(shadow.superview === surface.superview)
        XCTAssertNil(shadow.layer?.mask, "The shadow must extend outside the glass mask")
        XCTAssertFalse(try XCTUnwrap(shadow.layer).masksToBounds)
        for track in [pathAnimation, opacityAnimation, radiusAnimation] {
            XCTAssertEqual(track.keyTimes, keyTimes)
            XCTAssertEqual(track.duration, surfaceAnimation.duration)
            XCTAssertFalse(track.isRemovedOnCompletion, "Hold the final shadow until window handoff")
        }
        XCTAssertEqual(paths.count, scales.count)
        XCTAssertEqual(opacities.count, keyTimes.count)
        XCTAssertEqual(radii.count, keyTimes.count)
        for index in keyTimes.indices {
            let rect = paths[index].boundingBoxOfPath
            XCTAssertEqual(rect.width, surface.bounds.width * scales[index].m11, accuracy: 0.001)
            XCTAssertEqual(rect.height, surface.bounds.height * scales[index].m22, accuracy: 0.001)
            XCTAssertEqual(rect.midX, surface.bounds.midX, accuracy: 0.001)
            XCTAssertEqual(rect.maxY, surface.bounds.maxY, accuracy: 0.001)
            if index > 0 {
                XCTAssertLessThanOrEqual(opacities[index], opacities[index - 1] + 0.00001)
                XCTAssertLessThanOrEqual(radii[index], radii[index - 1] + 0.00001)
            }
            if keyTimes[index].doubleValue >= 0.4 {
                XCTAssertEqual(opacities[index], 0, accuracy: 0.00001,
                               "The notch rebound must not restore the shadow")
                XCTAssertEqual(radii[index], 0, accuracy: 0.00001)
            }
        }
        XCTAssertGreaterThan(restingOpacity, 0)
        XCTAssertEqual(opacities[0], restingOpacity, accuracy: 0.001)
        XCTAssertGreaterThan(opacities.filter { $0 > 0 && $0 < restingOpacity }.count, 8,
                             "The shadow must fade progressively rather than switch off")
        XCTAssertEqual(paths.first!.boundingBoxOfPath.width, 356, accuracy: 0.001)
        XCTAssertLessThan(paths.map { $0.boundingBoxOfPath.width }.min()!, 260)
        XCTAssertEqual(paths.last!.boundingBoxOfPath.width, 297, accuracy: 0.001)

        try await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(try XCTUnwrap(opacityAtHandoff), 0, accuracy: 0.00001)
        XCTAssertNil(shadow.layer?.animation(forKey: "shadowPath"))
        XCTAssertEqual(shadow.layer!.shadowOpacity, restingOpacity, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(shadow.layer?.shadowPath).boundingBoxOfPath.width, 356,
                       accuracy: 0.001, "Reset the hidden shadow for the next opening")
    }

    func testReopeningContinuesFromVisibleShadowInsteadOfRestarting() async throws {
        let (_, _, shadow, animator) = makePresentation()
        defer { animator.stopImmediately() }
        animator.setPresented(true, anchorX: 210)
        try await Task.sleep(for: .milliseconds(700))
        animator.setPresented(false, anchorX: 210)
        try await Task.sleep(for: .milliseconds(80))
        let live = try XCTUnwrap(shadow.layer?.presentation())
        let liveOpacity = live.shadowOpacity
        let liveRadius = live.shadowRadius
        let liveBounds = try XCTUnwrap(live.shadowPath).boundingBoxOfPath
        XCTAssertGreaterThan(liveOpacity, 0)

        animator.setPresented(true, anchorX: 210)
        let paths = try XCTUnwrap(try animation("shadowPath", on: shadow).values as? [CGPath])
        let opacities = try XCTUnwrap(try animation("shadowOpacity", on: shadow).values as? [NSNumber])
        let radii = try XCTUnwrap(try animation("shadowRadius", on: shadow).values as? [NSNumber])
        XCTAssertEqual(try XCTUnwrap(opacities.first).floatValue, liveOpacity, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(radii.first).doubleValue, Double(liveRadius), accuracy: 0.5)
        let firstBounds = try XCTUnwrap(paths.first).boundingBoxOfPath
        XCTAssertEqual(firstBounds.width, liveBounds.width, accuracy: 2)
        XCTAssertEqual(firstBounds.height, liveBounds.height, accuracy: 2)
    }

    private func animation(_ key: String, on shadow: NotchShadowView) throws -> CAKeyframeAnimation {
        try XCTUnwrap(shadow.layer?.animation(forKey: key) as? CAKeyframeAnimation)
    }

    private func makePresentation() -> (NSPanel, NotchSurfaceView, NotchShadowView, PanelPresentationAnimator) {
        _ = NSApplication.shared
        let panel = NSPanel(contentRect: NSRect(x: -1000, y: -1000, width: 420, height: 218),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 218))
        let surface = NotchSurfaceView(frame: NSRect(x: 32, y: 32, width: 356, height: 186))
        let shadow = NotchShadowView(frame: surface.frame)
        panel.contentView!.addSubview(shadow)
        panel.contentView!.addSubview(surface)
        surface.shadowView = shadow
        let animator = PanelPresentationAnimator(panel: panel, surfaceView: surface, reduceMotion: { false })
        animator.compactSize = NSSize(width: 297, height: 32)
        animator.cameraWidth = 185
        return (panel, surface, shadow, animator)
    }
}
