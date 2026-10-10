import AppKit
import ExactMacServer
import Foundation
import os
import SwiftUI

/// Observable view model managing posture, biometric gate, login-item, and service settings.
@MainActor
@Observable
final class SettingsViewModel {
    private(set) var serviceState: ServiceState = .running
    private(set) var failClosed: (title: String, body: String)?
    private(set) var pendingNotice: String?

    var isServiceRunning: Bool {
        serviceState == .running || serviceState == .pending
    }

    var isServiceEnabled: Bool {
        isServiceRunning
    }

    var isStartAtLoginEnabled: Bool {
        startAtLogin.status == .enabled
    }

    private(set) var postureHandle: HostedPostureHandle?
    private(set) var displayedPosture: Posture = .strict

    private(set) var biometricGateHandle: HostedBiometricGateHandle?
    private(set) var displayedBiometricGate: Bool = true
    private var isPerformingBiometricGateChange: Bool = false

    let startAtLogin: StartAtLogin
    let presentation: OperatorInterface
    let ceremony: (any CeremonyPerforming)?
    let windows: ConsoleWindowHost
    let stateEnvironment: [String: String]

    private let logger = Logger(
        subsystem: "io.github.joeycumines.exactmac.console",
        category: "settings.vm",
    )

    init(
        startAtLogin: StartAtLogin = StartAtLogin(),
        presentation: OperatorInterface = ServerHosting.current(),
        windows: ConsoleWindowHost = ConsoleWindowHost(),
        ceremony: (any CeremonyPerforming)? = BiometricCeremony(),
        stateEnvironment: [String: String] = ProcessInfo.processInfo.environment,
    ) {
        self.startAtLogin = startAtLogin
        self.presentation = presentation
        self.windows = windows
        self.ceremony = ceremony
        self.stateEnvironment = stateEnvironment
    }

    // MARK: - Posture Management

    func adoptPostureHandle(_ handle: HostedPostureHandle) {
        postureHandle = handle
        displayedPosture = handle.current
    }

    func setPosture(_ posture: Posture) {
        guard let postureHandle else {
            logger.notice("Cannot set posture: server handle is not ready")
            return
        }
        postureHandle.setStoredPreference(posture, environment: stateEnvironment)
        displayedPosture = postureHandle.current
    }

    /// Confirms a stored non-strict posture (.balanced) via interactive operator Touch ID.
    @discardableResult
    func confirmStoredPosture() async -> Bool {
        guard let handle = postureHandle, handle.needsConfirmation else { return true }
        guard let ceremony else {
            logger.error("Cannot confirm stored posture: no biometric ceremony is installed")
            return false
        }
        windows.activateForCeremony()
        let outcome = await ceremony.perform(
            nonce: UUID().uuidString,
            reason: "ExactMac asks to confirm your stored non-strict posture (Balanced)",
        )
        guard case .performed = outcome else {
            logger.notice("Touch ID confirmation for stored non-strict posture was declined or cancelled")
            return false
        }
        handle.confirmStoredPreference()
        displayedPosture = handle.current
        logger.info("Stored non-strict posture confirmed by operator Touch ID")
        return true
    }

    // MARK: - Biometric Gate Management

    func adoptBiometricGateHandle(_ handle: HostedBiometricGateHandle) {
        biometricGateHandle = handle
        displayedBiometricGate = handle.isCeremonyRequired
    }

    func setBiometricGate(_ requiring: Bool) {
        Task { @MainActor in
            await performBiometricGateChange(requiring)
        }
    }

    func performBiometricGateChange(_ requiring: Bool) async {
        guard !isPerformingBiometricGateChange else { return }
        isPerformingBiometricGateChange = true
        defer { isPerformingBiometricGateChange = false }

        let action = requiring
            ? "the console biometric gate was turned on"
            : "the console biometric gate was turned off"

        guard let ceremony else {
            logger.error(
                "The biometric gate was asked to change and no ceremony is installed; refusing rather than changing without the check",
            )
            let recorded = ServerInspectionService.recordOperatorAction(
                action: action,
                approved: false,
                biometricObtained: false,
                refusalReason: .biometricUnavailable,
                environment: stateEnvironment,
            )
            if !recorded {
                pendingNotice = "The setting was not changed: the decision log could not record the attempt."
            }
            return
        }

        windows.activateForCeremony()
        let outcome = await ceremony.perform(
            nonce: UUID().uuidString,
            reason: requiring
                ? "ExactMac asks to require Touch ID again to open Grants and Activity"
                : "ExactMac asks before Touch ID stops protecting Grants and Activity",
        )
        guard case .performed = outcome else {
            logger.notice("The biometric gate change was refused: the ceremony did not complete")
            let recorded = ServerInspectionService.recordOperatorAction(
                action: action,
                approved: false,
                biometricObtained: false,
                refusalReason: .biometricUnavailable,
                environment: stateEnvironment,
            )
            if !recorded {
                pendingNotice = "The setting was not changed: the decision log could not record the attempt."
            }
            return
        }

        let recorded = ServerInspectionService.recordOperatorAction(
            action: action,
            approved: true,
            biometricObtained: true,
            refusalReason: nil,
            environment: stateEnvironment,
        )
        guard recorded else {
            pendingNotice = "The setting was not changed: the decision log could not take the record."
            logger.error("The biometric gate change was not applied: the audit could not record it")
            return
        }
        guard let biometricGateHandle else {
            logger.notice("Cannot set biometric gate: server handle is not ready")
            return
        }
        biometricGateHandle.setCeremonyRequired(requiring, environment: stateEnvironment)
        displayedBiometricGate = biometricGateHandle.isCeremonyRequired
    }

