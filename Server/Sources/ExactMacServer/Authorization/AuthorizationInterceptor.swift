import Darwin
import ExactMacProto
import Foundation
import GRPCCore
import os
import SwiftProtobuf
import Synchronization

// MARK: - What the interceptor is given

/// The monotonic clock, injected because a deadline that cannot be tested is a deadline
/// that is only believed.
protocol MonotonicClock: Sendable {
    func now() -> MonotonicInstant
}

/// `CLOCK_MONOTONIC`, and never `Date`: a wall-clock change must not be able to extend or
/// end a deadline, which is the same reason grant expiry is monotonic.
struct SystemMonotonicClock: MonotonicClock {
    func now() -> MonotonicInstant {
        MonotonicInstant.now()
    }
}

/// Standing grants and envelopes, as they are RIGHT NOW, plus the store's own integrity.
///
/// A separate protocol rather than a parameter so C5's store supplies it, and so a test
/// can say "the store is unreadable" without inventing a file.
protocol GrantSupply: Sendable {
    func snapshot() async -> GrantSnapshot
    /// Spends `operations` from a count-bounded grant. False when the grant cannot cover
    /// it — revoked, expired, or fewer operations left than the scope declared.
    ///
    /// DECLARED, NOT DEFAULTED, and the default is refusal: a supply that implements only
    /// `snapshot` cannot truthfully claim a spend happened, and a spend that did not
    /// happen is a bound that does not exist. The production store implements both;
    /// `NoStandingGrants` refuses both. INVARIANT 9 lives here as much as in the engine:
    /// a count on a grant that is never decremented is decoration.
    func consume(_ grantIdentifier: String, operations: Int) async -> Bool
    /// The same spend against a grant inside a pre-authorization envelope.
    func consumeEnvelope(_ envelopeIdentifier: String, operations: Int) async -> Bool
}

struct GrantSnapshot: Sendable, Equatable {
    var grants: [Grant] = []
    var envelopes: [PreAuthorizationEnvelope] = []
    /// An unreadable store is not an empty one. Treating it as empty would turn a corrupt
    /// file into a blank slate of permissions, which is the fail-OPEN direction.
    var integrity: AuthorizationContext.StoreIntegrity = .intact
}

/// The production supply until the store exists: nothing is standing, and the store is
/// intact. Deny-by-default rather than allow-by-default is the entire point of the
/// interceptor, and a supply that reported an unreadable store would deny EVERYTHING,
/// so it reports an intact empty one.
struct NoStandingGrants: GrantSupply {
    func snapshot() async -> GrantSnapshot {
        GrantSnapshot()
    }

    func consume(_: String, operations _: Int) async -> Bool {
        false
    }

    func consumeEnvelope(_: String, operations _: Int) async -> Bool {
        false
    }
}

// MARK: - Consent

/// What the operator said.
///
/// It names the request it answers, so a decision cannot be applied to a different one,
/// and it carries the biometric outcome because "a biometric was required" and "a
/// biometric was obtained" are different facts.
public struct ConsentAnswer: Sendable, Equatable {
    public var requestID: AuthorizationRequestID
    public var isApproved: Bool
    public var selected: OfferedDecision.Kind?
    public var note: String?
    /// THE CEREMONY'S PROOF, or nil when none was performed or none was claimed.
    ///
    /// IT REPLACED A BOOLEAN, and the boolean WAS the defect. `biometricObtained: true` said a
    /// ceremony happened and the interceptor took it at face value, so anything able to return
    /// an answer could satisfy the requirement for a fingerprint without one. With the operator
    /// interface hosted in the same process that is not a remote attacker — it is a bug in the
    /// app, and invariant 3 is about the app as much as about a stranger.
    ///
    /// A proof names the request, carries a single-use nonce the server minted for this
    /// decision, and expires. The server checks all three and spends the nonce atomically, so
    /// one ceremony authorizes one decision and cannot be replayed onto a second.
    public var ceremonyProof: BiometricProof?

    /// Whether a ceremony was performed, DERIVED from the proof rather than stated beside it.
    ///
    /// DERIVED, because a boolean stored next to a proof is a second source of truth: a `true`
    /// beside a nil proof would claim a ceremony the server can see did not happen, which is
    /// the exact state a downgrade produces.
    public var biometricObtained: Bool {
        ceremonyProof != nil
    }

    /// A host constructs the answer it hands back to the server that asked, and the
    /// memberwise initialiser of a public struct is internal, so this is the seam.
    public init(
        requestID: AuthorizationRequestID,
        isApproved: Bool,
        selected: OfferedDecision.Kind? = nil,
        note: String? = nil,
        ceremonyProof: BiometricProof? = nil,
    ) {
        self.requestID = requestID
        self.isApproved = isApproved
        self.selected = selected
        self.note = note
        self.ceremonyProof = ceremonyProof
    }
}

/// Whom the interceptor asks, and what they said.
///
/// A FUNCTION, not a strategy object, and the reason is that there is nothing left to
/// abstract over. The protocol this replaced existed so the SERVER could ask a console in
/// another PROCESS, and it had four conformances — one per combination of "nobody to ask",
/// "ask an endpoint", and two test doubles. The operator interface is hosted in this process
/// now, so there is one question with one shape and one way of failing to answer it: nil. A
/// caller supplies one of these and the interceptor calls it; there is no hierarchy to
/// implement and no variant to select.
///
/// NIL IS THE DENIAL, and it is nil rather than an error because "there is nobody to ask" is
/// not a fault in the caller, and the two must not be distinguishable from outside. There is
/// no type to construct for "nobody to answer" — there is only nil.
public typealias ConsentAnswering = @Sendable (
    _ request: AuthorizationRequest,
    _ identity: CallerIdentity,
    _ decision: AuthorizationDecision,
) async -> ConsentAnswer?

