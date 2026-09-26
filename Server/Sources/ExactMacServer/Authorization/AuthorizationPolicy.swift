import Foundation

/// The decision engine.
///
/// `evaluate` is a PURE function of its arguments. It reads no clock, touches no
/// filesystem, opens no socket, and holds no state between calls, which is what makes
/// the table-driven tests in `AuthorizationPolicyTests` exhaustive rather than
/// representative. Every input that could exist in a failing system — an unreachable
/// console, an unauthenticated peer, an unreadable store, an absent biometric, a TCP
/// listener, a locked-down posture — is a parameter with a value, and every one of them
/// has exactly one effect: deny.
///
/// It also never accepts a verdict. Capability and scope are derived from the request
/// bytes by the derivation layer and handed over as fact; nothing the console displays,
/// returns, or is asked to display is an input here, so there is nothing for a prompt and
/// the enforcement point to disagree about.
enum AuthorizationPolicy {
    /// The maximum span an envelope may be granted, and the ceiling the prompt states on
    /// its face. An agent may pre-authorize a long session; it may not pre-authorize
    /// forever.
    static let maximumEnvelopeSeconds = 8 * 60 * 60

    static func evaluate(
        request: AuthorizationRequest,
        identity: CallerIdentity,
        grants: [Grant],
        envelopes: [PreAuthorizationEnvelope],
        posture: Posture,
        context: AuthorizationContext,
        now: MonotonicInstant,
    ) -> AuthorizationDecision {
        let effective = request.capability.impliedCapabilities
        let consequence = context.highConsequenceTargets.contains {
            Self.isHighConsequence($0, for: request.scope)
        }
        let radius = Self.blastRadius(
            for: request,
            identity: identity,
            targetIsHighConsequence: consequence,
        )
        let risk = radius.riskClass
        let signature = identity.code.signature

        func deny(_ reason: DenialReason) -> AuthorizationDecision {
            AuthorizationDecision(
                outcome: .deny,
                basis: .denied(reason),
                effectiveCapabilities: effective,
                blastRadius: radius,
                riskClass: risk,
                biometric: .notRequired,
                offeredDecisions: [],
                expiresAt: nil,
            )
        }

        // Order matters and is not arbitrary. Each of these is a property of the SYSTEM,
        // not of the request, so a request that would otherwise be allowed is refused
        // before any of its own content is considered. That ordering is also what makes
        // the refusal un-leaky: a caller cannot distinguish "no grant matched" from "the
        // console is down" by timing the difference between two denials.

        // A TCP listener has no socket access to restrict and therefore no authenticating
        // principal, so it has no consent path and no process verification. Every
        // consent-requiring capability is denied, and this is a named state rather than
        // the emergent consequence of a missing dependency.
        if context.transport == .tcp, request.capability.requiresConsent {
            return deny(.reducedUnauthenticatedPosture)
        }
        guard context.peerAuthenticated else {
            return deny(.unauthenticatedPeer)
        }
        // A grant store that could not be read is not an empty one.
        if case .unreadable = context.store {
            return deny(.grantStoreUnreadable)
        }
        guard request.capability.requiresConsent else {
            return AuthorizationDecision(
                outcome: .allow,
                basis: .noConsentRequired,
                effectiveCapabilities: effective,
                blastRadius: radius,
                riskClass: risk,
                biometric: .notRequired,
                offeredDecisions: [],
                expiresAt: nil,
            )
        }
        // Locked down is the fail-closed direction: nothing can be granted, so nothing
        // can be replayed.
        guard posture != .lockedDown else {
            return deny(.postureLockedDown)
        }

        if posture.honoursStandingGrants {
            // A live grant, and then an envelope. Both bind to CODE IDENTITY, so a
            // different binary running as the same user does not inherit them, and
            // neither is ever matched on a pid.
            if let grant = grants.first(where: {
                $0.authorizes(request, identity: identity, now: now)
            }) {
                return AuthorizationDecision(
                    outcome: .allow,
                    basis: .grant(id: grant.id),
                    effectiveCapabilities: effective,
                    blastRadius: radius,
                    riskClass: risk,
                    biometric: .notRequired,
                    offeredDecisions: [],
                    expiresAt: grant.expiresAt,
                )
            }
            if let envelope = envelopes.first(where: {
                $0.authorizes(request, identity: identity, now: now)
            }) {
                return AuthorizationDecision(
                    outcome: .allow,
                    basis: .envelope(id: envelope.id),
                    effectiveCapabilities: effective,
                    blastRadius: radius,
                    riskClass: risk,
                    biometric: .notRequired,
                    offeredDecisions: [],
                    expiresAt: envelope.expiresAt,
                )
            }
        }

        // Nothing standing covers it, so consent is required — which means the console
        // has to be reachable. If it is not, the answer is deny, and it is deny rather
        // than a hang and rather than allow.
        guard context.isConsoleReachable else {
            return deny(.consoleUnreachable)
        }

        let offered = Self.offeredDecisions(
            for: request,
            posture: posture,
            riskClass: risk,
        )
        let requirement = Self.biometricRequirement(
            capability: request.capability,
            riskClass: risk,
            targetIsHighConsequence: consequence,
            signature: signature,
        )
        // A biometric that cannot be performed is a denial, never a downgrade to a
        // weaker check. Offered decisions that would need a ceremony the machine cannot
        // run are withdrawn rather than silently downgraded.
        if case .unavailable = context.biometric, case .required = requirement {
            return deny(.biometricUnavailable)
        }
        return AuthorizationDecision(
            outcome: .deny,
            basis: .promptRequired,
            effectiveCapabilities: effective,
            blastRadius: radius,
            riskClass: risk,
            biometric: requirement,
            offeredDecisions: requirement == .notRequired ? offered : offered,
            expiresAt: nil,
        )
    }

