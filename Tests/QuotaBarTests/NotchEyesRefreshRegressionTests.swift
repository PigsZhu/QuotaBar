import AppKit
import XCTest
@testable import QuotaBar

@MainActor
final class NotchEyesRefreshRegressionTests: XCTestCase {
    func testEffortRemainsVisibleInNotchWhileQuotaRefreshes() async throws {
        _ = NSApplication.shared
        let button = NotchButton(frame: NSRect(x: 0, y: 0, width: 297, height: 32))
        button.cameraWidth = 185
        button.remainingPercent = 95
        let panel = NSPanel(contentRect: NSRect(x: -1000, y: -1000, width: 297, height: 32),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = button
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        button.layoutSubtreeIfNeeded()
        let container = try XCTUnwrap(button.layer?.sublayers?.first)
        let eyes = try XCTUnwrap(container.sublayers?.compactMap { $0 as? NotchEyesLayer }.first)
        eyes.resetPose(NotchEyesIdleExpression.overchargeQuota.steps[3].pose)
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(30))
        eyes.shakeWithEffort()
        CATransaction.flush()
        var horizontal: [CGFloat] = []
        var vertical: [CGFloat] = []
        for sample in 0..<22 {
            try await Task.sleep(for: .milliseconds(20))
            if sample == 5 || sample == 11 {
                // Exercise both a changed quota and a refresh with the same value.
                button.remainingPercent = 94
                button.layoutSubtreeIfNeeded()
                CATransaction.flush()
            }
            let live = try XCTUnwrap(eyes.presentation())
            horizontal.append(live.transform.m41)
            vertical.append(live.transform.m42)
        }
        let horizontalTravel = try XCTUnwrap(horizontal.max()) - XCTUnwrap(horizontal.min())
        let verticalTravel = try XCTUnwrap(vertical.max()) - XCTUnwrap(vertical.min())
        XCTAssertGreaterThan(horizontalTravel, 2.4, "The live eye layer must visibly move through a quota refresh")
        XCTAssertGreaterThan(verticalTravel, 0.8, "The peak squeeze must travel enough vertically to stay perceptible")
        try await Task.sleep(for: .milliseconds(100))
        let settled = try XCTUnwrap(eyes.presentation()).transform
        XCTAssertEqual(settled.m41, 0, accuracy: 0.01)
        XCTAssertEqual(settled.m42, 0, accuracy: 0.01)
    }
}
