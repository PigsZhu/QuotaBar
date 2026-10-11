import Foundation
import XCTest
@testable import QuotaBar

@MainActor
final class UsageStoreTests: XCTestCase {
    private func snapshot(usedPercent: Int, updatedAt: TimeInterval = 1_800_000_000) -> UsageSnapshot {
        UsageSnapshot(
            providerName: "Codex",
            planName: "pro",
            primary: UsageWindow(usedPercent: usedPercent, resetDate: nil, durationMinutes: 300),
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }

    func testFirstFailureStopsRefreshingAndExposesError() async {
        let provider = ControlledUsageProvider()
        let store = UsageStore(provider: provider)
        let refresh = Task { await store.refresh() }
        await provider.waitForCall(1)

        XCTAssertTrue(store.isRefreshing)
        XCTAssertNil(store.lastError)
        await provider.fail()
        await refresh.value

        XCTAssertFalse(store.isRefreshing)
        XCTAssertNil(store.snapshot)
        XCTAssertEqual(store.lastError, TestUsageError.unavailable.localizedDescription)
    }

    func testFailureKeepsLastSuccessfulSnapshotAndTimestamp() async {
        let provider = ControlledUsageProvider()
        let store = UsageStore(provider: provider)
        let initial = snapshot(usedPercent: 20)
        let first = Task { await store.refresh() }
        await provider.waitForCall(1)
        await provider.succeed(initial)
        await first.value

        let refresh = Task { await store.refresh() }
        await provider.waitForCall(2)
        await provider.fail()
        await refresh.value

        XCTAssertFalse(store.isRefreshing)
        XCTAssertEqual(store.snapshot?.primary?.usedPercent, 20)
        XCTAssertEqual(store.snapshot?.updatedAt, initial.updatedAt)
        XCTAssertNotNil(store.lastError)
    }

    func testConcurrentRefreshOnlyRequestsOnce() async {
        let provider = ControlledUsageProvider()
        let store = UsageStore(provider: provider)
        let first = Task { await store.refresh() }
        await provider.waitForCall(1)

        await store.refresh()
        let callCount = await provider.callCount
        XCTAssertEqual(callCount, 1)
        XCTAssertTrue(store.isRefreshing)

        await provider.succeed(snapshot(usedPercent: 30))
        await first.value
        XCTAssertFalse(store.isRefreshing)
        XCTAssertEqual(store.snapshot?.primary?.usedPercent, 30)
    }

    func testRetryClearsErrorWhileRunningAndRecoversOnSuccess() async {
        let provider = ControlledUsageProvider()
        let store = UsageStore(provider: provider)
        let first = Task { await store.refresh() }
        await provider.waitForCall(1)
        await provider.fail()
        await first.value
        XCTAssertNotNil(store.lastError)

        let retry = Task { await store.refresh() }
        await provider.waitForCall(2)
        XCTAssertTrue(store.isRefreshing)
        XCTAssertNil(store.lastError)

        let recovered = snapshot(usedPercent: 12, updatedAt: 1_800_000_100)
        await provider.succeed(recovered)
        await retry.value

        XCTAssertFalse(store.isRefreshing)
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.snapshot?.primary?.remainingPercent, 88)
        XCTAssertEqual(store.snapshot?.updatedAt, recovered.updatedAt)
    }

    func testAutomaticRefreshStartsWithoutOpeningCardAndKeepsPolling() async {
        let provider = ControlledUsageProvider()
        let timer = ControlledRefreshTimer()
        let store = UsageStore(provider: provider, sleep: { try await timer.sleep($0) })
        store.startAutomaticRefresh()
        let initialDelay = await timer.waitForSchedule(1)
        XCTAssertEqual(initialDelay, 0)
        await timer.fireLatest()
        await provider.waitForCall(1)
        await provider.succeed(snapshot(usedPercent: 20))

        let compactDelay = await timer.waitForSchedule(2)
        XCTAssertEqual(compactDelay, 30, accuracy: 0.1)
        await timer.fireLatest()
        await provider.waitForCall(2)
        await provider.succeed(snapshot(usedPercent: 31))
        _ = await timer.waitForSchedule(3)
        XCTAssertEqual(store.snapshot?.primary?.remainingPercent, 69)
        await store.shutdown()
    }

    func testOpeningFreshCardUsesTenSecondIntervalAndStaleCardRefreshesImmediately() async {
        let provider = ControlledUsageProvider()
        let timer = ControlledRefreshTimer()
        var date = Date(timeIntervalSince1970: 1_800_000_000)
        let store = UsageStore(provider: provider, now: { date }, sleep: { try await timer.sleep($0) })
        let first = Task { await store.refresh() }
        await provider.waitForCall(1)
        await provider.succeed(snapshot(usedPercent: 20))
        await first.value
        store.startAutomaticRefresh()
        _ = await timer.waitForSchedule(1)
        store.setExpanded(true)
        let freshDelay = await timer.waitForSchedule(2)
        XCTAssertEqual(freshDelay, 10)
        let calls = await provider.callCount
        XCTAssertEqual(calls, 1)

        store.setExpanded(false)
        _ = await timer.waitForSchedule(3)
        date += 6
        store.setExpanded(true)
        let staleDelay = await timer.waitForSchedule(4)
        XCTAssertEqual(staleDelay, 0)
        await timer.fireLatest()
        await provider.waitForCall(2)
        await provider.succeed(snapshot(usedPercent: 23))
        _ = await timer.waitForSchedule(5)
        XCTAssertEqual(store.snapshot?.primary?.usedPercent, 23)
        await store.shutdown()
    }

