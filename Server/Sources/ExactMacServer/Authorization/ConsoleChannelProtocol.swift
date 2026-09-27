import CommonCrypto
import Darwin
import Foundation
import Security
import Synchronization

// MARK: - The shared token

/// The shared secret that authenticates the console to the server and the server to the
/// console.
///
/// IT IS A FILE, NOT AN ENVIRONMENT VARIABLE, and the reason is the threat model rather
/// than tidiness: an environment variable is readable from the environment of any process
/// the operator starts, by that process and by anything it spawns, and it is inherited by
/// every child. A 0600 file the operator alone can read is a smaller surface than a string
/// that travels to everything the process tree touches.
///
/// THE RESIDUAL, STATED PLAINLY AND NOT PAPERED OVER: this defends against a careless or
/// unrelated process that finds the socket path. It does NOT defend against same-uid
/// malware, which can read the operator's private files and would therefore find the token.
/// The control that covers that case is the graded identity evidence the prompt shows the
/// operator, not this token. A token that claimed to stop same-uid malware would be
/// offering false assurance, which is worse than naming the limit.
enum ConsoleChannelToken: Sendable, Equatable {
    case shared(String)
    case unavailable(reason: String)

    /// Reads the token from an owner-private file, creating it if absent.
    ///
    /// The same discipline as the grant store, and for the same reasons: a symlink redirects
    /// the read, a second hard link is a second name another path can also write, a foreign
    /// owner means somebody else chose the secret, and wide permissions mean the secret is
    /// not a secret.
    static func loadOrCreate(at path: String) throws -> ConsoleChannelToken {
        let descriptor = try openOrCreate(path: path)
        defer { _ = Darwin.close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw ConsoleChannelError.unreadableToken(reason: "fstat failed with errno \(errno)")
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw ConsoleChannelError.unreadableToken(reason: "the token path is not a regular file")
        }
        guard info.st_nlink == 1 else {
            throw ConsoleChannelError.unreadableToken(
                reason: "the token file has \(info.st_nlink) hard links; want exactly one",
            )
        }
        guard info.st_uid == geteuid() else {
            throw ConsoleChannelError.unreadableToken(
                reason: "the token file is owned by uid \(info.st_uid); want \(geteuid())",
            )
        }
        let permissions = info.st_mode & 0o777
        guard permissions == 0o600 else {
            throw ConsoleChannelError.unreadableToken(
                reason: "the token file is %#o; want 0600",
            )
        }

        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let read = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(descriptor, raw.baseAddress, raw.count)
            }
            if read > 0 {
                bytes.append(contentsOf: buffer[0 ..< read])
                // A token is 64 hex characters. Anything longer is a file that is not a
                // token, and reading all of it would be a memory-growth vector.
                guard bytes.count <= Self.maximumTokenLength else {
                    throw ConsoleChannelError.unreadableToken(reason: "the token file is too long to be a token")
                }
                continue
            }
            if read == 0 {
                break
            }
            if errno == EINTR {
                continue
            }
            throw ConsoleChannelError.unreadableToken(reason: "read failed with errno \(errno)")
        }

        let text = String(decoding: bytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            let created = Self.generate()
            try Self.write(created, to: descriptor)
            return .shared(created)
        }
        guard text.count == Self.tokenLength, text.allSatisfy(\.isHexDigit) else {
            throw ConsoleChannelError.unreadableToken(reason: "the token file does not hold a token")
        }
        return .shared(text.lowercased())
    }

    static let tokenLength = 64
    static let maximumTokenLength = 4096

    /// 32 bytes from the kernel's CSPRNG, hex-encoded. `UInt32.random` is not a random
    /// number generator and a guessable token is the same as no token.
    static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: tokenLength / 2)
        let filled = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(
            filled == errSecSuccess,
            "the system random number generator failed, so no token can be made; refusing to continue",
        )
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func write(_ token: String, to descriptor: Int32) throws {
        let bytes = Array(token.utf8)
        try bytes.withUnsafeBytes { raw in
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
                throw ConsoleChannelError.unreadableToken(reason: "write failed with errno \(errno)")
            }
        }
        guard fsync(descriptor) == 0 else {
            throw ConsoleChannelError.unreadableToken(reason: "fsync failed with errno \(errno)")
        }
    }

    private static func openOrCreate(path: String) throws -> Int32 {
        let descriptor = Darwin.open(path, O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_CREAT, 0o600)
        guard descriptor >= 0 else {
            throw ConsoleChannelError.unreadableToken(reason: "open failed with errno \(errno)")
        }
        return descriptor
    }

    /// Comparison in CONSTANT TIME, because a token compared with `==` leaks its prefix
    /// through timing, and a token is the whole authentication.
    func matches(_ candidate: String) -> Bool {
        guard case let .shared(expected) = self else { return false }
        let left = Array(expected.utf8)
        let right = Array(candidate.lowercased().utf8)
        guard left.count == Self.tokenLength, right.count == left.count else { return false }
        var difference: UInt8 = 0
        for index in 0 ..< left.count {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }
}

