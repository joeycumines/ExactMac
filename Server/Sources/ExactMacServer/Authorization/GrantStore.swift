import Darwin
import Foundation
import os
import Synchronization

/// A permission that already exists, on disk.
///
/// THE SUBJECT IS CODE IDENTITY AND NEVER A PID. A pid changes every run, so a grant keyed
/// by one is either useless or — worse — silently inherited by whatever process the kernel
/// hands that number next. Every field here is a property of the BINARY: its path, its
/// bundle, and the designated requirement sealed into its signature.
struct StoredGrant: Codable, Equatable, Sendable {
    var id: String
    var capability: String
    var scope: StoredScope
    /// `once` or a whole number of monotonic seconds. A duration in a form that can be
    /// misread as a wall-clock span is a duration a clock change can move.
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
        // A stored capability the model does not know is a file written by a NEWER server.
        // It is dropped rather than guessed at, so a downgrade cannot silently widen.
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

/// Everything the store holds. One file, written whole, because a half-written permission
/// store is worse than an absent one and the whole file is small.
struct GrantStoreContents: Codable, Equatable, Sendable {
    var grants: [StoredGrant] = []
    var envelopes: [StoredEnvelope] = []
    /// The wall-clock time of the boot these monotonic deadlines belong to.
    ///
    /// A monotonic clock does not survive a reboot, so a deadline read back afterwards names
    /// an instant on a timeline that no longer exists. Rather than guess, the store
    /// compares the boot: a store written under a different boot is EXPIRED, in full. That
    /// is the fail-closed direction, and it is why a reboot cannot silently extend a grant.
    var bootWallClockSeconds: Int = 0
    var sequence: UInt64 = 0
}

/// The store's own account of what it could do.
enum GrantStoreError: Error, Equatable {
    case notARegularFile(path: String)
    case tooManyHardLinks(path: String, links: UInt16)
    case foreignOwner(path: String, owner: UInt32)
    case permissionsTooWide(path: String, mode: UInt16)
    case unreadable(path: String, reason: String)
    case notFound(path: String)
}

/// Why an envelope was refused. Each is a distinct operator mistake, and a caller has to be
/// able to tell them apart or the guidance cannot be written.
enum EnvelopeValidationFailure: Error, Equatable {
    case globalPersistentScope
    case durationExceedsMaximum(allowed: Int, requested: Int)
    case undeclaredCapability(String)
    case scopeNotRequested(String)
    case empty
}

/// The grant store: issuance, persistence, expiry, revocation, and envelopes.
///
/// FILE HANDLING IS THE `audit.go` PATTERN, because that is the project's own precedent and
/// it is the right one: `O_NOFOLLOW` so a symlink cannot redirect the write, `O_CLOEXEC` so
/// the descriptor does not leak into a child, a regular file check, EXACTLY ONE hard link so
/// the store cannot be a second name for something else, the effective uid as owner, and
/// 0600. A store that fails any of these is NOT EMPTY, it is UNREADABLE, and unreadable
/// denies everything — because a corrupt file read as an empty one is a blank slate of
/// permissions.
final class GrantStore: Sendable {
    let path: String
    let clock: any MonotonicClock
    let bootWallClockSeconds: Int
    let maximumEnvelopeSeconds: Int
    private let state = Synchronization.Mutex<GrantStoreContents>(GrantStoreContents())
    /// Serializes the whole persist — snapshot, encode, write, fsync — as one unit.
    ///
    /// THE STATE LOCK ALONE WAS NOT ENOUGH, and the failure it allowed was resurrection:
    /// a mutator mutated under `state`, released, and THEN persisted, so a persist could
    /// snapshot state that a concurrent mutator had already changed again and land that
    /// content on disk after the newer content was already written — a revoked grant
    /// back in the file the next boot reads. Snapshot and write are atomic under THIS
    /// lock, so the last write to land is always the snapshot taken last, which is the
    /// state as it stood.
    private let persistenceLock = Synchronization.Mutex<Void>(())
    private let logger = Logger(
        subsystem: "io.github.joeycumines.exactmac",
        category: "authorization.grants",
    )

