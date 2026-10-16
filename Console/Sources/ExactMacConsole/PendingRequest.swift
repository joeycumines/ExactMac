import ExactMacServer
import Foundation

/// A request waiting on the operator, carrying the whole disclosure.
struct PendingRequest: Equatable {
    let requestID: String
    /// The pid the kernel named for the connection. Carried because the tree's first row IS
    /// this process and a tree that could not name it would be asking the operator to trust
    /// a row with no identity in it.
    let processIdentifier: Int32
    let nonce: String
    let requestDigest: String
    let rpcName: String
    let capability: String
    /// What the capability would take, in words. This is the prompt's title, because
    /// "observation.ax" is a token and what the operator has to picture is the consequence.
    let consequence: String
    let scopeDescription: String
    let argumentSummary: String
    let agentReason: String?
    let executablePath: String
    let bundleIdentifier: String?
    let signature: SignatureBadge.State
    let isFullyResolved: Bool
    let ancestors: [Ancestor]
    let isAncestryTruncated: Bool
    /// The engine's own risk class, which is what the design's chip shows. `basis` says WHY a
    /// decision was reached and is not a risk level; the prompt was showing it as one, which
    /// put an enum rawValue in the operator's face.
    let riskClass: CapabilityRisk
    /// What the grant silently includes, beyond the capability being asked for. The design
    /// draws this as the implication, and it was being sent and then dropped.
    let impliedCapabilities: [String]
    let requiresBiometric: Bool
    let biometricReason: String?
    /// The options the server offered, each with ITS OWN SCOPE.
    ///
    /// It was `[OptionRow.Kind]`, which kept the kind and threw the scope away, and the
    /// prompt then named the options by `OptionRow.Kind.title` — a STATIC string that reads
    /// "Allow for TextEdit" whatever the target is. In the render it promised "Allow for
    /// TextEdit" directly under a scope line reading "every application". The scope is the
    /// whole of what distinguishes one option from another, so it is kept.
    let offered: [Offered]

    struct Offered: Equatable {
        let kind: OptionRow.Kind
        /// The server's own description of what this option would permit, e.g. "this exact
        /// request", "one application", "every app this agent touches".
        let scope: String
        /// How long THIS option's grant lasts, in seconds, or nil for a one-shot. Carried
        /// from the server's `GrantDuration` rather than re-derived, so the envelope review
        /// states the option's real ceiling instead of a number the console invented.
        let durationSeconds: Int?
        /// Whether agreeing to THIS option costs a fingerprint, carried per option because
        /// the server attaches the requirement to the option and not to the request. THE
        /// FOCUSED OPTION'S REQUIREMENT IS `requiresBiometric` above; this is the one the
        /// operator actually selects. Dropping it is what made a broad option unapprovable:
        /// the console ran no ceremony for it (its gate read the focused option's bar) and
        /// the server always refused an answer that skipped the selected option's own.
        let requiresBiometric: Bool
        /// Whether the server marked this option as the default focus. Exactly one offered
        /// option carries this flag; the console uses it for the collapsed primary button
        /// and the expanded "default" badge. Previously the console picked the first array
        /// element, which diverged from the engine when high-risk requests shifted the
        /// default to a narrower scope.
        let isDefault: Bool

        /// The row the operator reads under the option's title: the server's scope string
        /// plus the option's real duration. Composed from the carried values rather than a
        /// static vocabulary, so a grant configured for 20 minutes cannot read "for 8
        /// hours". Deny creates no grant and says so; a once grant expires when the
        /// request completes.
        var scopeLine: String {
            if kind == .deny {
                return "no grant is created"
            }
            let durationText = durationSeconds.map { "for \(PendingRequest.humanDuration($0))" }
                ?? "expires when it completes"
            return "\(scope)  ·  \(durationText)"
        }
    }

    /// The options, as kinds, for the call sites that only need to choose one.
    var offeredKinds: [OptionRow.Kind] {
        offered.map(\.kind)
    }

    /// The option the SERVER marked as the default focus, or nil when the offer carries
    /// no mark. The engine marks exactly one option and never Deny; nil is the malformed
    /// offer, and the batch decision treats it as an absence of approval rather than
    /// guessing a weaker option on the operator's behalf.
    ///
    /// SEPARATE FROM `ApprovalPrompt.focusedKind` because the two are different fallback
    /// policies for different jobs: the prompt always needs a clickable primary (so it
    /// falls back to the first offer), while the queue's batch decision must not approve
    /// on an unmarked offer (so it falls to deny). Same source of truth — the server's
    /// `isDefault` mark — read with the policy each consumer needs.
    var serverDefaultKind: OptionRow.Kind? {
        offered.first(where: \.isDefault)?.kind
    }

