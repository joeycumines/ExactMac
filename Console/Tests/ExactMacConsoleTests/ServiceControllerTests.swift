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
        let model = ConsoleModel(
            channel: ConsoleChannelClient(socketPath: "/tmp/test.sock", token: "test"),
            serviceController: controller,
            onServiceDisabled: {
                disabledExpectation.withLock { $0 = true }
            },
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
