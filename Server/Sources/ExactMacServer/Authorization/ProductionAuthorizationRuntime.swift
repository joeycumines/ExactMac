import Darwin
import Foundation
import GRPCCore
import GRPCHealthService
import os

// MARK: - Where the server's own state lives

/// The one place the server, the console and the deployment documentation agree on where
/// state is kept.
///
/// THE PATHS ARE HERE RATHER THAN IN THE CALLERS because they have to agree: a grant store the
/// console cannot find, or a console socket the server and the console spell differently, is a
/// service that denies everything and says nothing useful. `~/.exactmac` is one short
/// directory, which is not tidiness — `sun_path` is 104 bytes on Darwin and the console socket
/// has to fit inside it.
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

    static func consoleSocketPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        stateDirectory(environment: environment) + "/console.sock"
    }

    static func consoleTokenPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        stateDirectory(environment: environment) + "/console.token"
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
    case consoleChannelUnavailable(reason: String)

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
        case let .consoleChannelUnavailable(reason):
            "the console channel is unavailable: \(reason)"
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
    ) -> Bool {
        audit.record(
            request: request,
            identity: identity,
            decision: decision,
            operatorNote: operatorNote,
            biometricObtained: biometricObtained,
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

// MARK: - The console

/// The console endpoint as the interceptor's consent broker.
///
/// A THIN ADAPTER, because `ConsoleServerEndpoint.obtainConsent` is already the real broker:
/// it mints the nonce, computes the digest, keeps the request so a console that authenticates
/// late is caught up, validates the answer against both, and denies on the bound. All this
/// adds is the timeout, which the interceptor holds rather than the endpoint.
struct ConsoleEndpointConsentBroker: ConsentBroker {
    private let endpoint: ConsoleServerEndpoint?
    private let timeout: @Sendable () -> Duration

    init(endpoint: ConsoleServerEndpoint?, timeout: @escaping @Sendable () -> Duration) {
        self.endpoint = endpoint
        self.timeout = timeout
    }

    func obtainConsent(
        for request: AuthorizationRequest,
        identity: CallerIdentity,
        decision: AuthorizationDecision,
    ) async -> ConsentAnswer? {
        // No endpoint is nil, which the interceptor reads as an unreachable console and
        // denies on. It is the same answer as a console that is not running, which is right:
        // from the caller's side the two are not distinguishable and must not be.
        guard let endpoint else { return nil }
        return await endpoint.obtainConsent(
            for: request,
            identity: identity,
            decision: decision,
            timeout: timeout(),
        )
    }
}

/// The real authorization runtime, and the one place the server's own state is created.
///
/// IT EXISTS AS A SINGLE VALUE rather than as arguments threaded through `main`, because the
/// failure this project keeps meeting is a runtime assembled from defaults: `NoStandingGrants`,
/// `UnavailableConsentBroker`, `isConsoleReachable = false`, a nil recorder. Each of those
/// denies, so each is safe, and together they are a system that cannot do anything while
/// looking as though it is running. Assembling them here makes the set of things the server
/// is actually using one readable list, and adding a dependency is a visible edit.
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
    let consoleSocketPath: String?
    let consoleEndpoint: ConsoleServerEndpoint?
    /// The endpoint's accept loop, held so shutdown can stop it. It is a SEPARATE TASK and
    /// not a call, because `ConsoleServerEndpoint.serve()` runs until `stop()` and calling
    /// it inline would block startup forever.
    let consoleEndpointTask: Task<Void, Never>?
    let authorizationRuntime: AuthorizationRuntime
    let consentTimeout: Duration

    /// - Throws: when the state directory, the audit log, the grant store or a configured
    ///   console channel cannot be established. Startup fails rather than continuing with a
    ///   component missing, because a server that cannot record a decision has no reason to be
    ///   listening, and a grant store that cannot be read is the state in which the system
    ///   must not be granting things.
    static func make(
        config: ServerConfig,
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) throws -> ProductionAuthorizationRuntime {
        try ExactMacRuntimePaths.prepareStateDirectory(environment: environment)

        let clock = SystemMonotonicClock()
        let auditPath = ExactMacRuntimePaths.auditLogPath(environment: environment)
        let grantStorePath = ExactMacRuntimePaths.grantStorePath(environment: environment)
        let registry = ConnectionPeerRegistry()

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

        // THE CONSOLE CHANNEL IS OPTIONAL, and its absence is not an error. The server has to
        // be able to start and refuse everything rather than not start at all: a service that
        // is down is harder to diagnose than one that is up and denying. Reachability is still
        // answered live, so a configured channel with no console attached reports unreachable
        // rather than pretending a consent path exists.
        let consoleSocketPath = config.consoleSocketPath
        var consoleEndpoint: ConsoleServerEndpoint?
        var consoleEndpointTask: Task<Void, Never>?
        if let consoleSocketPath {
            let token: ConsoleChannelToken
            do {
                token = try ConsoleChannelToken.loadOrCreate(
                    at: ExactMacRuntimePaths.consoleTokenPath(environment: environment),
                )
            } catch {
                throw ExactMacRuntimeError.consoleChannelUnavailable(
                    reason: String(describing: error),
                )
            }
            let endpoint = ConsoleServerEndpoint(
                socketPath: consoleSocketPath,
                token: token,
                responder: ConsoleReplyFactory(
                    store: store,
                    audit: audit,
                    posture: config.defaultPosture,
                    stateDirectory: ExactMacRuntimePaths.stateDirectory(environment: environment),
                ).answer,
            )
            do {
                try endpoint.listen()
            } catch {
                throw ExactMacRuntimeError.consoleChannelUnavailable(
                    reason: String(describing: error),
                )
            }
            // THE ACCEPT LOOP IS STARTED HERE, and its absence was the whole reason the
            // console could never be seen. `listen()` binds and listens; `serve()` is what
            // accepts, and a server that only ever listened had a console socket that
            // answered `connect` and then nothing — so `hasAuthenticatedConsole` stayed
            // false forever and every consent request denied with `consoleUnreachable`.
            consoleEndpointTask = Task { [endpoint] in
                await endpoint.serve()
            }
            consoleEndpoint = endpoint
        }

        let consentTimeout = Duration.seconds(config.consentTimeoutSeconds)
        let descriptorPolicy = try PublicRequestDescriptorPolicy.load()
        var runtime = AuthorizationRuntime.unixSocket(
            descriptorPolicy: descriptorPolicy,
            grants: GrantStoreSupply(store: store),
            consent: ConsoleEndpointConsentBroker(
                endpoint: consoleEndpoint,
                timeout: { consentTimeout },
            ),
            issuance: GrantStoreIssuance(store: store),
            clock: clock,
            posture: config.defaultPosture,
            consentTimeout: consentTimeout,
            // Replaced immediately below with a live answer; the literal here exists only so
            // the initializer has one.
            isConsoleReachable: consoleEndpoint != nil,
            peerEvidence: .registry(registry),
            audit: AuditDecisionRecorder(audit: audit),
            auditRequired: true,
        )
        if let consoleEndpoint {
            runtime.isConsoleReachable = { consoleEndpoint.hasAuthenticatedConsole }
        }
        return ProductionAuthorizationRuntime(
            registry: registry,
            auditPath: auditPath,
            grantStorePath: grantStorePath,
            consoleSocketPath: consoleSocketPath,
            consoleEndpoint: consoleEndpoint,
            consoleEndpointTask: consoleEndpointTask,
            authorizationRuntime: runtime,
            consentTimeout: consentTimeout,
        )
    }
}

/// A console channel with no endpoint behind it, which is what "no console socket is
/// configured" means: the broker is asked, and the answer is that there is nothing to ask.
struct UnreachableConsoleEndpoint: ConsentBroker {
    func obtainConsent(
        for _: AuthorizationRequest,
        identity _: CallerIdentity,
        decision _: AuthorizationDecision,
    ) async -> ConsentAnswer? {
        nil
    }
}

/// The console's three queries, answered from the state the server already owns.
///
/// THE CHANNEL CARRIES THE FRAME AND NOT THE DATA, so the payload is JSON encoded here and
/// decoded by the console against its own copy of the shapes. That duplication is a real
/// coupling and it is stated rather than hidden: a disagreement is a decode failure on a
/// refused frame, not a silently misread field.
struct ConsoleReplyFactory {
    private let store: GrantStore
    private let audit: DecisionAudit
    private let posture: Posture
    private let stateDirectory: String

    init(store: GrantStore, audit: DecisionAudit, posture: Posture, stateDirectory: String) {
        self.store = store
        self.audit = audit
        self.posture = posture
        self.stateDirectory = stateDirectory
    }

    func answer(_ kind: QueryKind) async -> ConsoleReply {
        let payload: String?
        switch kind {
        case .grants:
            payload = encode(store.grantsForDisplay())
        case .activity:
            // THE VERIFICATION TRAVELS WITH THE ENTRIES rather than beside them, because a
            // list of decisions the console renders as authoritative is exactly what a
            // tampered log looks like. A consumer that sees the defect can say which sequence
            // is wrong instead of displaying a broken chain as history.
            let verification = audit.verify()
            payload = encode(ActivitySummary(
                entryCount: verification.entryCount,
                isIntact: verification.isIntact,
                firstBrokenSequence: verification.firstBrokenSequence,
                defect: verification.defect.map { String(describing: $0) },
            ))
        case .settings:
            payload = encode(SettingsSummary(
                posture: String(describing: posture),
                stateDirectory: stateDirectory,
                auditLog: audit.path,
                grantStore: store.path,
            ))
        }
        return ConsoleReply(kind: kind.rawValue, payload: payload)
    }

    /// What the activity query reports: the chain's own verdict, not a list of decisions the
    /// console would present as authoritative.
    struct ActivitySummary: Encodable {
        var entryCount: Int
        var isIntact: Bool
        var firstBrokenSequence: UInt64?
        var defect: String?
    }

    /// What the settings query reports: where the operator's state is, so "which installation
    /// am I looking at" is answerable without guessing.
    struct SettingsSummary: Encodable {
        var posture: String
        var stateDirectory: String
        var auditLog: String
        var grantStore: String
    }

    /// A payload that fails to encode is nil rather than a placeholder: the console shows an
    /// unreadable query as an error, and a placeholder would be a plausible-looking value it
    /// then displayed.
    private func encode(_ value: some Encodable) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return text
    }
}
