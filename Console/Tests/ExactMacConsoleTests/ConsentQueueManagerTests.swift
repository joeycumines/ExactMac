@testable import ExactMacConsole
@testable import ExactMacServer
import Foundation
import Testing

@Suite("Consent queue preserves FIFO, attribution, starvation bounds, and fail-closed batch actions", .serialized)
@MainActor
struct ConsentQueueManagerTests {
    private static func makePendingRequest(
        id: String,
        executablePath: String,
        bundleIdentifier: String? = nil,
        capability: Capability = .clipboardRead,
        defaultKind: OfferedDecision.Kind = .allowOnce
    ) -> PendingRequest {
        let (req, _, decision) = ServerFixture.request(
            requestID: id,
            capability: capability,
            defaultKind: defaultKind
        )
        let identity = ServerFixture.identity(
            executablePath: executablePath,
            bundleIdentifier: bundleIdentifier
        )
        return PendingRequest(
            request: req,
            identity: identity,
            decision: decision
        )
    }

    @Test
    func `FIFO arrival order is strictly preserved`() {
        let manager = ConsentQueueManager()
        let req1 = Self.makePendingRequest(id: "r1", executablePath: "/usr/local/bin/exactmac-mcp")
        let req2 = Self.makePendingRequest(id: "r2", executablePath: "/usr/local/bin/codex")
        let req3 = Self.makePendingRequest(id: "r3", executablePath: "/usr/local/bin/claude")

        manager.enqueue(req1, blockedBy: "Active Prompt")
        manager.enqueue(req2, blockedBy: "Active Prompt")
        manager.enqueue(req3, blockedBy: "Active Prompt")

        #expect(manager.queuedRequests.count == 3)
        #expect(manager.queuedRequests[0].requestID == "r1")
        #expect(manager.queuedRequests[1].requestID == "r2")
        #expect(manager.queuedRequests[2].requestID == "r3")

        let next = manager.promoteNext()
        #expect(next?.requestID == "r1")
        #expect(manager.queuedRequests.count == 2)
        #expect(manager.queuedRequests[0].requestID == "r2")
        #expect(manager.queuedRequests[1].requestID == "r3")
    }

    @Test
    func `promoteQueued inserts active prompt at head and updates timestamp`() {
        let manager = ConsentQueueManager()
        let active = Self.makePendingRequest(id: "active", executablePath: "/usr/local/bin/terminal")
        let req1 = Self.makePendingRequest(id: "r1", executablePath: "/usr/local/bin/exactmac-mcp")
        let req2 = Self.makePendingRequest(id: "r2", executablePath: "/usr/local/bin/codex")

        manager.enqueue(req1, blockedBy: active.promptTitle)
        manager.enqueue(req2, blockedBy: active.promptTitle)

        let chosen = manager.promoteQueued(requestID: "r2", active: active)
        #expect(chosen != nil)
        #expect(chosen?.requestID == "r2")

        // Active prompt is now at head of queued requests
        #expect(manager.queuedRequests.count == 2)
        #expect(manager.queuedRequests[0].requestID == "active")
        #expect(manager.queuedRequests[1].requestID == "r1")
        #expect(manager.blockedBy["active"] == chosen?.promptTitle)
    }

    @Test
    func `cancelAllWaiting clears state and resumes all continuations fail-closed`() async {
        let manager = ConsentQueueManager()
        let req1 = Self.makePendingRequest(id: "r1", executablePath: "/usr/local/bin/exactmac-mcp")
        let req2 = Self.makePendingRequest(id: "r2", executablePath: "/usr/local/bin/codex")

        manager.enqueue(req1, blockedBy: "Active")
        manager.enqueue(req2, blockedBy: "Active")

        let task1 = Task { @MainActor in
            await withCheckedContinuation { cont in
                _ = manager.registerContinuation(cont, for: "r1")
            }
        }
        let task2 = Task { @MainActor in
            await withCheckedContinuation { cont in
                _ = manager.registerContinuation(cont, for: "r2")
            }
        }

        // Give background tasks a cycle to enqueue continuations
        try? await Task.sleep(nanoseconds: 20_000_000)

        #expect(manager.waitingCount == 2)
        let cancelled = manager.cancelAllWaiting()
        #expect(cancelled.count == 2)
        #expect(manager.isWaitingEmpty)
        #expect(manager.queuedRequests.isEmpty)
        #expect(manager.blockedBy.isEmpty)

        for item in cancelled {
            item.continuation.resume(returning: nil)
        }

        let res1 = await task1.value
        let res2 = await task2.value
        #expect(res1 == nil)
        #expect(res2 == nil)
    }

    @Test
    func `caller property resolves from executablePath or bundleIdentifier`() {
        let fromPath = Self.makePendingRequest(id: "p1", executablePath: "/opt/homebrew/bin/codex")
        #expect(fromPath.caller == "codex")

        let fromBundle = Self.makePendingRequest(id: "p2", executablePath: "", bundleIdentifier: "com.anthropic.claude")
        #expect(fromBundle.caller == "com.anthropic.claude")

        let fallback = Self.makePendingRequest(id: "p3", executablePath: "", bundleIdentifier: nil)
        #expect(fallback.caller == "An application")
    }

    @Test
    func `QueueReview Item attributionLine formats caller and scopeLine with bullet`() {
        let itemFull = QueueReview.Item(
            id: "1",
            title: "Read the clipboard in TextEdit",
            caller: "exactmac-mcp",
            scopeLine: "this request only"
        )
        #expect(itemFull.attributionLine == "exactmac-mcp  ·  this request only")

        let itemNoCaller = QueueReview.Item(
            id: "2",
            title: "Type text",
            caller: "",
            scopeLine: "TextEdit  ·  for 15 minutes"
        )
        #expect(itemNoCaller.attributionLine == "TextEdit  ·  for 15 minutes")

        let itemNoScope = QueueReview.Item(
            id: "3",
            title: "Open app",
            caller: "codex",
            scopeLine: ""
        )
        #expect(itemNoScope.attributionLine == "codex")
    }
}
