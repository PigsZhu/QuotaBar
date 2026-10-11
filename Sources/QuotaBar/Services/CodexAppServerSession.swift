import Foundation
import Darwin

/// A reusable, read-only connection. Only the locally launched child (server or
/// transparent proxy) belongs to QuotaBar; a shared desktop daemon is never stopped.
final class CodexAppServerSession: @unchecked Sendable {
    private let explicitLaunches: [Launch]?
    private let environment: [String: String]?
    private let timeout: TimeInterval
    // All process, handle and response-buffer access is serialized by ioLock.
    private let ioLock = NSLock()
    private let lifecycleLock = NSLock()
    private var generation: UInt64 = 0
    private var isClosing = false
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var nextID = 1

    struct Launch: Sendable {
        let executableURL: URL
        let arguments: [String]
    }

    init(executableURL: URL? = nil, arguments: [String]? = nil,
         environment: [String: String]? = nil, timeout: TimeInterval = 12) {
        explicitLaunches = executableURL.map {
            [Launch(executableURL: $0, arguments: arguments ?? ["app-server", "--stdio"])]
        }
        self.environment = environment
        self.timeout = timeout
    }

    init(launches: [Launch], environment: [String: String]? = nil, timeout: TimeInterval = 12) {
        explicitLaunches = launches
        self.environment = environment
        self.timeout = timeout
    }

    deinit { closeConnection() }

    func readUsageResult() throws -> [String: Any] {
        try Task.checkCancellation()
        guard timeout.isFinite, timeout > 0 else { throw CodexUsageError.timeout }
        let requestGeneration = lifecycleLock.withLock { generation }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        // A queued read remains cancellable and shares the same bounded deadline.
        while !ioLock.try() {
            try checkRequest(deadline: deadline, generation: requestGeneration)
            Thread.sleep(forTimeInterval: 0.01)
        }
        defer { ioLock.unlock() }
        do {
            try checkRequest(deadline: deadline, generation: requestGeneration)
            if process?.isRunning != true {
                closeConnection()
                try connect(deadline: deadline, generation: requestGeneration)
            }
            let id = nextID
            nextID += 1
            try write(["id": id, "method": "account/rateLimits/read", "params": NSNull()],
                      deadline: deadline, generation: requestGeneration)
            return try readResponse(id: id, deadline: deadline, generation: requestGeneration)
        } catch {
            // No potentially stale response is carried into the next attempt.
            closeConnection()
            throw error
        }
    }

    /// Interrupt an in-flight read, release our child, and allow a later reconnect.
    func shutdown() {
        lifecycleLock.withLock {
            generation &+= 1
            isClosing = true
        }
        ioLock.lock()
        closeConnection()
        lifecycleLock.withLock { isClosing = false }
        ioLock.unlock()
    }

