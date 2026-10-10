import Darwin
@testable import ExactMacServer
import Foundation
import Synchronization
import XCTest

/// Acceptance suite for the in-memory GrantStore enforcing Standing Invariant 12.
///
/// STANDING INVARIANT 12: The console persists no decision state, so there is nothing on
/// disk for a same-uid process to forge. All grants and pre-authorization envelopes are held
/// exclusively in process memory protected by `Synchronization.Mutex<GrantStoreContents>`.
///
/// The binding test is the primary control answering confused-deputy and same-uid malware
/// cases: a grant belongs to a BINARY and not to a number the kernel hands out.
final class GrantStoreTests: XCTestCase {
    // MARK: - Fixtures

    /// A clock the test moves, because expiry proven against a clock the test cannot move is
    /// expiry that has not been proven.
    private final class MovableClock: MonotonicClock, @unchecked Sendable {
        private let lock = NSLock()
        private var nanoseconds: UInt64

        init(_ nanoseconds: UInt64 = 1_000_000_000) {
            self.nanoseconds = nanoseconds
        }

        func now() -> MonotonicInstant {
            lock.withLock { MonotonicInstant(nanoseconds: nanoseconds) }
        }

        func advance(by interval: Duration) {
            lock.withLock { nanoseconds = nowValue().advanced(by: interval).nanoseconds }
        }

        private func nowValue() -> MonotonicInstant {
            MonotonicInstant(nanoseconds: nanoseconds)
        }
    }

    private static let signedRequirement = #"identifier "com.example.agent" and anchor apple"#

    private static func identity(
        path: String = "/usr/local/bin/exactmac",
        bundle: String? = "io.github.joeycumines.exactmac",
        requirement: String? = #"identifier "io.github.joeycumines.exactmac" and anchor apple"#,
        signature: SignatureState = .signedAndValid,
        fullyResolved: Bool = true,
        pid: Int32 = 4242,
    ) -> CallerIdentity {
        CallerIdentity(
            processIdentifier: pid,
            effectiveUserIdentifier: getuid(),
            parentProcessIdentifier: nil,
            code: CodeIdentity(
                executablePath: path,
                bundleIdentifier: bundle,
                designatedRequirement: requirement,
                signature: signature,
            ),
            isFullyResolved: fullyResolved,
        )
    }

    private static let clipboardRequest = AuthorizationRequest(
        id: AuthorizationRequestID(rawValue: "req-store"),
        rpcName: "exactmac.v1.ExactMac/GetClipboard",
        capability: .clipboardRead,
        scope: AuthorizationScope(application: .bundleIdentifier("com.apple.TextEdit")),
        argumentSummary: "the clipboard",
        agentReason: "the test asked",
        origin: .mcpProxy,
    )

    private func makeStore(
        clock: any MonotonicClock,
    ) -> GrantStore {
        GrantStore(clock: clock, maximumEnvelopeSeconds: 3600)
    }

    // MARK: - Invariant 12 & In-Memory Integrity

    /// In-memory store reports intact integrity unconditionally and evaluates cleanly under policy.
    func testAnInMemoryStoreHasIntactIntegrity() async {
        let clock = MovableClock()
        let store = makeStore(clock: clock)

        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.integrity, .intact)