    init(
        path: String,
        clock: any MonotonicClock,
        bootWallClockSeconds: Int = SystemBoot.wallClockSeconds,
        maximumEnvelopeSeconds: Int = ServerConfig.defaultMaximumEnvelopeSeconds,
    ) {
        self.path = path
        self.clock = clock
        self.bootWallClockSeconds = bootWallClockSeconds
        self.maximumEnvelopeSeconds = maximumEnvelopeSeconds
    }

    // MARK: - Opening

    /// Opens the store, creating it if absent, and refuses anything that is not an
    /// owner-private singly-linked regular file.
    ///
    /// - Returns: A store, or a failure. A failure is not an empty store, and the caller
    ///   must treat it as a denial for every consent-requiring capability.
    static func openStore(
        path: String,
        clock: any MonotonicClock,
        maximumEnvelopeSeconds: Int = ServerConfig.defaultMaximumEnvelopeSeconds,
    ) throws -> GrantStore {
        let store = GrantStore(
            path: path,
            clock: clock,
            maximumEnvelopeSeconds: maximumEnvelopeSeconds,
        )
        try store.load()
        return store
    }

    private func load() throws {
        guard FileManager.default.fileExists(atPath: path) else {
            state.withLock { $0 = GrantStoreContents(bootWallClockSeconds: bootWallClockSeconds) }
            try persist()
            return
        }
        let descriptor = try openHardened()
        defer { Self.closeDescriptor(descriptor) }
        let bytes = try Self.readAll(descriptor: descriptor, path: path)
        guard !bytes.isEmpty else {
            state.withLock { $0 = GrantStoreContents(bootWallClockSeconds: bootWallClockSeconds) }
            return
        }
        let contents: GrantStoreContents
        do {
            contents = try JSONDecoder().decode(GrantStoreContents.self, from: bytes)
        } catch {
            throw GrantStoreError.unreadable(path: path, reason: "the file is not a grant store")
        }
        // A store written under a previous boot is EXPIRED IN FULL. Its deadlines name
        // instants on a monotonic timeline that ended at shutdown, and reading them as if
        // they were live would be the fail-open direction.
        guard contents.bootWallClockSeconds == bootWallClockSeconds else {
            logger.notice(
                "Grant store was written under an earlier boot; every grant in it is expired.",
            )
            state.withLock { $0 = GrantStoreContents(bootWallClockSeconds: bootWallClockSeconds) }
            try persist()
            return
        }
        state.withLock { $0 = contents }
    }

    /// `O_NOFOLLOW | O_CLOEXEC | O_RDWR`, then every property the file must have.
    ///
    /// Each check is on the OPENED DESCRIPTOR and not on the path, so a rename between the
    /// check and the use cannot substitute a different file.
    private func openHardened() throws -> Int32 {
        let descriptor = open(path, O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_CREAT, 0o600)
        guard descriptor >= 0 else {
            throw GrantStoreError.unreadable(path: path, reason: "open failed with errno \(errno)")
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            Self.closeDescriptor(descriptor)
            throw GrantStoreError.unreadable(path: path, reason: "fstat failed with errno \(errno)")
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            Self.closeDescriptor(descriptor)
            throw GrantStoreError.notARegularFile(path: path)
        }
        // EXACTLY one. A second hard link is a second name for the same bytes, which is how
        // a store becomes something a less-privileged path can also write.
        guard info.st_nlink == 1 else {
            Self.closeDescriptor(descriptor)
            throw GrantStoreError.tooManyHardLinks(path: path, links: info.st_nlink)
        }
        guard info.st_uid == geteuid() else {
            Self.closeDescriptor(descriptor)
            throw GrantStoreError.foreignOwner(path: path, owner: info.st_uid)
        }
        let permissions = info.st_mode & 0o777
        guard permissions == 0o600 else {
            Self.closeDescriptor(descriptor)
            throw GrantStoreError.permissionsTooWide(path: path, mode: UInt16(permissions))
        }
        return descriptor
    }

