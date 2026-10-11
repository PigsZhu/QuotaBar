import AppKit
import QuartzCore
import XCTest
@testable import QuotaBar

@MainActor
final class NotchEyesAngerGeometryTests: XCTestCase {
    func testAngerLowersTheInnerUpperLidWithoutChangingPupilsOrLowerContour() {
        for side in [-1.0, 1.0] {
            var angry = NotchEyesPose.resting
            angry.anger = 1
            let neutral = vertices(of: NotchEyesGeometry.path(side: side))
            let glare = vertices(of: NotchEyesGeometry.path(side: side, pose: angry))
            let inner = side < 0 ? 8 : 24
            let outer = side < 0 ? 24 : 8
            XCTAssertGreaterThan(glare[outer].y - glare[inner].y, 1,
                                 "The inward lid slope must read as anger, not an oval squint")
            XCTAssertLessThan(glare[inner].y, neutral[inner].y - 1)
            XCTAssertEqual(Array(glare[32...]), Array(neutral[32...]),
                           "The lower white keeps its accepted round contour")
            XCTAssertEqual(NotchEyesGeometry.path(side: side, pose: angry, pupil: true),
                           NotchEyesGeometry.path(side: side, pupil: true))
        }
    }

    func testAngerTransitionsKeep64FinitePointsInsideTheWingAcrossGazeAndBlink() {
        let wing = CGRect(x: -12.64, y: -8, width: 41.28, height: 32)
        for horizontal in [-1.0, 0, 1] {
            for vertical in [-1.0, 0, 1] {
                for openness in [0.0, 0.8, 1] {
                    var start = NotchEyesPose.looking(horizontal: horizontal, vertical: vertical)
                    start.openness = openness
                    var target = start
                    target.anger = 1
                    for sample in 0...20 {
                        let pose = NotchEyesPose.interpolate(start, target, progress: Double(sample) / 20)
                        var sameGazeWithoutAnger = pose
                        sameGazeWithoutAnger.anger = 0
                        XCTAssertEqual(pose.anger, Double(sample) / 20, accuracy: 0.000001)
                        for side in [-1.0, 1.0] {
                            let path = NotchEyesGeometry.path(side: side, pose: pose)
                            let points = vertices(of: path)
                            XCTAssertEqual(points.count, 64)
                            XCTAssertTrue(points.allSatisfy { $0.x.isFinite && $0.y.isFinite })
                            XCTAssertTrue(wing.contains(path.boundingBoxOfPath))
                            XCTAssertEqual(NotchEyesGeometry.path(side: side, pose: pose, pupil: true),
                                           NotchEyesGeometry.path(side: side, pose: sameGazeWithoutAnger, pupil: true))
                        }
                    }
                }
            }
        }
    }

    func testWhitePinkCoralColorsClampAndKeepTheAcceptedNeutral() throws {
        XCTAssertEqual(NotchEyesAppearance.whiteColor(anger: 0),
                       NSColor(calibratedWhite: 0.96, alpha: 1).cgColor)
        XCTAssertEqual(NotchEyesAppearance.whiteColor(anger: -1), NotchEyesAppearance.whiteColor(anger: 0))
        XCTAssertEqual(NotchEyesAppearance.whiteColor(anger: 2), NotchEyesAppearance.whiteColor(anger: 1))
        let pink = try rgb(NotchEyesAppearance.whiteColor(anger: 0.35))
        let coral = try rgb(NotchEyesAppearance.whiteColor(anger: 1))
        XCTAssertEqual(pink.redComponent, 1, accuracy: 0.0001)
        XCTAssertEqual(pink.greenComponent, 0.75, accuracy: 0.0001)
        XCTAssertEqual(pink.blueComponent, 0.77, accuracy: 0.0001)
        XCTAssertEqual(coral.redComponent, 1, accuracy: 0.0001)
        XCTAssertEqual(coral.greenComponent, 0.38, accuracy: 0.0001)
        XCTAssertEqual(coral.blueComponent, 0.34, accuracy: 0.0001)
    }

