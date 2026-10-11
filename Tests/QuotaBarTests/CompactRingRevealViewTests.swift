import AppKit
import QuartzCore
import XCTest
@testable import QuotaBar

@MainActor
final class CompactRingRevealViewTests: XCTestCase {
    func testClosingSymbolsFadeAfterClearingPhysicalCamera() async throws {
        _ = NSApplication.shared
        let view = CompactRingRevealView(frame: NSRect(x: 0, y: 0, width: 356, height: 186))
        view.cameraWidth = 185
        view.compactSize = NSSize(width: 297, height: 32)
        view.remainingPercent = 87
        let panel = NSPanel(contentRect: NSRect(x: -1000, y: -1000, width: 420, height: 218),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let surface = NotchSurfaceView(frame: NSRect(x: 32, y: 32, width: 356, height: 186))
        panel.contentView!.addSubview(surface)
        surface.addSubview(view)
        let animator = PanelPresentationAnimator(panel: panel, surfaceView: surface, reduceMotion: { false })
        animator.compactSize = view.compactSize
        animator.cameraWidth = view.cameraWidth
        var scales: [NSSize] = []
        var keyTimes: [NSNumber] = []
        animator.onCompactRingAnimation = { samples, times, duration, presented in
            guard !presented else { return }
            scales = samples
            keyTimes = times
            view.animate(scales: samples, keyTimes: times, duration: duration, presented: false)
        }
        defer { animator.stopImmediately(); view.resetAnimation() }
        animator.setPresented(true, anchorX: 210)
        try await Task.sleep(for: .milliseconds(700))
        animator.setPresented(false, anchorX: 210)

        let symbols = try XCTUnwrap(view.layer?.sublayers)
        XCTAssertEqual(symbols.count, 2)
        var finalPhysicalOffsets: [CGFloat] = []
        for symbol in symbols {
            let halfWidth: CGFloat = symbol is NotchEyesLayer ? 10 : 8
            let positionAnimation = try XCTUnwrap(
                symbol.animation(forKey: "position") as? CAKeyframeAnimation
            )
            let opacityAnimation = try XCTUnwrap(
                symbol.animation(forKey: "opacity") as? CAKeyframeAnimation
            )
            let positions = try XCTUnwrap(positionAnimation.values as? [NSValue])
            let opacities = try XCTUnwrap(opacityAnimation.values as? [NSNumber])
            let opacityTimes = try XCTUnwrap(opacityAnimation.keyTimes)
            XCTAssertEqual(positionAnimation.keyTimes, opacityTimes)
            XCTAssertEqual(positionAnimation.duration, opacityAnimation.duration)
            XCTAssertEqual(opacityTimes, keyTimes)
            XCTAssertEqual(positions.count, keyTimes.count)
            XCTAssertEqual(opacities.count, keyTimes.count)
            guard positions.count == keyTimes.count, opacities.count == keyTimes.count else { continue }

            // The parent scales the positions, while the symbols counter-scale
            // their contents to retain each symbol's physical half-width.
            let physicalDisplacements = zip(positions, scales).map { position, scale in
                abs((position.pointValue.x - view.bounds.midX) * scale.width)
            }
            let finalPosition = try XCTUnwrap(positions.last).pointValue
            let finalScale = try XCTUnwrap(scales.last)
            finalPhysicalOffsets.append((finalPosition.x - view.bounds.midX) * finalScale.width)
            let firstClearIndex = try XCTUnwrap(positions.indices.first { index in
                physicalDisplacements[index] - halfWidth >= view.cameraWidth / 2
            })
            XCTAssertEqual(try XCTUnwrap(opacities.first).doubleValue, 0, accuracy: 0.0001)
            XCTAssertEqual(try XCTUnwrap(opacities.last).doubleValue, 1, accuracy: 0.0001)
            XCTAssertLessThanOrEqual(opacities[firstClearIndex].doubleValue, 0.1,
                                     "Symbols must emerge nearly transparent from the physical camera")
            for (previous, current) in zip(opacities, opacities.dropFirst()) {
                XCTAssertGreaterThanOrEqual(current.doubleValue, previous.doubleValue,
                                            "The visible reveal must fade in without reversing")
            }
            for (previous, current) in zip(physicalDisplacements, physicalDisplacements.dropFirst()) {
                XCTAssertGreaterThanOrEqual(current, previous,
                                            "The closing symbols must move outward without retreating")
            }

            let firstVisibleIndex = try XCTUnwrap(opacities.indices.first {
                opacities[$0].doubleValue >= 0.1
            })
            let mostlyVisibleIndex = try XCTUnwrap(opacities.indices.first {
                opacities[$0].doubleValue >= 0.9
            })
            XCTAssertGreaterThanOrEqual(physicalDisplacements[mostlyVisibleIndex]
                - physicalDisplacements[firstVisibleIndex], 8,
                "The symbols must visibly move outward while fading from ten to ninety percent opacity")

            for index in firstVisibleIndex..<positions.count {
                let bodyHalfWidth = view.bounds.width * scales[index].width / 2
                    - NotchSurfaceView.shoulderWidth
                XCTAssertLessThanOrEqual(physicalDisplacements[index] + halfWidth, bodyHalfWidth,
                                         "The visible symbols must fit inside the wings while the narrow notch widens")
            }

            let visibleIntermediateSamples = opacities[firstClearIndex...].filter {
                $0.doubleValue > 0.1 && $0.doubleValue < 0.9
            }
            XCTAssertGreaterThanOrEqual(visibleIntermediateSamples.count, 4,
                                        "Several intermediate alpha levels must remain visible outside the camera")
            let fullyOpaqueIndex = try XCTUnwrap(opacities.indices.first { index in
                index >= firstClearIndex && opacities[index].doubleValue >= 1
            })
            let visibleFadeDuration = (opacityTimes[fullyOpaqueIndex].doubleValue
                - opacityTimes[firstClearIndex].doubleValue) * opacityAnimation.duration
            XCTAssertGreaterThanOrEqual(visibleFadeDuration, 0.18,
                                        "The fade must remain perceptible after the symbols clear the camera")
        }
        let shoulder = view.compactSize.height * 0.46
        let slotCenterOffset = (view.cameraWidth / 2 + view.compactSize.width / 2 - shoulder) / 2
        finalPhysicalOffsets.sort()
        XCTAssertEqual(try XCTUnwrap(finalPhysicalOffsets.first), -slotCenterOffset, accuracy: 0.0001,
                       "The left symbol must finish at its static compact slot center")
        XCTAssertEqual(try XCTUnwrap(finalPhysicalOffsets.last), slotCenterOffset, accuracy: 0.0001,
                       "The right symbol must finish at its static compact slot center")
    }
}
