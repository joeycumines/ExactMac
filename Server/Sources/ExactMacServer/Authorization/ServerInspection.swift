import Darwin
import Foundation
import os

/// The state of a grant's countdown chip.
public enum DisplayCountdownState: String, Sendable, Equatable {
    case live
    case soon
    case expired
}

/// A grant row formatted and ready for operator display in the console.
///
/// SERVER-COMPUTED AND DISPLAY-READY: the expiry is computed against the server's monotonic clock,
/// so no client process ever tries to interpret nanoseconds across process or boot boundaries.
public struct DisplayGrant: Sendable, Equatable, Identifiable {
    public var id: String
    public var consequence: String
    public var capability: String
    public var scope: String
    public var holder: String
    public var signature: String
    public var origin: String
    public var remaining: String
    public var countdownState: DisplayCountdownState
    public var isRevocable: Bool

    public init(
        id: String,
        consequence: String,
        capability: String,
        scope: String,
        holder: String,
        signature: String,
        origin: String,
        remaining: String,
        countdownState: DisplayCountdownState,
        isRevocable: Bool = true,
    ) {
        self.id = id
        self.consequence = consequence
        self.capability = capability
        self.scope = scope
        self.holder = holder
        self.signature = signature
        self.origin = origin
        self.remaining = remaining
        self.countdownState = countdownState
        self.isRevocable = isRevocable
    }
}

/// One decision row from the decision audit log, formatted for operator display.
public struct DisplayActivityItem: Sendable, Equatable, Identifiable {
    public var id: String
    public var sequence: UInt64
    public var isAllowed: Bool
    public var time: String
    public var consequence: String
    public var capability: String
    public var basis: String
    public var identity: String
    public var signature: String
    public var agentReason: String
    public var operatorNote: String?

    public init(
        id: String,
        sequence: UInt64,
        isAllowed: Bool,
        time: String,
        consequence: String,
        capability: String,
        basis: String,
        identity: String,
        signature: String,
        agentReason: String,
        operatorNote: String? = nil,
    ) {
        self.id = id
        self.sequence = sequence
        self.isAllowed = isAllowed
        self.time = time
        self.consequence = consequence
        self.capability = capability
        self.basis = basis
        self.identity = identity
        self.signature = signature
        self.agentReason = agentReason
        self.operatorNote = operatorNote
    }
}

/// The integrity state of the hash chain protecting the decision audit log.
public enum DisplayIntegrityState: Sendable, Equatable {
    case verified(entryCount: Int)
    case broken(atSequence: Int)
    case unreadable(reason: String)
}

/// The complete activity report returned to the console.
public struct DisplayActivityReport: Sendable, Equatable {
    public var items: [DisplayActivityItem]
    public var integrity: DisplayIntegrityState
    public var subtitle: String

    public init(
        items: [DisplayActivityItem],
        integrity: DisplayIntegrityState,
        subtitle: String = "Today · newest first",
    ) {
        self.items = items
        self.integrity = integrity
        self.subtitle = subtitle
    }
}

/// The read and inspection interface exposed by ExactMacServer to the hosted console.
///
/// Thread-safe and in-process. When a server runtime is actively hosted, inspection reads the
/// live in-memory stores and clocks. When stopped, inspection reads and verifies on-disk state.
public final class ServerInspectionService: @unchecked Sendable {
    private struct ActiveState: Sendable {
        let stateDirectory: String
        let store: GrantStore
        let audit: DecisionAudit
        let clock: any MonotonicClock
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var activeState: ActiveState?

    /// Registers the live server runtime stores so inspection reflects active state immediately.
    static func register(
        store: GrantStore,
        audit: DecisionAudit,
        clock: any MonotonicClock,
        stateDirectory: String,
    ) {
        lock.withLock {
            activeState = ActiveState(
                stateDirectory: stateDirectory,
                store: store,
                audit: audit,
                clock: clock,
            )
        }
    }

    /// Unregisters the live server runtime stores upon shutdown.
    static func unregister() {
        lock.withLock {
            activeState = nil
        }
    }

    /// Reads all active standing grants and formats them into display-ready rows.
    public static func inspectGrants(
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) throws -> [DisplayGrant] {
        let (store, clock) = try resolveStoreAndClock(environment: environment)
        let now = clock.now()
        let live = store.liveGrants(now: now)
        return live.map { formatGrant($0, now: now) }
    }