    private static func readAll(descriptor: Int32, path: String) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let read = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(descriptor, raw.baseAddress, raw.count)
            }
            if read > 0 {
                data.append(contentsOf: buffer[0 ..< read])
                continue
            }
            // A short read is an error, not an end: the file must be whole.
            if read == 0 {
                break
            }
            if errno == EINTR {
                continue
            }
            throw GrantStoreError.unreadable(path: path, reason: "read failed with errno \(errno)")
        }
        return data
    }

    private static func closeDescriptor(_ descriptor: Int32) {
        _ = Darwin.close(descriptor)
    }

    // MARK: - Persistence

    private func persist() throws {
        // Snapshot, encode, write and fsync are ONE unit under this lock, or the last
        // writer to land could be carrying stale content — see the declaration above.
        try persistenceLock.withLock { _ in
            let contents = state.withLock { $0 }
            let data = try JSONEncoder().encode(contents)
            // The whole file, written through a fresh hardened descriptor, so a write cannot
            // land in a file that was swapped after the open.
            let descriptor = try openHardened()
            defer { Self.closeDescriptor(descriptor) }
            guard ftruncate(descriptor, 0) == 0 else {
                throw GrantStoreError.unreadable(path: path, reason: "truncate failed with errno \(errno)")
            }
            try data.withUnsafeBytes { raw in
                guard let baseAddress = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(descriptor, baseAddress.advanced(by: offset), raw.count - offset)
                    if written > 0 {
                        offset += written
                        continue
                    }
                    if written < 0, errno == EINTR {
                        continue
                    }
                    throw GrantStoreError.unreadable(path: path, reason: "write failed with errno \(errno)")
                }
            }
            // Durability before the caller is told the grant exists. A grant that is reported
            // and then lost on power failure is a grant the operator believes they revoked.
            guard fsync(descriptor) == 0 else {
                throw GrantStoreError.unreadable(path: path, reason: "fsync failed with errno \(errno)")
            }
        }
    }

    // MARK: - Reading

    /// The live contents, with expired grants dropped and expired envelopes revoked.
    ///
    /// Dropping rather than marking is deliberate: a grant that cannot authorize anything
    /// must not be shown in the grants manager as if it could.
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
    ///
    /// `integrity` IS NOW THE STORE'S ACTUAL INTEGRITY rather than a constant, and it was a
    /// constant for the whole life of this type. `AuthorizationPolicy` has a
    /// `grantStoreUnreadable` denial whose comment reads "A grant store that could not be
    /// read is not an empty one", and it could never fire: this was the only production
    /// `GrantSupply`, it always answered `.intact`, and the interceptor copied that answer
    /// straight into the decision context. The store's own documentation said a failing store
    /// is UNREADABLE AND NOT EMPTY AND THAT UNREADABLE DENIES, and none of those three
    /// sentences was true after startup.
    ///
    /// SO IT RE-READS THROUGH THE SAME HARDENED OPEN `load()` uses. The file is small and
    /// this runs once per request, and the alternative — trusting a validated-once copy in
    /// memory — is what made the claim false: anything that damages the file after startup
    /// would be invisible, and an operator whose store had been replaced with an empty one
    /// would see a silent narrowing of their own permissions rather than a refusal.
    ///
    /// WHAT THIS DOES NOT DO, and the limit is the threat model's rather than the code's:
    /// a same-uid process can WRITE a well-formed store, because the file's owner is the
    /// operator. `risk-same-uid-malware-residual` in threat-model/RISKS.md already declares
    /// that residual accepted. This change makes a store that has become UNREADABLE deny,
    /// which is the claim the code was making and was not keeping.
    func snapshot() async -> GrantSnapshot {
        let at = clock.now()
        // The file is pruned on the read the interceptor performs each request, so a
        // store cannot grow without limit between maintenance points. The prune is
        // best-effort: a store that cannot be written is unreadable, and unreadable
        // denies through `currentIntegrity` rather than through this path.
        _ = try? pruneExpired(now: at)
        return GrantSnapshot(
            grants: liveGrants(now: at),
            envelopes: liveEnvelopes(now: at),
            integrity: currentIntegrity(),
        )
    }

    /// The store's integrity RIGHT NOW, re-verified through the hardened open rather than
    /// remembered from startup.
    private func currentIntegrity() -> AuthorizationContext.StoreIntegrity {
        do {
            let descriptor = try openHardened()
            defer { Self.closeDescriptor(descriptor) }
            let bytes = try Self.readAll(descriptor: descriptor, path: path)
            guard !bytes.isEmpty else { return .intact }
            let contents = try JSONDecoder().decode(GrantStoreContents.self, from: bytes)
            guard contents.bootWallClockSeconds == bootWallClockSeconds else {
                return .unreadable(reason: "the store on disk was written under an earlier boot")
            }
            return .intact
        } catch {
            // The reason is logged, never returned: it carries a filesystem path, and the
            // console is not the place a server-side path belongs.
            logger.notice("Grant store is unreadable and is denying: \(String(describing: error), privacy: .public)")
            return .unreadable(reason: "the grant store could not be read")
        }
    }

    /// The grants manager's view: what is held, by whom, for what, and until when.
    ///
    /// Includes EXPIRED grants, because an operator revoking a session needs to see that it
    /// is already over as well as the ones that are not.
    func grantsForDisplay() -> [StoredGrant] {
        state.withLock { $0.grants }
    }

    // MARK: - Issuing

    /// Issues a grant and persists it before returning.
    ///
    /// - Returns: The issued grant, or the failure. A grant that cannot be persisted is not
    ///   issued, because reporting one the operator cannot rely on is worse than refusing.
    ///
    /// A `.once` grant is NOT persisted: it completes with the request it authorized and
    /// `isExpired` at the instant of issue, so writing it to the file buys nothing and
    /// accumulates one dead entry per approval for the life of the installation. The grant
    /// is still RETURNED — the caller authorizes this request against it — it is just never
    /// stored, because a live store is the only place a once-grant could sit around looking
    /// reusable. The file therefore holds only grants that can authorize a FUTURE request.
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
        try persist()
        return grant
    }

    /// The mapping from a decision to a grant, and the checks a grant must pass to exist.
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
        // A grant to an UNRESOLVED caller can never authorize anything, because
        // `Grant.authorizes` requires a fully resolved identity. Issuing one would let the
        // operator grant a session and get nothing, silently — so it is refused here, where
        // the refusal can be reported, rather than discovered later.
        guard holder.isFullyResolved else {
            throw GrantIssuanceError.unresolvedHolder
        }
        // A count is a CEILING, and a negative or zero one authorizes nothing while looking
        // like a grant.
        if let remainingOperations, remainingOperations < 1 {
            throw GrantIssuanceError.nonPositiveOperationCount(remainingOperations)
        }
        // `.once` completes with the request it authorized and cannot be re-presented, so it
        // is stored with an expiry of "now": a live store is the only place a once-grant
        // could sit around looking reusable.
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

    /// Removes grants that can no longer authorize anything, and persists the result.
    ///
    /// THE ONLY THING THAT GROWS THE FILE IS ISSUANCE, and issuance only stores grants
    /// that outlive the request they authorized — `.once` is never written (see `issue`),
    /// so what accumulates here is time-expired grants and count-exhausted ones. The
    /// sweep is bounded by construction: it visits each entry once and writes the file
    /// once, so a store cannot grow without limit between maintenance points. It is
    /// called on the read paths (`liveGrants`, `snapshot`) rather than on a timer,
    /// because a timer is a background thread with its own lifetime and failure modes,
    /// and the store's own reads are the only moments that provably need it fresh.
    ///
    /// - Returns: The number of entries removed.
    @discardableResult
    func pruneExpired(now: MonotonicInstant? = nil) throws -> Int {
        let at = now ?? clock.now()
        let removed = state.withLock { contents -> Int in
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
        if removed > 0 {
            try persist()
        }
        return removed
    }

    // MARK: - Consuming

    /// Spends one operation from a count-bounded grant.
    ///
    /// The decrement belongs HERE and not in the engine, because `evaluate` takes grants by
    /// value: a count advanced there could not be persisted, so a count-bounded grant would
    /// be unbounded in practice while its type claimed otherwise.
    ///
    /// - Returns: True when the operation was spent, false when the count is already spent.
    ///   False is not an error: a caller that is out of count is simply not authorized, and
    ///   the engine turns that into the refusal it would have produced anyway.
    @discardableResult
    func consume(_ grantIdentifier: String) throws -> Bool {
        let now = clock.now()
        let consumed = state.withLock { contents -> Bool in
            guard let index = contents.grants.firstIndex(where: { $0.id == grantIdentifier }) else {
                return false
            }
            let stored = contents.grants[index]
            guard stored.remainingOperations != nil else { return false }
            guard MonotonicInstant(nanoseconds: stored.expiresAtNanoseconds) > now else { return false }
            let left = (stored.remainingOperations ?? 0) - 1
            guard left > 0 else {
                // Exhausted: the grant is REMOVED rather than left at zero, so the grants
                // manager does not show a permission that authorizes nothing.
                contents.grants.remove(at: index)
                return true
            }
            contents.grants[index].remainingOperations = left
            return true
        }
        if consumed {
            try persist()
        }
        return consumed
    }

    /// Spends a BATCH from a count-bounded grant: the commit or rollback of a transaction
    /// is authorized as a scope with a declared operation count, and this is what makes
    /// the declared count real. The same predicate the engine used to allow the request —
    /// enough remaining, not expired — re-checked under the store's own lock, because the
    /// snapshot the engine judged is already out of date by the time the allow arrives.
    ///
    /// - Returns: False when the grant cannot cover the batch — fewer operations left
    ///   than declared, or it no longer exists. The interceptor refuses on false rather
    ///   than letting the allow stand, which is the fail-closed direction.
    @discardableResult
    func consume(_ grantIdentifier: String, operations: Int) throws -> Bool {
        guard operations >= 1 else { return false }
        let now = clock.now()
        let consumed = state.withLock { contents -> Bool in
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
        if consumed {
            try persist()
        }
        return consumed
    }

    /// The same spend against a grant INSIDE a pre-authorization envelope, which is the
    /// door a count would otherwise stay open through: envelopes are granted as a unit,
    /// and a count-bounded grant that only decrements outside envelopes is a bound with a
    /// hole shaped exactly like the long-running sessions envelopes exist for.
    ///
    /// The envelope's grants are searched in order with the engine's own predicate —
    /// enough remaining, not expired — because the decision carries the envelope's id and
    /// not the inner grant's: the first grant that could have covered the request is the
    /// one that did.
    ///
    /// RECORDED RESIDUAL: the first COULD-HAVE-COVERED grant is not provably the grant
    /// the engine's own match picked — with two count-bounded grants in one envelope, a
    /// spend may land on the other one. The envelope's aggregate remaining count
    /// decreases by exactly the declared amount either way, so no authorization is
    /// extended; what can be wrong is which grant's row shows the decrement. That is
    /// bookkeeping display, not a boundary, and tightening it would mean carrying the
    /// inner grant's id in the decision rather than the envelope's.
    @discardableResult
    func consumeEnvelope(_ envelopeIdentifier: String, operations: Int) throws -> Bool {
        guard operations >= 1 else { return false }
        let now = clock.now()
        let consumed = state.withLock { contents -> Bool in
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
                    // Exhausted: removed, so the grants manager never shows a permission
                    // that authorizes nothing — the same rule `consume` applies.
                    contents.envelopes[envelopeIndex].grants.remove(at: grantIndex)
                }
                return true
            }
            return false
        }
        if consumed {
            try persist()
        }
        return consumed
    }

    // MARK: - Revoking

    /// Revokes one grant. Immediate, and it survives a restart because it is removed.
    func revoke(_ grantIdentifier: String) throws {
        state.withLock { contents in
            contents.grants.removeAll { $0.id == grantIdentifier }
            // A grant inside an envelope is removed from the envelope too, or revoking one
            // would leave it alive inside a batch the grants manager no longer shows.
            for index in contents.envelopes.indices {
                contents.envelopes[index].grants.removeAll { $0.id == grantIdentifier }
            }
        }
        try persist()
    }

    /// Revokes everything. The one operation that always needs a ceremony, and the reason is
    /// in `AuthorizationPolicy.biometricRequirement`.
    func revokeAll() throws {
        state.withLock { contents in
            contents.grants.removeAll()
            contents.envelopes.removeAll()
        }
        try persist()
    }

    // MARK: - Envelopes

    /// Validates a pre-authorization envelope BEFORE it is stored, because an envelope that
    /// is stored and then refused is an envelope the operator was told they had.
    static func validateEnvelope(
        envelope: PreAuthorizationEnvelope,
        requested: [AuthorizationRequest],
        maximumSeconds: Int,
    ) throws {
        guard !envelope.grants.isEmpty else { throw EnvelopeValidationFailure.empty }
        // NEVER global-persistent: an envelope that could become one would outlive the
        // session it was granted for, which is the failure the envelope exists to prevent.
        guard !envelope.isGlobalPersistent else { throw EnvelopeValidationFailure.globalPersistentScope }
        if let seconds = envelope.declaredDuration.seconds, seconds > maximumSeconds {
            throw EnvelopeValidationFailure.durationExceedsMaximum(
                allowed: maximumSeconds,
                requested: seconds,
            )
        }
        // Everything it covers must be something the requester actually asked for. An
        // envelope is a promise about a stated intention, and one that widens beyond it is
        // pre-authorization for something nobody said they wanted.
        for grant in envelope.grants {
            guard requested.contains(where: { $0.capability.implies(grant.capability) }) else {
                throw EnvelopeValidationFailure.undeclaredCapability(grant.capability.rawValue)
            }
            guard requested.contains(where: { $0.scope.covers(grant.scope) }) else {
                throw EnvelopeValidationFailure.scopeNotRequested(grant.scope.description)
            }
        }
    }

    /// Stores a validated envelope, expiring as a unit.
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
        try persist()
        return envelope
    }

    /// Revokes an envelope and everything in it, in one step. "Immediate total revocation"
    /// is a property of this being ONE operation: a caller that could revoke the envelope
    /// and leave its grants behind would have a revocation that is not total.
    func revokeEnvelope(_ envelopeIdentifier: String) throws {
        state.withLock { contents in
            contents.envelopes.removeAll { $0.id == envelopeIdentifier }
            let inside = Set(contents.envelopes.flatMap { $0.grants.map(\.id) })
            contents.grants.removeAll { $0.originEnvelopeIdentifier == envelopeIdentifier && !inside.contains($0.id) }
        }
        try persist()
    }

    // MARK: - Test support

    /// The decoded contents, for a test that must assert what was actually persisted rather
    /// than what the model reconstructed.
    func persistedContents() -> GrantStoreContents {
        state.withLock { $0 }
    }
}

enum GrantIssuanceError: Error, Equatable {
    /// A grant to an unresolved caller can never authorize anything, so it is refused where
    /// the refusal can be reported.
    case unresolvedHolder
    case nonPositiveOperationCount(Int)
}

public extension AuthorizationScope {
    /// A description for an operator-facing error, which must not be empty.
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

/// The wall-clock time the kernel booted, which is what makes a monotonic deadline mean
/// something after a restart.
enum SystemBoot {
    static var wallClockSeconds: Int {
        var info = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &info, &size, nil, 0) == 0 else { return 0 }
        return Int(info.tv_sec)
    }
}

/// The stored form of a grant, which cannot fail for a `Capability` the caller passed in —
/// the raw value came FROM the model, so it is one the model knows.
private func storedGrant(_ grant: Grant) -> StoredGrant {
    StoredGrant(grant)
}
