@testable import ExactMacConsole
import Foundation
import Synchronization
import Testing

/// A thread-safe mock executor for testing launchctl interactions and simulating
/// launchd's persistent configuration across simulated reboots.
final class MockLaunchctlExecutor: LaunchctlExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCalls: [[String]] = []
    private var disabledServices: Set<String> = []
    private var loadedServices: Set<String> = []
    var customResponses: [String: (Int32, String, String)] = [:]

    init(initiallyEnabled: Bool = true, serviceLabel: String = "io.github.joeycumines.exactmac.server") {
        if initiallyEnabled {
            loadedServices.insert(serviceLabel)
        } else {
            disabledServices.insert(serviceLabel)
        }
    }

    func execute(arguments: [String]) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let (_, custom, first): (String, (Int32, String, String)?, String?) = lock.withLock {
            recordedCalls.append(arguments)
            let key = arguments.joined(separator: " ")
            return (key, customResponses[key], arguments.first)
        }
        if let custom {
            return custom
        }

        guard let first else {
            return (0, "", "")
        }

        return lock.withLock {
            switch first {
            case "print-disabled":
                var lines = ["\tdisabled services = {"]
                for label in disabledServices {
                    lines.append("\t\t\"\(label)\" => disabled")
                }
                for label in loadedServices where !disabledServices.contains(label) {
                    lines.append("\t\t\"\(label)\" => enabled")
                }
                lines.append("\t}")
                return (0, lines.joined(separator: "\n"), "")

            case "print":
                guard let target = arguments.dropFirst().first else { return (1, "", "missing target") }
                let label = target.components(separatedBy: "/").last ?? target
                if loadedServices.contains(label) {
                    return (0, "\(target) = {\n\tstate = running\n}", "")
                } else {
                    return (1, "", "Could not find service \"\(target)\"")
                }

            case "disable":
                guard let target = arguments.dropFirst().first else { return (1, "", "missing target") }
                let label = target.components(separatedBy: "/").last ?? target
                disabledServices.insert(label)
                return (0, "", "")

            case "enable":
                guard let target = arguments.dropFirst().first else { return (1, "", "missing target") }
                let label = target.components(separatedBy: "/").last ?? target
                disabledServices.remove(label)
                return (0, "", "")

            case "bootout":
                guard let target = arguments.dropFirst().first else { return (1, "", "missing target") }
                let label = target.components(separatedBy: "/").last ?? target
                loadedServices.remove(label)
                return (0, "", "")

            case "bootstrap":
                guard arguments.count >= 3 else { return (1, "", "missing bootstrap arguments") }
                let plistPath = arguments[2]
                let label = URL(fileURLWithPath: plistPath).deletingPathExtension().lastPathComponent
                loadedServices.insert(label)
                disabledServices.remove(label)
                return (0, "", "")

            case "kickstart":
                return (0, "", "")

            default:
                return (0, "", "")
            }
        }
    }

    func getRecordedCalls() -> [[String]] {
        lock.withLock { recordedCalls }
    }
}

@Suite("Launchd persistent service control")
struct ServiceControllerTests {
    @Test
    func `status detects enabled service from print-disabled`() async throws {
        let executor = MockLaunchctlExecutor(initiallyEnabled: true)
        let controller = LaunchdServiceController(
            serviceLabel: "io.github.joeycumines.exactmac.server",
            launchDomain: "gui/501",
            plistPath: "/tmp/exactmac.plist",
            executor: executor,
        )

        let enabled = try await controller.isServiceEnabled()
        #expect(enabled == true)
    }

    @Test
    func `status detects disabled service from print-disabled`() async throws {
        let executor = MockLaunchctlExecutor(initiallyEnabled: false)
        let controller = LaunchdServiceController(
            serviceLabel: "io.github.joeycumines.exactmac.server",
            launchDomain: "gui/501",
            plistPath: "/tmp/exactmac.plist",
            executor: executor,
        )

        let enabled = try await controller.isServiceEnabled()
        #expect(enabled == false)
    }

    @Test
    func `disabling service invokes launchctl disable and bootout`() async throws {
        let executor = MockLaunchctlExecutor(initiallyEnabled: true)
        let controller = LaunchdServiceController(
            serviceLabel: "io.github.joeycumines.exactmac.server",
            launchDomain: "gui/501",
            plistPath: "/tmp/exactmac.plist",
            executor: executor,
        )

        try await controller.setServiceEnabled(false)

        let calls = executor.getRecordedCalls()
        #expect(calls.contains { $0 == ["disable", "gui/501/io.github.joeycumines.exactmac.server"] })
        #expect(calls.contains { $0 == ["bootout", "gui/501/io.github.joeycumines.exactmac.server"] })

        let postCheck = try await controller.isServiceEnabled()
        #expect(postCheck == false)
    }

