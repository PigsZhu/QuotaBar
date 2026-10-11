import AppKit
import QuartzCore

/// Matching path segments keep the compact notch and expanded surface morphable.
enum NotchGeometry {
    static func path(in rect: CGRect, notch: Bool, radius: CGFloat = 22) -> CGPath {
        let p = CGMutablePath()
        let r = min(radius, rect.height / 2, rect.width / 4)
        let left = rect.minX, right = rect.maxX
        let top = rect.maxY, bottom = rect.minY
        let inset = notch ? r : 0
        let start = notch ? left : left + r
        let end = notch ? right : right - r
        p.move(to: CGPoint(x: start, y: top))
        p.addLine(to: CGPoint(x: end, y: top))
        p.addCurve(to: CGPoint(x: right - inset, y: top - r),
                   control1: CGPoint(x: notch ? right - r : right, y: top),
                   control2: CGPoint(x: right - inset, y: top - r * 0.45))
        p.addLine(to: CGPoint(x: right - inset, y: bottom + r))
        p.addCurve(to: CGPoint(x: right - inset - r, y: bottom),
                   control1: CGPoint(x: right - inset, y: bottom + r * 0.45),
                   control2: CGPoint(x: right - inset - r * 0.45, y: bottom))
        p.addLine(to: CGPoint(x: left + inset + r, y: bottom))
        p.addCurve(to: CGPoint(x: left + inset, y: bottom + r),
                   control1: CGPoint(x: left + inset + r * 0.45, y: bottom),
                   control2: CGPoint(x: left + inset, y: bottom + r * 0.45))
        p.addLine(to: CGPoint(x: left + inset, y: top - r))
        p.addCurve(to: CGPoint(x: start, y: top),
                   control1: CGPoint(x: left + inset, y: top - r * 0.45),
                   control2: CGPoint(x: notch ? left + r : left, y: top))
        p.closeSubpath()
        return p
    }
}

enum QuotaRingDrawing {
    static func draw(in context: CGContext, center: CGPoint, diameter: CGFloat = 16,
                     remainingPercent: Int?) {
        let lineWidth: CGFloat = 3
        let radius = (diameter - lineWidth) / 2
        let ring = CGRect(x: center.x - radius, y: center.y - radius,
                          width: radius * 2, height: radius * 2)
        context.saveGState()
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor)
        context.strokeEllipse(in: ring)
        if let remainingPercent, remainingPercent > 0 {
            let fraction = CGFloat(min(100, remainingPercent)) / 100
            context.setStrokeColor(NSColor.white.cgColor)
            if fraction == 1 {
                context.strokeEllipse(in: ring)
            } else {
                context.addArc(center: center, radius: radius,
                               startAngle: .pi / 2, endAngle: .pi / 2 - .pi * 2 * fraction,
                               clockwise: true)
                context.strokePath()
            }
        }
        context.restoreGState()
    }
}

