import Foundation

// The authorization domain model.
//
// Every type here is a value with no I/O, no clock and no dependency on gRPC, AppKit,
// LocalAuthentication or the filesystem. That is not tidiness: the decision engine has to
// be exhaustively testable without a running server, a window server, a biometric
// ceremony or a writable store, and every one of those is something a test cannot
// provide. Anything that needs the outside world lives behind a protocol in a different
// file and is passed IN as a value.

// MARK: - Time

/// A point on the monotonic clock, in nanoseconds.
///
/// Grants expire against this and never against the wall clock, because a wall-clock
/// change — an NTP correction, a manual change, a timezone bug — must not be able to
/// extend a grant the operator already let expire. Every value that expires carries one.
struct MonotonicInstant: Sendable, Equatable, Hashable, Comparable {
    let nanoseconds: UInt64

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.nanoseconds < rhs.nanoseconds
    }

    /// Saturating, so a hostile or buggy duration cannot wrap into the past and make
    /// every grant look expired, or into the far future and make them look live.
    func advanced(by interval: Swift.Duration) -> MonotonicInstant {
        // Saturating on BOTH operations. The multiply used to happen in Int64 before
        // anything clamped it, so `advanced(by: .seconds(Int64.max))` trapped and killed
        // the process — the opposite of the promise in the doc comment, and this is the
        // function grant issuance calls on values read back from a store.
        // NEGATIVE intervals are zero, not a saturating maximum. Reporting overflow on a
        // negative product set the delta to UInt64.max, so a duration of about -292 years
        // or worse produced an instant at the end of time — a grant that never expires,
        // which is the fail-OPEN direction and the exact opposite of what the comment
        // promises. A store that is readable is not a store that is untampered.
        let seconds = max(0, interval.components.seconds)
        let (scaled, secondsOverflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        let delta: UInt64
        if secondsOverflow {
            // Saturate the DELTA to the whole representable range. Clamping the
            // nanosecond value instead capped the result at Int64.max, which is a
            // saturating answer that is still wrong by a factor of two billion.
            delta = UInt64.max
        } else {
            let nanos = scaled &+ Int64(clamping: max(0, interval.components.attoseconds) / 1_000_000_000)
            delta = UInt64(clamping: max(0, nanos))
        }
        let (sum, overflow) = nanoseconds.addingReportingOverflow(delta)
        return MonotonicInstant(nanoseconds: overflow ? UInt64.max : sum)
    }

    func remaining(until deadline: MonotonicInstant) -> Swift.Duration? {
        guard deadline > self else { return nil }
        return .nanoseconds(Int64(clamping: deadline.nanoseconds - self.nanoseconds))
    }
}

/// How long an authorization lasts. `.once` completes with the request it authorized
/// and cannot be re-presented; `.monotonicSeconds` is a real span of the monotonic
/// clock.
///
/// NAMED GrantDuration, not Duration, and that is a compile error I earned: a top-level
/// `Duration` in this module shadows the standard library's for the WHOLE target, so
/// `ExactMacService.swift` stopped compiling with "type 'Duration' has no member
/// 'milliseconds'". A type declared at module scope is visible to every file in it, and
/// the fix belongs here rather than in the twenty files that use the stdlib type.
enum GrantDuration: Sendable, Equatable, Hashable {
    case once
    case monotonicSeconds(Int)

    var isPersistent: Bool {
        if case .monotonicSeconds = self {
            return true
        }
        return false
    }

    /// The span in seconds, or nil for `.once`. Used by the blast-radius product, which
    /// is why it is a total function rather than a stored number: two representations
    /// of "long" must not be able to disagree.
    var seconds: Int? {
        switch self {
        case .once: nil
        case let .monotonicSeconds(value): value
        }
    }
}

// MARK: - Capabilities