    // MARK: - The risk model

    /// Risk is the PRODUCT of what a grant would permit, not a property of a capability
    /// label. A clipboard read scoped to one application stays near free; the same
    /// capability across every application, continuously, for two hours, costs a
    /// biometric. Friction therefore scales with blast radius, and a uniform prompt is
    /// not a stricter policy — it is a failed control, because a prompt an operator sees
    /// for everything is a prompt they stop reading.
    static func blastRadius(
        for request: AuthorizationRequest,
        identity: CallerIdentity,
        targetIsHighConsequence: Bool,
    ) -> BlastRadius {
        BlastRadius(
            capability: capabilityFactor(request.capability),
            breadth: breadthFactor(request.scope),
            // A one-shot asks for nothing, so it contributes almost nothing.
            duration: 0.2,
            // An operation count is the ergonomic grain between once and forever: as the
            // remaining count falls the radius falls, which is what makes a loop
            // converge to a fresh decision instead of running to the end of the grant.
            remainingCount: remainingCountFactor(request.scope.operationLimit),
            targetConsequence: targetIsHighConsequence ? 1.0 : 0.45,
            signatureQuality: identity.code.signature.quality,
        )
    }

    static func capabilityFactor(_ capability: Capability) -> Double {
        switch capability {
        case .scriptExecute: 1.0
        case .macroExecute: 0.85
        case .accessibilityTraverse: 0.8
        case .screenObserve: 0.8
        case .inputSynthesize: 0.75
        case .clipboardWrite: 0.7
        case .clipboardRead: 0.65
        case .observationStream: 0.6
        case .fileDialogAutomate: 0.6
        case .windowManage: 0.55
        case .applicationControl: 0.5
        case .windowObserve: 0.45
        case .transactionManage: 0.4
        case .sessionManage: 0.3
        case .displayRead: 0.3
        case .localEcho: 0.1
        }
    }

    static func breadthFactor(_ scope: AuthorizationScope) -> Double {
        var factor = scope.application.isGlobal ? 1.0 : 0.45
        if case .processIdentifier = scope.application { factor = 0.25 }
        if scope.window != .any { factor *= 0.8 }
        return factor
    }

    static func remainingCountFactor(_ limit: Int?) -> Double {
        guard let limit else { return 1.0 }
        // `return switch`, because a switch after a `guard` is a statement in a
        // multi-statement body and every one of its case values was being discarded.
        return switch limit {
        case ..<1: 0.2
        case 1: 0.3
        case 2...5: 0.5
        case 6...20: 0.7
        default: 0.85
        }
    }

    // MARK: - Biometric policy

    /// Whether a decision needs a ceremony, as a pure function of what is being
    /// authorised. Exhaustive tests live in `BiometricPolicyTests`; this is the whole
    /// policy, with no authenticator anywhere in sight, because the requirement must be
    /// answerable whether or not the machine can perform one.
    static func biometricRequirement(
        capability: Capability,
        riskClass: RiskClass,
        targetIsHighConsequence: Bool,
        signature: SignatureState,
        isRevokeAll: Bool = false,
        decisionKind: OfferedDecision.Kind = .allowOnce,
    ) -> BiometricRequirement {
        // THE ORDER IS THE POLICY, and it is the order the table test found. The
        // allow-once exemption used to sit second, which meant it overrode two rules
        // that must never be overridable: an UNSIGNED caller asking for one narrow thing
        // got no ceremony — the case where the operator has least reason to be wary and
        // most to be given — and a SCRIPT asked for once got no ceremony either, even
        // though a shell can read the screen, the clipboard and the interface and is the
        // single most dangerous capability in the product.
        if isRevokeAll {
            return .required(reason: "revoking every grant at once")
        }
        // Verification is graded evidence, and the cheapest honest escalation of a weak
        // signature is a ceremony rather than a denial.
        if signature == .unsigned || signature == .invalid || signature == .unresolved {
            return .required(reason: "the caller's signature is \(signature.rawValue)")
        }
        if capability == .scriptExecute {
            return .required(reason: "running a shell reaches everything this Mac can do")
        }
        if decisionKind == .allowGlobalPersistent {
            return .required(reason: "a grant that outlives this request and covers every app")
        }
        if decisionKind == .preAuthorizeEnvelope {
            return .required(reason: "a pre-authorized batch runs unattended")
        }
        if targetIsHighConsequence {
            return .required(reason: "this application is on your high-consequence list")
        }
        if riskClass == .high {
            return .required(reason: "this grant would permit a lot")
        }
        // A narrow allow-once is where friction is deliberately NOT spent, and it is
        // last because it is the only exemption on this list.
        if decisionKind == .allowOnce, riskClass == .routine, !targetIsHighConsequence {
            return .notRequired
        }
        return .notRequired
    }

