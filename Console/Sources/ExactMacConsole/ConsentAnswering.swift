import Foundation

/// What the operator said, in the console's own vocabulary.
///
/// IT EXISTS SO THE ANSWER IS A VALUE BEFORE IT IS ANYTHING ELSE. The flow the app has to
/// perform — present, run the ceremony, decide — used to end in a side effect: a decision
/// was POSTED somewhere. That shape cannot serve a caller that wants the answer returned to
/// it, which is now the only shape there is, because the operator interface is hosted in
/// this process rather than reached over a socket. A function that returns the answer can be
/// posted by the old path and returned by the new one from the same implementation, so the
/// ceremony-ordering rule is written once instead of once per transport.
struct PendingAnswer: Sendable, Equatable {
    /// The request this answers, carried rather than implied.
    ///
    /// IT IS PART OF THE VALUE BECAUSE AN ANSWER IS ONLY AN ANSWER TO SOMETHING. A decision
    /// that could be applied to a different request than the operator was shown is the
    /// confused deputy in its narrowest form, and the cheapest place to prevent it is a type
    /// that cannot be constructed without saying which request it is for.
    let requestID: String
    let nonce: String
    let requestDigest: String
    /// The option the operator chose, or `.deny`. There is no "neither": the offered set is
    /// closed, and an unrecognised option becomes Deny rather than being dropped.
    let kind: OptionRow.Kind
    let note: String
    /// Only true when a ceremony was actually performed FOR THIS NONCE.
    let biometricObtained: Bool
    /// Why there is no approval, or nil when there is one.
    ///
    /// STORED RATHER THAN INFERRED FROM `biometricObtained`, which is what this did first and
    /// which was wrong. Inference cannot tell the two refusals apart: a denial the operator
    /// chose and a denial because the ceremony did not happen both arrive as
    /// `biometricObtained == false`, so a caller was told "the operator declined" for a
    /// request the operator had actually tried to approve. A caller that logs which happened
    /// — and a caller that retries one and not the other — needs them to be different values.
    let refusal: AnswerRefusal?

    /// Whether the operator approved. Derived from the option rather than stored, so the two
    /// cannot disagree — a `true` beside a `.deny` option would authorise nothing while
    /// claiming the operator said yes.
    var isApproved: Bool {
        kind != .deny
    }
}

/// Why there is no approval.
enum AnswerRefusal: Sendable, Equatable {
    /// The operator chose Deny.
    case operatorDeclined
    /// The operator chose to allow, the option required a biometric, and the ceremony did
    /// not happen — so the weaker path is not taken on their behalf.
    case ceremonyRefused
}

// MARK: - The seam the server calls

/// THE ONE THING THE APP STILL CANNOT BUILD, and exactly what it needs.
///
/// ## What exists on the server today
///
/// `ConsentAnswering`, `AuthorizationRequest`, `CallerIdentity`, `AuthorizationDecision` and
/// `ConsentAnswer` are all `public` TYPES, so this module can name them. Every MEMBER of
/// every one of them is `internal`, so this module can do nothing with them. Verified rather
/// than assumed: a probe declaring
///
/// ```swift
/// let handler: ConsentAnswering = { request, identity, decision in
///     let r = decision.riskClass   // error: 'riskClass' is inaccessible due to 'internal'
///     ...
/// }
/// ```
///
/// fails to compile at the first field read, and `ConsentAnswer(requestID:...)` is
/// unreachable for the same reason — the memberwise initialiser of a `public struct` with no
/// declared initialiser is `internal`.
///
/// `serve(config:transport:authorizationRuntime:listenerFactory:)` is also `internal`, and
/// takes an `internal` `AuthorizationRuntime`, so there is no way to hand the server a
/// consent handler even if one could be written. `ExactMacServer.main()` is public and
/// installs `consent: nil`.
///
/// ## What this file therefore does NOT contain
///
/// A `ConsentAnswering` closure. Writing one against members that are not visible, or against
/// a guessed signature, would be a fake the rest of this app gets built on — and the failure
/// would surface as a consent prompt that renders nothing, which is the worst possible place
/// to find out.
///
/// ## What the app is ready to hand over the moment it exists
///
/// ```swift
/// public typealias ConsentAnswering = @Sendable (
///     _ request: AuthorizationRequest,
///     _ identity: CallerIdentity,
///     _ decision: AuthorizationDecision,
/// ) async -> ConsentAnswer?
/// ```
///
/// and, on the read side, `public` members on the three request types; on the write side, a
/// `public` initialiser on `ConsentAnswer`. Plus an entry point that accepts the handler,
/// because `main()` cannot and `serve()` is not reachable:
///
/// ```swift
/// @MainActor
/// public func serveHosted(consent: ConsentAnswering?) async throws
/// ```
///
/// With those, this module's remaining work is a mapping from the server's request onto
/// `PendingRequest` and this file's answer back onto `ConsentAnswer` — both of which are
/// already written, in `PendingRequest` and in `PendingAnswer` respectively.
enum ConsentSeam {
    /// The absence of the host entry, as a sentence a log can carry.
    ///
    /// IT IS NAMED RATHER THAN LEFT IMPLICIT so the log says WHY a request is being denied
    /// instead of only that it was. "The operator interface could not be installed" and "the
    /// operator said no" look identical to a reader and are not the same event.
    static let unavailableReason =
        "the server exposes no public entry that accepts an in-process consent handler"

    /// Whether the app can present a consent request at all.
    ///
    /// FALSE UNTIL THE SEAM EXISTS, and it is the same fact `OperatorInterface` reports for
    /// the other reason a process cannot ask: there is no window, or there is no way to hand
    /// the question to the server that would show it. Both deny; they are different
    /// diagnoses and the log distinguishes them.
    static var canPresentConsent: Bool {
        false
    }
}
