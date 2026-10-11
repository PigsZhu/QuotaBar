import AppKit
import QuartzCore

/// The camera surround stays opaque in screen points while the panel stretches.
@MainActor
final class CameraGlassShadeView: NSView {
    var cameraHeight: CGFloat = 0 {
        didSet { updateLocations() }
    }
    private let shade = CAGradientLayer()
    private let materialMask = CAGradientLayer()
    private weak var material: NSView?
    private let animationKey = "QuotaBar.cameraBlend"
    private let designHeight: CGFloat = 184
    private let designCameraHeight: CGFloat = 32
    private let designOpaqueStop: CGFloat = 0.176467

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for gradient in [shade, materialMask] {
            gradient.startPoint = CGPoint(x: 0.5, y: 1)
            gradient.endPoint = CGPoint(x: 0.5, y: 0)
        }
        shade.colors = colors(scale: 1, forMaterial: false)
        materialMask.colors = colors(scale: 1, forMaterial: true)
        layer?.addSublayer(shade)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func maskMaterial(_ view: NSView) {
        material = view
        view.wantsLayer = true
        view.layer?.mask = materialMask
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shade.frame = bounds
        materialMask.frame = material?.bounds ?? bounds
        updateLocations()
        CATransaction.commit()
    }

    private var opaqueDepth: CGFloat {
        // Replace the Figma camera placeholder with the actual camera height,
        // preserving the gradient stop's distance below the camera in points.
        max(cameraHeight > 0 ? cameraHeight + 8 : 0,
            cameraHeight + designHeight * designOpaqueStop - designCameraHeight)
    }

    private func locations(scale: CGFloat, forMaterial: Bool) -> [NSNumber] {
        if forMaterial && cameraHeight <= 0 { return [0, 0, 0, 1] }
        let visibleHeight = max(1, bounds.height * scale)
        // Hide both the camera edge and system glass highlights for another 8pt.
        let distances: [CGFloat] = forMaterial
            ? [0, cameraHeight + 8, cameraHeight + 28, visibleHeight]
            : [opaqueDepth, visibleHeight]
        return distances.map { NSNumber(value: Double(min(1, $0 / visibleHeight))) }
    }

    private func colors(scale: CGFloat, forMaterial: Bool) -> [CGColor] {
        let visibleHeight = max(1, bounds.height * scale)
        if forMaterial {
            let revealed = cameraHeight <= 0 || visibleHeight > cameraHeight + 8
            let end = revealed ? NSColor.black.cgColor : NSColor.clear.cgColor
            return [NSColor.clear.cgColor, NSColor.clear.cgColor, end, end]
        }
        // When the stops meet during collapse, keep even the bottom edge opaque.
        let bottomAlpha: CGFloat = visibleHeight <= opaqueDepth ? 1 : 0.2
        return [NSColor.black.cgColor, NSColor.black.withAlphaComponent(bottomAlpha).cgColor]
    }

    private func updateLocations() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shade.locations = locations(scale: 1, forMaterial: false)
        materialMask.locations = locations(scale: 1, forMaterial: true)
        shade.colors = colors(scale: 1, forMaterial: false)
        materialMask.colors = colors(scale: 1, forMaterial: true)
        CATransaction.commit()
    }

    func animate(verticalScales: [CGFloat], keyTimes: [NSNumber], duration: TimeInterval) {
        for (gradient, isMaterial) in [(shade, false), (materialMask, true)] {
            let tracks: [(String, [Any])] = [
                ("locations", verticalScales.map { locations(scale: $0, forMaterial: isMaterial) }),
                ("colors", verticalScales.map { colors(scale: $0, forMaterial: isMaterial) })
            ]
            let animation = CAAnimationGroup()
            animation.animations = tracks.map { keyPath, values in
                let track = CAKeyframeAnimation(keyPath: keyPath)
                track.values = values
                track.keyTimes = keyTimes
                track.duration = duration
                track.calculationMode = .linear
                track.timingFunction = CAMediaTimingFunction(name: .linear)
                return track
            }
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
            gradient.add(animation, forKey: animationKey)
        }
    }

    func resetAnimation() {
        shade.removeAnimation(forKey: animationKey)
        materialMask.removeAnimation(forKey: animationKey)
        updateLocations()
    }
}
