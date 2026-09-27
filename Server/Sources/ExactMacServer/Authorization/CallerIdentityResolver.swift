import Darwin
import Foundation
import os
import Security

// MARK: - Peer evidence

/// What the kernel says about the process on the other end of a connected socket.
///
/// It is a value, and nothing else can produce one, because every source of it is a
/// `getsockopt` on a descriptor the server owns. A pid arriving from request metadata, a
/// header, or the client claiming who it is would be the confused deputy in its most
/// literal form, and a same-uid peer can claim anything.
struct PeerProcessEvidence: Sendable, Equatable, Hashable {
    var processIdentifier: Int32
    var effectiveUserIdentifier: uid_t
}

/// Reads peer evidence from a connected socket descriptor.
///
/// A protocol rather than a direct call, because the descriptor can only be obtained from
/// the transport, and the transport is not required to be able to supply one. A test
/// therefore needs to be able to say "this call arrived with no descriptor" without
/// inventing a socket.
protocol PeerProcessEvidenceReading: Sendable {
    /// - Returns: The peer's pid and uid, or nil when there is no descriptor to ask, or
    ///   the descriptor is not a connected Unix socket.
    func evidence(forFileDescriptor descriptor: Int32) -> PeerProcessEvidence?
}

/// `getsockopt(LOCAL_PEERPID)` and `getpeereid`, and nothing else.
///
/// `LOCAL_PEERPID` is the only kernel answer to "which process is this", and it is the
/// reason a Unix-socket deployment can say anything about its caller at all. The uid comes
/// from `getpeereid` rather than from the pid's own idea of who it is, so a caller that
/// forks between the two calls cannot be reported as the wrong user.
struct SocketPeerProcessEvidence: PeerProcessEvidenceReading {
    func evidence(forFileDescriptor descriptor: Int32) -> PeerProcessEvidence? {
        guard descriptor >= 0 else { return nil }
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.stride)
        let gotPid = withUnsafeMutablePointer(to: &pid) { pointer in
            getsockopt(
                descriptor,
                SOL_LOCAL,
                LOCAL_PEERPID,
                pointer,
                &size,
            )
        }
        guard gotPid == 0, pid > 1 else { return nil }
        var uid = uid_t()
        var gid = gid_t()
        guard getpeereid(descriptor, &uid, &gid) == 0 else { return nil }
        return PeerProcessEvidence(processIdentifier: pid, effectiveUserIdentifier: uid)
    }
}

// MARK: - Process inspection

/// What the process table can be asked, so the resolver's logic is testable against a
/// process table that can be made to contain a cycle, a missing parent and a process that
/// exits mid-walk.
protocol ProcessInspecting: Sendable {
    /// - Returns: The process's resolved code identity, or nil when it is gone or its path
    ///   cannot be read.
    func codeIdentity(processIdentifier: Int32) -> CodeIdentity?
    /// - Returns: The process's parent, or nil when it is gone.
    func parentProcessIdentifier(of processIdentifier: Int32) -> Int32?
}

// MARK: - The resolver

/// Turns kernel evidence about a connected socket into the identity the operator judges.
///
/// IT PRODUCES EVIDENCE, NOT A VERDICT, and the type system is meant to make violating that
/// hard rather than merely discouraged: nothing here can deny anything. `AuthorizationPolicy`
/// reads the signature state and the `isFullyResolved` flag and decides, and the two
/// decisions it reaches are both escalation. An unsigned caller is never rejected, because
/// same-uid malware is cryptographically indistinguishable from the operator's own agent and
/// a control that claimed otherwise would be offering false assurance.
///
/// EXISTENCE IS THE VARIANT GATE. `CallerIdentitySource` has no resolver in its TCP case,
/// so the code path that needs one is not merely unused under a TCP listener — it does not
/// exist to be reached.
struct CallerIdentityResolver: Sendable {
    /// Depth of the ancestry, capped because a real chain runs
    /// Terminal -> login shell -> agent host -> `exactmac`, and `proc_parentpid` will happily
    /// walk a kernel-spawned chain forever. A cap that silently truncated the tree would
    /// present an incomplete picture as a complete one, so the truncation is REPORTED.
    static let defaultMaximumAncestorDepth = 8