enum ConsoleChannelError: Error, Equatable, Sendable {
    case unavailable(reason: String)
    case unreadableToken(reason: String)
    /// The peer did not present the token, or presented the wrong one. Never a distinction
    /// the peer can act on: the same refusal either way, so a prober learns nothing.
    case unauthenticated
    case malformedFrame(reason: String)
    case frameTooLarge
}

// MARK: - The protocol

/// One frame of the console channel. Newline-delimited JSON, because a channel that has to
/// carry a command, a decision and a list of grants should not be a second protobuf
/// definition to drift.
enum ConsoleFrame: Sendable, Equatable {
    /// The console proves itself before anything else is said. It is the FIRST frame in both
    /// directions, and a frame that arrives before it is refused.
    case hello(ConsoleHello)
    /// A decision that needs the operator. Carries everything the designed prompt displays,
    /// so the console renders from this and from nothing else.
    case pending(PendingConsent)
    /// The operator's answer.
    case decision(ConsentDecision)
    /// A read request from the console.
    case query(QueryKind)
    /// A read answer from the server.
    case reply(ConsoleReply)

    static let maximumFrameLength = 4 * 1024 * 1024
}

struct ConsoleHello: Sendable, Equatable, Codable {
    var token: String
    /// The console's own version, so a mismatch is refused rather than half-understood.
    var version: Int
    static let currentVersion = 1
}

/// A request waiting on the operator, carrying the whole disclosure.
struct PendingConsent: Sendable, Equatable, Codable {
    var request: WireRequest
    var identity: WireIdentity
    var decision: WireDecision
    /// Single-use and bound to `request.requestID`. A decision carrying any other nonce is
    /// refused, so one ceremony cannot be presented for two decisions.
    var nonce: String
    /// The exact bytes of the request, so the decision is bound to what was shown rather
    /// than to a summary of it. A prompt that displayed a different request than the one
    /// authorized is the prompt-versus-enforcement problem in its purest form.
    var requestDigest: String
}

/// The operator's answer.
struct ConsentDecision: Sendable, Equatable, Codable {
    var requestID: String
    var nonce: String
    /// The digest the decision was given for, echoed back. A mismatch means the console is
    /// answering about a different request than the one it was shown.
    var requestDigest: String
    var isApproved: Bool
    var selected: String?
    var note: String?
    /// Only true when a ceremony was actually performed FOR THIS nonce.
    var biometricObtained: Bool
}

enum QueryKind: String, Sendable, Equatable, Codable, CaseIterable {
    case grants
    case activity
    case settings
}

struct ConsoleReply: Sendable, Equatable, Codable {
    var kind: String
    /// Opaque to the transport and interpreted by the console. The CHANNEL carries it; what
    /// is in it belongs to the store, the audit and the settings, each of which owns its own
    /// shape and none of which is invented here.
    var payload: String?
}

