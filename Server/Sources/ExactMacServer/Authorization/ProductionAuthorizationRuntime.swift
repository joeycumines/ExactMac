import Darwin
import Foundation
import GRPCCore
import GRPCHealthService
import os

// MARK: - Where the server's own state lives

/// The one place the server, the operator interface and the deployment documentation agree on
// MARK: - The audit

/// Where a decision goes on the record.
///
/// A PROTOCOL rather than a direct call to `DecisionAudit` because the interceptor must be
/// able to run with no audit at all in the tests that are about something else, and because
/// "record this" and "record this, or refuse the RPC" are different requirements and the
/// caller has to be able to ask for each.
protocol DecisionRecording: Sendable {
    /// - Returns: whether the decision is on the record.
    @discardableResult
    func record(
        request: AuthorizationRequest,
        identity: CallerIdentity,
        decision: AuthorizationDecision,
        operatorNote: String?,
        biometricObtained: Bool,
        refusalReason: DenialReason?,
    ) -> Bool
}

/// The production recorder, and the only one that can satisfy Invariant 1.
///
/// EVERY DISPOSITION GOES THROUGH HERE, allows and refusals alike, because a log that
/// records what was permitted is a log that cannot be asked what was refused.
struct AuditDecisionRecorder: DecisionRecording {
    private let audit: DecisionAudit

    init(audit: DecisionAudit) {
        self.audit = audit
    }

    @discardableResult
    func record(
        request: AuthorizationRequest,
        identity: CallerIdentity,
        decision: AuthorizationDecision,
        operatorNote: String? = nil,
        biometricObtained: Bool = false,
        refusalReason: DenialReason? = nil,
    ) -> Bool {
        audit.record(
            request: request,
            identity: identity,
            decision: decision,
            operatorNote: operatorNote,
            biometricObtained: biometricObtained,
            refusalReason: refusalReason,
        ) != nil
    }
}

// MARK: - The grant store as the interceptor's supply and issuer

/// The store as the interceptor reads it.
///
/// `GrantStore.snapshot()` already returns exactly `GrantSnapshot`, including the integrity
/// that makes an UNREADABLE store deny rather than present a blank slate of permissions, so
/// this is a name for the conformance rather than a translation.
struct GrantStoreSupply: GrantSupply {
    private let store: GrantStore

    init(store: GrantStore) {
        self.store = store
    }

    func snapshot() async -> GrantSnapshot {
        await store.snapshot()
    }

    func consume(_ grantIdentifier: String, operations: Int) async -> Bool {
        store.consume(grantIdentifier, operations: operations)
    }

    func consumeEnvelope(_ envelopeIdentifier: String, operations: Int) async -> Bool {
        store.consumeEnvelope(envelopeIdentifier, operations: operations)
    }
}

/// Turning the operator's answer into a grant that is persisted before the caller is told.
///
/// THE SELECTED OPTION IS WHAT IS ISSUED, not what the caller asked for and not what the
/// engine's decision happened to name. A consent answer carries the option the operator
/// clicked, and the scope, duration and operation count come from that option — so the
/// operator's choice is the grant, and a mismatch is a refusal rather than a silent upgrade.
struct GrantStoreIssuance: GrantIssuing {
    private let store: GrantStore

    init(store: GrantStore) {
        self.store = store
    }

    func authorize(
        answer: ConsentAnswer,
        request: AuthorizationRequest,
        identity: CallerIdentity,
        offered: [OfferedDecision],
        now: MonotonicInstant,
    ) async throws -> AuthorizationDecision {
        // `.deny` never issues. A consent answer that approved but selected nothing has
        // therefore not selected a grant, and inventing the narrowest one would be the
        // interceptor deciding what the operator agreed to.
        guard let kind = answer.selected, kind != .deny else {
            return Self.refusal(for: request, identity: identity, reason: .notPermitted)
        }
        // An option THIS ENGINE did not offer is an answer about something else, and the only
        // safe reading of it is that nothing was agreed.
        guard let option = offered.first(where: { $0.kind == kind }) else {
            return Self.refusal(for: request, identity: identity, reason: .notPermitted)
        }

        let scope = option.scope
        if option.kind == .preAuthorizeEnvelope {
            let grant = Self.makeGrant(
                capability: request.capability,
                scope: scope,
                duration: option.duration,
                identity: identity,
                now: now,
                origin: .prompt(decidedAt: now),
            )
            let envelope = PreAuthorizationEnvelope(
                id: "envelope-\(UUID().uuidString)",
                grants: [grant],
                declaredDuration: option.duration,
                expiresAt: grant.expiresAt,
                holder: identity.code.binding,
            )
            // Validated BEFORE it is stored, and by the store's own four refusals, so the
            // agent guidance can be written against them rather than against a store that
            // silently accepted something.
            try GrantStore.validateEnvelope(
                envelope: envelope,
                requested: [request],
                maximumSeconds: store.maximumEnvelopeSeconds,
            )
            let stored = try store.issueEnvelope(envelope: envelope, now: now)
            return Self.decision(
                for: request,
                identity: identity,
                outcome: .allow,
                basis: .envelope(id: stored.id),
                expiresAt: stored.expiresAt,
                offered: offered,
            )
        }

        let grant = try store.issue(
            capability: request.capability,
            scope: scope,
            duration: option.duration,
            holder: identity,
            now: now,
            remainingOperations: scope.operationLimit,
            origin: .prompt(decidedAt: now),
            request: request,
        )
        return Self.decision(
            for: request,
            identity: identity,
            outcome: .allow,
            basis: .grant(id: grant.id),
            expiresAt: grant.expiresAt,
            offered: offered,
        )
    }

