/// Tracks continuous pointer movement independently of the clamped eye pose.
struct NotchEyesPatience {
    private(set) var progress: Double = 0

    private let duration: Double
    private let inactivityLimit: Double
    private var startedAt: Double?
    private var lastMovement: (horizontal: Double, vertical: Double, time: Double)?

    init(duration: Double = 3, inactivityLimit: Double = 1) {
        precondition(duration.isFinite && duration > 0)
        precondition(inactivityLimit.isFinite && inactivityLimit >= 0)
        self.duration = duration
        self.inactivityLimit = inactivityLimit
    }

    /// Coordinates are normalized by the pointer area, without clamping to ±1.
    /// Returns whether this event contains enough movement to renew attention.
    @discardableResult
    mutating func record(horizontal: Double, vertical: Double, at time: Double) -> Bool {
        guard horizontal.isFinite, vertical.isFinite, time.isFinite else { return false }

        if let previous = lastMovement {
            guard time >= previous.time else { return false }
            if time - previous.time > inactivityLimit {
                progress = 0
                startedAt = nil
            }
            // Keep the previous effective point so small movements can add up,
            // and stationary events cannot restart the clock after inactivity.
            let distance = abs(horizontal - previous.horizontal) + abs(vertical - previous.vertical)
            guard distance >= 0.06 else { return false }
        }

        let start = startedAt ?? time
        startedAt = start
        lastMovement = (horizontal, vertical, time)
        progress = min(1, max(0, (time - start) / duration))
        return true
    }

    mutating func reset() {
        progress = 0
        startedAt = nil
        lastMovement = nil
    }
}
