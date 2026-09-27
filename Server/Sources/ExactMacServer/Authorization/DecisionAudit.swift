import Darwin
import Foundation
import os

/// One decision, recorded.
///
/// SERVER-SIDE AND AUTHORITATIVE, because the Go layer's `MCP_AUDIT_LOG_FILE` is
/// metadata-only and on the wrong side of the privilege boundary: a caller that the server
/// authorizes can write that log, so it cannot be the record the operator reads to find out
/// what was allowed.
///
/// EVERY FIELD HERE IS WHAT THE OPERATOR WOULD NEED TO JUDGE IT AFTERWARDS, which is the
/// test for a field belonging in the record at all.
struct AuditEntry: Codable, Equatable, Sendable {
    /// Monotonic, from 1. A gap is a removal, and that is the property the sequence carries.
    var sequence: UInt64
    /// Monotonic nanoseconds, so a wall-clock change cannot reorder or hide the record.
    var occurredAtNanoseconds: UInt64
    /// Wall clock, for the operator to read, and never for ordering.
    var wallClockSeconds: Int
    /// Which boot the monotonic timestamps belong to, so a record from a previous boot is
    /// marked rather than silently compared.
    var bootWallClockSeconds: Int
    /// The previous entry's hash. This is the chain.
    var previousHash: String
    /// Over the previous hash and this entry's own content, so editing ANY field changes
    /// this value and therefore every entry after it.
    var hash: String

    // MARK: What was asked

    var requestID: String
    var rpcName: String
    var capability: String
    var scopeDescription: String
    var argumentSummary: String
    /// The agent's own words. An unexplained request is one the operator should decline, so
    /// whether one was given is part of the record.
    var agentReason: String?

    // MARK: Who asked, as resolved AT DECISION TIME

    var identity: WireIdentity

    // MARK: What was decided, and WHY

    /// `allow`, `deny`, or `prompt`.
    var decision: String
    /// WHICH GRANT MATCHED, or that it came from an interactive prompt, or from an
    /// envelope, or that it was refused and why. Not merely the decision: a log that says
    /// "allowed" without saying on what basis cannot answer the question the operator
    /// actually has, which is "who decided this and when".
    var basis: String
    var grantIdentifier: String?
    var grantExpiresAtNanoseconds: UInt64?
    var envelopeIdentifier: String?
    var biometricRequired: Bool
    var biometricObtained: Bool
    /// What the operator typed back, which is the only place their reasoning exists.
    var operatorNote: String?

    /// The canonical bytes the hash is taken over.
    ///
    /// HASHED EXCLUDE `hash` and INCLUDE `previousHash`, and the reason is that a chain
    /// which did not include the previous hash would let an attacker rewrite every entry
    /// independently. `JSONEncoder` with SORTED KEYS, because the field order of a
    /// dictionary is not a property anyone should depend on.
    func digestPayload() -> Data {
        var copy = self
        copy.hash = ""
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(copy)) ?? Data()
    }

    /// Recomputes this entry's hash from its own content and its declared predecessor.
    func recomputedHash(previous: String) -> String {
        var copy = self
        copy.previousHash = previous
        copy.hash = ""
        return SHA256HexDigest.hexDigest(of: copy.digestPayload())
    }

    static func genesisHash(birth: String) -> String {
        SHA256HexDigest.hexDigest(of: Data("exactmac-audit-genesis:\(birth)".utf8))
    }
}

/// What verifying the log found.
struct AuditVerification: Sendable, Equatable {
    var entryCount: Int
    var isIntact: Bool
    /// The sequence number of the first entry whose hash or sequence is wrong, or nil when
    /// the whole log verified.
    var firstBrokenSequence: UInt64?
    /// What was wrong about it, so a verifier can say "edited" rather than merely "bad".
    var defect: Defect?