/// The capabilities the server gates, and the lattice they form.
///
/// This is NOT a flat list, and the shape is the point. `scriptExecute` is not a peer
/// of the others: it subsumes them, because a shell can read the screen, read the
/// clipboard and drive the interface. Presenting "allow shell" beside "allow clipboard
/// read" as two independent checkboxes is incoherent, because the first silently
/// includes the second. `implies(_:)` is therefore a real relation on this type, the
/// engine closes every request over it, and the prompt states what a grant silently
/// includes — because information the operator is entitled to before agreeing cannot be
/// buried.
enum Capability: String, Sendable, CaseIterable, Hashable {
    case scriptExecute = "script.execute"
    case macroExecute = "macro.execute"
    case accessibilityTraverse = "observation.ax"
    case windowObserve = "observation.window"
    case screenObserve = "observation.screen"
    case observationStream = "observation.stream"
    case displayRead = "display.read"
    case clipboardRead = "clipboard.read"
    case clipboardWrite = "clipboard.write"
    case inputSynthesize = "input.synthesize"
    case windowManage = "window.manage"
    case applicationControl = "application.control"
    case fileDialogAutomate = "file.automate"
    case transactionManage = "transaction.manage"
    case sessionManage = "session.manage"
    /// Reads nothing off the desktop: it echoes back input the caller itself submitted.
    /// It still passes through the interceptor, and it is still mapped, so that the
    /// set of unmapped methods stays empty.
    case localEcho = "local.echo"

    /// The capabilities this one carries with it. Transitive closure is computed by
    /// `impliedCapabilities`, so this table only ever states DIRECT implications.
    var directlyImplies: Set<Capability> {
        switch self {
        case .scriptExecute:
            // A shell reaches everything this server can reach, and more.
            [
                .macroExecute, .accessibilityTraverse, .windowObserve, .screenObserve,
                .observationStream, .displayRead, .clipboardRead, .clipboardWrite,
                .inputSynthesize, .windowManage, .applicationControl,
                .fileDialogAutomate, .transactionManage, .sessionManage,
            ]
        case .macroExecute:
            // A recorded macro is a bounded sequence of input and transactions.
            [.inputSynthesize, .transactionManage]
        case .accessibilityTraverse:
            // Reading the tree tells you which windows exist and which displays they
            // are on, so the narrower observations come with it.
            [.windowObserve, .displayRead]
        case .screenObserve:
            // A screenshot shows the window layout and the display geometry.
            [.windowObserve, .displayRead]
        case .windowObserve:
            [.displayRead]
        case .observationStream, .windowManage, .applicationControl, .fileDialogAutomate,
             .transactionManage, .sessionManage, .displayRead, .clipboardRead,
             .clipboardWrite, .inputSynthesize, .localEcho:
            []
        }
    }

    /// This capability and everything it transitively carries.
    var impliedCapabilities: Set<Capability> {
        var seen: Set<Capability> = []
        var frontier: Set<Capability> = [self]
        while let next = frontier.popFirst() {
            guard seen.insert(next).inserted else { continue }
            frontier.formUnion(next.directlyImplies.subtracting(seen))
        }
        return seen
    }

    /// True when a grant for the RECEIVER would authorise a request for `other`.
    ///
    /// Direction matters and is easy to invert, and it was inverted: this read
    /// `other.impliedCapabilities.contains(self)`, which asks whether the REQUEST's
    /// closure contains the GRANT's capability, and so reported that a shell grant does
    /// NOT cover a clipboard read. The closure runs from the subsuming capability
    /// outward — `scriptExecute.impliedCapabilities` contains `clipboardRead` — so the
    /// grant's own closure is what has to contain the request. A shell grant covers a
    /// clipboard read; a clipboard grant does not cover a shell.
    func implies(_ other: Capability) -> Bool {
        impliedCapabilities.contains(other)
    }

    /// Whether reaching the desktop at all requires a decision. `localEcho` does not,
    /// and this is the only reason `localEcho` exists rather than every RPC being equal.
    var requiresConsent: Bool {
        self != .localEcho
    }

