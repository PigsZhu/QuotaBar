import AppKit
import QuartzCore

/// An unmasked sibling keeps the shadow outside the morphing glass contour.
@MainActor
final class NotchShadowView: NSView {
    private let restingOpacity: Float = 0.25
    // Approximate Figma's 32pt blur with Core Animation's softer radius scale.
    private let restingRadius: CGFloat = 16
    // AppKit's unflipped coordinate system makes a downward offset negative.
    private let restingOffset: CGFloat = -12

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
        layer?.shadowColor = NSColor.black.cgColor
        layer?.masksToBounds = false
    }

    func updateContour(_ path: CGPath) {
        guard let layer, layer.animation(forKey: "shadowPath") == nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.shadowPath = path
        layer.shadowOpacity = restingOpacity
        layer.shadowRadius = restingRadius
        layer.shadowOffset = CGSize(width: 0, height: restingOffset)
        CATransaction.commit()
    }

    func animate(contours: [CGPath], scales: [NSSize], keyTimes: [NSNumber],
                 duration: TimeInterval, presented: Bool) {
        guard let layer, !contours.isEmpty,
              contours.count == scales.count, scales.count == keyTimes.count else { return }
        let continuing = layer.animation(forKey: "shadowPath") != nil
        let live = layer.presentation() ?? layer
        let startOpacity = continuing ? live.shadowOpacity : (presented ? 0 : restingOpacity)
        let startRadius = continuing ? live.shadowRadius : (presented ? 0 : restingRadius)
        let startOffset = continuing ? live.shadowOffset.height : (presented ? 0 : restingOffset)
        let currentPath = continuing ? live.shadowPath : nil
        let targetOpacity: Float = presented ? restingOpacity : 0
        let targetRadius: CGFloat = presented ? restingRadius : 0
        let targetOffset: CGFloat = presented ? restingOffset : 0
        var paths = zip(contours, scales).map { path, scale in
            // Scale the contour about the same top-center anchor as the glass,
            // leaving the blur circular in screen points.
            var transform = CGAffineTransform(a: scale.width, b: 0, c: 0, d: scale.height,
                tx: bounds.midX * (1 - scale.width), ty: bounds.maxY * (1 - scale.height))
            return path.copy(using: &transform) ?? path
        }
        if let currentPath { paths[0] = currentPath }
        let progress = keyTimes.map { time -> CGFloat in
            // Fade with the main collapse, before the compact-width rebound;
            // the height swell must not bring the shadow back.
            let t = min(1, max(0, CGFloat(time.doubleValue) / 0.4))
            return t * t * (3 - 2 * t)
        }
        let opacities = progress.map { startOpacity + (targetOpacity - startOpacity) * Float($0) }
        let radii = progress.map { startRadius + (targetRadius - startRadius) * $0 }
        let offsets = progress.map {
            NSValue(size: NSSize(width: 0, height: startOffset + (targetOffset - startOffset) * $0))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.shadowPath = paths.last
        layer.shadowOpacity = targetOpacity
        layer.shadowRadius = targetRadius
        layer.shadowOffset = CGSize(width: 0, height: targetOffset)
        let tracks: [(String, [Any])] = [
            ("shadowPath", paths), ("shadowOpacity", opacities),
            ("shadowRadius", radii), ("shadowOffset", offsets)
        ]
        for (keyPath, samples) in tracks {
            let animation = CAKeyframeAnimation(keyPath: keyPath)
            animation.values = samples
            animation.keyTimes = keyTimes
            animation.duration = duration
            animation.calculationMode = .linear
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
            layer.add(animation, forKey: keyPath)
        }
        CATransaction.commit()
    }

    func resetAnimation() {
        layer?.removeAllAnimations()
    }
}