    func testColorAndLidShareKeyframesAndResetClearsAnger() throws {
        let eyes = NotchEyesLayer()
        var notifications: [(Double, Double)] = []
        eyes.onAngerChange = { notifications.append(($0, $1)) }
        var angry = NotchEyesPose.looking(horizontal: -0.6, vertical: 0)
        angry.anger = 1
        eyes.look(at: angry, duration: 0.36)
        XCTAssertEqual(notifications.last?.0, 1)
        XCTAssertEqual(notifications.last?.1, 0.36)
        let whites = try XCTUnwrap(eyes.sublayers as? [CAShapeLayer])
        XCTAssertEqual(whites.count, 2, "Background belongs outside the two-white eye layer")
        for white in whites {
            let pathAnimation = try XCTUnwrap(white.animation(forKey: "expression") as? CAKeyframeAnimation)
            let colorAnimation = try XCTUnwrap(white.animation(forKey: "expressionColor") as? CAKeyframeAnimation)
            XCTAssertEqual(pathAnimation.keyTimes, colorAnimation.keyTimes)
            XCTAssertEqual(pathAnimation.duration, colorAnimation.duration)
            let colors = try XCTUnwrap(colorAnimation.values as? [CGColor])
            XCTAssertEqual(colors.count, pathAnimation.values?.count)
            XCTAssertEqual(colors.first, NotchEyesAppearance.whiteColor(anger: 0))
            XCTAssertEqual(colors.last, NotchEyesAppearance.whiteColor(anger: 1))
            XCTAssertEqual(white.fillColor, NotchEyesAppearance.whiteColor(anger: 1))
            let pupil = try XCTUnwrap(white.sublayers?.first as? CAShapeLayer)
            XCTAssertEqual(pupil.fillColor, NSColor.black.cgColor)
            XCTAssertNil(pupil.animation(forKey: "expressionColor"))
        }

        eyes.resetPose()
        XCTAssertEqual(notifications.last?.0, 0)
        XCTAssertEqual(notifications.last?.1, 0)
        for white in whites {
            XCTAssertEqual(white.fillColor, NotchEyesAppearance.whiteColor(anger: 0))
            XCTAssertNil(white.animation(forKey: "expressionColor"))
            XCTAssertNil(white.animation(forKey: "expression"))
        }
    }

    func testInterruptedColorStartsAtTheVisibleLayerColor() throws {
        let eyes = NotchEyesLayer()
        var angry = NotchEyesPose.resting
        angry.anger = 1
        eyes.look(at: angry, duration: 1)
        let whites = try XCTUnwrap(eyes.sublayers as? [CAShapeLayer])
        // An unattached layer has no presentation tree. Set its visible model
        // color to exercise the same fallback used before the first display.
        let visible = NotchEyesAppearance.whiteColor(anger: 0.35)
        whites.forEach { $0.fillColor = visible }
        eyes.look(at: .resting, duration: 0.25)
        for white in whites {
            let animation = try XCTUnwrap(white.animation(forKey: "expressionColor") as? CAKeyframeAnimation)
            let colors = try XCTUnwrap(animation.values as? [CGColor])
            XCTAssertEqual(colors.first, visible)
            XCTAssertEqual(colors.last, NotchEyesAppearance.whiteColor(anger: 0))
        }
    }

    func testBackgroundStaysBeforeCameraAndFollowsAngerAt18PercentPeak() throws {
        let button = NotchButton(frame: CGRect(x: 0, y: 0, width: 320, height: 32))
        button.cameraWidth = 208
        button.layout()
        let container = try XCTUnwrap(button.layer?.sublayers?.first)
        let glow = try XCTUnwrap(container.sublayers?.first as? NotchAngerGlowLayer)
        let bloom = try XCTUnwrap(glow.sublayers?.first as? CAGradientLayer)
        let eyes = try XCTUnwrap(container.sublayers?.dropFirst().first as? NotchEyesLayer)
        XCTAssertEqual(container.sublayers?.count, 3)
        XCTAssertEqual(eyes.sublayers?.count, 2)
        XCTAssertEqual(glow.opacity, 0)
        XCTAssertFalse(glow.isHidden)
        XCTAssertTrue(glow.masksToBounds)
        XCTAssertEqual(bloom.type, .radial)
        let colors = try XCTUnwrap(bloom.colors as? [CGColor])
        XCTAssertEqual(colors.first?.alpha, 1)
        XCTAssertEqual(colors.last?.alpha, 0)
        XCTAssertTrue(zip(colors, colors.dropFirst()).allSatisfy { $0.alpha > $1.alpha },
                      "The radial light must fade continuously without a solid disc")
        let edgeMask = try XCTUnwrap(glow.mask as? CAGradientLayer)
        let edgeColors = try XCTUnwrap(edgeMask.colors as? [CGColor])
        XCTAssertEqual(edgeColors.suffix(2).map(\.alpha), [0, 0])
        let verticalMask = try XCTUnwrap(edgeMask.mask as? CAGradientLayer)
        let verticalColors = try XCTUnwrap(verticalMask.colors as? [CGColor])
        XCTAssertEqual(verticalColors.first?.alpha, 0)
        XCTAssertEqual(verticalColors.last?.alpha, 0)
        for cameraWidth in [CGFloat(160), 208, 240] {
            button.cameraWidth = cameraWidth
            button.layout()
            let cameraLeft = button.bounds.midX - cameraWidth / 2
            XCTAssertLessThanOrEqual(glow.frame.maxX, cameraLeft - 1)
            XCTAssertEqual(glow.frame.minX, button.bounds.minX)
            XCTAssertEqual(edgeMask.frame, glow.bounds)
            XCTAssertEqual(verticalMask.frame, edgeMask.bounds)
        }
        var warm = NotchEyesPose.resting
        warm.anger = 0.3
        eyes.look(at: warm, duration: 0.12)
        XCTAssertEqual(bloom.transform.m11, 0.15, accuracy: 0.0001)
        XCTAssertEqual(glow.opacity, 0.054, accuracy: 0.0001)
        XCTAssertNil(bloom.animation(forKey: "angerExpansion"))
        var angry = warm
        angry.anger = 1
        eyes.look(at: angry, duration: 0.12)
        XCTAssertEqual(glow.opacity, 0.18, accuracy: 0.0001)
        let expansion = try XCTUnwrap(bloom.animation(forKey: "angerExpansion") as? CABasicAnimation)
        XCTAssertEqual(try XCTUnwrap(expansion.fromValue as? NSNumber).doubleValue, 0.15, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(expansion.toValue as? NSNumber).doubleValue, 1, accuracy: 0.0001)
        XCTAssertEqual(expansion.duration, 0.46, accuracy: 0.0001)
        eyes.resetPose()
        XCTAssertEqual(glow.opacity, 0)
        XCTAssertNil(glow.animation(forKey: "anger"))
        XCTAssertNil(bloom.animation(forKey: "angerExpansion"))
        button.cameraWidth = 0
        button.layout()
        XCTAssertTrue(container.isHidden)
        XCTAssertTrue(glow.isHidden)
    }

