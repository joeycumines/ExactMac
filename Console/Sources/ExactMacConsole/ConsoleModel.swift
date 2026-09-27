import AppKit
import Foundation
import os

/// What the popover reads, and the one place the console decides anything.
///
/// Every state here is a property of the LISTENER, not a flag the console sets: whether the
/// service is up, whether it is answering, and whether it is reachable at all. The console
/// reports those; it does not decide them.
@MainActor
@Observable
final class ConsoleModel {
    private(set) var serviceState: ServiceState = .running
    private(set) var isServiceEnabled = true
    private(set) var activeGrantCount: Int?
    private(set) var activityCount: Int?
    /// `.none` when there is nothing wrong, and the band when there is. An OPTIONAL SLOT at a
    /// fixed index, which is why the popover's height is driven by it and nothing else.
    private(set) var failClosed: (title: String, body: String)?
    private(set) var pendingNotice: String?
    var pendingPrompt: PendingRequest?

    private let channel: ConsoleChannelClient
    private let serviceController: any ServiceControlling
    private let onServiceDisabled: (@Sendable () async throws -> Void)?
    private let logger = Logger(
        subsystem: "io.github.joeycumines.exactmac.console",
        category: "console",
    )

    init(
        channel: ConsoleChannelClient = .live(),
        serviceController: any ServiceControlling = LaunchdServiceController(),
        onServiceDisabled: (@Sendable () async throws -> Void)? = nil,
    ) {
        self.channel = channel
        self.serviceController = serviceController
        self.onServiceDisabled = onServiceDisabled
    }

    // MARK: The service control

    /// Changes the service enablement state in launchd, revoking standing grants on disable.
    func setServiceEnabled(_ enabling: Bool) async throws {
        let previousEnabled = isServiceEnabled
        let previousState = serviceState
        let previousFailClosed = failClosed
        let previousGrants = activeGrantCount

        isServiceEnabled = enabling
        serviceState = enabling ? .running : .stopped
        if !enabling {
            activeGrantCount = 0
            failClosed = (
                "The service is off",
                "You turned ExactMac off. Nothing is served and nothing is exposed until you turn it back on.",
            )
        } else {
            failClosed = nil
        }
        logger.info("Service \(enabling ? "enabled" : "disabled", privacy: .public) by the operator")
        do {
            try await serviceController.setServiceEnabled(enabling)
            if !enabling, let onServiceDisabled {
                try await onServiceDisabled()
            }
        } catch {
            isServiceEnabled = previousEnabled
            serviceState = previousState
            failClosed = previousFailClosed
            activeGrantCount = previousGrants
            throw error
        }
    }

    /// Toggling drives launchd, the platform's own mechanism, and never a bespoke flag file.
    func toggleService() {
        let enabling = !isServiceEnabled
        Task { [weak self] in
            do {
                try await self?.setServiceEnabled(enabling)
            } catch {
                self?.handleServiceControlError(error, desiredState: enabling)
            }
        }
    }

