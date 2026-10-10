import Darwin
import Foundation
import os
import Synchronization

/// A permission held in memory.
///
/// THE SUBJECT IS CODE IDENTITY AND NEVER A PID. A pid changes every run, so a grant keyed
/// by one is either useless or — worse — silently inherited by whatever process the kernel
/// hands that number next. Every field here is a property of the BINARY: its path, its
/// bundle, and the designated requirement sealed into its signature.
struct StoredGrant: Codable, Equatable, Sendable {
    var id: String
    var capability: String
    var scope: StoredScope
    /// `once` or a whole number of monotonic seconds.
    var durationSeconds: Int?
    var isOnce: Bool
    var executablePath: String
    var bundleIdentifier: String?
    /// Absent for an unsigned holder, and NOT an empty string: an empty requirement is not
    /// a requirement, and storing one would make the grant satisfiable by anything.
    var designatedRequirement: String?
    var issuedAtNanoseconds: UInt64
    var expiresAtNanoseconds: UInt64
    var originPromptDecidedAtNanoseconds: UInt64?
    var originEnvelopeIdentifier: String?
    var remainingOperations: Int?
    var targetIsHighConsequence: Bool
    /// The request that produced it, verbatim enough for the grants manager to show the
    /// operator what they agreed to and what it was for.
    var originRPCName: String
    var originArgumentSummary: String

    var holder: CodeBinding {
        CodeBinding(
            executablePath: executablePath,
            bundleIdentifier: bundleIdentifier,
            designatedRequirement: designatedRequirement,
        )
    }

    var origin: GrantOrigin {
        if let decided = originPromptDecidedAtNanoseconds {
            return .prompt(decidedAt: MonotonicInstant(nanoseconds: decided))
        }
        return .envelope(id: originEnvelopeIdentifier ?? "")
    }

    func model(issuedAt: MonotonicInstant) -> Grant? {
        guard let capability = Capability(rawValue: capability) else { return nil }
        return Grant(
            id: id,
            capability: capability,
            scope: scope.model(),
            duration: isOnce ? .once : .monotonicSeconds(durationSeconds ?? 0),
            holder: holder,
            issuedAt: issuedAt,
            expiresAt: MonotonicInstant(nanoseconds: expiresAtNanoseconds),
            origin: origin,
            remainingOperations: remainingOperations,
            targetIsHighConsequence: targetIsHighConsequence,
        )
    }

    init(_ grant: Grant) {
        self.id = grant.id
        capability = grant.capability.rawValue
        scope = StoredScope(grant.scope)
        isOnce = grant.duration == .once
        durationSeconds = grant.duration.seconds
        executablePath = grant.holder.executablePath
        bundleIdentifier = grant.holder.bundleIdentifier
        designatedRequirement = grant.holder.designatedRequirement
        issuedAtNanoseconds = grant.issuedAt.nanoseconds
        expiresAtNanoseconds = grant.expiresAt.nanoseconds
        switch grant.origin {
        case let .prompt(decidedAt): originPromptDecidedAtNanoseconds = decidedAt.nanoseconds
        case let .envelope(id): originEnvelopeIdentifier = id
        }
        remainingOperations = grant.remainingOperations
        targetIsHighConsequence = grant.targetIsHighConsequence
        originRPCName = ""
        originArgumentSummary = ""
    }

    /// The origin fields the model does not carry, attached at issue time.
    mutating func attachOrigin(rpcName: String, argumentSummary: String) {
        originRPCName = rpcName
        originArgumentSummary = argumentSummary
    }
}

struct StoredScope: Codable, Equatable, Sendable {
    var application: StoredTarget
    var windowIdentifier: String?
    var operationLimit: Int?

    enum StoredTarget: Codable, Equatable, Sendable {
        case any
        case bundleIdentifier(String)
        case processIdentifier(Int32)
        case opaqueApplication(resourceName: String, resolvedBundleIdentifier: String?)
    }

    init(_ scope: AuthorizationScope) {
        let target: StoredTarget = switch scope.application {
        case .any: .any
        case let .bundleIdentifier(identifier): .bundleIdentifier(identifier)
        case let .processIdentifier(identifier): .processIdentifier(identifier)
        case let .opaqueApplication(name, resolved): .opaqueApplication(
                resourceName: name, resolvedBundleIdentifier: resolved,
            )
        }
        application = target
        windowIdentifier = if case let .identifier(identifier) = scope.window {
            identifier
        } else {
            nil
        }
        operationLimit = scope.operationLimit
    }