    /// The operator-facing consequence, and the only label the prompt is allowed to
    /// show. "script.execute" is not something an operator can picture; what it will
    /// take is.
    var consequence: String {
        switch self {
        case .scriptExecute: "Run a shell command, AppleScript or JavaScript"
        case .macroExecute: "Replay a recorded macro"
        case .accessibilityTraverse: "Read the accessibility tree of an app"
        case .windowObserve: "List and read windows and applications"
        case .screenObserve: "Read the contents of the screen"
        case .observationStream: "Watch accessibility changes as they happen"
        case .displayRead: "Read the display layout"
        case .clipboardRead: "Read the clipboard and its history"
        case .clipboardWrite: "Replace what is on the clipboard"
        case .inputSynthesize: "Type and click as you"
        case .windowManage: "Move, resize, close and focus windows"
        case .applicationControl: "Open, activate and quit applications"
        case .fileDialogAutomate: "Drive open and save panels"
        case .transactionManage: "Group actions into a transaction"
        case .sessionManage: "Create and inspect sessions"
        case .localEcho: "Read back input this server was already given"
        }
    }
}

// MARK: - Scope

/// Which application a request lands on. Consequence is overwhelmingly a function of
/// WHERE an action lands rather than of what shape it has, which is why this is the
/// primary axis of a grant and not a filter applied afterwards.
enum TargetApplication: Sendable, Equatable, Hashable {
    case any
    case bundleIdentifier(String)
    case processIdentifier(Int32)
    /// The API's own application resource name, `applications/<sha256>`, derived from the
    /// pid AND the process start time, so it identifies one PROCESS INSTANCE rather than
    /// one application.
    ///
    /// This case exists because that is the name production actually emits. A parser that
    /// expected a pid found nothing in a 64-character hex digest and silently produced a
    /// global scope, which defeated the entire scope column — and the digest is better
    /// than the pid it replaced, because a recycled pid cannot inherit a grant aimed at the
    /// process that used to hold it.
    ///
    /// `resolvedBundleIdentifier` is carried alongside so a grant scoped to an application
    /// the operator NAMED can still cover a request that arrived naming the opaque form,
    /// without making `covers` impure.
    case opaqueApplication(resourceName: String, resolvedBundleIdentifier: String?)

    var isGlobal: Bool {
        if case .any = self {
            return true
        }
        return false
    }

    /// A grant on the opaque form is narrower than any other named target, and that is
    /// deliberate: it names one process instance, not an application.
    var isProcessInstance: Bool {
        if case .opaqueApplication = self {
            return true
        }
        return false
    }

    /// True when a grant scoped to the RECEIVER authorises a request scoped to this.
    /// Every pairing is enumerated, including the three that must NOT match — a grant
    /// on one application never covers a request against another, and a grant on a
    /// bundle identifier never covers a request that named a pid — because a `default`
    /// here would quietly turn "unconsidered" into "allowed".
    var covers: (TargetApplication) -> Bool {
        { other in
            switch (self, other) {
            case (.any, _):
                true
            case let (.bundleIdentifier(granted), .bundleIdentifier(requested)):
                granted == requested
            case let (.processIdentifier(granted), .processIdentifier(requested)):
                granted == requested
            // A grant on the opaque form covers that exact process instance, and the same
            // instance resolved to a bundle — because the resource name is derived from the
            // pid and the start time, so an identical name IS the same process.
            case let (.opaqueApplication(granted, _), .opaqueApplication(requested, _)):
                granted == requested
            case let (.opaqueApplication(_, resolved), .bundleIdentifier(requested)):
                resolved == requested
            // A grant naming a bundle never covers a request that named the opaque form,
            // even though the resolver may know they are the same application: the grant
            // was made for an application and this request named an instance, and the
            // conservative direction is to ask again rather than assume.
            case (.bundleIdentifier, .opaqueApplication):
                false
            // A grant naming one process INSTANCE does not cover a request that named
            // only a pid: the instance is identified by pid AND start time, and a bare pid
            // is exactly the identity a recycled process could present. Refusing here is
            // the conservative direction and costs nothing in practice, because a resolved
            // request derives a bundle scope rather than an opaque one.
            case (.bundleIdentifier, .processIdentifier), (.processIdentifier, .bundleIdentifier),
                 (.bundleIdentifier, .any), (.processIdentifier, .any),
                 (.opaqueApplication, .any),
                 (.processIdentifier, .opaqueApplication),
                 (.opaqueApplication, .processIdentifier):
                false
                // Exhaustiveness is asserted rather than papered over with a `default`, because
                // a `default` here would turn every pairing nobody thought about into "allowed".
                // Adding a case to TargetApplication therefore fails the build until its
                // coverage is decided.
            }
        }
    }
}

