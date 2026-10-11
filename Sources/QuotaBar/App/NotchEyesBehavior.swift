import AppKit

/// Occasional idle expressions yield to interaction; no fixed repeating movie.
@MainActor
final class NotchEyesBehavior {
    enum State { case hidden, entering, settling, resting, expressing, attentive, annoyed, ignoring, recovering }
    enum QuotaInteraction { case inspect, overcharge }
    private(set) var state: State = .hidden
    private(set) var hasEntered = false
    private let eyes: NotchEyesLayer
    private let reduceMotion: () -> Bool
    private let idleDelay: () -> Double
    private let onRingResponse: () -> Void
    private let onRingCharge: () -> Void
    private let onRingBurst: () -> Void
    private let onRingReset: (Bool) -> Void
    private let onAngerTurn: () -> Void
    private var phaseTask: Task<Void, Never>?
    private var attentionTask: Task<Void, Never>?
    private var blinkTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var annoyanceTask: Task<Void, Never>?
    private var patienceExpiryTask: Task<Void, Never>?
    private var patience: NotchEyesPatience
    private let ignoreDuration: Double
    private var lastWarmth: Double = 0
    private var lastIdleExpression: NotchEyesIdleExpression?
    // Alternate the ring interactions, with two other expressions between.
    // Visibility changes keep that cadence instead of replaying the debut.
    private var expressionsSinceQuotaCheck = 2
    private var nextQuotaInteraction: QuotaInteraction
    private var pendingPupilGlance = true
    private var pointer: (x: Double, y: Double)?
    private var lastLook: (x: Double, y: Double)?
    private var lastLookTime: Double = 0
    private var generation = 0

    init(eyes: NotchEyesLayer, reduceMotion: @escaping () -> Bool = {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }, idleDelay: @escaping () -> Double = { Double.random(in: 4...7) },
         onRingResponse: @escaping () -> Void = {},
         onRingCharge: @escaping () -> Void = {},
         onRingBurst: @escaping () -> Void = {},
         onRingReset: @escaping (Bool) -> Void = { _ in },
         onAngerTurn: @escaping () -> Void = {},
         initialQuotaInteraction: QuotaInteraction = .overcharge,
         patienceDuration: Double = 3, ignoreDuration: Double = 3) {
        self.eyes = eyes
        self.reduceMotion = reduceMotion
        self.idleDelay = idleDelay
        self.onRingResponse = onRingResponse
        self.onRingCharge = onRingCharge
        self.onRingBurst = onRingBurst
        self.onRingReset = onRingReset
        self.onAngerTurn = onAngerTurn
        self.nextQuotaInteraction = initialQuotaInteraction
        self.patience = NotchEyesPatience(duration: patienceDuration)
        self.ignoreDuration = ignoreDuration
    }