    /// Desktop bundles do not depend on Finder inheriting a shell's PATH.
    static func preferredLaunches(environment: [String: String] = ProcessInfo.processInfo.environment,
                                  bundledCandidates: [URL]? = nil,
                                  applicationBundles: [URL]? = nil) -> [Launch] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let applications = applicationBundles ?? [
            URL(fileURLWithPath: "/Applications/ChatGPT.app"),
            URL(fileURLWithPath: "/Applications/Codex.app"),
            home.appendingPathComponent("Applications/ChatGPT.app"),
            home.appendingPathComponent("Applications/Codex.app")
        ]
        let candidates = bundledCandidates ?? applications.flatMap { application in
            // New desktop releases embed a signed CLI app; retain the previous
            // layout for machines that have not updated their Codex installation.
            ["Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
             "Contents/Resources/codex"].map { application.appendingPathComponent($0) }
        }
        let pathDirectories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin"]
        let executable = (candidates + pathDirectories.map {
            URL(fileURLWithPath: $0).appendingPathComponent("codex")
        }).first { FileManager.default.isExecutableFile(atPath: $0.path) }
        let commandPrefix = executable == nil ? ["codex"] : []
        let executableURL = executable ?? URL(fileURLWithPath: "/usr/bin/env")
        let codexHome = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".codex")
        let socket = codexHome.appendingPathComponent("app-server-control/app-server-control.sock")
        var launches: [Launch] = []
        if let attributes = try? FileManager.default.attributesOfItem(atPath: socket.path),
           attributes[.type] as? FileAttributeType == .typeSocket {
            launches.append(Launch(executableURL: executableURL,
                                   arguments: commandPrefix + ["app-server", "proxy", "--sock", socket.path]))
        }
        launches.append(Launch(executableURL: executableURL,
                               arguments: commandPrefix + ["app-server", "--stdio"]))
        return launches
    }

    private func connect(deadline: TimeInterval, generation: UInt64) throws {
        let launches = explicitLaunches
            ?? Self.preferredLaunches(environment: environment ?? ProcessInfo.processInfo.environment)
        guard !launches.isEmpty else { throw CodexUsageError.launchFailed }
        for (index, launch) in launches.enumerated() {
            // A present but hung shared socket must leave time for the fallback.
            let handshakeDeadline = index < launches.count - 1
                ? min(deadline, ProcessInfo.processInfo.systemUptime + 2)
                : deadline
            do {
                try checkRequest(deadline: handshakeDeadline, generation: generation)
                try start(launch)
                let id = nextID
                nextID += 1
                try write([
                    "id": id, "method": "initialize",
                    "params": ["clientInfo": ["name": "QuotaBar", "version": "0.1.0"]]
                ], deadline: handshakeDeadline, generation: generation)
                _ = try readResponse(id: id, deadline: handshakeDeadline, generation: generation)
                try write(["method": "initialized"], deadline: handshakeDeadline, generation: generation)
                return
            } catch {
                closeConnection()
                // A stale control socket must not prevent the standalone fallback.
                // Cancellation and the shared request deadline always take priority.
                try checkRequest(deadline: deadline, generation: generation)
                if index == launches.count - 1 { throw error }
            }
        }
    }

    private func start(_ launch: Launch) throws {
        let child = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        child.executableURL = launch.executableURL
        child.arguments = launch.arguments
        // Explicitly setting nil clears the environment on this toolchain.
        if let environment { child.environment = environment }
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        do {
            try child.run()
        } catch {
            try? stdin.fileHandleForReading.close()
            try? stdin.fileHandleForWriting.close()
            try? stdout.fileHandleForReading.close()
            try? stdout.fileHandleForWriting.close()
            throw CodexUsageError.launchFailed
        }
        process = child
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        // Retaining the child's endpoints in the parent masks EOF.
        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        for descriptor in [stdin.fileHandleForWriting.fileDescriptor, stdout.fileHandleForReading.fileDescriptor] {
            let flags = fcntl(descriptor, F_GETFL)
            guard flags != -1, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
                throw CodexUsageError.connectionClosed
            }
        }
        guard fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw CodexUsageError.connectionClosed
        }
    }

    private func checkRequest(deadline: TimeInterval, generation requestGeneration: UInt64) throws {
        try Task.checkCancellation()
        guard lifecycleLock.withLock({ !isClosing && generation == requestGeneration }) else {
            throw CancellationError()
        }
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw CodexUsageError.timeout }
    }

    private func write(_ object: [String: Any], deadline: TimeInterval, generation: UInt64) throws {
        guard let input, var data = try? JSONSerialization.data(withJSONObject: object) else {
            throw CodexUsageError.malformedResponse
        }
        data.append(0x0A)
        var offset = 0
        while offset < data.count {
            try checkRequest(deadline: deadline, generation: generation)
            let count = data.withUnsafeBytes { bytes in
                Darwin.write(input.fileDescriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    try waitForIO(input.fileDescriptor, events: Int16(POLLOUT),
                                  deadline: deadline, generation: generation)
                    continue
                }
                throw CodexUsageError.connectionClosed
            }
            guard count > 0 else { throw CodexUsageError.connectionClosed }
            offset += count
        }
    }

    private func readResponse(id: Int, deadline: TimeInterval, generation: UInt64) throws -> [String: Any] {
        guard let output else { throw CodexUsageError.connectionClosed }
        while true {
            try checkRequest(deadline: deadline, generation: generation)
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if line.isEmpty { continue }
                guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                    throw CodexUsageError.malformedResponse
                }
                // A persistent connection may deliver notifications between reads.
                guard (object["id"] as? NSNumber)?.intValue == id else { continue }
                if let error = object["error"], !(error is NSNull) {
                    throw CodexUsageError.fromServerError(error)
                }
                guard let result = object["result"] as? [String: Any] else {
                    throw CodexUsageError.malformedResponse
                }
                return result
            }
            try waitForIO(output.fileDescriptor, events: Int16(POLLIN),
                          deadline: deadline, generation: generation)
            var chunk = [UInt8](repeating: 0, count: 8_192)
            let count = chunk.withUnsafeMutableBytes { bytes in
                Darwin.read(output.fileDescriptor, bytes.baseAddress, bytes.count)
            }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                throw CodexUsageError.connectionClosed
            }
            guard count > 0 else { throw CodexUsageError.connectionClosed }
            guard buffer.count + count <= 1_048_576 else { throw CodexUsageError.malformedResponse }
            buffer.append(contentsOf: chunk.prefix(count))
        }
    }

    private func waitForIO(_ descriptor: Int32, events: Int16,
                           deadline: TimeInterval, generation: UInt64) throws {
        while true {
            try checkRequest(deadline: deadline, generation: generation)
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            let milliseconds = Int32(max(0, min(100, ceil(remaining * 1_000))))
            var state = pollfd(fd: descriptor, events: events, revents: 0)
            let ready = Darwin.poll(&state, 1, milliseconds)
            let pollError = errno
            try checkRequest(deadline: deadline, generation: generation)
            if ready == 0 { continue }
            if ready < 0 {
                if pollError == EINTR { continue }
                throw CodexUsageError.connectionClosed
            }
            if state.revents & Int16(POLLNVAL) != 0 { throw CodexUsageError.connectionClosed }
            return
        }
    }

    private func closeConnection() {
        try? input?.close()
        if let process { Self.stop(process) }
        try? output?.close()
        process = nil
        input = nil
        output = nil
        buffer.removeAll(keepingCapacity: false)
        nextID = 1
    }

    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        _ = Darwin.kill(process.processIdentifier, SIGTERM)
        waitForExit(process, for: 0.2)
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            waitForExit(process, for: 0.5)
        }
    }

    private static func waitForExit(_ process: Process, for duration: TimeInterval) {
        let deadline = ProcessInfo.processInfo.systemUptime + duration
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
}