    enum Defect: Sendable, Equatable {
        /// The entry's own content does not match its hash: it was EDITED.
        case edited(sequence: UInt64)
        /// The entry names a different predecessor than the previous entry's hash: a removal
        /// or a reordering happened somewhere before it.
        case brokenChain(sequence: UInt64)
        /// The sequence skipped, or went backwards.
        case sequenceGap(sequence: UInt64, expected: UInt64)
        /// The log was written under a different boot, so its monotonic stamps are on a
        /// timeline that has ended.
        case writtenUnderAnotherBoot
        /// The final line is incomplete — a crash mid-write, or an editor that truncated it.
        /// That is NOT tampering: the chain over the entries that are whole still verifies,
        /// and the reader must not lose them.
        case incompleteFinalLine
    }
}

/// The decision audit: append-only, hash-chained, server-side.
///
/// WHAT THE CHAIN DETECTS, STATED PRECISELY BECAUSE IT IS NOT EVERYTHING. Editing any
/// field of any entry changes that entry's hash and therefore every entry after it, so
/// in-place editing is detected at the first edited entry. Removing an entry from the
/// middle leaves the next entry naming a predecessor that is no longer there, which is
/// detected too. REMOVING THE LAST ENTRY IS NOT DETECTED by anything in this file: a
/// same-uid attacker who can truncate can also edit the sequence numbers, and a claim that
/// the tail is protected would be false. What the chain does buy is that silent tampering
/// requires re-deriving every subsequent hash, so a cheap edit is a detectable one. That
/// limit is stated here rather than glossed, and the same limit is what the threat model
/// records as accepted residual.
final class DecisionAudit: @unchecked Sendable {
    let path: String
    private let clock: any MonotonicClock
    private let bootWallClockSeconds: Int
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var nextSequence: UInt64 = 1
    private var lastHash: String
    private let logger = Logger(
        subsystem: "io.github.joeycumines.exactmac",
        category: "authorization.audit",
    )
    /// The socket path is a birth record, not a secret: it distinguishes one installation's
    /// audit from another's when they are read together.
    private let birth: String

    init(
        path: String,
        clock: any MonotonicClock,
        bootWallClockSeconds: Int = SystemBoot.wallClockSeconds,
        birth: String = UUID().uuidString,
    ) throws {
        self.path = path
        self.clock = clock
        self.bootWallClockSeconds = bootWallClockSeconds
        self.birth = birth
        self.lastHash = AuditEntry.genesisHash(birth: birth)
        try openAndRecover()
    }

    deinit {
        if descriptor >= 0 {
            _ = Darwin.close(descriptor)
        }
    }

    /// Opens the log and reads far enough to continue the chain where it left off.
    ///
    /// A log whose FINAL LINE IS INCOMPLETE is truncated to the last whole entry and
    /// appended to, because a half-written line is a crash and not tampering — and losing
    /// every entry after it would be a worse outcome than the one it prevents.
    private func openAndRecover() throws {
        let opened = Darwin.open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard opened >= 0 else {
            throw AuditError.unreadable(reason: "open failed with errno \(errno)")
        }
        var info = stat()
        guard fstat(opened, &info) == 0 else {
            Darwin.close(opened)
            throw AuditError.unreadable(reason: "fstat failed with errno \(errno)")
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(opened)
            throw AuditError.notARegularFile
        }
        guard info.st_nlink == 1 else {
            Darwin.close(opened)
            throw AuditError.tooManyHardLinks(info.st_nlink)
        }
        guard info.st_uid == geteuid() else {
            Darwin.close(opened)
            throw AuditError.foreignOwner(info.st_uid)
        }
        guard info.st_mode & 0o777 == 0o600 else {
            Darwin.close(opened)
            throw AuditError.permissionsTooWide(info.st_mode & 0o777)
        }
        descriptor = opened

        let readBack = try AuditEntry.readAll(from: path)
        for entry in readBack.whole {
            nextSequence = entry.sequence &+ 1
            lastHash = entry.hash
        }
        if readBack.hadIncompleteFinalLine {
            // Truncate the partial line so the next append starts on a boundary, and say so.
            logger.notice("The audit log ended in a partial line; it was dropped and the log continues.")
            try truncateToWholeEntries(readBack.whole)
        }
    }

