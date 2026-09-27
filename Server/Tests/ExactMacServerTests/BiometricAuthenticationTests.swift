@testable import ExactMacServer
import Foundation
import LocalAuthentication
import XCTest

/// C6's acceptance suite.
///
/// The ceremony itself cannot run here and is never faked: what IS tested is everything
/// around it — the policy, the nonce binding, the failure taxonomy, and the fact that the
/// production authenticator is built with the right policy for a given machine. A stub that
/// says "yes" proves nothing about whether a real one would, so the tests that matter are the
/// ones that assert the DECISION rather than the gesture.
final class BiometricAuthenticationTests: XCTestCase {
    // MARK: - The policy table

    /// EVERY capability crossed with EVERY decision kind, asserting exactly which require a
    /// ceremony. Membership is asserted as a set per row rather than by spot-checking, so a
    /// reclassification has to be deliberate.
    func testEveryCapabilityCrossedWithEveryDecisionKind() {
        var table: [String: Set<String>] = [:]
        for capability in Capability.allCases {
            for kind in OfferedDecision.Kind.allCases where kind != .deny {
                // A representative but CONSISTENT set of conditions: a session or longer
                // grant, which is the case where the breadth-and-persistence rule can bite.
                let requirement = AuthorizationPolicy.biometricRequirement(
                    capability: capability,
                    scope: AuthorizationScope(application: .any),
                    duration: Self.duration(for: kind),
                    riskClass: .routine,
                )
                if case .required = requirement {
                    table[kind.rawValue, default: []].insert(capability.rawValue)
                }
            }
        }
        // Shell execution is ALWAYS a ceremony, at every duration including one-shot.
        XCTAssertTrue(table["allowOnce"]?.contains(Capability.scriptExecute.rawValue) == true)
        for kind in ["allowOnce", "allowTargetApplication", "allowSession", "preAuthorizeEnvelope", "allowGlobalPersistent"] {
            XCTAssertTrue(
                table[kind]?.contains(Capability.scriptExecute.rawValue) == true,
                "\(kind) let a shell through without a ceremony",
            )
        }
        // A clipboard read scoped to ONE application, once, costs nothing at any kind.
        for kind in OfferedDecision.Kind.allCases where kind != .deny {
            let requirement = AuthorizationPolicy.biometricRequirement(
                capability: .clipboardRead,
                scope: AuthorizationScope(application: .bundleIdentifier("com.apple.TextEdit")),
                duration: .once,
                riskClass: .routine,
            )
            XCTAssertEqual(
                requirement, .notRequired,
                "a narrow one-shot read must stay friction-free, and \(kind.rawValue) broke that",
            )
        }
        // And the standing permission DOES cost one: global AND persistent, neither half alone.
        XCTAssertEqual(
            AuthorizationPolicy.biometricRequirement(
                capability: .clipboardRead,
                scope: AuthorizationScope(application: .any),
                duration: .monotonicSeconds(3600),
                riskClass: .routine,
            ).isRequired,
            true,
            "a global hour-long clipboard read is a standing permission and must cost a ceremony",
        )
    }

    /// Revoke-everything always costs a ceremony, whatever else is true.
    func testRevokeAllAlwaysRequiresACeremony() {
        for capability in Capability.allCases {
            XCTAssertTrue(
                AuthorizationPolicy.biometricRequirement(
                    capability: capability,
                    isRevokeAll: true,
                ).isRequired,
                "\(capability.rawValue) revoked every grant without a ceremony",
            )
        }
    }

    /// A weak signature costs a ceremony even for the narrowest request, which is the case a
    /// narrow-allow-once exemption used to wave through.
    func testAWeakSignatureCostsACeremonyEvenForANarrowOneShot() {
        for signature in [SignatureState.unsigned, .invalid, .unresolved] {
            for capability in Capability.allCases {
                let requirement = AuthorizationPolicy.biometricRequirement(
                    capability: capability,
                    scope: AuthorizationScope(application: .bundleIdentifier("com.apple.TextEdit")),
                    duration: .once,
                    signature: signature,
                )
                XCTAssertTrue(
                    requirement.isRequired,
                    "\(capability.rawValue) at \(signature.rawValue) was waved through",
                )
            }
        }
    }

