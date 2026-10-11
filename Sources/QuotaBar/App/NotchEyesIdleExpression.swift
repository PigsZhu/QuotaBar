import simd

/// Native gestures inspired by the reference's expression families, adapted
/// to oval whites and pupils. Each ends at the accepted right-biased rest pose.
enum NotchEyesIdleExpression: CaseIterable {
    case lookAround, curious, wink, content, pupilGlance, inspectQuota, overchargeQuota

    enum RingAction { case respond, charge, burst }

    struct Step {
        let pose: NotchEyesPose
        let duration: Double
        let hold: Double
        var ringAction: RingAction?
        var effortShake = false
    }

    var steps: [Step] {
        switch self {
        case .pupilGlance:
            return [
                Step(pose: .glancing(horizontal: -1), duration: 0.24, hold: 0.60),
                Step(pose: .glancing(horizontal: 1), duration: 0.32, hold: 0.65),
                Step(pose: .resting, duration: 0.30, hold: 0)
            ]
        case .overchargeQuota:
            return [
                step(x: 0.9, y: 0, duration: 0.34, hold: 0.14),
                // Both eyes squeeze shut as the ring fills under pressure.
                step(x: 0.78, y: -0.14, roll: -0.05, left: 0.06, right: 0.06,
                     duration: 0.40, hold: 0.25, ringAction: .charge),
                step(x: 0.82, y: -0.18, roll: 0.03, left: 0.015, right: 0.015,
                     duration: 0.30, hold: 0.35),
                // Hold the tightest expression and visibly strain before release.
                step(x: 0.82, y: -0.18, roll: 0.03, left: 0.015, right: 0.015,
                     duration: 0.01, hold: 0.50, effortShake: true),
                // The finite 480 ms tremor settles before the ring explodes.
                // Pop open and recoil away from the burst, then pause before
                // cautiously checking the ring as its particles settle.
                step(x: -0.5, y: 0.12, roll: 0.08, surprise: 1,
                     duration: 0.12, hold: 0.20, ringAction: .burst),
                step(x: 0.7, y: 0, surprise: 0.22, duration: 0.34, hold: 0.46),
                Step(pose: .resting, duration: 0.44, hold: 0)
            ]
        case .inspectQuota:
            return [
                // Notice the ring first; leave a beat before it responds.
                step(x: 0.9, y: 0, roll: -0.06, duration: 0.44, hold: 0.34),
                step(x: 0.9, y: 0, roll: -0.06, duration: 0.08, hold: 0.76, ringAction: .respond),
                // The ring's 720 ms response finishes before the wink.
                step(x: 0.9, y: 0, roll: -0.06, right: 0, duration: 0.14, hold: 0.16),
                step(x: 0.65, y: 0, duration: 0.24, hold: 0.25),
                Step(pose: .resting, duration: 0.48, hold: 0)
            ]
        case .lookAround:
            return [
                step(x: 0.85, y: 0, duration: 0.46, hold: 0.65),
                step(x: -0.75, y: -0.12, duration: 0.6, hold: 0.7),
                Step(pose: .resting, duration: 0.5, hold: 0)
            ]
        case .curious:
            return [
                step(x: -0.65, y: -0.08, roll: 0.12, left: 0.55, duration: 0.48, hold: 0.85),
                step(x: -0.3, y: 0, roll: -0.08, duration: 0.38, hold: 0.4),
                Step(pose: .resting, duration: 0.48, hold: 0)
            ]
        case .wink:
            return [
                step(x: 0.4, y: 0, duration: 0.34, hold: 0.2),
                step(x: 0.4, y: 0, right: 0, duration: 0.14, hold: 0.2),
                step(x: 0.4, y: 0, duration: 0.24, hold: 0.35),
                Step(pose: .resting, duration: 0.42, hold: 0)
            ]
        case .content:
            return [
                step(x: 0.15, y: -0.15, left: 0.28, right: 0.28, duration: 0.4, hold: 0.55),
                step(x: 0.4, y: 0, duration: 0.38, hold: 0.35),
                Step(pose: .resting, duration: 0.46, hold: 0)
            ]
        }
    }

    private func step(x: Double, y: Double, roll: Double = 0,
                      left: Double = 1, right: Double = 1, surprise: Double = 0,
                      duration: Double, hold: Double, ringAction: RingAction? = nil,
                      effortShake: Bool = false) -> Step {
        var pose = NotchEyesPose.looking(horizontal: x, vertical: y)
        pose.orientation = simd_quatd(angle: roll, axis: SIMD3(0, 0, 1)) * pose.orientation
        pose.leftOpenness = left
        pose.rightOpenness = right
        pose.surprise = surprise
        return Step(pose: pose, duration: duration, hold: hold, ringAction: ringAction, effortShake: effortShake)
    }
}
