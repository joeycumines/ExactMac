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
        var instant = timespec()
        clock_gettime(CLOCK_MONOTONIC, &instant)
        let seconds = UInt64(clamping: instant.tv_sec)
        let nanos = UInt64(clamping: instant.tv_nsec)
        return MonotonicInstant(nanoseconds: seconds &* 1_000_000_000 &+ nanos)
    }
}

/// Standing grants and envelopes, as they are RIGHT NOW, plus the store's own integrity.
///
/// A separate protocol rather than a parameter so C5's store supplies it, and so a test
/// can say "the store is unreadable" without inventing a file.
protocol GrantSupply: Sendable {
    func snapshot() async -> GrantSnapshot
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
}

// MARK: - Consent

/// What the operator said.
///
/// It names the request it answers, so a decision cannot be applied to a different one,
/// and it carries the biometric outcome because "a biometric was required" and "a
/// biometric was obtained" are different facts.
struct ConsentAnswer: Sendable, Equatable {
    var requestID: AuthorizationRequestID
    var isApproved: Bool
    var selected: OfferedDecision.Kind?
    var note: String?
    /// Only true when a ceremony was actually performed for THIS request. C6's nonce binds
    /// the two, so a success cannot be replayed onto another decision.
    var biometricObtained: Bool = false
}

/// Where consent decisions come from.
///
/// Returns nil when there is no console to ask, which the interceptor treats as a denial.
/// It is nil and not an error because "the console is not running" is not a fault in the
/// caller, and the two must not be distinguishable from outside.
protocol ConsentBroker: Sendable {
    func obtainConsent(
        for request: AuthorizationRequest,
        identity: CallerIdentity,
        decision: AuthorizationDecision,
    ) async -> ConsentAnswer?
}

/// The production broker until the console channel exists.
///
/// IT DENIES, and that is the whole implementation. There is no consent path yet, so there
/// is no consent, and a system that cannot ask must not proceed as though it had. This is
/// what makes the interceptor safe to ship before C7: a missing capability is a denial
/// rather than an allow.
struct UnavailableConsentBroker: ConsentBroker {
    func obtainConsent(
        for _: AuthorizationRequest,
        identity _: CallerIdentity,
        decision _: AuthorizationDecision,
    ) async -> ConsentAnswer? {
        nil
    }
}

