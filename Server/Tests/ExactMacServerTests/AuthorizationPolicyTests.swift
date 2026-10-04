@testable import ExactMacServer
import Foundation
import XCTest

/// The decision engine's acceptance suite.
///
/// Table-driven rather than representative, because the engine's whole job is to be
/// TOTAL: every capability, every scope, every posture, with and without a matching
/// grant, expired and unexpired, and every way the system can be broken. A test that
/// checks three representative combinations proves nothing about the other forty.
final class AuthorizationPolicyTests: XCTestCase {
    // MARK: - Fixtures

    private let now = MonotonicInstant(nanoseconds: 1_000_000_000_000)

    /// Signed arithmetic throughout, because the suite needs instants in the PAST to
    /// prove that an expired grant denies, and `UInt64(-1)` traps rather than wrapping —
    /// which killed the test process mid-run instead of failing one assertion.
    private func instant(offsetSeconds: Int) -> MonotonicInstant {
        let base = Int64(bitPattern: now.nanoseconds)
        let delta = Int64(offsetSeconds) &* 1_000_000_000
        return MonotonicInstant(nanoseconds: UInt64(bitPattern: base &+ delta))
    }

    /// The real shape of a caller: `exactmac`, the stdio MCP process, which is the peer
    /// on the socket. It is deliberately ad-hoc signed, because that is what a locally
    /// built Go binary is, and an ad-hoc peer is the common case rather than the worst.
    private func peerIdentity(
        signature: SignatureState = .adHoc,
        path: String = "/usr/local/bin/exactmac",
        bundleIdentifier: String? = "io.github.joeycumines.exactmac",
        requirement: String? = "identifier \"io.github.joeycumines.exactmac\" and anchor apple generic",
        pid: Int32 = 4517,
        isFullyResolved: Bool = true,
    ) -> CallerIdentity {
        CallerIdentity(
            processIdentifier: pid,
            effectiveUserIdentifier: 501,
            parentProcessIdentifier: 4490,
            code: CodeIdentity(
                executablePath: path,
                bundleIdentifier: bundleIdentifier,
                designatedRequirement: requirement,
                signature: signature,
            ),
            isFullyResolved: isFullyResolved,
        )
    }

    private func request(
        _ capability: Capability,
        scope: AuthorizationScope = AuthorizationScope(),
        id: String = "req-1",
    ) -> AuthorizationRequest {
        AuthorizationRequest(
            id: AuthorizationRequestID(rawValue: id),
            rpcName: "exactmac.v1.ExactMac/Test",
            capability: capability,
            scope: scope,
            argumentSummary: "a representative argument",
            agentReason: "because the test says so",
            origin: .directSocket,
        )
    }

    private func grant(
        _ capability: Capability,
        scope: AuthorizationScope = AuthorizationScope(),
        identity: CallerIdentity? = nil,
        expiresInSeconds: Int = 3600,
        remainingOperations: Int? = nil,
        id: String = "grant-1",
    ) -> Grant {
        let holder = (identity ?? peerIdentity()).code.binding
        return Grant(
            id: id,
            capability: capability,
            scope: scope,
            duration: .monotonicSeconds(expiresInSeconds),
            holder: holder,
            issuedAt: now,
            expiresAt: instant(offsetSeconds: expiresInSeconds),
            origin: .prompt(decidedAt: now),
            // A count-bounded grant with no consumption counter authorises nothing, which
            // is the fail-closed reading and is deliberate: a grant that declares a limit
            // and cannot say how much of it is left is malformed. So a FRESH one is
            // modelled with its full declared budget, and exhausting it is a separate
            // test below.
            remainingOperations: remainingOperations ?? scope.operationLimit,
            targetIsHighConsequence: false,
        )
    }

    private func envelope(
        _ capability: Capability,
        scope: AuthorizationScope = AuthorizationScope(
            application: .bundleIdentifier("com.apple.TextEdit"),
        ),
        identity: CallerIdentity? = nil,
        durationSeconds: Int = 3600,
        id: String = "env-1",
    ) -> PreAuthorizationEnvelope {
        let holder = (identity ?? peerIdentity()).code.binding
        return PreAuthorizationEnvelope(
            id: id,
            grants: [grant(capability, scope: scope, identity: identity, id: "env-1-grant")],
            declaredDuration: .monotonicSeconds(durationSeconds),
            expiresAt: instant(offsetSeconds: durationSeconds),
            holder: holder,
        )
    }

    private func decide(
        _ request: AuthorizationRequest,
        identity: CallerIdentity? = nil,
        grants: [Grant] = [],
        envelopes: [PreAuthorizationEnvelope] = [],
        posture: Posture = .balanced,
        context: AuthorizationContext = .unixSocket(),
        at instant: MonotonicInstant? = nil,
    ) -> AuthorizationDecision {
        AuthorizationPolicy.evaluate(
            request: request,
            identity: identity ?? peerIdentity(),
            grants: grants,
            envelopes: envelopes,
            posture: posture,
            context: context,
            now: instant ?? now,
        )
    }

    private var scopes: [(name: String, scope: AuthorizationScope)] {
        [
            ("any application", AuthorizationScope()),
            ("one application", AuthorizationScope(application: .bundleIdentifier("com.apple.TextEdit"))),
            ("one process", AuthorizationScope(application: .processIdentifier(4211))),
            ("one window", AuthorizationScope(
                application: .bundleIdentifier("com.apple.TextEdit"),
                window: .identifier("window-1"),
            )),
            ("count bounded", AuthorizationScope(operationLimit: 3)),
        ]
    }

    // MARK: - The table

    /// Every capability crossed with every scope, with no standing grant. Balanced
    /// prompts; strict prompts; locked down denies; and nothing is allowed by accident.
    func testEveryCapabilityCrossedWithEveryScopeAndPosture() {
        var checked = 0
        for capability in Capability.allCases {
            for entry in scopes {
                for posture in [Posture.strict, .balanced, .lockedDown] {
                    let decision = decide(
                        request(capability, scope: entry.scope),
                        posture: posture,
                    )
                    checked += 1
                    if !capability.requiresConsent {
                        XCTAssertEqual(decision.outcome, .allow, "\(capability) needs no consent")
                        XCTAssertEqual(decision.basis, .noConsentRequired)
                        continue
                    }
                    switch posture {
                    case .lockedDown:
                        XCTAssertEqual(decision.denialReason, .postureLockedDown, "\(capability)")
                    case .strict, .balanced:
                        XCTAssertEqual(decision.basis, .promptRequired, "\(capability) \(entry.name)")
                        XCTAssertFalse(decision.isAllowed)
                        XCTAssertFalse(
                            decision.offeredDecisions.isEmpty,
                            "\(capability) \(entry.name) must offer the operator something",
                        )
                    }
                }
            }
        }
        XCTAssertEqual(checked, Capability.allCases.count * scopes.count * 3)
        XCTAssertEqual(Capability.allCases.count, 17)
    }

    /// The same table with a MATCHING grant, and then with the same grant expired. The
    /// second half is the half that matters: an expired grant that still allows is the
    /// bug this whole subsystem exists to prevent.
    func testMatchingGrantAllowsAndItsExpiryIsHonoured() {
        for capability in Capability.allCases where capability.requiresConsent {
            for entry in scopes {
                let live = decide(
                    request(capability, scope: entry.scope),
                    grants: [grant(capability, scope: entry.scope)],
                )
                XCTAssertEqual(live.outcome, .allow, "\(capability) \(entry.name)")
                if case let .grant(id) = live.basis {
                    XCTAssertEqual(id, "grant-1")
                } else {
                    XCTFail("\(capability) \(entry.name) allowed on the wrong basis: \(live.basis)")
                }
                XCTAssertEqual(live.expiresAt, instant(offsetSeconds: 3600))

                let expired = decide(
                    request(capability, scope: entry.scope),
                    grants: [grant(capability, scope: entry.scope, expiresInSeconds: -1)],
                )
                XCTAssertFalse(expired.isAllowed, "an expired grant allowed \(capability) \(entry.name)")
                XCTAssertEqual(expired.basis, .promptRequired)
            }
        }
    }

    /// A strict posture ignores standing grants entirely, which is the difference
    /// between it and balanced.
    func testStrictPostureIgnoresStandingGrants() {
        let decision = decide(
            request(.clipboardRead),
            grants: [grant(.clipboardRead)],
            posture: .strict,
        )
        XCTAssertEqual(decision.basis, .promptRequired)
        XCTAssertFalse(decision.isAllowed)
    }

    // MARK: - The lattice

