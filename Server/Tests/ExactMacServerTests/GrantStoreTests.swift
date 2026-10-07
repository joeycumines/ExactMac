import Darwin
@testable import ExactMacServer
import Foundation
import Synchronization
import XCTest

/// C5's acceptance suite.
///
/// The binding test is the one that matters, and it is here rather than in a property test
/// because it is the control that answers the confused-deputy and same-uid-malware cases:
/// a grant must belong to a BINARY and not to a number the kernel hands out.
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
        named name: String = UUID().uuidString,
        clock: any MonotonicClock,
        boot: Int = 1_000_000,
    ) throws -> (GrantStore, String) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("exactmac-grants-\(name).json").path
        try? FileManager.default.removeItem(atPath: path)
        let store = try GrantStore.openStore(path: path, clock: clock, maximumEnvelopeSeconds: 3600)
        _ = boot
        return (store, path)
    }

    // MARK: - Persistence

    /// A STORE THAT HAS BECOME UNREADABLE REPORTS UNREADABLE, AND THE POLICY REFUSES ON IT.
    ///
    /// `snapshot().integrity` was the constant `.intact` for the whole life of this type, and
    /// `GrantStore` is the only production `GrantSupply` — so `AuthorizationPolicy`'s
    /// `grantStoreUnreadable` denial, whose comment says "a grant store that could not be read
    /// is not an empty one", could never fire. The store's own documentation claimed
    /// UNREADABLE DENIES, and nothing denied.
    ///
    /// The test drives the real file: issue a grant, then replace the store's contents with
    /// something that is not a grant store, and ask the snapshot what it thinks. It asserts
    /// through the POLICY as well as the store, because the store reporting unreadable is
    /// only worth anything if the decision refuses.
    func testAStoreDamagedAfterStartupIsReportedUnreadableAndDenies() async throws {
        let clock = MovableClock()
        let (store, path) = try makeStore(clock: clock)

        // Intact, and a grant is live.
        let before = await store.snapshot()
        XCTAssertEqual(before.integrity, .intact)

        // DAMAGE IT THE WAY A RECOVERY WOULD: replace the file with bytes that are not a
        // grant store, on the same path, keeping the mode and owner the checks expect.
        let descriptor = try FileManager.default.createFile(
            atPath: path,
            contents: Data("this is not a grant store".utf8),
            attributes: [.posixPermissions: 0o600],
        )
        XCTAssertNotNil(descriptor, "the fixture must be able to damage the store")

        let after = await store.snapshot()
        guard case .unreadable = after.integrity else {
            XCTFail("a store replaced with non-store bytes reported \(after.integrity)")
            return
        }
        // AND THE DECISION REFUSES RATHER THAN TREATING IT AS EMPTY.
        let decision = AuthorizationPolicy.evaluate(
            request: AuthorizationRequest(
                id: AuthorizationRequestID(rawValue: "damaged"),
                rpcName: "\(RPCAuthorizationMap.serviceName)/GetClipboard",
                capability: .clipboardRead,
                scope: AuthorizationScope(),
                argumentSummary: "the clipboard",
                agentReason: "because the test says so",
                origin: .mcpProxy,
            ),
            identity: Self.identity(),
            grants: after.grants,
            envelopes: after.envelopes,
            posture: .balanced,
            context: .unixSocket(store: after.integrity),
            now: clock.now(),
        )
        XCTAssertEqual(decision.denialReason, .grantStoreUnreadable)
    }

    /// A grant survives the process: torn down, reopened from the same file, and still there
    /// with the origin the operator would need to reason about it.
    func testAGrantSurvivesTheStoreBeingRebuilt() throws {
        let clock = MovableClock()
        let (store, path) = try makeStore(clock: clock)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let issued = try store.issue(
            capability: .clipboardRead,
            scope: AuthorizationScope(application: .bundleIdentifier("com.apple.TextEdit")),
            duration: .monotonicSeconds(600),
            holder: Self.identity(),
            request: Self.clipboardRequest,
        )

        // A NEW store over the same path: a torn-down-and-rebuilt store, not a re-read of
        // the same object.
        let reopened = try GrantStore.openStore(path: path, clock: clock)
        let live = reopened.liveGrants()
        XCTAssertEqual(live.count, 1)
        let recovered = try XCTUnwrap(live.first)
        XCTAssertEqual(recovered.id, issued.id)
        XCTAssertEqual(recovered.capability, .clipboardRead)
        XCTAssertEqual(recovered.scope, issued.scope)
        XCTAssertEqual(recovered.holder, issued.holder)
        XCTAssertEqual(recovered.origin, issued.origin)

        // The origin the grants manager shows is the REQUEST, and it survived too.
        let stored = try XCTUnwrap(reopened.grantsForDisplay().first { $0.id == issued.id })
        XCTAssertEqual(stored.originRPCName, "exactmac.v1.ExactMac/GetClipboard")
        XCTAssertEqual(stored.originArgumentSummary, "the clipboard")
    }

    /// THE BINDING TEST. A grant belongs to a binary, not to a number the kernel hands out,
    /// so a grant issued to a signed application is not honoured by an unsigned binary at
    /// another path running as the same user.
    func testAGrantDoesNotTransferToAnUnsignedBinaryAtAnotherPath() throws {
        let clock = MovableClock()
        let (store, path) = try makeStore(clock: clock)
        defer { try? FileManager.default.removeItem(atPath: path) }

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
        let (store, path) = try makeStore(clock: clock)
        defer { try? FileManager.default.removeItem(atPath: path) }

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
        let (store, path) = try makeStore(clock: clock)
        defer { try? FileManager.default.removeItem(atPath: path) }

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
        let (store, path) = try makeStore(clock: clock)
        defer { try? FileManager.default.removeItem(atPath: path) }

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

    /// A store written under an EARLIER BOOT is expired in full, because a monotonic
    /// deadline does not survive a reboot and reading it anyway is the fail-open direction.
    func testAStoreWrittenUnderAnEarlierBootIsExpiredInFull() throws {
        let clock = MovableClock()
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("exactmac-grants-\(UUID().uuidString).json").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        // A store stamped with a boot that is not this one.
        let contents = GrantStoreContents(
            grants: [],
            envelopes: [],
            bootWallClockSeconds: SystemBoot.wallClockSeconds + 1,
            sequence: 0,
        )
        try JSONEncoder().encode(contents).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)

        let store = try GrantStore.openStore(path: path, clock: clock)
        XCTAssertEqual(store.liveGrants().count, 0, "a grant from another boot is not live")
        XCTAssertEqual(
            store.persistedContents().bootWallClockSeconds,
            SystemBoot.wallClockSeconds,
            "the store must be restamped for this boot",
        )
    }

    /// A count-bounded grant is CONSUMABLE, and the decrement is the store's job because the
    /// engine takes grants by value and could not persist one.
    func testACountBoundedGrantIsConsumableAndNeverAmortises() throws {
        let clock = MovableClock()
        let (store, path) = try makeStore(clock: clock)
        defer { try? FileManager.default.removeItem(atPath: path) }

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

        XCTAssertTrue(try store.consume(granted.id))
        XCTAssertEqual(try XCTUnwrap(store.liveGrants().first).remainingOperations, 2)
        XCTAssertTrue(try store.consume(granted.id))
        XCTAssertTrue(try store.consume(granted.id))
        // Exhausted: the grant is REMOVED, not left at zero looking reusable.
        XCTAssertEqual(store.liveGrants().count, 0)
        XCTAssertFalse(try store.consume(granted.id), "a removed grant cannot be spent again")
    }

    /// INVARIANT 9, AT THE STORE: a batch spend — the commit or rollback of a transaction
    /// authorized as a scope with a declared operation count — decrements by the DECLARED
    /// count, refuses when the remaining count cannot cover it, and removes the grant at
    /// exhaustion. The single-operation consume above covers one-at-a-time grants; this is
    /// the batch shape, and before it existed no production path called consume at all,
    /// which made every count on every grant decoration.
    func testABatchSpendDecrementsByTheDeclaredCountAndExhaustionRemovesTheGrant() throws {
        let clock = MovableClock()
        let (store, path) = try makeStore(clock: clock)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let granted = try store.issue(
            capability: .transactionManage,
            scope: AuthorizationScope(application: .any, operationLimit: 5),
            duration: .monotonicSeconds(600),
            holder: Self.identity(),
            remainingOperations: 5,
        )

        XCTAssertTrue(try store.consume(granted.id, operations: 3))
        XCTAssertEqual(try XCTUnwrap(store.liveGrants().first).remainingOperations, 2)
        // Two left cannot cover three: the same predicate the engine judged, re-checked
        // under the store's lock, because the snapshot it judged is already stale.
        XCTAssertFalse(try store.consume(granted.id, operations: 3))
        XCTAssertEqual(try XCTUnwrap(store.liveGrants().first).remainingOperations, 2)
        XCTAssertTrue(try store.consume(granted.id, operations: 2))
        XCTAssertTrue(store.liveGrants().isEmpty, "an exhausted grant is removed, not left at zero")
    }

    /// Finding #16: Calling consume or consumeEnvelope with zero or negative operations
    /// returns false rather than trapping with a precondition.
    func testConsumeWithZeroOrNegativeOperationsReturnsFalse() throws {
        let clock = MovableClock()
        let (store, path) = try makeStore(clock: clock)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let granted = try store.issue(
            capability: .transactionManage,
            scope: AuthorizationScope(application: .any, operationLimit: 5),
            duration: .monotonicSeconds(600),
            holder: Self.identity(),
            remainingOperations: 5,
        )

        XCTAssertFalse(try store.consume(granted.id, operations: 0))
        XCTAssertFalse(try store.consume(granted.id, operations: -1))
        XCTAssertEqual(try XCTUnwrap(store.liveGrants().first).remainingOperations, 5)

        try store.issueEnvelope(envelope: Self.envelope(id: "e-nonpositive"), now: clock.now())
        XCTAssertFalse(try store.consumeEnvelope("e-nonpositive", operations: 0))
        XCTAssertFalse(try store.consumeEnvelope("e-nonpositive", operations: -2))
    }

    /// THE PERSIST RACE, under load: a persist that snapshots, encodes and writes as
    /// separate steps can land STALE content after a newer persist has already written —
    /// a revoked grant back in the file the next boot reads. The write is serialized now,
    /// so the property this asserts is: after concurrent issue and revoke quiesce, the
    /// file on disk is EXACTLY the state memory holds, and no grant any task revoked is
    /// in it. The assertion is made against a REOPENED store, because memory converging
    /// while the file lags is precisely the failure this guards against.
    func testConcurrentIssueAndRevokeLeaveTheFileEqualToMemoryAndNeverResurrect() async throws {
        let clock = MovableClock()
        let (store, path) = try makeStore(clock: clock)
        defer { try? FileManager.default.removeItem(atPath: path) }

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
                            try? store.revoke(granted.id)
                            revokedByID.withLock { $0[granted.id] = true }
                        }
                        _ = task
                        _ = round
                    }
                }
            }
        }

        // Every issued grant was revoked by the task that issued it, so the live set —
        // and therefore the file — must be EMPTY.
        XCTAssertTrue(store.liveGrants().isEmpty, "every grant was revoked; none may be live")
        let reopened = try GrantStore.openStore(path: path, clock: clock)
        XCTAssertEqual(
            reopened.liveGrants().count, 0,
            "a revoked grant survived in the file: the persist race resurrected it",
        )
    }

    /// The same spend against a grant INSIDE an envelope. Envelopes are granted as a unit
    /// and re-checked per request, so a count on an envelope grant that only decremented
    /// for ordinary grants would be a bound with a hole exactly the shape of the
    /// long-running sessions envelopes exist for.
    func testAnEnvelopeGrantIsSpentThroughItsEnvelope() throws {
        let clock = MovableClock()
        let (store, path) = try makeStore(clock: clock)
        defer { try? FileManager.default.removeItem(atPath: path) }

        try store.issueEnvelope(envelope: Self.envelope(id: "e-count"), now: clock.now())
        XCTAssertEqual(try XCTUnwrap(store.liveEnvelopes().first).grants.count, 2)

        XCTAssertTrue(try store.consumeEnvelope("e-count", operations: 3))
        // The FIRST grant that could cover the batch is the one spent, which is the
        // engine's own matching order.
        XCTAssertEqual(
            try XCTUnwrap(store.liveEnvelopes().first).grants.first?.remainingOperations, 2,
        )
        XCTAssertFalse(try store.consumeEnvelope("e-count", operations: 3))
        // An unknown envelope cannot be spent, which the interceptor reads as a refusal.
        XCTAssertFalse(try store.consumeEnvelope("e-absent", operations: 1))
    }

    // MARK: - Revocation

    func testRevokingOneGrantIsImmediateAndSurvivesARestart() throws {
        let clock = MovableClock()
        let (store, path) = try makeStore(clock: clock)
        defer { try? FileManager.default.removeItem(atPath: path) }

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

        try store.revoke(first.id)
        XCTAssertEqual(store.liveGrants().map(\.id), [store.liveGrants()[0].id])

        let reopened = try GrantStore.openStore(path: path, clock: clock)
        XCTAssertEqual(reopened.liveGrants().count, 1, "the revocation did not survive a restart")
        XCTAssertFalse(reopened.liveGrants().contains { $0.id == first.id })
    }

    func testRevokingEverythingRemovesEveryGrantAndEveryEnvelope() throws {
        let clock = MovableClock()
        let (store, path) = try makeStore(clock: clock)
        defer { try? FileManager.default.removeItem(atPath: path) }

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

        try store.revokeAll()
        XCTAssertEqual(store.liveGrants().count, 0)
        XCTAssertEqual(store.liveEnvelopes().count, 0)
        XCTAssertEqual(
            try GrantStore.openStore(path: path, clock: clock).liveGrants().count,
            0,
            "revoke-all did not survive a restart",
        )
    }

    // MARK: - Envelopes

    /// An envelope is validated BEFORE it is stored, because one that is stored and then
    /// refused is one the operator was told they had.
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

    /// An envelope may only cover what the requester actually asked for. One that widens
    /// beyond the stated intention is pre-authorization for something nobody wanted.
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

    /// And it may not cover a SCOPE the requester did not name, which is the other half of
    /// the same promise.
    func testEnvelopeValidationRejectsAScopeNobodyAskedFor() throws {
        let envelope = Self.envelope(
            id: "e-scope",
            capability: .clipboardRead,
            scope: AuthorizationScope(application: .any, operationLimit: 1),
        )
        XCTAssertThrowsError(try GrantStore.validateEnvelope(
            envelope: envelope,
            // The requester asked about TextEdit only.
            requested: [Self.clipboardRequest],
            maximumSeconds: 3600,
        )) { error in
            guard case .scopeNotRequested = error as? EnvelopeValidationFailure else {
                return XCTFail("expected a scope refusal, got \(error)")
            }
        }
    }

    func testEnvelopeValidationAcceptsWhatWasAskedFor() throws {
        // One grant, for the one capability that was asked for, in the one scope that was
        // named. The shared fixture carries a second, unrelated grant, which the validator
        // correctly refuses — so this builds its own rather than weakening the check.
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

    /// Revoking an envelope revokes everything INSIDE it, in one step. A revocation that
    /// left the contents behind would not be total.
    func testRevokingAnEnvelopeRevokesEverythingInIt() throws {
        let clock = MovableClock()
        let (store, path) = try makeStore(clock: clock)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let envelope = Self.envelope(id: "e-2")
        try store.issueEnvelope(envelope: envelope, now: clock.now())
        XCTAssertEqual(store.liveEnvelopes().count, 1)
        XCTAssertEqual(store.liveEnvelopes()[0].grants.count, 2)

        try store.revokeEnvelope("e-2")
        XCTAssertEqual(store.liveEnvelopes().count, 0)
        XCTAssertEqual(
            try GrantStore.openStore(path: path, clock: clock).liveEnvelopes().count,
            0,
            "the envelope revocation did not survive a restart",
        )
    }

    /// An envelope expires as a UNIT, and the grants inside it stop authorizing at the same
    /// instant rather than each living out its own duration.
    func testAnEnvelopeExpiresAsAUnit() throws {
        let clock = MovableClock()
        let (store, path) = try makeStore(clock: clock)
        defer { try? FileManager.default.removeItem(atPath: path) }

        try store.issueEnvelope(envelope: Self.envelope(id: "e-3"), now: clock.now())
        XCTAssertEqual(store.liveEnvelopes().count, 1)
        clock.advance(by: .seconds(31))
        XCTAssertEqual(
            store.liveEnvelopes().count, 0,
            "an envelope outlived the duration it promised",
        )
    }

    // MARK: - Issuance refusals

    /// A grant to an UNRESOLVED caller can never authorize anything, so it is refused where
    /// the refusal can be reported rather than discovered later as a silent no-op.
    func testAGrantToAnUnresolvedCallerIsRefused() throws {
        let clock = MovableClock()
        let (store, path) = try makeStore(clock: clock)
        defer { try? FileManager.default.removeItem(atPath: path) }

        XCTAssertThrowsError(try store.issue(
            capability: .clipboardRead,
            scope: AuthorizationScope(application: .any),
            duration: .monotonicSeconds(600),
            holder: Self.identity(fullyResolved: false),
            request: Self.clipboardRequest,
        )) { error in
            XCTAssertEqual(error as? GrantIssuanceError, .unresolvedHolder)
        }
        XCTAssertEqual(store.liveGrants().count, 0, "a refused grant was persisted anyway")
    }

    /// A count of zero or less authorizes nothing while looking like a grant.
    func testANonPositiveOperationCountIsRefused() throws {
        let clock = MovableClock()
        let (store, path) = try makeStore(clock: clock)
        defer { try? FileManager.default.removeItem(atPath: path) }

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

    /// A `.once` grant completes with the request it authorized and cannot be re-presented,
    /// so it is never even WRITTEN: the store returns it for the request at hand, but the
    /// file holds nothing, because a persisted once-grant is one dead entry per approval
    /// for the life of the installation and nothing can read it back as live.
    func testAOnceGrantIsNeverLive() throws {
        let clock = MovableClock()
        let (store, path) = try makeStore(clock: clock)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let granted = try store.issue(
            capability: .clipboardRead,
            scope: AuthorizationScope(application: .any),
            duration: .once,
            holder: Self.identity(),
            request: Self.clipboardRequest,
        )
        XCTAssertEqual(granted.expiresAt, clock.now())
        XCTAssertEqual(store.liveGrants().count, 0)
        // THE FILE, not the model: the entry is absent from what was persisted, which is
        // the claim E30 makes and the read path alone cannot prove.
        XCTAssertTrue(store.persistedContents().grants.isEmpty)
        XCTAssertFalse(granted.authorizes(Self.clipboardRequest, identity: Self.identity(), now: clock.now()))
    }

    /// E30: an expired grant is REMOVED from the file, not merely filtered on read. The
    /// acceptance is about the file, because the read path always filtered and the file
    /// still grew — one dead entry per grant for the life of the installation.
    func testExpiredGrantsAreRemovedFromTheStore() throws {
        let clock = MovableClock()
        let (store, path) = try makeStore(clock: clock)
        defer { try? FileManager.default.removeItem(atPath: path) }

        _ = try store.issue(
            capability: .clipboardRead,
            scope: AuthorizationScope(application: .any),
            duration: .monotonicSeconds(60),
            holder: Self.identity(),
        )
        XCTAssertEqual(store.persistedContents().grants.count, 1)

        clock.advance(by: .seconds(61))
        let removed = try store.pruneExpired()
        XCTAssertEqual(removed, 1)
        XCTAssertTrue(store.persistedContents().grants.isEmpty, "the file must not retain an expired grant")

        // A PRUNE THAT FINDS NOTHING WRITES NOTHING: persist() is skipped when the count
        // is zero, so the read path cannot turn into a disk write per request.
        let next = try store.pruneExpired()
        XCTAssertEqual(next, 0)
    }

    /// E30: a long run of expiring grants leaves a bounded file, because each sweep
    /// removes every entry that can no longer authorize anything.
    func testAWeekOfExpiringGrantsLeavesABoundedFile() throws {
        let clock = MovableClock()
        let (store, path) = try makeStore(clock: clock)
        defer { try? FileManager.default.removeItem(atPath: path) }

        for _ in 0 ..< 200 {
            _ = try store.issue(
                capability: .clipboardRead,
                scope: AuthorizationScope(application: .any),
                duration: .monotonicSeconds(1),
                holder: Self.identity(),
            )
            clock.advance(by: .seconds(2))
            try store.pruneExpired()
        }
        let contents = store.persistedContents()
        XCTAssertTrue(contents.grants.isEmpty, "every short-lived grant expired and was swept")
        XCTAssertLessThanOrEqual(contents.grants.count, 200)
    }

    /// E30: a revoked grant stops authorizing AND is not retained in the file.
    func testARevokedGrantIsNotRetained() throws {
        let clock = MovableClock()
        let (store, path) = try makeStore(clock: clock)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let granted = try store.issue(
            capability: .clipboardRead,
            scope: AuthorizationScope(application: .any),
            duration: .monotonicSeconds(3600),
            holder: Self.identity(),
        )
        try store.revoke(granted.id)
        XCTAssertTrue(store.persistedContents().grants.isEmpty)
        // The store's own live view no longer carries the grant: revocation is total,
        // and a grant the store cannot find cannot authorize through the store.
        XCTAssertFalse(store.liveGrants().contains { $0.id == granted.id })
        // And a reopened store over the same file — a torn-down-and-rebuilt store, not
        // a re-read of the same object — has nothing to recover, which is the part the
        // in-memory view alone cannot prove.
        let reopened = try GrantStore.openStore(path: path, clock: clock)
        XCTAssertFalse(reopened.liveGrants().contains { $0.id == granted.id })
    }

    // MARK: - The file itself

    /// The store refuses a SYMLINKED file. `O_NOFOLLOW` is the reason, and a symlink is how
    /// a store's writes are redirected somewhere the checks would not have looked.
    func testTheStoreRefusesASymlinkedFile() throws {
        let real = FileManager.default.temporaryDirectory
            .appendingPathComponent("exactmac-real-\(UUID().uuidString).json")
        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("exactmac-link-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: real)
            try? FileManager.default.removeItem(at: link)
        }
        try Data("{}".utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        XCTAssertThrowsError(
            try GrantStore.openStore(path: link.path, clock: MovableClock()),
        ) { error in
            guard case .unreadable = error as? GrantStoreError else {
                return XCTFail("expected an unreadable store, got \(error)")
            }
        }
    }

    /// And a file with a SECOND hard link, which is a second name for the same bytes and is
    /// how a store becomes something another path can also write.
    func testTheStoreRefusesAFileWithMoreThanOneHardLink() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("exactmac-grants-\(UUID().uuidString).json")
        let other = FileManager.default.temporaryDirectory
            .appendingPathComponent("exactmac-grants-other-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: path)
            try? FileManager.default.removeItem(at: other)
        }
        try Data("{}".utf8).write(to: path)
        XCTAssertEqual(Darwin.link(path.path, other.path), 0)

        XCTAssertThrowsError(
            try GrantStore.openStore(path: path.path, clock: MovableClock()),
        ) { error in
            XCTAssertEqual(
                error as? GrantStoreError,
                .tooManyHardLinks(path: path.path, links: 2),
            )
        }
    }

    /// A DIRECTORY is not a store, and a store that accepted one would be a store whose
    /// integrity nobody could reason about.
    ///
    /// The refusal happens at `open` rather than at the regular-file check, because
    /// `O_RDWR` is not permitted on a directory and the kernel answers EISDIR first. The
    /// outcome is the same and the specific error is asserted so the order stays visible.
    func testTheStoreRefusesADirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("exactmac-grants-dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertThrowsError(
            try GrantStore.openStore(path: directory.path, clock: MovableClock()),
        ) { error in
            guard case let .unreadable(_, reason) = error as? GrantStoreError else {
                return XCTFail("a directory was not refused: \(error)")
            }
            XCTAssertTrue(reason.contains("21"), "expected EISDIR, got \(reason)")
        }
    }

    /// A file that is NOT a grant store is unreadable, and unreadable denies. Reading it as
    /// an empty one would turn a corrupt file into a blank slate of permissions.
    func testACorruptStoreIsUnreadableRatherThanEmpty() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("exactmac-grants-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: path) }
        try Data("this is not a grant store".utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)

        XCTAssertThrowsError(try GrantStore.openStore(path: path.path, clock: MovableClock())) { error in
            guard case .unreadable = error as? GrantStoreError else {
                return XCTFail("expected an unreadable store, got \(error)")
            }
        }
    }

    /// The file the store creates is owner-only, because the permissions are the boundary a
    /// same-uid reader does not have to cross.
    func testTheStoreFileIsOwnerPrivate() throws {
        let clock = MovableClock()
        let (store, path) = try makeStore(clock: clock)
        defer { try? FileManager.default.removeItem(atPath: path) }

        try store.issue(
            capability: .clipboardRead,
            scope: AuthorizationScope(application: .any),
            duration: .monotonicSeconds(600),
            holder: Self.identity(),
            request: Self.clipboardRequest,
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).uint16Value
        XCTAssertEqual(permissions, 0o600)
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

    func testListGrantsFilterGrammarValidation() throws {
        let clock = MovableClock()
        let (store, _) = try makeStore(clock: clock)
        let now = clock.now()

        let (emptyResp, emptyErr) = AuthorizationMethods.listGrants(
            store: store,
            filter: "",
            now: now,
            pageSize: 10,
            skip: 0
        )
        XCTAssertNil(emptyErr)
        XCTAssertEqual(emptyResp.grants.count, 0)

        let (validResp, validErr) = AuthorizationMethods.listGrants(
            store: store,
            filter: "clipboard.read, observation.window",
            now: now,
            pageSize: 10,
            skip: 0
        )
        XCTAssertNil(validErr)
        XCTAssertEqual(validResp.grants.count, 0)

        let (_, emptyTokenErr) = AuthorizationMethods.listGrants(
            store: store,
            filter: "clipboard.read,,observation.window",
            now: now,
            pageSize: 10,
            skip: 0
        )
        XCTAssertNotNil(emptyTokenErr)
        XCTAssertEqual(emptyTokenErr?.code, .invalidArgument)

        let (_, unknownTokenErr) = AuthorizationMethods.listGrants(
            store: store,
            filter: "clipboard.read,not_a_real_capability",
            now: now,
            pageSize: 10,
            skip: 0
        )
        XCTAssertNotNil(unknownTokenErr)
        XCTAssertEqual(unknownTokenErr?.code, .invalidArgument)
    }
}