    /// The same grant the store would build for itself, for the envelope that carries it.
    private static func makeGrant(
        capability: Capability,
        scope: AuthorizationScope,
        duration: GrantDuration,
        identity: CallerIdentity,
        now: MonotonicInstant,
        origin: GrantOrigin,
    ) -> Grant {
        Grant(
            id: "grant-\(UUID().uuidString)",
            capability: capability,
            scope: scope,
            duration: duration,
            holder: identity.code.binding,
            issuedAt: now,
            // `.once` expires as it is issued, so a once-grant can never sit in a live store
            // looking reusable. The same arithmetic the store uses, so the envelope's
            // deadline and the grant's cannot disagree.
            expiresAt: duration == .once
                ? now
                : now.advanced(by: .seconds(duration.seconds ?? 0)),
            origin: origin,
            remainingOperations: scope.operationLimit,
            targetIsHighConsequence: false,
        )
    }

    /// A decision shaped like every other one, so a store that cannot issue produces the same
    /// answer a policy denial would rather than a different kind of failure.
    ///
    /// THE CAPABILITIES ARE THE REQUEST'S CLOSURE and the signature is the CALLER'S, both
    /// read from the same places the engine reads them: an issued decision that understated
    /// what was permitted would be a decision the audit log and the prompt disagree with.
    private static func decision(
        for request: AuthorizationRequest,
        identity: CallerIdentity,
        outcome: AuthorizationDecision.Outcome,
        basis: DecisionBasis,
        expiresAt: MonotonicInstant?,
        offered: [OfferedDecision],
    ) -> AuthorizationDecision {
        let effectiveSignature: SignatureState = identity.isFullyResolved
            ? identity.code.signature
            : .unresolved
        let radius = AuthorizationPolicy.blastRadius(
            capability: request.capability,
            scope: request.scope,
            duration: .once,
            remainingCount: request.scope.operationLimit,
            targetIsHighConsequence: false,
            signatureQuality: effectiveSignature.quality,
        )
        return AuthorizationDecision(
            outcome: outcome,
            basis: basis,
            effectiveCapabilities: request.capability.impliedCapabilities,
            blastRadius: radius,
            riskClass: radius.riskClass,
            biometric: .notRequired,
            offeredDecisions: offered,
            expiresAt: expiresAt,
        )
    }

    private static func refusal(
        for request: AuthorizationRequest,
        identity: CallerIdentity,
        reason: DenialReason,
    ) -> AuthorizationDecision {
        var refused = decision(
            for: request,
            identity: identity,
            outcome: .deny,
            basis: .denied(reason),
            expiresAt: nil,
            offered: [],
        )
        refused.biometric = .notRequired
        return refused
    }
}

// MARK: - The real authorization runtime

/// The real authorization runtime, and the one place the server's own state is created.
///
/// IT EXISTS AS A SINGLE VALUE rather than as arguments threaded through `main`, because the
/// failure this project keeps meeting is a runtime assembled from defaults: `NoStandingGrants`,
/// no operator to ask, `isConsoleReachable` false, a nil recorder. Each of those denies, so
/// each is safe, and together they are a system that cannot do anything while looking as
/// though it is running. Assembling them here makes the set of things the server is actually
/// using one readable list, and adding a dependency is a visible edit.
struct ProductionAuthorizationRuntime {
    /// The consent aspect's own health entry, so the reduced posture is VISIBLE rather than a
    /// log line nobody reads. The gRPC health protocol has no "degraded" status, and reporting
    /// the service itself as not serving would be the other kind of false: the TCP variant
    /// does serve, and every consent-requiring capability on it is denied.
    static let consentHealthServiceName = "exactmac.v1.ExactMac.consent"