        let decision = AuthorizationPolicy.evaluate(
            request: AuthorizationRequest(
                id: AuthorizationRequestID(rawValue: "intact"),
                rpcName: "\(RPCAuthorizationMap.serviceName)/GetClipboard",
                capability: .clipboardRead,
                scope: AuthorizationScope(),
                argumentSummary: "the clipboard",
                agentReason: "because the test says so",
                origin: .mcpProxy,
            ),
            identity: Self.identity(),
            grants: snapshot.grants,
            envelopes: snapshot.envelopes,
            posture: .balanced,
            context: .unixSocket(store: snapshot.integrity),
            now: clock.now(),
        )
        // With no grants, balanced posture prompts for consent rather than failing with grantStoreUnreadable.
        XCTAssertEqual(decision.basis, .promptRequired)
        XCTAssertNil(decision.denialReason)
    }

    /// STANDING INVARIANT 12: Zero decision state on disk.
    /// Grants fail-closed on restart; a fresh store instance starts completely empty.
    func testAGrantFailsClosedAndDoesNotPersistAcrossStoreInstances() throws {
        let clock = MovableClock()
        let store = makeStore(clock: clock)

        let issued = try store.issue(
            capability: .clipboardRead,
            scope: AuthorizationScope(application: .bundleIdentifier("com.apple.TextEdit")),
            duration: .monotonicSeconds(600),
            holder: Self.identity(),
            request: Self.clipboardRequest,
        )
        XCTAssertEqual(store.liveGrants().count, 1)

        // The origin the grants manager shows is the REQUEST.
        let stored = try XCTUnwrap(store.grantsForDisplay().first { $0.id == issued.id })
        XCTAssertEqual(stored.originRPCName, "exactmac.v1.ExactMac/GetClipboard")
        XCTAssertEqual(stored.originArgumentSummary, "the clipboard")

        // A brand new store instance in memory has zero grants (fails closed).
        let freshStore = makeStore(clock: clock)
        XCTAssertEqual(freshStore.liveGrants().count, 0)
        XCTAssertTrue(freshStore.grantsForDisplay().isEmpty)
    }

    /// STANDING INVARIANT 12: Zero decision state on disk.
    /// Neither grants nor envelopes ever create any file on disk.
    func testStandingInvariant12ZeroDecisionStateOnDisk() throws {
        let clock = MovableClock()
        let store = makeStore(clock: clock)

        // Issue grants and envelopes in memory.
        try store.issue(
            capability: .clipboardRead,
            scope: AuthorizationScope(application: .any),
            duration: .monotonicSeconds(600),
            holder: Self.identity(),
            request: Self.clipboardRequest,
        )
        try store.issueEnvelope(envelope: Self.envelope(id: "e-inv12"), now: clock.now())

        XCTAssertEqual(store.liveGrants().count, 1)
        XCTAssertEqual(store.liveEnvelopes().count, 1)

        // Verify that no grants.json or related decision state file exists in temporary or home paths.
        let tmpGrants = FileManager.default.temporaryDirectory.appendingPathComponent("grants.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpGrants.path))
    }

    // MARK: - Code Identity Binding

    /// THE BINDING TEST. A grant belongs to a binary, not to a number the kernel hands out,
    /// so a grant issued to a signed application is not honoured by an unsigned binary at
    /// another path running as the same user.
    func testAGrantDoesNotTransferToAnUnsignedBinaryAtAnotherPath() throws {
        let clock = MovableClock()
        let store = makeStore(clock: clock)

        let granted = try store.issue(
            capability: .clipboardRead,
            scope: AuthorizationScope(application: .any),
            duration: .monotonicSeconds(600),
            holder: Self.identity(),
            request: Self.clipboardRequest,
        )
        let grants = store.liveGrants()
        XCTAssertTrue(grants[0].authorizes(Self.clipboardRequest, identity: Self.identity(), now: clock.now()))

        // Same uid, same moment, DIFFERENT binary, and no signature to speak of.
        let impostor = Self.identity(
            path: "/tmp/exactmac",
            bundle: nil,
            requirement: nil,
            signature: .unsigned,
            pid: 9001,
        )
        XCTAssertFalse(
            granted.authorizes(Self.clipboardRequest, identity: impostor, now: clock.now()),
            "a grant for a signed application was honoured by an unsigned binary at another path",
        )
    }

    /// Nor does it transfer to a DIFFERENT PROCESS that later receives the original pid,
    /// which is the recycled-pid case a grant keyed by a number cannot defend against.
    func testAGrantDoesNotTransferToAProcessThatLaterReceivesTheOriginalPID() throws {
        let clock = MovableClock()
        let store = makeStore(clock: clock)

        let original = Self.identity(pid: 4242)
        let granted = try store.issue(
            capability: .clipboardRead,
            scope: AuthorizationScope(application: .any),
            duration: .monotonicSeconds(600),
            holder: original,
            request: Self.clipboardRequest,
        )

        // The same PID, a different binary. This is exactly what a pid-keyed grant inherits
        // and a code-identity-keyed one does not.
        let recycled = Self.identity(path: "/tmp/other", bundle: nil, requirement: nil, pid: 4242)
        XCTAssertEqual(recycled.processIdentifier, original.processIdentifier)
        XCTAssertFalse(granted.authorizes(Self.clipboardRequest, identity: recycled, now: clock.now()))

        // And the matching binary under a different pid is still the SAME holder, which is
        // the property a pid-keyed grant gets wrong in the other direction.
        let sameBinaryNewPID = Self.identity(pid: 7777)
        XCTAssertTrue(
            granted.authorizes(Self.clipboardRequest, identity: sameBinaryNewPID, now: clock.now()),
            "a grant must survive the holder restarting, because the holder is the binary",
        )
    }

    /// An unsigned holder degrades to canonical-path identity rather than becoming unbound,
    /// which would let any process claim a grant it cannot prove.
    func testAnUnsignedHolderBindsByCanonicalPathAndNotByNothing() throws {
        let clock = MovableClock()
        let store = makeStore(clock: clock)

        let unsigned = Self.identity(
            path: "/usr/local/bin/exactmac",
            bundle: nil,
            requirement: nil,
            signature: .unsigned,
        )
        let granted = try store.issue(
            capability: .clipboardRead,
            scope: AuthorizationScope(application: .any),
            duration: .monotonicSeconds(600),
            holder: unsigned,
            request: Self.clipboardRequest,
        )
        XCTAssertNil(granted.holder.designatedRequirement)
        XCTAssertTrue(granted.authorizes(Self.clipboardRequest, identity: unsigned, now: clock.now()))
        XCTAssertFalse(
            granted.authorizes(
                Self.clipboardRequest,
                identity: Self.identity(path: "/tmp/exactmac", bundle: nil, requirement: nil),
                now: clock.now(),
            ),
            "an unsigned grant must not be satisfied by a different path",
        )
    }

    // MARK: - Expiry

    /// Expiry is on a MONOTONIC schedule, so a wall-clock change cannot extend a grant. The
    /// wall clock is not consulted at all, which is asserted by moving the ONLY clock the
    /// store has and showing nothing else can matter.
    func testExpiryIsMonotonicAndAWallClockChangeCannotExtendAGrant() throws {
        let clock = MovableClock()
        let store = makeStore(clock: clock)

        try store.issue(
            capability: .clipboardRead,
            scope: AuthorizationScope(application: .any),
            duration: .monotonicSeconds(60),
            holder: Self.identity(),
            request: Self.clipboardRequest,
        )
        XCTAssertEqual(store.liveGrants().count, 1)

        clock.advance(by: .seconds(59))
        XCTAssertEqual(store.liveGrants().count, 1, "expired one second early")

        clock.advance(by: .seconds(2))
        XCTAssertEqual(
            store.liveGrants().count, 0,
            "a grant outlived its duration; the store reads no other clock",
        )
    }

    /// A count-bounded grant is CONSUMABLE, and the decrement is the store's job because the
    /// engine takes grants by value and could not mutate one.
    func testACountBoundedGrantIsConsumableAndNeverAmortises() throws {
        let clock = MovableClock()
        let store = makeStore(clock: clock)

        let request = AuthorizationRequest(
            id: AuthorizationRequestID(rawValue: "req-count"),
            rpcName: "exactmac.v1.ExactMac/BeginTransaction",
            capability: .transactionManage,
            scope: AuthorizationScope(application: .any, operationLimit: 1),
            argumentSummary: "a transaction",
            agentReason: "the test asked",
            origin: .mcpProxy,
        )
        let granted = try store.issue(
            capability: .transactionManage,
            scope: AuthorizationScope(application: .any, operationLimit: 1),
            duration: .monotonicSeconds(600),
            holder: Self.identity(),
            remainingOperations: 3,
            request: request,
        )
        XCTAssertEqual(granted.remainingOperations, 3)

        XCTAssertTrue(store.consume(granted.id))
        XCTAssertEqual(try XCTUnwrap(store.liveGrants().first).remainingOperations, 2)
        XCTAssertTrue(store.consume(granted.id))
        XCTAssertTrue(store.consume(granted.id))
        // Exhausted: the grant is REMOVED, not left at zero looking reusable.
        XCTAssertEqual(store.liveGrants().count, 0)
        XCTAssertFalse(store.consume(granted.id), "a removed grant cannot be spent again")
    }

    /// INVARIANT 9, AT THE STORE: a batch spend — the commit or rollback of a transaction
    /// authorized as a scope with a declared operation count — decrements by the DECLARED
    /// count, refuses when the remaining count cannot cover it, and removes the grant at
    /// exhaustion.
    func testABatchSpendDecrementsByTheDeclaredCountAndExhaustionRemovesTheGrant() throws {
        let clock = MovableClock()
        let store = makeStore(clock: clock)

        let granted = try store.issue(
            capability: .transactionManage,
            scope: AuthorizationScope(application: .any, operationLimit: 5),
            duration: .monotonicSeconds(600),
            holder: Self.identity(),
            remainingOperations: 5,
        )

        XCTAssertTrue(store.consume(granted.id, operations: 3))
        XCTAssertEqual(try XCTUnwrap(store.liveGrants().first).remainingOperations, 2)
        // Two left cannot cover three: the predicate re-checked under the store's lock refuses.
        XCTAssertFalse(store.consume(granted.id, operations: 3))
        XCTAssertEqual(try XCTUnwrap(store.liveGrants().first).remainingOperations, 2)
        XCTAssertTrue(store.consume(granted.id, operations: 2))
        XCTAssertTrue(store.liveGrants().isEmpty, "an exhausted grant is removed, not left at zero")
    }

    /// Calling consume or consumeEnvelope with zero or negative operations returns false rather
    /// than trapping with a precondition.
    func testConsumeWithZeroOrNegativeOperationsReturnsFalse() throws {
        let clock = MovableClock()
        let store = makeStore(clock: clock)

        let granted = try store.issue(
            capability: .transactionManage,
            scope: AuthorizationScope(application: .any, operationLimit: 5),
            duration: .monotonicSeconds(600),
            holder: Self.identity(),
            remainingOperations: 5,
        )

        XCTAssertFalse(store.consume(granted.id, operations: 0))
        XCTAssertFalse(store.consume(granted.id, operations: -1))
        XCTAssertEqual(try XCTUnwrap(store.liveGrants().first).remainingOperations, 5)

        try store.issueEnvelope(envelope: Self.envelope(id: "e-nonpositive"), now: clock.now())
        XCTAssertFalse(store.consumeEnvelope("e-nonpositive", operations: 0))
        XCTAssertFalse(store.consumeEnvelope("e-nonpositive", operations: -2))
    }

    /// Thread safety under load: concurrent issue and revoke operations under mutex protection
    /// leave memory coherent and never resurrect revoked grants.
    func testConcurrentIssueAndRevokeUnderMemoryMutex() async {
        let clock = MovableClock()
        let store = makeStore(clock: clock)

        let tasks = 8
        let rounds = 25
        let revokedByID = Synchronization.Mutex<[String: Bool]>([:])
        await withTaskGroup(of: Void.self) { group in
            for task in 0 ..< tasks {
                group.addTask {
                    for round in 0 ..< rounds {
                        let granted = try? store.issue(
                            capability: .clipboardRead,
                            scope: AuthorizationScope(application: .bundleIdentifier("com.apple.TextEdit")),
                            duration: .monotonicSeconds(6000),
                            holder: Self.identity(),
                        )
                        if let granted {
                            revokedByID.withLock { $0[granted.id] = false }
                            store.revoke(granted.id)
                            revokedByID.withLock { $0[granted.id] = true }
                        }
                        _ = task
                        _ = round
                    }
                }
            }
        }

        // Every issued grant was revoked by the task that issued it, so the live set must be EMPTY.
        XCTAssertTrue(store.liveGrants().isEmpty, "every grant was revoked; none may be live")
        XCTAssertTrue(store.persistedContents().grants.isEmpty)
    }

    /// A spend against a grant INSIDE an envelope decrements through consumeEnvelope.
    func testAnEnvelopeGrantIsSpentThroughItsEnvelope() throws {
        let clock = MovableClock()
        let store = makeStore(clock: clock)

        try store.issueEnvelope(envelope: Self.envelope(id: "e-count"), now: clock.now())
        XCTAssertEqual(try XCTUnwrap(store.liveEnvelopes().first).grants.count, 2)

        XCTAssertTrue(store.consumeEnvelope("e-count", operations: 3))
        // The FIRST grant that could cover the batch is spent.
        XCTAssertEqual(
            try XCTUnwrap(store.liveEnvelopes().first).grants.first?.remainingOperations, 2,
        )
        XCTAssertFalse(store.consumeEnvelope("e-count", operations: 3))
        // An unknown envelope cannot be spent.
        XCTAssertFalse(store.consumeEnvelope("e-absent", operations: 1))
    }

    // MARK: - Revocation

    func testRevokingOneGrantIsImmediateInMemory() throws {
        let clock = MovableClock()
        let store = makeStore(clock: clock)

        let first = try store.issue(
            capability: .clipboardRead,
            scope: AuthorizationScope(application: .any),
            duration: .monotonicSeconds(600),
            holder: Self.identity(),
            request: Self.clipboardRequest,
        )
        try store.issue(
            capability: .screenObserve,
            scope: AuthorizationScope(application: .any),
            duration: .monotonicSeconds(600),
            holder: Self.identity(),
            request: Self.clipboardRequest,
        )
        XCTAssertEqual(store.liveGrants().count, 2)

        store.revoke(first.id)
        XCTAssertEqual(store.liveGrants().map(\.id), [store.liveGrants()[0].id])
        XCTAssertFalse(store.liveGrants().contains { $0.id == first.id })
    }

    func testRevokingEverythingRemovesEveryGrantAndEveryEnvelope() throws {
        let clock = MovableClock()
        let store = makeStore(clock: clock)

        try store.issue(
            capability: .clipboardRead,
            scope: AuthorizationScope(application: .any),
            duration: .monotonicSeconds(600),
            holder: Self.identity(),
            request: Self.clipboardRequest,
        )
        _ = try store.issueEnvelope(envelope: Self.envelope(id: "e-1"), now: clock.now())
        XCTAssertEqual(store.liveGrants().count, 1)
        XCTAssertEqual(store.liveEnvelopes().count, 1)

        store.revokeAll()
        XCTAssertEqual(store.liveGrants().count, 0)
        XCTAssertEqual(store.liveEnvelopes().count, 0)
    }

    // MARK: - Envelopes

    /// An envelope is validated BEFORE it is stored.
    func testEnvelopeValidationRejectsGlobalPersistentScope() throws {
        let global = Self.envelope(
            id: "e-global",
            scope: AuthorizationScope(application: .any, window: .any, operationLimit: nil),
        )
        XCTAssertThrowsError(try GrantStore.validateEnvelope(
            envelope: global,
            requested: [Self.clipboardRequest],
            maximumSeconds: 3600,
        )) { error in
            XCTAssertEqual(error as? EnvelopeValidationFailure, .globalPersistentScope)
        }
    }

    func testEnvelopeValidationRejectsAnOverLongDuration() throws {
        let long = Self.envelope(id: "e-long", duration: .monotonicSeconds(7200))
        XCTAssertThrowsError(try GrantStore.validateEnvelope(
            envelope: long,
            requested: [Self.clipboardRequest],
            maximumSeconds: 3600,
        )) { error in
            XCTAssertEqual(
                error as? EnvelopeValidationFailure,
                .durationExceedsMaximum(allowed: 3600, requested: 7200),
            )
        }
    }

    /// An envelope may only cover what the requester actually asked for.
    func testEnvelopeValidationRejectsAnUndeclaredCapability() throws {
        let request = Self.clipboardRequest
        let envelope = Self.envelope(
            id: "e-wide",
            capability: .scriptExecute,
            scope: AuthorizationScope(application: .any, operationLimit: 1),
        )
        XCTAssertThrowsError(try GrantStore.validateEnvelope(
            envelope: envelope,
            requested: [request],
            maximumSeconds: 3600,
        )) { error in
            XCTAssertEqual(
                error as? EnvelopeValidationFailure,
                .undeclaredCapability(Capability.scriptExecute.rawValue),
            )
        }
    }

    /// And it may not cover a SCOPE the requester did not name.
    func testEnvelopeValidationRejectsAScopeNobodyAskedFor() throws {
        let envelope = Self.envelope(
            id: "e-scope",
            capability: .clipboardRead,
            scope: AuthorizationScope(application: .any, operationLimit: 1),
        )
        XCTAssertThrowsError(try GrantStore.validateEnvelope(
            envelope: envelope,
            requested: [Self.clipboardRequest],
            maximumSeconds: 3600,
        )) { error in
            guard case .scopeNotRequested = error as? EnvelopeValidationFailure else {
                return XCTFail("expected a scope refusal, got \(error)")
            }
        }
    }

    func testEnvelopeValidationAcceptsWhatWasAskedFor() throws {
        let scope = AuthorizationScope(
            application: .bundleIdentifier("com.apple.TextEdit"),
            operationLimit: 1,
        )
        let at = MonotonicInstant(nanoseconds: 1_000_000_000)
        let envelope = PreAuthorizationEnvelope(
            id: "e-ok",
            grants: [
                Grant(
                    id: "e-ok-g1",
                    capability: .clipboardRead,
                    scope: scope,
                    duration: .monotonicSeconds(30),
                    holder: Self.identity().code.binding,
                    issuedAt: at,
                    expiresAt: at.advanced(by: .seconds(30)),
                    origin: .envelope(id: "e-ok"),
                    remainingOperations: 5,
                    targetIsHighConsequence: false,
                ),
            ],
            declaredDuration: .monotonicSeconds(30),
            expiresAt: at.advanced(by: .seconds(30)),
            holder: Self.identity().code.binding,
        )
        XCTAssertNoThrow(try GrantStore.validateEnvelope(
            envelope: envelope,
            requested: [Self.clipboardRequest],
            maximumSeconds: 3600,
        ))
    }

    /// Revoking an envelope revokes everything INSIDE it, in one step.
    func testRevokingAnEnvelopeRevokesEverythingInIt() throws {
        let clock = MovableClock()
        let store = makeStore(clock: clock)

        let envelope = Self.envelope(id: "e-2")
        try store.issueEnvelope(envelope: envelope, now: clock.now())
        XCTAssertEqual(store.liveEnvelopes().count, 1)
        XCTAssertEqual(store.liveEnvelopes()[0].grants.count, 2)

        store.revokeEnvelope("e-2")
        XCTAssertEqual(store.liveEnvelopes().count, 0)
    }

    /// An envelope expires as a UNIT.
    func testAnEnvelopeExpiresAsAUnit() throws {
        let clock = MovableClock()
        let store = makeStore(clock: clock)

        try store.issueEnvelope(envelope: Self.envelope(id: "e-3"), now: clock.now())
        XCTAssertEqual(store.liveEnvelopes().count, 1)
        clock.advance(by: .seconds(31))
        XCTAssertEqual(
            store.liveEnvelopes().count, 0,
            "an envelope outlived the duration it promised",
        )
    }

    // MARK: - Issuance refusals

    /// A grant to an UNRESOLVED caller is refused.
    func testAGrantToAnUnresolvedCallerIsRefused() throws {
        let clock = MovableClock()
        let store = makeStore(clock: clock)

        XCTAssertThrowsError(try store.issue(
            capability: .clipboardRead,
            scope: AuthorizationScope(application: .any),
            duration: .monotonicSeconds(600),
            holder: Self.identity(fullyResolved: false),
            request: Self.clipboardRequest,
        )) { error in
            XCTAssertEqual(error as? GrantIssuanceError, .unresolvedHolder)
        }
        XCTAssertEqual(store.liveGrants().count, 0)
    }

    /// A count of zero or less authorizes nothing while looking like a grant.
    func testANonPositiveOperationCountIsRefused() throws {
        let clock = MovableClock()
        let store = makeStore(clock: clock)

        for count in [0, -1] {
            XCTAssertThrowsError(try store.issue(
                capability: .transactionManage,
                scope: AuthorizationScope(application: .any, operationLimit: 1),
                duration: .monotonicSeconds(600),
                holder: Self.identity(),
                remainingOperations: count,
                request: Self.clipboardRequest,
            )) { error in
                XCTAssertEqual(error as? GrantIssuanceError, .nonPositiveOperationCount(count))
            }
        }
    }

    /// A `.once` grant completes with the request it authorized and is never added to standing grants.
    func testAOnceGrantIsNeverLive() throws {
        let clock = MovableClock()
        let store = makeStore(clock: clock)

        let granted = try store.issue(
            capability: .clipboardRead,
            scope: AuthorizationScope(application: .any),
            duration: .once,
            holder: Self.identity(),
            request: Self.clipboardRequest,
        )
        XCTAssertEqual(granted.expiresAt, clock.now())
        XCTAssertEqual(store.liveGrants().count, 0)
        XCTAssertTrue(store.persistedContents().grants.isEmpty)
        XCTAssertFalse(granted.authorizes(Self.clipboardRequest, identity: Self.identity(), now: clock.now()))
    }

    /// Expired grants are pruned from memory.
    func testExpiredGrantsAreRemovedFromTheStore() throws {
        let clock = MovableClock()
        let store = makeStore(clock: clock)

        _ = try store.issue(
            capability: .clipboardRead,
            scope: AuthorizationScope(application: .any),
            duration: .monotonicSeconds(60),
            holder: Self.identity(),
        )
        XCTAssertEqual(store.persistedContents().grants.count, 1)

        clock.advance(by: .seconds(61))
        let removed = store.pruneExpired()
        XCTAssertEqual(removed, 1)
        XCTAssertTrue(store.persistedContents().grants.isEmpty)

        let next = store.pruneExpired()
        XCTAssertEqual(next, 0)
    }

    /// A long run of expiring grants leaves a bounded memory footprint.
    func testAWeekOfExpiringGrantsLeavesABoundedMemoryStore() throws {
        let clock = MovableClock()
        let store = makeStore(clock: clock)

        for _ in 0 ..< 200 {
            _ = try store.issue(
                capability: .clipboardRead,
                scope: AuthorizationScope(application: .any),
                duration: .monotonicSeconds(1),
                holder: Self.identity(),
            )
            clock.advance(by: .seconds(2))
            store.pruneExpired()
        }
        let contents = store.persistedContents()
        XCTAssertTrue(contents.grants.isEmpty, "every short-lived grant expired and was swept")
        XCTAssertLessThanOrEqual(contents.grants.count, 200)
    }

    /// A revoked grant stops authorizing and is removed from memory.
    func testARevokedGrantIsNotRetained() throws {
        let clock = MovableClock()
        let store = makeStore(clock: clock)

        let granted = try store.issue(
            capability: .clipboardRead,
            scope: AuthorizationScope(application: .any),
            duration: .monotonicSeconds(3600),
            holder: Self.identity(),
        )
        store.revoke(granted.id)
        XCTAssertTrue(store.persistedContents().grants.isEmpty)
        XCTAssertFalse(store.liveGrants().contains { $0.id == granted.id })
    }

    // MARK: - Envelope fixture

    private static func envelope(
        id: String,
        capability: Capability = .clipboardRead,
        scope: AuthorizationScope? = nil,
        duration: GrantDuration = .monotonicSeconds(30),
        now: MonotonicInstant? = nil,
    ) -> PreAuthorizationEnvelope {
        let at = now ?? MonotonicInstant(nanoseconds: 1_000_000_000)
        let resolved = scope ?? AuthorizationScope(
            application: .bundleIdentifier("com.apple.TextEdit"),
            operationLimit: 1,
        )
        let expiry = duration == .once ? at : at.advanced(by: .seconds(duration.seconds ?? 0))
        return PreAuthorizationEnvelope(
            id: id,
            grants: [
                Grant(
                    id: "\(id)-g1",
                    capability: capability,
                    scope: resolved,
                    duration: duration,
                    holder: identity().code.binding,
                    issuedAt: at,
                    expiresAt: expiry,
                    origin: .envelope(id: id),
                    remainingOperations: 5,
                    targetIsHighConsequence: false,
                ),
                Grant(
                    id: "\(id)-g2",
                    capability: .windowObserve,
                    scope: resolved,
                    duration: duration,
                    holder: identity().code.binding,
                    issuedAt: at,
                    expiresAt: expiry,
                    origin: .envelope(id: id),
                    remainingOperations: nil,
                    targetIsHighConsequence: false,
                ),
            ],
            declaredDuration: duration,
            expiresAt: expiry,
            holder: identity().code.binding,
        )
    }

    // MARK: - Filter validation tests

    func testListGrantsFilterGrammarValidation() {
        let clock = MovableClock()
        let store = makeStore(clock: clock)
        let now = clock.now()

        let (emptyResp, emptyErr) = AuthorizationMethods.listGrants(
            store: store,
            filter: "",
            now: now,
            pageSize: 10,
            skip: 0,
        )
        XCTAssertNil(emptyErr)
        XCTAssertEqual(emptyResp.grants.count, 0)

        let (validResp, validErr) = AuthorizationMethods.listGrants(
            store: store,
            filter: "clipboard.read, observation.window",
            now: now,
            pageSize: 10,
            skip: 0,
        )
        XCTAssertNil(validErr)
        XCTAssertEqual(validResp.grants.count, 0)

        let (_, emptyTokenErr) = AuthorizationMethods.listGrants(
            store: store,
            filter: "clipboard.read,,observation.window",
            now: now,
            pageSize: 10,
            skip: 0,
        )
        XCTAssertNotNil(emptyTokenErr)
        XCTAssertEqual(emptyTokenErr?.code, .invalidArgument)

        let (_, unknownTokenErr) = AuthorizationMethods.listGrants(
            store: store,
            filter: "clipboard.read,not_a_real_capability",
            now: now,
            pageSize: 10,
            skip: 0,
        )
        XCTAssertNotNil(unknownTokenErr)
        XCTAssertEqual(unknownTokenErr?.code, .invalidArgument)
    }
}
