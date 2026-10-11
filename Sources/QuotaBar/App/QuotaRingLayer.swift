import AppKit
import QuartzCore

/// Keeps real quota data in the model while temporary expressions run in presentation layers.
final class QuotaRingLayer: CALayer {
    private static let responseKey = "quotaResponse"
    private static let resetKey = "quotaResponseReset"
    private let glyph = CALayer()
    private let halo = CAShapeLayer()
    private var sparks: [CAShapeLayer] = []
    private var renderedDiameter: CGFloat?
    private var renderedPercent: Int?
    private var isCharging = false

    override init() {
        super.init()
        contentsScale = 2
        anchorPoint = CGPoint(x: 0.5, y: 0.5)
        glyph.name = "quotaGlyph"
        glyph.contentsScale = 2
        addSublayer(glyph)
        halo.name = "quotaBurstHalo"
        halo.contentsScale = 2
        halo.fillColor = nil
        halo.strokeColor = NSColor.white.cgColor
        halo.lineWidth = 0.8
        halo.opacity = 0
        addSublayer(halo)
        for index in 0..<8 {
            let spark = CAShapeLayer()
            spark.name = "quotaBurstSpark\(index)"
            spark.contentsScale = 2
            spark.fillColor = nil
            spark.strokeColor = NSColor.white.cgColor
            spark.lineWidth = 1.2
            spark.lineCap = .round
            spark.opacity = 0
            sparks.append(spark)
            addSublayer(spark)
        }
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    func update(diameter: CGFloat, remainingPercent: Int?) {
        guard renderedDiameter != diameter || renderedPercent != remainingPercent else { return }
        let sizeChanged = renderedDiameter != diameter
        renderedDiameter = diameter
        renderedPercent = remainingPercent
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard diameter.isFinite, diameter > 0 else {
            resetResponse(animated: false)
            bounds = .zero
            glyph.contents = nil
            return
        }
        if sizeChanged {
            resetResponse(animated: false)
            bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            glyph.frame = bounds
            halo.frame = bounds
            let center = CGPoint(x: diameter / 2, y: diameter / 2)
            let radius = (diameter - 2) / 2
            halo.path = CGPath(ellipseIn: CGRect(x: 1, y: 1, width: diameter - 2, height: diameter - 2), transform: nil)
            for (index, spark) in sparks.enumerated() {
                spark.frame = bounds
                let angle = CGFloat(index) * .pi / 4
                let path = CGMutablePath()
                path.move(to: CGPoint(x: center.x + cos(angle) * radius,
                                      y: center.y + sin(angle) * radius))
                path.addLine(to: CGPoint(x: center.x + cos(angle) * (radius + 1.8),
                                        y: center.y + sin(angle) * (radius + 1.8)))
                spark.path = path
            }
        }
        // Never replace the true quota with the playful, temporary 100% value.
        glyph.contents = image(percent: remainingPercent)
    }

    func respond() {
        resetResponse(animated: false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glyph.add(keyframes("transform.scale", values: [1, 1.14, 0.985, 1.025, 1],
                            times: [0, 0.32, 0.60, 0.80, 1], duration: 0.72), forKey: Self.responseKey)
        CATransaction.commit()
    }

    /// Fill first, then hold at 100% until the eyes explicitly trigger burst().
    func charge() {
        let visibleContents = glyph.presentation()?.contents ?? glyph.contents
        let visibleScale = glyph.presentation()?.transform.m11 ?? glyph.transform.m11
        resetResponse(animated: false)
        guard renderedDiameter != nil, glyph.contents != nil else { return }
        isCharging = true
        let initial = max(0, min(100, renderedPercent ?? 0))
        let fill = CAKeyframeAnimation(keyPath: "contents")
        fill.values = (0...42).compactMap { step -> CGImage? in
            if step == 0, let visibleContents { return (visibleContents as! CGImage) }
            return image(percent: initial + Int((Double(100 - initial) * Double(step) / 42).rounded()))
        }
        fill.duration = 0.70
        fill.calculationMode = .discrete
        fill.fillMode = .forwards
        fill.isRemovedOnCompletion = false
        glyph.add(fill, forKey: "quotaChargeFill")
        let swelling = keyframes("transform.scale", values: [visibleScale, 1.04, 1.18],
                                 times: [0, 0.32, 1], duration: 0.70)
        swelling.fillMode = .forwards
        swelling.isRemovedOnCompletion = false
        glyph.add(swelling, forKey: "quotaChargeScale")
    }

    func burst() {
        guard isCharging else { return }
        isCharging = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glyph.removeAllAnimations()
        // Hold the full image only while it disappears. The reappearing ring reads
        // model contents, including quota refreshes that arrive during the burst.
        if let full = image(percent: 100) {
            let flash = CABasicAnimation(keyPath: "contents")
            flash.fromValue = full
            flash.toValue = full
            flash.duration = 0.12
            glyph.add(flash, forKey: "quotaBurstFull")
        }
        glyph.add(keyframes("transform.scale", values: [1.18, 1.30, 0.84, 1.06, 1],
                            times: [0, 0.12, 0.62, 0.83, 1], duration: 0.98), forKey: "quotaBurstScale")
        glyph.add(keyframes("opacity", values: [1, 0, 0, 1, 1],
                            times: [0, 0.12, 0.40, 0.74, 1], duration: 0.98), forKey: "quotaBurstOpacity")
        halo.add(keyframes("opacity", values: [0, 0.65, 0], times: [0, 0.08, 1], duration: 0.40),
                 forKey: "quotaBurstOpacity")
        halo.add(keyframes("transform.scale", values: [1.12, 1.72], times: [0, 1], duration: 0.40),
                 forKey: "quotaBurstScale")
        for (index, spark) in sparks.enumerated() {
            let angle = CGFloat(index) * .pi / 4
            let travel = CABasicAnimation(keyPath: "transform.translation")
            travel.fromValue = NSValue(point: .zero)
            travel.toValue = NSValue(point: CGPoint(x: cos(angle) * 4, y: sin(angle) * 4))
            travel.duration = 0.52
            travel.timingFunction = CAMediaTimingFunction(name: .easeOut)
            spark.add(travel, forKey: "quotaBurstTravel")
            spark.add(keyframes("opacity", values: [0, 1, 0.85, 0],
                                times: [0, 0.08, 0.30, 1], duration: 0.52), forKey: "quotaBurstOpacity")
        }
        CATransaction.commit()
    }

    func resetResponse(animated: Bool) {
        isCharging = false
        let current = glyph.presentation() ?? glyph
        let currentTransform = current.transform
        let currentOpacity = current.opacity
        let currentContents = current.contents
        let effects = [halo] + sparks
        let effectOpacities = effects.map { ($0.presentation() ?? $0).opacity }
        let effectTransforms = effects.map { ($0.presentation() ?? $0).transform }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        removeAllAnimations()
        transform = CATransform3DIdentity
        glyph.removeAllAnimations()
        glyph.transform = CATransform3DIdentity
        glyph.opacity = 1
        for (index, effect) in effects.enumerated() {
            effect.removeAllAnimations()
            effect.transform = CATransform3DIdentity
            effect.opacity = 0
            if animated, effectOpacities[index] > 0 {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = effectOpacities[index]
                fade.toValue = 0
                fade.duration = 0.18
                effect.add(fade, forKey: Self.resetKey)
                let settle = CABasicAnimation(keyPath: "transform")
                settle.fromValue = NSValue(caTransform3D: effectTransforms[index])
                settle.toValue = NSValue(caTransform3D: effectTransforms[index])
                settle.duration = 0.18
                effect.add(settle, forKey: "quotaEffectResetPosition")
            }
        }
        if animated {
            if !CATransform3DIsIdentity(currentTransform) {
                let animation = CABasicAnimation(keyPath: "transform")
                animation.fromValue = NSValue(caTransform3D: currentTransform)
                animation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
                animation.duration = 0.18
                animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                glyph.add(animation, forKey: Self.resetKey)
            }
            let opacity = CABasicAnimation(keyPath: "opacity")
            opacity.fromValue = currentOpacity
            opacity.toValue = 1
            opacity.duration = 0.18
            glyph.add(opacity, forKey: "quotaResetOpacity")
            if let currentContents, let actualContents = glyph.contents {
                let dissolve = CABasicAnimation(keyPath: "contents")
                dissolve.fromValue = currentContents
                dissolve.toValue = actualContents
                dissolve.duration = 0.18
                glyph.add(dissolve, forKey: "quotaResetFill")
            }
        }
        CATransaction.commit()
    }

    private func keyframes(_ keyPath: String, values: [CGFloat], times: [NSNumber], duration: Double) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = times
        animation.duration = duration
        animation.calculationMode = .linear
        animation.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: values.count - 1)
        return animation
    }

    private func image(percent: Int?) -> CGImage? {
        guard let diameter = renderedDiameter, diameter.isFinite, diameter > 0 else { return nil }
        let pixels = Int(ceil(diameter * contentsScale))
        guard let context = CGContext(data: nil, width: pixels, height: pixels,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let scale = CGFloat(pixels) / diameter
        context.scaleBy(x: scale, y: scale)
        QuotaRingDrawing.draw(in: context, center: CGPoint(x: diameter / 2, y: diameter / 2),
                              diameter: diameter, remainingPercent: percent)
        return context.makeImage()
    }
}