    func testScriptExecutionSubsumesTheRest() {
        // Every CONSENT-REQUIRING capability, and deliberately not `localEcho`: that one
        // reads nothing off the desktop, it echoes back input the caller itself
        // submitted, so no grant is needed for it and none should be implied by one.
        for capability in Capability.allCases where capability.requiresConsent {
            XCTAssertTrue(
                Capability.scriptExecute.implies(capability),
                "a shell reaches \(capability.rawValue)",
            )
        }
        XCTAssertFalse(
            Capability.scriptExecute.implies(.localEcho),
            "a shell does not need a grant to read back its own input",
        )
        XCTAssertFalse(
            Capability.clipboardRead.implies(.scriptExecute),
            "a clipboard grant must not cover a shell",
        )
        XCTAssertFalse(
            Capability.accessibilityTraverse.implies(.clipboardRead),
            "reading a tree is not reading the clipboard",
        )
        XCTAssertTrue(Capability.accessibilityTraverse.implies(.windowObserve))
        XCTAssertTrue(Capability.windowObserve.implies(.displayRead))
    }

    /// A grant for the broad capability covers the narrow request; the reverse is not
    /// true, and that asymmetry is the control.
    func testABroadGrantCoversANarrowRequestAndNotTheReverse() {
        let broad = decide(
            request(.clipboardRead, scope: AuthorizationScope(
                application: .bundleIdentifier("com.apple.TextEdit"),
            )),
            grants: [grant(.scriptExecute)],
        )
        XCTAssertEqual(broad.outcome, .allow)

        let narrow = decide(
            request(.scriptExecute),
            grants: [grant(.clipboardRead)],
        )
        XCTAssertEqual(narrow.basis, .promptRequired)
    }

    func testTheRequestCapabilityIsClosedOverImplication() {
        let decision = decide(request(.scriptExecute))
        XCTAssertTrue(decision.effectiveCapabilities.contains(.clipboardRead))
        XCTAssertTrue(decision.effectiveCapabilities.contains(.inputSynthesize))
        XCTAssertTrue(decision.effectiveCapabilities.contains(.scriptExecute))
    }

    // MARK: - Failing closed

    func testAnUnavailableConsoleDenies() {
        for posture in [Posture.strict, .balanced, .lockedDown] {
            let decision = decide(
                request(.clipboardRead),
                posture: posture == .lockedDown ? .balanced : posture,
                context: .unixSocket(isConsoleReachable: false),
            )
            XCTAssertEqual(decision.denialReason, .consoleUnreachable)
            XCTAssertTrue(decision.offeredDecisions.isEmpty, "a denial offers nothing to act on")
        }
    }

    /// The reduced TCP posture is a named state, not the absence of a dependency, and no
    /// posture turns it into anything else.
    func testTCPListenerDeniesEveryConsentRequiringCapability() {
        let tcp = AuthorizationContext(
            transport: .tcp,
            isConsoleReachable: true,
            peerAuthenticated: true,
            biometric: .available,
            store: .intact,
            highConsequenceTargets: [],
        )
        for capability in Capability.allCases {
            for posture in [Posture.strict, .balanced, .lockedDown] {
                let decision = decide(
                    request(capability),
                    grants: [grant(capability)],
                    posture: posture,
                    context: tcp,
                )
                if capability.requiresConsent {
                    XCTAssertEqual(
                        decision.denialReason,
                        .reducedUnauthenticatedPosture,
                        "\(capability.rawValue) over TCP must be denied, not granted by a stored grant",
                    )
                } else {
                    XCTAssertEqual(decision.outcome, .allow)
                }
            }
        }
    }

    func testAnUnauthenticatedPeerDenies() {
        let decision = decide(
            request(.clipboardRead),
            grants: [grant(.clipboardRead)],
            context: .unixSocket(peerAuthenticated: false),
        )
        XCTAssertEqual(decision.denialReason, .unauthenticatedPeer)
    }

    /// An unreadable grant store is not an empty one. Treating it as empty turns a
    /// corrupt file into a blank slate of permissions.
    func testAnUnreadableGrantStoreDeniesEvenWithAGrantInHand() {
        let decision = decide(
            request(.clipboardRead),
            grants: [grant(.clipboardRead)],
            context: .unixSocket(store: .unreadable(reason: "EACCES")),
        )
        XCTAssertEqual(decision.denialReason, .grantStoreUnreadable)
    }

    /// A biometric that cannot be performed is a denial. It is never a downgrade to a
    /// weaker check, and never a silent allow.
    func testAnUnavailableBiometricDeniesRatherThanDowngrading() {
        for capability in Capability.allCases where capability.requiresConsent {
            let decision = decide(
                request(capability),
                context: .unixSocket(
                    biometric: .unavailable(reason: "no enrolled biometric"),
                ),
            )
            if case .required = decision.biometric {
                XCTAssertEqual(
                    decision.denialReason,
                    .biometricUnavailable,
                    "\(capability.rawValue) needed a ceremony that cannot run",
                )
            }
        }
    }

    func testNoPostureTurnsAnyDenialIntoAnAllow() {
        let broken: [(String, AuthorizationContext)] = [
            ("no console", .unixSocket(isConsoleReachable: false)),
            ("unauthenticated", .unixSocket(peerAuthenticated: false)),
            ("unreadable store", .unixSocket(store: .unreadable(reason: "corrupt"))),
            (
                "tcp",
                AuthorizationContext(
                    transport: .tcp,
                    isConsoleReachable: true,
                    peerAuthenticated: true,
                    biometric: .available,
                    store: .intact,
                    highConsequenceTargets: [],
                ),
            ),
        ]
        for (label, environment) in broken {
            for capability in Capability.allCases where capability.requiresConsent {
                for posture in [Posture.strict, .balanced, .lockedDown] {
                    // No standing grant here, and that is the point rather than an
                    // omission: a LIVE grant legitimately survives a broken system,
                    // because it was approved when the system worked and re-asking would
                    // mean the operator's decision had an expiry independent of the one
                    // they agreed to. What must never happen is a broken system turning a
                    // request that needs a DECISION into an allow.
                    let decision = decide(
                        request(capability),
                        posture: posture,
                        context: environment,
                    )
                    XCTAssertFalse(
                        decision.isAllowed,
                        "\(label) allowed \(capability.rawValue) under \(posture)",
                    )
                }
            }
        }
    }

    /// The distinction the previous test blurred, and it matters: a biometric is a
    /// CEREMONY at grant-creation time, not a system-availability property. So an
    /// unavailable biometric must block a request that needs a ceremony, and must NOT
    /// retroactively void a grant the operator already approved — the ceremony already
    /// happened when that grant was made.
    func testAnUnavailableBiometricBlocksTheCeremonyAndNotAnExistingGrant() {
        let noBiometric = AuthorizationContext.unixSocket(
            biometric: .unavailable(reason: "locked out"),
        )
        let needsCeremony = decide(
            request(.scriptExecute, scope: AuthorizationScope()),
            context: noBiometric,
        )
        XCTAssertEqual(needsCeremony.denialReason, .biometricUnavailable)

        let alreadyGranted = decide(
            request(.scriptExecute, scope: AuthorizationScope()),
            grants: [grant(.scriptExecute, scope: AuthorizationScope())],
            context: noBiometric,
        )
        XCTAssertEqual(
            alreadyGranted.outcome,
            .allow,
            "a grant approved with a fingerprint keeps working when Touch ID is later unavailable",
        )

        // And a narrow request that never needed a ceremony still prompts rather than
        // being waved through by the broken sensor.
        let narrow = decide(
            request(.clipboardRead, scope: AuthorizationScope(
                application: .bundleIdentifier("com.apple.TextEdit"),
            )),
            context: noBiometric,
        )
        XCTAssertEqual(narrow.basis, .promptRequired)
    }

    /// The counterpart, stated because it is the subtle half: a live grant does not need
    /// the console. Re-prompting on every call would make a grant meaningless, and an
    /// approval whose meaning depended on a running UI would not be an approval.
    func testALiveGrantSurvivesAnUnreachableConsole() {
        for capability in Capability.allCases where capability.requiresConsent {
            let decision = decide(
                request(capability),
                grants: [grant(capability)],
                context: .unixSocket(isConsoleReachable: false),
            )
            XCTAssertEqual(decision.outcome, .allow, "\(capability.rawValue)")
            if case .grant = decision.basis {} else {
                XCTFail("allowed on the wrong basis: \(decision.basis)")
            }
        }
    }

    /// And once the grant is gone the same broken system denies, so the two mechanisms
    /// are not quietly covering for each other.
    func testAnExpiredGrantPlusAnUnreachableConsoleDenies() {
        let decision = decide(
            request(.clipboardRead),
            grants: [grant(.clipboardRead, expiresInSeconds: -1)],
            context: .unixSocket(isConsoleReachable: false),
        )
        XCTAssertEqual(decision.denialReason, .consoleUnreachable)
    }