    /// The scope line of the server-marked default option, for the queue review row.
    /// Falls back to the request's own scope description when the offer carries no
    /// default mark — a row must say SOMETHING true about the grant even on a malformed
    /// offer, and the request's scope is the truest thing available.
    var serverDefaultScopeLine: String {
        offered.first(where: \.isDefault)?.scopeLine ?? scopeDescription
    }

    /// How long the operator has. The design draws a countdown, and the prompt was passing
    /// nil, so nothing on screen said the request would expire.
    let consentTimeoutSeconds: Int
    /// When this pending request was created or promoted, for computing live remaining countdown time.
    var createdAt: Date
    /// Returns a copy of this request with an updated active presentation timestamp.
    func withActiveTimestamp(_ date: Date = Date()) -> PendingRequest {
        var copy = self
        copy.createdAt = date
        return copy
    }

    /// Whether this is the revoke-everything decision, which is the one request whose
    /// consequence is not a capability at all.
    let isRevokeAll: Bool

    struct Ancestor: Equatable {
        let processIdentifier: Int32
        let executablePath: String
        let signature: SignatureBadge.State
        let isFullyResolved: Bool
    }

    /// BUILDS THE DISCLOSURE FROM THE SERVER'S OWN TYPES, and reads them rather than
    /// re-deriving anything. The request, the identity and the decision were all produced by
    /// the server from the request bytes; the one thing that did not come across the wire as a
    /// field is the request's own id, which is here because the continuation is keyed by it.
    init(
        request: AuthorizationRequest,
        identity: CallerIdentity,
        decision: AuthorizationDecision,
        createdAt: Date = Date(),
    ) {
        requestID = request.id.rawValue
        processIdentifier = identity.processIdentifier
        nonce = decision.ceremonyNonce ?? request.id.rawValue
        requestDigest = request.id.rawValue
        rpcName = request.rpcName
        capability = request.capability.rawValue
        consequence = request.capability.consequence
        scopeDescription = ScopeDescription.describe(request.scope)
        argumentSummary = request.argumentSummary
        agentReason = request.agentReason
        executablePath = identity.code.executablePath
        bundleIdentifier = identity.code.bundleIdentifier
        signature = SignatureBadge.State(serverValue: identity.code.signature.rawValue)
        isFullyResolved = identity.isFullyResolved
        ancestors = identity.ancestors.map {
            Ancestor(
                processIdentifier: $0.processIdentifier,
                executablePath: $0.code.executablePath,
                signature: SignatureBadge.State(serverValue: $0.code.signature.rawValue),
                isFullyResolved: $0.isFullyResolved,
            )
        }
        isAncestryTruncated = identity.isAncestryTruncated
        riskClass = CapabilityRisk(serverValue: decision.riskClass.rawValue)
        impliedCapabilities = decision.effectiveCapabilities
            .filter { $0 != request.capability }
            .map(\.rawValue)
            .sorted()
        requiresBiometric = decision.biometric.reason != nil
        biometricReason = decision.biometric.reason
        let envTimeout = ProcessInfo.processInfo.environment["EXACTMAC_CONSENT_TIMEOUT_SECONDS"].flatMap(Int.init)
        consentTimeoutSeconds = (envTimeout != nil && envTimeout! > 0) ? envTimeout! : ServerConfig.defaultConsentTimeoutSeconds
        self.createdAt = createdAt
        isRevokeAll = false
        offered = decision.offeredDecisions.map { option in
            Offered(
                kind: OptionRow.Kind(serverValue: option.kind.rawValue),
                scope: ScopeDescription.describe(option.scope),
                durationSeconds: option.duration.seconds,
                requiresBiometric: option.biometric.isRequired,
                isDefault: option.isDefault,
            )
        }
    }

