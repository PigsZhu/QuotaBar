import AppKit
import QuartzCore
import XCTest
@testable import QuotaBar

@MainActor
final class NotchAngerReleaseTests: XCTestCase {
    func testReleaseIsVisibleExpandsAndStaysDarkThroughTheTurnAndRecovery() async throws {
        let glow = NotchAngerGlowLayer()
        let panel = host(glow)
        defer { panel.orderOut(nil) }
        let origin = CGPoint(x: 32, y: 16)
        glow.update(anger: 1, duration: 0, origin: origin)
        glow.release(origin: origin)
        CATransaction.flush()
        let wave = try XCTUnwrap(glow.sublayers?.first { $0.name == "angerReleaseWave" } as? CAGradientLayer)
        let colors = try XCTUnwrap(wave.colors as? [CGColor])
        XCTAssertEqual(colors.first?.alpha, 0, "The center should open into an outward wave")
        XCTAssertEqual(colors.last?.alpha, 0, "The outer edge must fade softly to clear")
        XCTAssertEqual(wave.position.x + glow.frame.minX, origin.x, accuracy: 0.001)
        XCTAssertEqual(wave.position.y + glow.frame.minY, origin.y, accuracy: 0.001)

        var opacity: [Float] = []
        var scale: [CGFloat] = []
        for sample in 0..<10 {
            try await Task.sleep(for: .milliseconds(60))
            opacity.append(try XCTUnwrap(glow.presentation()).opacity)
            scale.append(try XCTUnwrap(wave.presentation()).transform.m11)
            if sample == 1 {
                glow.update(anger: 1, duration: 0.14, origin: CGPoint(x: 20, y: 16))
                glow.release(origin: CGPoint(x: 20, y: 16))
            }
            if sample == 3 { glow.update(anger: 0.45, duration: 0.16, origin: origin) }
            CATransaction.flush()
        }
        XCTAssertGreaterThan(try XCTUnwrap(opacity.max()), 0.25,
                             "The transient wave must be more visible than the old 18-percent glow")
        XCTAssertGreaterThan(try XCTUnwrap(scale.last), try XCTUnwrap(scale.first))
        XCTAssertEqual(try XCTUnwrap(opacity.last), 0, accuracy: 0.001)
        XCTAssertEqual(wave.position.x + glow.frame.minX, origin.x, accuracy: 0.001,
                       "The moving eyes must not drag or restart the released wave")
        XCTAssertEqual(glow.opacity, 0, "Recovery must not relight the spent wave")
    }

    func testResetCancelsTheWaveAndAllowsTheNextAngerCycle() async throws {
        let glow = NotchAngerGlowLayer()
        let panel = host(glow)
        defer { panel.orderOut(nil) }
        let origin = CGPoint(x: 32, y: 16)
        glow.update(anger: 1, duration: 0, origin: origin)
        glow.release(origin: origin)
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(80))
        glow.update(anger: 0, duration: 0, origin: origin)
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(try XCTUnwrap(glow.presentation()).opacity, 0, accuracy: 0.001)
        XCTAssertTrue((glow.animationKeys() ?? []).isEmpty)
        XCTAssertTrue((glow.sublayers ?? []).allSatisfy { ($0.animationKeys() ?? []).isEmpty })

        glow.update(anger: 1, duration: 0.12, origin: origin)
        glow.release(origin: origin)
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertGreaterThan(try XCTUnwrap(glow.presentation()).opacity, 0.25,
                             "Reset must allow a fresh wave on the next head turn")
        glow.update(anger: 0, duration: 0, origin: origin)
    }

    private func host(_ glow: NotchAngerGlowLayer) -> NSPanel {
        _ = NSApplication.shared
        let panel = NSPanel(contentRect: NSRect(x: -1000, y: -1000, width: 56, height: 32),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 56, height: 32))
        view.wantsLayer = true
        panel.contentView = view
        view.layer!.addSublayer(glow)
        glow.updateFrame(CGRect(x: 0, y: 0, width: 55, height: 32))
        panel.orderFrontRegardless()
        return panel
    }
}
