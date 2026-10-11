import AppKit
import QuartzCore
import XCTest
@testable import QuotaBar

@MainActor
final class PanelPresentationOriginTests: XCTestCase {
    func testReopeningAfterHiddenResizeKeepsOriginAtNotchThroughLayout() async throws {
        let harness = makeHarness()
        defer { harness.animator.stopImmediately() }
        let originalGeometry = try restingGeometry(of: harness)

        harness.animator.setPresented(true, anchorX: harness.container.bounds.midX)
        try await samplePinnedSurface(harness, geometry: originalGeometry, frames: 34)
        harness.animator.setPresented(false, anchorX: harness.container.bounds.midX)
        try await samplePinnedSurface(harness, geometry: originalGeometry, frames: 22)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertFalse(harness.panel.isVisible)

        // A background content update can resize the ordered-out window. Leave
        // it hidden across run-loop turns, then reopen with fresh Auto Layout.
        harness.panel.setContentSize(NSSize(width: 516, height: 302))
        forceLayout(harness)
        try await Task.sleep(for: .milliseconds(140))
        forceLayout(harness)
        let resizedGeometry = try restingGeometry(of: harness)
        XCTAssertNotEqual(resizedGeometry.frame.size, originalGeometry.frame.size)
        XCTAssertEqual(resizedGeometry.anchor, originalGeometry.anchor,
                       "A closed panel must retain AppKit's backing-layer anchor")

        harness.animator.setPresented(true, anchorX: harness.container.bounds.midX)
        try await samplePinnedSurface(harness, geometry: resizedGeometry, frames: 34)
        XCTAssertTrue(harness.panel.isVisible)
        XCTAssertTrue(harness.animator.isPresented)

        harness.animator.setPresented(false, anchorX: harness.container.bounds.midX)
        try await samplePinnedSurface(harness, geometry: resizedGeometry, frames: 22)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertFalse(harness.panel.isVisible)
    }

    func testReversingDuringLayoutKeepsOriginAtNotch() async throws {
        let harness = makeHarness()
        defer { harness.animator.stopImmediately() }
        let geometry = try restingGeometry(of: harness)

        harness.animator.setPresented(true, anchorX: harness.container.bounds.midX)
        try await samplePinnedSurface(harness, geometry: geometry, frames: 8)
        harness.animator.setPresented(false, anchorX: harness.container.bounds.midX)
        try await samplePinnedSurface(harness, geometry: geometry, frames: 5)
        harness.animator.setPresented(true, anchorX: harness.container.bounds.midX)
        try await samplePinnedSurface(harness, geometry: geometry, frames: 34)

        XCTAssertTrue(harness.panel.isVisible,
                      "The superseded close must not hide the reopened panel")
        XCTAssertTrue(harness.animator.isPresented)
    }

    private struct Harness {
        let panel: NSPanel
        let container: NSView
        let surface: NotchSurfaceView
        let animator: PanelPresentationAnimator
    }

    private struct RestingGeometry {
        let frame: NSRect
        let anchor: CGPoint
        let position: CGPoint
    }

    private func makeHarness() -> Harness {
        _ = NSApplication.shared
        let panel = NSPanel(contentRect: NSRect(x: -1000, y: -1000, width: 420, height: 218),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 218))
        container.wantsLayer = true
        panel.contentView = container
        let surface = NotchSurfaceView()
        surface.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(surface)
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(content)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 32),
            surface.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -32),
            surface.topAnchor.constraint(equalTo: container.topAnchor),
            surface.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -32),
            content.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            content.topAnchor.constraint(equalTo: surface.topAnchor),
            content.bottomAnchor.constraint(equalTo: surface.bottomAnchor)
        ])
        container.layoutSubtreeIfNeeded()
        let animator = PanelPresentationAnimator(panel: panel, contentView: content,
                                                  surfaceView: surface, reduceMotion: { false })
        animator.compactSize = NSSize(width: 297, height: 32)
        animator.cameraWidth = 185
        return Harness(panel: panel, container: container, surface: surface, animator: animator)
    }

    private func restingGeometry(of harness: Harness) throws -> RestingGeometry {
        let layer = try XCTUnwrap(harness.surface.layer)
        XCTAssertGreaterThan(harness.surface.bounds.width, 0)
        XCTAssertGreaterThan(harness.surface.bounds.height, 0)
        return RestingGeometry(frame: harness.surface.frame, anchor: layer.anchorPoint,
                               position: layer.position)
    }

    private func forceLayout(_ harness: Harness) {
        harness.container.needsLayout = true
        harness.surface.needsLayout = true
        harness.container.layoutSubtreeIfNeeded()
        harness.panel.displayIfNeeded()
    }

    private func samplePinnedSurface(_ harness: Harness, geometry: RestingGeometry,
                                     frames: Int) async throws {
        for _ in 0..<frames {
            forceLayout(harness)
            try await Task.sleep(for: .milliseconds(20))
            let layer = try XCTUnwrap(harness.surface.layer)
            XCTAssertEqual(harness.surface.frame, geometry.frame,
                           "Presentation must not alter the view's Auto Layout geometry")
            XCTAssertEqual(layer.anchorPoint.x, geometry.anchor.x, accuracy: 0.0001,
                           "AppKit must retain ownership of the backing-layer anchor")
            XCTAssertEqual(layer.anchorPoint.y, geometry.anchor.y, accuracy: 0.0001,
                           "AppKit must retain ownership of the backing-layer anchor")
            XCTAssertEqual(layer.position.x, geometry.position.x, accuracy: 0.01,
                           "Presentation must not reposition the backing layer")
            XCTAssertEqual(layer.position.y, geometry.position.y, accuracy: 0.01,
                           "Presentation must not reposition the backing layer")
            let live = try XCTUnwrap(layer.presentation())
            let topCenter = CGPoint(x: live.bounds.midX, y: live.bounds.maxY)
            let visibleTopCenter = live.convert(topCenter, to: live.superlayer)
            XCTAssertEqual(visibleTopCenter.x, geometry.frame.midX, accuracy: 0.5,
                           "The live surface must grow and recoil at the notch's horizontal center")
            XCTAssertEqual(visibleTopCenter.y, geometry.frame.maxY, accuracy: 0.5,
                           "The live surface must stay attached to the screen top through layout")
        }
    }
}