    /// Reads and verifies the decision audit log, returning a report with verified hash-chain status.
    public static func inspectActivity(
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) throws -> DisplayActivityReport {
        let (audit, path) = try resolveAuditAndPath(environment: environment)
        let verification = audit.verify()

        let integrity: DisplayIntegrityState = if verification.isIntact {
            .verified(entryCount: verification.entryCount)
        } else if let brokenSeq = verification.firstBrokenSequence {
            .broken(atSequence: Int(brokenSeq))
        } else if let defect = verification.defect {
            switch defect {
            case let .edited(seq):
                .broken(atSequence: Int(seq))
            case let .brokenChain(seq):
                .broken(atSequence: Int(seq))
            case let .sequenceGap(seq, _):
                .broken(atSequence: Int(seq))
            case .unreadable:
                .unreadable(reason: "The decision log could not be read")
            case .undecodableLine:
                .unreadable(reason: "The decision log contains invalid lines")
            case .writtenUnderAnotherBoot:
                .unreadable(reason: "The decision log was written under a previous boot")
            case .incompleteFinalLine:
                .verified(entryCount: verification.entryCount)
            }
        } else {
            .unreadable(reason: "Audit log integrity check failed")
        }

        let readBack = (try? AuditEntry.readAll(from: path))?.whole ?? []
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"

        let items: [DisplayActivityItem] = readBack.reversed().map { entry in
            formatActivityItem(entry, formatter: formatter)
        }

        return DisplayActivityReport(
            items: items,
            integrity: integrity,
            subtitle: "Today · newest first",
        )
    }

    /// Revokes a specific standing grant by identifier.
    public static func revokeGrant(
        id: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) throws {
        let (store, _) = try resolveStoreAndClock(environment: environment)
        try store.revoke(id)
    }

    /// Revokes all standing grants and pre-authorization envelopes.
    public static func revokeAllGrants(
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) throws {
        let (store, _) = try resolveStoreAndClock(environment: environment)
        try store.revokeAll()
    }

    /// THE CONSOLE'S WRITE INTO THE DECISION LOG, for the one local act that is a decision:
    /// the operator asking to weaken or restore the biometric gate on the console's own
    /// revealing surfaces. EVERY ATTEMPT is recorded, successful or not, because a gate
    /// whose downgrades could happen off the record is a gate an auditor cannot trust.
    ///
    /// THE ENTRY IS BUILT AND APPENDED HERE, inside the server module, because
    /// `AuthorizationRequest` and `AuthorizationDecision` have no public inits: their
    /// constructors are boundary-enforced facts, and an operator action that never crossed
    /// the wire should not be able to fabricate them from the console either. The entry
    /// names `rpcName: "console.operatorAction"` — a label, not an RPC — and the console's
    /// own identity as the caller, resolved from this process.
    ///
    /// THE AUDIT IS THE REGISTERED LIVE ONE, and the reason is the chain: a
    /// `DecisionAudit` caches its next sequence and last hash at open, so a SECOND instance
    /// opened on the same path would append from a stale chain position and break every
    /// entry after it. When no audit is registered — a host that never started a runtime —
    /// the action FAILS CLOSED: `nil` is returned, nothing is applied on the console side,
    /// and the operator is told the change did not happen. An unrecordable change is not
    /// applied, which is the same discipline as `auditUnavailable` on the RPC path.
    ///
    /// - Parameter outcome: what the attempt ended in — the operator approved the change
    ///   after a successful ceremony, or the ceremony failed and nothing changed.
    /// - Returns: whether the entry reached the log. A `false` return means the log could
    ///   not take the record and the caller must treat the action as not having happened.
    @discardableResult
    public static func recordOperatorAction(
        action: String,
        approved: Bool,
        biometricObtained: Bool,
        refusalReason: DenialReason?,
        environment _: [String: String] = ProcessInfo.processInfo.environment,
    ) -> Bool {
        lock.lock()
        let audit = activeState?.audit
        lock.unlock()
        guard let audit else {
            return false
        }

        let identity = SelfIdentityResolver.resolve()
        // The decision that is recorded: an approved toggle is an ALLOW on the operator's
        // own action; a failed ceremony is a DENY with the refusal named, so the log can
        // be asked "what was refused and why" the same way it can for an RPC.
        let decision = AuthorizationDecision(
            outcome: approved ? .allow : .deny,
            basis: approved ? .noConsentRequired : .denied(.notPermitted),
            effectiveCapabilities: [],
            blastRadius: BlastRadius(
                capability: 0.1,
                breadth: 0.1,
                duration: 0.1,
                remainingCount: 0.1,
                targetConsequence: 0.1,
                signatureQuality: 1.0,
            ),
            riskClass: .routine,
            biometric: .notRequired,
            offeredDecisions: [],
            ceremonyNonce: nil,
            expiresAt: nil,
        )
        let request = AuthorizationRequest(
            id: AuthorizationRequestID(rawValue: "console-\(UUID().uuidString)"),
            rpcName: "console.operatorAction",
            capability: .authorizationManage,
            scope: AuthorizationScope(),
            argumentSummary: action,
            agentReason: nil,
            origin: .directSocket,
        )
        return audit.record(
            request: request,
            identity: identity,
            decision: decision,
            operatorNote: approved ? nil : "The change was not applied.",
            biometricObtained: biometricObtained,
            refusalReason: refusalReason,
        ) != nil
    }

