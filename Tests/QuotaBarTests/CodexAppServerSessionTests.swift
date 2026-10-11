import Darwin
import Foundation
import XCTest
@testable import QuotaBar

final class CodexAppServerSessionTests: XCTestCase {
    func testDefaultSessionInheritsParentEnvironment() throws {
        let key = "QUOTABAR_TEST_ENV_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        setenv(key, "inherited", 1)
        defer { unsetenv(key) }
        let transport = session(script: """
        [ "$\(key)" = "inherited" ] || exit 9
        read -r request
        printf '%s\\n' '{"id":1,"result":{}}'
        read -r notification
        read -r request
        printf '%s\\n' '{"id":2,"result":{"inherited":true}}'
        """)
        let result = try transport.readUsageResult()
        XCTAssertEqual(result["inherited"] as? Bool, true)
    }

    private func session(script: String, timeout: TimeInterval = 2) -> CodexAppServerSession {
        CodexAppServerSession(executableURL: URL(fileURLWithPath: "/bin/sh"),
                              arguments: ["-c", script], timeout: timeout)
    }

    func testReadsJSONLHandshakeAndIgnoresNotifications() throws {
        let transport = session(script: #"""
        read -r request
        printf '%s\n' '{"method":"notice","params":{}}' '{"id":1,"result":{}}'
        read -r notification
        read -r request
        printf '%s\n' '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":4,"windowDurationMins":10080},"secondary":null}}}'
        """#)

        let snapshot = try CodexAppServerUsageProvider.decodeUsage(from: transport.readUsageResult())
        XCTAssertEqual(snapshot.primary?.durationMinutes, 10_080)
        XCTAssertEqual(snapshot.primary?.remainingPercent, 96)
    }

    func testClosedServerReturnsPromptly() {
        let transport = session(script: "read -r request; exit 0")
        let startedAt = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try transport.readUsageResult()) { error in
            XCTAssertEqual(error as? CodexUsageError, .connectionClosed)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - startedAt, 1.5)
    }

    func testHungServerTimesOutAndTerminatesItsProcess() throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-timeout-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let quotedPath = "'" + pidFile.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let transport = session(script: "trap '' TERM; printf '%s' \"$$\" > \(quotedPath); while :; do :; done",
                                timeout: 0.2)
        let startedAt = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try transport.readUsageResult()) { error in
            XCTAssertEqual(error as? CodexUsageError, .timeout)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - startedAt, 2)

        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        XCTAssertEqual(Darwin.kill(pid, 0), -1, "A timed-out app-server must not remain running")
        XCTAssertEqual(errno, ESRCH)
    }

    func testTwoReadsReuseOneProcessAndHandshake() throws {
        let transport = session(script: #"""
        read -r request
        printf '%s\n' '{"id":1,"result":{}}'
        read -r notification
        id=2
        while read -r request; do
            printf '{"id":%s,"result":{"pid":%s}}\n' "$id" "$$"
            id=$((id + 1))
        done
        """#)
        defer { transport.shutdown() }

        let first = try transport.readUsageResult()
        let second = try transport.readUsageResult()
        XCTAssertNotNil(first["pid"] as? Int32)
        XCTAssertEqual(first["pid"] as? Int32, second["pid"] as? Int32,
                       "Refreshes must reuse the initialized child and advance request IDs")
    }

    func testDisconnectedSessionCanReconnectOnNextRead() throws {
        let transport = session(script: #"""
        read -r request
        printf '%s\n' '{"id":1,"result":{}}'
        read -r notification
        read -r request
        printf '{"id":2,"result":{"pid":%s}}\n' "$$"
        read -r request
        exit 0
        """#)
        defer { transport.shutdown() }
        let firstPID = try XCTUnwrap(transport.readUsageResult()["pid"] as? Int32)
        XCTAssertThrowsError(try transport.readUsageResult()) { error in
            XCTAssertEqual(error as? CodexUsageError, .connectionClosed)
        }
        let recoveredPID = try XCTUnwrap(transport.readUsageResult()["pid"] as? Int32)
        XCTAssertNotEqual(firstPID, recoveredPID)
    }

    func testShutdownStopsChildAndAllowsLaterReconnect() throws {
        let transport = session(script: #"""
        read -r request
        printf '%s\n' '{"id":1,"result":{}}'
        read -r notification
        read -r request
        printf '{"id":2,"result":{"pid":%s}}\n' "$$"
        while read -r request; do :; done
        """#)
        defer { transport.shutdown() }
        let firstPID = try XCTUnwrap(transport.readUsageResult()["pid"] as? Int32)
        transport.shutdown()
        XCTAssertEqual(Darwin.kill(firstPID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        let secondPID = try XCTUnwrap(transport.readUsageResult()["pid"] as? Int32)
        XCTAssertNotEqual(firstPID, secondPID)
    }

    func testCancellationCleansUpAnInFlightRead() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-cancel-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let quotedPath = "'" + pidFile.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let transport = session(script: "printf '%s' \"$$\" > \(quotedPath); read -r request; while read -r request; do :; done",
                                timeout: 8)
        let worker = Task.detached { _ = try transport.readUsageResult() }
        defer { worker.cancel(); transport.shutdown() }
        let pid = try await waitForPID(at: pidFile)
        let startedAt = ProcessInfo.processInfo.systemUptime
        worker.cancel()
        do {
            try await worker.value
            XCTFail("Cancellation must propagate")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - startedAt, 1)
        XCTAssertEqual(Darwin.kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testShutdownInterruptsAnInFlightRead() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-shutdown-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let quotedPath = "'" + pidFile.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let transport = session(script: "printf '%s' \"$$\" > \(quotedPath); read -r request; while read -r request; do :; done",
                                timeout: 8)
        let worker = Task.detached { _ = try transport.readUsageResult() }
        defer { worker.cancel(); transport.shutdown() }
        let pid = try await waitForPID(at: pidFile)
        let startedAt = ProcessInfo.processInfo.systemUptime
        transport.shutdown()
        do {
            try await worker.value
            XCTFail("Shutdown must interrupt the pending request")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - startedAt, 1)
        XCTAssertEqual(Darwin.kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testBundledExecutableIsPreferredWithoutShellPath() throws {
        let launches = CodexAppServerSession.preferredLaunches(
            environment: ["PATH": "", "CODEX_HOME": "/quotabar-no-shared-socket"],
            bundledCandidates: [URL(fileURLWithPath: "/bin/sh")]
        )
        XCTAssertEqual(launches.count, 1)
        XCTAssertEqual(launches.first?.executableURL.path, "/bin/sh")
        XCTAssertEqual(launches.first?.arguments, ["app-server", "--stdio"])
    }

    func testNestedDesktopCLIIsFoundWithoutShellPath() throws {
        try checkDesktopLayout("Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
    }

    func testLegacyDesktopCLIStillWorksWithoutShellPath() throws {
        try checkDesktopLayout("Contents/Resources/codex")
    }

    private func checkDesktopLayout(_ relativePath: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["Applications/ChatGPT.app", "Applications/Codex.app",
                     "User/Applications/ChatGPT.app", "User/Applications/Codex.app"] {
            let application = root.appendingPathComponent(name)
            let executable = application.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            let launches = CodexAppServerSession.preferredLaunches(
                environment: ["PATH": "", "CODEX_HOME": root.appendingPathComponent("no-socket").path],
                applicationBundles: [application])
            XCTAssertEqual(launches.first?.executableURL, executable)
            XCTAssertEqual(launches.first?.arguments, ["app-server", "--stdio"])
        }
    }

    func testHungSharedHandshakeFallsBackWithinOverallDeadline() throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-proxy-timeout-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let quotedPath = "'" + pidFile.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let transport = CodexAppServerSession(launches: [
            .init(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c",
                "printf '%s' \"$$\" > \(quotedPath); while read -r request; do :; done"]),
            .init(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", #"""
                read -r request
                printf '%s\n' '{"id":1,"result":{}}'
                read -r notification
                read -r request
                printf '%s\n' '{"id":2,"result":{"fallback":true}}'
                while read -r request; do :; done
                """#])
        ], timeout: 4)
        defer { transport.shutdown() }
        let startedAt = ProcessInfo.processInfo.systemUptime
        let result = try transport.readUsageResult()
        XCTAssertEqual(result["fallback"] as? Bool, true)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - startedAt, 3.5)
        let proxyPID = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        XCTAssertEqual(Darwin.kill(proxyPID, 0), -1, "The hung proxy must be released")
        XCTAssertEqual(errno, ESRCH)
    }

    private func waitForPID(at url: URL) async throws -> Int32 {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let text = try? String(contentsOf: url, encoding: .utf8), let pid = Int32(text) {
                return pid
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CodexUsageError.timeout
    }

    func testLaunchFailureIsReadable() {
        let transport = CodexAppServerSession(
            executableURL: URL(fileURLWithPath: "/quotabar-test-missing-executable"),
            arguments: [], timeout: 0.2
        )
        XCTAssertThrowsError(try transport.readUsageResult()) { error in
            XCTAssertEqual(error as? CodexUsageError, .launchFailed)
        }
    }
}
