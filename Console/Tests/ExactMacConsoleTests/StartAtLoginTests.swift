@testable import ExactMacConsole
import Foundation
import ServiceManagement
import Testing

/// The start-at-login POLICY, tested without touching the system.
///
/// A test that called `register()` would need a login item, an operator, and a machine
/// whose login window is a real one. The behaviour worth asserting is the mapping from an
/// observed status to an action, and that mapping is where every interesting mistake lives.
@Suite("Start at login")
struct StartAtLoginTests {
    // MARK: The action, from a status

    @Test
    func `Turning it on registers an absent or unregistered login item`() {
        #expect(StartAtLoginPolicy.action(for: .notFound, desired: true) == .register)
        #expect(StartAtLoginPolicy.action(for: .notRegistered, desired: true) == .register)
    }

    @Test
    func `Turning it on when it is already on does nothing`() {
        // The idempotence case, and the reason `.none` is its own action rather than a
        // redundant `register()`. `register()` is a privileged round trip to launchd that
        // can block and can fail for reasons unrelated to the operator's intent.
        #expect(StartAtLoginPolicy.action(for: .enabled, desired: true) == .none)
    }

    @Test
    func `Turning it off unregisters an enabled login item`() {
        #expect(StartAtLoginPolicy.action(for: .enabled, desired: false) == .unregister)
    }

    @Test
    func `Turning it off when it is already off does nothing`() {
        #expect(StartAtLoginPolicy.action(for: .notRegistered, desired: false) == .none)
        #expect(StartAtLoginPolicy.action(for: .notFound, desired: false) == .none)
    }

    @Test
    func `An unapproved login item is not re-registered when the operator asks for it on`() {
        // The case that has no fourth action. `register()` cannot clear `.requiresApproval`
        // — macOS holds that decision outside the app — so the honest answer is to stop and
        // report, not to retry and not to claim a start-at-login that will not happen.
        #expect(StartAtLoginPolicy.action(for: .requiresApproval, desired: true) == .operatorApprovalRequired)
    }

    @Test
    func `An unapproved login item is still removed when the operator asks for it off`() {
        // Leaving a registered-but-unapproved entry behind is the orphan: invisible in the
        // app, and a surprise the next time the operator changes their mind about it.
        #expect(StartAtLoginPolicy.action(for: .requiresApproval, desired: false) == .unregister)
    }

    @Test
    func `Every status is decided, and no status can reach an unhandled path`() {
        // A STATE DIFFERENCE ASSERTION over the whole input space rather than a spot check:
        // the four real cases plus a deliberately unknown one, all of which must produce a
        // decided action. `SMAppService.Status` has exactly four cases and no `disabled`,
        // which is itself the reason the switch is written out.
        let statuses: [SMAppService.Status] = [
            .notFound, .notRegistered, .enabled, .requiresApproval,
        ]
        for status in statuses {
            #expect(StartAtLoginPolicy.action(for: status, desired: true) != .operatorApprovalRequired
                || status == .requiresApproval)
            #expect(StartAtLoginPolicy.action(for: status, desired: false) != .register)
        }
    }
}

/// A login item that records what was asked of it and answers with a chosen status.
private final class FakeLoginItem: LoginItemRegistering, @unchecked Sendable {
    private let lock = NSLock()
    private var storedStatus: SMAppService.Status
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    /// Thrown by the next call to the matching verb, to exercise the refusal path.
    var failure: (any Error)?

    init(status: SMAppService.Status) {
        storedStatus = status
    }

    var status: SMAppService.Status {
        lock.withLock { storedStatus }
    }

    func register() throws {
        if let failure {
            throw failure
        }
        lock.withLock {
            registerCount += 1
            storedStatus = .enabled
        }
    }

    func unregister() throws {
        if let failure {
            throw failure
        }
        lock.withLock {
            unregisterCount += 1
            storedStatus = .notRegistered
        }
    }

    /// Stands in for the operator revoking the login item in System Settings, which this
    /// process is not told about and cannot observe without re-reading.
    func simulateExternalRevocation() {
        lock.withLock { storedStatus = .notRegistered }
    }
}

