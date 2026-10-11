import Foundation
import XCTest
@testable import QuotaBar

final class CodexUsageRecoveryTests: XCTestCase {
    private func snapshot() -> UsageSnapshot {
        UsageSnapshot(providerName: "Codex", planName: nil,
                      primary: UsageWindow(usedPercent: 4, resetDate: nil, durationMinutes: 10_080),
                      updatedAt: .now)
    }

    func testTransientNetworkFailureRetriesAndRecovers() async throws {
        let attempts = Attempts([.failure(.networkUnavailable), .success(snapshot())])
        let provider = CodexAppServerUsageProvider(retryDelay: .zero) {
            try await attempts.next()
        }

        let result = try await provider.fetchUsage()
        let count = await attempts.count
        XCTAssertEqual(count, 2)
        XCTAssertEqual(result.primary?.remainingPercent, 96)
    }

    func testRetryIsBoundedToTwoAttempts() async {
        let attempts = Attempts([.failure(.timeout), .failure(.networkUnavailable)])
        let provider = CodexAppServerUsageProvider(retryDelay: .zero) {
            try await attempts.next()
        }

        do {
            _ = try await provider.fetchUsage()
            XCTFail("The second failure must be reported")
        } catch {
            XCTAssertEqual(error as? CodexUsageError, .networkUnavailable)
        }
        let count = await attempts.count
        XCTAssertEqual(count, 2)
    }

    func testAuthenticationFailureIsNotRetried() async {
        let attempts = Attempts([.failure(.authenticationRequired)])
        let provider = CodexAppServerUsageProvider(retryDelay: .zero) {
            try await attempts.next()
        }

        do {
            _ = try await provider.fetchUsage()
            XCTFail("Login failure must be reported")
        } catch {
            XCTAssertEqual(error as? CodexUsageError, .authenticationRequired)
        }
        let count = await attempts.count
        XCTAssertEqual(count, 1)
    }

    func testCancellationIsNotRetriedAsNetworkFailure() async {
        let counter = Counter()
        let provider = CodexAppServerUsageProvider(retryDelay: .zero) {
            await counter.increment()
            throw CancellationError()
        }
        do {
            _ = try await provider.fetchUsage()
            XCTFail("Cancellation must propagate")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let count = await counter.count
        XCTAssertEqual(count, 1)
    }

    func testNetworkServerErrorHasActionableMessageWithoutRawPayload() {
        let error = CodexUsageError.fromServerError([
            "code": -32603,
            "message": "failed to fetch codex rate limits: error sending request for url (https://chatgpt.com/backend-api/wham/usage)"
        ])
        XCTAssertEqual(error, .networkUnavailable)
        XCTAssertTrue(error.localizedDescription.contains("重试"))
        XCTAssertFalse(error.localizedDescription.contains("https://"))
        XCTAssertFalse(error.localizedDescription.contains("-32603"))
        XCTAssertEqual(CodexUsageError.fromServerError(["message": "401 Unauthorized"]),
                       .authenticationRequired)
        XCTAssertEqual(CodexUsageError.fromServerError(["message": "request timed out"]), .timeout)
    }
}

private actor Attempts {
    private let outcomes: [Result<UsageSnapshot, CodexUsageError>]
    private(set) var count = 0

    init(_ outcomes: [Result<UsageSnapshot, CodexUsageError>]) {
        self.outcomes = outcomes
    }

    func next() throws -> UsageSnapshot {
        let index = count
        count += 1
        guard index < outcomes.count else { throw CodexUsageError.serviceUnavailable }
        return try outcomes[index].get()
    }
}

private actor Counter {
    private(set) var count = 0
    func increment() { count += 1 }
}