/// Turning an approval into an authorization: the grant that is issued, persisted, and
/// what the caller is finally told.
///
/// Separate from the ask because the ask is about the OPERATOR and this is about the
/// STORE, and the store is the one that can be replaced without changing who decides.
protocol GrantIssuing: Sendable {
    func authorize(
        answer: ConsentAnswer,
        request: AuthorizationRequest,
        identity: CallerIdentity,
        offered: [OfferedDecision],
        now: MonotonicInstant,
    ) async throws -> AuthorizationDecision
}

/// The production issuer until the store exists: an approval cannot become a grant, so the
/// caller is still refused. It throws rather than returning a decision, because returning
/// one would mean inventing a grant that nothing persists.
struct NoGrantIssuance: GrantIssuing {
    func authorize(
        answer _: ConsentAnswer,
        request _: AuthorizationRequest,
        identity _: CallerIdentity,
        offered _: [OfferedDecision],
        now _: MonotonicInstant,
    ) async throws -> AuthorizationDecision {
        throw RPCError(
            code: .permissionDenied,
            message: "authorization is unavailable: no grant store is present",
        )
    }
}

// MARK: - Settings and wiring

/// The kernel's answer about the connected socket behind ONE rpc, resolved at enforcement time.
///
/// A FUNCTION OVER THE CONTEXT rather than a value, because the evidence is per-connection
/// and the interceptor is per-RPC, and because `ServerContext` is the only handle the
/// pinned gRPC stack gives an interceptor. Production resolves it through
/// `ConnectionPeerRegistry`; a test says "this call arrived with no evidence" or "with this
/// evidence" without inventing a socket. The nil case is the fail-closed one and the engine
/// escalates it, so a resolver that fails is a system that denies rather than one that
/// proceeds as though it knew.
struct PeerProcessResolution: Sendable {
    var resolve: @Sendable (ServerContext) -> PeerProcessEvidence?

    /// Production: the registry the listener writes to, keyed by the connection token the
    /// transport reports in the peer description.
    static func registry(_ registry: ConnectionPeerRegistry) -> PeerProcessResolution {
        PeerProcessResolution { context in
            registry.evidence(forPeerDescription: context.remotePeer)
        }
    }

    /// Nothing is known about any connection, which is the TCP posture and the shape a test
    /// uses to say "this call has no identifiable caller".
    static let unavailable = PeerProcessResolution { _ in nil }

    /// One fixed answer for every call, which is the only shape a test can use and the
    /// reason production does not go through here.
    static func fixed(_ evidence: PeerProcessEvidence?) -> PeerProcessResolution {
        PeerProcessResolution { _ in evidence }
    }
}

/// Everything the interceptor needs, gathered so a test can vary one thing at a time and
/// production cannot accidentally omit one.
struct AuthorizationRuntime: Sendable {
    var descriptorPolicy: PublicRequestDescriptorPolicy
    var identity: CallerIdentitySource
    var grants: any GrantSupply
    /// Whom to ask, or nil when this process has no operator interface installed.
    ///
    /// NIL IS A STATED POSTURE, not a shortcut, and it is the same shape as `audit` below: a
    /// runtime with nobody to ask is a runtime that denies, which is safe, and it is
    /// production's actual state until the host installs an operator interface. What it must
    /// never become is a fallback: a nil handler does not degrade to anything.
    var consent: ConsentAnswering?
    var issuance: any GrantIssuing
    var clock: any MonotonicClock
    /// THE POSTURE ACTUALLY IN FORCE, asked at the moment a decision needs it rather
    /// than captured at construction. A captured value is what made the settings control
    /// a lie: the operator changed their mind, and every later request was judged by the
    /// posture the server STARTED with. The source consults the environment override,
    /// then the operator's stored preference, then strict — the same ordering the control
    /// displays.
    var postureSource: PostureSource
    /// A bounded wait for the operator. Past it, deny.
    var consentTimeout: Duration
    /// Whether an operator is able to answer RIGHT NOW, asked at the moment a request needs
    /// one rather than captured at construction.
    ///
    /// A FUNCTION because a constant is wrong in both directions here. Captured `true` when
    /// nobody can answer makes the interceptor take the consent path and then deny on the
    /// timeout, which the caller experiences as a slow refusal; captured `false` when an
    /// operator IS present makes a working service permanently unusable. A test still passes
    /// a literal, because the factory wraps it.
    var isConsoleReachable: @Sendable () -> Bool
    var biometric: AuthorizationContext.BiometricAvailability
    var highConsequenceTargets: Set<String>
    /// The application resolver C2 needs to turn an opaque application name into the
    /// application it names. The server's own catalog in production.
    var applicationResolver: any ApplicationTargetResolving
    /// The count a transaction commit or rollback is authorized AS A SCOPE WITH: how many
    /// operations the named transaction has accumulated, which only the session manager
    /// knows. NIL WHEN THERE IS NO SOURCE, which is a test fixture's shape — production
    /// wires the composition's session manager at `serve`, and a nil here is why the
    /// count was decoration for so long. A request with no transaction id, or a
    /// transaction that has gone away, derives with no count rather than a guessed one.
    var declaredOperationCount: (@Sendable (_ sessionName: String, _ transactionId: String) async -> Int?)?
    /// The kernel's answer about the socket this call arrived on, WHEN THE TRANSPORT CAN
    /// SUPPLY ONE.
    ///
    /// Production resolves it per call through `ConnectionPeerRegistry`, which
    /// `PeerIdentifyingListenerFactory` fills at accept time from `LOCAL_PEERPID` and
    /// `LOCAL_PEERCRED`. `.unavailable` is the TCP posture, where the engine denies before
    /// this is consulted anyway. A lookup that misses — an unnamed peer, a connection that
    /// has closed, a caller that never registered — is an UNRESOLVED identity, which the
    /// engine escalates and which denies.
    var peerEvidence: PeerProcessResolution
    /// Where every decision goes on the record.
    ///
    /// NIL IS NOT A SHORTCUT, IT IS A STATED POSTURE: a runtime with no recorder is one
    /// where nothing can be audited, which is a test fixture and never production. The
    /// production runtime supplies one, and `auditRequired` below turns a missing or failing
    /// recorder into a refusal rather than a silent gap, because Invariant 1 is that no RPC
    /// reaches a handler without a decision on the record.
    var audit: (any DecisionRecording)?
    /// The spent-proof set. ONE PER RUNTIME, not one per call, because spending a nonce is only
    /// meaningful if both attempts look at the same set.
    let ceremonyLedger = BiometricNonceLedger()