    @Test
    func `enabling service invokes launchctl enable and bootstrap`() async throws {
        let executor = MockLaunchctlExecutor(initiallyEnabled: false)
        let controller = LaunchdServiceController(
            serviceLabel: "io.github.joeycumines.exactmac.server",
            launchDomain: "gui/501",
            plistPath: "/tmp/io.github.joeycumines.exactmac.server.plist",
            executor: executor,
        )

        try await controller.setServiceEnabled(true)

        let calls = executor.getRecordedCalls()
        #expect(calls.contains { $0 == ["enable", "gui/501/io.github.joeycumines.exactmac.server"] })
        #expect(calls.contains { $0 == ["bootstrap", "gui/501", "/tmp/io.github.joeycumines.exactmac.server.plist"] })

        let postCheck = try await controller.isServiceEnabled()
        #expect(postCheck == true)
    }

    @Test
    func `service configuration state survives a simulated reboot across separate instances`() async throws {
        // Shared backing store simulating persistent launchd per-user configuration database
        let sharedExecutor = MockLaunchctlExecutor(initiallyEnabled: true)

        let instance1 = LaunchdServiceController(
            serviceLabel: "io.github.joeycumines.exactmac.server",
            launchDomain: "gui/501",
            plistPath: "/tmp/io.github.joeycumines.exactmac.server.plist",
            executor: sharedExecutor,
        )

        #expect(try await instance1.isServiceEnabled() == true)

        // Operator stops and disables the service
        try await instance1.setServiceEnabled(false)
        #expect(try await instance1.isServiceEnabled() == false)

        // Simulate reboot / fresh login: new controller instance created reading launchd store
        let instanceAfterRestart = LaunchdServiceController(
            serviceLabel: "io.github.joeycumines.exactmac.server",
            launchDomain: "gui/501",
            plistPath: "/tmp/io.github.joeycumines.exactmac.server.plist",
            executor: sharedExecutor,
        )

        // Verifies the state persisted across process restart
        let stateAfterRestart = try await instanceAfterRestart.isServiceEnabled()
        #expect(stateAfterRestart == false)

        // Operator re-enables
        try await instanceAfterRestart.setServiceEnabled(true)
        #expect(try await instanceAfterRestart.isServiceEnabled() == true)

        // Second reboot: verify enabled state persists
        let instanceAfterSecondRestart = LaunchdServiceController(
            serviceLabel: "io.github.joeycumines.exactmac.server",
            launchDomain: "gui/501",
            plistPath: "/tmp/io.github.joeycumines.exactmac.server.plist",
            executor: sharedExecutor,
        )
        #expect(try await instanceAfterSecondRestart.isServiceEnabled() == true)
    }

    @Test
    @MainActor
    func `ConsoleModel coordinates with ServiceController and persists state`() async throws {
        let executor = MockLaunchctlExecutor(initiallyEnabled: true)
        let controller = LaunchdServiceController(
            serviceLabel: "io.github.joeycumines.exactmac.server",
            launchDomain: "gui/501",
            plistPath: "/tmp/io.github.joeycumines.exactmac.server.plist",
            executor: executor,
        )

        let disabledExpectation = Synchronization.Mutex<Bool>(false)
        // `startLoop: false` because this suite is about the service control, and the
        // channel loop is a background connection to a socket that is deliberately not there.
        // Started, it would immediately report `.unreachable` and overwrite the very state
        // these assertions are about — which is the loop working, not the loop breaking.
        let model = ConsoleModel(
            channel: ConsoleChannelClient(socketPath: "/tmp/test.sock", token: "test"),
            serviceController: controller,
            onServiceDisabled: {
                disabledExpectation.withLock { $0 = true }
            },
            startLoop: false,
        )

        #expect(model.isServiceEnabled == true)
        #expect(model.serviceState == .running)

        // Disable service
        try await model.setServiceEnabled(false)
        #expect(model.isServiceEnabled == false)
        #expect(model.serviceState == .stopped)
        #expect(model.failClosed?.title == "The service is off")
        #expect(disabledExpectation.withLock { $0 } == true)
        #expect(try await controller.isServiceEnabled() == false)

        // Simulate app restart / fresh instantiation with the same persistent controller
        let newModel = ConsoleModel(
            channel: ConsoleChannelClient(socketPath: "/tmp/test.sock", token: "test"),
            serviceController: controller,
        )
        await newModel.refreshServiceState()

        #expect(newModel.isServiceEnabled == false)
        #expect(newModel.serviceState == .stopped)
        #expect(newModel.failClosed?.title == "The service is off")
    }

