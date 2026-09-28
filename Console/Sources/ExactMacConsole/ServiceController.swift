import Foundation
import os

/// The interface for controlling the background ExactMac daemon.
public protocol ServiceControlling: Sendable {
    /// Returns true if the service is configured and enabled in the system service manager.
    func isServiceEnabled() async throws -> Bool

    /// Changes the persistent enable/disable state of the service.
    func setServiceEnabled(_ enabled: Bool) async throws
}

/// Abstract command executor for launchctl commands.
public protocol LaunchctlExecuting: Sendable {
    func execute(arguments: [String]) async throws -> (exitCode: Int32, stdout: String, stderr: String)
}

/// Production executor that runs `/bin/launchctl`.
public final class ProcessLaunchctlExecutor: LaunchctlExecuting, Sendable {
    public init() {}

    /// BOTH PIPES ARE DRAINED ON OTHER THREADS, AND THE WAIT COMES LAST.
    ///
    /// The order is the whole implementation. A child that fills a pipe buffer blocks
    /// writing and therefore never exits, so reading after `waitUntilExit()` deadlocks: the
    /// caller hangs, no error is produced, and the control the operator pressed appears to do
    /// nothing. `launchctl print` against a real domain can emit more than a pipe buffer, and
    /// a hang with no error is the worst possible symptom for a service the operator is
    /// trying to turn OFF.
    public func execute(arguments: [String]) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        // `Task.detached` AROUND A SYNCHRONOUS FUNCTION, and the split is deliberate: every
        // step below blocks a thread by design, and doing that on a cooperative-pool thread
        // would starve the pool the console's UI runs on. Putting the blocking in a plain
        // function is also what makes the compiler accept it at all — `DispatchGroup.wait()`
        // and `waitUntilExit()` are both unavailable inside an `async` context.
        try await Task.detached { try Self.runBlocking("/bin/launchctl", arguments) }.value
    }

    /// The blocking half, with its executable as a parameter so the drain-then-wait ordering
    /// can be tested against a child that genuinely outruns a pipe buffer. Everything a
    /// caller can reach still goes through `execute`, and only launchctl can be reached that
    /// way — this parameter is not a configuration surface.
    static func runBlocking(
        _ executable: String,
        _ arguments: [String],
    ) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()

        let collected = OutputCollector()
        let group = DispatchGroup()
        for (pipe, isStandardOutput) in [(outPipe, true), (errPipe, false)] {
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                collected.store(
                    String(data: data, encoding: .utf8) ?? "",
                    isStandardOutput: isStandardOutput,
                )
            }
        }
        process.waitUntilExit()
        group.wait()
        return (process.terminationStatus, collected.stdout, collected.stderr)
    }
}

/// The two captured streams, written from two threads and read after both have finished.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = ""
    private var err = ""

    var stdout: String {
        lock.withLock { out }
    }

    var stderr: String {
        lock.withLock { err }
    }

    func store(_ value: String, isStandardOutput: Bool) {
        lock.withLock {
            if isStandardOutput {
                out = value
            } else {
                err = value
            }
        }
    }
}

/// Controls the ExactMac LaunchAgent via Apple's native `launchctl` interface.
///
/// State persistence is managed through launchd's per-user configuration domain
/// (`com.apple.launchd.peruser.<uid>` accessed via `launchctl enable`/`disable`),
/// which natively survives reboots and user logouts.
public final class LaunchdServiceController: ServiceControlling, Sendable {
    public let serviceLabel: String
    public let launchDomain: String
    public let plistPath: String
    private let executor: any LaunchctlExecuting
    private let logger = Logger(
        subsystem: "io.github.joeycumines.exactmac.console",
        category: "service-controller",
    )

    public init(
        serviceLabel: String = "io.github.joeycumines.exactmac.server",
        launchDomain: String? = nil,
        plistPath: String? = nil,
        executor: any LaunchctlExecuting = ProcessLaunchctlExecutor(),
    ) {
        self.serviceLabel = serviceLabel
        let uid = getuid()
        self.launchDomain = launchDomain ?? "gui/\(uid)"
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.plistPath = plistPath ?? "\(home)/Library/LaunchAgents/\(serviceLabel).plist"
        self.executor = executor
    }

    public var serviceTarget: String {
        "\(launchDomain)/\(serviceLabel)"
    }

    public func isServiceEnabled() async throws -> Bool {
        let disabledResult = try await executor.execute(arguments: ["print-disabled", launchDomain])
        if disabledResult.exitCode == 0 {
            let lines = disabledResult.stdout.components(separatedBy: .newlines)
            for line in lines {
                if line.contains("\"\(serviceLabel)\"") {
                    if line.contains("disabled") {
                        return false
                    } else if line.contains("enabled") {
                        return true
                    }
                }
            }
        }

        let printResult = try await executor.execute(arguments: ["print", serviceTarget])
        return printResult.exitCode == 0
    }

    public func setServiceEnabled(_ enabled: Bool) async throws {
        if enabled {
            let enableResult = try await executor.execute(arguments: ["enable", serviceTarget])
            if enableResult.exitCode != 0 {
                logger.error("launchctl enable failed: \(enableResult.stderr, privacy: .public)")
                throw ServiceControllerError.commandFailed(
                    command: "enable",
                    exitCode: enableResult.exitCode,
                    message: enableResult.stderr,
                )
            }

            let printResult = try await executor.execute(arguments: ["print", serviceTarget])
            if printResult.exitCode != 0 {
                let bootResult = try await executor.execute(arguments: ["bootstrap", launchDomain, plistPath])
                if bootResult.exitCode != 0 {
                    logger.notice("launchctl bootstrap returned \(bootResult.exitCode, privacy: .public), trying kickstart")
                    _ = try await executor.execute(arguments: ["kickstart", serviceTarget])
                }
            } else {
                _ = try await executor.execute(arguments: ["kickstart", serviceTarget])
            }
            logger.info("Service enabled and started via launchd target: \(self.serviceTarget, privacy: .public)")
        } else {
            let disableResult = try await executor.execute(arguments: ["disable", serviceTarget])
            if disableResult.exitCode != 0 {
                logger.error("launchctl disable failed: \(disableResult.stderr, privacy: .public)")
                throw ServiceControllerError.commandFailed(
                    command: "disable",
                    exitCode: disableResult.exitCode,
                    message: disableResult.stderr,
                )
            }

            let bootoutResult = try await executor.execute(arguments: ["bootout", serviceTarget])
            if bootoutResult.exitCode != 0 {
                logger.notice("launchctl bootout returned \(bootoutResult.exitCode, privacy: .public)")
            }
            logger.info("Service disabled and stopped via launchd target: \(self.serviceTarget, privacy: .public)")
        }
    }
}

public enum ServiceControllerError: Error, LocalizedError, Sendable, Equatable {
    case commandFailed(command: String, exitCode: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case let .commandFailed(command, exitCode, message):
            "Command '\(command)' failed with exit code \(exitCode): \(message)"
        }
    }
}