    let inspector: any ProcessInspecting
    let maximumAncestorDepth: Int
    private let logger = Logger(
        subsystem: "io.github.joeycumines.exactmac",
        category: "authorization.identity",
    )

    init(
        inspector: any ProcessInspecting,
        maximumAncestorDepth: Int = CallerIdentityResolver.defaultMaximumAncestorDepth,
    ) {
        self.inspector = inspector
        self.maximumAncestorDepth = max(0, maximumAncestorDepth)
    }

    func resolve(_ peer: PeerProcessEvidence) -> CallerIdentity {
        let code = inspector.codeIdentity(processIdentifier: peer.processIdentifier)
        let parent = inspector.parentProcessIdentifier(of: peer.processIdentifier)
        // A pid with no readable path, or one that has already exited, still gets an
        // identity: unresolved with whatever WAS learned, never omitted and never trusted.
        // Omitting it would make an unresolvable caller indistinguishable from no caller,
        // and `isFullyResolved: false` is what escalates it.
        let walk = ancestry(from: parent, startingAfter: peer.processIdentifier)
        let resolved = code != nil
        logger.info(
            """
            Resolved caller pid \(peer.processIdentifier, privacy: .public) \
            uid \(peer.effectiveUserIdentifier, privacy: .public) \
            executable \(code?.executablePath ?? "unresolved", privacy: .private) \
            bundle \(code?.bundleIdentifier ?? "none", privacy: .private) \
            signature \(code?.signature.rawValue ?? "unresolved", privacy: .public) \
            ancestors \(walk.processes.count, privacy: .public) \
            truncated \(walk.isTruncated, privacy: .public) \
            fullyResolved \(resolved, privacy: .public)
            """,
        )
        return CallerIdentity(
            processIdentifier: peer.processIdentifier,
            effectiveUserIdentifier: peer.effectiveUserIdentifier,
            parentProcessIdentifier: parent,
            code: code ?? unresolvedCode(peer.processIdentifier),
            isFullyResolved: resolved,
            ancestors: walk.processes,
            isAncestryTruncated: walk.isTruncated,
        )
    }

    private struct Walk {
        var processes: [ResolvedProcess] = []
        var isTruncated = false
    }

    private func ancestry(from first: Int32?, startingAfter peer: Int32) -> Walk {
        var walk = Walk()
        var seen: Set<Int32> = [peer]
        var cursor = first
        while let pid = cursor {
            // A cycle is a fact about the process table, not an error, and a kernel-spawned
            // chain can present one. Following it forever is the alternative.
            if seen.contains(pid) {
                walk.isTruncated = true
                break
            }
            seen.insert(pid)
            if walk.processes.count >= maximumAncestorDepth {
                walk.isTruncated = true
                break
            }
            let code = inspector.codeIdentity(processIdentifier: pid)
            let parent = inspector.parentProcessIdentifier(of: pid)
            walk.processes.append(
                ResolvedProcess(
                    processIdentifier: pid,
                    parentProcessIdentifier: parent,
                    code: code ?? unresolvedCode(pid),
                    isFullyResolved: code != nil,
                ),
            )
            cursor = parent
        }
        return walk
    }

    /// A placeholder that SAYS it is a placeholder. Its path cannot be satisfied by any real
    /// binary, so no grant can ever bind to it, and its signature state is `unresolved` so it
    /// escalates.
    private func unresolvedCode(_ pid: Int32) -> CodeIdentity {
        CodeIdentity(
            executablePath: "<unresolved pid \(pid)>",
            bundleIdentifier: nil,
            designatedRequirement: nil,
            signature: .unresolved,
        )
    }
}

/// Whether the server can say who is calling, which is a property of the LISTENER and not of
/// a configuration flag.
enum CallerIdentitySource: Sendable {
    /// A Unix-socket listener. The kernel will tell us the peer's pid, so the resolver
    /// exists and identity resolution is available.
    case unixSocket(CallerIdentityResolver)
    /// A TCP listener. There is no authenticating principal — the boundary is a loopback
    /// port, and anything that can open a socket to it is inside — so no resolver is
    /// constructed and the consent path does not exist. Every consent-requiring capability
    /// is denied by `AuthorizationPolicy`, and the health service and the startup log both
    /// say so.
    case unavailableTransport