    // MARK: - Graded evidence, not a gate

    /// An unsigned caller is ESCALATED, never denied. The boundary was crossed at socket
    /// access, and same-uid malware is cryptographically indistinguishable from the
    /// operator's own agent, so a control that rejected unsigned callers would be
    /// providing false assurance.
    func testAnUnsignedCallerIsEscalatedRatherThanDenied() {
        let unsigned = peerIdentity(signature: .unsigned, requirement: nil)
        let decision = decide(request(.clipboardRead), identity: unsigned)
        XCTAssertEqual(decision.basis, .promptRequired)
        if case let .required(reason) = decision.biometric {
            XCTAssertTrue(reason.contains("signed"), "the reason must name the weakness")
        } else {
            XCTFail("an unsigned caller must escalate to a ceremony")
        }
    }

    func testAnUnresolvedCallerEscalatesRatherThanBeingTrusted() {
        let unresolved = peerIdentity(
            signature: .unresolved,
            requirement: nil,
            isFullyResolved: false,
        )
        let decision = decide(request(.clipboardRead), identity: unresolved)
        XCTAssertEqual(decision.basis, .promptRequired)
        if case .notRequired = decision.biometric {
            XCTFail("an unresolved caller must not pass without friction")
        }
    }

    func testSignatureQualityMovesTheRiskClassWithoutChangingTheOutcome() {
        let signed = decide(
            request(.clipboardRead),
            identity: peerIdentity(signature: .signedAndValid),
        )
        let unsigned = decide(
            request(.clipboardRead),
            identity: peerIdentity(signature: .unsigned, requirement: nil),
        )
        XCTAssertEqual(signed.basis, unsigned.basis)
        XCTAssertLessThan(signed.blastRadius.radius, unsigned.blastRadius.radius)
    }

    // MARK: - Code identity, never a pid

    /// THE BINDING TEST. A grant issued to a signed application must not be inherited by
    /// an unsigned binary at another path running as the same user, and must not be
    /// inherited by a different process that later receives the original pid.
    func testAGrantBindsToCodeIdentityAndNotToAPid() {
        let signedIdentity = peerIdentity(
            signature: .signedAndValid,
            path: "/Applications/Codex.app/Contents/MacOS/Codex",
            bundleIdentifier: "com.openai.codex",
            requirement: "identifier \"com.openai.codex\" and anchor apple generic",
        )
        let grantForSigned = grant(.clipboardRead, identity: signedIdentity)

        let unsignedImpostor = peerIdentity(
            signature: .unsigned,
            path: "/tmp/exactmac",
            bundleIdentifier: nil,
            requirement: nil,
            pid: 4517,
        )
        let byPid = decide(
            request(.clipboardRead),
            identity: unsignedImpostor,
            grants: [grantForSigned],
        )
        XCTAssertEqual(byPid.basis, .promptRequired, "a pid is not an identity")

        let sameBinaryWrongSignature = peerIdentity(
            signature: .unsigned,
            path: "/Applications/Codex.app/Contents/MacOS/Codex",
            bundleIdentifier: "com.openai.codex",
            requirement: nil,
            pid: 9999,
        )
        XCTAssertEqual(
            decide(
                request(.clipboardRead),
                identity: sameBinaryWrongSignature,
                grants: [grantForSigned],
            ).basis,
            .promptRequired,
            "an unsigned binary does not satisfy a signed binding",
        )

        let theRealThing = decide(
            request(.clipboardRead),
            identity: signedIdentity,
            grants: [grantForSigned],
        )
        XCTAssertEqual(theRealThing.outcome, .allow)
    }

    /// An unsigned CALLER still binds, by canonical path. A grant that degraded to
    /// "unbound" would be claimable by any process at all.
    func testAnUnsignedGrantHolderBindsByCanonicalPath() {
        let unsignedPeer = peerIdentity(signature: .unsigned, requirement: nil)
        let grantForIt = grant(.clipboardRead, identity: unsignedPeer)
        XCTAssertNil(grantForIt.holder.designatedRequirement)
        XCTAssertEqual(
            decide(
                request(.clipboardRead),
                identity: unsignedPeer,
                grants: [grantForIt],
            ).outcome,
            .allow,
        )
        let elsewhere = peerIdentity(
            signature: .unsigned,
            path: "/tmp/exactmac",
            requirement: nil,
        )
        XCTAssertEqual(
            decide(request(.clipboardRead), identity: elsewhere, grants: [grantForIt]).basis,
            .promptRequired,
        )
    }

    // MARK: - Breadth and counts

    func testScopeBreadthOnlyGrowsDownward() {
        let oneApp = AuthorizationScope(application: .bundleIdentifier("com.apple.TextEdit"))
        let everything = AuthorizationScope()
        XCTAssertTrue(everything.covers(oneApp))
        XCTAssertFalse(oneApp.covers(everything))
        XCTAssertFalse(
            oneApp.covers(AuthorizationScope(application: .bundleIdentifier("com.apple.Safari"))),
        )
        XCTAssertFalse(
            oneApp.covers(AuthorizationScope(application: .processIdentifier(4211))),
            "a bundle grant does not cover a pid request",
        )
    }

    /// A transaction is authorized as a scope with a declared count. A bounded grant
    /// never covers an unbounded request, and a grant with too little left does not
    /// cover the request.
    func testCountBoundedGrantsAreConsumableAndNeverAmortise() {
        let bounded = AuthorizationScope(operationLimit: 5)
        XCTAssertTrue(AuthorizationScope().covers(bounded), "unbounded covers bounded")
        XCTAssertFalse(bounded.covers(AuthorizationScope()), "bounded never covers unbounded")

        let plenty = decide(
            request(.transactionManage, scope: AuthorizationScope(operationLimit: 3)),
            grants: [grant(
                .transactionManage,
                scope: bounded,
                remainingOperations: 10,
            )],
        )
        XCTAssertEqual(plenty.outcome, .allow)

        let spent = decide(
            request(.transactionManage, scope: AuthorizationScope(operationLimit: 3)),
            grants: [grant(
                .transactionManage,
                scope: bounded,
                remainingOperations: 1,
            )],
        )
        XCTAssertEqual(spent.basis, .promptRequired)
    }

    // MARK: - Envelopes

    func testALiveEnvelopeAuthorisesAndAnExpiredOneDoesNot() {
        // Scoped to an application, because a global batch is exactly what the admission
        // check refuses — the fixture used to be inadmissible and the engine was right to
        // ignore it.
        let inside = decide(
            request(.clipboardRead, scope: AuthorizationScope(
                application: .bundleIdentifier("com.apple.TextEdit"),
            )),
            envelopes: [envelope(.clipboardRead)],
        )
        XCTAssertEqual(inside.outcome, .allow)
        if case let .envelope(id) = inside.basis {
            XCTAssertEqual(id, "env-1")
        } else {
            XCTFail("allowed on the wrong basis: \(inside.basis)")
        }

        let outside = decide(
            request(
                .inputSynthesize,
                scope: AuthorizationScope(application: .bundleIdentifier("com.apple.TextEdit")),
            ),
            envelopes: [envelope(.clipboardRead)],
        )
        XCTAssertEqual(outside.basis, .promptRequired, "an envelope is not a blanket permission")

        let expired = decide(
            request(.clipboardRead, scope: AuthorizationScope(
                application: .bundleIdentifier("com.apple.TextEdit"),
            )),
            envelopes: [envelope(.clipboardRead, durationSeconds: -1)],
        )
        XCTAssertEqual(expired.basis, .promptRequired)
    }

    /// An envelope can never be global-persistent and can never outlive the ceiling.
    /// Both are re-checked at evaluation, because a stored object that has become
    /// invalid must not be honoured on the strength of having once been valid.
    func testEnvelopeValidationRejectsGlobalScopeAndOverLongDuration() {
        let global = envelope(.clipboardRead, scope: AuthorizationScope())
        XCTAssertTrue(global.isGlobalPersistent)
        XCTAssertFalse(AuthorizationPolicy.envelopeIsAdmissible(global, now: now))
        XCTAssertTrue(
            AuthorizationPolicy.envelopeIsAdmissible(envelope(.clipboardRead), now: now),
            "a batch scoped to one application is admissible",
        )

        let tooLong = envelope(.clipboardRead, durationSeconds: 9 * 60 * 60)
        XCTAssertFalse(AuthorizationPolicy.envelopeIsAdmissible(tooLong, now: now))

        let atCeiling = envelope(
            .clipboardRead,
            scope: AuthorizationScope(application: .bundleIdentifier("com.apple.TextEdit")),
            durationSeconds: AuthorizationPolicy.maximumEnvelopeSeconds,
        )
        XCTAssertTrue(
            AuthorizationPolicy.envelopeIsAdmissible(atCeiling, now: now),
            "a batch at the eight-hour ceiling is admissible",
        )

        let empty = PreAuthorizationEnvelope(
            id: "env-empty",
            grants: [],
            declaredDuration: .monotonicSeconds(60),
            expiresAt: instant(offsetSeconds: 60),
            holder: peerIdentity().code.binding,
        )
        XCTAssertFalse(AuthorizationPolicy.envelopeIsAdmissible(empty, now: now))
    }