enum TargetWindow: Sendable, Equatable, Hashable {
    case any
    case identifier(String)

    /// A grant on one window never covers a request that named none, which is the
    /// pairing that is easiest to leave out and the one that would widen a grant by
    /// accident.
    var covers: (TargetWindow) -> Bool {
        { other in
            switch (self, other) {
            case (.any, _):
                true
            case let (.identifier(granted), .identifier(requested)):
                granted == requested
            case (.identifier, .any):
                false
            }
        }
    }
}

/// What a request is allowed to touch, derived from the request bytes rather than
/// accepted from anything that displays it.
struct AuthorizationScope: Sendable, Equatable, Hashable {
    var application: TargetApplication
    var window: TargetWindow
    /// A transaction declares how many operations it will perform, and exceeding that
    /// count is denied rather than amortised. Nil for everything else.
    var operationLimit: Int?

    init(
        application: TargetApplication = .any,
        window: TargetWindow = .any,
        operationLimit: Int? = nil,
    ) {
        self.application = application
        self.window = window
        self.operationLimit = operationLimit
    }

    var isGlobalPersistent: Bool {
        application.isGlobal && window == .any && operationLimit == nil
    }

    /// A declared count below one is malformed rather than maximally restrictive, and it
    /// is treated as unsatisfiable. It used to satisfy another malformed limit, because
    /// `0 >= 0` is true.
    var isSatisfiableOperationCount: Bool {
        (operationLimit ?? 1) >= 1
    }

    /// Whether a grant carrying THIS scope authorises a request carrying `other`.
    /// Breadth only ever grows downward: a grant may be broader than the request, never
    /// narrower, and a count-bounded grant may not cover an unbounded request.
    func covers(_ other: AuthorizationScope) -> Bool {
        guard application.covers(other.application), window.covers(other.window) else {
            return false
        }
        guard isSatisfiableOperationCount, other.isSatisfiableOperationCount else {
            return false
        }
        return switch (operationLimit, other.operationLimit) {
        case (nil, nil): true
        case let (granted?, requested?): granted >= requested
        // An unbounded grant covers a bounded request; a bounded grant never covers an
        // unbounded one, which is the whole reason a transaction carries a count.
        case (nil, .some): true
        case (.some, nil): false
        }
    }
}

// MARK: - Code identity

enum SignatureState: String, Sendable, Equatable, Hashable, CaseIterable {
    case signedAndValid
    case signedUnnotarized
    case adHoc
    case unsigned
    case invalid
    /// The system could not find out. A different fact from "found out, and it is bad",
    /// and the operator has to be able to tell them apart.
    case unresolved

    /// Signature quality as a multiplier on blast radius. This ESCALATES, and never
    /// denies: an unsigned caller is not rejected, because same-uid malware is
    /// cryptographically indistinguishable from the operator's own agent and a control
    /// claiming otherwise provides false assurance.
    var quality: Double {
        switch self {
        case .signedAndValid: 0.5
        case .signedUnnotarized: 0.7
        case .adHoc: 0.85
        case .unsigned: 1.0
        case .invalid: 1.0
        case .unresolved: 1.0
        }
    }
}

/// What a grant binds to: never a pid, which changes every run.
struct CodeIdentity: Sendable, Equatable, Hashable {
    var executablePath: String
    var bundleIdentifier: String?
    var designatedRequirement: String?
    var signature: SignatureState

    /// The binding a grant stores. A signed caller binds to its designated requirement
    /// and its path; an unsigned one degrades to canonical path identity rather than
    /// becoming unbound, which would let any process claim a grant it cannot prove.
    var binding: CodeBinding {
        CodeBinding(
            executablePath: executablePath,
            bundleIdentifier: bundleIdentifier,
            designatedRequirement: signature == .unsigned || signature == .invalid
                || signature == .unresolved || designatedRequirement?.isEmpty != false
                ? nil : designatedRequirement,
        )
    }
}

struct CodeBinding: Sendable, Equatable, Hashable {
    var executablePath: String
    var bundleIdentifier: String?
    /// An empty requirement is not a requirement. It is rejected at the boundary rather
    /// than compared as a string that happens to match another empty string.
    var designatedRequirement: String?

