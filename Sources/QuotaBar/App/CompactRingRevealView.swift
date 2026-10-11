import AppKit
import QuartzCore

@MainActor
final class CompactRingRevealView: NSView {
    var cameraWidth: CGFloat = 0
    var compactSize = NSSize(width: 297, height: 32)
    var remainingPercent: Int? {
        didSet { updateRingContents() }
    }

    private let ringLayer = CALayer()
    private let iconLayer = NotchEyesLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayer()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func configureLayer() {
        wantsLayer = true
        for symbolLayer in [ringLayer, iconLayer] {
            symbolLayer.bounds = CGRect(x: 0, y: 0, width: 16, height: 16)
            symbolLayer.contentsScale = 2
            symbolLayer.opacity = 0
            layer?.addSublayer(symbolLayer)
        }
        updateRingContents()
    }

    private func updateRingContents() {
        updateContents(of: ringLayer) { context in
            QuotaRingDrawing.draw(in: context, center: CGPoint(x: 8, y: 8),
                                  remainingPercent: remainingPercent)
        }
    }

    private func updateContents(of symbolLayer: CALayer, draw: (CGContext) -> Void) {
        guard let context = CGContext(data: nil, width: 32, height: 32,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.scaleBy(x: 2, y: 2)
        draw(context)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        symbolLayer.contents = context.makeImage()
        CATransaction.commit()
    }

    func animate(scales: [NSSize], keyTimes: [NSNumber], duration: TimeInterval, presented: Bool) {
        resetAnimation()
        let compactHeight = compactSize.height
        guard !presented, cameraWidth > 0, compactHeight > 0,
              bounds.width > 0, bounds.height > compactHeight,
              duration > 0, scales.count > 1, scales.count == keyTimes.count,
              scales.allSatisfy({ $0.width > 0 && $0.height > 0
                  && $0.width.isFinite && $0.height.isFinite }) else { return }

        let compactRadius = compactHeight * 0.46
        let restingOffset = (cameraWidth / 2 + compactSize.width / 2 - compactRadius) / 2
        let cameraClearOffset = min(restingOffset, cameraWidth / 2 + 8)
        let eyesClearOffset = min(restingOffset, cameraWidth / 2 + 10)
        var ringPositions: [NSValue] = []
        var iconPositions: [NSValue] = []
        var transforms: [NSValue] = []
        var opacities: [NSNumber] = []
        for (scale, time) in zip(scales, keyTimes) {
            let hidden = min(1, max(0, (time.doubleValue - 0.30) / 0.14))
            let reveal = min(1, max(0, (time.doubleValue - 0.44) / 0.56))
            let revealProgress = reveal * reveal * (3 - 2 * reveal)
            // Reach the camera edge while hidden, then use ONE progress for
            // both the visible outward slide and the full 0-to-1 fade.
            let offset = cameraClearOffset * CGFloat(hidden * hidden * (3 - 2 * hidden))
                + (restingOffset - cameraClearOffset) * CGFloat(revealProgress)
            let eyeOffset = eyesClearOffset * CGFloat(hidden * hidden * (3 - 2 * hidden))
                + (restingOffset - eyesClearOffset) * CGFloat(revealProgress)
            let travelX = offset / scale.width
            let positionY = bounds.maxY - compactHeight / 2 / scale.height
            ringPositions.append(NSValue(point: CGPoint(x: bounds.midX + travelX, y: positionY)))
            iconPositions.append(NSValue(point: CGPoint(x: bounds.midX - eyeOffset / scale.width, y: positionY)))
            transforms.append(NSValue(caTransform3D: CATransform3DMakeScale(1 / scale.width, 1 / scale.height, 1)))
            opacities.append(NSNumber(value: revealProgress))
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ringLayer.position = ringPositions.last!.pointValue
        iconLayer.position = iconPositions.last!.pointValue
        for symbolLayer in [ringLayer, iconLayer] {
            symbolLayer.transform = transforms.last!.caTransform3DValue
            symbolLayer.opacity = 1
        }
        for (symbolLayer, positions) in [(ringLayer, ringPositions), (iconLayer, iconPositions)] {
            let values: [(String, [Any])] = [
                ("position", positions), ("transform", transforms), ("opacity", opacities)
            ]
            for (keyPath, samples) in values {
                let animation = CAKeyframeAnimation(keyPath: keyPath)
                animation.values = samples
                animation.keyTimes = keyTimes
                animation.duration = duration
                animation.calculationMode = .linear
                animation.timingFunction = CAMediaTimingFunction(name: .linear)
                animation.fillMode = .forwards
                animation.isRemovedOnCompletion = false
                symbolLayer.add(animation, forKey: keyPath)
            }
        }
        // Publish the final model values and explicit animations atomically,
        // so no frame can expose the fully opaque model before the fade starts.
        CATransaction.commit()
    }

    func resetAnimation() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for symbolLayer in [ringLayer, iconLayer] {
            symbolLayer.removeAllAnimations()
            symbolLayer.opacity = 0
        }
        CATransaction.commit()
    }
}
