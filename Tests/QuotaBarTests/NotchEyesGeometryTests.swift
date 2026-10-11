import AppKit
import QuartzCore
import XCTest
@testable import QuotaBar

@MainActor
final class NotchEyesGeometryTests: XCTestCase {
    func testPupilsGlanceAcrossStationaryWhitesAndReturnToAcceptedStyle() {
        for side in [-1.0, 1.0] {
            let white = NotchEyesGeometry.path(side: side)
            let left = NotchEyesPose.glancing(horizontal: -1)
            let right = NotchEyesPose.glancing(horizontal: 1)
            let leftX = NotchEyesGeometry.path(side: side, pose: left, pupil: true).boundingBoxOfPath.midX
            let rightX = NotchEyesGeometry.path(side: side, pose: right, pupil: true).boundingBoxOfPath.midX
            XCTAssertLessThan(leftX, white.boundingBoxOfPath.midX)
            XCTAssertGreaterThan(rightX, white.boundingBoxOfPath.midX)
            XCTAssertGreaterThan(rightX - leftX, 3, "Pupil movement must be large enough to read in the notch")
            var previousX = leftX
            for sample in 0...20 {
                let pose = NotchEyesPose.interpolate(left, right, progress: Double(sample) / 20)
                XCTAssertEqual(NotchEyesGeometry.path(side: side, pose: pose), white,
                               "An independent glance must not turn or deform the eye whites")
                let pupil = NotchEyesGeometry.path(side: side, pose: pose, pupil: true)
                XCTAssertGreaterThanOrEqual(pupil.boundingBoxOfPath.midX, previousX)
                previousX = pupil.boundingBoxOfPath.midX
                let points = vertices(of: pupil)
                XCTAssertGreaterThan(Double(points.filter { white.contains($0) }.count) / Double(points.count), 0.6,
                                     "The eyelid mask must leave a readable pupil throughout the glance")
            }
            XCTAssertEqual(NotchEyesGeometry.path(side: side, pose: .glancing(horizontal: 0), pupil: true),
                           NotchEyesGeometry.path(side: side, pupil: true),
                           "Default pupil offset and tilt must remain exactly as accepted")
        }
    }

    func testGazeFitsPhysicalWingAndNeutralFitsClosingRevealWithoutEyeOverlap() {
        let reveal = CGRect(x: -2, y: -2, width: 20, height: 20)
        // The real 41.28 × 32 pt wing, relative to the eye layer's (8, 8) center.
        let wing = CGRect(x: -12.64, y: -8, width: 41.28, height: 32)
        for side in [-1.0, 1.0] {
            XCTAssertTrue(reveal.contains(NotchEyesGeometry.path(side: side).boundingBoxOfPath))
        }
        for horizontal in stride(from: -1.0, through: 1.0, by: 0.25) {
            for vertical in stride(from: -1.0, through: 1.0, by: 0.5) {
                for openness in [0.0, 0.35, 1.0] {
                    var pose = NotchEyesPose.looking(horizontal: horizontal, vertical: vertical)
                    pose.openness = openness
                    let left = NotchEyesGeometry.path(side: -1, pose: pose)
                    let right = NotchEyesGeometry.path(side: 1, pose: pose)
                    let context = "gaze (\(horizontal), \(vertical)), openness \(openness)"
                    XCTAssertTrue(wing.contains(left.boundingBoxOfPath), context)
                    XCTAssertTrue(wing.contains(right.boundingBoxOfPath), context)
                    // Rolled eyes can have intersecting bounding boxes without
                    // their actual silhouettes touching. Check the silhouettes.
                    let overlap = left.boundingBoxOfPath.intersection(right.boundingBoxOfPath)
                    guard !overlap.isNull, !overlap.isEmpty else { continue }
                    for x in stride(from: overlap.minX, through: overlap.maxX, by: 0.1) {
                        for y in stride(from: overlap.minY, through: overlap.maxY, by: 0.1) {
                            let point = CGPoint(x: x, y: y)
                            XCTAssertFalse(left.contains(point) && right.contains(point), context)
                        }
                    }
                }
            }
        }
    }