    func testLiveGlowExpandsFromEyeMidpointThroughRefreshAndResetCannotReviveIt() async throws {
        _ = NSApplication.shared
        let button = NotchButton(frame: CGRect(x: 0, y: 0, width: 320, height: 32))
        button.cameraWidth = 208
        let panel = NSPanel(contentRect: CGRect(x: -1000, y: -1000, width: 320, height: 32),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = button
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        button.layoutSubtreeIfNeeded()
        let container = try XCTUnwrap(button.layer?.sublayers?.first)
        let glow = try XCTUnwrap(container.sublayers?.first as? NotchAngerGlowLayer)
        let bloom = try XCTUnwrap(glow.sublayers?.first as? CAGradientLayer)
        let eyes = try XCTUnwrap(container.sublayers?.dropFirst().first as? NotchEyesLayer)
        var warm = NotchEyesPose.looking(horizontal: -0.8, vertical: 0.25)
        warm.anger = 0.3
        eyes.resetPose(warm)
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(40))
        let liveEyes = try XCTUnwrap(eyes.presentation())
        let whites = try XCTUnwrap(liveEyes.sublayers as? [CAShapeLayer])
        let union = try whites.reduce(CGRect.null) { partial, white in
            partial.union(white.convert(try XCTUnwrap(white.path).boundingBoxOfPath, to: liveEyes))
        }
        let expectedOrigin = liveEyes.convert(CGPoint(x: union.midX, y: union.midY), to: liveEyes.superlayer)
        var angry = warm
        angry.anger = 1
        eyes.look(at: angry, duration: 0.12)
        CATransaction.flush()
        XCTAssertEqual(bloom.position.x + glow.frame.minX, expectedOrigin.x, accuracy: 0.001)
        XCTAssertEqual(bloom.position.y + glow.frame.minY, expectedOrigin.y, accuracy: 0.001)
        let lockedOrigin = bloom.position
        var scales: [CGFloat] = []
        for sample in 0..<9 {
            try await Task.sleep(for: .milliseconds(60))
            if sample == 2 || sample == 4 {
                var turned = NotchEyesPose.looking(horizontal: 0.9, vertical: -0.2)
                turned.anger = 1
                eyes.look(at: turned, duration: 0.12)
                button.remainingPercent = 94
                button.layoutSubtreeIfNeeded()
                CATransaction.flush()
            }
            XCTAssertEqual(bloom.position, lockedOrigin)
            scales.append(try XCTUnwrap(bloom.presentation()).transform.m11)
        }
        XCTAssertLessThan(try XCTUnwrap(scales.first), 0.6)
        XCTAssertGreaterThan(try XCTUnwrap(scales.last) - XCTUnwrap(scales.first), 0.4)
        XCTAssertEqual(try XCTUnwrap(scales.last), 1, accuracy: 0.001,
                       "Quota refresh and same-anger turns must not restart the 0.46-second expansion")
        XCTAssertTrue(zip(scales, scales.dropFirst()).allSatisfy { $1 >= $0 - 0.001 })
        eyes.look(at: .resting, duration: 0.24)
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(try XCTUnwrap(bloom.presentation()).transform.m11, 1, accuracy: 0.001,
                       "Recovery must fade the expanded light, not shrink it")
        eyes.resetPose()
        eyes.look(at: angry, duration: 0.12)
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(50))
        eyes.resetPose()
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(try XCTUnwrap(glow.presentation()).opacity, 0, accuracy: 0.0001)
        XCTAssertNil(glow.animation(forKey: "anger"))
        XCTAssertNil(bloom.animation(forKey: "angerExpansion"))
    }

    private func rgb(_ color: CGColor) throws -> NSColor {
        try XCTUnwrap(NSColor(cgColor: color)?.usingColorSpace(.sRGB))
    }

    private func vertices(of path: CGPath) -> [CGPoint] {
        var points: [CGPoint] = []
        path.applyWithBlock { element in
            switch element.pointee.type {
            case .moveToPoint, .addLineToPoint: points.append(element.pointee.points[0])
            default: break
            }
        }
        return points
    }
}