@MainActor
final class NotchSurfaceView: NSView {
    weak var shadowView: NotchShadowView?
    static let shoulderWidth: CGFloat = 16
    private static let bottomRadius: CGFloat = 16
    private static let contourAnimationKey = "notchContour"
    private let surfaceMask = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureMask()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureMask()
    }

    private func configureMask() {
        wantsLayer = true
        surfaceMask.fillColor = NSColor.black.cgColor
        layer?.mask = surfaceMask
    }

    override func layout() {
        super.layout()
        updateMask()
    }

    func animateContour(compactSize: NSSize, scales: [NSSize], keyTimes: [NSNumber], duration: TimeInterval,
                        presented: Bool) {
        guard bounds.height > compactSize.height, compactSize.height > 0,
              duration > 0, scales.count > 1,
              scales.allSatisfy({ $0.width > 0 && $0.height > 0
                  && $0.width.isFinite && $0.height.isFinite }) else {
            resetContour()
            return
        }

        let compactScaleY = compactSize.height / bounds.height
        let compactRadius = compactSize.height * 0.46
        let paths = scales.map { scale in
            let progress = min(1, max(0, (scale.height - compactScaleY) / (1 - compactScaleY)))
            let shoulder = compactRadius + (Self.shoulderWidth - compactRadius) * progress
            let bottomRadius = compactRadius + (Self.bottomRadius - compactRadius) * progress
            return contourPath(
                shoulder: NSSize(width: shoulder / scale.width, height: shoulder / scale.height),
                bottomRadius: NSSize(width: bottomRadius / scale.width, height: bottomRadius / scale.height)
            )
        }

        updateMask()
        let animation = CAKeyframeAnimation(keyPath: "path")
        animation.values = paths
        animation.keyTimes = keyTimes
        animation.duration = duration
        animation.calculationMode = .linear
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        surfaceMask.add(animation, forKey: Self.contourAnimationKey)
        shadowView?.animate(contours: paths, scales: scales, keyTimes: keyTimes,
                            duration: duration, presented: presented)
    }

    func resetContour() {
        surfaceMask.removeAnimation(forKey: Self.contourAnimationKey)
        shadowView?.resetAnimation()
        updateMask()
    }

    private func updateMask() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surfaceMask.frame = bounds
        surfaceMask.path = contourPath(
            shoulder: NSSize(width: Self.shoulderWidth, height: Self.shoulderWidth),
            bottomRadius: NSSize(width: Self.bottomRadius, height: Self.bottomRadius)
        )
        if let path = surfaceMask.path { shadowView?.updateContour(path) }
        CATransaction.commit()
    }

    private func contourPath(shoulder: NSSize, bottomRadius: NSSize) -> CGPath {
        let shoulderX = shoulder.width, shoulderY = shoulder.height
        let radiusX = bottomRadius.width, radiusY = bottomRadius.height
        let left = bounds.minX, right = bounds.maxX
        let top = bounds.maxY, bottom = bounds.minY
        let path = CGMutablePath()
        path.move(to: CGPoint(x: left, y: top))
        path.addLine(to: CGPoint(x: right, y: top))
        path.addCurve(to: CGPoint(x: right - shoulderX, y: top - shoulderY),
                      control1: CGPoint(x: right - shoulderX, y: top),
                      control2: CGPoint(x: right - shoulderX, y: top - shoulderY * 0.45))
        path.addLine(to: CGPoint(x: right - shoulderX, y: bottom + radiusY))
        path.addCurve(to: CGPoint(x: right - shoulderX - radiusX, y: bottom),
                      control1: CGPoint(x: right - shoulderX, y: bottom + radiusY * 0.45),
                      control2: CGPoint(x: right - shoulderX - radiusX * 0.45, y: bottom))
        path.addLine(to: CGPoint(x: left + shoulderX + radiusX, y: bottom))
        path.addCurve(to: CGPoint(x: left + shoulderX, y: bottom + radiusY),
                      control1: CGPoint(x: left + shoulderX + radiusX * 0.45, y: bottom),
                      control2: CGPoint(x: left + shoulderX, y: bottom + radiusY * 0.45))
        path.addLine(to: CGPoint(x: left + shoulderX, y: top - shoulderY))
        path.addCurve(to: CGPoint(x: left, y: top),
                      control1: CGPoint(x: left + shoulderX, y: top - shoulderY * 0.45),
                      control2: CGPoint(x: left + shoulderX, y: top))
        path.closeSubpath()
        return path
    }
}

final class NotchButton: NSButton {
    private let eyes = NotchEyesLayer()
    private let quotaRing = QuotaRingLayer()
    private let eyesContainer = CALayer()
    private let eyesMask = CAShapeLayer()
    private let angerGlow = NotchAngerGlowLayer()
    private lazy var eyeBehavior = NotchEyesBehavior(eyes: eyes,
        onRingResponse: { [weak self] in self?.quotaRing.respond() },
        onRingCharge: { [weak self] in self?.quotaRing.charge() },
        onRingBurst: { [weak self] in self?.quotaRing.burst() },
        onRingReset: { [weak self] animated in self?.quotaRing.resetResponse(animated: animated) },
        onAngerTurn: { [weak self] in self?.releaseAngerGlow() })
    private var eyeTrackingArea: NSTrackingArea?
    private var nearbyPointerMonitor: Any?
    private var localPointerMonitor: Any?
    var cameraWidth: CGFloat = 0 {
        didSet { needsDisplay = true; needsLayout = true }
    }
    var remainingPercent: Int? {
        didSet {
            needsDisplay = true
            needsLayout = true
            setAccessibilityValue(remainingPercent.map { "剩余 \(max(0, min(100, $0)))%" } ?? "额度暂不可用")
        }
    }