    /// A later request matches a grant only when the caller's resolved code identity
    /// SATISFIES the binding. A designated requirement, when both sides have one, is the
    /// whole answer; otherwise the pair is matched on bundle identifier and path
    /// together, so a different binary at the same path does not inherit the grant.
    func isSatisfied(by candidate: CodeIdentity) -> Bool {
        let candidateBinding = candidate.binding
        if let required = designatedRequirement {
            // A binding that names a designated requirement can ONLY be satisfied by a
            // signature. Falling through to the path-and-bundle comparison when the
            // candidate offers no requirement meant an unsigned binary at the same path
            // and bundle identifier inherited a grant issued to a signed one — the
            // confused deputy wearing the victim's clothes.
            guard let offered = candidateBinding.designatedRequirement else { return false }
            return required == offered
        }
        // A binding that names a bundle is only satisfied by a candidate that names the
        // SAME bundle at the same path. It used to fall back to the path alone whenever
        // either side lacked a bundle, so a grant held by (path /tmp/x, bundle com.x) was
        // satisfied by a bare binary at /tmp/x with no bundle at all.
        guard let grantedBundle = bundleIdentifier else {
            return executablePath == candidateBinding.executablePath
        }
        guard let offeredBundle = candidateBinding.bundleIdentifier else { return false }
        return grantedBundle == offeredBundle && executablePath == candidateBinding.executablePath
    }
}

/// One process in the caller's ancestry, resolved the same way the peer is.
///
/// The chain exists because the socket peer is the `exactmac` stdio MCP proxy, not the
/// process the operator has in mind: the agent is the peer's PARENT. An identity that names
/// only the peer tells the operator that a binary asked, which is not the decision they are
/// making.
struct ResolvedProcess: Sendable, Equatable, Hashable {
    var processIdentifier: Int32
    var parentProcessIdentifier: Int32?
    var code: CodeIdentity
    /// False when the process exited mid-walk or its path could not be read.
    var isFullyResolved: Bool
}

/// The caller as the system resolved it, which is evidence for the operator's judgement
/// and not an authentication verdict. The boundary was crossed at socket access.
struct CallerIdentity: Sendable, Equatable, Hashable {
    var processIdentifier: Int32
    var effectiveUserIdentifier: uid_t
    var parentProcessIdentifier: Int32?
    var code: CodeIdentity
    /// False when the process exited mid-resolution or its path could not be read. An
    /// unresolved identity RAISES the risk class; it is never trusted and never
    /// special-cased into a denial of its own.
    var isFullyResolved: Bool
    /// Nearest ancestor first. Capped, and a truncated chain says so rather than
    /// pretending it is complete — an unshown process is an unreviewed process.
    var ancestors: [ResolvedProcess] = []
    /// True when the chain hit the depth cap or a cycle, so the prompt can mark the tree
    /// incomplete instead of showing a confident, short tree.
    var isAncestryTruncated: Bool = false
}

// MARK: - Requests, grants, envelopes

struct AuthorizationRequestID: Sendable, Equatable, Hashable {
    let rawValue: String
}

/// The request, as derived from the request bytes. Nothing here is accepted from a
/// client, a console or a prompt: the derivation layer builds it, and the engine treats
/// it as fact precisely because it was never displayed to anyone who could alter it.
struct AuthorizationRequest: Sendable, Equatable {
    var id: AuthorizationRequestID
    var rpcName: String
    var capability: Capability
    var scope: AuthorizationScope
    /// The literal command text for a script, the keys or coordinate for input, the
    /// region for a capture, the target and selector for a read. The prompt's entire
    /// value depends on this being complete and untruncated, so it is a first-class
    /// field rather than something rendered from the raw request later.
    var argumentSummary: String
    /// Required on consent-requiring requests. An unexplained request is one the
    /// operator should decline, so its absence changes what is offered.
    var agentReason: String?
    /// Whether the caller holds a verified, non-ad-hoc signature. Factored out of the
    /// identity so the prompt can show it without the engine inspecting process state.
    var origin: RequestOrigin
}

