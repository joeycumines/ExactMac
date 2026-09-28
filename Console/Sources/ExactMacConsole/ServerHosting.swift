import CoreGraphics
import Foundation
import os

/// The axis that separates the two ways ExactMac can run: an operator interface in this
/// process, or none.
///
/// ## What the axis actually IS
///
/// The product runs two ways and they differ in one fact: **can this process put a consent
/// prompt in front of the operator?** Everything else follows from that answer.
///
/// * `.application` — a bundle with a window server connection. It can order a window
///   front, run the biometric ceremony in front of the operator, and hold a request
///   open until they answer. A request that arrives here can be shown to a human.
/// * `.headless` — no operator interface. A request cannot be shown, so it cannot be
///   answered, so it must be DENIED. This is not degraded service; it is a server that
///   serves only the capabilities needing no consent.
///
/// ## Why this is a NAMED AXIS rather than prose
///
/// A correction worth recording, because the opposite is easy to assume: **there is no
/// headless capability in existence today to preserve.** Until this work, the only
/// deployment was a LaunchAgent in the `gui/<uid>` launchd domain, which dies at logout —
/// so "headless" was never a mode anything could run in, it was a word in a design
/// document. What the standalone server is, what it may serve without an operator, and
/// whether it may run at all in a session with no window server are therefore decisions
/// this axis MAKES rather than constraints it preserves. They are made conservatively:
/// unrecognised is unpromptable, and unpromptable denies.
///
/// ## Why it is not `AuthorizationContext.Transport`
///
/// On the server that axis is already taken and it means something narrower and
/// different: whether the LISTENER has an owning user to authenticate (`unixSocket`) or no
/// principal at all (`tcp`). That is a property of a socket. This is a property of a
/// process's ability to talk to a person. A Unix-socket listener running headless has a
/// principal and no way to ask it anything; a TCP listener in an app bundle has a window
/// and no principal. Collapsing them would let one property answer for the other.
enum OperatorInterface: Sendable, Equatable {
    /// This process can present the prompt. Consent is obtainable.
    case application
    /// This process cannot present the prompt, so every consent-requiring request is
    /// denied. It is a stated posture, not a fault, and it is the safe default.
    case headless

    /// Whether a consent request can be put to an operator at all.
    var canObtainConsent: Bool {
        self == .application
    }

    /// The one-line summary, for the log line written once at launch.
    var summary: String {
        switch self {
        case .application: "application: consent can be presented in this process"
        case .headless: "headless: no operator interface in this process, consent is denied"
        }
    }
}

/// Decides which of the two ways this process is running.
///
/// THE CLASSIFIER IS PURE AND ITS DEFAULT IS THE DENYING ONE. A process that cannot prove
/// it has a window to prompt in is treated as one that cannot prompt, because the failure
/// mode of guessing the other way is a consent prompt that never appears while the request
/// waits — an operator who never sees a prompt cannot consent to it, and a request that
/// expires unseen is a denial the operator did not know was asked for. Guessing "headless"
/// instead denies immediately and visibly, which is the recoverable direction.
enum ServerHosting {
    /// The override that forces the headless posture.
    ///
    /// IT EXISTS AS AN ENVIRONMENT VARIABLE rather than as a build flag because the
    /// question "does this build present consent or not" is a diagnostic an operator has to
    /// be able to answer about a binary they already have, at the moment they are looking
    /// at it, without a rebuild. An unrecognised or empty value is IGNORED rather than
    /// treated as a request for headless: a typo in a variable name must not silently
    /// strip the operator interface off a running app.
    static let headlessOverrideKey = "EXACTMAC_HEADLESS"

    /// - Parameters:
    ///   - isApplicationBundle: Whether this process was launched from an `.app` bundle.
    ///   - hasWindowServerSession: Whether there is a window server session this process
    ///     can put a window in.
    ///   - environment: Read for the headless override.
    static func classify(
        isApplicationBundle: Bool,
        hasWindowServerSession: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) -> OperatorInterface {
        if let override = environment[headlessOverrideKey],
           override.lowercased() == "1" || override.lowercased() == "true"
        {
            return .headless
        }
        // BOTH, NOT EITHER. An app bundle with no window server cannot order a window
        // front, and a window server session with no bundle is some other process that
        // happens to be looking at this one. Requiring both is what makes the
        // classification a claim about this process rather than an inference from context.
        guard isApplicationBundle, hasWindowServerSession else { return .headless }
        return .application
    }

    /// Whether this process is a bundle, which is the part of the answer that cannot be
    /// faked by a launchd job and the part a standalone binary can never satisfy.
    static var isApplicationBundle: Bool {
        // `bundleIdentifier` is nil for a bare executable launched directly, which is
        // precisely the standalone headless server's shape. Reading the bundle rather than
        // the executable path is deliberate: a bundle's executable can live anywhere.
        Bundle.main.bundleIdentifier != nil
    }

    /// Whether a window server session exists for this user.
    ///
    /// `CGSessionCopyCurrentDictionary` is the check, and it is nil for a process in a
    /// launchd domain with no GUI login — which is what a per-user daemon in the
    /// `gui/<uid>` domain of a logged-out session looks like, and also what `ssh` and a
    /// CI runner look like. Both are places a prompt could not be shown, which is the only
    /// fact being asked about.
    static var hasWindowServerSession: Bool {
        CGSessionCopyCurrentDictionary() != nil
    }

    /// The classification for the running process, and the one thing written at launch.
    static func current() -> OperatorInterface {
        classify(
            isApplicationBundle: isApplicationBundle,
            hasWindowServerSession: hasWindowServerSession,
        )
    }
}