    /// Whether a decision that could not be recorded may still be enforced.
    ///
    /// FALSE IN PRODUCTION, and the refusal it produces is `auditUnavailable`: an
    /// unrecordable decision is not a decision this system is willing to act on, because the
    /// whole point of the log is that the operator can afterwards ask what was permitted.
    var auditRequired: Bool

    /// WHETHER AN OPERATOR CAN ANSWER RIGHT NOW, in a process that hosts its own operator
    /// interface and has not been given one.
    ///
    /// NAMED RATHER THAN WRITTEN AS A LITERAL where it is supplied, because the question
    /// changed shape when the console boundary came out. A console in another process had to be
    /// CONNECTED to, so reachability was a fact about a socket and a live closure was the only
    /// honest way to ask it. The operator interface is hosted in THIS process, so reachability
    /// is a fact about whether a consent handler has been installed — which is the host's to
    /// answer, and until the host answers it, this is the answer. It agrees with `consent` being
    /// nil, which is what makes the two fail-closed together: a request that needs a prompt
    /// finds nobody to ask and is denied with `consoleUnreachable` rather than waiting.
    static let noOperatorInterfaceIsInstalled = false

    /// THE SAME FACT AS THE LIVE ANSWER, so the two spellings cannot drift. The runtime stores
    /// a closure because reachability has to be asked at the moment a request needs it; the
    /// factory takes a value because a test that cannot ask a question should not have to.
    static let noOperatorInterfaceInstalled: @Sendable () -> Bool = { noOperatorInterfaceIsInstalled }

    /// The Unix-socket variant, which is the only one with an identity and the only one
    /// that can consent.
    static func unixSocket(
        descriptorPolicy: PublicRequestDescriptorPolicy,
        grants: any GrantSupply = NoStandingGrants(),
        consent: ConsentAnswering? = nil,
        issuance: any GrantIssuing = NoGrantIssuance(),
        clock: any MonotonicClock = SystemMonotonicClock(),
        postureSource: PostureSource,
        consentTimeout: Duration = .seconds(120),
        isConsoleReachable: Bool = false,
        biometric: AuthorizationContext.BiometricAvailability = .available,
        highConsequenceTargets: Set<String> = [],
        applicationResolver: any ApplicationTargetResolving = UnresolvableApplicationTarget(),
        peerEvidence: PeerProcessResolution = .unavailable,
        audit: (any DecisionRecording)? = nil,
        auditRequired: Bool = false,
    ) -> AuthorizationRuntime {
        AuthorizationRuntime(
            descriptorPolicy: descriptorPolicy,
            identity: .unixSocket(
                CallerIdentityResolver(inspector: SystemProcessInspector()),
            ),
            grants: grants,
            consent: consent,
            issuance: issuance,
            clock: clock,
            postureSource: postureSource,
            consentTimeout: consentTimeout,
            isConsoleReachable: { isConsoleReachable },
            biometric: biometric,
            highConsequenceTargets: highConsequenceTargets,
            applicationResolver: applicationResolver,
            peerEvidence: peerEvidence,
            audit: audit,
            auditRequired: auditRequired,
        )
    }

    /// The TCP variant, which has no authenticating principal. There is no resolver to
    /// construct and no consent path to enter, so the reduced posture is a NAMED state
    /// rather than the emergent consequence of a nil dependency.
    static func tcp(
        descriptorPolicy: PublicRequestDescriptorPolicy,
        grants: any GrantSupply = NoStandingGrants(),
        clock: any MonotonicClock = SystemMonotonicClock(),
        postureSource: PostureSource,
    ) -> AuthorizationRuntime {
        AuthorizationRuntime(
            descriptorPolicy: descriptorPolicy,
            identity: .unavailableTransport,
            grants: grants,
            consent: nil,
            issuance: NoGrantIssuance(),
            clock: clock,
            postureSource: postureSource,
            consentTimeout: .seconds(120),
            // The operator is irrelevant here: the posture denies before anything is asked,
            // and reporting it reachable would let a caller infer a working consent path.
            isConsoleReachable: noOperatorInterfaceInstalled,
            biometric: .unavailable(reason: "the reduced unauthenticated posture has no ceremony"),
            highConsequenceTargets: [],
            applicationResolver: UnresolvableApplicationTarget(),
            peerEvidence: .unavailable,
            // The reduced posture records nothing, because there is nothing to record: the
            // TCP variant denies every consent-requiring capability in the engine before any
            // of this is reached, and a log of denials nobody can influence is noise.
            audit: nil,
            auditRequired: false,
        )
    }

    var transport: AuthorizationContext.Transport {
        identity.isIdentityResolutionAvailable ? .unixSocket : .tcp
    }
}

// MARK: - Counters

/// Denials by reason, so a caller cannot distinguish a refusal from a crash by probing and
/// so the operator can see what the system is actually refusing.
/// A final class, not a struct: a `let` of a struct holding a `Mutex` is not `Copyable`,
/// and the counter is shared by every invocation of one interceptor instance.
final class AuthorizationCounters: Sendable {
    private let lock = Synchronization.Mutex<[String: Int]>([:])

    func record(_ reason: DenialReason) {
        lock.withLock { $0[reason.rawValue, default: 0] += 1 }
    }

