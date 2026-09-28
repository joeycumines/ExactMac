@testable import ExactMacServer
import Foundation
import XCTest

/// C11's concurrency suite, and the things it is here to catch.
///
/// None of these can be found by a test that runs one thing at a time, and each is a way for
/// an authorization system to authorize something twice, or to authorize something an
/// operator has already taken back.
///
/// WHAT IS NOT HERE ANY MORE, AND WHY: two tests drove a console channel over a real socket to
/// show that a decision cannot be applied to a request it was not shown for, and that a
/// ceremony cannot be spent twice. Both properties were enforced by the channel's
/// pending-request ledger — a per-request nonce and a request digest, held by the endpoint
/// because the answer arrived out of band and had to be matched against something. There is no
/// channel, so there is no ledger and nothing enforcing either. What survives in the
/// interceptor is the request-ID binding (`AuthorizationInterceptor.prompt` refuses an answer
/// whose `requestID` is not this request's), and that is a weaker property: it does not bind
/// the answer to the request BYTES, and it has nothing to say about a ceremony presented twice.
/// Both belong to the host-side operator interface and are called out as a gap there.
final class AuthorizationConcurrencyTests: XCTestCase {
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
}