    /// - Returns: The resolver, or nil because this listener has no authenticating
    ///   principal. The nil is the point: callers must handle it, and they cannot tell the
    ///   difference between "no resolver" and "resolver that found nothing".
    var resolver: CallerIdentityResolver? {
        switch self {
        case let .unixSocket(resolver): resolver
        case .unavailableTransport: nil
        }
    }

    var isIdentityResolutionAvailable: Bool {
        resolver != nil
    }
}

// MARK: - Production process inspection

/// `libproc` and Security.framework. No `NSRunningApplication`: the process table and the
/// kernel are authoritative, and AGENTS.md already records that the AppKit view of a
/// process can lag the Accessibility server.
struct SystemProcessInspector: ProcessInspecting {
    func codeIdentity(processIdentifier: Int32) -> CodeIdentity? {
        guard processIdentifier > 1,
              let path = executablePath(processIdentifier: processIdentifier),
              !path.isEmpty
        else {
            return nil
        }
        let signature = CodeSignature.inspect(executablePath: path)
        return CodeIdentity(
            executablePath: path,
            bundleIdentifier: BundleIdentifierResolver.bundleIdentifier(forExecutable: path),
            designatedRequirement: signature.designatedRequirement,
            signature: signature.state,
        )
    }

    func parentProcessIdentifier(of processIdentifier: Int32) -> Int32? {
        guard processIdentifier > 1 else { return nil }
        var info = proc_bsdinfo()
        let expected = MemoryLayout<proc_bsdinfo>.stride
        let read = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(processIdentifier, PROC_PIDTBSDINFO, 0, pointer, Int32(expected))
        }
        guard read == expected, info.pbi_pid > 1 else { return nil }
        return Int32(info.pbi_ppid)
    }

    private func executablePath(processIdentifier: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Self.maximumExecutablePathLength)
        // `withUnsafeMutableBufferPointer`, NOT `withUnsafeMutablePointer(to:)`. The latter
        // hands out a pointer that is only valid for the duration of the call while the
        // array itself remains live and is read again afterwards; on an array that
        // `proc_pidpath` filled, that read is a segfault. The buffer form pins the array for
        // the duration of the call and is the correct API for "fill this array".
        let length = buffer.withUnsafeMutableBufferPointer { storage in
            proc_pidpath(processIdentifier, storage.baseAddress, UInt32(storage.count))
        }
        guard length > 0 else { return nil }
        let terminated = buffer.prefix(while: { $0 != 0 })
        return String(decoding: terminated.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// `PATH_MAX`. `proc_pidpath` takes the caller's buffer size and this SDK exports no
    /// `PROC_PIDPATHINFO_MAXSIZE`, and a longer path cannot be executed on Darwin anyway.
    private static let maximumExecutablePathLength = 4096
}

/// The bundle identifier of the `.app` a binary lives in, read from that bundle's own
/// Info.plist.
///
/// Walking up from the executable rather than asking `NSRunningApplication` is deliberate:
/// this runs for processes that are not applications at all, and the answer it must give
/// for a bare binary is nil rather than a guess.
enum BundleIdentifierResolver {
    static func bundleIdentifier(forExecutable path: String) -> String? {
        var directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        // A binary can be nested arbitrarily deep inside a bundle, and the bundle is
        // whichever ancestor is named `.app`.
        for _ in 0 ..< 8 {
            if directory.pathExtension == "app",
               let identifier = Bundle(url: directory)?.bundleIdentifier,
               !identifier.isEmpty
            {
                return identifier
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path {
                break
            }
            directory = parent
        }
        return nil
    }
}

/// The code-signature facts, and the states they add up to.
///
/// The order of the questions is the order of what each one rules out, and it is
/// established by running them against real binaries rather than by reading the headers:
/// an ad-hoc signature is VALID, so validity cannot detect it; a validity check without
/// `kSecCSRequirementInformation` does not RETURN the designated requirement, so asking
/// only for signing information silently omits the one thing a grant binds to; and
/// `SecCodeCopySigningInformation` returns a `CFDictionary` that does NOT cast to
/// `[String: Any]`, so a lookup against an empty dictionary reports every binary as having
/// no signature at all.
enum CodeSignature {
    struct Inspection: Sendable, Equatable {
        var state: SignatureState
        var designatedRequirement: String?
    }