    func activate(arriving: Bool) {
        stop()
        eyes.resetPose()
        if reduceMotion() {
            hasEntered = true
            state = .resting
            return
        }
        let firstAppearance = !hasEntered && !arriving
        hasEntered = true
        state = firstAppearance ? .entering : .settling
        let token = generation
        if firstAppearance { eyes.peekFromLowerLeft() }
        phaseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(firstAppearance ? 0.56 : 0.12))
            guard !Task.isCancelled, let self, self.generation == token else { return }
            // Returning starts in the identical overlay pose, then raises its
            // gaze once. It never replays the lower-left entrance.
            if !firstAppearance {
                self.eyes.look(at: .looking(horizontal: 0, vertical: 0.45), duration: 0.2)
                try? await Task.sleep(for: .seconds(0.26))
                guard !Task.isCancelled, self.generation == token else { return }
            }
            self.state = .resting
            self.eyes.look(at: .resting, duration: 0.25)
            self.phaseTask = nil
            self.scheduleBlink(after: firstAppearance ? 0.18 : Double.random(in: 1.8...3.0))
            if self.pointer != nil { self.noticePointer() }
            else { self.scheduleIdle() }
        }
    }

    func stop() {
        generation += 1
        phaseTask?.cancel()
        attentionTask?.cancel()
        blinkTask?.cancel()
        idleTask?.cancel()
        annoyanceTask?.cancel()
        resetPatience()
        phaseTask = nil
        attentionTask = nil
        blinkTask = nil
        idleTask = nil
        annoyanceTask = nil
        pointer = nil
        lastLook = nil
        state = .hidden
        onRingReset(false)
        eyes.resetPose()
    }

    func pointerMoved(horizontal: Double, vertical: Double) {
        guard state != .hidden, !reduceMotion() else { return }
        pointer = (max(-1, min(1, horizontal)), max(-1, min(1, vertical)))
        if state == .entering || state == .settling { return }
        // Keep the latest pointer for recovery, but don't let mouse events
        // replace the angry expression or re-enter attention during its pause.
        if isDecliningAttention { return }
        idleTask?.cancel()
        idleTask = nil
        if state == .expressing {
            eyes.cancelEffort(animated: true)
            onRingReset(true)
            state = .resting
            scheduleBlink(after: Double.random(in: 1.8...3))
        }
        if state == .attentive {
            if patience.record(horizontal: horizontal, vertical: vertical, at: CACurrentMediaTime()) {
                if patience.progress >= 1 {
                    beginAnnoyance()
                    return
                }
                expirePatienceAfterInactivity()
            }
            attentionTask?.cancel()
            attentionTask = nil
            followPointer()
        } else { noticePointer() }
    }

    func pointerExited() {
        // Further movement outside must not keep postponing the return gaze.
        guard pointer != nil else { return }
        pointer = nil
        resetPatience()
        attentionTask?.cancel()
        attentionTask = nil
        if state == .annoyed || state == .ignoring {
            beginRecovery()
            return
        }
        if state == .recovering { return }
        guard state == .attentive else {
            if state == .resting {
                // The pointer can leave during the 100 ms attention delay.
                eyes.look(at: .resting, duration: 0.42)
                scheduleIdle()
            }
            return
        }
        let token = generation
        // A short lingering look makes attention feel intentional.
        attentionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.38))
            guard !Task.isCancelled, let self, self.generation == token, self.pointer == nil else { return }
            self.eyes.look(at: .resting, duration: 0.42)
            self.state = .resting
            self.lastLook = nil
            self.attentionTask = nil
            self.scheduleIdle()
        }
    }

    private func noticePointer() {
        guard !isDecliningAttention else { return }
        guard attentionTask == nil else { return }
        let token = generation
        attentionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.10))
            guard !Task.isCancelled, let self, self.generation == token, self.pointer != nil else { return }
            self.state = .attentive
            self.attentionTask = nil
            self.followPointer(force: true)
        }
    }

    private func followPointer(force: Bool = false) {
        guard let pointer else { return }
        let now = CACurrentMediaTime()
        let warmth = max(0, (patience.progress - 0.6) / 0.4) * 0.35
        if !force, let previous = lastLook {
            guard now - lastLookTime > 0.05,
                  abs(pointer.x - previous.x) + abs(pointer.y - previous.y) > 0.06
                    || abs(warmth - lastWarmth) > 0.025 else { return }
        }
        lastLook = pointer
        lastLookTime = now
        lastWarmth = warmth
        var pose = NotchEyesPose.looking(horizontal: pointer.x, vertical: pointer.y)
        pose.anger = warmth
        eyes.look(at: pose, duration: force ? 0.28 : 0.18)
    }

    private var isDecliningAttention: Bool {
        state == .annoyed || state == .ignoring || state == .recovering
    }

    // A one-shot developer preview uses the real reaction and recovery path.
    // Normal launches always reach this expression through pointer patience.
    func previewAnnoyance() {
        guard state == .resting || state == .attentive || state == .expressing,
              !reduceMotion() else { return }
        if state == .expressing {
            eyes.cancelEffort(animated: true)
            onRingReset(true)
        }
        beginAnnoyance()
    }

    private func resetPatience() {
        patienceExpiryTask?.cancel()
        patienceExpiryTask = nil
        patience.reset()
        lastWarmth = 0
    }

    private func expirePatienceAfterInactivity() {
        patienceExpiryTask?.cancel()
        let token = generation
        patienceExpiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, self.generation == token, self.state == .attentive else { return }
            let wasWarm = self.lastWarmth > 0
            self.resetPatience()
            if self.reduceMotion() { self.eyes.resetPose() }
            else if wasWarm { self.followPointer(force: true) }
        }
    }

    private func beginAnnoyance() {
        attentionTask?.cancel()
        attentionTask = nil
        idleTask?.cancel()
        idleTask = nil
        blinkTask?.cancel()
        blinkTask = nil
        resetPatience()
        state = .annoyed
        let token = generation
        let direction = pointer?.x ?? 0
        eyes.holdCurrentPose()
        annoyanceTask = Task { [weak self] in
            // A brief stop makes the following fast lid press feel deliberate.
            try? await Task.sleep(for: .seconds(0.10))
            guard let self, self.canContinueAnnoyance(token: token) else { return }
            var glare = NotchEyesPose.looking(horizontal: direction * 0.35, vertical: -0.06)
            glare.anger = 1
            glare.leftOpenness = 0.72
            glare.rightOpenness = 0.72
            self.eyes.look(at: glare, duration: 0.12)
            // The red bloom starts with the lid press and spreads during this hold.
            try? await Task.sleep(for: .seconds(0.67))
            guard self.canContinueAnnoyance(token: token) else { return }
            self.state = .ignoring
            self.onAngerTurn()
            let turnDirection = direction >= 0 ? -1.0 : 1.0
            var away = NotchEyesPose.looking(horizontal: turnDirection * 0.90, vertical: 0.08)
            away.anger = 1
            away.leftOpenness = 0.76
            away.rightOpenness = 0.76
            self.eyes.look(at: away, duration: 0.14)
            try? await Task.sleep(for: .seconds(0.14))
            guard self.canContinueAnnoyance(token: token) else { return }
            var settled = NotchEyesPose.looking(horizontal: turnDirection * 0.82, vertical: 0.08)
            settled.anger = 1
            settled.leftOpenness = 0.76
            settled.rightOpenness = 0.76
            self.eyes.look(at: settled, duration: 0.12)
            try? await Task.sleep(for: .seconds(max(0.12, self.ignoreDuration - 0.14)))
            guard self.canContinueAnnoyance(token: token) else { return }
            await self.recoverFromAnnoyance(token: token)
        }
    }

    private func beginRecovery() {
        annoyanceTask?.cancel()
        let token = generation
        annoyanceTask = Task { [weak self] in
            guard let self, self.canContinueAnnoyance(token: token) else { return }
            await self.recoverFromAnnoyance(token: token)
        }
    }

    private func canContinueAnnoyance(token: Int) -> Bool {
        guard !Task.isCancelled, generation == token else { return false }
        if reduceMotion() {
            resetPatience()
            eyes.resetPose()
            state = .resting
            annoyanceTask = nil
            return false
        }
        return true
    }

    private func recoverFromAnnoyance(token: Int) async {
        state = .recovering
        var peek = NotchEyesPose.looking(horizontal: (pointer?.x ?? 0.35) * 0.55, vertical: 0)
        peek.anger = 0.45
        peek.leftOpenness = 0.82
        peek.rightOpenness = 0.82
        eyes.look(at: peek, duration: 0.16)
        try? await Task.sleep(for: .seconds(0.46))
        guard canContinueAnnoyance(token: token) else { return }
        eyes.look(at: .resting, duration: 0.45)
        try? await Task.sleep(for: .seconds(0.48))
        guard canContinueAnnoyance(token: token) else { return }
        resetPatience()
        lastLook = nil
        annoyanceTask = nil
        state = .resting
        scheduleBlink(after: Double.random(in: 1.8...3))
        if pointer != nil {
            state = .attentive
            followPointer(force: true)
        } else { scheduleIdle() }
    }

    private func scheduleBlink(after delay: Double) {
        blinkTask?.cancel()
        let token = generation
        blinkTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.generation == token,
                  self.state != .hidden, !self.reduceMotion() else { return }
            self.eyes.blink()
            self.scheduleBlink(after: Double.random(in: 3.4...6.2))
        }
    }

    private func scheduleIdle() {
        idleTask?.cancel()
        idleTask = nil
        guard state == .resting, pointer == nil, !reduceMotion() else { return }
        let token = generation
        let delay = max(0.3, idleDelay())
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.generation == token,
                  self.state == .resting, self.pointer == nil, !self.reduceMotion() else { return }
            let expression: NotchEyesIdleExpression
            if self.expressionsSinceQuotaCheck >= 2 {
                expression = self.nextQuotaInteraction == .inspect ? .inspectQuota : .overchargeQuota
                self.nextQuotaInteraction = self.nextQuotaInteraction == .inspect ? .overcharge : .inspect
                self.expressionsSinceQuotaCheck = 0
            } else if self.pendingPupilGlance {
                expression = .pupilGlance
                self.pendingPupilGlance = false
                self.expressionsSinceQuotaCheck += 1
            } else {
                let choices = NotchEyesIdleExpression.allCases.filter {
                    $0 != .inspectQuota && $0 != .overchargeQuota && $0 != self.lastIdleExpression
                }
                guard let choice = choices.randomElement() else { return }
                expression = choice
                self.expressionsSinceQuotaCheck += 1
            }
            self.lastIdleExpression = expression
            self.state = .expressing
            // A blink also owns the eye paths. Don't let it interrupt a wink
            // or freeze a head turn midway through an idle expression.
            self.blinkTask?.cancel()
            self.blinkTask = nil
            for step in expression.steps {
                self.eyes.look(at: step.pose, duration: step.duration)
                if step.effortShake { self.eyes.shakeWithEffort() }
                switch step.ringAction {
                case .respond: self.onRingResponse()
                case .charge: self.onRingCharge()
                case .burst: self.onRingBurst()
                case nil: break
                }
                try? await Task.sleep(for: .seconds(step.duration + step.hold))
                guard !Task.isCancelled, self.generation == token,
                      self.state == .expressing, self.pointer == nil else { return }
                if self.reduceMotion() {
                    self.onRingReset(false)
                    self.eyes.resetPose()
                    self.state = .resting
                    self.idleTask = nil
                    return
                }
            }
            self.state = .resting
            self.idleTask = nil
            self.scheduleBlink(after: Double.random(in: 1.4...2.8))
            self.scheduleIdle()
        }
    }
}