    func model() -> AuthorizationScope {
        let target: TargetApplication = switch application {
        case .any: .any
        case let .bundleIdentifier(identifier): .bundleIdentifier(identifier)
        case let .processIdentifier(identifier): .processIdentifier(identifier)
        case let .opaqueApplication(name, resolved): .opaqueApplication(
                resourceName: name,
                resolvedBundleIdentifier: resolved,
            )
        }
        return AuthorizationScope(
            application: target,
            window: windowIdentifier.map(TargetWindow.identifier) ?? .any,
            operationLimit: operationLimit,
        )
    }
}

/// A declared batch, expiring as a unit.
struct StoredEnvelope: Codable, Equatable, Sendable {
    var id: String
    var grants: [StoredGrant]
    var isOnce: Bool
    var declaredDurationSeconds: Int?
    var expiresAtNanoseconds: UInt64
    var executablePath: String
    var bundleIdentifier: String?
    var designatedRequirement: String?

    var holder: CodeBinding {
        CodeBinding(
            executablePath: executablePath,
            bundleIdentifier: bundleIdentifier,
            designatedRequirement: designatedRequirement,
        )
    }
}

/// Everything the store holds in memory.
struct GrantStoreContents: Codable, Equatable, Sendable {
    var grants: [StoredGrant] = []
    var envelopes: [StoredEnvelope] = []
    var sequence: UInt64 = 0
}

/// Why an envelope was refused.
enum EnvelopeValidationFailure: Error, Equatable {
    case globalPersistentScope
    case durationExceedsMaximum(allowed: Int, requested: Int)
    case undeclaredCapability(String)
    case scopeNotRequested(String)
    case empty
}

/// The grant store: issuance, monotonic expiry, consumption, revocation, and envelopes.
///
/// STANDING INVARIANT 12: The console persists no decision state, so there is nothing on
/// disk for a same-uid process to forge. All grants and pre-authorization envelopes are held
/// exclusively in process memory protected by `Synchronization.Mutex<GrantStoreContents>`.
/// When ExactMac restarts, all grants naturally fail-closed and expire.
final class GrantStore: Sendable {
    let clock: any MonotonicClock
    let maximumEnvelopeSeconds: Int
    private let state = Synchronization.Mutex<GrantStoreContents>(GrantStoreContents())
    private let logger = Logger(
        subsystem: "io.github.joeycumines.exactmac",
        category: "authorization.grants",
    )

    init(
        clock: any MonotonicClock,
        maximumEnvelopeSeconds: Int = ServerConfig.defaultMaximumEnvelopeSeconds,
    ) {
        self.clock = clock
        self.maximumEnvelopeSeconds = maximumEnvelopeSeconds
    }

    // MARK: - Reading

    /// The live contents, with expired grants dropped and expired envelopes revoked.
    func liveGrants(now: MonotonicInstant? = nil) -> [Grant] {
        let at = now ?? clock.now()
        return state.withLock { contents in
            contents.grants.compactMap { $0.model(issuedAt: MonotonicInstant(nanoseconds: $0.issuedAtNanoseconds)) }
        }
        .filter { !$0.isExpired(at) && $0.remainingOperations != 0 }
    }

    func liveEnvelopes(now: MonotonicInstant? = nil) -> [PreAuthorizationEnvelope] {
        let at = now ?? clock.now()
        return state.withLock { contents in
            contents.envelopes.compactMap { envelope in
                PreAuthorizationEnvelope(
                    id: envelope.id,
                    grants: envelope.grants.compactMap {
                        $0.model(issuedAt: MonotonicInstant(nanoseconds: $0.issuedAtNanoseconds))
                    },
                    declaredDuration: envelope.isOnce
                        ? .once
                        : .monotonicSeconds(envelope.declaredDurationSeconds ?? 0),
                    expiresAt: MonotonicInstant(nanoseconds: envelope.expiresAtNanoseconds),
                    holder: envelope.holder,
                )
            }
        }
        .filter { $0.expiresAt > at }
    }

    /// What the interceptor hands the engine each request.
    func snapshot() async -> GrantSnapshot {
        let at = clock.now()
        _ = pruneExpired(now: at)
        return GrantSnapshot(
            grants: liveGrants(now: at),
            envelopes: liveEnvelopes(now: at),
            integrity: currentIntegrity(),
        )
    }

    /// In-memory state has no disk corruption mode, returning intact unconditionally.
    func currentIntegrity() -> AuthorizationContext.StoreIntegrity {
        .intact
    }

    /// The grants manager's view: what is held in memory.
    func grantsForDisplay() -> [StoredGrant] {
        state.withLock { $0.grants }
    }

    // MARK: - Issuing

