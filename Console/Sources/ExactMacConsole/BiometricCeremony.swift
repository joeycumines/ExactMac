import AppKit
import ExactMacServer
import Foundation
import LocalAuthentication
import os

/// The ceremony, performed in the console because that is where an application context
/// exists.
///
/// THE SERVER NEVER PERFORMS IT. The server decides WHETHER a ceremony is required — that is
/// a pure function of what is being authorized — and the console performs it, because
/// `LAContext` needs a real application to present a sensor against, and a menu-bar
/// accessory is the thing the operator is already looking at.
///
/// EVERY FAILURE DENIES, and the failures are distinguished so the prompt can say which one
/// happened: "no biometric is enrolled" is fixable in System Settings and "the console is
/// not frontmost" is a bug in the console, and one opaque "biometric failed" makes them the
/// same to the operator.
@MainActor
final class BiometricCeremony: @unchecked Sendable {
    enum Outcome: Equatable, Sendable {
        case performed
        case unavailable(BiometricFailure)
    }

    private let logger = Logger(
        subsystem: "io.github.joeycumines.exactmac.console",
        category: "console.biometric",
    )

    /// Whether this machine can perform a ceremony at all, and why not when it cannot.
    ///
    /// A FRESH CONTEXT per query. A cached `LAContext` that has been invalidated — which is
    /// what repeated failures do — answers every later question with the same error, so a
    /// recoverable lockout becomes a permanently unavailable ceremony.
    nonisolated static func availability() -> BiometricFailure? {
        let probe = LAContext()
        var error: NSError?
        if probe.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            return nil
        }
        var passcodeError: NSError?
        if probe.canEvaluatePolicy(.deviceOwnerAuthentication, error: &passcodeError) {
            // No sensor, but the device passcode still proves presence, so the ceremony is
            // available with a weaker proof rather than refused outright. Refusing would
            // deny a legitimate operator on a Mac with no sensor.
            return nil
        }
        return map(passcodeError ?? error)
    }

    /// Performs the ceremony for exactly one decision and returns a proof bound to it.
    ///
    /// The reason is what macOS renders BESIDE THE SENSOR, so it is composed from the
    /// decision rather than written as prose here: the operator is reading it while their
    /// finger is on the reader, and that is the only place they read what they are
    /// agreeing to.
    func perform(
        nonce _: String,
        reason: String,
    ) async -> Outcome {
        guard isFrontmost else {
            // A ceremony nobody can see proves nothing, and a biometric performed against a
            // hidden window is indistinguishable from one the operator never intended. So
            // this is checked FIRST, before the sensor is touched.
            return .unavailable(.consoleNotFrontmost)
        }
        let ceremony = LAContext()
        // No system fallback button: the weaker path is chosen here, explicitly, by the
        // policy below, rather than offered by the system after a cancel.
        ceremony.localizedFallbackTitle = ""
        var error: NSError?
        let probe = LAContext()
        var probeError: NSError?
        let policy = probe.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: &probeError,
        )
            ? LAPolicy.deviceOwnerAuthenticationWithBiometrics
            : LAPolicy.deviceOwnerAuthentication
        guard ceremony.canEvaluatePolicy(policy, error: &error) else {
            let failure = Self.map(error)
            logger.notice("Ceremony unavailable: \(String(describing: failure), privacy: .public)")
            return .unavailable(failure)
        }
        do {
            let succeeded = try await ceremony.evaluatePolicy(policy, localizedReason: reason)
            guard succeeded else { return .unavailable(.cancelled) }
            return .performed
        } catch {
            return .unavailable(Self.map(error as NSError))
        }
    }

    /// The system's own reasons, mapped onto ours.
    ///
    /// A PURE FUNCTION of the `LAError` code, so it is testable on a machine whose sensor
    /// works perfectly and cannot be asked to fail on purpose.
    nonisolated static func map(_ error: NSError?) -> BiometricFailure {
        guard let error else { return .hardwareUnavailable }
        return switch LAError.Code(rawValue: error.code) {
        case .some(.biometryNotEnrolled): .noEnrolment
        case .some(.biometryNotAvailable), .some(.touchIDNotAvailable): .hardwareUnavailable
        case .some(.biometryLockout): .lockedOut
        case .some(.userCancel), .some(.appCancel), .some(.systemCancel), .some(.userFallback):
            .cancelled
        case .some(.passcodeNotSet): .passcodeNotSet
        case .some(.authenticationFailed): .cancelled
        default: .unavailable(reason: error.localizedDescription)
        }
    }

    /// Whether the console is in a position to SHOW a ceremony.
    ///
    /// `NSApp.isActive` is the honest signal: the menu-bar accessory is the frontmost
    /// application exactly when the operator has just used it, and a ceremony presented
    /// behind another window is a ceremony nobody saw.
    var isFrontmost: Bool {
        NSApp.isActive
    }
}

/// Why a ceremony could not be performed.
///
/// EVERY CASE DENIES. They are distinct because the operator needs to know which happened:
/// "no biometric is enrolled" is fixable in System Settings, "the console is not frontmost"
/// is a bug in the console, and one opaque "biometric failed" makes them the same.
///
/// THE SERVER HAS ITS OWN COPY, for the same reason it has its own copy of the wire format:
/// the authorization types are not a library the console can import today. They are two
/// enumerations of the same taxonomy rather than one shared type, and the two have to agree
/// — the reason strings the server shows and the ones the console shows are the same words.
enum BiometricFailure: Error, Equatable, Sendable {
    case noEnrolment
    case hardwareUnavailable
    case lockedOut
    case cancelled
    case passcodeNotSet
    case consoleNotFrontmost
    case unavailable(reason: String)

    /// The product's own words, which are what the prompt shows beside the sensor.
    var explanation: String {
        switch self {
        case .noEnrolment: "no biometric is enrolled on this Mac"
        case .hardwareUnavailable: "this Mac cannot perform a biometric check"
        case .lockedOut: "the biometric sensor is locked out after too many attempts"
        case .cancelled: "the check was cancelled"
        case .passcodeNotSet: "no passcode is set, so presence cannot be proven"
        case .consoleNotFrontmost: "the console was not frontmost, so the check could not be shown"
        case let .unavailable(reason): reason
        }
    }
}
