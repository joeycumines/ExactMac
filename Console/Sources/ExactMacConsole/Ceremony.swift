import ExactMacServer
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
    ///
    /// THE DURATIONS ARE THE OFFER'S OWN, never remembered strings. This sentence used to
    /// say "until you revoke it" for a grant that runs fifteen minutes and "until ExactMac
    /// quits" for one that runs eight hours — a lie the operator's fingerprint was
    /// endorsing, because the sensor prompt is what they are agreeing TO. Each duration is
    /// read from the offered option the server actually attached to this request; an option
    /// the offer does not carry falls back to the server's envelope ceiling, which is the
    /// widest any of these can run.
    static func compose(
        request: PendingRequest,
        option: OptionRow.Kind,
        failure: BiometricFailure? = nil,
    ) -> String {
        let permits = switch option {
        case .deny: "deny this request"
        case .once: "allow this one request for \(request.scopeDescription)"
        case .target: "allow \(request.scopeDescription) for \(duration(of: .target, in: request))"
        case .session: "allow every app this agent touches for \(duration(of: .session, in: request))"
        case .envelope: "pre-authorize these capabilities for up to \(duration(of: .envelope, in: request))"
        case .global: "allow every app, every time, for \(duration(of: .global, in: request))"
        }
        let asked = "ExactMac asks to \(permits)"
        // Strip internal rpcName to strictly satisfy Invariant 17:
        // No operator-facing string exposes an internal identifier or RPC name.
        let caller = "\(request.executablePath) requested access"
        guard let failure else { return "\(caller). \(asked)." }
        return "\(caller). \(asked). It did not happen: \(failure.explanation)."
    }

    /// The offered option's own duration in the operator's words, falling back to the
    /// server's envelope ceiling — the widest any grant can run — when the offer does not
    /// carry the option.
    private static func duration(of kind: OptionRow.Kind, in request: PendingRequest) -> String {
        if let offered = request.offered.first(where: { $0.kind == kind }),
           let seconds = offered.durationSeconds,
           seconds > 0
        {
            return PendingRequest.humanDuration(seconds)
        }
        return PendingRequest.humanDuration(ServerConfig.defaultMaximumEnvelopeSeconds)
    }
}
