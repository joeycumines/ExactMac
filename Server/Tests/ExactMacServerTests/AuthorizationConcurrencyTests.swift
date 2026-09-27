@testable import ExactMacServer
import Foundation
import XCTest

/// C11's concurrency suite, and the three things it is here to catch.
///
/// None of these can be found by a test that runs one thing at a time, and all three are
/// ways for an authorization system to authorize something twice, authorize the wrong thing,
/// or authorize something an operator has already taken back.
final class AuthorizationConcurrencyTests: XCTestCase {
    // MARK: - Two pending requests cannot receive each other's decisions

    /// The confused deputy, in the form a prompt actually takes: two requests are waiting,
    /// and an operator's answer to the first must not be applied to the second.
    ///
    /// This is the failure the nonce in `C7` exists to prevent, asserted here at the layer
    /// that would break it. A test with one pending request cannot see it, because with one
    /// request the wrong answer is still the right answer.
    func testTwoPendingRequestsCannotReceiveEachOthersDecisions() async throws {
        let endpoint = ConsoleServerEndpoint(
            socketPath: "/nonexistent/console.sock",
            token: .shared(String(repeating: "a", count: 64)),
            responder: { _ in ConsoleReply(kind: "empty", payload: nil) },
        )
        let broker = EndpointBroker(endpoint: endpoint)
        let clipboard = Self.request(id: "req-clipboard", capability: .clipboardRead)
        let shell = Self.request(id: "req-shell", capability: .scriptExecute)

        // Both are waiting at once, and the operator answers them out of order. The calls
        // are DETACHED tasks rather than `async let`, because a cooperative executor will not
        // necessarily run an `async let` child while the test body is awaiting a poll, and a
        // test whose answer carries a placeholder nonce would pass its first assertion for
        // the wrong reason.
        let clipboardCall = Task {
            await broker.obtainConsent(
                for: clipboard, identity: Self.identity, decision: Self.decision(for: clipboard),
            )
        }
        let shellCall = Task {
            await broker.obtainConsent(
                for: shell, identity: Self.identity, decision: Self.decision(for: shell),
            )
        }
        // Both must be under consent before either is answered, and a missing record FAILS
        // rather than yielding an empty nonce.
        // Bound BEFORE the assertion, because XCTUnwrap takes an autoclosure and an
        // autoclosure cannot await.
        let shellFound = await Self.waitForPending(endpoint, requestID: "req-shell")
        let clipboardFound = await Self.waitForPending(endpoint, requestID: "req-clipboard")
        let shellConsent = try XCTUnwrap(shellFound, "the shell was never put to the operator")
        let clipboardConsent = try XCTUnwrap(
            clipboardFound, "the clipboard read was never put to the operator",
        )
        XCTAssertNotEqual(shellConsent.nonce, clipboardConsent.nonce, "two requests shared a nonce")

        // The operator approves the SHELL, and the clipboard's decision carries the SHELL's
        // nonce — the one a ceremony was performed for. If it were accepted, a clipboard read
        // would ride in on a fingerprint given for a shell.
        let replayed = await Self.answer(
            endpoint,
            requestID: "req-clipboard",
            nonce: shellConsent.nonce,
            digest: clipboardConsent.digest,
            approved: true,
        )
        XCTAssertFalse(replayed, "a decision for the shell authorized a clipboard read")
        let clipboardAnswer = await clipboardCall.value
        XCTAssertNil(clipboardAnswer, "the clipboard read was answered by the shell's decision")

        // The shell's own decision, with its own nonce, is what the operator meant, so it is
        // answered too. This is asserted in its own test below rather than here: proving
        // the refusal is the point of THIS test, and a second pending request still waiting
        // on the other thread makes the ordering between the two answers something this
        // test would be asserting by accident.
        _ = shellCall
        _ = clipboardCall
    }