    func testBlinkRetainsSlitAndPupilsFollowTheSameAnimatedWhiteMask() throws {
        for side in [-1.0, 1.0] {
            let neutral = NotchEyesGeometry.path(side: side)
            var closed = NotchEyesPose.resting
            closed.openness = NotchEyesGeometry.blinkOpenness(progress: 0.42)
            let slit = NotchEyesGeometry.path(side: side, pose: closed)
            XCTAssertGreaterThan(slit.boundingBoxOfPath.height, 0.8)
            XCTAssertLessThan(slit.boundingBoxOfPath.height, neutral.boundingBoxOfPath.height * 0.2)
            for progress in [0.0, 1.0] {
                var pose = NotchEyesPose.resting
                pose.openness = NotchEyesGeometry.blinkOpenness(progress: progress)
                XCTAssertEqual(vertices(of: NotchEyesGeometry.path(side: side, pose: pose)), vertices(of: neutral))
            }
        }
        let eyes = NotchEyesLayer()
        eyes.resetPose(.looking(horizontal: 1, vertical: -1))
        eyes.blink()
        let whites = try XCTUnwrap(eyes.sublayers as? [CAShapeLayer])
        XCTAssertEqual(whites.count, 2)
        for white in whites {
            let pupil = try XCTUnwrap(white.sublayers?.first as? CAShapeLayer)
            let lid = try XCTUnwrap(pupil.mask as? CAShapeLayer)
            XCTAssertEqual(vertices(of: try XCTUnwrap(lid.path)), vertices(of: try XCTUnwrap(white.path)))
            let whiteAnimation = try XCTUnwrap(white.animation(forKey: "expression") as? CAKeyframeAnimation)
            let maskAnimation = try XCTUnwrap(lid.animation(forKey: "expression") as? CAKeyframeAnimation)
            XCTAssertEqual(whiteAnimation.keyTimes, maskAnimation.keyTimes)
            XCTAssertEqual(whiteAnimation.duration, maskAnimation.duration)
            let whitePaths = try XCTUnwrap(whiteAnimation.values as? [CGPath])
            let maskPaths = try XCTUnwrap(maskAnimation.values as? [CGPath])
            XCTAssertEqual(whitePaths.count, maskPaths.count)
            for (whitePath, maskPath) in zip(whitePaths, maskPaths) {
                XCTAssertEqual(vertices(of: whitePath), vertices(of: maskPath),
                               "The pupil must remain clipped throughout the eyelid animation")
            }
        }
    }

    func testEveryIdleTransitionFitsThePhysicalWingAndReturnsToNeutral() {
        let wing = CGRect(x: -12.64, y: -8, width: 41.28, height: 32)
        for expression in NotchEyesIdleExpression.allCases {
            var previous = NotchEyesPose.resting
            for (index, step) in expression.steps.enumerated() {
                for sample in 0...20 {
                    let pose = NotchEyesPose.interpolate(previous, step.pose, progress: Double(sample) / 20)
                    for side in [-1.0, 1.0] {
                        let path = NotchEyesGeometry.path(side: side, pose: pose)
                        XCTAssertTrue(wing.contains(path.boundingBoxOfPath),
                                      "\(expression), step \(index), sample \(sample), side \(side) exceeds the notch wing")
                    }
                }
                previous = step.pose
            }
            for side in [-1.0, 1.0] {
                XCTAssertEqual(vertices(of: NotchEyesGeometry.path(side: side, pose: previous)),
                               vertices(of: NotchEyesGeometry.path(side: side)),
                               "\(expression) should end with the accepted resting eyes")
                XCTAssertEqual(vertices(of: NotchEyesGeometry.path(side: side, pose: previous, pupil: true)),
                               vertices(of: NotchEyesGeometry.path(side: side, pupil: true)),
                               "\(expression) should restore the accepted pupil position too")
            }
        }
    }

    func testWinkClosesOneEyeWhileTheOtherStaysOpen() throws {
        let wink = try XCTUnwrap(NotchEyesIdleExpression.wink.steps.first {
            $0.pose.leftOpenness != $0.pose.rightOpenness
        }).pose
        var open = wink
        open.leftOpenness = 1
        open.rightOpenness = 1
        let closedSide = wink.leftOpenness < wink.rightOpenness ? -1.0 : 1.0
        XCTAssertEqual(vertices(of: NotchEyesGeometry.path(side: -closedSide, pose: wink)),
                       vertices(of: NotchEyesGeometry.path(side: -closedSide, pose: open)))
        let closedHeight = NotchEyesGeometry.path(side: closedSide, pose: wink).boundingBoxOfPath.height
        let openHeight = NotchEyesGeometry.path(side: closedSide, pose: open).boundingBoxOfPath.height
        XCTAssertGreaterThan(closedHeight, 0)
        XCTAssertLessThan(closedHeight, openHeight * 0.3)
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
