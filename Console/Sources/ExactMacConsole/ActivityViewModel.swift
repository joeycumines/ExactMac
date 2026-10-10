import AppKit
import ExactMacServer
import Foundation
import os
import SwiftUI

/// Observable view model managing inspection and hash-chain verification of the decision audit log.
@MainActor
@Observable
final class ActivityViewModel {
    private(set) var rows: [ActivityRow.Model] = []
    private(set) var integrity: IntegrityBadge.State = .unchecked
    private(set) var subtitle: String = "Unavailable"
    private(set) var errorMessage: String?

    let windows: ConsoleWindowHost

    private let logger = Logger(
        subsystem: "io.github.joeycumines.exactmac.console",
        category: "activity.vm",
    )

    init(windows: ConsoleWindowHost) {
        self.windows = windows
    }

    /// Reads and verifies the decision audit log from the server and updates state.
    func refresh() {
        let activityResult: Result<DisplayActivityReport, Error> = Result {
            try ServerInspectionService.inspectActivity()
        }

        switch activityResult {
        case let .success(report):
            if case let .unreadable(reason) = report.integrity {
                rows = []
                integrity = .unchecked
                subtitle = "Unavailable"
                errorMessage = "The decision log did not open: \(reason). Decisions are still being enforced; this view is missing, not the protection."
            } else {
                rows = report.items.map { ActivityRow.Model(from: $0) }
                integrity = IntegrityBadge.State(from: report.integrity, itemCount: rows.count)
                subtitle = report.subtitle
                errorMessage = nil
            }
        case let .failure(error):
            logger.error("Failed to inspect activity: \(String(describing: error), privacy: .public)")
            rows = []
            integrity = .unchecked
            subtitle = "Unavailable"
            errorMessage = "The decision log did not open. Decisions are still being enforced; this view is missing, not the protection."
        }

        presentWindow()
    }

    /// Presents the Activity window with the current state.
    func presentWindow() {
        windows.present(
            .activity,
            title: "Activity",
            activates: true,
            updateIfPresent: true,
        ) { [weak self] in
            guard let self else { return AnyView(EmptyView()) }
            return AnyView(
                ActivityTimeline(
                    rows: self.rows,
                    integrity: self.integrity,
                    subtitle: self.subtitle,
                    errorMessage: self.errorMessage,
                    onRetry: { [weak self] in
                        self?.refresh()
                    },
                ),
            )
        }
    }
}