    // MARK: - Gate Passing for Protected Surfaces

    func passBiometricGate(for surface: String) async -> Bool {
        guard let handle = biometricGateHandle else {
            logger.notice("Opening \(surface, privacy: .public) was refused: the server's gate has not come up")
            return false
        }
        guard handle.isCeremonyRequired else {
            return true
        }
        guard let ceremony else {
            logger.notice(
                "Opening \(surface, privacy: .public) was refused: the gate requires a ceremony and none is installed",
            )
            return false
        }
        windows.activateForCeremony()
        let outcome = await ceremony.perform(
            nonce: UUID().uuidString,
            reason: "ExactMac asks before showing \(surface) — what is permitted and what was asked",
        )
        guard case .performed = outcome else {
            logger.notice("Opening \(surface, privacy: .public) was refused: the ceremony did not complete")
            return false
        }
        return true
    }

    // MARK: - Reset Everything

    func resetEverything(onGrantsRevoked: (() -> Void)? = nil) {
        Task { @MainActor in
            await performResetEverything(onGrantsRevoked: onGrantsRevoked)
        }
    }

    func performResetEverything(onGrantsRevoked: (() -> Void)? = nil) async {
        guard let ceremony else {
            logger.error("Cannot reset everything: no biometric ceremony is installed")
            return
        }
        windows.activateForCeremony()
        let outcome = await ceremony.perform(
            nonce: UUID().uuidString,
            reason: "ExactMac asks to reset everything: revoke every grant and restore the default posture",
        )
        guard case .performed = outcome else {
            logger.notice("The reset ceremony was cancelled or declined")
            return
        }
        do {
            try ServerInspectionService.revokeAllGrants()
        } catch {
            logger.error("Reset failed to revoke grants: \(String(describing: error), privacy: .public)")
            pendingNotice = "The reset did not complete: grants could not be revoked. Nothing else was changed."
            return
        }
        postureHandle?.setStoredPreference(.strict, environment: stateEnvironment)
        if let postureHandle {
            displayedPosture = postureHandle.current
        }
        onGrantsRevoked?()
    }

    // MARK: - Login-Item Registration

    func setStartAtLoginEnabled(_ enabling: Bool) {
        let outcome = startAtLogin.setEnabled(enabling)
        switch outcome {
        case .none:
            break
        case .register:
            logger.info("ExactMac registered to start at login")
        case .unregister:
            logger.info("ExactMac removed from start at login")
        case .operatorApprovalRequired:
            break
        }
        pendingNotice = startAtLogin.lastRefusal
    }

    func toggleStartAtLogin() {
        setStartAtLoginEnabled(!isStartAtLoginEnabled)
    }

    func refreshServiceState() {
        startAtLogin.refresh()
    }

    // MARK: - Service Lifecycle

    private func vetoed(_ state: ServiceState) -> ServiceState {
        guard !presentation.canObtainConsent else { return state }
        switch state {
        case .running, .pending: return .unreachable
        case .degraded, .reduced, .stopped, .unreachable: return state
        }
    }

    func apply(_ state: ServiceState) {
        let effective = vetoed(state)
        if effective != serviceState {
            logger.info("Console state is now \(String(describing: effective), privacy: .public)")
        }
        if effective != state {
            logger.notice(
                "Refusing to report \(String(describing: state), privacy: .public): this process cannot present a consent prompt (\(self.presentation.summary, privacy: .public))",
            )
        }
        serviceState = effective
        switch effective {
        case .unreachable:
            failClosed = (
                "Denied until ExactMac can ask you",
                "Every request that needs consent is being denied, because nothing can put "
                    + "the question in front of you. Nothing ran and no grant was created.",
            )
        case .degraded:
            failClosed = (
                "The service is not answering",
                "No request can be made or answered. Nothing on this Mac is being "
                    + "automated while this is the case.",
            )
        case .reduced:
            failClosed = (
                "Running without approvals",
                "This server is listening on TCP, where there is no owning user to "
                    + "authenticate. Process verification and approvals are unavailable, so "
                    + "every consent-requiring capability is denied.",
            )
        case .stopped:
            failClosed = (
                "ExactMac is not serving",
                "Nothing is being served and nothing is exposed. Quitting and opening "
                    + "ExactMac again will not help on its own — the reason is in the log.",
            )
        case .running, .pending:
            failClosed = nil
        }
    }

    func stopService(onStop: (() -> Void)? = nil) {
        logger.info("Stopping ExactMac service by operator request")
        onStop?()
        windows.close(.approval)
        apply(.stopped)
        failClosed = (
            "The service is off",
            "You turned ExactMac off. Nothing is served and nothing is exposed until you turn it back on.",
        )
    }

    func startService() {
        logger.info("Starting ExactMac service by operator request")
        apply(.running)
    }

    func toggleService(onStop: (() -> Void)? = nil) {
        if isServiceRunning {
            stopService(onStop: onStop)
        } else {
            startService()
        }
    }

    func setServiceEnabled(_ enabling: Bool, onStop: (() -> Void)? = nil) {
        if enabling {
            startService()
        } else {
            stopService(onStop: onStop)
        }
    }

    func reportServerStarted() {
        apply(.running)
    }

    func reportServerStartFailure(reason: String) {
        logger.error("The hosted server did not start: \(reason, privacy: .public)")
        pendingNotice = "ExactMac could not start its server: \(reason)"
        apply(.stopped)
    }

    func setPendingNotice(_ notice: String?) {
        pendingNotice = notice
    }
}