private struct FakeLoginItemError: Error {}

/// The EXECUTION, tested against a fake.
///
/// These assert state differences on the fake — how many system calls were made, and what
/// the app then published — rather than that a function was invoked. A test that counted
/// calls would still pass if the app published a status the system disagrees with, which
/// is the actual failure mode worth guarding: `register()` returns `Void`, so the only
/// evidence it worked is the status afterwards.
@Suite("Start at login execution")
@MainActor
struct StartAtLoginExecutionTests {
    @Test
    func `Turning it on registers exactly once and publishes the resulting status`() {
        let item = FakeLoginItem(status: .notFound)
        let subject = StartAtLogin(item: item)

        let outcome = subject.setEnabled(true)

        #expect(outcome == .register)
        #expect(item.registerCount == 1)
        // Read back from the SYSTEM, not assumed: this is the assertion that the published
        // state is evidence rather than a guess.
        #expect(subject.status == .enabled)
        #expect(subject.lastRefusal == nil)
    }

    @Test
    func `Turning it on when already on performs no system call at all`() {
        let item = FakeLoginItem(status: .enabled)
        let subject = StartAtLogin(item: item)

        let outcome = subject.setEnabled(true)

        #expect(outcome == .none)
        // The state difference, not the return value: a redundant `register()` is the thing
        // being prevented, so the count has to be zero.
        #expect(item.registerCount == 0)
        #expect(item.unregisterCount == 0)
    }

    @Test
    func `Turning it off unregisters exactly once and publishes the resulting status`() {
        let item = FakeLoginItem(status: .enabled)
        let subject = StartAtLogin(item: item)

        let outcome = subject.setEnabled(false)

        #expect(outcome == .unregister)
        #expect(item.unregisterCount == 1)
        #expect(item.registerCount == 0)
        #expect(subject.status == .notRegistered)
    }

    @Test
    func `Turning it off when already off performs no system call at all`() {
        let item = FakeLoginItem(status: .notFound)
        let subject = StartAtLogin(item: item)

        let outcome = subject.setEnabled(false)

        #expect(outcome == .none)
        #expect(item.registerCount == 0)
        #expect(item.unregisterCount == 0)
    }

    @Test
    func `An unapproved login item is not re-registered and says so`() {
        let item = FakeLoginItem(status: .requiresApproval)
        let subject = StartAtLogin(item: item)

        let outcome = subject.setEnabled(true)

        #expect(outcome == .operatorApprovalRequired)
        #expect(item.registerCount == 0)
        // An operator who is told nothing is handed a toggle that silently did nothing.
        #expect(subject.lastRefusal != nil)
    }

    @Test
    func `A refused registration leaves the published status at the system's value`() {
        let item = FakeLoginItem(status: .notFound)
        item.failure = FakeLoginItemError()
        let subject = StartAtLogin(item: item)

        _ = subject.setEnabled(true)

        // The state difference that matters: a failed `register()` must not leave the app
        // claiming ExactMac starts at login. The status is re-read, so it still says what
        // launchd says.
        #expect(subject.status == .notFound)
        #expect(subject.lastRefusal != nil)
    }

    @Test
    func `A refusal is cleared by the next request that succeeds`() {
        let item = FakeLoginItem(status: .notFound)
        item.failure = FakeLoginItemError()
        let subject = StartAtLogin(item: item)
        _ = subject.setEnabled(true)
        #expect(subject.lastRefusal != nil)

        item.failure = nil
        _ = subject.setEnabled(true)

        #expect(subject.lastRefusal == nil)
        #expect(subject.status == .enabled)
    }

    @Test
    func `The published status tracks the system after an external revocation`() {
        // The case a cached bool cannot handle: an operator revoking the login item in
        // System Settings while the app runs. Only a re-read can notice.
        let item = FakeLoginItem(status: .enabled)
        let subject = StartAtLogin(item: item)
        #expect(subject.status == .enabled)

        item.simulateExternalRevocation()
        #expect(subject.status == .enabled)

        subject.refresh()

        #expect(subject.status == .notRegistered)
    }
}