    private func truncateToWholeEntries(_ entries: [AuditEntry]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var body = Data()
        for entry in entries {
            var line = try encoder.encode(entry)
            line.append(0x0A)
            body.append(line)
        }
        let temporary = path + ".recovered"
        let scratch = Darwin.open(
            temporary, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0o600,
        )
        guard scratch >= 0 else {
            throw AuditError.unreadable(reason: "could not open the recovery file")
        }
        defer { _ = Darwin.close(scratch) }
        try AuditEntry.writeAll(body, to: scratch)
        guard rename(temporary, path) == 0 else {
            unlink(temporary)
            throw AuditError.unreadable(reason: "could not replace the log with its recovery")
        }
        // The append descriptor still points at the old inode, so it has to be reopened.
        _ = Darwin.close(descriptor)
        descriptor = Darwin.open(path, O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw AuditError.unreadable(reason: "could not reopen the recovered log")
        }
    }

    /// Records a decision. The hash is computed and the line appended under one lock, so two
    /// concurrent decisions cannot interleave into a broken chain.
    @discardableResult
    func record(
        request: AuthorizationRequest,
        identity: CallerIdentity,
        decision: AuthorizationDecision,
        operatorNote: String? = nil,
        biometricObtained: Bool = false,
        // The expiry of the grant that authorized this, recorded IN THE ENTRY at the moment
        // the entry is written. There is deliberately no way to add it later: a hash-chained
        // record whose entries can be edited after the fact is not a chain.
        grantExpiresAtNanoseconds: UInt64? = nil,
    ) -> AuditEntry? {
        lock.withLock { () -> AuditEntry? in
            let previous = lastHash
            let sequence = nextSequence
            var entry = AuditEntry(
                sequence: sequence,
                occurredAtNanoseconds: clock.now().nanoseconds,
                wallClockSeconds: Int(Date().timeIntervalSince1970),
                bootWallClockSeconds: bootWallClockSeconds,
                previousHash: previous,
                hash: "",
                requestID: request.id.rawValue,
                rpcName: request.rpcName,
                capability: request.capability.rawValue,
                scopeDescription: request.scope.description,
                argumentSummary: request.argumentSummary,
                agentReason: request.agentReason,
                identity: WireIdentity(
                    processIdentifier: identity.processIdentifier,
                    effectiveUserIdentifier: identity.effectiveUserIdentifier,
                    executablePath: identity.code.executablePath,
                    bundleIdentifier: identity.code.bundleIdentifier,
                    signature: identity.code.signature.rawValue,
                    designatedRequirement: identity.code.designatedRequirement,
                    isFullyResolved: identity.isFullyResolved,
                    ancestors: identity.ancestors.map {
                        WireAncestor(
                            processIdentifier: $0.processIdentifier,
                            executablePath: $0.code.executablePath,
                            bundleIdentifier: $0.code.bundleIdentifier,
                            signature: $0.code.signature.rawValue,
                            isFullyResolved: $0.isFullyResolved,
                        )
                    },
                    isAncestryTruncated: identity.isAncestryTruncated,
                ),
                decision: decision.outcome == .allow ? "allow" : "deny",
                basis: DecisionAudit.describe(decision.basis),
                grantIdentifier: nil,
                grantExpiresAtNanoseconds: grantExpiresAtNanoseconds,
                envelopeIdentifier: nil,
                biometricRequired: decision.biometric.reason != nil,
                biometricObtained: biometricObtained,
                operatorNote: operatorNote,
            )
            switch decision.basis {
            case let .grant(identifier):
                entry.grantIdentifier = identifier
            case let .envelope(identifier):
                entry.envelopeIdentifier = identifier
            case .noConsentRequired, .promptRequired, .denied:
                break
            }
            entry.hash = entry.recomputedHash(previous: previous)
            do {
                var line = try JSONEncoder().encode(entry)
                line.append(0x0A)
                try AuditEntry.writeAll(line, to: descriptor)
                _ = fsync(descriptor)
            } catch {
                // A decision that cannot be recorded has still been made. Returning nil says
                // so, and the caller decides — silently returning an entry that is not on
                // disk would be a record that does not exist.
                logger.error("The audit entry could not be written: \(error.localizedDescription, privacy: .public)")
                return nil
            }
            nextSequence = sequence &+ 1
            lastHash = entry.hash
            return entry
        }
    }