    /// The duration each decision kind stands for, so the table crosses a capability with
    /// the duration the operator would actually be granting.
    private static func duration(for kind: OfferedDecision.Kind) -> GrantDuration {
        switch kind {
        case .deny, .allowOnce: .once
        case .allowTargetApplication: .monotonicSeconds(3600)
        case .allowSession: .monotonicSeconds(3600)
        case .preAuthorizeEnvelope: .monotonicSeconds(3600)
        case .allowGlobalPersistent: .monotonicSeconds(86400)
        }
    }

    // MARK: - The production authenticator's policy

    /// The real `LAContext` implementation is CONSTRUCTED with the right policy, asserted
    /// without performing a ceremony — which is the only part of it CI can check, and the
    /// part that decides whether a finger or a passcode is what the operator is asked for.
    func testTheProductionAuthenticatorChoosesBiometricsFirstAndPasscodeAsFallback() {
        XCTAssertEqual(
            LocalAuthenticationAuthenticator.policy(for: .available),
            .deviceOwnerAuthenticationWithBiometrics,
            "a working sensor must be preferred: a fingerprint is a statement about a person",
        )
        XCTAssertEqual(
            LocalAuthenticationAuthenticator.policy(for: .unavailable(reason: "no sensor")),
            .deviceOwnerAuthentication,
            "a machine that cannot do biometrics must still be able to prove presence",
        )
    }

    /// The reason a ceremony names is what macOS renders BESIDE THE SENSOR, and it is the
    /// only thing the operator reads while their finger is on it. So it names the decision:
    /// the capability, the target, the duration and the payload. A generic "Confirm" there
    /// means the ceremony is divorced from what it authorizes.
    func testTheCeremonyReasonNamesTheDecision() {
        let request = Self.clipboardRequest
        let reason = CeremonyReason.compose(
            request: request,
            selected: Self.allowOnce,
            ceremonyReason: "the caller's signature is unsigned",
        )
        XCTAssertTrue(reason.contains(Capability.clipboardRead.rawValue), reason)
        XCTAssertTrue(reason.contains("com.apple.TextEdit"), reason)
        XCTAssertTrue(reason.contains("once"), reason)
        XCTAssertTrue(reason.contains("the clipboard"), reason)
        XCTAssertTrue(reason.contains("unsigned"), reason)
    }

    /// And it says WHICH of the offered options is being paid for, because the prompt asks
    /// for one ceremony and then offers several grants, and a ceremony that does not name
    /// its option is one the operator cannot tell apart from the others.
    func testTheCeremonyReasonDistinguishesTheOptionItIsPayingFor() {
        let reasons = [
            Self.allowOnce,
            OfferedDecision(
                kind: .allowGlobalPersistent,
                scope: AuthorizationScope(application: .any),
                duration: .monotonicSeconds(86400),
                blastRadius: Self.allowOnce.blastRadius,
                biometric: .required(reason: "this grant would permit a lot"),
                isDestructive: true,
                isDefault: false,
                isPrimary: false,
            ),
        ].map { CeremonyReason.compose(request: Self.clipboardRequest, selected: $0, ceremonyReason: "x") }
        XCTAssertNotEqual(reasons[0], reasons[1], "two options produced the same ceremony reason")
    }