    /// `ServingStatus` has no "degraded", and the consent aspect is a real question rather
    /// than a flavour of the service's health, so it gets its own name in the health service
    /// and the mapping is a function of the one fact that answers it.
    static func consentServingStatus(isConsoleReachable: Bool) -> ServingStatus {
        isConsoleReachable ? .serving : .notServing
    }

    let registry: ConnectionPeerRegistry
    let auditPath: String
    let authorizationRuntime: AuthorizationRuntime
    let consentTimeout: Duration
    /// The live posture, shared with the host: the console's settings control writes the
    /// operator's choice HERE, and the interceptor reads it per request. THE ENVIRONMENT
    /// OVERRIDE IS SETTLED AT CONSTRUCTION, below — an operator preference cannot
    /// override a deployment-level setting, and the control says so when it holds.
    let postureSource: PostureSource
    /// The live console gate, shared with the host the same way: whether opening Grants
    /// or Activity costs a ceremony is enforcement state the console displays and the
    /// toggle writes. `make` SEEDS it from the stored gate, so the control's first render
    /// after a relaunch shows the choice that survived it.
    let biometricGate: BiometricGateSource

    /// - Throws: when the state directory or the audit log cannot be established.
    ///   Startup fails rather than continuing with a component missing.
    static func make(
        config: ServerConfig,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        consent: ConsentAnswering? = nil,
    ) throws -> ProductionAuthorizationRuntime {
        try ExactMacPaths.prepareApplicationSupportDirectory(environment: environment)

        let clock = SystemMonotonicClock()
        let auditPath = ExactMacPaths.auditLogPath(environment: environment)
        let registry = ConnectionPeerRegistry()

        // THE POSTURE ORDERING, decided once here: the environment override wins, then the
        // operator's stored preference (loaded from the state directory, because it must
        // survive a relaunch), then strict — the engine's own fail-closed default. An
        // unparseable preference file is NOT a preference, so it reads as strict rather
        // than as a guess.
        let envOverride: Posture? = switch environment["EXACTMAC_POSTURE"]?.lowercased() {
        case "balanced": .balanced
        case "lockeddown", "locked_down", "locked-down": .lockedDown
        case "strict": .strict
        default: nil
        }
        let postureSource = PostureSource(override: envOverride)
        let biometricGateSource = BiometricGateSource()

        let audit: DecisionAudit
        do {
            audit = try DecisionAudit(path: auditPath, clock: clock)
        } catch {
            throw ExactMacRuntimeError.auditUnavailable(reason: String(describing: error))
        }
        let store = GrantStore(
            clock: clock,
            maximumEnvelopeSeconds: config.maximumEnvelopeSeconds,
        )

        let consentTimeout = Duration.seconds(config.consentTimeoutSeconds)
        let descriptorPolicy = try PublicRequestDescriptorPolicy.load()
        let runtime = AuthorizationRuntime.unixSocket(
            descriptorPolicy: descriptorPolicy,
            grants: GrantStoreSupply(store: store),
            // A NIL HANDLER DENIES, and that is the standalone server's actual state: it
            // installs nothing, so it starts and refuses every consent-requiring capability
            // rather than granting anything it could not have shown an operator. It is not
            // an error, because a service that is down is harder to diagnose than one that is
            // up and denying. A HOST passes its own handler and gets the same fail-closed
            // behaviour for a request it declines to answer.
            consent: consent,
            issuance: GrantStoreIssuance(store: store),
            clock: clock,
            postureSource: postureSource,
            consentTimeout: consentTimeout,
            // Reachability now agrees with the handler: a process that was given something to
            // ask with can ask, and one that was given nothing cannot. Deriving the two from
            // the same value is what stops them failing closed independently.
            isConsoleReachable: consent != nil,
            peerEvidence: .registry(registry),
            audit: AuditDecisionRecorder(audit: audit),
            auditRequired: true,
        )
        ServerInspectionService.register(
            store: store,
            audit: audit,
            clock: clock,
            stateDirectory: ExactMacPaths.applicationSupportDirectory(environment: environment),
        )
        return ProductionAuthorizationRuntime(
            registry: registry,
            auditPath: auditPath,
            authorizationRuntime: runtime,
            consentTimeout: consentTimeout,
            postureSource: postureSource,
            biometricGate: biometricGateSource,
        )
    }
}