    /// Issues a grant in memory.
    @discardableResult
    func issue(
        capability: Capability,
        scope: AuthorizationScope,
        duration: GrantDuration,
        holder: CallerIdentity,
        now: MonotonicInstant? = nil,
        remainingOperations: Int? = nil,
        origin: GrantOrigin = .prompt(decidedAt: MonotonicInstant(nanoseconds: 0)),
        request: AuthorizationRequest? = nil,
        envelopeIdentifier: String? = nil,
    ) throws -> Grant {
        let at = now ?? clock.now()
        let grant = try Self.makeGrant(
            capability: capability,
            scope: scope,
            duration: duration,
            holder: holder,
            at: at,
            remainingOperations: remainingOperations,
            origin: origin,
            request: request,
            envelopeIdentifier: envelopeIdentifier,
        )
        guard duration != .once else {
            return grant
        }
        state.withLock { contents in
            contents.sequence += 1
            var stored = storedGrant(grant)
            if let request {
                stored.attachOrigin(rpcName: request.rpcName, argumentSummary: request.argumentSummary)
            }
            contents.grants.append(stored)
        }
        return grant
    }

    private static func makeGrant(
        capability: Capability,
        scope: AuthorizationScope,
        duration: GrantDuration,
        holder: CallerIdentity,
        at: MonotonicInstant,
        remainingOperations: Int?,
        origin: GrantOrigin,
        request _: AuthorizationRequest?,
        envelopeIdentifier _: String?,
    ) throws -> Grant {
        guard holder.isFullyResolved else {
            throw GrantIssuanceError.unresolvedHolder
        }
        if let remainingOperations, remainingOperations < 1 {
            throw GrantIssuanceError.nonPositiveOperationCount(remainingOperations)
        }
        let expiry = duration == .once ? at : at.advanced(by: .seconds(duration.seconds ?? 0))
        return Grant(
            id: "grant-\(UUID().uuidString)",
            capability: capability,
            scope: scope,
            duration: duration,
            holder: holder.code.binding,
            issuedAt: at,
            expiresAt: expiry,
            origin: origin,
            remainingOperations: remainingOperations,
            targetIsHighConsequence: false,
        )
    }

    /// Removes expired grants and envelopes from memory.
    @discardableResult
    func pruneExpired(now: MonotonicInstant? = nil) -> Int {
        let at = now ?? clock.now()
        return state.withLock { contents -> Int in
            let before = contents.grants.count
            contents.grants.removeAll { stored in
                MonotonicInstant(nanoseconds: stored.expiresAtNanoseconds) <= at
                    || stored.remainingOperations == 0
            }
            let expiredEnvelopes = contents.envelopes.filter {
                MonotonicInstant(nanoseconds: $0.expiresAtNanoseconds) <= at
            }
            for expired in expiredEnvelopes {
                contents.envelopes.removeAll { $0.id == expired.id }
            }
            let envelopeGrants = Set(contents.envelopes.flatMap { $0.grants.map(\.id) })
            contents.grants.removeAll {
                $0.originEnvelopeIdentifier != nil && !envelopeGrants.contains($0.id)
            }
            return before - contents.grants.count
        }
    }

    // MARK: - Consuming

    /// Spends one operation from a count-bounded grant.
    @discardableResult
    func consume(_ grantIdentifier: String) -> Bool {
        let now = clock.now()
        return state.withLock { contents -> Bool in
            guard let index = contents.grants.firstIndex(where: { $0.id == grantIdentifier }) else {
                return false
            }
            let stored = contents.grants[index]
            guard stored.remainingOperations != nil else { return false }
            guard MonotonicInstant(nanoseconds: stored.expiresAtNanoseconds) > now else { return false }
            let left = (stored.remainingOperations ?? 0) - 1
            guard left > 0 else {
                contents.grants.remove(at: index)
                return true
            }
            contents.grants[index].remainingOperations = left
            return true
        }
    }

    /// Spends a batch from a count-bounded grant.
    @discardableResult
    func consume(_ grantIdentifier: String, operations: Int) -> Bool {
        guard operations >= 1 else { return false }
        let now = clock.now()
        return state.withLock { contents -> Bool in
            guard let index = contents.grants.firstIndex(where: { $0.id == grantIdentifier }) else {
                return false
            }
            let stored = contents.grants[index]
            guard let remaining = stored.remainingOperations, remaining >= operations else {
                return false
            }
            guard MonotonicInstant(nanoseconds: stored.expiresAtNanoseconds) > now else {
                return false
            }
            let left = remaining - operations
            guard left > 0 else {
                contents.grants.remove(at: index)
                return true
            }
            contents.grants[index].remainingOperations = left
            return true
        }
    }

