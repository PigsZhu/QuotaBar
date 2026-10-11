import AppKit
import QuartzCore
import simd

struct NotchEyesPose {
    var orientation = simd_quatd(angle: 0, axis: SIMD3<Double>(0, 1, 0))
    var curiosity: Double = 0
    var gazeY: Double = 0
    var openness: Double = 1
    var leftOpenness: Double = 1
    var rightOpenness: Double = 1
    var pupilShiftX: Double = 0
    var surprise: Double = 0
    var anger: Double = 0
    static let resting = NotchEyesPose()

    static func looking(horizontal: Double, vertical: Double) -> Self {
        let x = max(-1, min(1, horizontal)), y = max(-1, min(1, vertical))
        return Self(orientation:
            simd_quatd(angle: -x * 0.14, axis: SIMD3(0, 0, 1))
                * simd_quatd(angle: -y * 0.22, axis: SIMD3(1, 0, 0))
                * simd_quatd(angle: x * 0.44, axis: SIMD3(0, 1, 0)),
                    curiosity: x, gazeY: y, openness: 1)
    }

    static func glancing(horizontal: Double) -> Self {
        let direction = max(-1, min(1, horizontal))
        var pose = Self.resting
        // The accepted rest already looks slightly right. Give the left
        // glance enough travel to cross the white, while keeping the pupil visible.
        pose.pupilShiftX = direction * (direction < 0 ? 1.95 : 0.45)
        return pose
    }

    static func interpolate(_ from: Self, _ to: Self, progress: Double) -> Self {
        // Exact endpoints keep interrupted gestures and the closing handoff
        // on the same geometry, without quaternion normalization round-off.
        if progress <= 0 { return from }
        if progress >= 1 { return to }
        return Self(orientation: simd_slerp(from.orientation, to.orientation, progress),
             curiosity: from.curiosity + (to.curiosity - from.curiosity) * progress,
             gazeY: from.gazeY + (to.gazeY - from.gazeY) * progress,
             openness: from.openness + (to.openness - from.openness) * progress,
             leftOpenness: from.leftOpenness + (to.leftOpenness - from.leftOpenness) * progress,
             rightOpenness: from.rightOpenness + (to.rightOpenness - from.rightOpenness) * progress,
             pupilShiftX: from.pupilShiftX + (to.pupilShiftX - from.pupilShiftX) * progress,
             surprise: from.surprise + (to.surprise - from.surprise) * progress,
             anger: from.anger + (to.anger - from.anger) * progress)
    }
}

enum NotchEyesAppearance {
    static func whiteColor(anger: Double) -> CGColor {
        let amount = max(0, min(1, anger))
        // Keep the accepted neutral white, including its original color space.
        let neutral = NSColor(calibratedWhite: 0.96, alpha: 1)
        guard amount > 0 else { return neutral.cgColor }
        let neutralRGB = neutral.usingColorSpace(.sRGB)
            ?? NSColor(srgbRed: 0.96, green: 0.96, blue: 0.96, alpha: 1)
        let white = SIMD3<Double>(Double(neutralRGB.redComponent), Double(neutralRGB.greenComponent),
                                  Double(neutralRGB.blueComponent))
        let pink = SIMD3<Double>(1, 0.75, 0.77)
        let coral = SIMD3<Double>(1, 0.38, 0.34)
        let color: SIMD3<Double>
        if amount <= 0.35 {
            color = white + (pink - white) * (amount / 0.35)
        } else {
            color = pink + (coral - pink) * ((amount - 0.35) / 0.65)
        }
        return NSColor(srgbRed: color.x, green: color.y, blue: color.z, alpha: 1).cgColor
    }
}

