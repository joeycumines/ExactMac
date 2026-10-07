@testable import ExactMacConsole
import Foundation
import LocalAuthentication
import Testing

/// The ceremony's failure mapping, and the two properties that matter about it.
///
/// The ceremony itself cannot run here and is never faked: it needs a human, a sensor and
/// a frontmost application. What CAN be proven without one is that every failure the system
/// can report maps onto one of ours, that the mapping is exact rather than flattened, and
/// that a decision which needs a ceremony cannot be reported as performed without one.
@Suite("The biometric ceremony")
@MainActor
struct BiometricCeremonyTests {
    @Test
    func `every LAError code we claim to handle maps to a distinct, named failure`() {
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
            (LAError.authenticationFailed.rawValue, .unavailable(reason: "authentication failed")),
        ]
        for (code, want) in expected {
            let error = NSError(domain: LAError.errorDomain, code: code)
            #expect(
                BiometricCeremony.map(error) == want,
                "code \(code) mapped elsewhere",
            )
        }
    }

    @Test
    func `an unrecognised code is NAMED rather than flattened into a cancellation`() {
        let error = NSError(
            domain: LAError.errorDomain,
            code: 99999,
            userInfo: [NSLocalizedDescriptionKey: "something new"],
        )
        guard case let .unavailable(reason) = BiometricCeremony.map(error) else {
            Issue.record("a new system error was flattened into a known failure")
            return
        }
        #expect(reason.contains("something new"), "\(reason)")
    }

    @Test
    func `no error at all is a hardware failure rather than a crash`() {
        #expect(BiometricCeremony.map(nil) == .hardwareUnavailable)
    }

    @Test
    func `every failure explains itself in the product's own words`() {
        let failures: [BiometricFailure] = [
            .noEnrolment, .hardwareUnavailable, .lockedOut, .cancelled,
            .passcodeNotSet, .consoleNotFrontmost, .unavailable(reason: "why"),
        ]
        for failure in failures {
            #expect(!failure.explanation.isEmpty, "\(failure) says nothing")
        }
        // The two that a confused operator would otherwise conflate must be distinguishable.
        let unenrolled = BiometricFailure.noEnrolment.explanation
        let hidden = BiometricFailure.consoleNotFrontmost.explanation
        #expect(
            unenrolled != hidden,
            "an unenrolled sensor and a hidden console read as the same problem",
        )
    }

    @Test
    func `this machine's availability is answerable without performing a ceremony`() {
        // Either it can, or it says which of the named reasons it cannot — and either answer
        // is a real one rather than a crash.
        if let failure = BiometricCeremony.availability() {
            #expect(!failure.explanation.isEmpty)
        }
    }
}