    var counts: [String: Int] {
        lock.withLock { $0 }
    }

    var total: Int {
        lock.withLock { $0.values.reduce(0, +) }
    }
}

// MARK: - The interceptor

/// Every RPC, authorized, before any handler runs.
///
/// POSITION IS A SECURITY PROPERTY: it is registered AFTER `PublicRequestValidationInterceptor`
/// so a malformed request cannot probe the authorization layer, and BEFORE every handler so
/// none can allocate state, start work or touch the physical desktop without a decision.
///
/// A DENIAL IS NEVER A HANG AND NEVER AN ALLOW. An unreachable console, an unresolvable
/// caller, a timeout, an unreadable store, an unavailable biometric and the reduced
/// transport all deny, and each names itself.
struct AuthorizationInterceptor: ServerInterceptor {
    private let runtime: AuthorizationRuntime
    private let counters: AuthorizationCounters
    private let logger = Logger(
        subsystem: "io.github.joeycumines.exactmac",
        category: "authorization.interceptor",
    )

    init(runtime: AuthorizationRuntime, counters: AuthorizationCounters = AuthorizationCounters()) {
        self.runtime = runtime
        self.counters = counters
    }

    func intercept<Input: Sendable, Output: Sendable>(
        request: StreamingServerRequest<Input>,
        context: ServerContext,
        next: @Sendable (
            _ request: StreamingServerRequest<Input>,
            _ context: ServerContext,
        ) async throws -> StreamingServerResponse<Output>,
    ) async throws -> StreamingServerResponse<Output> {
        // Every method of every authorized service is mapped and authorized, including
        // the ones that need no consent, so the set of methods that bypass this is empty
        // by construction rather than by remembering to add each one to a list. The
        // google.longrunning.Operations service used to be the hole: registered on the
        // server, absent from the map, and waved through this gate — five RPCs reaching
        // handlers with no decision and no record.
        guard RPCAuthorizationMap.authorizedServiceNames.contains(
            context.descriptor.service.fullyQualifiedService,
        ) else {
            return try await next(request, context)
        }

        // The request is buffered so the first message can be derived from and the rest
        // replayed. Every method in this API is unary or server-streaming, so the buffer
        // holds exactly one message; a client-streaming method would make this unbounded,
        // and there is none.
        let messages = try await collect(request.messages)
        guard let first = messages.first else {
            return try await next(
                StreamingServerRequest(
                    metadata: request.metadata,
                    messages: RPCAsyncSequence<Input, any Error>(wrapping: AsyncThrowingStream<Input, Error> { $0.finish() }),
                ),
                context,
            )
        }

        let decision: AuthorizationDecision
        do {
            decision = try await authorize(
                method: context.descriptor.fullyQualifiedMethod,
                message: first,
                metadata: request.metadata,
                serverContext: context,
            )
        } catch let error as AuthorizationDenial {
            counters.record(error.reason)
            logger.info(
                """
                Denied \(context.descriptor.fullyQualifiedMethod, privacy: .public) \
                capability \(error.capability.rawValue, privacy: .public) \
                reason \(error.reason.rawValue, privacy: .public)
                """,
            )
            // The reason and the capability travel back; the TARGET does not. A denial that
            // said "no such window" would tell a probing caller that the window does not
            // exist, which is a disclosure the authorization layer is not there to make.
            throw RPCErrorHelpers.error(
                code: .permissionDenied,
                message: "denied: \(error.reason.rawValue)",
                reason: error.reason.rawValue,
                metadata: [
                    "capability": error.capability.rawValue,
                    "method": context.descriptor.fullyQualifiedMethod,
                ],
            )
        }

        logger.info(
            """
            Allowed \(context.descriptor.fullyQualifiedMethod, privacy: .public) \
            capability \(decision.effectiveCapabilities.map(\.rawValue).sorted().joined(separator: ","), privacy: .public) \
            basis \(Self.describe(decision.basis), privacy: .public) \
            risk \(decision.riskClass.rawValue, privacy: .public)
            """,
        )

        var replayed = messages
        replayed[0] = first
        return try await next(
            StreamingServerRequest(
                metadata: request.metadata,
                messages: RPCAsyncSequence<Input, any Error>(
                    wrapping: AsyncThrowingStream<Input, Error> { continuation in
                        for message in replayed {
                            continuation.yield(message)
                        }
                        continuation.finish()
                    },
                ),
            ),
            context,
        )
    }

