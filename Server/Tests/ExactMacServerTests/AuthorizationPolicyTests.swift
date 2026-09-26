import Foundation
@testable import ExactMacServer
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
        scope: AuthorizationScope = AuthorizationScope(),
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
        XCTAssertEqual(Capability.allCases.count, 16)
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
                if case .grant(let id) = live.basis {
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
        if case .required(let reason) = decision.biometric {
            XCTAssertTrue(reason.contains("unsigned"), "the reason must name the weakness")
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
        let inside = decide(
            request(.clipboardRead),
            envelopes: [envelope(.clipboardRead)],
        )
        XCTAssertEqual(inside.outcome, .allow)
        if case .envelope(let id) = inside.basis {
            XCTAssertEqual(id, "env-1")
        } else {
            XCTFail("allowed on the wrong basis: \(inside.basis)")
        }

        let outside = decide(
            request(.inputSynthesize),
            envelopes: [envelope(.clipboardRead)],
        )
        XCTAssertEqual(outside.basis, .promptRequired, "an envelope is not a blanket permission")

        let expired = decide(
            request(.clipboardRead),
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
        XCTAssertFalse(AuthorizationPolicy.envelopeIsAdmissible(global))

        let tooLong = envelope(.clipboardRead, durationSeconds: 9 * 60 * 60)
        XCTAssertFalse(AuthorizationPolicy.envelopeIsAdmissible(tooLong))

        let atCeiling = envelope(
            .clipboardRead,
            scope: AuthorizationScope(application: .bundleIdentifier("com.apple.TextEdit")),
            durationSeconds: AuthorizationPolicy.maximumEnvelopeSeconds,
        )
        XCTAssertTrue(AuthorizationPolicy.envelopeIsAdmissible(atCeiling))

        let empty = PreAuthorizationEnvelope(
            id: "env-empty",
            grants: [],
            declaredDuration: .monotonicSeconds(60),
            expiresAt: instant(offsetSeconds: 60),
            holder: peerIdentity().code.binding,
        )
        XCTAssertFalse(AuthorizationPolicy.envelopeIsAdmissible(empty))
    }

    // MARK: - The biometric table

    func testBiometricRequirementIsAPureFunctionOfWhatIsBeingAuthorised() {
        var required = 0
        var optional = 0
        for capability in Capability.allCases {
            for kind in OfferedDecision.Kind.allCases {
                for risk in RiskClass.allCases {
                    for signature in [SignatureState.signedAndValid, .unsigned] {
                        for high in [false, true] {
                            let requirement = AuthorizationPolicy.biometricRequirement(
                                capability: capability,
                                riskClass: risk,
                                targetIsHighConsequence: high,
                                signature: signature,
                                decisionKind: kind,
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
                            if capability == .scriptExecute, kind == .allowOnce,
                               risk == .routine, !high, signature == .signedAndValid {
                                XCTAssertEqual(
                                    requirement,
                                    .required(reason: "running a shell reaches everything this Mac can do"),
                                )
                            }
                            // The exemption itself, on a capability where it does apply.
                            if capability == .clipboardRead, kind == .allowOnce,
                               risk == .routine, !high, signature == .signedAndValid {
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
            // before the global-grant one, and that ordering is deliberate: the ceremony
            // should name the most dangerous thing being authorised.
            guard case .required(let reason) = AuthorizationPolicy.biometricRequirement(
                capability: capability,
                riskClass: .routine,
                targetIsHighConsequence: false,
                signature: .signedAndValid,
                decisionKind: .allowGlobalPersistent,
            ) else {
                XCTFail("\(capability.rawValue) allowed a global persistent grant with no ceremony")
                continue
            }
            XCTAssertFalse(reason.isEmpty, "\(capability.rawValue) must name what is being authorized")
        }
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
                    XCTAssertFalse(
                        defaults[0].isDestructive,
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
                    if offered.count >= 3,
                       let defaultIndex = offered.firstIndex(where: \.isDefault),
                       let denyIndex = offered.firstIndex(where: { $0.kind == .deny }),
                       let primaryIndex = offered.firstIndex(where: \.isPrimary) {
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

        let base = MonotonicInstant(nanoseconds: 1_000)
        XCTAssertEqual(base.remaining(until: MonotonicInstant(nanoseconds: 1_500)), .nanoseconds(500))
        XCTAssertNil(base.remaining(until: base), "a deadline in the past leaves nothing")
    }
}
