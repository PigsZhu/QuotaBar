import Foundation
import Observation

@Observable
@MainActor
final class UsageStore {
    private let provider: any CodexUsageProviding
    private(set) var snapshot: UsageSnapshot?
    private(set) var isRefreshing = false
    private(set) var lastError: String?

    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let sleep: @Sendable (TimeInterval) async throws -> Void
    @ObservationIgnored private var automaticTask: Task<Void, Never>?
    @ObservationIgnored private var requestTask: Task<UsageSnapshot, any Error>?
    @ObservationIgnored private var automaticRefreshEnabled = false
    @ObservationIgnored private var isSuspended = false
    @ObservationIgnored private var isExpanded = false
    @ObservationIgnored private var isShuttingDown = false
    @ObservationIgnored private var refreshAfterCurrent = false
    @ObservationIgnored private var lastCompletedAt: Date?
    @ObservationIgnored private var consecutiveFailures = 0

    init(provider: any CodexUsageProviding,
         now: @escaping () -> Date = Date.init,
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
             try await Task.sleep(for: .seconds($0))
         }) {
        self.provider = provider
        self.now = now
        self.sleep = sleep
    }

    var menuBarTitle: String {
        guard let primary = snapshot?.primary else { return "Codex" }
        return "Codex \(primary.remainingPercent)%"
    }

    func refresh() async {
        guard !isRefreshing, !isShuttingDown else { return }
        cancelScheduledRefresh()
        isRefreshing = true
        lastError = nil
        let request = Task { try await provider.fetchUsage() }
        requestTask = request
        defer {
            requestTask = nil
            isRefreshing = false
            lastCompletedAt = now()
            if refreshAfterCurrent {
                refreshAfterCurrent = false
                scheduleRefresh(after: 0)
            } else {
                scheduleNextRefresh()
            }
        }

        do {
            let result = try await withTaskCancellationHandler {
                try await request.value
            } onCancel: {
                request.cancel()
            }
            guard !request.isCancelled, !isShuttingDown else { return }
            snapshot = result
            lastError = nil
            consecutiveFailures = 0
        } catch {
            guard !request.isCancelled, !isShuttingDown else { return }
            lastError = error.localizedDescription
            consecutiveFailures += 1
        }
    }

    func startAutomaticRefresh() {
        guard !automaticRefreshEnabled, !isShuttingDown else { return }
        automaticRefreshEnabled = true
        scheduleRefresh(after: 0)
    }

    func setExpanded(_ expanded: Bool) {
        guard isExpanded != expanded else { return }
        isExpanded = expanded
        guard !isRefreshing else { return }
        // Opening a stale card refreshes promptly; rapid toggles share a five-second cache.
        if expanded && (lastCompletedAt == nil || now().timeIntervalSince(lastCompletedAt!) >= 5) {
            scheduleRefresh(after: 0)
        } else {
            scheduleNextRefresh()
        }
    }

    func suspendAutomaticRefresh() {
        isSuspended = true
        refreshAfterCurrent = false
        cancelScheduledRefresh()
        requestTask?.cancel()
    }

    func resumeAutomaticRefresh() {
        isSuspended = false
        consecutiveFailures = 0
        if isRefreshing {
            refreshAfterCurrent = true
        } else {
            scheduleRefresh(after: 0)
        }
    }

    func shutdown() async {
        isShuttingDown = true
        automaticRefreshEnabled = false
        suspendAutomaticRefresh()
        await provider.shutdown()
    }

    private func scheduleNextRefresh() {
        var interval: TimeInterval = isExpanded ? 10 : 30
        if consecutiveFailures > 0 {
            interval = min(120, 30 * pow(2, Double(min(consecutiveFailures - 1, 2))))
        }
        let elapsed = lastCompletedAt.map { max(0, now().timeIntervalSince($0)) } ?? interval
        var delay = max(0, interval - elapsed)
        // Read just after the quota resets, even if the normal polling deadline is later.
        if consecutiveFailures == 0, let resetDate = snapshot?.primary?.resetDate {
            let untilReset = resetDate.timeIntervalSince(now())
            if untilReset > 0 { delay = min(delay, untilReset + 1) }
        }
        scheduleRefresh(after: delay)
    }

    private func scheduleRefresh(after delay: TimeInterval) {
        cancelScheduledRefresh()
        guard automaticRefreshEnabled, !isSuspended, !isShuttingDown, !isRefreshing else { return }
        let sleep = sleep
        automaticTask = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.automaticTask = nil
            await self.refresh()
        }
    }

    private func cancelScheduledRefresh() {
        automaticTask?.cancel()
        automaticTask = nil
    }
}
