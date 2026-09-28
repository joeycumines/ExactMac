import Foundation
import os
import ServiceManagement

/// Start-at-login, owned by the application rather than by a hand-written plist.
///
/// WHY THIS EXISTS AND WHY IT IS NOT A LAUNCHAGENT. The product used to be installed by
/// writing `~/Library/LaunchAgents/com.exactmac.console.plist` and driving it with
/// `launchctl bootstrap`. That is retired: the app is one program now, it hosts the server
/// in its own process, and it registers ITSELF through `SMAppService.mainApp`. Three
/// properties make the platform's own registration the right mechanism rather than a
/// tidier version of the same idea:
///
/// * The registration is keyed to the CODE IDENTITY of the containing bundle, so a
///   rebuild that changes the signature does not silently inherit the operator's
///   approval of a different binary.
/// * It is visible and revocable in System Settings, which a plist in a dot-directory is
///   not — an operator can audit and undo it without knowing the repository exists.
/// * It requires the bundle to be code signed, and an ad-hoc signature satisfies that.
///   Verified on this machine, which has zero valid codesigning identities: a minimal
///   ad-hoc-signed bundle went from `notFound(3)` to `enabled(1)` on `register()`. Ad-hoc
///   is therefore the entire available signing posture here, not a fallback.
///
/// NOTE WHAT IS DELIBERATELY ABSENT: there is no embedded LaunchAgent plist under
/// `Contents/Library/LaunchAgents`. `SMAppService.agent(plistName:)` needs one, and
/// `SMAppService.mainApp` — the variant used here — must not have one. Shipping a
/// hand-written agent for an app that is meant to be self-registering is how both end up
/// installed at once, which is the orphan this type exists to prevent.
///
/// THE POLICY IS A PURE FUNCTION and the system call is a side effect behind it, so the
/// part that decides is assertable on a machine with no login items and no operator.
/// Asserting "register was called" would prove nothing; asserting "given a status, the
/// action is X" is the whole behaviour, including the two cases that are easy to get
/// wrong: registering something already registered, and asking for approval that only
/// the operator can give.
protocol LoginItemRegistering: Sendable {
    /// The current registration state, read fresh. `SMAppService.Status` has no
    /// `isEnabled`, so the enabled fact is the `.enabled` case itself and nothing else.
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

/// The production implementation, and the only place `SMAppService` is named.
///
/// IT STORES NOTHING. `SMAppService` is not `Sendable`, and an earlier version of this held
/// one and reached for `@unchecked Sendable`, which would have been a claim about
/// thread-safety nobody had checked. `SMAppService.mainApp` is a static factory that
/// returns a handle onto the same system state every time, so each call makes a fresh one
/// and there is no shared instance to be safe about. `Sendable` then holds by
/// construction rather than by assertion.
struct SystemLoginItem: LoginItemRegistering {
    init() {}

