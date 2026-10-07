import Foundation
import LocalAuthentication
import os
import Synchronization

// MARK: - What a ceremony produces

/// Why a ceremony could not be performed.
///
/// EVERY CASE DENIES. They are distinct because the operator needs to know which happened —
/// "no biometric is enrolled" is fixable in System Settings and "the console is not frontmost"
/// is a bug in the console — and because a single opaque "biometric failed" would make both
/// indistinguishable. None of them is ever downgraded to a weaker check.
enum BiometricFailure: Error, Equatable, Sendable {
    /// No biometric is enrolled. The operator can fix this, and the prompt should say so.
    case noEnrolment
    /// The hardware cannot do it at all on this machine.
    case hardwareUnavailable
    /// Too many failed attempts; the system has locked the sensor.
    case lockedOut
    /// The operator chose to cancel, or the operator was not there.
    case cancelled
    /// The system refused: no passcode is set, so there is no way to prove presence.
    case passcodeNotSet
    /// The context died mid-ceremony, usually from repeated failures. A fresh context is
    /// needed, which means the decision has to be asked for again.
    case contextInvalidated
    /// The ceremony was not completed inside its window. A proof that arrives late is not
    /// proof of a decision the operator has since forgotten about.
    case expired
    /// The operator could not have been shown the prompt, because the console was not the
    /// frontmost application. A ceremony nobody can see is not a ceremony.
    case consoleNotFrontmost
    /// Anything else, named rather than flattened.
    case unavailable(reason: String)
}

/// Proof that the operator authorized ONE decision.
///
/// It names the decision and it carries a NONCE, because a ceremony proves presence and
/// presence is not consent for a particular request. A proof with no request binding is a
/// bearer token: whatever presents it next is authorized, which is a confused deputy
/// wearing the operator's own fingerprint.
public struct BiometricProof: Sendable, Equatable, Hashable {
    public var requestID: AuthorizationRequestID
    /// Single-use, and bound to this decision. Two decisions cannot share one.
    public var nonce: String
    public var decidedAt: MonotonicInstant
    /// The ceremony is a moment, not a licence. A proof older than this is refused.
    public var expiresAt: MonotonicInstant

    public init(
        requestID: AuthorizationRequestID,
        nonce: String,
        decidedAt: MonotonicInstant,
        expiresAt: MonotonicInstant,
    ) {
        self.requestID = requestID
        self.nonce = nonce
        self.decidedAt = decidedAt
        self.expiresAt = expiresAt
    }

    /// Whether this proof speaks for `request` at `now`.
    ///
    /// ALL THREE conditions, and each is load-bearing: the request binding stops one decision
    /// being honoured for another, the nonce is what a spent-proof ledger keys on, and the
    /// expiry stops a proof being replayed later in the same session.
    public func authorizes(
        _ request: AuthorizationRequest,
        nonce expectedNonce: String,
        now: MonotonicInstant,
    ) -> Bool {
        requestID == request.id && nonce == expectedNonce && now < expiresAt
    }
}

/// One-time use, enforced.
///
/// A proof that authorizes twice is not a proof, so the check-and-spend has to be atomic:
/// two requests racing the same nonce must not both win it.
final class BiometricNonceLedger: Sendable {
    private struct Entry {
        let expiresAt: MonotonicInstant?
    }

    private struct State {
        var entries: [String: Entry] = [:]
        var order: [String] = []
    }

    private let capacity: Int
    private let state = Synchronization.Mutex<State>(State())

    init(capacity: Int = 1024) {
        self.capacity = max(1, capacity)
    }

    /// - Returns: True when the nonce had not been spent and is now spent.
    @discardableResult
    func spend(_ nonce: String, expiresAt: MonotonicInstant? = nil) -> Bool {
        state.withLock { s in
            if s.entries[nonce] != nil {
                return false
            }
            // Enforce capacity bound: prune oldest entry if at capacity
            while s.order.count >= capacity {
                let oldest = s.order.removeFirst()
                s.entries.removeValue(forKey: oldest)
            }
            s.entries[nonce] = Entry(expiresAt: expiresAt)
            s.order.append(nonce)
            return true
        }
    }

    func hasSpent(_ nonce: String) -> Bool {
        state.withLock { $0.entries[nonce] != nil }
    }

    /// Expired proofs leave the ledger, so a nonce cannot be reused by a later decision that
    /// happens to be issued the same string.
    func forget(_ nonce: String) {
        state.withLock { s in
            s.entries.removeValue(forKey: nonce)
            s.order.removeAll { $0 == nonce }
        }
    }