enum RequestOrigin: Sendable, Equatable {
    /// A direct gRPC caller over the Unix socket.
    case directSocket
    /// The Go MCP layer, which forwards the real caller's identity.
    case mcpProxy
    case unknown
}

/// A permission that already exists. Its subject is CODE IDENTITY and never a pid.
struct Grant: Sendable, Equatable, Hashable {
    var id: String
    var capability: Capability
    var scope: AuthorizationScope
    var duration: GrantDuration
    var holder: CodeBinding
    var issuedAt: MonotonicInstant
    var expiresAt: MonotonicInstant
    /// The request that produced it, because a grant the operator cannot trace to a
    /// decision is a grant they cannot reason about.
    var origin: GrantOrigin
    /// A count-bounded grant: the ergonomic grain between allow-once and
    /// allow-forever, and the one that matches how agents actually work, in loops.
    ///
    /// NOT CONSUMED HERE, and deliberately: `evaluate` takes grants by value, so
    /// decrementing here could not be persisted and consumption is the STORE's job (C5).
    /// What this type guarantees is the ceiling — a grant never authorises more than its
    /// declared count — and the store guarantees the decrement. A count here is therefore
    /// a bound to check, not a counter to advance.
    var remainingOperations: Int?
    /// Whether the target was on the operator's own high-consequence list at issue time.
    var targetIsHighConsequence: Bool

    var isExpired: @Sendable (MonotonicInstant) -> Bool {
        { now in now >= expiresAt }
    }

    /// Whether this grant authorises `request` for `identity` at `now`.
    func authorizes(
        _ request: AuthorizationRequest,
        identity: CallerIdentity,
        now: MonotonicInstant,
    ) -> Bool {
        guard !isExpired(now) else { return false }
        guard capability.implies(request.capability) else { return false }
        guard scope.covers(request.scope) else { return false }
        guard holder.isSatisfied(by: identity.code) else { return false }
        // An unresolved identity cannot be shown to BE the holder, so it inherits
        // nothing. It is not denied for that reason either — refusing every caller whose
        // path could not be read would be verification-as-a-gate, which this product
        // rejects — so it falls through to a prompt with escalated friction instead.
        guard identity.isFullyResolved else { return false }
        if let declared = scope.operationLimit, let requested = request.scope.operationLimit {
            // A count-bounded grant is a consumable: it authorises the request only if
            // enough of its declared count is left, and `declared` is deliberately not
            // compared here — the CALLER's count is the ceiling being checked against
            // what the grant has left.
            guard (remainingOperations ?? 0) >= requested else { return false }
            _ = declared
        }
        return true
    }
}

enum GrantOrigin: Sendable, Equatable, Hashable {
    case prompt(decidedAt: MonotonicInstant)
    case envelope(id: String)
}

/// A declared set of capability-and-scope pairs, valid for a duration, expiring as a
/// unit. Envelopes are how an agent pre-authorizes a long session, so they are a
/// first-class object rather than a bundle of grants: revoking one must revoke all of
/// it immediately, and there must be no way to widen one after the fact.
struct PreAuthorizationEnvelope: Sendable, Equatable, Hashable {
    var id: String
    var grants: [Grant]
    var declaredDuration: GrantDuration
    var expiresAt: MonotonicInstant
    var holder: CodeBinding
    /// Never true, and asserted rather than assumed: an envelope that could become
    /// global-persistent would outlive the session it was granted for.
    var isGlobalPersistent: Bool {
        grants.contains { $0.scope.isGlobalPersistent }
    }

    func authorizes(
        _ request: AuthorizationRequest,
        identity: CallerIdentity,
        now: MonotonicInstant,
    ) -> Bool {
        guard now < expiresAt else { return false }
        guard holder.isSatisfied(by: identity.code), identity.isFullyResolved else { return false }
        return grants.contains { $0.authorizes(request, identity: identity, now: now) }
    }
}

// MARK: - Posture, environment

/// The operator's standing choice. Three, and deliberately no permissive one: a posture
/// that widens what may happen without asking is the vulnerability this product exists
/// to remove, so the third is locked down rather than open.
enum Posture: Sendable, Equatable, Hashable {
    /// Grants and envelopes are ignored; every request that needs consent prompts.
    case strict
    /// Friction scales with blast radius. The default.
    case balanced
    /// Every consent-requiring capability is denied without prompting.
    case lockedDown