/// Independently written native adaptation of the reference's curved-face
/// projection and asymmetric blink; see docs/eyes-reference.md.
enum NotchEyesGeometry {
    static func path(side: Double, pose: NotchEyesPose = .resting, pupil: Bool = false) -> CGPath {
        // Oval whites with separately projected pupils, based on the user's
        // yellow-face reference. The whites double as moving eyelid masks.
        // Surprise exposes more white without changing the accepted pupils.
        // Keep it in the pose so pointer attention can interrupt it smoothly.
        let surprise = max(0, min(1, pose.surprise))
        let width = pupil ? 3.078 : 5.6 * (1 + surprise * 0.06)
        let restingHeight = (7.0 + side * pose.curiosity * 1.35) * (1 + surprise * 0.22)
        let lidOpenness = side < 0 ? pose.leftOpenness : pose.rightOpenness
        let height = 0.85 + (restingHeight - 0.85) * max(0, min(1, pose.openness * lidOpenness))
        let anger = max(0, min(1, pose.anger))
        let radius = 16.0, focalLength = 84.0
        let path = CGMutablePath()
        for sample in 0..<64 {
            let angle = Double(sample) / 64 * .pi * 2
            var x = cos(angle) * width / 2
            var y = sin(angle) * (pupil ? 3.888 : height) / 2
            if !pupil, anger > 0 {
                // Cap the upper white with a lid that slopes down toward the
                // nose. Blending the same 64 samples preserves interruption
                // continuity; the lower contour and pupil stay untouched.
                let upperLid = height * (0.21 + side * (x / (width / 2)) * 0.19)
                y += (min(y, upperLid) - y) * anger
            }
            if pupil {
                let tilt = -0.5
                let originalX = x
                x = originalX * cos(tilt) - y * sin(tilt) + 0.8 + pose.curiosity * 0.8 + pose.pupilShiftX
                y = originalX * sin(tilt) + y * cos(tilt) + pose.gazeY * 0.8
            }
            let longitude = (side * 3.5 + x) / radius
            let latitude = y / radius
            let spherePoint = SIMD3(radius * cos(latitude) * sin(longitude),
                                    radius * sin(latitude),
                                    radius * cos(latitude) * cos(longitude))
            let point3D = pose.orientation.act(spherePoint)
            let perspective = focalLength / (focalLength - point3D.z)
            let point = CGPoint(x: 8 + point3D.x * perspective * 1.3,
                                y: 8 + point3D.y * perspective * 1.3)
            if sample == 0 { path.move(to: point) }
            else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    static func blinkOpenness(progress: Double) -> Double {
        guard progress > 0, progress < 1 else { return 1 }
        if progress < 0.42 {
            let closing = progress / 0.42
            return 1 - closing * closing
        }
        let opening = (progress - 0.42) / 0.58
        return 1 - (1 - opening) * (1 - opening)
    }
}

final class NotchEyesLayer: CALayer {
    var onAngerChange: ((Double, Double) -> Void)?
    private let leftEye = CAShapeLayer()
    private let rightEye = CAShapeLayer()
    private let leftPupil = CAShapeLayer()
    private let rightPupil = CAShapeLayer()
    private let leftLid = CAShapeLayer()
    private let rightLid = CAShapeLayer()
    private var fromPose = NotchEyesPose.resting
    private var targetPose = NotchEyesPose.resting
    private var transitionStart: Double = 0
    private var transitionDuration: Double = 0
    private var blinkStart: Double?

    override init() {
        super.init()
        // Preserve the same center as the closing overlay. Interactive paths
        // may extend outside this box into the left wing, under its notch mask.
        bounds = CGRect(x: 0, y: 0, width: 16, height: 16)
        masksToBounds = false
        for eye in [leftEye, rightEye] {
            eye.frame = bounds
            eye.fillColor = NotchEyesAppearance.whiteColor(anger: 0)
            eye.contentsScale = 2
            addSublayer(eye)
        }
        for (eye, pupil, lid) in [(leftEye, leftPupil, leftLid), (rightEye, rightPupil, rightLid)] {
            // Keep pupil masks large enough for the exaggerated projected
            // gaze; a 16pt mask would crop the pupil while the white moves on.
            let activityBounds = CGRect(x: -16, y: -12, width: 48, height: 40)
            pupil.bounds = activityBounds
            pupil.position = CGPoint(x: 8, y: 8)
            pupil.fillColor = NSColor.black.cgColor
            pupil.contentsScale = 2
            lid.bounds = activityBounds
            lid.position = CGPoint(x: 8, y: 8)
            lid.fillColor = NSColor.black.cgColor
            pupil.mask = lid
            eye.addSublayer(pupil)
        }
        resetPose()
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    func resetPose(_ pose: NotchEyesPose = .resting) {
        fromPose = pose
        targetPose = pose
        transitionDuration = 0
        blinkStart = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        removeAllAnimations()
        transform = CATransform3DIdentity
        for (eye, pupil, lid, side) in [(leftEye, leftPupil, leftLid, -1.0), (rightEye, rightPupil, rightLid, 1.0)] {
            for shape in [eye, pupil, lid] { shape.removeAllAnimations() }
            let white = NotchEyesGeometry.path(side: side, pose: pose)
            eye.path = white
            eye.fillColor = NotchEyesAppearance.whiteColor(anger: pose.anger)
            lid.path = white
            pupil.path = NotchEyesGeometry.path(side: side, pose: pose, pupil: true)
        }
        CATransaction.commit()
        onAngerChange?(pose.anger, 0)
    }

    private func currentPose(at time: Double) -> NotchEyesPose {
        let t = transitionDuration > 0 ? min(1, max(0, (time - transitionStart) / transitionDuration)) : 1
        var pose = NotchEyesPose.interpolate(fromPose, targetPose, progress: t * t * (3 - 2 * t))
        if let blinkStart { pose.openness = NotchEyesGeometry.blinkOpenness(progress: (time - blinkStart) / 0.28) }
        return pose
    }

    func look(at pose: NotchEyesPose, duration: Double = 0.28) {
        guard duration > 0 else {
            resetPose(pose)
            return
        }
        let now = CACurrentMediaTime()
        let start = currentPose(at: now)
        fromPose = start
        targetPose = pose
        transitionStart = now
        transitionDuration = duration
        blinkStart = nil
        let count = max(2, Int(ceil(duration * 60)))
        let times = (0...count).map { Double($0) / Double(count) }
        animatePaths(times: times, duration: duration) { time in
            NotchEyesPose.interpolate(start, pose, progress: time * time * (3 - 2 * time))
        }
        onAngerChange?(pose.anger, duration)
    }

    func holdCurrentPose() {
        // Stop following without snapping to the unfinished gaze's target.
        look(at: currentPose(at: CACurrentMediaTime()), duration: 0.04)
    }

    func blink() {
        let now = CACurrentMediaTime()
        var pose = currentPose(at: now)
        pose.openness = 1
        fromPose = pose
        targetPose = pose
        transitionDuration = 0
        blinkStart = now
        let times = Array(Set((0...18).map { Double($0) / 18 } + [0.42])).sorted()
        animatePaths(times: times, duration: 0.28) { time in
            var frame = pose
            frame.openness = NotchEyesGeometry.blinkOpenness(progress: time)
            return frame
        }
    }

    private func animatePaths(times: [Double], duration: Double,
                              poseAt: (Double) -> NotchEyesPose) {
        let poses = times.map(poseAt)
        let keyTimes = times.map { NSNumber(value: $0) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (eye, pupil, lid, side) in [(leftEye, leftPupil, leftLid, -1.0), (rightEye, rightPupil, rightLid, 1.0)] {
            let whites = poses.map { NotchEyesGeometry.path(side: side, pose: $0) }
            let pupils = poses.map { NotchEyesGeometry.path(side: side, pose: $0, pupil: true) }
            for (shape, samples) in [(eye, whites), (lid, whites), (pupil, pupils)] {
                var paths = samples
                if let live = shape.presentation()?.path ?? shape.path { paths[0] = live }
                shape.path = paths.last
                let animation = CAKeyframeAnimation(keyPath: "path")
                animation.values = paths
                animation.keyTimes = keyTimes
                animation.duration = duration
                animation.calculationMode = .linear
                animation.timingFunction = CAMediaTimingFunction(name: .linear)
                shape.add(animation, forKey: "expression")
            }
            var colors = poses.map { NotchEyesAppearance.whiteColor(anger: $0.anger) }
            if let live = eye.presentation()?.fillColor ?? eye.fillColor { colors[0] = live }
            eye.fillColor = colors.last
            let colorAnimation = CAKeyframeAnimation(keyPath: "fillColor")
            colorAnimation.values = colors
            colorAnimation.keyTimes = keyTimes
            colorAnimation.duration = duration
            colorAnimation.calculationMode = .linear
            colorAnimation.timingFunction = CAMediaTimingFunction(name: .linear)
            eye.add(colorAnimation, forKey: "expressionColor")
        }
        CATransaction.commit()
    }

    func shakeWithEffort() {
        cancelEffort(animated: false)
        // At maximum squeeze the whites are thin lines. Give the vertical
        // movement enough travel to read as effort instead of subpixel shimmer.
        let offsets: [(CGFloat, CGFloat)] = [
            (0, 0), (-0.60, -0.20), (1.00, 0.35), (-1.40, -0.45),
            (1.80, 0.56), (-1.70, -0.56), (1.30, 0.42), (-0.70, -0.21), (0, 0)
        ]
        let animation = CAKeyframeAnimation(keyPath: "transform")
        animation.values = offsets.map {
            NSValue(caTransform3D: CATransform3DMakeTranslation($0.0, $0.1, 0))
        }
        animation.keyTimes = [0, 0.12, 0.24, 0.36, 0.49, 0.62, 0.76, 0.90, 1]
        animation.duration = 0.48
        animation.calculationMode = .linear
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        add(animation, forKey: "effortShake")
    }

    func cancelEffort(animated: Bool) {
        guard animation(forKey: "effortShake") != nil || animation(forKey: "effortReset") != nil else { return }
        let visibleTransform = presentation()?.transform ?? transform
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        removeAnimation(forKey: "effortShake")
        removeAnimation(forKey: "effortReset")
        if animated, !CATransform3DIsIdentity(visibleTransform) {
            let reset = CABasicAnimation(keyPath: "transform")
            reset.fromValue = NSValue(caTransform3D: visibleTransform)
            reset.toValue = NSValue(caTransform3D: transform)
            reset.duration = 0.12
            reset.timingFunction = CAMediaTimingFunction(name: .easeOut)
            add(reset, forKey: "effortReset")
        }
        CATransaction.commit()
    }

    func peekFromLowerLeft() {
        resetPose(.looking(horizontal: -0.35, vertical: 0.8))
        look(at: .resting, duration: 0.56)
        let offsets: [(CGFloat, CGFloat)] = [(-12, -24), (-10, -9), (-3, 4), (1, 1.5), (0, 0)]
        let animation = CAKeyframeAnimation(keyPath: "transform")
        animation.values = offsets.map { NSValue(caTransform3D: CATransform3DMakeTranslation($0.0, $0.1, 0)) }
        animation.keyTimes = [0, 0.3, 0.66, 0.84, 1]
        animation.duration = 0.56
        animation.timingFunctions = (0..<4).map { _ in CAMediaTimingFunction(name: .easeInEaseOut) }
        add(animation, forKey: "peekEntrance")
    }
}
