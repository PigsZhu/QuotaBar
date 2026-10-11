import AppKit
import QuartzCore

/// A soft radial bloom anchored once per glare, independently of later eye motion.
final class NotchAngerGlowLayer: CALayer {
    private let bloom = CAGradientLayer()
    private let releaseWave = CAGradientLayer()
    private let edgeMask = CAGradientLayer()
    private let verticalMask = CAGradientLayer()
    private var targetAnger: Double = 0
    private var expanded = false
    private var released = false
    private var originInHost = CGPoint.zero
    private var releaseOriginInHost = CGPoint.zero
    private static let initialScale: CGFloat = 0.15
    private static let expansionDuration: Double = 0.46
    static let releaseDuration: Double = 0.40

    override init() {
        super.init()
        opacity = 0
        masksToBounds = true
        let coral = NSColor(srgbRed: 1, green: 0.38, blue: 0.34, alpha: 1)
        // A continuous falloff, without a solid disc or a visible outer ring.
        let stops = (0...32).map { Double($0) / 32 }
        bloom.type = .radial
        bloom.startPoint = CGPoint(x: 0.5, y: 0.5)
        bloom.endPoint = CGPoint(x: 1, y: 1)
        bloom.locations = stops.map { NSNumber(value: $0) }
        bloom.colors = stops.map { radius in
            let fade = max(0, (exp(-5 * radius * radius) - exp(-5)) / (1 - exp(-5)))
            return coral.withAlphaComponent(fade).cgColor
        }
        bloom.transform = CATransform3DMakeScale(Self.initialScale, Self.initialScale, 1)
        addSublayer(bloom)
        releaseWave.name = "angerReleaseWave"
        releaseWave.type = .radial
        releaseWave.startPoint = CGPoint(x: 0.5, y: 0.5)
        releaseWave.endPoint = CGPoint(x: 1, y: 1)
        // A broad annulus with transparent center and edges. Dense stops keep
        // the outward pulse soft even within the small left wing.
        let waveStops = (0...64).map { Double($0) / 64 }
        releaseWave.locations = waveStops.map { NSNumber(value: $0) }
        releaseWave.colors = waveStops.map { radius in
            let distance = (radius - 0.50) / 0.18
            let envelope = pow(sin(.pi * radius), 2)
            let alpha = radius == 0 || radius == 1 ? 0 : exp(-0.5 * distance * distance) * envelope
            return coral.withAlphaComponent(alpha).cgColor
        }
        releaseWave.opacity = 0
        addSublayer(releaseWave)
        // The bloom may be wider than the wing. Fade to clear before clipping,
        // including a transparent camera-side tail, so the crop never reads as a box.
        edgeMask.colors = [0.0, 1, 1, 0, 0].map { NSColor.black.withAlphaComponent($0).cgColor }
        edgeMask.locations = [0, 0.24, 0.66, 0.97, 1]
        edgeMask.startPoint = CGPoint(x: 0, y: 0.5)
        edgeMask.endPoint = CGPoint(x: 1, y: 0.5)
        verticalMask.colors = [0.0, 0.5, 1, 0.5, 0].map { NSColor.black.withAlphaComponent($0).cgColor }
        verticalMask.locations = [0, 0.22, 0.5, 0.78, 1]
        verticalMask.startPoint = CGPoint(x: 0.5, y: 0)
        verticalMask.endPoint = CGPoint(x: 0.5, y: 1)
        edgeMask.mask = verticalMask
        mask = edgeMask
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    func updateFrame(_ rect: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame = rect
        edgeMask.frame = bounds
        verticalMask.frame = edgeMask.bounds
        let diameter = max(rect.width * 1.5, rect.height * 2)
        bloom.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        releaseWave.bounds = bloom.bounds
        updateOrigin()
        CATransaction.commit()
    }

    func update(anger: Double, duration: Double, origin: CGPoint) {
        let amount = max(0, min(1, anger))
        let visibleOpacity = presentation()?.opacity ?? opacity
        let visibleScale = bloom.presentation()?.transform.m11 ?? bloom.transform.m11
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        if duration <= 0 {
            removeAllAnimations()
            bloom.removeAllAnimations()
            releaseWave.removeAllAnimations()
            releaseWave.opacity = 0
            releaseWave.transform = CATransform3DIdentity
            bloom.opacity = 1
            released = false
            opacity = Float(amount * 0.18)
            expanded = amount >= 1
            let scale = expanded ? 1 : Self.initialScale
            bloom.transform = CATransform3DMakeScale(scale, scale, 1)
            originInHost = origin
            updateOrigin()
            targetAnger = amount
            return
        }
        // The turn consumes this glare's light. Later away/recovery poses must
        // not light it again; only reaching neutral rearms the next cycle.
        if released {
            targetAnger = amount
            if amount == 0 {
                removeAllAnimations()
                bloom.removeAllAnimations()
                releaseWave.removeAllAnimations()
                opacity = 0
                releaseWave.opacity = 0
                releaseWave.transform = CATransform3DIdentity
                bloom.opacity = 1
                bloom.transform = CATransform3DMakeScale(Self.initialScale, Self.initialScale, 1)
                expanded = false
                released = false
            }
            return
        }
        // Every pose in the angry turn reports the same anger value. Keeping
        // this transition edge-triggered also preserves its original start time.
        guard amount != targetAnger else { return }
        let startsExpansion = amount >= 1 && targetAnger < 1
        if startsExpansion {
            originInHost = origin
            updateOrigin()
            let startScale = expanded && visibleOpacity > 0.001 ? visibleScale : Self.initialScale
            bloom.transform = CATransform3DIdentity
            let expansion = CABasicAnimation(keyPath: "transform.scale")
            expansion.fromValue = startScale
            expansion.toValue = 1
            expansion.duration = Self.expansionDuration
            expansion.timingFunction = CAMediaTimingFunction(name: .easeOut)
            bloom.add(expansion, forKey: "angerExpansion")
            expanded = true
        } else if amount > 0 && targetAnger == 0 && visibleOpacity < 0.001 {
            // Prepare the next small warm glow only after the old one is dark.
            bloom.removeAnimation(forKey: "angerExpansion")
            bloom.transform = CATransform3DMakeScale(Self.initialScale, Self.initialScale, 1)
            expanded = false
            originInHost = origin
            updateOrigin()
        }
        targetAnger = amount
        opacity = Float(amount * 0.18)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = visibleOpacity
        fade.toValue = opacity
        fade.duration = startsExpansion ? Self.expansionDuration : duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        add(fade, forKey: "anger")
        // Recovery changes only opacity: the currently expanded light never
        // visibly collapses back into a point, even if the glare is interrupted.
    }

    func release(origin: CGPoint) {
        guard !released, targetAnger > 0 else { return }
        let visibleOpacity = presentation()?.opacity ?? opacity
        let liveBloom = bloom.presentation() ?? bloom
        let visibleBloomOpacity = liveBloom.opacity
        let visibleBloomTransform = liveBloom.transform
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        released = true
        releaseOriginInHost = origin
        updateOrigin()
        removeAllAnimations()
        bloom.removeAllAnimations()
        releaseWave.removeAllAnimations()
        // The model is already completely dark, so cancellation and normal
        // animation completion cannot leave a red patch behind.
        opacity = 0
        bloom.opacity = 0
        bloom.transform = visibleBloomTransform
        releaseWave.opacity = 0
        releaseWave.transform = CATransform3DMakeScale(1.15, 1.15, 1)

        let brightness = CAKeyframeAnimation(keyPath: "opacity")
        brightness.values = [visibleOpacity, Float(0.74), Float(0.64), Float(0)]
        brightness.keyTimes = [0, 0.20, 0.48, 1]
        brightness.duration = Self.releaseDuration
        brightness.calculationMode = .linear
        add(brightness, forKey: "angerRelease")

        let bloomFade = CABasicAnimation(keyPath: "opacity")
        bloomFade.fromValue = visibleBloomOpacity
        bloomFade.toValue = 0
        bloomFade.duration = 0.07
        bloom.add(bloomFade, forKey: "angerReleaseFade")

        let expansion = CABasicAnimation(keyPath: "transform.scale")
        expansion.fromValue = 0.16
        expansion.toValue = 1.15
        expansion.duration = Self.releaseDuration
        expansion.timingFunction = CAMediaTimingFunction(name: .easeOut)
        releaseWave.add(expansion, forKey: "angerReleaseExpansion")

        let waveFade = CAKeyframeAnimation(keyPath: "opacity")
        waveFade.values = [0, 1, 1, 0]
        waveFade.keyTimes = [0, 0.16, 0.52, 1]
        waveFade.duration = Self.releaseDuration
        waveFade.calculationMode = .linear
        releaseWave.add(waveFade, forKey: "angerReleaseFade")
    }

    private func updateOrigin() {
        bloom.position = CGPoint(x: originInHost.x - frame.minX, y: originInHost.y - frame.minY)
        releaseWave.position = CGPoint(x: releaseOriginInHost.x - frame.minX,
                                       y: releaseOriginInHost.y - frame.minY)
    }
}