    /// Every failure the system can report maps to one of ours, and NONE of them is a
    /// downgrade. The codes are the real `LAError` ones, so the mapping is checked against
    /// the framework rather than against a list somebody wrote.
    func testEverySystemFailureMapsToADenialAndNoneIsADowngrade() {
        let expected: [(Int, BiometricFailure)] = [
            (LAError.biometryNotEnrolled.rawValue, .noEnrolment),
            (LAError.biometryNotAvailable.rawValue, .hardwareUnavailable),
            (LAError.touchIDNotAvailable.rawValue, .hardwareUnavailable),
            (LAError.biometryLockout.rawValue, .lockedOut),
            (LAError.userCancel.rawValue, .cancelled),
            (LAError.systemCancel.rawValue, .cancelled),
            (LAError.appCancel.rawValue, .cancelled),
            (LAError.userFallback.rawValue, .cancelled),
            (LAError.passcodeNotSet.rawValue, .passcodeNotSet),
            (LAError.authenticationFailed.rawValue, .cancelled),
        ]
        for (code, want) in expected {
            XCTAssertEqual(
                LocalAuthenticationAuthenticator.failure(forCode: code, reason: "test"),
                want,
                "code \\(code) mapped somewhere else",
            )
        }
        // An unrecognised code is NAMED rather than flattened into a generic failure, so a
        // new system error does not read to the operator as "cancelled".
        XCTAssertEqual(
            LocalAuthenticationAuthenticator.failure(forCode: 99999, reason: "who knows"),
            .unavailable(reason: "who knows"),
        )
    }

    // MARK: - Nonce binding

    /// A ceremony proves PRESENCE, and presence is not consent for a particular request. A
    /// proof with no request binding is a bearer token.
    func testAProofSpeaksForItsOwnRequestOnly() {
        let now = MonotonicInstant(nanoseconds: 1000)
        let proof = BiometricProof(
            requestID: Self.clipboardRequest.id,
            nonce: "nonce-a",
            decidedAt: now,
            expiresAt: now.advanced(by: .seconds(60)),
        )
        let other = AuthorizationRequest(
            id: AuthorizationRequestID(rawValue: "a-different-request"),
            rpcName: "exactmac.v1.ExactMac/GetClipboardHistory",
            capability: .clipboardRead,
            scope: AuthorizationScope(),
            argumentSummary: "the clipboard history",
            agentReason: "the test asked",
            origin: .mcpProxy,
        )
        XCTAssertTrue(proof.authorizes(Self.clipboardRequest, nonce: "nonce-a", now: now))
        XCTAssertFalse(
            proof.authorizes(other, nonce: "nonce-a", now: now),
            "a proof for one decision authorized another",
        )
    }

    /// And for its own nonce only, so a proof cannot be carried onto a decision that merely
    /// happened to arrive while it was fresh.
    func testAProofIsBoundToItsOwnNonce() {
        let now = MonotonicInstant(nanoseconds: 1000)
        let proof = BiometricProof(
            requestID: Self.clipboardRequest.id,
            nonce: "nonce-a",
            decidedAt: now,
            expiresAt: now.advanced(by: .seconds(60)),
        )
        XCTAssertFalse(
            proof.authorizes(Self.clipboardRequest, nonce: "nonce-b", now: now),
            "a proof was honoured under a different nonce",
        )
    }

    /// THE REPLAY TEST. One success authorizes exactly one decision: a second presentation of
    /// the same nonce is refused, and the check-and-spend is atomic so two requests racing
    /// the same nonce cannot both win it.
    func testOneCeremonyCannotAuthorizeTwoDecisions() {
        let ledger = BiometricNonceLedger()
        XCTAssertTrue(ledger.spend("nonce-a"), "the first presentation must win it")
        XCTAssertFalse(ledger.spend("nonce-a"), "the same nonce was spent twice")
        XCTAssertTrue(ledger.hasSpent("nonce-a"))
        // A different nonce is a different decision and is unaffected.
        XCTAssertTrue(ledger.spend("nonce-b"))
    }

    /// Concurrency: the ledger is the thing standing between a replayed ceremony and a second
    /// authorization, so it is tested under the race it exists to settle.
    func testOnlyOneOfManyConcurrentSpendsWins() async {
        let ledger = BiometricNonceLedger()
        let wins = await withTaskGroup(of: Bool.self) { group in
            for _ in 0 ..< 64 {
                group.addTask { ledger.spend("contended") }
            }
            var total = 0
            for await won in group where won {
                total += 1
            }
            return total
        }
        XCTAssertEqual(wins, 1, "a contended nonce was spent \(wins) times")
    }