    // MARK: - The biometric table

    func testBiometricRequirementIsAPureFunctionOfWhatIsBeingAuthorised() {
        var required = 0
        var optional = 0
        let oneApp = AuthorizationScope(application: .bundleIdentifier("com.apple.TextEdit"))
        let everywhere = AuthorizationScope()
        for capability in Capability.allCases {
            for scope in [oneApp, everywhere] {
                for duration in [GrantDuration.once, .monotonicSeconds(900), .monotonicSeconds(28800)] {
                    for risk in RiskClass.allCases {
                        for signature in [SignatureState.signedAndValid, .unsigned] {
                            for high in [false, true] {
                                let requirement = AuthorizationPolicy.biometricRequirement(
                                    capability: capability,
                                    scope: scope,
                                    duration: duration,
                                    riskClass: risk,
                                    targetIsHighConsequence: high,
                                    signature: signature,
                                )
                                switch requirement {
                                case .required: required += 1
                                case .notRequired: optional += 1
                                }
                                // Script execution requires a ceremony at EVERY breadth and
                                // every risk, including allow-once on a signed caller. My
                                // first version of this assertion claimed the narrow
                                // exemption applied to it, which is exactly the inversion the
                                // table test was written to catch: a shell can read the
                                // screen, the clipboard and the interface, so no script runs
                                // on a hurried keystroke.
                                if capability == .scriptExecute, duration == .once,
                                   risk == .routine, !high, signature == .signedAndValid
                                {
                                    XCTAssertEqual(
                                        requirement,
                                        .required(reason: "a shell can read your screen, your clipboard and your keystrokes"),
                                    )
                                }
                                // The exemption itself, on a capability where it does apply.
                                if capability == .clipboardRead, duration == .once, !scope.application.isGlobal,
                                   risk == .routine, !high, signature == .signedAndValid
                                {
                                    XCTAssertEqual(
                                        requirement,
                                        .notRequired,
                                        "a narrow clipboard read is where friction is deliberately not spent",
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(required, 0)
        XCTAssertGreaterThan(optional, 0, "a policy that always demands a ceremony is a failed control")
    }

    func testRevokingEverythingAlwaysNeedsABiometric() {
        XCTAssertEqual(
            AuthorizationPolicy.biometricRequirement(
                capability: .clipboardRead,
                riskClass: .routine,
                targetIsHighConsequence: false,
                signature: .signedAndValid,
                isRevokeAll: true,
            ),
            .required(reason: "revoking every grant at once"),
        )
    }

    func testAGlobalPersistentGrantAlwaysNeedsABiometric() {
        for capability in Capability.allCases {
            // Asserted as a CASE, not as a string. A shell answers with its own reason
            // before the breadth one, and that ordering is deliberate: the ceremony
            // should name the most dangerous thing being authorised.
            guard case let .required(reason) = AuthorizationPolicy.biometricRequirement(
                capability: capability,
                scope: AuthorizationScope(),
                duration: .monotonicSeconds(AuthorizationPolicy.maximumEnvelopeSeconds),
                riskClass: .routine,
                targetIsHighConsequence: false,
                signature: .signedAndValid,
            ) else {
                XCTFail("\(capability.rawValue) allowed a global persistent grant with no ceremony")
                continue
            }
            XCTAssertFalse(reason.isEmpty, "\(capability.rawValue) must name what is being authorized")
        }
    }

    /// BREADTH x PERSISTENCE, which is the rule the design's own worked example states.
    func testBreadthTimesPersistenceIsWhatCostsACeremony() {
        let everyApp = AuthorizationScope()
        let oneApp = AuthorizationScope(application: .bundleIdentifier("com.apple.TextEdit"))
        let eightHours = GrantDuration.monotonicSeconds(AuthorizationPolicy.maximumEnvelopeSeconds)

        XCTAssertEqual(
            AuthorizationPolicy.biometricRequirement(
                capability: .clipboardRead, scope: everyApp, duration: eightHours,
            ),
            .required(reason: "a standing permission over every application until you revoke it"),
            "gf-2 states this case explicitly: every application, continuously, costs a biometric",
        )
        XCTAssertEqual(
            AuthorizationPolicy.biometricRequirement(
                capability: .clipboardRead, scope: everyApp, duration: .once,
            ),
            .notRequired,
            "a single global read is not a standing permission",
        )
        XCTAssertEqual(
            AuthorizationPolicy.biometricRequirement(
                capability: .clipboardRead, scope: oneApp, duration: eightHours,
            ),
            .notRequired,
            "a narrow long grant is a standing permission, but a narrow one",
        )
    }

    // MARK: - The offered decisions

    /// The ordering is a security property: the default leads, the destructive option is
    /// never the default, and Deny is never adjacent to whatever holds focus.
    func testDenyIsNeverTheDefaultAndNeverSitsBesideThePrimary() {
        for capability in Capability.allCases where capability.requiresConsent {
            for entry in scopes {
                for risk in RiskClass.allCases {
                    let offered = AuthorizationPolicy.offeredDecisions(
                        for: request(capability, scope: entry.scope),
                        posture: .balanced,
                        riskClass: risk,
                    )
                    let defaults = offered.filter(\.isDefault)
                    XCTAssertEqual(defaults.count, 1, "\(capability) \(entry.name) \(risk)")
                    // Guarded rather than subscripted: a drop to zero used to trap here and
                    // kill the process, which is the one failure mode a table this size
                    // cannot afford.
                    guard let focused = defaults.first else { continue }
                    XCTAssertFalse(
                        focused.isDestructive,
                        "\(capability) \(entry.name) \(risk) defaults to a destructive option",
                    )
                    // Deny is always marked destructive, which is what makes "the
                    // default is never the destructive option" a real assertion rather
                    // than a tautology.
                    for option in offered where option.kind == .deny {
                        XCTAssertTrue(
                            option.isDestructive,
                            "\(capability) \(entry.name) \(risk) does not mark Deny destructive",
                        )
                    }
                    // Adjacency only means anything in a list long enough to misclick, and
                    // the strict posture genuinely has two options — where the DESIGN puts
                    // Deny on its own row below a hairline rather than in the list at all.
                    // With three or more, Deny must touch neither the focused option nor
                    // the primary action.
                    if offered.count < 3 {
                        // The strict posture's only two options. Adjacency is unavoidable
                        // in a list of two, and the DESIGN puts Deny on its own row below
                        // a hairline rather than in the list at all — so what is asserted
                        // here is that the two are ordered least-destructive first.
                        XCTAssertEqual(
                            offered.map(\.kind),
                            [.allowOnce, .deny],
                            "\(capability) \(entry.name) \(risk) changed the strict-posture pair",
                        )
                        continue
                    }
                    if let defaultIndex = offered.firstIndex(where: \.isDefault),
                       let denyIndex = offered.firstIndex(where: { $0.kind == .deny }),
                       let primaryIndex = offered.firstIndex(where: \.isPrimary)
                    {
                        XCTAssertNotEqual(
                            abs(denyIndex - primaryIndex),
                            1,
                            "Deny sits immediately beside the primary action",
                        )
                        XCTAssertGreaterThan(
                            abs(denyIndex - defaultIndex),
                            1,
                            "Deny sits immediately beside the focused option",
                        )
                    }
                }
            }
        }
    }

    /// "Allow for this application" is meaningless when the request named no
    /// application, and offering it anyway is how a UI starts lying about its own scope.
    func testApplicationScopedOptionsOnlyAppearWhenTheRequestNamedOne() {
        let globalRequest = request(.clipboardRead, scope: AuthorizationScope())
        let globalKinds = AuthorizationPolicy.offeredDecisions(
            for: globalRequest, posture: .balanced, riskClass: .routine,
        ).map(\.kind)
        XCTAssertFalse(globalKinds.contains(.allowTargetApplication))
        XCTAssertTrue(globalKinds.contains(.allowGlobalPersistent))

        let appRequest = request(
            .clipboardRead,
            scope: AuthorizationScope(application: .bundleIdentifier("com.apple.TextEdit")),
        )
        let appKinds = AuthorizationPolicy.offeredDecisions(
            for: appRequest, posture: .balanced, riskClass: .routine,
        ).map(\.kind)
        XCTAssertTrue(appKinds.contains(.allowTargetApplication))
        XCTAssertFalse(
            appKinds.contains(.allowGlobalPersistent),
            "a global grant for a request about one application is a decision the operator did not think they were making",
        )
    }

    /// Under the strict posture nothing persists, so the durable options are withdrawn
    /// rather than shown and then ignored.
    func testStrictPostureWithdrawsTheDurableOptions() {
        let kinds = AuthorizationPolicy.offeredDecisions(
            for: request(
                .clipboardRead,
                scope: AuthorizationScope(application: .bundleIdentifier("com.apple.TextEdit")),
            ),
            posture: .strict,
            riskClass: .routine,
        ).map(\.kind)
        XCTAssertEqual(Set(kinds), [.allowOnce, .deny])
    }

    // MARK: - Monotonic time

    /// Moving the wall clock must not be able to extend a grant, which is why nothing in
    /// the model holds a wall-clock time at all.
    func testExpiryIsMonotonicAndArithmeticSaturates() {
        let start = MonotonicInstant(nanoseconds: UInt64.max - 10)
        let advanced = start.advanced(by: .seconds(3600))
        XCTAssertEqual(advanced.nanoseconds, UInt64.max, "overflow must saturate, not wrap into the past")

        let base = MonotonicInstant(nanoseconds: 1000)
        XCTAssertEqual(base.remaining(until: MonotonicInstant(nanoseconds: 1500)), .nanoseconds(500))
        XCTAssertNil(base.remaining(until: base), "a deadline in the past leaves nothing")
    }

    // MARK: E24 — capability consent partition is explicit, positive-listed, and exhaustive

    /// Task E24: The set of capabilities that require no consent is stated explicitly in code
    /// as a positive list with a stated reason for each member, rather than emerging from a subtraction.
    /// Reading the display layout does not prompt.
    /// A test asserts the partition directly — which capabilities are on each side — so a capability
    /// added later cannot silently inherit the permissive side.
    func testCapabilityConsentPartitionIsExplicitAndExhaustive() {
        let nonConsent = Set(Capability.allCases.filter { !$0.requiresConsent })
        let consent = Set(Capability.allCases.filter(\.requiresConsent))

        // Assert exact members of each partition
        XCTAssertEqual(
            nonConsent,
            [.localEcho, .displayRead],
            "Only localEcho and displayRead may be on the non-consent side",
        )
        XCTAssertEqual(
            consent,
            [
                .scriptExecute,
                .macroExecute,
                .accessibilityTraverse,
                .windowObserve,
                .screenObserve,
                .observationStream,
                .clipboardRead,
                .clipboardWrite,
                .inputSynthesize,
                .windowManage,
                .applicationControl,
                .fileDialogAutomate,
                .transactionManage,
                .sessionManage,
                .authorizationManage,
            ],
            "Every other capability requires an operator consent decision",
        )

        // Union equals all cases, intersection is empty
        XCTAssertEqual(nonConsent.union(consent), Set(Capability.allCases))
        XCTAssertTrue(nonConsent.isDisjoint(with: consent))

        // Every non-consent capability has an explicit non-empty justification
        for cap in nonConsent {
            let reason = Capability.nonConsentRequiringCapabilities[cap]
            XCTAssertNotNil(reason, "\(cap) must have an explicit reason documented in nonConsentRequiringCapabilities")
            XCTAssertFalse(reason?.isEmpty ?? true)
        }

        // Verify that display.read does not prompt and is evaluated to .noConsentRequired
        let displayRequest = request(.displayRead, scope: AuthorizationScope())
        let displayDecision = decide(displayRequest, posture: .strict)
        XCTAssertEqual(displayDecision.outcome, .allow, "display.read must be allowed without prompting")
        XCTAssertEqual(displayDecision.basis, .noConsentRequired)
    }

    // MARK: E29 — reading display layout never prompts across repeated requests or with prior grant

    func testDisplayReadNeverPromptsEvenAcrossRepeatedRequestsOrWithPriorGrant() {
        let displayReq = request(.displayRead, scope: AuthorizationScope())

        // 1. Initial request without grant: allows without prompt on all postures
        for posture in [Posture.strict, .balanced] {
            let initial = decide(displayReq, posture: posture)
            XCTAssertEqual(initial.outcome, .allow)
            XCTAssertEqual(initial.basis, .noConsentRequired)
            XCTAssertFalse(initial.basis == .promptRequired, "display.read must never prompt")
        }

        // 2. Prior grant present: still allows with .noConsentRequired
        let priorGrant = grant(.displayRead, scope: AuthorizationScope())
        let subsequent = decide(displayReq, grants: [priorGrant], posture: .strict)
        XCTAssertEqual(subsequent.outcome, .allow)
        XCTAssertEqual(subsequent.basis, .noConsentRequired)

        // 3. Repeated requests: cadence is zero prompts
        for _ in 1 ... 10 {
            let repeated = decide(displayReq, posture: .balanced)
            XCTAssertEqual(repeated.outcome, .allow)
            XCTAssertEqual(repeated.basis, .noConsentRequired)
        }
    }
}

/// Regressions for the six blocking findings an independent review returned on C1.
/// Each one is a defect that compiled, passed its own tests, and was found by
/// construction-fuzzing or by reading the code against the design rather than by
/// writing a test — so each is now pinned.
final class AuthorizationPolicyReviewRegressionTests: XCTestCase {
    private let now = MonotonicInstant(nanoseconds: 1_000_000_000_000)

    private func instant(offsetSeconds: Int) -> MonotonicInstant {
        let base = Int64(bitPattern: now.nanoseconds)
        let delta = Int64(offsetSeconds) &* 1_000_000_000
        return MonotonicInstant(nanoseconds: UInt64(bitPattern: base &+ delta))
    }

    private func peerIdentity(
        signature: SignatureState = .adHoc,
        path: String = "/usr/local/bin/exactmac",
        bundleIdentifier: String? = "io.github.joeycumines.exactmac",
        requirement: String? = "identifier \"io.github.joeycumines.exactmac\" and anchor apple generic",
        isFullyResolved: Bool = true,
    ) -> CallerIdentity {
        CallerIdentity(
            processIdentifier: 4517,
            effectiveUserIdentifier: 501,
            parentProcessIdentifier: 4490,
            code: CodeIdentity(
                executablePath: path,
                bundleIdentifier: bundleIdentifier,
                designatedRequirement: requirement,
                signature: signature,
            ),
            isFullyResolved: isFullyResolved,
        )
    }

    private func request(
        _ capability: Capability,
        scope: AuthorizationScope = AuthorizationScope(),
        reason: String? = "because the test says so",
        origin: RequestOrigin = .directSocket,
    ) -> AuthorizationRequest {
        AuthorizationRequest(
            id: AuthorizationRequestID(rawValue: "req-1"),
            rpcName: "exactmac.v1.ExactMac/Test",
            capability: capability,
            scope: scope,
            argumentSummary: "a representative argument",
            agentReason: reason,
            origin: origin,
        )
    }

    private func grant(
        _ capability: Capability,
        scope: AuthorizationScope = AuthorizationScope(),
        identity: CallerIdentity? = nil,
        expiresInSeconds: Int = 3600,
        duration: GrantDuration = .monotonicSeconds(3600),
        remainingOperations: Int? = nil,
    ) -> Grant {
        Grant(
            id: "grant-1",
            capability: capability,
            scope: scope,
            duration: duration,
            holder: (identity ?? peerIdentity()).code.binding,
            issuedAt: now,
            expiresAt: instant(offsetSeconds: expiresInSeconds),
            origin: .prompt(decidedAt: now),
            remainingOperations: remainingOperations ?? scope.operationLimit,
            targetIsHighConsequence: false,
        )
    }

    private func decide(
        _ request: AuthorizationRequest,
        identity: CallerIdentity? = nil,
        grants: [Grant] = [],
        envelopes: [PreAuthorizationEnvelope] = [],
        posture: Posture = .balanced,
        context: AuthorizationContext = .unixSocket(),
    ) -> AuthorizationDecision {
        AuthorizationPolicy.evaluate(
            request: request,
            identity: identity ?? peerIdentity(),
            grants: grants,
            envelopes: envelopes,
            posture: posture,
            context: context,
            now: now,
        )
    }

    private var consentCapabilities: [Capability] {
        Capability.allCases.filter(\.requiresConsent)
    }

    // MARK: B1 — an envelope the admission check rejects must not be honoured

    /// The admission check existed, was documented as "re-checked at evaluation", and was
    /// never called from `evaluate`. A global-persistent envelope therefore authorised
    /// requests, which is precisely what the type's own documentation says can never be
    /// true.
    func testAnInadmissibleEnvelopeIsNotHonouredAtEvaluation() {
        let globalEnvelope = PreAuthorizationEnvelope(
            id: "env-global",
            grants: [grant(.clipboardRead, scope: AuthorizationScope())],
            declaredDuration: .monotonicSeconds(3600),
            expiresAt: instant(offsetSeconds: 3600),
            holder: peerIdentity().code.binding,
        )
        XCTAssertTrue(globalEnvelope.isGlobalPersistent)
        XCTAssertFalse(AuthorizationPolicy.envelopeIsAdmissible(globalEnvelope, now: now))
        let decision = decide(
            request(.clipboardRead, scope: AuthorizationScope()),
            envelopes: [globalEnvelope],
        )
        XCTAssertEqual(
            decision.basis,
            .promptRequired,
            "a global-persistent envelope authorised a request",
        )
        XCTAssertFalse(decision.isAllowed)
    }

    func testAnOverLongEnvelopeIsNotHonouredAtEvaluation() {
        let tooLong = PreAuthorizationEnvelope(
            id: "env-long",
            grants: [grant(.clipboardRead, scope: AuthorizationScope(
                application: .bundleIdentifier("com.apple.TextEdit"),
            ))],
            declaredDuration: .monotonicSeconds(9 * 60 * 60),
            expiresAt: instant(offsetSeconds: 9 * 60 * 60),
            holder: peerIdentity().code.binding,
        )
        XCTAssertFalse(AuthorizationPolicy.envelopeIsAdmissible(tooLong, now: now))
        XCTAssertEqual(
            decide(
                request(
                    .clipboardRead,
                    scope: AuthorizationScope(application: .bundleIdentifier("com.apple.TextEdit")),
                ),
                envelopes: [tooLong],
            ).basis,
            .promptRequired,
        )
    }

    /// An envelope whose inner grant outlives the envelope keeps authorising after the
    /// operator believes the batch has ended, and revoking the envelope leaves it alive.
    func testAnEnvelopeWhoseGrantOutlivesItIsInadmissible() {
        let leaky = PreAuthorizationEnvelope(
            id: "env-leaky",
            grants: [grant(
                .clipboardRead,
                scope: AuthorizationScope(application: .bundleIdentifier("com.apple.TextEdit")),
                expiresInSeconds: 7200,
            )],
            declaredDuration: .monotonicSeconds(3600),
            expiresAt: instant(offsetSeconds: 3600),
            holder: peerIdentity().code.binding,
        )
        XCTAssertFalse(AuthorizationPolicy.envelopeIsAdmissible(leaky, now: now))
    }

    // MARK: B2 — friction must actually scale with blast radius

    /// Every risk class must be REACHABLE. The first version of the model pinned duration
    /// at 0.2, which capped the radius at 0.09 against a 0.18 threshold, so `.elevated`
    /// and `.high` could never occur and the whole escalation ladder was dead code. A
    /// review enumerated 1,344 decisions and found 0 of each.
    func testEveryRiskClassIsReachable() {
        var seen: Set<RiskClass> = []
        for capability in consentCapabilities {
            for scope in [
                AuthorizationScope(),
                AuthorizationScope(application: .bundleIdentifier("com.apple.TextEdit")),
                AuthorizationScope(application: .processIdentifier(4211)),
            ] {
                for duration in [
                    GrantDuration.once,
                    .monotonicSeconds(900),
                    .monotonicSeconds(AuthorizationPolicy.maximumEnvelopeSeconds),
                ] {
                    for signature in [SignatureState.signedAndValid, .unsigned] {
                        for high in [false, true] {
                            seen.insert(
                                AuthorizationPolicy.blastRadius(
                                    capability: capability,
                                    scope: scope,
                                    duration: duration,
                                    remainingCount: scope.operationLimit,
                                    targetIsHighConsequence: high,
                                    signatureQuality: signature.quality,
                                ).riskClass,
                            )
                        }
                    }
                }
            }
        }
        XCTAssertEqual(seen, [.routine, .elevated, .high], "a risk model that cannot reach its own top class is inert")
    }

    /// The design's own worked example, as an assertion: the same capability, once scoped
    /// to one application and once across every application for two hours, must not get
    /// the same friction.
    func testBreadthAndDurationChangeTheAnswer() {
        func radius(
            _ capability: Capability,
            _ scope: AuthorizationScope,
            _ duration: GrantDuration,
        ) -> Double {
            AuthorizationPolicy.blastRadius(
                capability: capability,
                scope: scope,
                duration: duration,
                remainingCount: nil,
                targetIsHighConsequence: false,
                signatureQuality: SignatureState.signedAndValid.quality,
            ).radius
        }
        let oneApp = AuthorizationScope(application: .bundleIdentifier("com.apple.TextEdit"))
        let everywhere = AuthorizationScope()
        let eightHours = GrantDuration.monotonicSeconds(AuthorizationPolicy.maximumEnvelopeSeconds)

        func risk(
            _ capability: Capability,
            _ scope: AuthorizationScope,
            _ duration: GrantDuration,
        ) -> RiskClass {
            AuthorizationPolicy.blastRadius(
                capability: capability,
                scope: scope,
                duration: duration,
                remainingCount: nil,
                targetIsHighConsequence: false,
                signatureQuality: SignatureState.signedAndValid.quality,
            ).riskClass
        }
        let narrow = radius(.clipboardRead, oneApp, .once)
        let broad = radius(.clipboardRead, everywhere, eightHours)
        XCTAssertGreaterThan(
            broad, narrow * 2,
            "breadth and duration together must move the radius, not one of them",
        )
        // The risk CLASS has to separate too, or every escalation that depends on it
        // stays dead. Two hours globally is still `routine` BY DESIGN — that case is
        // carried by the breadth-and-persistence rule, not by the radius — so the
        // crossing pair is the widest one the model can express.
        XCTAssertEqual(risk(.clipboardRead, oneApp, .once), .routine)
        XCTAssertEqual(risk(.clipboardRead, oneApp, eightHours), .routine)
        XCTAssertEqual(risk(.clipboardRead, everywhere, eightHours), .elevated)
        XCTAssertEqual(
            risk(.screenObserve, everywhere, eightHours),
            .high,
            "reading the screen of every application for eight hours is a high-blast-radius grant",
        )
        // And an unsigned caller on a listed application moves a narrow grant up two
        // classes, which is what makes signature quality and the operator's own list two
        // of the six factors rather than two decorations.
        XCTAssertEqual(
            AuthorizationPolicy.blastRadius(
                capability: .clipboardRead, scope: oneApp, duration: eightHours,
                remainingCount: nil, targetIsHighConsequence: true,
                signatureQuality: SignatureState.unsigned.quality,
            ).riskClass,
            .high,
        )
    }

    /// Each option states the friction IT costs, so the prompt can show the numbers beside
    /// the choice rather than asking the operator to guess which one needs a fingerprint.
    func testEachOfferedOptionCarriesItsOwnRadiusAndCeremony() {
        let decision = decide(
            request(.clipboardRead, scope: AuthorizationScope()),
        )
        let options = decision.offeredDecisions
        guard let once = options.first(where: { $0.kind == .allowOnce }),
              let always = options.first(where: { $0.kind == .allowGlobalPersistent })
        else {
            return XCTFail("a global clipboard read must offer once and always")
        }
        XCTAssertGreaterThan(always.blastRadius.radius, once.blastRadius.radius)
        XCTAssertEqual(once.biometric, .notRequired)
        XCTAssertEqual(
            always.biometric,
            .required(reason: "a standing permission over every application until you revoke it"),
        )
    }

    // MARK: B3 — one scope, one ceremony, whatever the option is called

    /// The policy used to be keyed on the option's NAME, so `.allowSession` handed out a
    /// grant with the same global scope and the same eight hours as
    /// `.allowGlobalPersistent` and asked for no ceremony. Two labels for one scope is a
    /// policy that can be defeated by choosing the other label.
    func testTwoOptionsWithOneScopeCostTheSameCeremony() {
        let options = AuthorizationPolicy.offeredDecisions(
            for: request(.clipboardRead, scope: AuthorizationScope()),
            posture: .balanced,
            riskClass: .routine,
        )
        guard let session = options.first(where: { $0.kind == .allowSession }),
              let always = options.first(where: { $0.kind == .allowGlobalPersistent })
        else {
            return XCTFail("expected both a session and a global option")
        }
        XCTAssertEqual(session.scope, always.scope, "the two differ only in name")
        XCTAssertEqual(session.duration, always.duration)
        XCTAssertEqual(session.biometric, always.biometric)
    }

    // MARK: B4 — an unresolved caller inherits nothing

    /// `isFullyResolved` had no reader anywhere. An unresolved caller was allowed by a
    /// standing grant, which is the opposite of failing closed. It is still not DENIED —
    /// refusing every caller whose path could not be read would be verification-as-a-gate,
    /// which this product rejects — so it escalates to a prompt instead.
    func testAnUnresolvedCallerInheritsNoGrantAndEscalates() {
        let unresolved = peerIdentity(isFullyResolved: false)
        let granted = decide(
            request(.clipboardRead),
            identity: unresolved,
            grants: [grant(.clipboardRead)],
        )
        XCTAssertEqual(
            granted.basis,
            .promptRequired,
            "an unresolved caller was allowed by a standing grant",
        )
        guard case .required = granted.biometric else {
            return XCTFail("an unresolved caller must not pass without friction")
        }
    }

    // MARK: B5 — the biometric-availability test was vacuous

    /// Every denial hardcoded `biometric: .notRequired`, so the original loop's
    /// `if case .required` guard never matched and not one assertion in it ran. The
    /// invariant held by construction; the suite was not checking it. This version
    /// asserts the DENIAL REASON directly, which cannot be skipped.
    func testAnUnavailableBiometricDeniesExactlyTheDecisionsThatNeedOne() {
        let noBiometric = AuthorizationContext.unixSocket(
            biometric: .unavailable(reason: "locked out"),
        )
        var ceremonyDenied = 0
        var ceremonyNotDenied = 0
        for capability in consentCapabilities {
            for scope in [
                AuthorizationScope(),
                AuthorizationScope(application: .bundleIdentifier("com.apple.TextEdit")),
            ] {
                let decision = decide(
                    request(capability, scope: scope),
                    context: noBiometric,
                )
                // Classified from the POLICY, not from the decision's own offers. A denial
                // for a missing ceremony returns no offers at all — correctly, since there
                // is then nothing for the operator to act on — so reading them back to
                // decide which branch to take asserted nothing. Twice.
                let needsCeremony = AuthorizationPolicy.offeredDecisions(
                    for: request(capability, scope: scope),
                    posture: .balanced,
                    riskClass: .routine,
                ).contains { $0.isDefault && $0.biometric.isRequired }
                if needsCeremony {
                    ceremonyDenied += 1
                    XCTAssertEqual(
                        decision.denialReason,
                        .biometricUnavailable,
                        "\(capability.rawValue) needed a ceremony that cannot run",
                    )
                    XCTAssertTrue(
                        decision.biometric.isRequired,
                        "a refusal for a missing ceremony must still REPORT that one was needed",
                    )
                } else {
                    ceremonyNotDenied += 1
                    XCTAssertEqual(
                        decision.basis,
                        .promptRequired,
                        "\\(capability.rawValue) does not need a ceremony, so a broken sensor is irrelevant",
                    )
                }
            }
        }
        XCTAssertGreaterThan(ceremonyDenied, 0, "no case in this table needs a ceremony, so the test is vacuous")
        XCTAssertGreaterThan(ceremonyNotDenied, 0)
    }

    // MARK: B6 — saturating arithmetic that actually saturates

    func testAdvancedBySaturatesInsteadOfTrapping() {
        XCTAssertEqual(
            MonotonicInstant(nanoseconds: 0).advanced(by: .seconds(Int64.max)).nanoseconds,
            UInt64.max,
        )
        XCTAssertEqual(
            MonotonicInstant(nanoseconds: UInt64.max).advanced(by: .seconds(86400)).nanoseconds,
            UInt64.max,
        )
        XCTAssertEqual(
            MonotonicInstant(nanoseconds: 1000).advanced(by: .seconds(2)).nanoseconds,
            2_000_001_000,
        )
    }

    // MARK: Follow-ups the review confirmed as real

    /// A declared count below one is malformed, and it must not satisfy another malformed
    /// count — `0 >= 0` used to be enough — nor be scored as five times safer than an
    /// unbounded request.
    func testAMalformedOperationCountIsNeitherSatisfiableNorSafe() {
        let malformed = AuthorizationScope(operationLimit: 0)
        XCTAssertFalse(malformed.isSatisfiableOperationCount)
        XCTAssertFalse(
            malformed.covers(AuthorizationScope(operationLimit: 0)),
            "a zero-operation request satisfied a zero-operation grant",
        )
        XCTAssertGreaterThanOrEqual(
            AuthorizationPolicy.remainingCountFactor(0),
            AuthorizationPolicy.remainingCountFactor(nil),
            "a malformed count must not look safer than an unbounded one",
        )
    }

    /// A grant that names a bundle is only satisfied by the same bundle at the same path.
    /// It used to fall back to the path alone whenever either side lacked a bundle.
    func testABundleBindingIsNotSatisfiedByABareBinaryAtTheSamePath() {
        let bound = CodeBinding(
            executablePath: "/tmp/exactmac",
            bundleIdentifier: "io.github.joeycumines.exactmac",
            designatedRequirement: nil,
        )
        let bare = CodeIdentity(
            executablePath: "/tmp/exactmac",
            bundleIdentifier: nil,
            designatedRequirement: nil,
            signature: .unsigned,
        )
        XCTAssertFalse(bound.isSatisfied(by: bare))
        XCTAssertTrue(bound.isSatisfied(by: CodeIdentity(
            executablePath: "/tmp/exactmac",
            bundleIdentifier: "io.github.joeycumines.exactmac",
            designatedRequirement: nil,
            signature: .unsigned,
        )))
    }

    /// An empty designated requirement is not a requirement, and must not compare equal to
    /// another empty one as though it were.
    func testAnEmptyDesignatedRequirementIsTreatedAsNoRequirement() {
        let identity = CodeIdentity(
            executablePath: "/tmp/x",
            bundleIdentifier: nil,
            designatedRequirement: "",
            signature: .signedAndValid,
        )
        XCTAssertNil(identity.binding.designatedRequirement)
    }

    /// An unexplained request is one the operator should decline, so a MISSING reason is a
    /// different prompt rather than a shorter one — and it escalates rather than quietly
    /// being treated as routine.
    func testAMissingReasonEscalatesAndAnUnknownOriginEscalates() {
        let explained = decide(request(.clipboardRead, scope: AuthorizationScope(
            application: .bundleIdentifier("com.apple.TextEdit"),
        )))
        let unexplained = decide(request(
            .clipboardRead,
            scope: AuthorizationScope(application: .bundleIdentifier("com.apple.TextEdit")),
            reason: nil,
        ))
        let blank = decide(request(
            .clipboardRead,
            scope: AuthorizationScope(application: .bundleIdentifier("com.apple.TextEdit")),
            reason: "   ",
        ))
        let unattributed = decide(request(
            .clipboardRead,
            scope: AuthorizationScope(application: .bundleIdentifier("com.apple.TextEdit")),
            origin: .unknown,
        ))
        XCTAssertEqual(explained.biometric, .notRequired)
        for (label, decision) in [
            ("no reason", unexplained), ("blank reason", blank), ("unknown origin", unattributed),
        ] {
            guard case .required = decision.biometric else {
                XCTFail("\(label) did not escalate")
                continue
            }
        }
    }

    /// The pre-authorization option is offered only when there is an application to scope
    /// the batch to, because a batch over "every application" is exactly the global scope
    /// `envelopeIsAdmissible` refuses.
    func testTheEnvelopeOptionIsOnlyOfferedWhenItCanBeScoped() {
        let targeted = AuthorizationPolicy.offeredDecisions(
            for: request(
                .clipboardRead,
                scope: AuthorizationScope(application: .bundleIdentifier("com.apple.TextEdit")),
            ),
            posture: .balanced,
            riskClass: .routine,
        )
        let global = AuthorizationPolicy.offeredDecisions(
            for: request(.clipboardRead, scope: AuthorizationScope()),
            posture: .balanced,
            riskClass: .routine,
        )
        XCTAssertTrue(targeted.contains { $0.kind == .preAuthorizeEnvelope })
        XCTAssertFalse(global.contains { $0.kind == .preAuthorizeEnvelope })
        // And it is destructive, because it authorises unattended future capability.
        XCTAssertTrue(
            targeted.first { $0.kind == .preAuthorizeEnvelope }?.isDestructive ?? false,
        )
    }
}

/// The second review's findings, each pinned.
final class AuthorizationPolicySecondReviewRegressionTests: XCTestCase {
    private let now = MonotonicInstant(nanoseconds: 1_000_000_000_000)

    private func instant(offsetSeconds: Int) -> MonotonicInstant {
        let base = Int64(bitPattern: now.nanoseconds)
        return MonotonicInstant(
            nanoseconds: UInt64(bitPattern: base &+ (Int64(offsetSeconds) &* 1_000_000_000)),
        )
    }

    private func peerIdentity(
        signature: SignatureState = .adHoc,
        path: String = "/usr/local/bin/exactmac",
        bundleIdentifier: String? = "io.github.joeycumines.exactmac",
        requirement: String? = "identifier \"io.github.joeycumines.exactmac\" and anchor apple generic",
    ) -> CallerIdentity {
        CallerIdentity(
            processIdentifier: 4517,
            effectiveUserIdentifier: 501,
            parentProcessIdentifier: 4490,
            code: CodeIdentity(
                executablePath: path,
                bundleIdentifier: bundleIdentifier,
                designatedRequirement: requirement,
                signature: signature,
            ),
            isFullyResolved: true,
        )
    }

    private func request(
        _ capability: Capability,
        scope: AuthorizationScope = AuthorizationScope(),
    ) -> AuthorizationRequest {
        AuthorizationRequest(
            id: AuthorizationRequestID(rawValue: "req-1"),
            rpcName: "exactmac.v1.ExactMac/Test",
            capability: capability,
            scope: scope,
            argumentSummary: "a representative argument",
            agentReason: "because the test says so",
            origin: .directSocket,
        )
    }

    /// N1: a negative duration is zero. It used to saturate to UInt64.max, which is a
    /// grant that never expires — the fail-open direction, in the function issuance calls
    /// on values read back from a store.
    func testANegativeDurationIsZeroAndNeverProducesANeverExpiringGrant() {
        XCTAssertEqual(MonotonicInstant(nanoseconds: 1000).advanced(by: .seconds(-1)).nanoseconds, 1000)
        XCTAssertEqual(
            MonotonicInstant(nanoseconds: 1000).advanced(by: .seconds(-10_000_000_000)).nanoseconds,
            1000,
        )
        XCTAssertEqual(
            MonotonicInstant(nanoseconds: 1000).advanced(by: .seconds(Int64.min)).nanoseconds,
            1000,
        )
    }

    /// F2: the eight-hour ceiling is enforced against the REMAINING LIFETIME, because
    /// `expiresAt` is what authorises. It was checked against `declaredDuration`, so an
    /// envelope declaring one second and living for eight hours passed the only gate.
    func testTheEnvelopeCeilingIsEnforcedAgainstTheRemainingLifetime() {
        let oneApp = AuthorizationScope(application: .bundleIdentifier("com.apple.TextEdit"))
        let shortButLongLived = PreAuthorizationEnvelope(
            id: "env-mismatch",
            grants: [Grant(
                id: "env-mismatch-grant",
                capability: .clipboardRead,
                scope: oneApp,
                duration: .monotonicSeconds(1),
                holder: peerIdentity().code.binding,
                issuedAt: now,
                expiresAt: instant(offsetSeconds: AuthorizationPolicy.maximumEnvelopeSeconds),
                origin: .envelope(id: "env-mismatch"),
                remainingOperations: nil,
                targetIsHighConsequence: false,
            )],
            declaredDuration: .monotonicSeconds(1),
            expiresAt: instant(offsetSeconds: AuthorizationPolicy.maximumEnvelopeSeconds),
            holder: peerIdentity().code.binding,
        )
        XCTAssertFalse(
            AuthorizationPolicy.envelopeIsAdmissible(shortButLongLived, now: now),
            "an envelope declaring one second and living for eight hours passed the gate",
        )
    }

    /// F10: a hard denial must not report a radius that varies with the operator's PRIVATE
    /// high-consequence list, because that is a side channel on a path taken before the
    /// target is consulted.
    func testADenialDoesNotLeakTheOperatorsHighConsequenceList() {
        let listed = AuthorizationContext.unixSocket(
            isConsoleReachable: false,
            highConsequenceTargets: ["com.apple.TextEdit"],
        )
        let unlisted = AuthorizationContext.unixSocket(isConsoleReachable: false)
        let oneApp = AuthorizationScope(application: .bundleIdentifier("com.apple.TextEdit"))
        let listedDecision = AuthorizationPolicy.evaluate(
            request: request(.clipboardRead, scope: oneApp),
            identity: peerIdentity(), grants: [], envelopes: [], posture: .balanced,
            context: listed, now: now,
        )
        let unlistedDecision = AuthorizationPolicy.evaluate(
            request: request(.clipboardRead, scope: oneApp),
            identity: peerIdentity(), grants: [], envelopes: [], posture: .balanced,
            context: unlisted, now: now,
        )
        XCTAssertEqual(listedDecision.denialReason, .consoleUnreachable)
        XCTAssertEqual(
            listedDecision.blastRadius,
            unlistedDecision.blastRadius,
            "two identical requests differed only by the operator's private list",
        )
    }

    /// F4: a pid-scoped request cannot be matched against a list of bundle identifiers, and
    /// the old answer was a silent `false` — an unmatchable target skipping an escalation
    /// on the strength of being unmatchable.
    func testAPidScopedRequestEscalatesWhenTheOperatorHasListedAnything() {
        let pidScope = AuthorizationScope(application: .processIdentifier(4211))
        XCTAssertTrue(
            AuthorizationPolicy.isHighConsequence(
                "com.apple.TextEdit", for: pidScope, anyTargetsListed: true,
            ),
        )
        XCTAssertFalse(
            AuthorizationPolicy.isHighConsequence(
                "com.apple.TextEdit", for: pidScope, anyTargetsListed: false,
            ),
        )
        let withList = AuthorizationContext.unixSocket(
            highConsequenceTargets: ["com.apple.TextEdit"],
        )
        let decision = AuthorizationPolicy.evaluate(
            request: request(.clipboardRead, scope: pidScope),
            identity: peerIdentity(), grants: [], envelopes: [], posture: .balanced,
            context: withList, now: now,
        )
        guard case .required = decision.biometric else {
            return XCTFail("a pid-scoped request against a listed operator's list must escalate")
        }
    }

    /// N3: the breadth-and-persistence rule is about the APPLICATION axis. It used to key
    /// on a three-way conjunction, so adding a window or an operation count switched it off
    /// while the grant still covered every application.
    func testBreadthAndPersistenceCannotBeSwitchedOffByANarrowingLever() {
        let stillEveryApplication: [AuthorizationScope] = [
            AuthorizationScope(),
            AuthorizationScope(window: .identifier("window-1")),
            AuthorizationScope(operationLimit: 3),
            AuthorizationScope(window: .identifier("window-1"), operationLimit: 3),
        ]
        for scope in stillEveryApplication {
            XCTAssertTrue(
                scope.application.isGlobal,
                "the fixture drifted: this scope is no longer every application",
            )
            guard case .required = AuthorizationPolicy.biometricRequirement(
                capability: .clipboardRead,
                scope: scope,
                duration: .monotonicSeconds(AuthorizationPolicy.maximumEnvelopeSeconds),
            ) else {
                XCTFail("an 8-hour grant over every application escaped the ceremony rule: \(scope)")
                continue
            }
        }
    }

    /// N7: the review was right that `testEveryRiskClassIsReachable` alone does not pin
    /// the duration factor, because an unsigned high-consequence shell reaches the high
    /// class on capability alone. This one does.
    func testTheDurationFactorIsLoadBearingForTheRiskClass() {
        func risk(_ scope: AuthorizationScope, _ duration: GrantDuration) -> RiskClass {
            AuthorizationPolicy.blastRadius(
                capability: .clipboardRead, scope: scope, duration: duration,
                remainingCount: nil, targetIsHighConsequence: false,
                signatureQuality: SignatureState.signedAndValid.quality,
            ).riskClass
        }
        let everywhere = AuthorizationScope()
        XCTAssertEqual(risk(everywhere, .once), .routine)
        XCTAssertEqual(risk(everywhere, .monotonicSeconds(900)), .routine)
        XCTAssertEqual(
            risk(everywhere, .monotonicSeconds(AuthorizationPolicy.maximumEnvelopeSeconds)),
            .elevated,
            "a PINNED constant duration factor would make this routine, which is the B2 defect",
        )
    }

    /// N5: the conformance is real, not aspirational.
    func testOfferedDecisionsConformToHashable() {
        let options = AuthorizationPolicy.offeredDecisions(
            for: request(.clipboardRead, scope: AuthorizationScope(
                application: .bundleIdentifier("com.apple.TextEdit"),
            )),
            posture: .balanced,
            riskClass: .routine,
        )
        XCTAssertEqual(Set(options).count, options.count, "two options compared equal")
        var tally: [OfferedDecision: Int] = [:]
        for option in options {
            tally[option, default: 0] += 1
        }
        XCTAssertEqual(tally.count, options.count)
    }
}
