import AppKit
import QuartzCore

/// Morphs the live glass between the status-item capsule and the full panel,
/// while letting the information resolve a beat after the glass surface.
@MainActor
final class PanelPresentationAnimator {
    var onCompletion: ((Bool) -> Void)?
    var onWillFinishClosing: (() -> Void)?
    var onSurfaceScaleAnimation: (([CGFloat], [NSNumber], TimeInterval) -> Void)?
    var onCompactRingAnimation: (([NSSize], [NSNumber], TimeInterval, Bool) -> Void)?
    var onSurfaceReset: (() -> Void)?
    var compactSize = NSSize(width: 168, height: 30)
    var cameraWidth: CGFloat = 0

    private let panel: NSPanel
    private let animatedContentView: NSView
    private let surfaceView: NSView?
    private let reduceMotion: () -> Bool
    private var revision = 0
    private(set) var isPresented = false
    private let morphKey = "QuotaBar.presentationMorph"
    private let contentKey = "QuotaBar.presentationContent"
    private let scaleKey = "QuotaBar.surfaceScale"
    private static let closingDuration: TimeInterval = 0.54
    private static let closingCollapseEnd: CGFloat = 0.40
    private static let closingResponseStart: CGFloat = 0.36
    private static let closingWidthPeak: CGFloat = 0.79

    init(panel: NSPanel, contentView: NSView? = nil, surfaceView: NSView? = nil, reduceMotion: @escaping () -> Bool = {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }) {
        self.panel = panel
        self.surfaceView = surfaceView
        self.animatedContentView = contentView ?? panel.contentView ?? NSView()
        self.reduceMotion = reduceMotion
        panel.animationBehavior = .none
        panel.contentView?.wantsLayer = true
        animatedContentView.wantsLayer = true
    }

    func setPresented(_ presented: Bool, anchorX: CGFloat) {
        guard presented != isPresented else { return }
        isPresented = presented
        revision += 1
        let currentRevision = revision
        let reduceMotion = reduceMotion()
        let duration = reduceMotion ? 0.12 : (presented ? 0.60 : Self.closingDuration)
        let timing = CAMediaTimingFunction(name: presented ? .easeOut : .easeIn)

        if presented && !panel.isVisible {
            panel.alphaValue = 0
            setContentOpacity(0)
        }
        panel.ignoresMouseEvents = !presented
        if presented { panel.makeKeyAndOrderFront(nil) }

        if reduceMotion {
            clearMorphMask()
            animateContent(to: presented ? 1 : 0, duration: duration, delay: 0, timing: timing)
        } else {
            animateMorph(presented: presented, anchorX: anchorX, duration: duration)
            // Match the reference: glass forms first, then information resolves.
            animateContent(
                to: presented ? 1 : 0,
                duration: presented ? 0.22 : 0.09,
                delay: presented ? 0.12 : 0,
                timing: timing
            )
        }

        // The live surface stays opaque while shrinking back into the notch.
        // Reduced Motion retains its fade-only transition.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? duration : (presented ? 0.04 : 0)
            context.timingFunction = timing
            panel.animator().alphaValue = presented || !reduceMotion ? 1 : 0
        }