    func testFailuresBackOffAndWakeRefreshesImmediately() async {
        let provider = ControlledUsageProvider()
        let timer = ControlledRefreshTimer()
        let store = UsageStore(provider: provider, sleep: { try await timer.sleep($0) })
        store.startAutomaticRefresh()
        _ = await timer.waitForSchedule(1)
        for (index, delay) in [30.0, 60.0, 120.0, 120.0].enumerated() {
            await timer.fireLatest()
            await provider.waitForCall(index + 1)
            await provider.fail()
            let scheduledDelay = await timer.waitForSchedule(index + 2)
            XCTAssertEqual(scheduledDelay, delay, accuracy: 0.1)
        }

        store.suspendAutomaticRefresh()
        store.resumeAutomaticRefresh()
        let wakeDelay = await timer.waitForSchedule(6)
        XCTAssertEqual(wakeDelay, 0)
        await timer.fireLatest()
        await provider.waitForCall(5)
        await provider.succeed(snapshot(usedPercent: 12))
        let recoveredDelay = await timer.waitForSchedule(7)
        XCTAssertEqual(recoveredDelay, 30, accuracy: 0.1)
        XCTAssertNil(store.lastError)
        await store.shutdown()
    }

    func testWakeDuringCancelledRequestDiscardsOldResultAndReadsAgain() async {
        let provider = ControlledUsageProvider()
        let timer = ControlledRefreshTimer()
        let store = UsageStore(provider: provider, sleep: { try await timer.sleep($0) })
        store.startAutomaticRefresh()
        _ = await timer.waitForSchedule(1)
        await timer.fireLatest()
        await provider.waitForCall(1)
        store.suspendAutomaticRefresh()
        store.resumeAutomaticRefresh()
        await provider.succeed(snapshot(usedPercent: 90))
        let wakeDelay = await timer.waitForSchedule(2)
        XCTAssertEqual(wakeDelay, 0)
        XCTAssertNil(store.snapshot)
        XCTAssertNil(store.lastError)
        await timer.fireLatest()
        await provider.waitForCall(2)
        await provider.succeed(snapshot(usedPercent: 10))
        _ = await timer.waitForSchedule(3)
        XCTAssertEqual(store.snapshot?.primary?.remainingPercent, 90)
        await store.shutdown()
    }

    func testQuotaResetSchedulesAnEarlierRead() async {
        let provider = ControlledUsageProvider()
        let timer = ControlledRefreshTimer()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let store = UsageStore(provider: provider, now: { date }, sleep: { try await timer.sleep($0) })
        store.startAutomaticRefresh()
        _ = await timer.waitForSchedule(1)
        await timer.fireLatest()
        await provider.waitForCall(1)
        await provider.succeed(UsageSnapshot(providerName: "Codex", planName: "pro",
            primary: UsageWindow(usedPercent: 99, resetDate: date.addingTimeInterval(3), durationMinutes: 300),
            updatedAt: date))
        let delay = await timer.waitForSchedule(2)
        XCTAssertEqual(delay, 4)
        await store.shutdown()
    }

    func testShutdownClosesProviderAndPreventsFurtherRefresh() async {
        let provider = ControlledUsageProvider()
        let timer = ControlledRefreshTimer()
        let store = UsageStore(provider: provider, sleep: { try await timer.sleep($0) })
        store.startAutomaticRefresh()
        _ = await timer.waitForSchedule(1)
        await store.shutdown()
        await timer.fireLatest()
        store.resumeAutomaticRefresh()
        await store.refresh()
        let calls = await provider.callCount
        let shutdowns = await provider.shutdownCount
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(shutdowns, 1)
    }
}

private enum TestUsageError: LocalizedError, Sendable {
    case unavailable

    var errorDescription: String? { "暂时无法读取用量，请重试。" }
}

private actor ControlledUsageProvider: CodexUsageProviding {
    private(set) var callCount = 0
    private(set) var shutdownCount = 0
    private var pending: [CheckedContinuation<UsageSnapshot, any Error>] = []
    private var callWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func fetchUsage() async throws -> UsageSnapshot {
        callCount += 1
        let ready = callWaiters.filter { $0.count <= callCount }
        callWaiters.removeAll { $0.count <= callCount }
        for waiter in ready { waiter.continuation.resume() }
        return try await withCheckedThrowingContinuation { continuation in
            pending.append(continuation)
        }
    }

    func waitForCall(_ count: Int) async {
        guard callCount < count else { return }
        await withCheckedContinuation { continuation in
            callWaiters.append((count, continuation))
        }
    }

    func succeed(_ snapshot: UsageSnapshot) {
        pending.removeFirst().resume(returning: snapshot)
    }

    func fail() {
        pending.removeFirst().resume(throwing: TestUsageError.unavailable)
    }

    func shutdown() async {
        shutdownCount += 1
    }
}

private actor ControlledRefreshTimer {
    private var delays: [TimeInterval] = []
    private var pending: [(UUID, CheckedContinuation<Void, any Error>)] = []
    private var waiters: [(Int, CheckedContinuation<TimeInterval, Never>)] = []

    func sleep(_ delay: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                pending.append((id, continuation))
                delays.append(delay)
                let ready = waiters.filter { $0.0 <= delays.count }
                waiters.removeAll { $0.0 <= delays.count }
                for (count, waiter) in ready { waiter.resume(returning: delays[count - 1]) }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func waitForSchedule(_ count: Int) async -> TimeInterval {
        if delays.count >= count { return delays[count - 1] }
        return await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func fireLatest() {
        guard let (_, continuation) = pending.popLast() else { return }
        continuation.resume()
    }

    private func cancel(_ id: UUID) {
        guard let index = pending.firstIndex(where: { $0.0 == id }) else { return }
        pending.remove(at: index).1.resume(throwing: CancellationError())
    }
}