    /// THE SERVER CONTEXT IS NAMED `serverContext` AND NOT `context` because the body
    /// builds a local `let context = AuthorizationContext(...)` for the policy engine, which
    /// would otherwise shadow it — and the shadowed value is an `AuthorizationContext`, so
    /// passing `context` to `prompt` would not compile rather than quietly doing something
    /// wrong. Naming the two apart is the difference between a compiler error and a bug.
    private func authorize(
        method: String,
        message: any Sendable,
        metadata: Metadata,
        serverContext: ServerContext,
    ) async throws -> AuthorizationDecision {
        if serverContext.cancellation.isCancelled || Task.isCancelled {
            throw RPCError(code: .cancelled, message: "request was cancelled by the caller")
        }
        guard let protobuf = message as? any SwiftProtobuf.Message else {
            throw AuthorizationDenial(
                reason: .notPermitted,
                capability: .localEcho,
            )
        }
        let now = runtime.clock.now()
        let requestID = AuthorizationRequestID(rawValue: Self.requestIdentifier(method: method, at: now))
        // The transaction's declared operation count is not in the request — no request
        // message in the API carries such a field — it lives in the session manager, so
        // the runtime supplies a source and this is where it is consulted. A transaction
        // commit or rollback is the one call whose scope must name a COUNT, because a
        // single approval covering a batch without a bound is the amortisation invariant
        // 9 forbids. Anything else derives with no count.
        var operationLimit: Int? = nil
        if let source = runtime.declaredOperationCount {
            let facts = RequestFacts(message: protobuf, policy: runtime.descriptorPolicy)
            // RequestFacts keys are camelCased PROTO names, so the field spelled
            // `transaction_id` on the wire reads as `transactionId` here.
            if let sessionName = facts.text("name"), !sessionName.isEmpty,
               let transactionId = facts.text("transactionId"), !transactionId.isEmpty
            {
                operationLimit = await source(sessionName, transactionId)
            }
        }
        let request = await AuthorizationRequestDeriver.derive(
            method: method,
            message: protobuf,
            policy: runtime.descriptorPolicy,
            requestID: requestID,
            agentReason: Self.agentReason(from: metadata),
            origin: Self.origin(of: metadata),
            operationLimit: operationLimit,
            resolver: runtime.applicationResolver,
        )
        // An unmapped method yields NO request, which at the interceptor is a refusal. This
        // is the second reason the map is total rather than merely broad: a method with no
        // capability has no way to be authorized, so it cannot be reached.
        guard let request else {
            throw AuthorizationDenial(reason: .notPermitted, capability: .localEcho)
        }

        let identity = resolveIdentity(for: serverContext)
        let snapshot = await runtime.grants.snapshot()
        var context = AuthorizationContext(
            transport: runtime.transport,
            isConsoleReachable: runtime.isConsoleReachable(),
            // The peer is authenticated by socket access in the Unix-socket variant. In the
            // TCP variant there is no principal at all, and the transport check in the
            // engine denies before this is consulted.
            peerAuthenticated: true,
            biometric: runtime.biometric,
            store: snapshot.integrity,
            highConsequenceTargets: runtime.highConsequenceTargets,
        )
        if !identity.isFullyResolved {
            context.peerAuthenticated = false
        }

        let decision = AuthorizationPolicy.evaluate(
            request: request,
            identity: identity,
            grants: context.peerAuthenticated ? snapshot.grants : [],
            envelopes: context.peerAuthenticated ? snapshot.envelopes : [],
            posture: runtime.postureSource.current,
            context: context,
            now: now,
        )

        switch decision.basis {
        case .noConsentRequired:
            return try recorded(decision, for: request, identity: identity)
        case .grant, .envelope:
            // A COUNT THE SCOPE DECLARED IS SPENT HERE, or the count was decoration: the
            // store decrements what the grant has left, and a grant that reaches zero is
            // gone. This is invariant 9's enforcement point — the engine only ever CHECKS
            // the bound against a snapshot, and a check that never advances the counter
            // authorizes unboundedly.
            //
            // The store disagreeing with the snapshot the policy judged — a revoke or a
            // concurrent spend landing in between — is a refusal, not a race to look
            // through: the fail-closed direction is the only safe reading of "the grant
            // could not cover the count after all".
            if let declared = request.scope.operationLimit {
                let spent: Bool = switch decision.basis {
                case let .grant(id):
                    await runtime.grants.consume(id, operations: declared)
                case let .envelope(id):
                    await runtime.grants.consumeEnvelope(id, operations: declared)
                case .noConsentRequired, .promptRequired, .denied:
                    true
                }
                guard spent else {
                    var denial = decision
                    denial.outcome = .deny
                    denial.basis = .denied(.notPermitted)
                    try record(denial, for: request, identity: identity)
                    throw AuthorizationDenial(reason: .notPermitted, capability: request.capability)
                }
            }
            return try recorded(decision, for: request, identity: identity)
        case .promptRequired:
            // THE ISSUANCE STEP CAN STILL THROW, and it is the one thing that is allowed to:
            // it is the store refusing, not the operator, and a store refusal is a failure of
            // the system rather than a decision about this request. It is turned into a
            // refusal rather than left to unwind, because an unwinding error reaches nobody
            // but the caller — which is the same blindness the consent refusals had.
            let outcome: ConsentOutcome
            let status = Self.reasonStatus(from: metadata)
            do {
                outcome = try await prompt(
                    request: request,
                    identity: identity,
                    decision: decision,
                    context: serverContext,
                    reasonStatus: status,
                )
            } catch let error as RPCError where error.code == .cancelled {
                throw error
            } catch is CancellationError {
                throw RPCError(code: .cancelled, message: "request was cancelled by the caller")
            } catch {
                outcome = .refused(decision, .auditUnavailable)
            }

            switch outcome {
            case let .answered(issuedDecision, answer):
                try record(
                    issuedDecision,
                    for: request,
                    identity: identity,
                    answer: answer,
                )
                return issuedDecision
            case let .refused(refusedDecision, refusalReason):
                try record(
                    refusedDecision,
                    for: request,
                    identity: identity,
                    refusal: refusalReason,
                )
                throw AuthorizationDenial(reason: refusalReason, capability: request.capability)
            case .cancelled:
                // An abandoned request writes NO audit entry: it never reached a decision,
                // and writing an entry would imply the system decided something it did not.
                throw RPCError(code: .cancelled, message: "request was cancelled by the caller")
            }
        case let .denied(reason):
            // A refusal is recorded too. A log that records what was permitted cannot be
            // asked what was refused, and the refusals are the half an operator reads when
            // something did not work.
            try record(decision, for: request, identity: identity)
            throw AuthorizationDenial(reason: reason, capability: request.capability)
        }
    }

    /// Puts a decision on the record, and refuses the RPC when the runtime requires the
    /// record and the decision could not be written.
    private func recorded(
        _ decision: AuthorizationDecision,
        for request: AuthorizationRequest,
        identity: CallerIdentity,
        answer: ConsentAnswer? = nil,
    ) throws -> AuthorizationDecision {
        try record(decision, for: request, identity: identity, answer: answer)
        return decision
    }

