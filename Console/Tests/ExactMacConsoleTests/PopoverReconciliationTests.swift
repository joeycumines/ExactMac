import AppKit
@testable import ExactMacConsole
@testable import ExactMacServer
import Foundation
import ServiceManagement
import Testing

@Suite("Popover reconciliation and service toggle")
@MainActor
struct PopoverReconciliationTests {
    private func modelWithUnregisteredLoginItem(presentation: OperatorInterface = .application) -> ConsoleModel {
        ConsoleModel(
            startAtLogin: StartAtLogin(item: StubLoginItem(initialStatus: .notRegistered)),
            presentation: presentation,
            windows: ConsoleWindowHost(),
            ceremony: nil,
        )
    }

    private func fixtureRequest(
        capability: Capability = .clipboardRead,
        targetApp: TargetApplication = .bundleIdentifier("com.apple.TextEdit"),
    ) -> PendingRequest {
        let (req, id, dec) = ServerFixture.request(
            requestID: "popover-test-req",
            capability: capability,
            rpcName: "exactmac.v1.ExactMac/GetClipboard",
        )
        let scopedReq = AuthorizationRequest(
            id: req.id,
            rpcName: req.rpcName,
            capability: capability,
            scope: AuthorizationScope(application: targetApp, window: .any),
            argumentSummary: req.argumentSummary,
            agentReason: req.agentReason,
            origin: req.origin,
        )
        return PendingRequest(
            request: scopedReq,
            identity: id,
            decision: dec,
        )
    }

    @Test
    func `popover reports service running even when login item is not enabled`() {
        let model = modelWithUnregisteredLoginItem()

        // Login item is disabled on this system/model
        #expect(model.isStartAtLoginEnabled == false)

        // But the service itself is running and healthy
        #expect(model.isServiceRunning == true)
        #expect(model.isServiceEnabled == true)
        #expect(model.serviceState == .running)
        #expect(model.failClosed == nil)
    }

    @Test
    func `toggling service state transitions running and stopped without affecting login item`() {
        let model = modelWithUnregisteredLoginItem()
        #expect(model.isServiceRunning == true)
        #expect(model.isStartAtLoginEnabled == false)

        // Stopping service
        model.toggleService()
        #expect(model.isServiceRunning == false)
        #expect(model.isServiceEnabled == false)
        #expect(model.serviceState == .stopped)
        #expect(model.failClosed?.title == "The service is off")
        #expect(model.isStartAtLoginEnabled == false, "stopping service must leave login-item untouched")

        // Starting service
        model.toggleService()
        #expect(model.isServiceRunning == true)
        #expect(model.isServiceEnabled == true)
        #expect(model.serviceState == .running)
        #expect(model.failClosed == nil)
        #expect(model.isStartAtLoginEnabled == false, "starting service must leave login-item untouched")
    }

    @Test
    func `toggling login item does not affect service running state`() {
        let model = modelWithUnregisteredLoginItem()
        #expect(model.isServiceRunning == true)
        #expect(model.isStartAtLoginEnabled == false)

        model.toggleStartAtLogin()
        #expect(model.isStartAtLoginEnabled == true)
        #expect(model.isServiceRunning == true, "toggling login item must not alter service state")
        #expect(model.serviceState == .running)

        model.toggleStartAtLogin()
        #expect(model.isStartAtLoginEnabled == false)
        #expect(model.isServiceRunning == true)
        #expect(model.serviceState == .running)
    }

    @Test
    func `pendingNotice appears if and only if pendingPrompt is set and clicking it opens approval`() {
        let model = modelWithUnregisteredLoginItem()
        #expect(model.pendingPrompt == nil)
        #expect(model.waitingCount == 0)
        #expect(model.windows.isPresented(.approval) == false)

        let request = fixtureRequest()
        model.deliverPending(request)

        #expect(model.pendingPrompt != nil)
        #expect(model.waitingCount == 1)
        #expect(model.pendingNotice == request.popoverNoticeBody)
        #expect(model.serviceState == .pending)

        // Calling openApproval raises the approval window
        model.openApproval()
        #expect(model.windows.isPresented(.approval) == true)
    }

    @Test
    func `popoverNoticeBody formats caller consequence and target without internal tokens`() {
        let targeted = fixtureRequest(
            capability: .clipboardRead,
            targetApp: .bundleIdentifier("TextEdit"),
        )
        #expect(targeted.popoverNoticeBody == "exactmac wants to read the clipboard in TextEdit")

        let untargeted = fixtureRequest(
            capability: .screenObserve,
            targetApp: .any,
        )
        #expect(untargeted.popoverNoticeBody == "exactmac wants to read the contents of the screen")

        // Invariant 17: no internal capability tokens or rawValues
        #expect(!targeted.popoverNoticeBody.contains("clipboard.read"))
        #expect(!untargeted.popoverNoticeBody.contains("screen.observe"))
    }

    @Test
    func `cancelling waiting request clears pendingPrompt closes window and restores running state`() async {
        let model = modelWithUnregisteredLoginItem()
        let (req, id, dec) = ServerFixture.request()

        let task = Task {
            await model.answer(request: req, identity: id, decision: dec)
        }

        // Allow task to suspend on continuation
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(model.pendingPrompt != nil)
        #expect(model.waitingCount == 1)
        #expect(model.serviceState == .pending)
        #expect(model.windows.isPresented(.approval) == true)

        // Cancel the task
        task.cancel()
        let result = await task.value
        #expect(result == nil)

        // Give MainActor time to execute onCancel cleanup
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(model.pendingPrompt == nil)
        #expect(model.waitingCount == 0)
        #expect(model.serviceState == .running, "clearing pending request reverts serviceState from pending to running")
        #expect(model.windows.isPresented(.approval) == false, "cancellation closes the approval window")
    }

    @Test
    func `stopping service cancels waiting requests and denies new ones immediately`() async {
        let model = modelWithUnregisteredLoginItem()
        let (req, id, dec) = ServerFixture.request()

        let task = Task {
            await model.answer(request: req, identity: id, decision: dec)
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(model.waitingCount == 1)

        // Stop the service
        model.stopService()
        let result = await task.value
        #expect(result == nil, "stopping service must fail closed all waiting requests")

        #expect(model.serviceState == .stopped)
        #expect(model.waitingCount == 0)
        #expect(model.windows.isPresented(.approval) == false)

        // New requests while stopped fail closed immediately
        let immediate = await model.answer(request: req, identity: id, decision: dec)
        #expect(immediate == nil)
        #expect(model.pendingPrompt == nil)
        #expect(model.windows.isPresented(.approval) == false)
    }
}

// MARK: - Doubles

private final class StubLoginItem: LoginItemRegistering, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SMAppService.Status

    init(initialStatus: SMAppService.Status = .notRegistered) {
        self.stored = initialStatus
    }

    var status: SMAppService.Status {
        lock.withLock { stored }
    }

    func register() throws {
        lock.withLock { stored = .enabled }
    }

    func unregister() throws {
        lock.withLock { stored = .notRegistered }
    }
}