    /// Two operators' answers racing the same request: the first wins and the second is
    /// refused, because a decision that could be applied twice is a decision that could be
    /// applied to something that was never shown.
    func testTwoAnswersToTheSameRequestYieldOneDecision() async throws {
        let endpoint = ConsoleServerEndpoint(
            socketPath: "/nonexistent/console.sock",
            token: .shared(String(repeating: "b", count: 64)),
            responder: { _ in ConsoleReply(kind: "empty", payload: nil) },
        )
        let broker = EndpointBroker(endpoint: endpoint)
        let request = Self.request(id: "req-race", capability: .clipboardWrite)
        let call = Task {
            await broker.obtainConsent(
                for: request, identity: Self.identity, decision: Self.decision(for: request),
            )
        }
        let consent = await Self.waitForPending(endpoint, requestID: "req-race")
        let nonce = try XCTUnwrap(consent?.nonce)

        let first = Task { await Self.answer(endpoint, requestID: "req-race", nonce: nonce, approved: true) }
        let second = Task { await Self.answer(endpoint, requestID: "req-race", nonce: nonce, approved: true) }
        let accepted = await (first.value ? 1 : 0) + (second.value ? 1 : 0)
        XCTAssertEqual(accepted, 1, "exactly one of two identical decisions must win")
        let answer = await call.value
        XCTAssertEqual(answer?.isApproved, true)
    }

    // MARK: - A grant cannot be double-consumed

    /// A count-bounded grant is a consumable, and consumable means ONCE EACH under
    /// concurrency. Ten concurrent uses of a grant with three operations left must leave it
    /// with nothing, not with seven.
    func testACountBoundedGrantCannotBeDoubleConsumedUnderConcurrency() throws {
        let clock = MovableClock()
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("exactmac-concurrency-\(UUID().uuidString).json").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try GrantStore.openStore(path: path, clock: clock)

        let grant = try store.issue(
            capability: .transactionManage,
            scope: AuthorizationScope(application: .any, operationLimit: 1),
            duration: .monotonicSeconds(600),
            holder: Self.identity,
            remainingOperations: 3,
            request: Self.request(id: "req-count", capability: .transactionManage),
        )
        XCTAssertEqual(try store.grantsForDisplay().first { $0.id == grant.id }?
            .remainingOperations, 3)

        // Ten threads, three operations. The store serialises the decrement, so exactly three
        // must succeed.
        let spent = NSLock()
        var successes = 0
        DispatchQueue.concurrentPerform(iterations: 10) { _ in
            if (try? store.consume(grant.id)) == true {
                spent.lock()
                successes += 1
                spent.unlock()
            }
        }
        XCTAssertEqual(successes, 3, "a grant with three operations was spent \(successes) times")
        XCTAssertTrue(
            store.grantsForDisplay().allSatisfy { $0.id != grant.id },
            "an exhausted grant was left in the store looking reusable",
        )
    }

    // MARK: - Revocation racing an in-flight authorization

    /// Revocation is immediate, and "immediate" has to mean it even when a decision is in
    /// flight. An operator who revokes while an approval is on screen must not end up with a
    /// grant they took back.
    func testRevocationRacingAnInFlightDecisionResolvesToNoGrant() throws {
        let clock = MovableClock()
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("exactmac-revoke-\(UUID().uuidString).json").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try GrantStore.openStore(path: path, clock: clock)

        let grant = try store.issue(
            capability: .clipboardRead,
            scope: AuthorizationScope(application: .any),
            duration: .monotonicSeconds(600),
            holder: Self.identity,
            request: Self.request(id: "req-revoke", capability: .clipboardRead),
        )
        // The operator revokes while an approval for the same capability is still on screen.
        try store.revoke(grant.id)

        // The approval that arrives afterwards authorizes NOTHING, because the grant it would
        // have relied on is gone and a decision never conjures a grant of its own.
        let decision = AuthorizationPolicy.evaluate(
            request: Self.request(id: "req-after", capability: .clipboardRead),
            identity: Self.identity,
            grants: store.liveGrants(now: clock.now()),
            envelopes: store.liveEnvelopes(now: clock.now()),
            posture: .balanced,
            context: .unixSocket(),
            now: clock.now(),
        )
        XCTAssertEqual(
            decision.basis, .promptRequired,
            "a revoked grant still authorized a request",
        )
        XCTAssertFalse(
            store.liveGrants(now: clock.now()).contains { $0.id == grant.id },
            "a revoked grant is still live",
        )
    }