    @Test
    @MainActor
    func `setServiceEnabled rolls back in-memory state when controller throws`() async {
        let executor = MockLaunchctlExecutor(initiallyEnabled: true)
        // Force failure on disable command
        executor.customResponses["disable gui/501/io.github.joeycumines.exactmac.server"] = (1, "", "permission denied")

        let controller = LaunchdServiceController(
            serviceLabel: "io.github.joeycumines.exactmac.server",
            launchDomain: "gui/501",
            plistPath: "/tmp/io.github.joeycumines.exactmac.server.plist",
            executor: executor,
        )

        let model = ConsoleModel(
            channel: ConsoleChannelClient(socketPath: "/tmp/test.sock", token: "test"),
            serviceController: controller,
        )

        #expect(model.isServiceEnabled == true)
        #expect(model.serviceState == .running)
        #expect(model.failClosed == nil)

        // Attempt disable which fails in controller
        do {
            try await model.setServiceEnabled(false)
            Issue.record("Expected setServiceEnabled to throw")
        } catch {
            // Verify in-memory state rolled back to previous enabled state
            #expect(model.isServiceEnabled == true)
            #expect(model.serviceState == .running)
            #expect(model.failClosed == nil)
        }
    }
}

/// The executor runs a real subprocess, so the only honest test of it is a real one.
///
/// THE PROPERTY IS THAT IT RETURNS. The previous implementation read the pipes AFTER
/// `waitUntilExit()`, so a child that filled a pipe buffer blocked writing, never exited, and
/// the caller hung with no error at all — which reaches the operator as a control that does
/// nothing, on the one control whose whole job is to turn a service off. `launchctl print`
/// against a live domain is the shape of command that does it, so the command is sized past
/// a pipe buffer here rather than mocked.
@Suite("Launchctl executor")
struct ProcessLaunchctlExecutorTests {
    @Test
    func `a child that outruns a pipe buffer still returns`() async throws {
        // Half a megabyte on both streams: more than twice the 64 KiB a pipe holds, so the
        // child blocks writing unless something is draining while it runs. Reading after
        // `waitUntilExit()` — what this replaced — deadlocks here, and it deadlocks SILENTLY.
        let payload = String(repeating: "x", count: 512 * 1024)
        let result = try await ProcessLaunchctlExecutor.runBlocking(
            "/bin/sh",
            ["-c", "printf '%s%s' \"$1\" \"$1\"; printf '%s' \"$1\" >&2", "sh", payload],
        )
        #expect(result.exitCode == 0)
        #expect(result.stdout == payload + payload)
        #expect(result.stderr == payload)
    }

    @Test
    func `the real launchctl answers printdisabled for this domain`() async throws {
        let executor = ProcessLaunchctlExecutor()
        let result = try await executor.execute(arguments: ["print-disabled", "gui/\(getuid())"])
        #expect(result.exitCode == 0, "stderr: \(result.stderr)")
        #expect(result.stdout.contains("disabled services"))
    }
}

/// The channel loop, which is the console's only connection to anything.
///
/// IT WAS MISSING ENTIRELY and every other test in this package passed without it, because
/// nothing in the console ever called `connect()` or `poll()`: the model drew a popover from
/// its initialiser state and never spoke to the server. These two are the smallest honest
/// statements about a loop whose full behaviour needs a real server on the other end — that
/// it runs, that it reports the safe state when there is nothing to reach, and that it stops
/// when it is cancelled.
@Suite("Console channel loop")
struct ConsoleChannelLoopTests {
    @MainActor
    @Test
    func `the loop reports the safe state when there is no server`() async throws {
        let model = ConsoleModel(
            channel: ConsoleChannelClient(
                socketPath: "/tmp/exactmac-no-such-console-\(UUID().uuidString).sock",
                token: "unused",
            ),
            serviceController: LaunchdServiceController(executor: MockLaunchctlExecutor()),
            startLoop: false,
        )
        // Started by hand so the test owns its lifetime: the model's own loop is cancelled in
        // its `deinit`, which this test does not reach.
        let loop = Task { await model.run() }
        defer { loop.cancel() }

        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline, model.serviceState != .unreachable {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(model.serviceState == .unreachable)
        #expect(
            model.failClosed?.title == "Denied until the console is available",
            "a console that cannot reach the server must say the safe direction, not look idle",
        )
    }

    @MainActor
    @Test
    func `cancelling the loop stops it`() async throws {
        let model = ConsoleModel(
            channel: ConsoleChannelClient(
                socketPath: "/tmp/exactmac-no-such-console-\(UUID().uuidString).sock",
                token: "unused",
            ),
            serviceController: LaunchdServiceController(executor: MockLaunchctlExecutor()),
            startLoop: false,
        )
        let loop = Task { await model.run() }
        try await Task.sleep(for: .milliseconds(100))
        loop.cancel()
        // A cancelled loop that kept running would fail this, and would also keep a menu-bar
        // app's connection attempt alive forever after the app should have let go.
        try await loop.value
    }
}
