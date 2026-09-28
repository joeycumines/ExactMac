import Foundation
import OSLog

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
        // An identity that could not be fully resolved is treated as UNRESOLVED for
        // friction purposes whatever its binary claims, because "the signature on the
        // file says signed" and "we know which process is holding that file" are two
        // different claims and only the second one failed.
        let effectiveSignature: SignatureState = identity.isFullyResolved
            ? identity.code.signature
            : .unresolved
        let consequence = context.highConsequenceTargets.contains {
            isHighConsequence($0, for: request.scope, anyTargetsListed: true)
        } || isUnmatchableButFlaggedTarget(request.scope, context: context)
        // The radius of what was ASKED FOR, which is the prompt's risk chip: a one-shot
        // ask has no duration beyond the request itself, so it is the floor of the
        // product. Each offered decision carries its own radius, because what the
        // operator is really being asked to weigh is the option in front of them.
        let askedRadius = blastRadius(
            capability: request.capability,
            scope: request.scope,
            duration: .once,
            remainingCount: request.scope.operationLimit,
            targetIsHighConsequence: consequence,
            signatureQuality: effectiveSignature.quality,
        )
        let askedRisk = askedRadius.riskClass

        // A hard denial reports a radius that does NOT vary with the operator's private
        // high-consequence list. It used to, because the radius folded that list in, so
        // two byte-identical requests against an unreachable console returned the same
        // denial reason and different radii depending on a list the caller cannot read —
        // which is a side channel, and the comment above this function claimed the
        // opposite. The system failure is answered before the target is consulted.
        let neutralRadius = blastRadius(
            capability: request.capability,
            scope: request.scope,
            duration: .once,
            remainingCount: request.scope.operationLimit,
            targetIsHighConsequence: false,
            signatureQuality: effectiveSignature.quality,
        )

        func deny(_ reason: DenialReason, _ requirement: BiometricRequirement = .notRequired)
            -> AuthorizationDecision
        {
            AuthorizationDecision(
                outcome: .deny,
                basis: .denied(reason),
                effectiveCapabilities: effective,
                blastRadius: neutralRadius,
                riskClass: neutralRadius.riskClass,
                biometric: requirement,
                offeredDecisions: [],
                expiresAt: nil,
            )
        }

        // Order matters and is not arbitrary. Each of these is a property of the SYSTEM,
        // not of the request, so a request that would otherwise be allowed is refused
        // before any of its own content is considered. The property this buys is not
        // secrecy of the reason — a caller is told which system failure it hit — it is
        // that a system failure cannot be used to probe whether a TARGET exists, because
        // the target is never examined on this path.

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
                blastRadius: askedRadius,
                riskClass: askedRisk,
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
            // neither is ever matched on a pid. An envelope is additionally re-checked
            // for admissibility here rather than trusted on the strength of having once
            // been issued: a stored object that has become invalid must not be honoured.
            if let grant = grants.first(where: {
                $0.authorizes(request, identity: identity, now: now)
            }) {
                return AuthorizationDecision(
                    outcome: .allow,
                    basis: .grant(id: grant.id),
                    effectiveCapabilities: effective,
                    blastRadius: askedRadius,
                    riskClass: askedRisk,
                    biometric: .notRequired,
                    offeredDecisions: [],
                    expiresAt: grant.expiresAt,
                )
            }
            if let envelope = envelopes.first(where: {
                envelopeIsAdmissible($0, now: now)
                    && $0.authorizes(request, identity: identity, now: now)
            }) {
                return AuthorizationDecision(
                    outcome: .allow,
                    basis: .envelope(id: envelope.id),
                    effectiveCapabilities: effective,
                    blastRadius: askedRadius,
                    riskClass: askedRisk,
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

        let offered = offeredDecisions(
            for: request,
            posture: posture,
            riskClass: askedRisk,
            targetIsHighConsequence: consequence,
            signature: effectiveSignature,
            agentGaveReason: hasReason(request.agentReason),
            originIsKnown: request.origin != .unknown,
        )
        // The decision's own requirement is the requirement of the option that holds
        // focus, because that is the one a hurried operator is about to accept.
        let focused = offered.first(where: \.isDefault) ?? offered[0]
        // A biometric that cannot be performed is a denial, never a downgrade to a
        // weaker check. Options that would need a ceremony the machine cannot run are
        // withdrawn rather than silently downgraded.
        if case .unavailable = context.biometric, case .required = focused.biometric {
            return deny(.biometricUnavailable, focused.biometric)
        }
        return AuthorizationDecision(
            outcome: .deny,
            basis: .promptRequired,
            effectiveCapabilities: effective,
            blastRadius: askedRadius,
            riskClass: askedRisk,
            biometric: focused.biometric,
            offeredDecisions: offered,
            // MINTED WHEN **ANY** OFFERED OPTION NEEDS A CEREMONY, and not when the FOCUSED
            // one does -- the first version of this line read `focused.biometric.reason`, and
            // the prompt's default is the NARROWEST option, which is exactly the one that does
            // not need one. So the nonce was nil on every prompt whose broad option required a
            // fingerprint, and a test asserting the precondition caught it: a decision that
            // offered a ceremony had no nonce for it, which would have made every later proof
            // check vacuous rather than merely wrong.
            //
            // It is minted HERE rather than at the moment of asking so the value that the
            // HERE rather than at the moment of asking so the value that the operator's
            // interface performs against is the same one the server later checks. It is a
            // CSPRNG value: a predictable nonce is not a nonce, because a caller who can
            // guess the next one can present a proof for a decision nobody asked about. There
            // is no case in this file that needs the identifier of the process to be random
            // for that reason, which is a different property and a comment on its own.
            ceremonyNonce: offered.contains { $0.biometric.reason != nil } ? Self.ceremonyNonce() : nil,
            expiresAt: nil,
        )
    }

    /// A fresh ceremony nonce, from the system CSPRNG.
    ///
    /// `SecRandomCopyBytes` rather than `UUID().uuidString`, because a UUID is 122 bits drawn
    /// from a hash with a fixed structure and this value's whole job is to be unguessable to
    /// whatever is trying to present a proof for somebody else's decision.
    private static let logger = Logger(
        subsystem: "io.github.joeycumines.exactmac",
        category: "authorization.policy",
    )

    private static func ceremonyNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess
        else {
            // A FAILURE HERE IS NOT A FALLBACK TO SOMETHING WEAKER. Without a nonce the proof
            // cannot be bound to this decision, so a decision that needs a ceremony must be
            // refused rather than authorised with an unbindable one.
            Self.logger.error(
                "The system random source failed; a ceremony cannot be bound to this decision.",
            )
            return ""
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - The risk model

    /// Risk is the PRODUCT of what a grant would permit, not a property of a capability
    /// label. A clipboard read scoped to one application stays near free; the same
    /// capability across every application, continuously, for two hours, costs a
    /// biometric. Friction therefore scales with blast radius, and a uniform prompt is
    /// not a stricter policy — it is a failed control, because a prompt an operator sees
    /// for everything is a prompt they stop reading.
    ///
    /// EVERY FACTOR IS NOW A REAL INPUT. Duration used to be the constant 0.2, which put
    /// the theoretical maximum radius at 0.09 and made `.elevated` and `.high`
    /// unreachable: a review enumerated 1,344 decisions and found 0 of each. A global
    /// unbounded clipboard read and a single-application read were getting identical
    /// friction at 2.2x the radius apart. Duration and the remaining count are now
    /// arguments, because a risk model that cannot express the difference between "once"
    /// and "for eight hours" is not a risk model.
    static func blastRadius(
        capability: Capability,
        scope: AuthorizationScope,
        duration: GrantDuration,
        remainingCount: Int?,
        targetIsHighConsequence: Bool,
        signatureQuality: Double,
    ) -> BlastRadius {
        BlastRadius(
            capability: capabilityFactor(capability),
            breadth: breadthFactor(scope),
            duration: durationFactor(duration),
            remainingCount: remainingCountFactor(remainingCount),
            targetConsequence: targetIsHighConsequence ? 1.0 : 0.45,
            signatureQuality: signatureQuality,
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
        // Reading what is permitted discloses the operator's whole posture, so it costs
        // more than a metadata read and far less than touching the desktop.
        case .authorizationManage: 0.2
        case .localEcho: 0.1
        }
    }

    static func breadthFactor(_ scope: AuthorizationScope) -> Double {
        var factor = scope.application.isGlobal ? 1.0 : 0.45
        if case .processIdentifier = scope.application {
            factor = 0.25
        }
        // One process instance is narrower still, and the digest is what makes it so.
        if scope.application.isProcessInstance {
            factor = 0.2
        }
        if scope.window != .any {
            factor *= 0.8
        }
        return factor
    }

    /// A one-shot is a floor, not a zero: it still asks the operator once, and a risk
    /// model that scored it at zero would make "allow once" and "do nothing" identical.
    /// Eight hours is the ceiling of the scale, which is the same eight hours an
    /// envelope may be granted for, so the number the operator reads on the option is the
    /// number the model uses.
    static func durationFactor(_ duration: GrantDuration) -> Double {
        guard let seconds = duration.seconds else { return 0.08 }
        guard seconds > 0 else { return 1.0 }
        return min(1.0, Double(seconds) / Double(maximumEnvelopeSeconds))
    }

    /// An operation count is the ergonomic grain between once and forever: as the
    /// remaining count falls the radius falls, which is what makes a loop converge to a
    /// fresh decision instead of running to the end of the grant. A count below one is
    /// MALFORMED, and a malformed limit is scored at the maximum rather than the minimum:
    /// it used to score 0.2, which made "do this zero times" look five times safer than
    /// an unbounded request.
    static func remainingCountFactor(_ limit: Int?) -> Double {
        guard let limit else { return 1.0 }
        return switch limit {
        case ..<1: 1.0
        case 1: 0.3
        case 2 ... 5: 0.5
        case 6 ... 20: 0.7
        default: 0.85
        }
    }

    // MARK: - Biometric policy

    /// Whether a decision needs a ceremony, as a pure function of WHAT WOULD BE
    /// AUTHORISED: the capability, the scope, the duration, the target, and the caller's
    /// signature.
    ///
    /// IT IS KEYED ON THE SCOPE, NOT THE OPTION'S NAME. It used to take
    /// `decisionKind: OfferedDecision.Kind` and require a ceremony for
    /// `.allowGlobalPersistent`, which meant `.allowSession` handed out an identical
    /// grant — same global scope, same eight hours — with no ceremony at all. Two labels
    /// for one scope is a policy that can be defeated by choosing the other label.
    static func biometricRequirement(
        capability: Capability,
        scope: AuthorizationScope = AuthorizationScope(),
        duration: GrantDuration = .once,
        riskClass: RiskClass = .routine,
        targetIsHighConsequence: Bool = false,
        signature: SignatureState = .signedAndValid,
        isRevokeAll: Bool = false,
    ) -> BiometricRequirement {
        if isRevokeAll {
            return .required(reason: "revoking every grant at once")
        }
        // Signature escalation comes before every exemption, and that order is the whole
        // point. The narrow-allow-once exemption used to sit second and overrode two rules
        // that must never be overridable: an UNSIGNED caller asking for one narrow thing
        // got no ceremony — the case where the operator has least reason to be wary and
        // most to be given — and a SCRIPT asked for once got none either.
        if signature == .unsigned || signature == .invalid || signature == .unresolved {
            // NOT `\(signature.rawValue)`. The operator reads this sentence on the prompt
            // while Touch ID is waiting, and a raw enum there reads "unsigned" or
            // "unresolved" as though those were the finding. They are the finding, but they
            // are a classification and the operator cannot act on it. What they need is
            // what the classification MEANS for this caller, which is that the binary
            // cannot be tied to a signer — so the sentence says that.
            return .required(
                reason: "this caller is not signed by a developer you can identify",
            )
        }
        if capability == .scriptExecute {
            // "everything this Mac can do" was here and it is FALSE: a shell is bounded by
            // the sandbox, by TCC and by SIP, and a claim the operator can disprove is a
            // claim they will stop believing. What is true is the part that matters for
            // this decision — it can read what you can read.
            return .required(
                reason: "a shell can read your screen, your clipboard and your keystrokes",
            )
        }
        // BREADTH x PERSISTENCE, which is the rule the design's own worked example
        // states: a clipboard read scoped to one application stays near free, and the
        // same capability across EVERY application, CONTINUOUSLY, costs a biometric.
        // Neither half does it — a global one-shot and a single-app eight-hour grant are
        // both ordinary — and the product of the two is a standing permission.
        // Keyed on the APPLICATION axis, not on `isGlobalPersistent`. That is a
        // three-way conjunction, so adding a window or an operation count switched the
        // whole rule off while the grant still covered every application — the design's
        // rule is about breadth and persistence, and breadth here is the application axis.
        if scope.application.isGlobal, duration.isPersistent {
            return .required(
                reason: "a standing permission over every application until you revoke it",
            )
        }
        if targetIsHighConsequence {
            return .required(reason: "this application is on your high-consequence list")
        }
        if riskClass == .high {
            // "this grant would permit a lot" was here. It is an English OPINION where the
            // operator is being asked to authorise something, and it is the one sentence in
            // this function that says nothing checkable — no capability, no scope, no
            // duration. The risk class was computed from all three, so the sentence states
            // them.
            return .required(
                reason: "\(capability.consequence.lowercased()) across "
                    + "\(scope.application.isGlobal ? "every application" : "the applications in scope")",
            )
        }
        return .notRequired
    }

    // MARK: - Offered decisions

    /// The options the operator is given, each carrying its own breadth, duration, radius
    /// and ceremony requirement. The order IS a security property, because the default
    /// focus determines what a hurried operator approves: the default leads, the extremes
    /// bracket the list, and Deny is never adjacent to the option that holds focus.
    static func offeredDecisions(
        for request: AuthorizationRequest,
        posture: Posture,
        riskClass: RiskClass,
        targetIsHighConsequence: Bool = false,
        signature: SignatureState = .signedAndValid,
        agentGaveReason: Bool = true,
        originIsKnown: Bool = true,
    ) -> [OfferedDecision] {
        let target = request.scope.application
        let signatureQuality = signature.quality

        func decision(
            _ kind: OfferedDecision.Kind,
            _ scope: AuthorizationScope,
            _ duration: GrantDuration,
            isDestructive: Bool = false,
            isDefault: Bool = false,
            isPrimary: Bool = false,
        ) -> OfferedDecision {
            let radius = blastRadius(
                capability: request.capability,
                scope: scope,
                duration: duration,
                remainingCount: scope.operationLimit,
                targetIsHighConsequence: targetIsHighConsequence,
                signatureQuality: signatureQuality,
            )
            return OfferedDecision(
                kind: kind,
                scope: scope,
                duration: duration,
                blastRadius: radius,
                biometric: biometricRequirement(
                    capability: request.capability,
                    scope: scope,
                    duration: duration,
                    // A missing reason is a different prompt, not a shorter one, and an
                    // unexplained request is one the operator should decline — so it
                    // escalates rather than being quietly treated as routine. The same
                    // goes for an origin the server could not attribute.
                    riskClass: (agentGaveReason && originIsKnown) ? radius.riskClass : .high,
                    targetIsHighConsequence: targetIsHighConsequence,
                    signature: signature,
                ),
                isDestructive: isDestructive,
                isDefault: isDefault,
                isPrimary: isPrimary,
            )
        }

        var decisions: [OfferedDecision] = [
            decision(
                .allowOnce,
                request.scope,
                .once,
                isDefault: true,
                isPrimary: true,
            ),
        ]
        if case .any = target {
            // "Allow for this application" is meaningless when the request named none,
            // and offering it anyway is how a UI starts lying about its own scope.
        } else {
            decisions.append(
                decision(
                    .allowTargetApplication,
                    AuthorizationScope(application: target, window: .any),
                    .monotonicSeconds(15 * 60),
                ),
            )
        }
        decisions.append(
            decision(
                .allowSession,
                AuthorizationScope(application: target),
                .monotonicSeconds(maximumEnvelopeSeconds),
            ),
        )
        // A pre-authorized batch is offered only when there is an application to scope it
        // to. For a request that named no target, the envelope's own grants would be
        // global, and `envelopeIsAdmissible` rejects exactly that — so offering it would
        // be offering something the system would refuse at issuance.
        if !target.isGlobal {
            decisions.append(
                decision(
                    .preAuthorizeEnvelope,
                    AuthorizationScope(application: target),
                    .monotonicSeconds(maximumEnvelopeSeconds),
                    // It authorises unattended future capability, so it is marked
                    // destructive: it can never be the focused option by accident.
                    isDestructive: true,
                ),
            )
        }
        decisions.append(
            decision(
                .deny,
                AuthorizationScope(),
                .once,
                isDestructive: true,
            ),
        )
        // "Always allow" is offered only when the request named no single target. A
        // global grant for a request that was about one application is a decision the
        // operator did not think they were making.
        if target.isGlobal {
            decisions.append(
                decision(
                    .allowGlobalPersistent,
                    AuthorizationScope(),
                    .monotonicSeconds(maximumEnvelopeSeconds),
                    isDestructive: true,
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

    /// Whether the request's target is one the operator flagged.
    ///
    /// A pid-scoped request CANNOT be matched against a list of bundle identifiers, and
    /// the code used to answer `false` — a silent negative from a switch, which is exactly
    /// the pattern the TargetApplication.covers comment says this function exists to
    /// prevent. It answers honestly instead: "not one of the listed applications, OR not
    /// something I can check." When the operator has listed anything and the scope names a
    /// process rather than an application, the request escalates, because the alternative
    /// is to let an unmatchable target skip an escalation on the strength of being
    /// unmatchable.
    static func isHighConsequence(
        _ bundleIdentifier: String,
        for scope: AuthorizationScope,
        anyTargetsListed: Bool,
    ) -> Bool {
        switch scope.application {
        case let .bundleIdentifier(requested): requested == bundleIdentifier
        case let .opaqueApplication(_, resolved): resolved == bundleIdentifier
        case .any: false
        case .processIdentifier: anyTargetsListed
        }
    }

    private static func isUnmatchableButFlaggedTarget(
        _ scope: AuthorizationScope,
        context: AuthorizationContext,
    ) -> Bool {
        guard case .processIdentifier = scope.application else { return false }
        return !context.highConsequenceTargets.isEmpty
    }

    private static func hasReason(_ reason: String?) -> Bool {
        guard let reason else { return false }
        return !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether an envelope is admissible at all. Called at issuance AND re-checked at
    /// evaluation, because a stored object that has become invalid — hand-edited, or
    /// written by an older version with different rules — must not be honoured on the
    /// strength of having once been valid.
    /// `now` is required because the eight-hour ceiling is enforced against the envelope's
    /// REMAINING LIFETIME, not against its declared duration. It used to be checked
    /// against `declaredDuration` while `authorizes` enforced `expiresAt`, so an envelope
    /// declaring one second and expiring in eight hours passed — and once this function
    /// became the only evaluation-time gate, the ceiling was being enforced against a
    /// field that does not control the outcome. The declaration is still checked, because
    /// a lie in the declaration is itself a reason to refuse.
    static func envelopeIsAdmissible(
        _ envelope: PreAuthorizationEnvelope,
        now: MonotonicInstant,
    ) -> Bool {
        guard let seconds = envelope.declaredDuration.seconds else { return false }
        guard seconds > 0, seconds <= maximumEnvelopeSeconds else { return false }
        // The envelope may not outlive what it PROMISED, not merely the ceiling. The
        // prompt states the declared duration to the operator, so an envelope that
        // declares one second and lives for eight hours shows a number that is not true
        // and grants for two thousand times longer than the one the operator agreed to.
        guard let remaining = now.remaining(until: envelope.expiresAt) else { return false }
        let remainingSeconds = remaining.components.seconds
            + Int64(remaining.components.attoseconds / 1_000_000_000_000_000_000)
        guard remainingSeconds <= Int64(seconds) else { return false }
        guard !envelope.isGlobalPersistent else { return false }
        guard !envelope.grants.isEmpty else { return false }
        // Nothing inside the envelope may outlive the envelope: a grant stamped with a
        // later expiry would keep authorising after the operator believed the batch had
        // ended, and revoking the envelope would leave it alive.
        for grant in envelope.grants where grant.expiresAt > envelope.expiresAt {
            return false
        }
        return true
    }
}
