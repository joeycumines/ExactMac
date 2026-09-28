@testable import ExactMacConsole
import Foundation
import Testing

/// The headed-versus-headless axis.
///
/// The property under test is the DIRECTION of every error: a process that cannot prove it
/// has somewhere to prompt a human is one that cannot prompt, and every unrecognised
/// input must land on the denying side. The axis is what the server's
/// `AuthorizationContext.Transport` is not — that one is a property of a listener's
/// principal, this one is a property of a process's ability to talk to a person — and a
/// Unix-socket listener running headless is exactly the case that would be silently
/// misclassified if the two were treated as one.
@Suite("Operating mode")
struct ServerHostingTests {
    // MARK: Classification

    @Test
    func `A bundle with a window server session can present consent`() {
        #expect(ServerHosting.classify(
            isApplicationBundle: true,
            hasWindowServerSession: true,
            environment: [:],
        ) == .application)
    }

    @Test
    func `A bundle with no window server session cannot present consent`() {
        // The logged-out `gui/<uid>` domain, `ssh`, and a CI runner all land here. A
        // request that arrives must be denied rather than queued for an operator who is
        // not there to answer it.
        #expect(ServerHosting.classify(
            isApplicationBundle: true,
            hasWindowServerSession: false,
            environment: [:],
        ) == .headless)
    }

    @Test
    func `A bare executable cannot present consent, whatever the session`() {
        // The standalone headless server's shape. A launchd job cannot fake this one: it
        // has no `CFBundleIdentifier` however it was started.
        #expect(ServerHosting.classify(
            isApplicationBundle: false,
            hasWindowServerSession: true,
            environment: [:],
        ) == .headless)
        #expect(ServerHosting.classify(
            isApplicationBundle: false,
            hasWindowServerSession: false,
            environment: [:],
        ) == .headless)
    }

    @Test
    func `Consent is obtainable in exactly one of the two modes`() {
        #expect(OperatorInterface.application.canObtainConsent)
        #expect(!OperatorInterface.headless.canObtainConsent)
    }

    // MARK: The override, and why it is not the default

    @Test
    func `The override forces the headless posture`() {
        for value in ["1", "true", "TRUE", "True"] {
            #expect(ServerHosting.classify(
                isApplicationBundle: true,
                hasWindowServerSession: true,
                environment: [ServerHosting.headlessOverrideKey: value],
            ) == .headless)
        }
    }

    @Test
    func `An unrecognised override is ignored rather than treated as headless`() {
        // A typo must not strip the operator interface off a running app. Guessing
        // headless on a misspelt variable would turn a consent-capable app into one that
        // silently denies everything, and the cause would be invisible.
        for value in ["", "0", "false", "yes", "headless", "1 "] {
            #expect(ServerHosting.classify(
                isApplicationBundle: true,
                hasWindowServerSession: true,
                environment: [ServerHosting.headlessOverrideKey: value],
            ) == .application, "override \(value.debugDescription) should not change the mode")
        }
    }

    @Test
    func `An unrelated environment does not change the mode`() {
        #expect(ServerHosting.classify(
            isApplicationBundle: true,
            hasWindowServerSession: true,
            environment: ["PATH": "/usr/bin", ServerHosting.headlessOverrideKey + "_X": "1"],
        ) == .application)
    }

    // MARK: The running process

    @Test
    func `This process reports the mode for what it actually is`() {
        // NOT a test of a literal. The suite runs as a bare executable under the test
        // runner, so it is not a bundle and the honest classification is `headless` — and
        // asserting that pins the fact that the classifier reads the real process rather
        // than a value handed to it. A machine running the suite inside a bundle would
        // legitimately disagree, so the assertion is on the CONSISTENCY of the two parts
        // instead of on the verdict.
        let expected: OperatorInterface = Bundle.main.bundleIdentifier == nil ? .headless : .application
        #expect(ServerHosting.isApplicationBundle == (expected == .application))
        #expect(ServerHosting.classify(
            isApplicationBundle: ServerHosting.isApplicationBundle,
            hasWindowServerSession: ServerHosting.hasWindowServerSession,
        ) == expected)
    }
}
