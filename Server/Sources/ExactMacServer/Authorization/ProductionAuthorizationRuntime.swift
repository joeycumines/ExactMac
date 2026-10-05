import Darwin
import Foundation
import GRPCCore
import GRPCHealthService
import os

// MARK: - Where the server's own state lives

/// The one place the server, the operator interface and the deployment documentation agree on
/// where state is kept.
///
/// THE PATHS ARE HERE RATHER THAN IN THE CALLERS because they have to agree: a grant store the
/// prompt cannot find, or a state directory the server and the host spell differently, is a
/// service that denies everything and says nothing useful. `~/.exactmac` is one short
/// directory, which is not tidiness — it is the whole point of a single derivation.
enum ExactMacRuntimePaths {
    /// `~/.exactmac`, or `EXACTMAC_STATE_DIRECTORY` when the operator sets it.
    ///
    /// The override exists for the end-to-end verification, which must not write into the
    /// operator's real state, and for a deployment that keeps state on another volume. It is
    /// a plain directory path rather than a bundle of individual overrides, because two
    /// processes disagreeing about where the STATE is the failure, and one variable cannot
    /// express a partial disagreement.
    static func stateDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) -> String {
        if let override = environment["EXACTMAC_STATE_DIRECTORY"], !override.isEmpty {
            return override
        }
        return NSHomeDirectory() + "/.exactmac"
    }

    static func auditLogPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        stateDirectory(environment: environment) + "/audit.log"
    }

    static func grantStorePath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        stateDirectory(environment: environment) + "/grants.json"
    }

    /// Creates the state directory at `0700` if it is absent, and refuses it otherwise.
    ///
    /// REFUSES rather than repairs, because a directory that exists with the wrong mode or the
    /// wrong owner is a fact about something the operator did, and quietly widening or
    /// retaking it is how a store this system treats as private stops being private.
    static func prepareStateDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) throws {
        let path = stateDirectory(environment: environment)
        var info = stat()
        if path.withCString({ lstat($0, &info) }) == 0 {
            guard info.st_mode & mode_t(0o170000) == mode_t(0o040000) else {
                throw ExactMacRuntimeError.statePathIsNotADirectory(path)
            }
            guard info.st_uid == geteuid() else {
                throw ExactMacRuntimeError.stateDirectoryHasWrongOwner(path, actual: info.st_uid)
            }
            let permissions = info.st_mode & 0o777
            guard permissions == 0o700 else {
                throw ExactMacRuntimeError.stateDirectoryIsNotOwnerOnly(path, actual: permissions)
            }
            return
        }
        guard errno == ENOENT else {
            throw ExactMacRuntimeError.systemCall(operation: "lstat", path: path, code: errno)
        }
        guard mkdir(path, 0o700) == 0 else {
            throw ExactMacRuntimeError.systemCall(operation: "mkdir", path: path, code: errno)
        }
    }
}

enum ExactMacRuntimeError: Error, CustomStringConvertible {
    case statePathIsNotADirectory(String)
    case stateDirectoryHasWrongOwner(String, actual: uid_t)
    case stateDirectoryIsNotOwnerOnly(String, actual: mode_t)
    case systemCall(operation: String, path: String, code: Int32)
    case auditUnavailable(reason: String)
    case grantStoreUnavailable(reason: String)

    var description: String {
        switch self {
        case let .statePathIsNotADirectory(path):
            "\(path) exists and is not a directory"
        case let .stateDirectoryHasWrongOwner(path, actual):
            "\(path) is owned by uid \(actual); refusing to use a directory this user does not own"
        case let .stateDirectoryIsNotOwnerOnly(path, actual):
            "\(path) has permissions 0\(String(actual, radix: 8)); expected 0700"
        case let .systemCall(operation, path, code):
            "\(operation) failed for \(path): errno \(code)"
        case let .auditUnavailable(reason):
            "the decision audit is unavailable: \(reason)"
        case let .grantStoreUnavailable(reason):
            "the grant store is unavailable: \(reason)"
        }
    }
}

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
        do {
            return try store.consume(grantIdentifier, operations: operations)
        } catch {
            // A store that cannot be WRITTEN is a store that cannot honestly record a
            // spend, and reporting true would let a bound exist only in the log. The
            // unreadable case denies through the same false an exhausted grant returns.
            return false
        }
    }

    func consumeEnvelope(_ envelopeIdentifier: String, operations: Int) async -> Bool {
        do {
            return try store.consumeEnvelope(envelopeIdentifier, operations: operations)
        } catch {
            return false
        }
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
    let grantStorePath: String
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

    /// - Throws: when the state directory, the audit log or the grant store cannot be
    ///   established. Startup fails rather than continuing with a component missing, because a
    ///   server that cannot record a decision has no reason to be listening, and a grant store
    ///   that cannot be read is the state in which the system must not be granting things.
    static func make(
        config: ServerConfig,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        consent: ConsentAnswering? = nil,
    ) throws -> ProductionAuthorizationRuntime {
        try ExactMacRuntimePaths.prepareStateDirectory(environment: environment)

        let clock = SystemMonotonicClock()
        let auditPath = ExactMacRuntimePaths.auditLogPath(environment: environment)
        let grantStorePath = ExactMacRuntimePaths.grantStorePath(environment: environment)
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
        if envOverride == nil, let stored = PostureSource.loadStoredPreference(environment: environment) {
            postureSource.setStoredPreference(stored)
        }
        // THE GATE IS SEEDED FROM ITS STORED CHOICE — default true, and the loader
        // already answers true for every corrupt shape, so the seed is unconditional.
        let biometricGateSource = BiometricGateSource()
        biometricGateSource.setCeremonyRequired(
            BiometricGateSource.loadStoredGate(environment: environment),
        )

        let audit: DecisionAudit
        do {
            audit = try DecisionAudit(path: auditPath, clock: clock)
        } catch {
            throw ExactMacRuntimeError.auditUnavailable(reason: String(describing: error))
        }
        let store: GrantStore
        do {
            store = try GrantStore.openStore(
                path: grantStorePath,
                clock: clock,
                maximumEnvelopeSeconds: config.maximumEnvelopeSeconds,
            )
        } catch {
            throw ExactMacRuntimeError.grantStoreUnavailable(reason: String(describing: error))
        }

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
            stateDirectory: ExactMacRuntimePaths.stateDirectory(environment: environment),
        )
        return ProductionAuthorizationRuntime(
            registry: registry,
            auditPath: auditPath,
            grantStorePath: grantStorePath,
            authorizationRuntime: runtime,
            consentTimeout: consentTimeout,
            postureSource: postureSource,
            biometricGate: biometricGateSource,
        )
    }
}