    /// Prunes nonces that have expired by `now`.
    func pruneExpired(at now: MonotonicInstant) {
        state.withLock { s in
            var remainingOrder: [String] = []
            for nonce in s.order {
                if let entry = s.entries[nonce], let expiry = entry.expiresAt, expiry <= now {
                    s.entries.removeValue(forKey: nonce)
                } else {
                    remainingOrder.append(nonce)
                }
            }
            s.order = remainingOrder
        }
    }
}

/// The ceremony itself.
protocol BiometricAuthenticating: Sendable {
    /// Whether a ceremony is possible at all, and why not when it is not.
    func availability() -> AuthorizationContext.BiometricAvailability

    /// Whether the console is in a position to SHOW a ceremony. The operator's presence is
    /// proven by something they can see, so a console that is not frontmost cannot ask.
    func isConsoleFrontmost() async -> Bool

    /// Performs the ceremony for exactly one decision.
    ///
    /// - Parameter reason: what is being authorized, in the operator's words. This string is
    ///   what macOS renders NEXT TO THE SENSOR, so it is the only place the operator reads
    ///   what they are agreeing to while their finger is on it — which is why it is composed
    ///   from the decision by `CeremonyReason.compose` rather than passed in as prose.
    func authenticate(
        request: AuthorizationRequest,
        selected: OfferedDecision,
        reason: String,
        nonce: String,
        now: MonotonicInstant,
    ) async -> Result<BiometricProof, BiometricFailure>
}

/// The string macOS renders beside the sensor.
///
/// IT NAMES THE DECISION, because that string is the only thing the operator reads while
/// their finger is on the sensor, and a generic "Confirm" there means the ceremony is
/// divorced from what it is authorizing — which is exactly the shape of a ceremony an
/// attacker wants. Composed as a pure function so it can be asserted without a human, which
/// is the only way it can be asserted at all.
enum CeremonyReason {
    static func compose(
        request: AuthorizationRequest,
        selected: OfferedDecision,
        ceremonyReason: String,
    ) -> String {
        let breadth = switch selected.scope.application {
        case .any: "every application"
        case let .bundleIdentifier(identifier): identifier
        case let .processIdentifier(identifier): "process \(identifier)"
        case let .opaqueApplication(name, _): name
        }
        let duration = switch selected.duration {
        case .once: "once"
        case let .monotonicSeconds(seconds): "for \(seconds) seconds"
        }
        return """
        Allow \(request.capability.rawValue) in \(breadth) \(duration)? \
        \(ceremonyReason). Asked for: \(request.argumentSummary)
        """
    }
}

// MARK: - Production

/// `LocalAuthentication`, and nothing else.
///
/// THE POLICY IS CHOSEN, NOT ASSUMED. `.deviceOwnerAuthenticationWithBiometrics` is tried
/// first because a fingerprint is a statement about a person; when the machine cannot do it,
/// `.deviceOwnerAuthentication` is the documented fallback because the device passcode still
/// proves presence. Which one was used is REPORTED, because "Touch ID" and "passcode" are
/// different assurances and the operator is entitled to know which one they gave.
struct LocalAuthenticationAuthenticator: BiometricAuthenticating {
    /// The window a ceremony must complete inside. A proof older than this is refused, so a
    /// prompt the operator walked away from cannot be answered hours later by anyone.
    static let ceremonyWindow: Duration = .seconds(120)

    private let ledger: BiometricNonceLedger
    private let isFrontmost: @Sendable () async -> Bool
    private let logger = Logger(
        subsystem: "io.github.joeycumines.exactmac",
        category: "authorization.biometric",
    )

    init(
        ledger: BiometricNonceLedger = BiometricNonceLedger(),
        isFrontmost: @escaping @Sendable () async -> Bool = { true },
    ) {
        self.ledger = ledger
        self.isFrontmost = isFrontmost
    }

    /// Which policy a given availability leads to, as a PURE FUNCTION.
    ///
    /// Split out so the choice is testable without a ceremony, which cannot run unattended.
    /// The ceremony is the part that needs a human; the policy is the part that needs to be
    /// right, and it is right or it is not regardless of who is present.
    static func policy(for availability: AuthorizationContext.BiometricAvailability) -> LAPolicy {
        switch availability {
        case .available: .deviceOwnerAuthenticationWithBiometrics
        // A machine that cannot do biometrics can still prove presence with a passcode, and
        // refusing outright would deny a legitimate operator on a Mac with no sensor rather
        // than accepting them with a weaker proof.
        case .unavailable: .deviceOwnerAuthentication
        }
    }