    override var isFlipped: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureEyes()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureEyes()
    }

    private func configureEyes() {
        wantsLayer = true
        eyesContainer.mask = eyesMask
        eyesContainer.addSublayer(angerGlow)
        eyesContainer.addSublayer(eyes)
        eyesContainer.addSublayer(quotaRing)
        layer?.addSublayer(eyesContainer)
        eyes.onAngerChange = { [weak self] anger, duration in
            self?.animateAngerGlow(anger: anger, duration: duration)
        }
    }

    private func animateAngerGlow(anger: Double, duration: Double) {
        angerGlow.update(anger: anger, duration: duration, origin: currentEyesMidpoint)
    }

    private func releaseAngerGlow() {
        angerGlow.release(origin: currentEyesMidpoint)
    }

    private var currentEyesMidpoint: CGPoint {
        let liveEyes = eyes.presentation() ?? eyes
        var eyeBounds = CGRect.null
        for white in eyes.sublayers?.compactMap({ $0 as? CAShapeLayer }) ?? [] {
            let liveWhite = white.presentation() ?? white
            if let path = liveWhite.path {
                eyeBounds = eyeBounds.union(liveWhite.convert(path.boundingBoxOfPath, to: liveEyes))
            }
        }
        let midpoint = eyeBounds.isNull ? CGPoint(x: eyes.bounds.midX, y: eyes.bounds.midY)
            : CGPoint(x: eyeBounds.midX, y: eyeBounds.midY)
        return liveEyes.convert(midpoint, to: liveEyes.superlayer)
    }

    override func layout() {
        super.layout()
        let radius = bounds.height * 0.46
        let cameraLeft = bounds.midX - cameraWidth / 2
        let sideWidth = cameraLeft - (bounds.minX + radius)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        eyesContainer.frame = bounds
        eyesContainer.isHidden = cameraWidth <= 0
        // End the tint before the physical camera, with a full transparent
        // tail and a one-point black gap. No red layer reaches the right wing.
        angerGlow.updateFrame(CGRect(x: bounds.minX, y: bounds.minY,
                                    width: max(0, cameraLeft - bounds.minX - 1), height: bounds.height))
        angerGlow.isHidden = cameraWidth <= 0 || sideWidth <= 16
        eyes.isHidden = sideWidth <= 16
        eyesMask.frame = bounds
        eyesMask.path = NotchGeometry.path(in: bounds, notch: true, radius: radius)
        eyes.position = CGPoint(x: bounds.minX + radius + sideWidth / 2, y: bounds.midY)
        let diameter = min(16, sideWidth - 8, bounds.height - 8)
        quotaRing.isHidden = sideWidth <= 8 || diameter <= 0
        quotaRing.position = CGPoint(x: bounds.midX + cameraWidth / 2 + sideWidth / 2,
                                     y: bounds.midY)
        quotaRing.update(diameter: diameter, remainingPercent: remainingPercent)
        CATransaction.commit()
    }

    func previewAnnoyance() {
        eyeBehavior.previewAnnoyance()
    }

    func startEyesAnimation(arriving: Bool = false) {
        guard cameraWidth > 0 else { return }
        layoutSubtreeIfNeeded()
        eyeBehavior.activate(arriving: arriving)
        if nearbyPointerMonitor == nil {
            nearbyPointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
                Task { @MainActor in self?.noticeNearbyPointer() }
            }
        }
        if localPointerMonitor == nil {
            localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
                MainActor.assumeIsolated { self?.noticeNearbyPointer() }
                return event
            }
        }
    }

    func stopEyesAnimation() {
        eyeBehavior.stop()
        if let nearbyPointerMonitor { NSEvent.removeMonitor(nearbyPointerMonitor) }
        if let localPointerMonitor { NSEvent.removeMonitor(localPointerMonitor) }
        nearbyPointerMonitor = nil
        localPointerMonitor = nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let eyeTrackingArea { removeTrackingArea(eyeTrackingArea) }
        let area = NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        eyeTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { noticePointer(event) }
    override func mouseMoved(with event: NSEvent) { noticePointer(event) }
    override func mouseExited(with event: NSEvent) { noticeNearbyPointer() }

    private func noticePointer(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        followPointer(at: point)
    }

    private func noticeNearbyPointer() {
        guard let window, window.isVisible else { return }
        let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        guard bounds.insetBy(dx: -24, dy: -28).contains(point) else {
            eyeBehavior.pointerExited()
            return
        }
        followPointer(at: point)
    }

    private func followPointer(at point: NSPoint) {
        eyeBehavior.pointerMoved(horizontal: (point.x - eyes.position.x) / 28,
                                 vertical: (point.y - bounds.midY) / 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let radius = bounds.height * 0.46
        let path = NotchGeometry.path(in: bounds, notch: true, radius: radius)
        context.setFillColor(NSColor.black.cgColor)
        context.addPath(path)
        context.fillPath()
    }

}