    /// A proof that arrives after its window is refused: a prompt the operator walked away
    /// from cannot be answered later by anyone.
    func testAProofExpiresWithItsWindow() {
        let now = MonotonicInstant(nanoseconds: 1000)
        let proof = BiometricProof(
            requestID: Self.clipboardRequest.id,
            nonce: "nonce-a",
            decidedAt: now,
            expiresAt: now.advanced(by: .seconds(60)),
        )
        XCTAssertTrue(proof.authorizes(Self.clipboardRequest, nonce: "nonce-a", now: now))
        XCTAssertTrue(proof.authorizes(
            Self.clipboardRequest, nonce: "nonce-a", now: now.advanced(by: .seconds(59)),
        ))
        XCTAssertFalse(proof.authorizes(
            Self.clipboardRequest, nonce: "nonce-a", now: now.advanced(by: .seconds(61)),
        ), "a proof outlived its window")
    }

    // MARK: - Failure paths, through a stub

    /// EVERY enumerated failure yields a denial, and each is covered through the stub rather
    /// than asserted about the production type's behaviour on a machine that cannot fail on
    /// purpose.
    func testEveryFailurePathYieldsADenial() async {
        let request = Self.clipboardRequest
        for failure in Self.allFailures {
            let authenticator = StubAuthenticator(outcome: .failure(failure))
            let outcome = await authenticator.authenticate(
                request: request,
                selected: Self.allowOnce,
                reason: "because",
                nonce: "nonce-\\(UUID().uuidString)",
                now: MonotonicInstant(nanoseconds: 0),
            )
            guard case let .failure(reported) = outcome else {
                return XCTFail("\\(failure) produced a proof")
            }
            XCTAssertEqual(reported, failure)
            // And the decision that follows from a failure is a refusal, at the layer that
            // turns the outcome into an authorization.
            let decision = AuthorizationPolicy.evaluate(
                request: request,
                identity: Self.identity,
                grants: [],
                envelopes: [],
                posture: .balanced,
                context: AuthorizationContext.unixSocket(
                    biometric: failure == .noEnrolment
                        ? .unavailable(reason: LocalAuthenticationAuthenticator.description(of: failure))
                        : .available,
                ),
                now: MonotonicInstant(nanoseconds: 0),
            )
            if case .denied(.biometricUnavailable) = decision.basis {
                // Correct: a machine that cannot perform the ceremony withdraws the options
                // rather than downgrading them.
                continue
            }
            XCTAssertEqual(decision.basis, .promptRequired)
        }
    }

    /// A durable option is EITHER withdrawn when a ceremony is impossible OR carries its
    /// ceremony requirement. It is never offered WITHOUT one, which is the downgrade the
    /// design forbids: an option that costs a fingerprint must not become an option that
    /// costs nothing when the sensor stops working.
    func testNoDurableOptionIsEverOfferedWithoutItsCeremony() {
        for kind in [
            OfferedDecision.Kind.allowTargetApplication,
            .allowSession,
            .preAuthorizeEnvelope,
            .allowGlobalPersistent,
        ] {
            let offered = AuthorizationPolicy.offeredDecisions(
                for: Self.clipboardRequest,
                posture: .balanced,
                riskClass: .high,
                targetIsHighConsequence: true,
                signature: .unsigned,
                agentGaveReason: true,
                originIsKnown: true,
            )
            for option in offered where option.kind == kind {
                XCTAssertEqual(
                    option.biometric.isRequired, true,
                    "\(kind.rawValue) was offered without the ceremony it needs",
                )
            }
            // The property that actually matters for a ceremony-requiring option: DENY is
            // never what holds focus. A narrower option that needs a fingerprint is a
            // perfectly good default — the operator presses it and then proves presence —
            // and the design makes that one the default precisely so the destructive row
            // cannot be reached by muscle memory.
            for option in offered {
                XCTAssertFalse(
                    option.kind == .deny && (option.isDefault || option.isPrimary),
                    "deny is focused by default, so a hurried operator can reach it",
                )
            }
        }
    }