    var honoursStandingGrants: Bool {
        self == .balanced
    }
}

/// Everything about the world outside the request that the decision depends on, passed
/// in as values so the engine stays pure and total.
///
/// NAMED AuthorizationContext, not AuthorizationEnvironment, because macOS already has
/// an `AuthorizationEnvironment` in Security.framework and the collision only surfaced
/// in the test target — the server target happens not to import that header. A name that
/// compiles in one target and not another is worse than a long name.
struct AuthorizationContext: Sendable, Equatable {
    enum Transport: Sendable, Equatable {
        /// The supported production mode. Socket access to a 0600 launchd pathname is
        /// the authentication, and the owning user is the authenticating principal.
        case unixSocket
        /// Retained for compatibility, never a production mode. There is no owning user
        /// to authenticate, so there are no approvals and no identity.
        case tcp
    }

    enum BiometricAvailability: Sendable, Equatable {
        case available
        /// No enrolled biometric, locked out, unavailable hardware, or an expired
        /// evaluation. All of them deny; none of them downgrades.
        case unavailable(reason: String)
    }

    enum StoreIntegrity: Sendable, Equatable {
        case intact
        /// An unreadable grant store is not an empty one. Treating it as empty would
        /// turn a corrupt file into a blank slate of permissions.
        case unreadable(reason: String)
    }

    var transport: Transport
    /// False means the consent service could not be reached, so no decision can be
    /// obtained. There is no path from here to allow.
    var isConsoleReachable: Bool
    var peerAuthenticated: Bool
    var biometric: BiometricAvailability
    var store: StoreIntegrity
    /// The operator's own list of applications where consequence is high. Consequence
    /// is a fact about this operator's life, not a property of a taxonomy the product
    /// could ship, so the system escalates exactly where the operator says to.
    var highConsequenceTargets: Set<String>

    static func unixSocket(
        isConsoleReachable: Bool = true,
        peerAuthenticated: Bool = true,
        biometric: BiometricAvailability = .available,
        store: StoreIntegrity = .intact,
        highConsequenceTargets: Set<String> = [],
    ) -> AuthorizationContext {
        AuthorizationContext(
            transport: .unixSocket,
            isConsoleReachable: isConsoleReachable,
            peerAuthenticated: peerAuthenticated,
            biometric: biometric,
            store: store,
            highConsequenceTargets: highConsequenceTargets,
        )
    }
}

// MARK: - Decisions

enum RiskClass: String, Sendable, Equatable, Comparable, CaseIterable {
    case routine
    case elevated
    case high