    /// The ceremony requirement OF THE OPTION THE OPERATOR SELECTED, falling back to the
    /// focused one for an option the prompt did not offer — the same floor the server
    /// applies, so the console never runs a cheaper ceremony than the server would have
    /// accepted. `.deny` never costs a fingerprint, here as on the server.
    func requiresBiometric(for kind: OptionRow.Kind) -> Bool {
        if kind == .deny {
            return false
        }
        if let selected = offered.first(where: { $0.kind == kind }) {
            return selected.requiresBiometric
        }
        return requiresBiometric
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

    /// The prompt's TITLE, and the single most important line on the surface.
    var promptTitle: String {
        isRevokeAll ? "Revoke every grant" : consequence
    }

    /// The line under the title, naming what the grant is bounded to.
    var promptScopeLine: String {
        scopeDescription
    }

    /// What the grant would also permit, in the operator's words.
    var implicationText: String? {
        guard !impliedCapabilities.isEmpty else { return nil }
        let named = impliedCapabilities.compactMap(CapabilityRisk.consequence(of:))
        guard !named.isEmpty else { return nil }
        return "Also permits " + Self.proseList(named)
    }

    /// An English list, NOT the design's `  ·  ` metadata delimiter.
    private static func proseList(_ items: [String]) -> String {
        switch items.count {
        case 1:
            items[0]
        case 2:
            "\(items[0]) and \(items[1])"
        default:
            items.dropLast().joined(separator: ", ") + " and " + (items.last ?? "")
        }
    }

    /// How long the operator has, or nil when there is no timeout to count down.
    var clockText: String? {
        guard consentTimeoutSeconds > 0 else { return nil }
        return "decides in \(Self.clockLabel(consentTimeoutSeconds))"
    }

    /// A duration in M:SS, for every operator-facing place a timeout is stated.
    static func clockLabel(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let remainder = seconds % 60
        return "\(minutes):" + String(format: "%02d", remainder)
    }

    /// The biometric sentence, and what it says when no ceremony is required.
    var biometricLine: String {
        if let biometricReason, !biometricReason.isEmpty {
            return biometricReason
        }
        return requiresBiometric
            ? "\(BiometricCeremony.biometricType) will confirm this decision."
            : "This request requires no fingerprint confirmation."
    }

    /// The collapsed disclosure of the wider option set.
    var moreChoicesText: String? {
        let alternatives = offered.filter { $0.kind != .deny }
        guard alternatives.count > 1 else { return nil }
        let primaryOption = alternatives.first(where: \.isDefault) ?? alternatives[0]
        let others = alternatives.filter { $0.kind != primaryOption.kind }
        return "\(alternatives.count) more choices — \(primaryOption.scope), or "
            + Self.proseList(others.map(\.scope))
    }

    /// The body text shown on the popover's pending notice card, matching Figma node 0:1326.
    var popoverNoticeBody: String {
        let caller = !executablePath.isEmpty
            ? URL(fileURLWithPath: executablePath).lastPathComponent
            : (bundleIdentifier ?? "An application")
        var action = consequence.prefix(1).lowercased() + consequence.dropFirst()
        if action.hasSuffix(" and its history") {
            action = String(action.dropLast(" and its history".count))
        }
        if scopeDescription.hasPrefix("in ") {
            return "\(caller) wants to \(action) \(scopeDescription)"
        } else if scopeDescription != "any application", !scopeDescription.isEmpty {
            return "\(caller) wants to \(action) in \(scopeDescription)"
        } else {
            return "\(caller) wants to \(action)"
        }
    }

    /// Who is asking for the pre-authorization.
    var envelopeRequester: String {
        !executablePath.isEmpty
            ? URL(fileURLWithPath: executablePath).lastPathComponent
            : (bundleIdentifier ?? "An application")
    }

    /// What the envelope would permit, one row per capability.
    var envelopeCapabilities: [EnvelopeReview.Capability] {
        var rows: [EnvelopeReview.Capability] = []
        if let consequence = CapabilityRisk.consequence(of: capability) {
            rows.append(.init(
                id: capability,
                consequence: consequence,
                breadth: scopeDescription,
                risk: riskClass,
            ))
        }
        for implied in impliedCapabilities {
            guard let consequence = CapabilityRisk.consequence(of: implied) else { continue }
            rows.append(.init(
                id: implied,
                consequence: consequence,
                breadth: scopeDescription,
                risk: riskClass,
            ))
        }
        return rows
    }

    /// How long the envelope lasts, in the operator's words.
    var envelopeDurationLabel: String {
        guard let seconds = offered.first(where: { $0.kind == .envelope })?.durationSeconds,
              seconds > 0
        else { return "this session" }
        return Self.humanDuration(seconds)
    }

    /// Seconds in the operator's words.
    static func humanDuration(_ seconds: Int) -> String {
        if seconds >= 3600, seconds % 3600 == 0 {
            let hours = seconds / 3600
            return hours == 1 ? "1 hour" : "\(hours) hours"
        }
        if seconds >= 60, seconds % 60 == 0 {
            let minutes = seconds / 60
            return minutes == 1 ? "1 minute" : "\(minutes) minutes"
        }
        return seconds == 1 ? "1 second" : "\(seconds) seconds"
    }
}