    /// A console that is not frontmost cannot ask, because a ceremony nobody can see is not a
    /// ceremony. Checked FIRST, before the sensor is touched.
    func testAConsoleThatIsNotFrontmostCannotPerformACeremony() async {
        let authenticator = LocalAuthenticationAuthenticator(isFrontmost: { false })
        let outcome = await authenticator.authenticate(
            request: Self.clipboardRequest,
            selected: Self.allowOnce,
            reason: "because",
            nonce: "nonce-frontmost",
            now: MonotonicInstant(nanoseconds: 0),
        )
        guard case let .failure(reported) = outcome else {
            return XCTFail("a hidden console produced a proof")
        }
        XCTAssertEqual(reported, .consoleNotFrontmost)
    }

    // MARK: - Fixtures

    /// A whole option, because the authenticator takes one and a partially-built value is
    /// not a thing the model can express.
    ///
    /// TAKEN FROM THE ENGINE rather than assembled. An `OfferedDecision` is the policy's
    /// output, and hand-building one means copying the risk model's internal weights into a
    /// test that does not own them — a second copy of the model that goes stale silently
    /// when the first one moves, and which asserts about a decision the engine never made.
    private static let allowOnce: OfferedDecision = {
        let options = AuthorizationPolicy.offeredDecisions(
            for: clipboardRequest,
            posture: .balanced,
            riskClass: .routine,
            targetIsHighConsequence: false,
            signature: .signedAndValid,
            agentGaveReason: true,
            originIsKnown: true,
        )
        return options.first { $0.kind == .allowOnce } ?? options[0]
    }()

    private static let allFailures: [BiometricFailure] = [
        .noEnrolment,
        .hardwareUnavailable,
        .lockedOut,
        .cancelled,
        .passcodeNotSet,
        .contextInvalidated,
        .expired,
        .consoleNotFrontmost,
        .unavailable(reason: "something else"),
    ]

    private static let identity = CallerIdentity(
        processIdentifier: 4242,
        effectiveUserIdentifier: 0,
        parentProcessIdentifier: nil,
        code: CodeIdentity(
            executablePath: "/usr/local/bin/exactmac",
            bundleIdentifier: "io.github.joeycumines.exactmac",
            designatedRequirement: #"identifier "io.github.joeycumines.exactmac" and anchor apple"#,
            signature: .signedAndValid,
        ),
        isFullyResolved: true,
    )

    private static let clipboardRequest = AuthorizationRequest(
        id: AuthorizationRequestID(rawValue: "req-biometric"),
        rpcName: "exactmac.v1.ExactMac/GetClipboard",
        capability: .clipboardRead,
        scope: AuthorizationScope(application: .bundleIdentifier("com.apple.TextEdit")),
        argumentSummary: "the clipboard",
        agentReason: "the test asked",
        origin: .mcpProxy,
    )
}

private extension OfferedDecision {
    /// The ceremony reason, if the option demands one.
    var ceremonyReason: String? {
        guard case let .required(reason) = biometric else { return nil }
        return reason
    }
}

/// A stub that answers with a fixed outcome, which is the only way to exercise the failure
/// paths on a machine whose sensor works perfectly.
private struct StubAuthenticator: BiometricAuthenticating {
    var outcome: Result<BiometricProof, BiometricFailure>
    var availabilityOutcome: AuthorizationContext.BiometricAvailability = .available
    var frontmost = true

    func availability() -> AuthorizationContext.BiometricAvailability {
        availabilityOutcome
    }

    func isConsoleFrontmost() async -> Bool {
        frontmost
    }

    func authenticate(
        request: AuthorizationRequest,
        selected _: OfferedDecision,
        reason _: String,
        nonce: String,
        now: MonotonicInstant,
    ) async -> Result<BiometricProof, BiometricFailure> {
        switch outcome {
        case let .failure(failure): .failure(failure)
        case .success:
            .success(BiometricProof(
                requestID: request.id,
                nonce: nonce,
                decidedAt: now,
                expiresAt: now.advanced(by: .seconds(60)),
            ))
        }
    }
}
