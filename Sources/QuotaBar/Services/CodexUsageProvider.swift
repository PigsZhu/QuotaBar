import Foundation
import CoreFoundation

protocol CodexUsageProviding: Sendable {
    func fetchUsage() async throws -> UsageSnapshot
    func shutdown() async
}

extension CodexUsageProviding {
    func shutdown() async {}
}

/// Credentials stay with Codex; each attempt requests only the rate-limit snapshot.
struct CodexAppServerUsageProvider: CodexUsageProviding {
    private let readAttempt: @Sendable () async throws -> UsageSnapshot
    private let retryDelay: Duration
    private let closeSession: @Sendable () async -> Void

    init(retryDelay: Duration = .milliseconds(500),
         session: CodexAppServerSession = CodexAppServerSession()) {
        self.retryDelay = retryDelay
        readAttempt = { try await Self.readOnce(session: session) }
        closeSession = {
            await Task.detached(priority: .utility) { session.shutdown() }.value
        }
    }

    init(retryDelay: Duration = .milliseconds(500),
         readAttempt: @escaping @Sendable () async throws -> UsageSnapshot) {
        self.readAttempt = readAttempt
        self.retryDelay = retryDelay
        closeSession = {}
    }

    func shutdown() async { await closeSession() }

    func fetchUsage() async throws -> UsageSnapshot {
        try Task.checkCancellation()
        do {
            return try await readAttempt()
        } catch let error as CodexUsageError where error.isRetryable {
            // Only retry transient transport failures, once. Authentication and
            // protocol errors need action rather than another identical request.
            try await Task.sleep(for: retryDelay)
            try Task.checkCancellation()
            return try await readAttempt()
        }
    }

    private static func readOnce(session: CodexAppServerSession) async throws -> UsageSnapshot {
        let worker = Task.detached(priority: .utility) {
            do {
                return try decodeUsage(from: session.readUsageResult())
            } catch {
                session.shutdown()
                throw error
            }
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    static func decodeUsage(from result: [String: Any]) throws -> UsageSnapshot {
        let rateLimits: [String: Any]
        if let limitsByID = result["rateLimitsByLimitId"] as? [String: Any],
           let codexLimits = limitsByID["codex"] {
            guard let codexLimits = codexLimits as? [String: Any] else {
                throw CodexUsageError.malformedResponse
            }
            rateLimits = codexLimits
        } else if let legacyLimits = result["rateLimits"] as? [String: Any] {
            rateLimits = legacyLimits
        } else {
            throw CodexUsageError.malformedResponse
        }

        // Independent model buckets (for example Spark) are not Codex's quota.
        if let limitID = rateLimits["limitId"], !(limitID is NSNull),
           limitID as? String != "codex" {
            throw CodexUsageError.malformedResponse
        }
        guard rateLimits.keys.contains("primary") || rateLimits.keys.contains("secondary") else {
            throw CodexUsageError.malformedResponse
        }
        let windows = try ["primary", "secondary"].compactMap { key -> UsageWindow? in
            guard let value = rateLimits[key], !(value is NSNull) else { return nil }
            guard let window = value as? [String: Any] else {
                throw CodexUsageError.malformedResponse
            }
            return try decodeWindow(window)
        }

        return UsageSnapshot(
            providerName: "Codex",
            planName: rateLimits["planType"] as? String,
            primary: windows.first { $0.durationMinutes == 300 }
                ?? windows.first { $0.durationMinutes == 10_080 },
            updatedAt: .now
        )
    }

    private static func decodeWindow(_ json: [String: Any]) throws -> UsageWindow {
        guard let usedPercent = try number(json["usedPercent"]) else {
            throw CodexUsageError.malformedResponse
        }

        let resetDate = try number(json["resetsAt"])
            .map { Date(timeIntervalSince1970: $0.doubleValue) }
        let durationNumber = try number(json["windowDurationMins"])
        let duration = durationNumber.flatMap { Int(exactly: $0.doubleValue) }
        if durationNumber != nil && (duration == nil || duration! <= 0) {
            throw CodexUsageError.malformedResponse
        }

        return UsageWindow(
            usedPercent: usedPercent.intValue,
            resetDate: resetDate,
            durationMinutes: duration
        )
    }

    private static func number(_ value: Any?) throws -> NSNumber? {
        guard let value, !(value is NSNull) else { return nil }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else {
            throw CodexUsageError.malformedResponse
        }
        return number
    }
}

enum CodexUsageError: LocalizedError, Equatable {
    case connectionClosed
    case malformedResponse
    case launchFailed
    case timeout
    case networkUnavailable
    case authenticationRequired
    case serviceUnavailable

    var isRetryable: Bool {
        switch self {
        case .connectionClosed, .timeout, .networkUnavailable:
            true
        case .malformedResponse, .launchFailed, .authenticationRequired, .serviceUnavailable:
            false
        }
    }

    static func fromServerError(_ error: Any?) -> Self {
        let message = ((error as? [String: Any])?["message"] as? String ?? "").lowercased()
        if message.contains("unauthorized") || message.contains("not logged in")
            || message.contains("authentication") || message.contains("401") {
            return .authenticationRequired
        }
        if message.contains("timed out") || message.contains("timeout") {
            return .timeout
        }
        if message.contains("error sending request") || message.contains("connection")
            || message.contains("network") || message.contains("dns") {
            return .networkUnavailable
        }
        return .serviceUnavailable
    }

    var errorDescription: String? {
        switch self {
        case .connectionClosed:
            "与 Codex 的连接中断，请重试。"
        case .malformedResponse:
            "无法识别 Codex 用量数据，请更新 Codex 后重试。"
        case .launchFailed:
            "无法启动 Codex，请确认已安装 Codex App 或 CLI。"
        case .timeout:
            "读取用量超时，请重试。"
        case .networkUnavailable:
            "暂时无法连接用量服务，请检查网络后重试。"
        case .authenticationRequired:
            "请先在 Codex 登录，再重试。"
        case .serviceUnavailable:
            "Codex 用量服务暂不可用，请稍后重试。"
        }
    }
}