    private func record(
        _ decision: AuthorizationDecision,
        for request: AuthorizationRequest,
        identity: CallerIdentity,
        answer: ConsentAnswer? = nil,
        refusal: DenialReason? = nil,
    ) throws {
        guard let recorder = runtime.audit else {
            if runtime.auditRequired {
                throw AuthorizationDenial(
                    reason: .auditUnavailable,
                    capability: request.capability,
                )
            }
            return
        }
        let written = recorder.record(
            request: request,
            identity: identity,
            decision: decision,
            operatorNote: answer?.note,
            biometricObtained: answer?.biometricObtained ?? false,
            // A REFUSAL REACHES THE RECORD, not just the caller. When the consent path
            // refused, `decision` is the engine's promptRequired outcome and the basis alone
            // would read as "asked a person", which is true and is the half that hides the
            // failure. Carrying the reason is what makes the row answer "what was refused",
            // which is the question an operator actually has when something did not work.
            refusalReason: refusal,
        )
        guard written || !runtime.auditRequired else {
            throw AuthorizationDenial(
                reason: .auditUnavailable,
                capability: request.capability,
            )
        }
    }

    /// Identity evidence, and the variant's shape.
    ///
    /// THE EVIDENCE IS RESOLVED PER CALL, from the connection this call arrived on, and the
    /// context is the only thing that says which connection that is. Production looks the
    /// connection's token up in the registry the listener filled at accept; a test supplies
    /// a fixed answer. A lookup that misses is an UNRESOLVED identity, which the engine
    /// escalates and which denies — an unnamed peer, a connection that has since closed, and
    /// the TCP posture all arrive here as the same nil and are all refused.
    private func resolveIdentity(for context: ServerContext) -> CallerIdentity {
        guard let resolver = runtime.identity.resolver else {
            return Self.unresolvedCaller(path: "<no authenticating principal>")
        }
        guard let evidence = runtime.peerEvidence.resolve(context) else {
            return Self.unresolvedCaller(path: "<peer evidence unavailable>")
        }
        return resolver.resolve(evidence)
    }

    /// A placeholder that SAYS it is a placeholder.
    ///
    /// Its path cannot be satisfied by any real binary, so no grant can bind to it, and the
    /// signature state is `unresolved` so it escalates. The two causes get two different
    /// paths because they are genuinely different facts — a transport with no principal at
    /// all, and a transport that has one this connection did not earn — and that difference
    /// is diagnostic only: both are `isFullyResolved: false` and both deny identically.
    private static func unresolvedCaller(path: String) -> CallerIdentity {
        CallerIdentity(
            processIdentifier: 0,
            effectiveUserIdentifier: 0,
            parentProcessIdentifier: nil,
            code: CodeIdentity(
                executablePath: path,
                bundleIdentifier: nil,
                designatedRequirement: nil,
                signature: .unresolved,
            ),
            isFullyResolved: false,
        )
    }

    /// Asks the operator, under a bounded wait, and denies on the bound.
    ///
    /// The bound is a DENIAL and not a default: an operator who does not answer has not
    /// consented, and treating silence as consent is the failure this whole system exists
    /// to prevent.
    ///
    /// NOBODY TO ASK IS THE SAME DENIAL as nobody answering, and it is checked in both of its
    /// forms — `isConsoleReachable` false, and a nil handler — so a process with no operator
    /// interface refuses rather than reporting reachable and then waiting out a timeout it
    /// was always going to lose.
    ///
    /// IT RETURNS THE REFUSAL RATHER THAN THROWING IT, and that is the difference between a
    /// consent-path refusal being auditable and being invisible. A `throw` here propagates
    /// straight out of `authorize`, past the `record(...)` call that the `.promptRequired`
    /// branch makes, and the refusal reaches nobody but the caller. Returning a value keeps
    /// the decision AND the reason together so the caller can write one record carrying both.
    private func prompt(
        request: AuthorizationRequest,
        identity: CallerIdentity,
        decision: AuthorizationDecision,
        context: ServerContext,
        reasonStatus: ReasonStatus = .absent,
    ) async throws -> ConsentOutcome {
        if context.cancellation.isCancelled || Task.isCancelled {
            return .cancelled
        }

        if reasonStatus == .unreadable {
            return .refused(decision, .unreadableAgentReason)
        }
        if reasonStatus == .missing || (reasonStatus == .absent && request.origin == .mcpProxy) {
            return .refused(decision, .missingAgentReason)
        }

        guard runtime.isConsoleReachable(), let consent = runtime.consent else {
            return .refused(decision, .consoleUnreachable)
        }
        // Whether a ceremony is required is NOT checked here. It is checked against the
        // ANSWER, because the engine is pure and cannot know whether a ceremony happened,
        // and asking the operator first is what a user who cannot authenticate expects
        // rather than a refusal they cannot understand.

        let waitResult = await withConsentTimeout(
            runtime.consentTimeout,
            cancellation: context.cancellation,
        ) {
            await consent(request, identity, decision)
        }

        switch waitResult {
        case .cancelled:
            return .cancelled

        case .timedOut:
            // NOBODY ANSWERED. This is a refusal that must reach the record, and note that
            // the reason is `consoleUnreachable` because the ONLY way to reach here is a
            // handler that was asked and returned nothing — which is indistinguishable from
            // a console that vanished, and is treated as exactly that.
            return .refused(decision, .consoleUnreachable)

        case let .answered(answer):
            // An answer for a different request is not an answer. This is the confused deputy
            // in its narrowest form: two pending requests, one decision, applied to both.
            guard answer.requestID == request.id else {
                return .refused(decision, .notPermitted)
            }
            guard answer.isApproved else {
                return .refused(decision, .notPermitted)
            }
            // A decision the ceremony was required for, without the ceremony, is a denial. The
            // check is here rather than inside the engine because the engine is pure and cannot
            // know whether a ceremony happened.
            //
            // THE REQUIREMENT OF THE OPTION THAT WAS SELECTED, NOT OF THE ONE THE PROMPT
            // FOCUSED, and this is a security property rather than a detail. `decision.biometric`
            // is the requirement for the default option, and the default is usually the
            // narrowest: a clipboard read scoped to one application is routine and needs no
            // ceremony, while `allowGlobalPersistent` for the same request needs one. An
            // answer selecting the global option therefore passed a check that was reading the
            // narrow option's bar, and the grant was issued with no fingerprint — defeating the
            // BREADTH x PERSISTENCE rule the engine exists to enforce. An adversarial review of
            // this work found it; it is the same shape as the defect
            // `AuthorizationPolicy.swift` records having fixed once already, one layer up.
            //
            // AN ANSWER NAMING AN OPTION THIS ENGINE DID NOT OFFER CANNOT LOWER THE BAR: the
            // floor is the focused option's own requirement, so an unrecognised or absent
            // selection is judged against the decision rather than against nothing.
            let selectedRequirement = answer.selected
                .flatMap { kind in decision.offeredDecisions.first { $0.kind == kind }?.biometric }
                ?? decision.biometric
            if selectedRequirement.reason != nil, !answer.biometricObtained {
                return .refused(decision, .biometricUnavailable)
            }
            // AND THE CLAIM IS CHECKED, NOT BELIEVED, when the answer does carry one. The check
            // above asks only whether a ceremony was CLAIMED; this asks whether the claim is a
            // proof FOR THIS DECISION that has not been spent and has not expired. The server wrote
            // `BiometricProof` and `BiometricNonceLedger` for exactly this and called neither, so
            // an invariant claimed two load-bearing controls that were dead code.
            if let proof = answer.ceremonyProof {
                let now = runtime.clock.now()
                guard proof.authorizes(request, nonce: decision.ceremonyNonce ?? "", now: now),
                      runtime.ceremonyLedger.spend(proof.nonce)
                else {
                    logger.error(
                        "A ceremony proof for \(request.id.rawValue, privacy: .private) did not authorise this decision.",
                    )
                    return .refused(decision, .biometricUnavailable)
                }
            }

            let issued = try await runtime.issuance.authorize(
                answer: answer,
                request: request,
                identity: identity,
                offered: decision.offeredDecisions,
                now: runtime.clock.now(),
            )
            return .answered(decision: issued, answer: answer)
        }
    }