    private var rank: Int {
        switch self {
        case .routine: 0
        case .elevated: 1
        case .high: 2
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// The product the risk model is built from. Each factor is normalised to 0...1 and the
/// product is the radius, so raising any one of them raises the whole.
struct BlastRadius: Sendable, Equatable, Hashable {
    var capability: Double
    var breadth: Double
    var duration: Double
    var remainingCount: Double
    var targetConsequence: Double
    var signatureQuality: Double

    var radius: Double {
        capability * breadth * duration * remainingCount * targetConsequence * signatureQuality
    }

    /// Thresholds chosen so that all three classes are REACHABLE from the factors the
    /// policy actually produces, and so that the boundary cases the design names land
    /// where it says they should. The previous pair (0.18 / 0.42) was unreachable: with
    /// duration pinned at 0.2 the maximum expressible radius was 0.09, so every decision
    /// was `routine` and the escalation that depends on the radius never fired.
    ///
    /// Every figure below is computed, not asserted, at a SIGNED caller's quality of 0.5,
    /// and each one is reproduced by `testBreadthAndDurationChangeTheAnswer` and
    /// `testEveryRiskClassIsReachable`:
    ///
    ///   clipboard.read,      one application, once ...... 0.005  routine
    ///   clipboard.read,      every application, once .... 0.012  routine
    ///   clipboard.read,      one application, 8 hours ... 0.066  routine
    ///   observation.window,  every application, 8 hours .0.101  elevated
    ///   window.manage,       every application, 8 hours .0.124  elevated
    ///   clipboard.read,      every application, 8 hours .0.146  elevated
    ///   input.synthesize,    every application, 8 hours .0.169  elevated
    ///   observation.ax,      every application, 8 hours .0.180  high
    ///   script.execute,      every application, 8 hours .0.225  high
    ///
    /// So a long global grant of a READ capability reads as Elevated while the same grant
    /// of an observation or execution capability reads as High. Widening any single
    /// factor never lowers the class, which is the property the model has to have: an
    /// unsigned caller takes the 0.146 clipboard grant to 0.293, which is HIGH, and
    /// unsigned AND on a high-consequence application to 0.65, also high.
    var riskClass: RiskClass {
        switch radius {
        case ..<0.10: .routine
        case ..<0.18: .elevated
        default: .high
        }
    }
}

enum BiometricRequirement: Sendable, Hashable {
    case notRequired
    /// Carries why, because the prompt names the single decision the ceremony
    /// authorizes and an unexplained ceremony is not consent to anything in particular.
    case required(reason: String)

    var isRequired: Bool {
        if case .required = self {
            return true
        }
        return false
    }

    /// Nil unless one is required, so a caller cannot read a reason off a requirement
    /// that does not have one.
    var reason: String? {
        guard case let .required(reason) = self else { return nil }
        return reason
    }
}

enum DecisionBasis: Sendable, Equatable {
    /// No consent is required for this capability at all.
    case noConsentRequired
    case grant(id: String)
    case envelope(id: String)
    /// Consent is required and the operator must be asked.
    case promptRequired
    case denied(DenialReason)
}

enum DenialReason: String, Sendable, Equatable, CaseIterable {
    case capabilityRequiresConsent
    case reducedUnauthenticatedPosture
    case unauthenticatedPeer
    case consoleUnreachable
    case grantStoreUnreadable
    case postureLockedDown
    case biometricUnavailable
    case notPermitted
}

/// One thing the operator can say, carrying its own breadth and duration on its face.
/// An operator cannot compare options whose scope is hidden.
struct OfferedDecision: Sendable, Hashable {
    enum Kind: String, Sendable, Equatable, CaseIterable {
        case deny
        case allowOnce
        case allowTargetApplication
        case allowSession
        case preAuthorizeEnvelope
        case allowGlobalPersistent
    }

    var kind: Kind
    var scope: AuthorizationScope
    var duration: GrantDuration
    /// What THIS option would permit, scored on the same six factors as everything else.
    /// The prompt shows it beside the option so the operator is choosing on the numbers
    /// rather than on the option's name — "allow once" and "always allow" differ by
    /// nothing else.
    var blastRadius: BlastRadius
    /// Whether agreeing to THIS option would cost a ceremony. Per option, not per
    /// request: the fingerprint is what a specific grant costs, and a prompt that asked
    /// for one ceremony and then offered an option that needed another would be asking
    /// the operator to guess.
    var biometric: BiometricRequirement
    /// The destructive options are never the default and never sit beside the primary
    /// action; the ordering this array carries is the property, not the set.
    var isDestructive: Bool
    var isDefault: Bool
    var isPrimary: Bool
}

struct AuthorizationDecision: Sendable, Equatable {
    enum Outcome: Sendable, Equatable {
        case allow
        case deny
    }

    var outcome: Outcome
    var basis: DecisionBasis
    /// The request's capability plus everything it transitively carries. On an allow this
    /// states on the record what was permitted; on a denial it states what was ASKED
    /// FOR, which is not the same thing and is not claimed to be.
    var effectiveCapabilities: Set<Capability>
    var blastRadius: BlastRadius
    var riskClass: RiskClass
    var biometric: BiometricRequirement
    /// Populated when, and only when, the basis is `.promptRequired` — a decision that
    /// needs a human. Every hard denial carries none, so nothing a caller could act on
    /// travels back with a refusal.
    var offeredDecisions: [OfferedDecision]
    /// When a standing grant or envelope matched, the instant it stops authorising.
    var expiresAt: MonotonicInstant?

    var isAllowed: Bool {
        outcome == .allow
    }

    var denialReason: DenialReason? {
        guard case let .denied(reason) = basis else { return nil }
        return reason
    }
}