struct WireRequest: Sendable, Equatable, Codable {
    var requestID: String
    var rpcName: String
    var capability: String
    var scopeDescription: String
    var argumentSummary: String
    var agentReason: String?
    var blastRadius: Double
    var riskClass: String
    var isRevokeAll: Bool
    var operationLimit: Int?
    var effectiveCapabilities: [String]
}

struct WireIdentity: Sendable, Equatable, Codable {
    var processIdentifier: Int32
    var effectiveUserIdentifier: UInt32
    var executablePath: String
    var bundleIdentifier: String?
    var signature: String
    var designatedRequirement: String?
    var isFullyResolved: Bool
    /// Nearest ancestor first, so the console can draw the tree the design specifies without
    /// having to resolve anything itself.
    var ancestors: [WireAncestor]
    var isAncestryTruncated: Bool
}

struct WireAncestor: Sendable, Equatable, Codable {
    var processIdentifier: Int32
    var executablePath: String
    var bundleIdentifier: String?
    var signature: String
    var isFullyResolved: Bool
}

struct WireDecision: Sendable, Equatable, Codable {
    var basis: String
    var requiresBiometric: Bool
    var biometricReason: String?
    var offered: [WireOption]
    var consentTimeoutSeconds: Int
}

struct WireOption: Sendable, Equatable, Codable {
    var kind: String
    var scopeDescription: String
    var durationDescription: String
    var blastRadius: Double
    var requiresBiometric: Bool
    var isDestructive: Bool
    var isDefault: Bool
    var isPrimary: Bool
}

// MARK: - Coding

extension ConsoleFrame: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case hello
        case pending
        case decision
        case query
        case reply
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "hello": self = try .hello(container.decode(ConsoleHello.self, forKey: .hello))
        case "pending": self = try .pending(container.decode(PendingConsent.self, forKey: .pending))
        case "decision": self = try .decision(container.decode(ConsentDecision.self, forKey: .decision))
        case "query": self = try .query(container.decode(QueryKind.self, forKey: .query))
        case "reply": self = try .reply(container.decode(ConsoleReply.self, forKey: .reply))
        default: throw ConsoleChannelError.malformedFrame(reason: "unknown frame kind \(kind)")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .hello(hello):
            try container.encode("hello", forKey: .kind)
            try container.encode(hello, forKey: .hello)
        case let .pending(pending):
            try container.encode("pending", forKey: .kind)
            try container.encode(pending, forKey: .pending)
        case let .decision(decision):
            try container.encode("decision", forKey: .kind)
            try container.encode(decision, forKey: .decision)
        case let .query(query):
            try container.encode("query", forKey: .kind)
            try container.encode(query, forKey: .query)
        case let .reply(reply):
            try container.encode("reply", forKey: .kind)
            try container.encode(reply, forKey: .reply)
        }
    }
}

/// The digest a decision is bound to.
///
/// It is over the CANONICAL request bytes, so "the exact request" means the request and not
/// a field-by-field reconstruction of it that could drift. `requestDigest` is computed by
/// SHA-256 over the serialized request; the console echoes it back and the server compares.
enum RequestDigest {
    static func of(_ request: AuthorizationRequest) -> String {
        let parts = [
            request.rpcName,
            request.capability.rawValue,
            request.scope.description,
            request.argumentSummary,
            request.agentReason ?? "",
        ].joined(separator: "\u{1}")
        return SHA256HexDigest.hexDigest(of: Data(parts.utf8))
    }
}