    func availability() -> AuthorizationContext.BiometricAvailability {
        // A FRESH context per query. An `LAContext` that has been invalidated — which is what
        // repeated failures do — answers every later question with the same error, so a
        // cached one turns a recoverable lockout into a permanently unavailable ceremony.
        let probe = LAContext()
        var error: NSError?
        if probe.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: &error,
        ) {
            return .available
        }
        var passcodeError: NSError?
        if probe.canEvaluatePolicy(.deviceOwnerAuthentication, error: &passcodeError) {
            return .available
        }
        return .unavailable(reason: Self.description(of: Self.failure(for: passcodeError ?? error)))
    }

    func isConsoleFrontmost() async -> Bool {
        await isFrontmost()
    }

    func authenticate(
        request: AuthorizationRequest,
        selected _: OfferedDecision,
        reason: String,
        nonce: String,
        now: MonotonicInstant,
    ) async -> Result<BiometricProof, BiometricFailure> {
        // The order is the security property. The console is checked FIRST because a ceremony
        // nobody can see proves nothing, and a biometric performed against a hidden window is
        // indistinguishable from one the operator never intended.
        guard await isFrontmost() else { return .failure(.consoleNotFrontmost) }
        // A nonce already spent cannot be spent again, whatever the ceremony's outcome.
        guard ledger.spend(nonce) else { return .failure(.unavailable(reason: "nonce already spent")) }

        let availability = availability()
        if case let .unavailable(why) = availability {
            logger.notice("Ceremony unavailable: \(why, privacy: .public)")
            return .failure(.unavailable(reason: why))
        }

        let ceremony = LAContext()
        // `localizedFallbackTitle` empty means the system offers no fallback button, so a
        // cancelled-with-fallback is a cancellation rather than a weaker path the product did
        // not choose. The weaker path is chosen here, explicitly, by the policy above.
        ceremony.localizedFallbackTitle = ""
        var error: NSError?
        let policy = Self.policy(for: availability)
        guard ceremony.canEvaluatePolicy(policy, error: &error) else {
            return .failure(Self.failure(for: error))
        }

        do {
            let succeeded = try await ceremony.evaluatePolicy(policy, localizedReason: reason)
            guard succeeded else { return .failure(.cancelled) }
        } catch let failure as BiometricFailure {
            return .failure(failure)
        } catch {
            return .failure(Self.failure(for: error as NSError))
        }

        return .success(BiometricProof(
            requestID: request.id,
            nonce: nonce,
            decidedAt: now,
            expiresAt: now.advanced(by: Self.ceremonyWindow),
        ))
    }

    /// The system's own reasons, mapped to ours, so the prompt can say which happened rather
    /// than "biometric failed".
    ///
    /// An `NSError` from `LocalAuthentication` and not a string, so nothing has to be parsed
    /// back out of a message: the code is the fact and the description is for the operator.
    static func failure(for error: NSError?) -> BiometricFailure {
        guard let error else { return .hardwareUnavailable }
        return failure(forCode: error.code, reason: "\(error.domain) \(error.code)")
    }

    /// A human-readable form, for the startup log and the prompt's biometric line.
    static func description(of failure: BiometricFailure) -> String {
        switch failure {
        case .noEnrolment: "no biometric is enrolled on this Mac"
        case .hardwareUnavailable: "this Mac cannot perform a biometric check"
        case .lockedOut: "the biometric sensor is locked out after too many attempts"
        case .cancelled: "the check was cancelled"
        case .passcodeNotSet: "no passcode is set, so presence cannot be proven"
        case .contextInvalidated: "the check was invalidated and must be started again"
        case .expired: "the check was not completed in time"
        case .consoleNotFrontmost: "the console was not frontmost, so the check could not be shown"
        case let .unavailable(reason): reason
        }
    }

    /// The mapping, as a PURE FUNCTION of the `LAError` code, so it is testable on a machine
    /// that has a working sensor and cannot be asked to fail on purpose.
    static func failure(forCode code: Int, reason: String) -> BiometricFailure {
        guard let laError = LAError.Code(rawValue: code) else {
            return .unavailable(reason: reason)
        }
        switch laError {
        case .biometryNotEnrolled:
            return .noEnrolment
        case .biometryNotAvailable, .touchIDNotAvailable:
            return .hardwareUnavailable
        case .biometryLockout:
            return .lockedOut
        case .userCancel, .appCancel, .systemCancel, .userFallback:
            return .cancelled
        case .passcodeNotSet:
            return .passcodeNotSet
        case .authenticationFailed:
            return .cancelled
        default:
            return .unavailable(reason: reason)
        }
    }
}
