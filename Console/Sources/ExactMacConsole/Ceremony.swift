import Foundation

/// The ceremony the server decided is required, behind a protocol.
///
/// THE PROTOCOL IS WHAT MAKES A DECISION TESTABLE WITHOUT A SENSOR. The whole suite must run
/// unattended, and `LAContext` cannot be made to succeed on a machine with no enrolled
/// biometric — so a test that could only reach the real ceremony could only ever prove the
/// DENIAL path, which is the half that was never at risk. The production implementation is
/// `BiometricCeremony`; a test supplies an outcome and asserts that the decision it produced
/// is the one that was posted, which is the property that matters and the one that was
/// untested.
///
/// The failure taxonomy is the console's existing `BiometricFailure` and not a second one:
/// two taxonomies would let the prompt name a case the ceremony never produces.
@MainActor
protocol CeremonyPerforming: AnyObject {
    func perform(
        nonce: String,
        reason: String,
    ) async -> BiometricCeremony.Outcome
}

extension BiometricCeremony: CeremonyPerforming {}

/// The sentence macOS renders BESIDE THE SENSOR.
///
/// A PURE FUNCTION of the request, the option and the outcome, for two reasons. The operator
/// reads it while their finger is on the reader, which is the only moment they read what
/// they are agreeing to; and because it is pure it can be asserted without a human, which is
/// the only way it can be asserted at all. A string composed at the call site would be
/// unassertable prose, and unassertable prose in front of a biometric sensor is exactly the
/// place a vague sentence does damage.
enum CeremonyReason {
    /// What the option permits, in the words the operator is agreeing to.
    static func compose(
        request: PendingRequest,
        option: OptionRow.Kind,
        failure: BiometricFailure? = nil,
    ) -> String {
        let permits = switch option {
        case .deny: "deny this request"
        case .once: "allow this one request for \(request.scopeDescription)"
        case .target: "allow \(request.scopeDescription) until you revoke it"
        case .session: "allow every app this agent touches until ExactMac quits"
        case .envelope: "pre-authorize a declared batch for up to 8 hours"
        case .global: "allow every app, every time, until you revoke it"
        }
        let asked = "ExactMac asks to \(permits)"
        let caller = "\(request.executablePath) called \(request.rpcName)"
        guard let failure else { return "\(caller). \(asked)." }
        return "\(caller). \(asked). It did not happen: \(failure.explanation)."
    }
}