    /// Reads the whole log and says what is wrong with it.
    ///
    /// A final line that is not a complete JSON object is reported as
    /// `.incompleteFinalLine` and the entries before it are still returned, because the
    /// console renders Activity from this and must not lose a day of history to a crash
    /// during one append.
    func verify() -> AuditVerification {
        let readBack = (try? AuditEntry.readAll(from: path))
            ?? AuditEntry.ReadBack(whole: [], hadIncompleteFinalLine: false)
        var previous = AuditEntry.genesisHash(birth: birth)
        var expectedSequence: UInt64 = 1
        for entry in readBack.whole {
            if entry.sequence != expectedSequence {
                return AuditVerification(
                    entryCount: readBack.whole.count,
                    isIntact: false,
                    firstBrokenSequence: entry.sequence,
                    defect: .sequenceGap(sequence: entry.sequence, expected: expectedSequence),
                )
            }
            if entry.previousHash != previous {
                return AuditVerification(
                    entryCount: readBack.whole.count,
                    isIntact: false,
                    firstBrokenSequence: entry.sequence,
                    defect: .brokenChain(sequence: entry.sequence),
                )
            }
            if entry.hash != entry.recomputedHash(previous: previous) {
                return AuditVerification(
                    entryCount: readBack.whole.count,
                    isIntact: false,
                    firstBrokenSequence: entry.sequence,
                    defect: .edited(sequence: entry.sequence),
                )
            }
            if entry.bootWallClockSeconds != bootWallClockSeconds {
                return AuditVerification(
                    entryCount: readBack.whole.count,
                    isIntact: false,
                    firstBrokenSequence: entry.sequence,
                    defect: .writtenUnderAnotherBoot,
                )
            }
            previous = entry.hash
            expectedSequence &+= 1
        }
        return AuditVerification(
            entryCount: readBack.whole.count,
            isIntact: true,
            firstBrokenSequence: nil,
            defect: readBack.hadIncompleteFinalLine ? .incompleteFinalLine : nil,
        )
    }

    /// The basis as it appears on the face of the record. A test reads it, so a kind that
    /// rendered the same as another would be caught.
    static func describe(_ basis: DecisionBasis) -> String {
        switch basis {
        case .noConsentRequired: "noConsentRequired"
        case let .grant(identifier): "grant:\(identifier)"
        case let .envelope(identifier): "envelope:\(identifier)"
        case .promptRequired: "promptRequired"
        case let .denied(reason): "denied:\(reason.rawValue)"
        }
    }
}

enum AuditError: Error, Equatable, Sendable {
    case notARegularFile
    case tooManyHardLinks(UInt16)
    case foreignOwner(UInt32)
    case permissionsTooWide(UInt16)
    case unreadable(reason: String)
}

extension AuditEntry {
    struct ReadBack: Sendable {
        var whole: [AuditEntry]
        var hadIncompleteFinalLine: Bool
    }

    static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0, errno == EINTR {
                    continue
                }
                throw AuditError.unreadable(reason: "write failed with errno \(errno)")
            }
        }
    }

    /// The whole log, with a partially written final line reported rather than discarded.
    static func readAll(from path: String) throws -> ReadBack {
        let reader = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? reader.close() }
        let data = try reader.readToEnd() ?? Data()

        var entries: [AuditEntry] = []
        var incomplete = false
        var start = data.startIndex
        let decoder = JSONDecoder()
        while start < data.endIndex {
            guard let newline = data[start...].firstIndex(of: 0x0A) else {
                // No terminator: the append was interrupted. Whatever is here is not an
                // entry, and pretending otherwise would put a half-record in the timeline.
                incomplete = !data[start...].isEmpty
                break
            }
            let line = data[start ..< newline]
            start = data.index(after: newline)
            guard !line.isEmpty else { continue }
            if let entry = try? decoder.decode(AuditEntry.self, from: Data(line)) {
                entries.append(entry)
            } else {
                incomplete = true
            }
        }
        return ReadBack(whole: entries, hadIncompleteFinalLine: incomplete)
    }
}