    private enum ConsentWaitResult: Sendable, Equatable {
        case answered(ConsentAnswer)
        case timedOut
        case cancelled
    }

    /// Races the ask against the bound, the CALLER'S CANCELLATION, and each other.
    ///
    /// It cancels the ask's work when anything else wins — an operator answering a request
    /// the caller has already been refused is work nothing should be doing, and the comment
    /// said so before the code did it.
    ///
    /// CANCELLATION IS A SEPARATE WINNER BECAUSE A TASK TIMEOUT IS NOT ONE. This used to race
    /// the ask against `Task.sleep(for: timeout)` alone, and that sleep was wrapped in `try?`
    /// while a `withTaskGroup` scope joins its children — so `cancelAll()` could not shorten
    /// the wait and the group returned only after the full bound had actually elapsed.
    /// In addition, gRPC delivers cancellation through `ServerContext.RPCCancellationHandle`,
    /// not by cancelling your handler's Task. If you don't check isCancelled or use
    /// `withRPCCancellationHandler`, your handler keeps running after gRPC cancels the RPC.
    ///
    /// When the caller's context is cancelled (via RPCCancellationHandle or Task cancellation),
    /// the consent wait ends immediately: the askTask is cancelled (which dismisses the prompt
    /// in the operator UI and frees the waiter), the child tasks in the group are cancelled,
    /// and the function returns `.cancelled` promptly rather than waiting out the full bound.
    private func withConsentTimeout(
        _ timeout: Duration,
        cancellation: ServerContext.RPCCancellationHandle,
        _ body: @Sendable @escaping () async -> ConsentAnswer?,
    ) async -> ConsentWaitResult {
        if cancellation.isCancelled || Task.isCancelled {
            return .cancelled
        }

        let askTask = Task {
            await body()
        }

        return await withTaskCancellationHandler {
            await withRPCCancellationHandler {
                await withTaskGroup(of: ConsentWaitResult.self) { group in
                    group.addTask {
                        let answer = await askTask.value
                        if cancellation.isCancelled || Task.isCancelled || askTask.isCancelled {
                            return .cancelled
                        }
                        if let answer {
                            return .answered(answer)
                        } else {
                            return .timedOut
                        }
                    }
                    group.addTask {
                        do {
                            try await Task.sleep(for: timeout)
                            return .timedOut
                        } catch {
                            return .cancelled
                        }
                    }
                    group.addTask {
                        do {
                            try await cancellation.cancelled
                            return .cancelled
                        } catch {
                            return .cancelled
                        }
                    }

                    let first = await group.next() ?? .timedOut
                    let isCancelled = cancellation.isCancelled || Task.isCancelled || first == .cancelled
                    group.cancelAll()
                    askTask.cancel()
                    if isCancelled {
                        return .cancelled
                    }
                    return first
                }
            } onCancelRPC: {
                askTask.cancel()
            }
        } onCancel: {
            askTask.cancel()
        }
    }

    private static func describe(_ basis: DecisionBasis) -> String {
        switch basis {
        case .noConsentRequired: "noConsentRequired"
        case .grant: "grant"
        case .envelope: "envelope"
        case .promptRequired: "promptRequired"
        case let .denied(reason): "denied:\(reason.rawValue)"
        }
    }

