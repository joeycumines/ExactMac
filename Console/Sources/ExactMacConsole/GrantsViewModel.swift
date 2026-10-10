import AppKit
import ExactMacServer
import Foundation
import os
import SwiftUI

/// Observable view model managing inspection and revocation of in-memory standing grants.
@MainActor
@Observable
final class GrantsViewModel {
    private(set) var grants: [GrantRow.Model] = []
    private(set) var subtitle: String?
    private(set) var errorMessage: String?

    let windows: ConsoleWindowHost
    let ceremony: (any CeremonyPerforming)?

    private let logger = Logger(
        subsystem: "io.github.joeycumines.exactmac.console",
        category: "grants.vm",
    )

    init(
        windows: ConsoleWindowHost,
        ceremony: (any CeremonyPerforming)? = BiometricCeremony(),
    ) {
        self.windows = windows
        self.ceremony = ceremony
    }

    /// Refreshes standing grants from the server and presents the Grants window.
    func refresh() {
        let grantsResult: Result<[DisplayGrant], Error> = Result {
            try ServerInspectionService.inspectGrants()
        }

        switch grantsResult {
        case let .success(serverGrants):
            grants = serverGrants.map { GrantRow.Model(from: $0) }
            subtitle = ServerInspectionService.grantsSubtitle(for: serverGrants)
            errorMessage = nil
        case let .failure(error):
            logger.error("Failed to inspect grants: \(String(describing: error), privacy: .public)")
            grants = []
            subtitle = "Unavailable"
            errorMessage = "ExactMac cannot tell what is permitted, so it is denying every request that needs consent. Nothing is being granted on a guess."
        }

        presentWindow()
    }

    /// Presents the Grants window with the current state.
    func presentWindow() {
        windows.present(
            .grants,
            title: "Grants",
            activates: true,
            updateIfPresent: true,
        ) { [weak self] in
            guard let self else { return AnyView(EmptyView()) }
            return AnyView(
                GrantsManager(
                    grants: self.grants,
                    subtitle: self.subtitle,
                    errorMessage: self.errorMessage,
                    onRevoke: { [weak self] id in
                        self?.revokeGrant(id: id)
                    },
                    onRevokeAll: { [weak self] in
                        self?.revokeAllGrants()
                    },
                ),
            )
        }
    }

    /// Revokes a specific standing grant and refreshes.
    func revokeGrant(id: String) {
        do {
            try ServerInspectionService.revokeGrant(id: id)
        } catch {
            logger.error("Failed to revoke grant \(id, privacy: .private): \(String(describing: error), privacy: .public)")
        }
        refresh()
    }

    /// Revokes all standing grants and envelopes with biometric ceremony verification.
    func revokeAllGrants() {
        Task { @MainActor in
            await performRevokeAllGrants()
        }
    }

    /// Awaited revocation of all standing grants and envelopes.
    func performRevokeAllGrants() async {
        guard let ceremony else {
            logger.error("Cannot revoke all grants: no biometric ceremony is installed")
            return
        }
        windows.activateForCeremony()
        let outcome = await ceremony.perform(
            nonce: UUID().uuidString,
            reason: "ExactMac asks to revoke every grant at once",
        )
        guard case .performed = outcome else {
            logger.notice("Revoke-all ceremony was cancelled or declined")
            return
        }
        do {
            try ServerInspectionService.revokeAllGrants()
        } catch {
            logger.error("Failed to revoke all grants: \(String(describing: error), privacy: .public)")
        }
        refresh()
    }
}