    /// Synchronizes the in-memory state with launchd's persistent configuration.
    func refreshServiceState() async {
        do {
            let enabled = try await serviceController.isServiceEnabled()
            isServiceEnabled = enabled
            if !enabled {
                serviceState = .stopped
                failClosed = (
                    "The service is off",
                    "You turned ExactMac off. Nothing is served and nothing is exposed until you turn it back on.",
                )
            } else if serviceState == .stopped {
                serviceState = .running
                failClosed = nil
            }
        } catch {
            logger.warning("Failed to refresh service state: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handleServiceControlError(_ error: any Error, desiredState: Bool) {
        logger.error("Failed to set service state to \(desiredState, privacy: .public): \(error.localizedDescription, privacy: .public)")
    }

    func quit() {
        NSApp.terminate(nil)
    }

    // MARK: Reading from the channel

    /// Pulls the next frame and folds it into the state the popover draws.
    ///
    /// A channel that is not connected is the `unreachable` state and the words say
    /// everything: the console is not running, so every consent-requiring capability is
    /// being denied, and that is the safe direction rather than a fault.
    func poll() async {
        guard channel.isConnected else {
            apply(.unreachable)
            return
        }
        do {
            while let frame = try await channel.nextFrame(timeout: .milliseconds(200)) {
                try handle(frame)
            }
        } catch {
            apply(.unreachable)
        }
    }

    private func apply(_ state: ServiceState) {
        serviceState = state
        switch state {
        case .unreachable:
            failClosed = (
                "Denied until the console is available",
                "ExactMac could not reach the consent service, so every request that needs "
                    + "consent was denied. Nothing ran and no grant was created. "
                    + "This is the safe direction.",
            )
        case .degraded:
            failClosed = (
                "The service is not answering",
                "The console cannot reach ExactMac, so no request can be made or answered. "
                    + "Nothing on this Mac is being automated while it is down.",
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
                "The service is off",
                "You turned ExactMac off. Nothing is served and nothing is exposed until "
                    + "you turn it back on.",
            )
        case .running, .pending:
            failClosed = nil
        }
    }

    private func handle(_ frame: ConsoleFrame) throws {
        switch frame {
        case let .pending(consent):
            pendingPrompt = PendingRequest(consent: consent)
            pendingNotice = "\(consent.identity.executablePath) wants "
                + "\(consent.request.capability)"
            serviceState = .pending
        case let .reply(reply):
            switch reply.kind {
            case "grants": activeGrantCount = reply.count
            case "activity": activityCount = reply.count
            default: break
            }
        case .decision, .query, .hello:
            // Server-to-console frames arriving inbound are refused rather than ignored,
            // because a peer sending them is not speaking this protocol.
            throw ConsoleChannelError.malformedFrame(reason: "a server-to-console frame arrived inbound")
        }
    }

    /// The operator's answer. A decision that cannot be delivered is NOT a decision, and
    /// treating it as one would let a console that lost its socket authorize something the
    /// operator agreed to a prompt nobody can see.
    func decide(_ kind: OptionRow.Kind, note: String) async {
        guard let prompt = pendingPrompt else { return }
        defer { pendingPrompt = nil; pendingNotice = nil; serviceState = .running }
        let decision = ConsentDecision(
            requestID: prompt.requestID,
            nonce: prompt.nonce,
            requestDigest: prompt.requestDigest,
            isApproved: kind != .deny,
            selected: kind.rawValue,
            note: note,
            biometricObtained: false,
        )
        do {
            try await channel.post(decision)
        } catch {
            logger.error(
                "The decision could not be delivered: \(error.localizedDescription, privacy: .public)",
            )
        }
    }
}

/// A request waiting on the operator, carrying the whole disclosure.
struct PendingRequest: Equatable {
    let requestID: String
    let nonce: String
    let requestDigest: String
    let rpcName: String
    let capability: String
    let scopeDescription: String
    let argumentSummary: String
    let agentReason: String?
    let executablePath: String
    let bundleIdentifier: String?
    let signature: SignatureBadge.State
    let isFullyResolved: Bool
    let ancestors: [Ancestor]
    let isAncestryTruncated: Bool
    let basis: String
    let requiresBiometric: Bool
    let biometricReason: String?
    let offered: [OptionRow.Kind]

    struct Ancestor: Equatable {
        let processIdentifier: Int32
        let executablePath: String
        let signature: SignatureBadge.State
        let isFullyResolved: Bool
    }

    init(consent: PendingConsent) {
        requestID = consent.request.requestID
        nonce = consent.nonce
        requestDigest = consent.requestDigest
        rpcName = consent.request.rpcName
        capability = consent.request.capability
        scopeDescription = consent.request.scopeDescription
        argumentSummary = consent.request.argumentSummary
        agentReason = consent.request.agentReason
        executablePath = consent.identity.executablePath
        bundleIdentifier = consent.identity.bundleIdentifier
        signature = SignatureBadge.State(rawValue: consent.identity.signature) ?? .unresolved
        isFullyResolved = consent.identity.isFullyResolved
        ancestors = consent.identity.ancestors.map {
            Ancestor(
                processIdentifier: $0.processIdentifier,
                executablePath: $0.executablePath,
                signature: SignatureBadge.State(rawValue: $0.signature) ?? .unresolved,
                isFullyResolved: $0.isFullyResolved,
            )
        }
        isAncestryTruncated = consent.identity.isAncestryTruncated
        basis = consent.decision.basis
        requiresBiometric = consent.decision.requiresBiometric
        biometricReason = consent.decision.biometricReason
        offered = consent.decision.offered.compactMap { OptionRow.Kind(rawValue: $0.kind) }
    }

    /// The caller tree, in the order the design draws it: nearest ancestor first and the
    /// requester last, because the requester is the row that matters and the tree is read
    /// downward into it.
    var treeRows: [CallerTree.Row] {
        ancestors.enumerated().map { index, ancestor in
            CallerTree.Row(
                id: ancestor.processIdentifier,
                name: URL(fileURLWithPath: ancestor.executablePath).lastPathComponent,
                role: "ancestor",
                depth: index + 1,
                signature: ancestor.signature,
                isRequester: false,
            )
        } + [
            CallerTree.Row(
                id: 0,
                name: URL(fileURLWithPath: executablePath).lastPathComponent,
                role: "requesting",
                depth: ancestors.count + 1,
                signature: signature,
                isRequester: true,
            ),
        ]
    }
}