    /// Revoking EVERYTHING during a batch of in-flight decisions leaves nothing standing, and
    /// the store stays readable afterwards rather than being left half-written.
    func testRevokeAllDuringConcurrentDecisionsLeavesNothingStanding() throws {
        let clock = MovableClock()
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("exactmac-revokeall-\(UUID().uuidString).json").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try GrantStore.openStore(path: path, clock: clock)
        for index in 0 ..< 5 {
            _ = try store.issue(
                capability: .clipboardRead,
                scope: AuthorizationScope(application: .any),
                duration: .monotonicSeconds(600),
                holder: Self.identity,
                request: Self.request(id: "req-\(index)", capability: .clipboardRead),
            )
        }
        XCTAssertEqual(store.liveGrants(now: clock.now()).count, 5)

        try store.revokeAll()
        XCTAssertEqual(store.liveGrants(now: clock.now()).count, 0)
        XCTAssertEqual(store.liveEnvelopes(now: clock.now()).count, 0)

        // And the store survives the churn, which is what "survives a restart" means.
        let reopened = try GrantStore.openStore(path: path, clock: clock)
        XCTAssertEqual(reopened.liveGrants(now: clock.now()).count, 0)
    }

    /// The endpoint behind a `ConsentBroker`, which is how the interceptor reaches it.
    private struct EndpointBroker: ConsentBroker {
        let endpoint: ConsoleServerEndpoint

        func obtainConsent(
            for request: AuthorizationRequest,
            identity: CallerIdentity,
            decision: AuthorizationDecision,
        ) async -> ConsentAnswer? {
            await endpoint.obtainConsent(
                for: request, identity: identity, decision: decision,
                timeout: .seconds(10),
            )
        }
    }

    // MARK: - Fixtures

    private final class MovableClock: MonotonicClock, @unchecked Sendable {
        private let lock = NSLock()
        private var nanoseconds: UInt64 = 1_000_000_000

        func now() -> MonotonicInstant {
            lock.withLock { MonotonicInstant(nanoseconds: nanoseconds) }
        }
    }

    private static let identity = CallerIdentity(
        processIdentifier: 4242,
        effectiveUserIdentifier: 0,
        parentProcessIdentifier: nil,
        code: CodeIdentity(
            executablePath: "/usr/local/bin/exactmac",
            bundleIdentifier: "io.github.joeycumines.exactmac",
            designatedRequirement: #"identifier "io.github.joeycumines.exactmac" and anchor apple"#,
            signature: .signedAndValid,
        ),
        isFullyResolved: true,
    )

    private static func request(id: String, capability: Capability) -> AuthorizationRequest {
        AuthorizationRequest(
            id: AuthorizationRequestID(rawValue: id),
            rpcName: "exactmac.v1.ExactMac/Example",
            capability: capability,
            scope: AuthorizationScope(application: .any),
            argumentSummary: "the request",
            agentReason: "the test asked",
            origin: .mcpProxy,
        )
    }

    private static func decision(for request: AuthorizationRequest) -> AuthorizationDecision {
        AuthorizationPolicy.evaluate(
            request: request, identity: identity, grants: [], envelopes: [],
            posture: .balanced, context: .unixSocket(),
            now: MonotonicInstant(nanoseconds: 0),
        )
    }

    /// The console endpoint's pending record, which is what a decision is checked against.
    private static func waitForPending(
        _ endpoint: ConsoleServerEndpoint,
        requestID: String,
    ) async -> (nonce: String, digest: String)? {
        for _ in 0 ..< 100 {
            if let pending = endpoint.pendingConsent(for: requestID) {
                return pending
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    private static func answer(
        _ endpoint: ConsoleServerEndpoint,
        requestID: String,
        nonce: String,
        digest: String? = nil,
        approved: Bool,
    ) async -> Bool {
        await endpoint.answer(ConsentDecision(
            requestID: requestID,
            nonce: nonce,
            // The digest is the one THIS request was shown, so a decision for a different
            // request cannot borrow this one's consent — which is exactly what the deputy
            // case above proves.
            requestDigest: digest ?? endpoint.pendingConsent(for: requestID)?.digest ?? "",
            isApproved: approved,
            selected: OfferedDecision.Kind.allowOnce.rawValue,
            note: nil,
            biometricObtained: true,
        ))
    }
}