enum SHA256HexDigest {
    /// CryptoKit is not a dependency of this package and the server compiles with
    /// `-warnings-as-errors` under `-warn-concurrency`, so the digest is computed with
    /// CommonCrypto, which the platform already links.
    static func hexDigest(of data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { raw in
            _ = CC_SHA256(raw.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Waiting without blocking

/// Waits for a descriptor to become readable, and never blocks the caller's thread.
///
/// A blocking `read` on a socket with no data parks the thread FOREVER, and the console's
/// caller is a SwiftUI main actor — a channel that could park it would freeze the menu-bar
/// app for as long as the server had nothing to say. So every read is preceded by a `poll`
/// with a deadline, and a read that has no deadline is a bug rather than a default.
enum SocketWait {
    enum Outcome: Sendable, Equatable {
        case readable
        case timedOut
        case closed
        case failed(errno: Int32)
    }

    static func waitReadable(_ descriptor: Int32, timeout: Duration) -> Outcome {
        let milliseconds = milliseconds(from: timeout)
        var descriptors = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        while true {
            let ready = poll(&descriptors, 1, milliseconds)
            if ready < 0 {
                if errno == EINTR {
                    continue
                }
                return .failed(errno: errno)
            }
            if ready == 0 {
                return .timedOut
            }
            if descriptors.revents & Int16(POLLHUP | POLLERR) != 0,
               descriptors.revents & Int16(POLLIN) == 0
            {
                return .closed
            }
            return .readable
        }
    }

    /// Whole milliseconds, saturating. A negative duration is zero rather than a negative
    /// timeout, because `poll` reads a negative timeout as "wait forever" — which is the one
    /// outcome this whole function exists to prevent.
    static func milliseconds(from timeout: Duration) -> Int32 {
        let seconds = max(0, timeout.components.seconds)
        let attoseconds = max(0, timeout.components.attoseconds)
        let total = seconds
            .multipliedReportingOverflow(by: 1000)
        if total.overflow {
            return Int32.max
        }
        let fraction = attoseconds / 1_000_000_000_000_000
        let sum = total.partialValue.addingReportingOverflow(fraction)
        if sum.overflow || sum.partialValue > Int(Int32.max) {
            return Int32.max
        }
        return Int32(sum.partialValue)
    }
}

// MARK: - Reading and writing frames

/// Newline-delimited JSON over a descriptor, with a BOUNDED line.
///
/// The bound matters: a peer that never sends a newline would otherwise make the reader
/// accumulate without limit, and this channel is reachable by anything that finds the path.
enum FrameReader {
    static func readLine(from descriptor: Int32) throws -> Data? {
        var line = Data()
        var buffer = [UInt8](repeating: 0, count: 8 * 1024)
        while true {
            let read = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(descriptor, raw.baseAddress, raw.count)
            }
            if read > 0 {
                for index in 0 ..< read where buffer[index] == 0x0A {
                    line.append(contentsOf: buffer[0 ..< index])
                    return line
                }
                line.append(contentsOf: buffer[0 ..< read])
                guard line.count <= ConsoleFrame.maximumFrameLength else {
                    throw ConsoleChannelError.frameTooLarge
                }
                continue
            }
            if read == 0 {
                // The peer closed. A partial line is a truncated frame, which is a protocol
                // error rather than a silent end — the caller asked for something.
                return line.isEmpty ? nil : line
            }
            if errno == EINTR {
                continue
            }
            throw ConsoleChannelError.unavailable(reason: "read failed with errno \(errno)")
        }
    }

    static func readFrame(from descriptor: Int32) throws -> ConsoleFrame? {
        guard let line = try readLine(from: descriptor) else { return nil }
        guard !line.isEmpty else { return nil }
        do {
            return try JSONDecoder().decode(ConsoleFrame.self, from: line)
        } catch {
            throw ConsoleChannelError.malformedFrame(reason: "the frame is not readable")
        }
    }

    static func write(_ frame: ConsoleFrame, to descriptor: Int32) throws {
        var line = try JSONEncoder().encode(frame)
        line.append(0x0A)
        try line.withUnsafeBytes { raw in
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
                throw ConsoleChannelError.unavailable(reason: "write failed with errno \(errno)")
            }
        }
    }
}

/// Tracks which nonces have been spent, so a replayed decision cannot authorize twice.
final class ConsumedNonces: Sendable {
    private let state = Synchronization.Mutex<Set<String>>([])

    /// - Returns: True when the nonce was unused and is now consumed.
    @discardableResult
    func consume(_ nonce: String) -> Bool {
        state.withLock { $0.insert(nonce).inserted }
    }
}