    var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}

/// What the app should do about start-at-login, and why.
enum LoginItemAction: Sendable, Equatable {
    /// Nothing to do: the registration already matches what the operator asked for.
    ///
    /// ITS OWN CASE RATHER THAN A REDUNDANT CALL, because `register()` on an
    /// already-registered service is a privileged round trip to `launchd` that can block
    /// and can fail for reasons that have nothing to do with the operator's intent. A
    /// toggle that is already in the requested state should do nothing, and being able to
    /// assert that it does nothing is worth more than being able to assert that it called
    /// a function.
    case none
    case register
    case unregister
    /// The registration exists but the operator has not approved it, and no call from
    /// inside this app can change that.
    ///
    /// IT IS A DISTINCT OUTCOME RATHER THAN A FAILURE BECAUSE IT IS NOT A FAULT. macOS
    /// holds this decision outside the app deliberately, so the honest response is to stop
    /// and say so, not to retry and not to report a start-at-login that will not happen.
    case operatorApprovalRequired
}

/// The start-at-login policy, as a pure function of the observed status and the request.
///
/// EVERY BRANCH IS WRITTEN OUT rather than derived, because the interesting cases are
/// exactly the ones a general rule gets wrong. `SMAppService.Status` has four cases and no
/// `disabled`: a registration that is present but unapproved is `.requiresApproval`, and
/// both "turn it on" and "turn it off" have something specific to say about it.
enum StartAtLoginPolicy {
    /// The action that moves the registration to `desired`, or reports why it cannot.
    ///
    /// - Parameters:
    ///   - status: The registration state as observed right now.
    ///   - desired: Whether the operator wants ExactMac to start at login.
    static func action(for status: SMAppService.Status, desired: Bool) -> LoginItemAction {
        switch (status, desired) {
        // Already in the requested state. The two arms that are the same for both
        // directions are the common case, because a menu bar app spends nearly all of its
        // life reconciled.
        case (.enabled, true), (.notRegistered, false), (.notFound, false):
            .none
        case (.notRegistered, true), (.notFound, true):
            .register
        case (.enabled, false):
            .unregister
        case (.requiresApproval, true):
            // Registering again cannot clear this. The entry is present; macOS is
            // withholding permission for it, and only the operator can grant it.
            .operatorApprovalRequired
        case (.requiresApproval, false):
            // The operator asked for it OFF, so the entry is removed even though it was
            // never fully on. Leaving a registered-but-unapproved login item behind is
            // the orphan state: it is invisible in the app, and it reappears as a
            // surprise the next time the operator changes their mind.
            .unregister
        @unknown default:
            // AN UNRECOGNISED STATUS IS TREATED AS "NOT REGISTERED AND NOT PERMITTED TO
            // ASK". A future case that means "enabled" would otherwise be read as
            // anything but, and the direction of that error is a start-at-login the
            // operator did not choose, or a registration that cannot be undone.
            desired ? .register : .none
        }
    }
}

/// Drives the registration and reports what actually happened.
///
/// IT IS NOT A PROPERTY OF THE MODEL AND IT IS NOT A FLAG FILE. Everything here is
/// answered by the system, and a bespoke `isEnabled` bool in a preferences file is a
/// second source of truth that disagrees with launchd the first time anything else
/// changes it.
@MainActor
final class StartAtLogin: ObservableObject {
    /// What the system currently reports. Published because the popover reads it, and
    /// because the state can change outside this app — an operator can revoke a login
    /// item in System Settings while the app is running, and a value cached at launch
    /// would keep claiming otherwise.
    @Published private(set) var status: SMAppService.Status
    /// Set when the last request could not be carried out, and cleared by the next one
    /// that can. Surfaced rather than logged only, because "I turned it on and it did not
    /// turn on" is the failure an operator cannot otherwise diagnose.
    @Published private(set) var lastRefusal: String?

    private let item: any LoginItemRegistering
    private let logger = Logger(
        subsystem: "io.github.joeycumines.exactmac.console",
        category: "start-at-login",
    )

    init(item: any LoginItemRegistering = SystemLoginItem()) {
        self.item = item
        status = item.status
    }

    /// The status, re-read rather than served from the last published value.
    func refresh() {
        status = item.status
    }

    /// Moves the registration to `enabled`, and returns the state it ended in.
    ///
    /// IT REPORTS RATHER THAN THROWS for the two refusals that are not faults, because
    /// the caller is a menu bar toggle: an operator who is told "macOS needs you to
    /// approve this in System Settings" has something to do, and one who is handed a
    /// thrown error from a popover has nothing.
    @discardableResult
    func setEnabled(_ enabled: Bool) -> LoginItemAction {
        let outcome = StartAtLoginPolicy.action(for: item.status, desired: enabled)
        switch outcome {
        case .none:
            lastRefusal = nil
        case .register:
            do {
                try item.register()
                lastRefusal = nil
                logger.info("Registered ExactMac for start at login")
            } catch {
                lastRefusal = "ExactMac could not start at login: \(error.localizedDescription)"
                logger.error("Start-at-login registration failed: \(error.localizedDescription, privacy: .public)")
            }
        case .unregister:
            do {
                try item.unregister()
                lastRefusal = nil
                logger.info("Removed ExactMac from start at login")
            } catch {
                lastRefusal = "ExactMac could not be removed from start at login: \(error.localizedDescription)"
                logger.error("Start-at-login removal failed: \(error.localizedDescription, privacy: .public)")
            }
        case .operatorApprovalRequired:
            lastRefusal = "macOS is holding this login item until you approve it in System Settings."
            logger.notice("Start-at-login registration needs the operator's approval in System Settings")
        }
        // The system is asked again rather than assumed to have changed: `register()` and
        // `unregister()` return Void, so the only evidence either succeeded is the status
        // afterwards, and publishing a guess is how a toggle ends up showing a state the
        // system disagrees with.
        status = item.status
        return outcome
    }
}