    /// Formats a dynamic, design-aligned subtitle for the Grants manager window.
    public static func grantsSubtitle(for grants: [DisplayGrant]) -> String {
        let count = grants.count
        guard count > 0 else {
            return "0 listed"
        }
        let soonCount = grants.filter { $0.countdownState == .soon }.count
        if soonCount > 0 {
            let verb = soonCount == 1 ? "expires" : "expire"
            return "\(count) listed  ·  \(soonCount) \(verb) within a minute"
        }
        return "\(count) listed"
    }

    // MARK: - Internal Helpers

    private static func resolveStoreAndClock(
        environment: [String: String],
    ) throws -> (GrantStore, any MonotonicClock) {
        lock.lock()
        if let active = activeState {
            if environment["EXACTMAC_STATE_DIRECTORY"] == nil || environment["EXACTMAC_STATE_DIRECTORY"] == active.stateDirectory {
                lock.unlock()
                return (active.store, active.clock)
            }
        }
        lock.unlock()

        try ExactMacRuntimePaths.prepareStateDirectory(environment: environment)
        let path = ExactMacRuntimePaths.grantStorePath(environment: environment)
        let clock = SystemMonotonicClock()
        let store = try GrantStore.openStore(
            path: path,
            clock: clock,
            maximumEnvelopeSeconds: 86400,
        )
        return (store, clock)
    }

    private static func resolveAuditAndPath(
        environment: [String: String],
    ) throws -> (DecisionAudit, String) {
        lock.lock()
        if let active = activeState {
            if environment["EXACTMAC_STATE_DIRECTORY"] == nil || environment["EXACTMAC_STATE_DIRECTORY"] == active.stateDirectory {
                let path = active.audit.path
                lock.unlock()
                return (active.audit, path)
            }
        }
        lock.unlock()

        try ExactMacRuntimePaths.prepareStateDirectory(environment: environment)
        let path = ExactMacRuntimePaths.auditLogPath(environment: environment)
        let clock = SystemMonotonicClock()
        let audit = try DecisionAudit(path: path, clock: clock)
        return (audit, path)
    }

    private static func formatGrant(_ grant: Grant, now: MonotonicInstant) -> DisplayGrant {
        let consequence = grant.capability.consequence
        let scopeDesc = grant.scope.description

        let durationDesc: String
        switch grant.duration {
        case .once:
            durationDesc = "for this request"
        case let .monotonicSeconds(secs):
            if secs >= 3600 {
                let hours = secs / 3600
                durationDesc = "for \(hours) \(hours == 1 ? "hour" : "hours")"
            } else if secs >= 60 {
                let mins = secs / 60
                durationDesc = "for \(mins) \(mins == 1 ? "minute" : "minutes")"
            } else {
                durationDesc = "for \(secs)s"
            }
        }

        let fullScope = durationDesc.isEmpty ? scopeDesc : "\(scopeDesc)  ·  \(durationDesc)"

        let holderName: String = if let bundle = grant.holder.bundleIdentifier, !bundle.isEmpty {
            bundle
        } else if !grant.holder.executablePath.isEmpty {
            (grant.holder.executablePath as NSString).lastPathComponent
        } else {
            "Unknown"
        }

        let signature = if grant.holder.designatedRequirement != nil {
            "signedAndValid"
        } else if grant.holder.bundleIdentifier != nil {
            "adHoc"
        } else {
            "unsigned"
        }

        let originDesc: String
        switch grant.origin {
        case let .prompt(decidedAt):
            let elapsedSecs = (now >= decidedAt)
                ? Int((now.nanoseconds - decidedAt.nanoseconds) / 1_000_000_000)
                : 0
            if elapsedSecs < 60 {
                originDesc = "Origin: prompt  ·  granted just now"
            } else {
                let mins = elapsedSecs / 60
                originDesc = "Origin: prompt  ·  granted \(mins) \(mins == 1 ? "minute" : "minutes") ago"
            }
        case let .envelope(id):
            let shortId = String(id.prefix(8))
            originDesc = "Origin: envelope \(shortId)"
        }

        var remainingText: String
        let countdownState: DisplayCountdownState
        if grant.duration == .once {
            remainingText = "Once"
            countdownState = .live
        } else if grant.expiresAt <= now {
            remainingText = "expired"
            countdownState = .expired
        } else {
            let remainingSecs = (grant.expiresAt > now)
                ? Int((grant.expiresAt.nanoseconds - now.nanoseconds) / 1_000_000_000)
                : 0
            countdownState = (remainingSecs <= 60) ? .soon : .live
            if remainingSecs < 60 {
                remainingText = "\(remainingSecs)s"
            } else if remainingSecs < 3600 {
                let m = remainingSecs / 60
                let s = remainingSecs % 60
                remainingText = "\(m)m \(String(format: "%02d", s))s"
            } else {
                let h = remainingSecs / 3600
                let m = (remainingSecs % 3600) / 60
                remainingText = "\(h)h \(String(format: "%02d", m))m"
            }
        }

        if let remainingOps = grant.remainingOperations {
            remainingText += "  ·  \(remainingOps) left"
        }

        return DisplayGrant(
            id: grant.id,
            consequence: consequence,
            capability: grant.capability.rawValue,
            scope: fullScope,
            holder: holderName,
            signature: signature,
            origin: originDesc,
            remaining: remainingText,
            countdownState: countdownState,
            isRevocable: true,
        )
    }