    /// Spends against a grant inside a pre-authorization envelope.
    @discardableResult
    func consumeEnvelope(_ envelopeIdentifier: String, operations: Int) -> Bool {
        guard operations >= 1 else { return false }
        let now = clock.now()
        return state.withLock { contents -> Bool in
            guard let envelopeIndex = contents.envelopes.firstIndex(where: { $0.id == envelopeIdentifier })
            else {
                return false
            }
            for grantIndex in contents.envelopes[envelopeIndex].grants.indices {
                let stored = contents.envelopes[envelopeIndex].grants[grantIndex]
                guard let remaining = stored.remainingOperations, remaining >= operations else {
                    continue
                }
                guard MonotonicInstant(nanoseconds: stored.expiresAtNanoseconds) > now else {
                    continue
                }
                let left = remaining - operations
                if left > 0 {
                    contents.envelopes[envelopeIndex].grants[grantIndex].remainingOperations = left
                } else {
                    contents.envelopes[envelopeIndex].grants.remove(at: grantIndex)
                }
                return true
            }
            return false
        }
    }

    // MARK: - Revoking

    /// Revokes one grant in memory.
    func revoke(_ grantIdentifier: String) {
        state.withLock { contents in
            contents.grants.removeAll { $0.id == grantIdentifier }
            for index in contents.envelopes.indices {
                contents.envelopes[index].grants.removeAll { $0.id == grantIdentifier }
            }
        }
    }

    /// Revokes all standing grants and envelopes in memory.
    func revokeAll() {
        state.withLock { contents in
            contents.grants.removeAll()
            contents.envelopes.removeAll()
        }
    }

    // MARK: - Envelopes

    static func validateEnvelope(
        envelope: PreAuthorizationEnvelope,
        requested: [AuthorizationRequest],
        maximumSeconds: Int,
    ) throws {
        guard !envelope.grants.isEmpty else { throw EnvelopeValidationFailure.empty }
        guard !envelope.isGlobalPersistent else { throw EnvelopeValidationFailure.globalPersistentScope }
        if let seconds = envelope.declaredDuration.seconds, seconds > maximumSeconds {
            throw EnvelopeValidationFailure.durationExceedsMaximum(
                allowed: maximumSeconds,
                requested: seconds,
            )
        }
        for grant in envelope.grants {
            guard requested.contains(where: { $0.capability.implies(grant.capability) }) else {
                throw EnvelopeValidationFailure.undeclaredCapability(grant.capability.rawValue)
            }
            guard requested.contains(where: { $0.scope.covers(grant.scope) }) else {
                throw EnvelopeValidationFailure.scopeNotRequested(grant.scope.description)
            }
        }
    }

    @discardableResult
    func issueEnvelope(
        envelope: PreAuthorizationEnvelope,
        now: MonotonicInstant? = nil,
    ) throws -> PreAuthorizationEnvelope {
        let at = now ?? clock.now()
        state.withLock { contents in
            contents.sequence += 1
            let stored = StoredEnvelope(
                id: envelope.id,
                grants: envelope.grants.compactMap(StoredGrant.init),
                isOnce: envelope.declaredDuration == .once,
                declaredDurationSeconds: envelope.declaredDuration.seconds,
                expiresAtNanoseconds: envelope.expiresAt.nanoseconds,
                executablePath: envelope.holder.executablePath,
                bundleIdentifier: envelope.holder.bundleIdentifier,
                designatedRequirement: envelope.holder.designatedRequirement,
            )
            contents.envelopes.append(stored)
            _ = at
        }
        return envelope
    }

    func revokeEnvelope(_ envelopeIdentifier: String) {
        state.withLock { contents in
            contents.envelopes.removeAll { $0.id == envelopeIdentifier }
            let inside = Set(contents.envelopes.flatMap { $0.grants.map(\.id) })
            contents.grants.removeAll { $0.originEnvelopeIdentifier == envelopeIdentifier && !inside.contains($0.id) }
        }
    }

    // MARK: - Test support

    func persistedContents() -> GrantStoreContents {
        state.withLock { $0 }
    }
}

enum GrantIssuanceError: Error, Equatable {
    case unresolvedHolder
    case nonPositiveOperationCount(Int)
}

public extension AuthorizationScope {
    var description: String {
        let application = switch self.application {
        case .any: "every application"
        case let .bundleIdentifier(identifier): identifier
        case let .processIdentifier(identifier): "pid \(identifier)"
        case let .opaqueApplication(name, _): name
        }
        let window = if case let .identifier(identifier) = self.window {
            " window \(identifier)"
        } else {
            ""
        }
        let count = operationLimit.map { " up to \($0) operations" } ?? ""
        return application + window + count
    }
}

private func storedGrant(_ grant: Grant) -> StoredGrant {
    StoredGrant(grant)
}