    // MARK: - Offered decisions

    /// The options the operator is given, each carrying its own breadth and duration.
    /// The order IS a security property, because the default focus determines what a
    /// hurried operator approves: the default leads, the extremes bracket the list, and
    /// Deny is never adjacent to the option that holds focus.
    static func offeredDecisions(
        for request: AuthorizationRequest,
        posture: Posture,
        riskClass: RiskClass,
    ) -> [OfferedDecision] {
        let target = request.scope.application
        var decisions: [OfferedDecision] = [
            OfferedDecision(
                kind: .allowOnce,
                scope: request.scope,
                duration: .once,
                isDestructive: false,
                isDefault: true,
                isPrimary: true,
            ),
        ]
        if case .any = target {
            // "Allow for this application" is meaningless when the request named none,
            // and offering it anyway is how a UI starts lying about its own scope.
        } else {
            decisions.append(
                OfferedDecision(
                    kind: .allowTargetApplication,
                    scope: AuthorizationScope(application: target, window: .any),
                    duration: .monotonicSeconds(15 * 60),
                    isDestructive: false,
                    isDefault: false,
                    isPrimary: false,
                ),
            )
        }
        decisions.append(
            OfferedDecision(
                kind: .allowSession,
                scope: AuthorizationScope(application: target),
                duration: .monotonicSeconds(maximumEnvelopeSeconds),
                isDestructive: false,
                isDefault: false,
                isPrimary: false,
            ),
        )
        decisions.append(
            OfferedDecision(
                kind: .preAuthorizeEnvelope,
                scope: AuthorizationScope(application: target),
                duration: .monotonicSeconds(maximumEnvelopeSeconds),
                isDestructive: false,
                isDefault: false,
                isPrimary: false,
            ),
        )
        decisions.append(
            OfferedDecision(
                kind: .deny,
                scope: AuthorizationScope(),
                duration: .once,
                isDestructive: true,
                isDefault: false,
                isPrimary: false,
            ),
        )
        // "Always allow" is offered only when the request named no single target. A
        // global grant for a request that was about one application is a decision the
        // operator did not think they were making.
        if case .any = target {
            decisions.append(
                OfferedDecision(
                    kind: .allowGlobalPersistent,
                    scope: AuthorizationScope(),
                    duration: .monotonicSeconds(maximumEnvelopeSeconds),
                    isDestructive: true,
                    isDefault: false,
                    isPrimary: false,
                ),
            )
        }
        if posture == .strict {
            // Under the strict posture nothing persists, so the durable options are
            // withdrawn rather than shown and then ignored.
            decisions.removeAll {
                $0.kind == .allowSession || $0.kind == .preAuthorizeEnvelope
                    || $0.kind == .allowGlobalPersistent || $0.kind == .allowTargetApplication
            }
        }
        if riskClass == .high, let targetIndex = decisions.firstIndex(where: {
            $0.kind == .allowTargetApplication
        }) {
            // A NARROWER default, never a safer-looking one. This used to make Deny the
            // default and strip its destructive marking, which is the one thing the
            // design forbids: Deny is never focused by default, and it is rendered on its
            // own row below a hairline precisely so muscle memory cannot reach it.
            // Where there is no target to scope to, the one-shot keeps focus and the
            // ceremony — which the biometric policy requires for a high radius — is the
            // friction.
            decisions[targetIndex].isDefault = true
            decisions[targetIndex].isPrimary = true
            if let onceIndex = decisions.firstIndex(where: { $0.kind == .allowOnce }) {
                decisions[onceIndex].isDefault = false
                decisions[onceIndex].isPrimary = false
            }
        }
        return decisions
    }

    // MARK: - Helpers

    static func isHighConsequence(_ bundleIdentifier: String, for scope: AuthorizationScope) -> Bool {
        switch scope.application {
        case .bundleIdentifier(let requested): requested == bundleIdentifier
        case .any: false
        case .processIdentifier: false
        }
    }

    /// Whether an envelope is admissible at all. Called at issuance AND re-checked at
    /// evaluation, because a stored object that has become invalid — hand-edited, or
    /// written by an older version with different rules — must not be honoured on the
    /// strength of having once been valid.
    static func envelopeIsAdmissible(_ envelope: PreAuthorizationEnvelope) -> Bool {
        guard let seconds = envelope.declaredDuration.seconds else { return false }
        guard seconds > 0, seconds <= maximumEnvelopeSeconds else { return false }
        guard !envelope.isGlobalPersistent else { return false }
        return !envelope.grants.isEmpty
    }
}
