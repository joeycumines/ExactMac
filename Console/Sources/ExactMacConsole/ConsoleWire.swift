// The wire format of the consent channel, shared with the server.
//
// DUPLICATION, AND IT IS A KNOWN ONE. The server's copy lives in
// `Server/Sources/ExactMacServer/Authorization/ConsoleChannelProtocol.swift`; sharing it
// properly means splitting the server's Authorization sources into a library target, which
// they cannot be today because they reference `PublicRequestDescriptorPolicy`, `RPCError`
// and `ResourceBundleHelper` from the executable target. So the frame format is stated
// twice and the two copies have to agree. What makes that safe rather than merely
// fragile: both sides ENCODE AND DECODE THE SAME SHAPES, so a disagreement is a decode
// failure on a frame that is refused rather than a field that is silently misread — and the
// request digest, which is the one value that must match exactly, is ECHOED by the console
// rather than recomputed, so the two sides cannot compute different ones.

import CommonCrypto
import Darwin
import Foundation
import Security
import Synchronization

// MARK: - The shared token

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
    /// What the capability would TAKE, in the operator's words: "Read the clipboard and its
    /// history". Sent because a prompt cannot derive it — "clipboard.read" is a token, and
    /// what the operator has to picture is the consequence. The engine holds it and nothing
    /// else does.
    var capabilityConsequence: String
    var scopeDescription: String
    var argumentSummary: String
    var agentReason: String?
    var blastRadius: Double
    var riskClass: String
    var isRevokeAll: Bool
    var operationLimit: Int?
    /// The capabilities this grant SILENTLY INCLUDES, beyond the one being asked for. The
    /// engine closes the capability set over implication — a shell can read the screen — so
    /// an operator is entitled to know that before agreeing, and the design draws it.
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

/// The shared token, compared in constant time.
enum ConsoleToken {
    /// - Returns: True when the two tokens are the same. A token compared with `==` leaks
    ///   its prefix through timing, and a token IS the authentication.
    static func matches(_ expected: String, _ candidate: String) -> Bool {
        let left = Array(expected.lowercased().utf8)
        let right = Array(candidate.lowercased().utf8)
        guard !left.isEmpty, left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in 0 ..< left.count {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }
}

extension ConsoleReply {
    /// The count a list reply carries, when it carries one. A menu row's detail column is
    /// COMPUTED from the text rather than guessed, and it is optional per row.
    var count: Int? {
        guard kind == "grants" || kind == "activity" else { return nil }
        guard let payload else { return nil }
        return Int(payload.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: - The console's own copy of the decision vocabulary

/// Why a ceremony could not be performed.
///
/// EVERY CASE DENIES. They are distinct because the operator needs to know which happened:
/// "no biometric is enrolled" is fixable in System Settings, "the console is not frontmost"
/// is a bug in the console, and one opaque "biometric failed" makes them the same.
///
/// THE SERVER HAS ITS OWN COPY, for the same reason it has its own copy of the wire format:
/// the authorization types are not a library the console can import today. They are two
/// enumerations of the same taxonomy rather than one shared type, and the two have to agree
/// — the reason strings the server shows and the ones the console shows are the same words.
enum BiometricFailure: Error, Equatable, Sendable {
    case noEnrolment
    case hardwareUnavailable
    case lockedOut
    case cancelled
    case passcodeNotSet
    case consoleNotFrontmost
    case unavailable(reason: String)

    /// The product's own words, which are what the prompt shows beside the sensor.
    var explanation: String {
        switch self {
        case .noEnrolment: "no biometric is enrolled on this Mac"
        case .hardwareUnavailable: "this Mac cannot perform a biometric check"
        case .lockedOut: "the biometric sensor is locked out after too many attempts"
        case .cancelled: "the check was cancelled"
        case .passcodeNotSet: "no passcode is set, so presence cannot be proven"
        case .consoleNotFrontmost: "the console was not frontmost, so the check could not be shown"
        case let .unavailable(reason): reason
        }
    }
}

/// The request a decision belongs to, on the console side.
struct AuthorizationRequestID: Hashable, Sendable, CustomStringConvertible {
    let rawValue: String
    var description: String {
        rawValue
    }
}