    /// The gRPC metadata key the Go layer carries the agent's stated reason on.
    ///
    /// IT IS METADATA AND NOT A REQUEST FIELD, which is deliberate on both sides. The reason
    /// is caller-supplied text that the prompt shows inside a field marked NOT VERIFIED;
    /// putting it in the request message would make it look like part of the request being
    /// authorized rather than a claim about it, and the design's whole argument for the
    /// prompt rests on that distinction. It also means adding the reason changed no request
    /// message and therefore no capability and no scope.
    ///
    /// THE "-bin" SUFFIX IS LOAD-BEARING AND NOT COSMETIC. gRPC restricts a plain metadata
    /// value to printable ASCII ([0x20-0x7E]) and validates it in the client before the
    /// request is written, so an ordinary sentence containing an em-dash, a curly quote, an
    /// accent, an emoji or a CJK character would be rejected outright with
    /// `Internal - header key ... contains value with non-printable ASCII characters` — an
    /// internal server fault that did not happen, reported to an agent that is simply trying
    /// to say what it is doing. A "-bin" key is exempt from that check and is base64-encoded
    /// on the wire; reading it through `binaryValues` decodes it here, so the reason reaches
    /// the operator byte-identical to what the agent wrote.
    static let agentReasonMetadataKey = "exactmac-agent-reason-bin"
    static let legacyAgentReasonMetadataKey = "exactmac-agent-reason"

    enum ReasonStatus: Sendable, Equatable {
        case valid(String)
        case missing
        case unreadable
        case absent
    }

    static func reasonStatus(from metadata: Metadata) -> ReasonStatus {
        var iterator = metadata[binaryValues: agentReasonMetadataKey].makeIterator()
        if let bytes = iterator.next() {
            guard !bytes.isEmpty else {
                if let legacy = metadata[stringValues: legacyAgentReasonMetadataKey].first(where: { _ in true }) {
                    let trimmed = legacy.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? .missing : .valid(trimmed)
                }
                return .missing
            }
            guard let string = String(data: Data(bytes), encoding: .utf8) else {
                return .unreadable
            }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? .missing : .valid(trimmed)
        }
        if let legacy = metadata[stringValues: legacyAgentReasonMetadataKey].first(where: { _ in true }) {
            let trimmed = legacy.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? .missing : .valid(trimmed)
        }
        return .absent
    }

    /// The agent's reason, or nil.
    ///
    /// A BLANK header is treated as ABSENT rather than as a reason, because a header an agent
    /// can set to "" has satisfied the requirement without saying anything. The policy
    /// escalates a reasonless request rather than treating it as routine, and that
    /// escalation is only honest if an empty string does not count as a reason.
    ///
    /// READ THROUGH `binaryValues` first, because modern callers use "-bin" and the bytes
    /// are base64 on the wire; the subscript decodes them. If absent, falls back to the
    /// legacy plain `exactmac-agent-reason` string key so that stale or non-binary callers
    /// still have their reason delivered to the operator rather than being dropped.
    ///
    /// NOT VALID UTF-8 IS MARKED UNREADABLE: a reason that cannot be decoded is not one, and
    /// substituting replacement characters would put text in front of the operator that the
    /// agent never wrote.
    static func agentReason(from metadata: Metadata) -> String? {
        switch reasonStatus(from: metadata) {
        case let .valid(reason):
            reason
        case .missing, .unreadable, .absent:
            nil
        }
    }

    /// Where the request came from, which the policy escalates when it cannot attribute one.
    ///
    /// The Go MCP layer announces itself by name. That is a CLAIM and not an identity, and
    /// it is treated as one: the engine raises the risk class for an unattributed origin,
    /// and the peer identity the operator judges comes from the socket rather than from
    /// anything a caller says about itself.
    static let mcpProxyMetadataKey = "exactmac-origin"

    static func origin(of metadata: Metadata) -> RequestOrigin {
        let values = metadata[stringValues: mcpProxyMetadataKey]
        guard values.first(where: { _ in true }) == "mcp" else { return .directSocket }
        return .mcpProxy
    }

    private static func requestIdentifier(method: String, at now: MonotonicInstant) -> String {
        "\(method)#\(now.nanoseconds)"
    }

    private func collect<Input: Sendable>(
        _ messages: RPCAsyncSequence<Input, any Error>,
    ) async throws -> [Input] {
        var collected: [Input] = []
        for try await message in messages {
            collected.append(message)
        }
        return collected
    }
}

// MARK: - Denial

/// A refusal on its way out of the engine, carrying what may be said about it.
struct AuthorizationDenial: Error {
    var reason: DenialReason
    var capability: Capability
}

/// What asking the operator produced.
///
/// A NAMED TYPE RATHER THAN A TUPLE WITH A NIL ANSWER, because the shape is what makes the
/// audit fix reviewable: a refusal is a VALUE the caller must handle, sitting beside the
/// decision that produced it, rather than an exceptional path that unwinds past the
/// recorder. When `prompt` threw, every consent-path refusal skipped `record(...)` entirely
/// and the log could not be asked what it refused; returning the refusal is what puts it back.
enum ConsentOutcome {
    /// The operator answered, and the issuance step turned that into a final decision.
    case answered(decision: AuthorizationDecision, answer: ConsentAnswer)
    /// Nobody answered, nobody could be asked, or the answer did not hold up.
    ///
    /// THE DECISION CARRIES THROUGH UNCHANGED on a refusal. It is the engine's own
    /// `.promptRequired` outcome — what WOULD have been permitted had a person said yes —
    /// and recording it preserves the distinction a fabricated `.denied` basis would erase.
    case refused(AuthorizationDecision, DenialReason)
    /// The caller abandoned or cancelled the request before any decision was reached.
    case cancelled

    var decision: AuthorizationDecision? {
        switch self {
        case let .answered(decision, _): decision
        case let .refused(decision, _): decision
        case .cancelled: nil
        }
    }

    var answer: ConsentAnswer? {
        switch self {
        case let .answered(_, answer): answer
        case .refused, .cancelled: nil
        }
    }

    var refusal: DenialReason? {
        switch self {
        case .answered, .cancelled: nil
        case let .refused(_, reason): reason
        }
    }
}