    private static func humanReadableDenialReason(_ reason: String) -> String {
        switch reason {
        case "notPermitted":
            "declined by operator in prompt"
        case "consoleUnreachable":
            "console unreachable"
        case "timeout":
            "approval timed out"
        case "biometricUnavailable":
            "Touch ID unavailable"
        case "auditUnavailable":
            "audit log unavailable"
        case "capabilityRequiresConsent":
            "action requires operator consent"
        case "reducedUnauthenticatedPosture":
            "unauthenticated TCP connection cannot be authorized"
        case "unauthenticatedPeer":
            "calling process could not be authenticated"
        case "grantStoreUnreadable":
            "grant store is unreadable"
        case "postureLockedDown":
            "security posture is locked down"
        case "missingAgentReason":
            "agent gave no reason for request"
        case "unreadableAgentReason":
            "agent reason could not be read"
        default:
            "action not permitted"
        }
    }

    private static func formatActivityItem(
        _ entry: AuditEntry,
        formatter: DateFormatter,
    ) -> DisplayActivityItem {
        let isAllowed = entry.decision == "allow"
        let date = Date(timeIntervalSince1970: TimeInterval(entry.wallClockSeconds))
        let timeString = formatter.string(from: date)

        let consequence = Capability(rawValue: entry.capability)?.consequence ?? "Desktop action"
        let scopeAndCapability: String = if !entry.scopeDescription.isEmpty {
            entry.scopeDescription
        } else if let cap = Capability(rawValue: entry.capability) {
            cap.consequence
        } else {
            "Desktop action"
        }

        let basisText: String
        if isAllowed {
            if entry.basis.hasPrefix("grant:") {
                basisText = "Allowed by standing grant"
            } else if entry.basis.hasPrefix("envelope:") {
                basisText = "Allowed inside pre-authorization envelope"
            } else if entry.basis == "noConsentRequired" {
                basisText = "Allowed by policy (no consent required)"
            } else if entry.basis == "promptRequired" {
                basisText = "Approved by operator"
            } else {
                basisText = "Allowed"
            }
        } else {
            if let refusal = entry.refusalReason {
                basisText = "Denied — \(humanReadableDenialReason(refusal))"
            } else if entry.basis.hasPrefix("denied:") {
                let reason = String(entry.basis.dropFirst(7))
                basisText = "Denied — \(humanReadableDenialReason(reason))"
            } else {
                basisText = "Denied"
            }
        }

        let holderName: String = if let bundle = entry.identity.bundleIdentifier, !bundle.isEmpty {
            bundle
        } else if !entry.identity.executablePath.isEmpty {
            (entry.identity.executablePath as NSString).lastPathComponent
        } else {
            "pid \(entry.identity.processIdentifier)"
        }
        let identityString = "\(holderName)  ·  pid \(entry.identity.processIdentifier)"

        return DisplayActivityItem(
            id: String(entry.sequence),
            sequence: entry.sequence,
            isAllowed: isAllowed,
            time: timeString,
            consequence: consequence,
            capability: scopeAndCapability,
            basis: basisText,
            identity: identityString,
            signature: entry.identity.signature,
            agentReason: entry.agentReason ?? "No reason given by the agent",
            operatorNote: entry.operatorNote,
        )
    }
}