/// Turning an approval into an authorization: the grant that is issued, persisted, and
/// what the caller is finally told.
///
/// Separate from the broker because the broker is about the OPERATOR and this is about the
/// STORE, and C5 replaces only this one.
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
    var consent: any ConsentBroker
    var issuance: any GrantIssuing
    var clock: any MonotonicClock
    var posture: Posture
    /// A bounded wait for the operator. Past it, deny.
    var consentTimeout: Duration
    /// Whether a console is connected AND has authenticated, asked at the moment a request
    /// needs one rather than captured at construction.
    ///
    /// A FUNCTION because a constant is wrong in both directions here. Captured `true` when
    /// no console is running makes the interceptor take the consent path and then deny on the
    /// timeout, which the caller experiences as a slow refusal; captured `false` when one is
    /// running makes a working service permanently unusable. A test still passes a literal,
    /// because the factory wraps it.
    var isConsoleReachable: @Sendable () -> Bool
    var biometric: AuthorizationContext.BiometricAvailability
    var highConsequenceTargets: Set<String>
    /// The application resolver C2 needs to turn an opaque application name into the
    /// application it names. The server's own catalog in production.
    var applicationResolver: any ApplicationTargetResolving
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
    /// Whether a decision that could not be recorded may still be enforced.
    ///
    /// FALSE IN PRODUCTION, and the refusal it produces is `auditUnavailable`: an
    /// unrecordable decision is not a decision this system is willing to act on, because the
    /// whole point of the log is that the operator can afterwards ask what was permitted.
    var auditRequired: Bool

    /// The Unix-socket variant, which is the only one with an identity and the only one
    /// that can consent.
    static func unixSocket(
        descriptorPolicy: PublicRequestDescriptorPolicy,
        grants: any GrantSupply = NoStandingGrants(),
        consent: any ConsentBroker = UnavailableConsentBroker(),
        issuance: any GrantIssuing = NoGrantIssuance(),
        clock: any MonotonicClock = SystemMonotonicClock(),
        posture: Posture = .balanced,
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
            posture: posture,
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
        posture: Posture = .balanced,
    ) -> AuthorizationRuntime {
        AuthorizationRuntime(
            descriptorPolicy: descriptorPolicy,
            identity: .unavailableTransport,
            grants: grants,
            consent: UnavailableConsentBroker(),
            issuance: NoGrantIssuance(),
            clock: clock,
            posture: posture,
            consentTimeout: .seconds(120),
            // The console is irrelevant here: the posture denies before anything is asked,
            // and reporting it reachable would let a caller infer a working consent path.
            isConsoleReachable: { false },
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
        // Every method of the service is authorized, including the three that need no
        // consent, so the set of methods that bypass this is empty by construction rather
        // than by remembering to add each one to a list.
        guard context.descriptor.service.fullyQualifiedService == RPCAuthorizationMap.serviceName
        else {
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
                context: context,
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

    private func authorize(
        method: String,
        message: any Sendable,
        metadata: Metadata,
        context: ServerContext,
    ) async throws -> AuthorizationDecision {
        guard let protobuf = message as? any SwiftProtobuf.Message else {
            throw AuthorizationDenial(
                reason: .notPermitted,
                capability: .localEcho,
            )
        }
        let now = runtime.clock.now()
        let requestID = AuthorizationRequestID(rawValue: Self.requestIdentifier(method: method, at: now))
        let request = await AuthorizationRequestDeriver.derive(
            method: method,
            message: protobuf,
            policy: runtime.descriptorPolicy,
            requestID: requestID,
            agentReason: Self.agentReason(from: metadata),
            origin: Self.origin(of: metadata),
            operationLimit: nil,
            resolver: runtime.applicationResolver,
        )
        // An unmapped method yields NO request, which at the interceptor is a refusal. This
        // is the second reason the map is total rather than merely broad: a method with no
        // capability has no way to be authorized, so it cannot be reached.
        guard let request else {
            throw AuthorizationDenial(reason: .notPermitted, capability: .localEcho)
        }

        let identity = resolveIdentity(for: context)
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
            posture: runtime.posture,
            context: context,
            now: now,
        )

        switch decision.basis {
        case .noConsentRequired, .grant, .envelope:
            return try recorded(decision, for: request, identity: identity)
        case .promptRequired:
            let answered = try await prompt(request: request, identity: identity, decision: decision)
            return try recorded(
                answered.decision,
                for: request,
                identity: identity,
                answer: answered.answer,
            )
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
    private func prompt(
        request: AuthorizationRequest,
        identity: CallerIdentity,
        decision: AuthorizationDecision,
    ) async throws -> (decision: AuthorizationDecision, answer: ConsentAnswer) {
        guard runtime.isConsoleReachable() else {
            throw AuthorizationDenial(reason: .consoleUnreachable, capability: request.capability)
        }
        // Whether a ceremony is required is NOT checked here. It is checked against the
        // ANSWER, because the engine is pure and cannot know whether a ceremony happened,
        // and asking the operator first is what a user who cannot authenticate expects
        // rather than a refusal they cannot understand.

        let answer = await withConsentTimeout(runtime.consentTimeout) {
            await runtime.consent.obtainConsent(for: request, identity: identity, decision: decision)
        }

        guard let answer else {
            throw AuthorizationDenial(
                reason: .consoleUnreachable,
                capability: request.capability,
            )
        }
        // An answer for a different request is not an answer. This is the confused deputy
        // in its narrowest form: two pending requests, one decision, applied to both.
        guard answer.requestID == request.id else {
            throw AuthorizationDenial(reason: .notPermitted, capability: request.capability)
        }
        guard answer.isApproved else {
            throw AuthorizationDenial(reason: .notPermitted, capability: request.capability)
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
            throw AuthorizationDenial(
                reason: .biometricUnavailable,
                capability: request.capability,
            )
        }

        let issued = try await runtime.issuance.authorize(
            answer: answer,
            request: request,
            identity: identity,
            offered: decision.offeredDecisions,
            now: runtime.clock.now(),
        )
        return (decision: issued, answer: answer)
    }

    /// Races the broker against the bound, and CANCELS the broker's work when the bound
    /// wins — an operator answering a request the caller has already been refused is work
    /// nothing should be doing.
    private func withConsentTimeout(
        _ timeout: Duration,
        _ body: @Sendable @escaping () async -> ConsentAnswer?,
    ) async -> ConsentAnswer? {
        await withTaskGroup(of: ConsentAnswer?.self) { group in
            group.addTask { await body() }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
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
    static let agentReasonMetadataKey = "exactmac-agent-reason"

    /// The agent's reason, or nil.
    ///
    /// A BLANK header is treated as ABSENT rather than as a reason, because a header an agent
    /// can set to "" has satisfied the requirement without saying anything. The policy
    /// escalates a reasonless request rather than treating it as routine, and that
    /// escalation is only honest if an empty string does not count as a reason.
    static func agentReason(from metadata: Metadata) -> String? {
        let values = metadata[stringValues: agentReasonMetadataKey]
        guard let value: String = values.first(where: { _ in true }) else { return nil }
        return value.isEmpty ? nil : value
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