    /// `kSecCodeSignatureAdhoc`, which this SDK declares in `CSCommon.h` but does not export
    /// to Swift. Confirmed by measurement: `/bin/ls` reports 0 and a SwiftPM binary
    /// reports 2, which is the only bit separating a real signer from an ad-hoc stamp.
    private static let adHocSignatureFlag: UInt32 = 0x0002

    /// - Returns: The signature state, and the designated requirement in canonical text when
    ///   there is one. Never throws and never traps: an unreadable or unsigned binary is a
    ///   fact to report to the operator, not a failure of the server.
    static func inspect(executablePath path: String) -> Inspection {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            URL(fileURLWithPath: path) as CFURL,
            [],
            &staticCode,
        ) == errSecSuccess,
            let code = staticCode
        else {
            // The path could not even be turned into something to check. That is "could not
            // find out", which is `unresolved` and NOT `unsigned` — the operator has to be
            // able to tell those apart, because one is a gap in the evidence and the other
            // is a fact about the binary.
            return Inspection(state: .unresolved, designatedRequirement: nil)
        }

        // BOTH flags, because the designated requirement is REQUIREMENT information and is
        // simply absent without the second. A grant that stored an empty requirement would
        // then be satisfied by anything, which is the failure `CodeBinding` exists to stop.
        let informationFlags = SecCSFlags(rawValue: kSecCSSigningInformation)
            .union(SecCSFlags(rawValue: kSecCSRequirementInformation))
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, informationFlags, &information) == errSecSuccess,
              let raw = information
        else {
            return Inspection(state: .unsigned, designatedRequirement: nil)
        }
        // Bridged through `NSDictionary`, because `raw as? [String: Any]` fails for a
        // bridged CFDictionary and yields an EMPTY dictionary — a silent, total loss of
        // every signature fact, for every binary, reported as "unsigned".
        let entries = raw as NSDictionary

        // An ad-hoc signature is a real signature with no signer behind it, and it is what
        // an operator's own `swift build` produces, so it is its own state rather than
        // either "signed" or "unsigned". Its requirement text is EMPTY, which is correct: a
        // requirement any process can satisfy is not a requirement, and `CodeBinding` drops
        // an empty one at the boundary.
        if let flags = entries.value(forKey: kSecCodeInfoFlags as String) as? NSNumber,
           flags.uint32Value & adHocSignatureFlag != 0
        {
            return Inspection(state: .adHoc, designatedRequirement: nil)
        }

        var validityError: Unmanaged<CFError>?
        let validity = SecStaticCodeCheckValidityWithErrors(code, [], nil, &validityError)
        defer { validityError?.release() }
        guard validity == errSecSuccess else {
            // `errSecCSUnsigned` is the kernel saying there is no signature at all, which is
            // a different fact from a signature that exists and does not validate.
            if let failure = validityError?.takeUnretainedValue(),
               CFErrorGetCode(failure) == errSecCSUnsigned
            {
                return Inspection(state: .unsigned, designatedRequirement: nil)
            }
            return Inspection(state: .invalid, designatedRequirement: nil)
        }

        // Signed and structurally valid. Notarization is a SEPARATE claim, and the only one
        // a static check can make about the artifact itself is whether a ticket is stapled
        // to it. A Developer ID build with no stapled ticket is the ordinary local case, so
        // it gets its own state rather than being folded into "signed", and the name claims
        // nothing more than was checked.
        let notarized = entries.value(forKey: kSecCodeInfoStapledNotarizationTicket as String) != nil
        return Inspection(
            state: notarized ? .signedAndValid : .signedUnnotarized,
            designatedRequirement: designatedRequirement(entries),
        )
    }

    /// The designated requirement in canonical TEXT, because that is what a grant stores,
    /// compares and shows. `kSecCodeInfoRequirements` carries it as a string
    /// (`designated => identifier "com.apple.ls" and anchor apple`); the
    /// `kSecCodeInfoDesignatedRequirement` key carries an opaque `SecRequirement` object
    /// whose textual form this API does not expose. An empty string is not a requirement and
    /// is dropped at the boundary by `CodeBinding`.
    private static func designatedRequirement(_ entries: NSDictionary) -> String? {
        guard let text = entries.value(forKey: kSecCodeInfoRequirements as String) as? String
        else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