        // The opening window fade is intentionally shorter than the shape
        // morph. Finalize only after the morph itself finishes; otherwise the
        // mask would disappear halfway through the elastic expansion.
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            Task { @MainActor in
                guard let self, self.revision == currentRevision else { return }
                if !presented {
                    // Install the identical compact silhouette before hiding
                    // this window or clearing its final contour and gradient.
                    self.onWillFinishClosing?()
                    self.panel.orderOut(nil)
                    self.panel.alphaValue = 1
                    self.panel.ignoresMouseEvents = false
                }
                self.clearMorphMask()
                self.animatedContentView.layer?.removeAnimation(forKey: self.contentKey)
                self.setContentOpacity(1)
                self.onCompletion?(presented)
            }
        }
    }

    func stopImmediately() {
        revision += 1
        isPresented = false
        panel.orderOut(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1
        }
        clearMorphMask()
        animatedContentView.layer?.removeAnimation(forKey: contentKey)
        setContentOpacity(1)
        panel.ignoresMouseEvents = false
    }

    private func animateMorph(presented: Bool, anchorX: CGFloat, duration: TimeInterval) {
        if let surfaceView {
            animateSurface(surfaceView, presented: presented, duration: duration)
            return
        }
        guard let rootLayer = panel.contentView?.layer else { return }
        let bounds = rootLayer.bounds
        let collapsedWidth = compactSize.width
        let collapsedHeight = compactSize.height
        let x = min(max(anchorX, collapsedWidth / 2), bounds.width - collapsedWidth / 2)
        let top = panel.contentView?.isFlipped == true ? bounds.minY : bounds.maxY
        let collapsedRect = CGRect(
            x: x - collapsedWidth / 2,
            y: top - collapsedHeight,
            width: collapsedWidth,
            height: collapsedHeight
        )
        let fullPath = NotchGeometry.path(in: bounds, notch: false)
        let collapsedPath = NotchGeometry.path(in: collapsedRect, notch: true, radius: collapsedHeight * 0.46)

        let mask: CAShapeLayer
        let startPath: CGPath
        if let existing = rootLayer.mask as? CAShapeLayer {
            mask = existing
            startPath = existing.presentation()?.path ?? existing.path ?? (presented ? collapsedPath : fullPath)
            mask.removeAnimation(forKey: morphKey)
        } else {
            mask = CAShapeLayer()
            mask.frame = bounds
            rootLayer.mask = mask
            startPath = presented ? collapsedPath : fullPath
        }
        let targetPath = presented ? fullPath : collapsedPath
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.path = targetPath
        CATransaction.commit()

        // One continuous transition; no extra shrink/stretch keyframe after
        // reaching the expanded shape. The user's curve owns the easing.
        let animation = CABasicAnimation(keyPath: "path")
        animation.fromValue = startPath
        animation.toValue = targetPath
        animation.timingFunction = presented
            ? CAMediaTimingFunction(controlPoints: 0.45, 1.45, 0.8, 1)
            : CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
        animation.duration = duration
        mask.add(animation, forKey: morphKey)
    }

    private func animateContent(to opacity: Float, duration: TimeInterval, delay: TimeInterval,
                                timing: CAMediaTimingFunction) {
        guard let layer = animatedContentView.layer else { return }
        let start = layer.presentation()?.opacity ?? layer.opacity
        layer.removeAnimation(forKey: contentKey)
        setContentOpacity(opacity)

        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = start
        animation.toValue = opacity
        animation.beginTime = CACurrentMediaTime() + delay
        animation.duration = duration
        animation.fillMode = .backwards
        animation.timingFunction = timing
        layer.add(animation, forKey: contentKey)
    }

    private func clearMorphMask() {
        surfaceView?.layer?.removeAnimation(forKey: scaleKey)
        (surfaceView as? NotchSurfaceView)?.resetContour()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surfaceView?.layer?.transform = CATransform3DIdentity
        CATransaction.commit()
        panel.contentView?.layer?.mask?.removeAnimation(forKey: morphKey)
        panel.contentView?.layer?.mask = nil
        onSurfaceReset?()
    }

    private func animateSurface(_ surface: NSView, presented: Bool, duration: TimeInterval) {
        panel.contentView?.layoutSubtreeIfNeeded()
        guard let layer = surface.layer else { return }
        let bounds = layer.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let anchor = layer.anchorPoint
        let compact = topAnchoredScale(x: compactSize.width / bounds.width,
                                       y: compactSize.height / bounds.height,
                                       bounds: bounds, anchor: anchor)
        let current = layer.presentation()?.transform
        let start = layer.animation(forKey: scaleKey) != nil
            ? (current ?? layer.transform) : (presented ? compact : CATransform3DIdentity)
        layer.removeAnimation(forKey: scaleKey)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // AppKit owns this view's backing-layer anchor and position. Changing
        // them here is undone by later layout, moving the scale origin to the
        // lower-left. Encode the top-center pivot in the transform instead.
        layer.transform = presented ? CATransform3DIdentity : compact
        CATransaction.commit()

        let target = presented ? CATransform3DIdentity : compact
        // Leave the full camera footprint covered even at the inward-curving
        // bottom corners. The two symbols emerge as these narrow wings grow.
        let cameraMinimumWidth = cameraWidth > 0
            ? cameraWidth + 4 * max(compactSize.height * 0.46, NotchSurfaceView.shoulderWidth)
            : 0
        let narrowWidth = min(compactSize.width, max(compactSize.width * 0.84, cameraMinimumWidth))
        let narrowScaleX = narrowWidth / bounds.width
        // Keep every CSS linear() breakpoint, plus dense samples for the
        // inverse-scaled contour and camera gradient. All layers share timing.
        let regularTimes = (0...80).map { CGFloat($0) / 80 }
        let times = presented
            ? Array(Set(regularTimes + Self.openingCurve.map(\.time))).sorted()
            : Array(Set(regularTimes + [Self.closingCollapseEnd, Self.closingResponseStart,
                                       0.51, 0.81, Self.closingWidthPeak])).sorted()
        let keyTimes = times.map { NSNumber(value: Double($0)) }
        let animation = CAKeyframeAnimation(keyPath: "transform")
        var verticalScales: [CGFloat] = []
        var surfaceScales: [NSSize] = []
        animation.values = times.map { time in
            let progress = presented
                ? Self.openingProgress(time)
                : Self.curveProgress(min(1, time / Self.closingCollapseEnd), opening: false)
            // Land visibly narrower first, then spring outward while the
            // vertical absorption recovers. Keep the same surface throughout.
            let widthScale = presented
                ? start.m11 + (target.m11 - start.m11) * progress
                : start.m11 + (narrowScaleX - start.m11) * progress
                    + (compact.m11 - narrowScaleX) * Self.closingWidthRecovery(time)
            let absorption = presented ? 0 : compact.m22 * Self.closingHeightResponse(time)
            let transform = topAnchoredScale(
                x: widthScale,
                y: start.m22 + (target.m22 - start.m22) * progress + absorption,
                bounds: bounds, anchor: anchor)
            verticalScales.append(transform.m22)
            surfaceScales.append(NSSize(width: transform.m11, height: transform.m22))
            return NSValue(caTransform3D: transform)
        }
        animation.duration = duration
        animation.keyTimes = keyTimes
        animation.calculationMode = .linear
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: scaleKey)
        (surface as? NotchSurfaceView)?.animateContour(compactSize: compactSize, scales: surfaceScales,
                                                      keyTimes: keyTimes, duration: duration, presented: presented)
        onSurfaceScaleAnimation?(verticalScales, keyTimes, duration)
        onCompactRingAnimation?(surfaceScales, keyTimes, duration, presented)
    }

    private func topAnchoredScale(x: CGFloat, y: CGFloat, bounds: CGRect,
                                  anchor: CGPoint) -> CATransform3D {
        var transform = CATransform3DMakeScale(x, y, 1)
        transform.m41 = bounds.width * (0.5 - anchor.x) * (1 - x)
        transform.m42 = bounds.height * (1 - anchor.y) * (1 - y)
        return transform
    }

    // Gentler version of the user's curve: stretch the initial rise by 1.4x
    // and reduce overshoot to 4.8%, retaining the 600ms total duration.
    private static let openingCurve: [(time: CGFloat, progress: CGFloat)] = [
        (0, 0), (0.014, 0.009), (0.028, 0.033), (0.059, 0.13),
        (0.175, 0.681), (0.230, 0.893), (0.283, 1.012), (0.311, 1.030),
        (0.340, 1.041), (0.378, 1.048), (0.421, 1.046), (0.609, 1.007),
        (0.725, 0.995), (0.90, 1.0004), (1, 1)
    ]

    private static func openingProgress(_ time: CGFloat) -> CGFloat {
        for index in 1..<openingCurve.count where time <= openingCurve[index].time {
            let a = openingCurve[index - 1], b = openingCurve[index]
            let fraction = (time - a.time) / (b.time - a.time)
            return a.progress + (b.progress - a.progress) * fraction
        }
        return 1
    }

    private static func closingWidthRecovery(_ time: CGFloat) -> CGFloat {
        guard time > closingCollapseEnd else { return 0 }
        guard time < 1 else { return 1 }
        let u = (time - closingCollapseEnd) / (1 - closingCollapseEnd)
        let peak = (closingWidthPeak - closingCollapseEnd) / (1 - closingCollapseEnd)
        let overshoot: CGFloat = 0.075
        if u <= peak {
            // First lobe of a damped spring: zero landing velocity and one
            // small overshoot (about 3.6pt after a 47.5pt outward stretch).
            let damping = -log(overshoot) / peak
            let frequency = CGFloat.pi / peak
            return 1 - exp(-damping * u)
                * (cos(frequency * u) + damping / frequency * sin(frequency * u))
        }
        // Settle without another oscillation or a velocity jump at handoff.
        let settle = (u - peak) / (1 - peak)
        return 1 + overshoot * (1 - settle * settle * (3 - 2 * settle))
    }

    private static func closingHeightResponse(_ time: CGFloat) -> CGFloat {
        let u = (time - closingResponseStart) / (0.81 - closingResponseStart)
        guard u > 0, u < 1 else { return 0 }
        let v = 1 - u
        let peak: CGFloat = 16.0 / 729.0
        // Screen-top anchoring puts the 8pt impact below the 32pt camera;
        // the settled notch remains exactly its original height.
        return 0.25 * u * u * v * v * v * v / peak
    }

    private static func curveProgress(_ time: CGFloat, opening: Bool) -> CGFloat {
        func bezier(_ t: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGFloat {
            let u = 1 - t
            return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
        }
        var low: CGFloat = 0, high: CGFloat = 1
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if bezier(mid, opening ? 0.45 : 0.4, opening ? 0.8 : 0.2) < time {
                low = mid
            } else { high = mid }
        }
        return bezier((low + high) / 2, opening ? 1.45 : 0, 1)
    }

    private func setContentOpacity(_ opacity: Float) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        animatedContentView.layer?.opacity = opacity
        CATransaction.commit()
    }
}
