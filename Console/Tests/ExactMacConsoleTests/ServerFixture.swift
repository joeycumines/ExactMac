@testable import ExactMacServer
import Foundation

/// Test fixtures built from the SERVER'S OWN TYPES.
///
/// IT REPLACED FIXTURES BUILT FROM THE DUPLICATED WIRE SHAPES, and that is the substantive
/// change rather than a tidiness one. The old fixtures constructed `WireRequest`,
/// `WireIdentity` and `WireDecision` — a second copy of the server's types that existed
/// only to cross a socket — and then handed them to `PendingRequest.init(consent:)`. So
/// every test in this package exercised a mapping that production no longer performs, and
/// the mapping from the engine's real decision to the operator's prompt had no test at all.
/// It is the most security-relevant translation in the app: it decides what the operator is
/// shown and therefore what they are agreeing to.
///
/// Building the real types means a fixture that cannot contain a wire-shaped string, and a
/// test that fails if the engine's own vocabulary drifts from what the prompt renders.
enum ServerFixture {
    /// A consent-requiring request, its caller, and the decision that offers the operator a
    /// choice. Returned as the three values the server hands the app, in the same order.
    static func request(
        requestID: String = "req-1",
        capability: Capability = .clipboardRead,
        rpcName: String = "exactmac.v1.ExactMac/GetClipboard",
        argumentSummary: String = "the clipboard and its history",
        agentReason: String? = "answering a question about what you copied",
        operationLimit: Int? = nil,
        offeredKinds: [OfferedDecision.Kind]? = nil,
        perOptionBiometric: [OfferedDecision.Kind: Bool]? = nil,
    ) -> (AuthorizationRequest, CallerIdentity, AuthorizationDecision) {
        (
            AuthorizationRequest(
                id: AuthorizationRequestID(rawValue: requestID),
                rpcName: rpcName,
                capability: capability,
                scope: AuthorizationScope(
                    application: .any,
                    window: .any,
                    operationLimit: operationLimit,
                ),
                argumentSummary: argumentSummary,
                agentReason: agentReason,
                origin: .directSocket,
            ),
            identity(),
            decision(
                offered: offeredKinds ?? [.allowOnce, .allowTargetApplication, .allowSession, .deny],
                perOptionBiometric: perOptionBiometric,
            ),
        )
    }

    /// The caller, with a parent in the chain so the tree the prompt draws is not a single
    /// row — a tree with one entry cannot show that ancestry is walked at all.
    static func identity(
        processIdentifier: Int32 = 4242,
        executablePath: String = "/usr/local/bin/exactmac",
        bundleIdentifier: String? = "io.github.joeycumines.exactmac",
        signature: SignatureState = .signedUnnotarized,
        isFullyResolved: Bool = true,
        isAncestryTruncated: Bool = false,
        ancestors: [ResolvedProcess] = [
            ResolvedProcess(
                processIdentifier: 4200,
                parentProcessIdentifier: nil,
                code: CodeIdentity(
                    executablePath: "/bin/zsh",
                    bundleIdentifier: nil,
                    designatedRequirement: nil,
                    signature: .signedAndValid,
                ),
                isFullyResolved: true,
            ),
        ],
    ) -> CallerIdentity {
        CallerIdentity(
            processIdentifier: processIdentifier,
            effectiveUserIdentifier: 501,
            parentProcessIdentifier: nil,
            code: CodeIdentity(
                executablePath: executablePath,
                bundleIdentifier: bundleIdentifier,
                designatedRequirement: nil,
                signature: signature,
            ),
            isFullyResolved: isFullyResolved,
            ancestors: ancestors,
            isAncestryTruncated: isAncestryTruncated,
        )
    }

    /// The decision, offering Deny plus whatever the caller asks for.
    static func decision(
        requiresBiometric: Bool = false,
        // NIL BY DEFAULT, and that is deliberate: an empty reason is what makes the
        // prompt's own fallback sentence reachable. A fixture that always supplies a reason
        // cannot test the case where the engine required a ceremony without saying why.
        biometricReason: String? = nil,
        riskClass: RiskClass = .elevated,
        offered: [OfferedDecision.Kind] = [.allowOnce, .allowTargetApplication, .allowSession, .deny],
        /// WHICH OPTIONS COST A CEREMONY, per option — the engine attaches the requirement
        /// to the option, not to the request, so the fixture does too. Nil means "the
        /// request-level requirement applies to every option", which is the shape most
        /// existing callers expect.
        perOptionBiometric: [OfferedDecision.Kind: Bool]? = nil,
    ) -> AuthorizationDecision {
        AuthorizationDecision(
            outcome: .deny,
            basis: .promptRequired,
            effectiveCapabilities: [.clipboardRead],
            blastRadius: BlastRadius(
                capability: 0.4,
                breadth: 0.4,
                duration: 0.3,
                remainingCount: 0,
                targetConsequence: 0.3,
                signatureQuality: 0.2,
            ),
            riskClass: riskClass,
            biometric: requiresBiometric
                ? .required(reason: biometricReason ?? "")
                : .notRequired,
            offeredDecisions: offered.map { kind in
                // THE PER-OPTION FLAGS ARE SET THE WAY THE ENGINE SETS THEM, rather than
                // defaulted: `isPrimary` marks the one the design puts beside the confirm
                // button and `isDestructive` keeps the global grant out of the default
                // position. A fixture that got these wrong would render a prompt whose
                // emphasis does not match the decision, and the test would pass anyway.
                let isDestructive = kind == .allowGlobalPersistent
                return OfferedDecision(
                    kind: kind,
                    scope: AuthorizationScope(
                        application: kind == .allowTargetApplication
                            ? .bundleIdentifier("TextEdit")
                            : .any,
                        window: .any,
                        // The session option carries a count and the once option does not,
                        // so the two compose to different sentences. A fixture where every
                        // option reads the same cannot tell "the prompt names each option's
                        // scope" from "the prompt names the scope it happened to read
                        // first", which is the bug the composition exists to prevent.
                        operationLimit: kind == .allowSession ? 8 : nil,
                    ),
                    duration: kind == .deny ? .once : .monotonicSeconds(3600),
                    blastRadius: BlastRadius(
                        capability: 0.4,
                        breadth: 0.4,
                        duration: 0.3,
                        remainingCount: 0,
                        targetConsequence: 0.3,
                        signatureQuality: 0.2,
                    ),
                    biometric: {
                        // An explicit per-option entry wins; WITHOUT one, every option
                        // inherits the request-level requirement, which is what the old
                        // fixture expressed and what most callers still expect.
                        if let perOption = perOptionBiometric, let perOptionEntry = perOption[kind] {
                            return perOptionEntry
                                ? .required(reason: biometricReason ?? "the option you chose")
                                : .notRequired
                        }
                        return requiresBiometric
                            ? .required(reason: biometricReason ?? "") : .notRequired
                    }(),
                    isDestructive: isDestructive,
                    isDefault: kind == .allowSession,
                    isPrimary: kind == .allowOnce,
                )
            },
            expiresAt: nil,
        )
    }
}
