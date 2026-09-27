import Darwin
@testable import ExactMacServer
import Foundation
import XCTest

/// C3's acceptance suite.
///
/// THE FIRST TEST IS THE ONE THAT MATTERS MOST, and it is the only one that can be faked:
/// it stands up a real connected Unix socket pair, asks the real `getsockopt` for the peer,
/// and resolves the result with the real `libproc` and Security.framework path. Everything
/// else here can be satisfied by a stub, which is exactly why the stubbed tests are for
/// process tables the kernel will not produce — a cycle, a chain deeper than the cap — and
/// not for the ordinary case.
final class CallerIdentityResolverTests: XCTestCase {
    // MARK: - The evidence primitive, against a real socket

    /// A connected AF_UNIX socket pair, and this test process is genuinely the other end of
    /// one of them. If `getsockopt(LOCAL_PEERPID)` were being faked anywhere, this would
    /// notice.
    func testTheKernelNamesThisProcessAsThePeerOfARealConnectedSocket() throws {
        var descriptors: [Int32] = [-1, -1]
        let made = descriptors.withUnsafeMutableBufferPointer { buffer in
            socketpair(AF_UNIX, SOCK_STREAM, 0, buffer.baseAddress!)
        }
        XCTAssertEqual(made, 0, "socketpair failed: \(errno)")
        defer {
            for descriptor in descriptors where descriptor >= 0 {
                close(descriptor)
            }
        }

        let evidence = try XCTUnwrap(
            SocketPeerProcessEvidence().evidence(forFileDescriptor: descriptors[0]),
            "a connected Unix socket did not yield peer evidence",
        )
        XCTAssertEqual(evidence.processIdentifier, getpid(), "the peer of our own socket is us")
        XCTAssertEqual(evidence.effectiveUserIdentifier, geteuid())
    }

    /// A descriptor that is not a connected Unix socket yields nothing, and the caller has
    /// to handle that. It is the same shape as "the transport could not give us a
    /// descriptor", which is the state C4 has to survive.
    func testNoDescriptorMeansNoEvidence() {
        XCTAssertNil(SocketPeerProcessEvidence().evidence(forFileDescriptor: -1))
        let stdio = dup(STDIN_FILENO)
        defer { close(stdio) }
        XCTAssertNil(
            SocketPeerProcessEvidence().evidence(forFileDescriptor: stdio),
            "a non-socket descriptor must not be reported as peer evidence",
        )
    }

    /// A complete identity for a real process, with the real path, the real signature state
    /// and a real designated requirement where one exists.
    func testARealProcessResolvesToACompleteIdentity() throws {
        var descriptors: [Int32] = [-1, -1]
        let made = descriptors.withUnsafeMutableBufferPointer { buffer in
            socketpair(AF_UNIX, SOCK_STREAM, 0, buffer.baseAddress!)
        }
        XCTAssertEqual(made, 0, "socketpair failed: \(errno)")
        defer {
            for descriptor in descriptors where descriptor >= 0 {
                close(descriptor)
            }
        }
        let evidence = try XCTUnwrap(
            SocketPeerProcessEvidence().evidence(forFileDescriptor: descriptors[0]),
        )
        let identity = CallerIdentityResolver(inspector: SystemProcessInspector()).resolve(evidence)

        XCTAssertEqual(identity.processIdentifier, getpid())
        XCTAssertEqual(identity.effectiveUserIdentifier, geteuid())
        XCTAssertTrue(identity.isFullyResolved, "this process's path is readable")
        XCTAssertTrue(
            identity.code.executablePath.hasSuffix("xctest")
                || identity.code.executablePath.hasSuffix("swift-testing"),
            "the resolved path should be this test host: \(identity.code.executablePath)",
        )
        // A REAL state, not "some state": `SignatureState.allCases.contains(x)` is true for
        // every value the type can hold, so it asserted the type system rather than the
        // resolver. The SwiftPM test host is ad-hoc signed, and that is checkable.
        XCTAssertEqual(
            identity.code.signature, .adHoc,
            "a SwiftPM-built test host is ad-hoc signed, and that is the state it reports",
        )
        // Its requirement text is EMPTY — so the grant must not be able to bind to it.
        // Asserting the empty case is the point: an empty requirement that got stored would
        // be satisfied by anything.
        if identity.code.signature == .adHoc {
            XCTAssertNil(identity.code.designatedRequirement)
            XCTAssertNil(identity.code.binding.designatedRequirement)
        } else {
            XCTAssertNotNil(identity.code.designatedRequirement)
        }
        XCTAssertGreaterThan(identity.ancestors.count, 0, "a real process has a real ancestry")
    }

    // MARK: - The cases the kernel will not produce on demand

    /// A process that has exited. Its pid is now a number with nothing behind it, and the
    /// identity must SAY so rather than being omitted — an omitted identity is
    /// indistinguishable from no caller at all.
    ///
    /// The pid is CHOSEN rather than taken from a process that just exited, because a pid
    /// freed by one process is reused by the next within milliseconds on a busy machine, and
    /// a test that resolves a recycled pid passes or fails at random. This asks the kernel
    /// for a pid nothing holds.
    func testAProcessThatHasExitedResolvesToAnUnmarkedButUnresolvedIdentity() throws {
        let pid = try XCTUnwrap(Self.anUnusedProcessIdentifier())
        XCTAssertEqual(kill(pid, 0), -1, "the chosen pid must not be live")
        XCTAssertEqual(errno, ESRCH)

        let identity = CallerIdentityResolver(inspector: SystemProcessInspector()).resolve(
            PeerProcessEvidence(processIdentifier: pid, effectiveUserIdentifier: geteuid()),
        )
        XCTAssertFalse(
            identity.isFullyResolved,
            "a pid nothing holds cannot be fully resolved",
        )
        XCTAssertEqual(identity.code.signature, .unresolved)
        XCTAssertEqual(identity.code.bundleIdentifier, nil)
        XCTAssertEqual(identity.ancestors, [], "an absent process has no readable ancestry")
        XCTAssertNil(identity.code.binding.designatedRequirement)
        // And no grant bound to that placeholder can be satisfied by a real binary. An
        // identity always satisfies its OWN binding, so the comparison has to be against a
        // real candidate — comparing the placeholder to itself would pass for any value at
        // all, which is the kind of assertion that looks like coverage and is not.
        let real = CodeIdentity(
            executablePath: "/bin/ls",
            bundleIdentifier: nil,
            designatedRequirement: nil,
            signature: .signedAndValid,
        )
        XCTAssertFalse(
            identity.code.binding.isSatisfied(by: real),
            "an unresolved placeholder must not be satisfiable by a real binary",
        )
    }

    /// A pid the kernel says nothing holds. `kill(pid, 0)` performs the permission and
    /// existence checks without delivering a signal, and ESRCH is the answer that means
    /// "no such process".
    private static func anUnusedProcessIdentifier() -> Int32? {
        for candidate in stride(from: Int32(99999), to: 2, by: -1) {
            if kill(candidate, 0) == -1, errno == ESRCH {
                return candidate
            }
        }
        return nil
    }

    /// A binary that is not inside an application bundle has no bundle identifier, and the
    /// answer must be nil rather than a guess — every command-line tool on the machine is
    /// in this position, and the identity row shows a bundle or shows nothing.
    func testABinaryWithNoBundleHasNoBundleIdentifier() {
        XCTAssertNil(BundleIdentifierResolver.bundleIdentifier(forExecutable: "/bin/ls"))
    }

    /// A binary inside a bundle gets the bundle's OWN identifier, read from that bundle's
    /// Info.plist, with the nesting a real bundle has.
    func testABundleIdentifierIsReadFromTheOwningApplication() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("exactmac-identity-\(UUID().uuidString)")
        let bundle = root.appendingPathComponent("Example.app")
        let executable = bundle.appendingPathComponent("Contents/MacOS/Example")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
            "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
              <key>CFBundleExecutable</key><string>Example</string>
              <key>CFBundleIdentifier</key><string>com.example.exactmac-identity</string>
            </dict></plist>
            """.utf8,
        ).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        XCTAssertTrue(FileManager.default.createFile(atPath: executable.path, contents: Data()))
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(
            BundleIdentifierResolver.bundleIdentifier(forExecutable: executable.path),
            "com.example.exactmac-identity",
        )
    }

    /// A nonexistent path cannot be turned into something to check, which is "could not
    /// find out" and not "found out, and it is unsigned".
    func testAPathThatIsNotABinaryIsUnresolvedRatherThanUnsigned() {
        XCTAssertEqual(CodeSignature.inspect(executablePath: "/nonexistent/nope").state, .unresolved)
    }

    // MARK: - The ancestry, which is the whole reason this exists

    /// Hana's chain: Terminal -> login shell -> agent host -> `exactmac`. The peer is the
    /// LAST element, and an identity that names only the peer tells the operator that a
    /// binary asked, which is not the decision they are making.
    func testTheWholeAncestorChainIsCarriedNearestFirst() {
        let table = StubProcessTable(
            processes: [
                500: .init(path: "/usr/bin/true", parent: 400),
                400: .init(path: "/bin/zsh", parent: 300),
                300: .init(path: "/Applications/Terminal.app/Contents/MacOS/Terminal", parent: 1),
            ],
        )
        let identity = CallerIdentityResolver(inspector: table).resolve(
            PeerProcessEvidence(processIdentifier: 500, effectiveUserIdentifier: 501),
        )
        XCTAssertEqual(identity.ancestors.map(\.processIdentifier), [400, 300, 1])
        XCTAssertFalse(identity.isAncestryTruncated)
        // The agent is the peer's parent, and it is on the chain: this is the process the
        // operator has in mind.
        XCTAssertEqual(identity.ancestors.first?.code.executablePath, "/bin/zsh")
    }

    /// Depth is unbounded in practice, so it is capped — and the truncation is REPORTED,
    /// because a silently shortened tree presents an incomplete picture as a complete one.
    func testTheChainIsCappedAndTheTruncationIsReported() {
        var processes: [Int32: StubProcess] = [:]
        for pid in stride(from: Int32(1000), to: 1, by: -1) {
            processes[pid] = .init(path: "/bin/tool\(pid)", parent: pid - 1)
        }
        let identity = CallerIdentityResolver(
            inspector: StubProcessTable(processes: processes),
            maximumAncestorDepth: 4,
        ).resolve(PeerProcessEvidence(processIdentifier: 1000, effectiveUserIdentifier: 501))
        XCTAssertEqual(identity.ancestors.count, 4)
        XCTAssertEqual(identity.ancestors.map(\.processIdentifier), [999, 998, 997, 996])
        XCTAssertTrue(
            identity.isAncestryTruncated,
            "a capped chain that does not say it was capped is a lie",
        )
    }

    /// A cycle in the process table is a fact, not an error, and following it forever is the
    /// alternative.
    func testACycleInTheProcessTableTerminates() {
        let identity = CallerIdentityResolver(
            inspector: StubProcessTable(processes: [
                10: .init(path: "/bin/a", parent: 11),
                11: .init(path: "/bin/b", parent: 10),
            ]),
        ).resolve(PeerProcessEvidence(processIdentifier: 10, effectiveUserIdentifier: 501))
        XCTAssertEqual(identity.ancestors.map(\.processIdentifier), [11])
        XCTAssertTrue(identity.isAncestryTruncated)
    }

    /// A process whose path cannot be read does not remove its ancestors from the chain —
    /// the operator still needs to see what is above it.
    func testAnUnreadableAncestorKeepsTheRestOfTheChain() {
        let identity = CallerIdentityResolver(
            inspector: StubProcessTable(processes: [
                500: .init(path: "/tmp/peer", parent: 400),
                400: .init(path: "/bin/zsh", parent: 300),
                300: .init(path: nil, parent: nil),
            ]),
        ).resolve(PeerProcessEvidence(processIdentifier: 500, effectiveUserIdentifier: 501))
        XCTAssertEqual(identity.ancestors.map(\.processIdentifier), [400, 300])
        XCTAssertEqual(identity.ancestors.last?.isFullyResolved, false)
        XCTAssertEqual(identity.ancestors.last?.code.signature, .unresolved)
        XCTAssertEqual(identity.ancestors.first?.isFullyResolved, true)
    }

    // MARK: - The variant gate

    /// A TCP listener has no authenticating principal, so no resolver is CONSTRUCTED. The
    /// path that needs one does not exist to be reached, which is a stronger statement than
    /// "it returns nil".
    func testTheResolverDoesNotExistInTCPTransport() {
        XCTAssertNil(CallerIdentitySource.unavailableTransport.resolver)
        XCTAssertFalse(CallerIdentitySource.unavailableTransport.isIdentityResolutionAvailable)
        XCTAssertNotNil(CallerIdentitySource.unixSocket(CallerIdentityResolver(
            inspector: SystemProcessInspector(),
        )).resolver)
    }

    /// And the reduced transport denies rather than proceeding without evidence.
    func testTheReducedUnauthenticatedTransportDenies() {
        let decision = AuthorizationPolicy.evaluate(
            request: Self.clipboardReadRequest,
            identity: Self.anyIdentity,
            grants: [],
            envelopes: [],
            posture: .balanced,
            context: AuthorizationContext(
                transport: .tcp,
                isConsoleReachable: true,
                peerAuthenticated: true,
                biometric: .available,
                store: .intact,
                highConsequenceTargets: [],
            ),
            now: MonotonicInstant(nanoseconds: 0),
        )
        XCTAssertEqual(decision.outcome, .deny, "a TCP listener must not authorize")
        XCTAssertEqual(
            decision.basis,
            .denied(.reducedUnauthenticatedPosture),
            "the refusal must name the reduced posture, not the capability",
        )
    }

    /// THE INTERPRETIVE RULE, pinned end to end: an unsigned caller is ESCALATED, never
    /// REJECTED. A control that claimed to reject same-uid malware would be offering false
    /// assurance, because same-uid malware is cryptographically indistinguishable from the
    /// operator's own agent.
    ///
    /// "Escalated" means the decision is `.promptRequired` and carries a ceremony whose
    /// reason names the weakness. It is NOT `.denied(reason:)`, and it is not a silent
    /// allow. Note the engine's encoding: a decision awaiting consent reports
    /// `outcome: .deny` with `basis: .promptRequired`, because consent has not been
    /// obtained yet — so the basis is what distinguishes "ask the operator" from
    /// "refuse", and that is what this asserts.
    func testAnUnsignedCallerIsEscalatedRatherThanDenied() {
        let identity = CallerIdentityResolver(inspector: StubProcessTable(processes: [
            500: .init(path: "/tmp/unsigned-tool", parent: 400, signature: .unsigned),
            400: .init(path: "/bin/zsh", parent: 1, signature: .signedAndValid),
        ])).resolve(PeerProcessEvidence(processIdentifier: 500, effectiveUserIdentifier: 501))

        XCTAssertTrue(identity.isFullyResolved)
        XCTAssertEqual(identity.code.signature, .unsigned)

        let decision = AuthorizationPolicy.evaluate(
            request: Self.clipboardReadRequest,
            identity: identity,
            grants: [],
            envelopes: [],
            posture: .balanced,
            context: .unixSocket(),
            now: MonotonicInstant(nanoseconds: 0),
        )
        XCTAssertEqual(
            decision.basis,
            .promptRequired,
            "an unsigned caller must reach a prompt rather than being rejected",
        )
        if case .denied = decision.basis {
            XCTFail("an unsigned caller must not be hard-denied")
        }
        if case .notRequired = decision.biometric {
            XCTFail("an unsigned caller must reach a ceremony")
        }
        XCTAssertEqual(
            decision.biometric.reason?.contains("unsigned"),
            true,
            "the ceremony must name the weakness: \(decision.biometric.reason ?? "none")",
        )
        XCTAssertFalse(decision.offeredDecisions.isEmpty, "a prompt needs options to offer")
    }

    /// The signed caller of the same request, for contrast: the weak signature is what costs
    /// the ceremony. Without the pair, "unsigned escalates" could be satisfied by a policy
    /// that escalates everything.
    func testTheWeakSignatureIsWhatCostsTheCeremony() {
        func identity(signature: SignatureState) -> CallerIdentity {
            CallerIdentityResolver(inspector: StubProcessTable(processes: [
                500: .init(path: "/tmp/tool", parent: 400, signature: signature),
                400: .init(path: "/bin/zsh", parent: 1, signature: .signedAndValid),
            ])).resolve(PeerProcessEvidence(processIdentifier: 500, effectiveUserIdentifier: 501))
        }
        func decision(_ signature: SignatureState) -> AuthorizationDecision {
            AuthorizationPolicy.evaluate(
                request: Self.clipboardReadRequest,
                identity: identity(signature: signature),
                grants: [],
                envelopes: [],
                posture: .balanced,
                context: .unixSocket(),
                now: MonotonicInstant(nanoseconds: 0),
            )
        }

        let signed = decision(.signedAndValid)
        let unsigned = decision(.unsigned)
        XCTAssertEqual(signed.basis, .promptRequired)
        XCTAssertEqual(unsigned.basis, .promptRequired, "both reach a prompt")
        XCTAssertGreaterThan(
            unsigned.blastRadius.radius, signed.blastRadius.radius,
            "signature quality is a factor in the radius, so a weaker signature must cost more",
        )
        XCTAssertGreaterThanOrEqual(
            unsigned.riskClass, signed.riskClass,
            "a weaker signature cannot lower the risk class",
        )
        if case .notRequired = unsigned.biometric {
            XCTFail("an unsigned caller must reach a ceremony")
        }
        // The contrast that matters: for the SAME request, a signed caller costs nothing and
        // an unsigned one costs a biometric whose reason names the weakness. Without the
        // pair, "unsigned escalates" would also be satisfied by a policy that escalates
        // everything, which is a uniform prompt the design rejects.
        XCTAssertEqual(
            signed.biometric, .notRequired,
            "a signed, application-scoped clipboard read should cost nothing",
        )
        XCTAssertEqual(
            unsigned.biometric.reason?.contains("unsigned"),
            true,
            "the unsigned caller's ceremony must name the weakness: "
                + (unsigned.biometric.reason ?? "none"),
        )
    }

    // MARK: - Fixtures

    private static let clipboardReadRequest = AuthorizationRequest(
        id: AuthorizationRequestID(rawValue: "req-identity"),
        rpcName: "exactmac.v1.ExactMac/GetClipboard",
        capability: .clipboardRead,
        scope: AuthorizationScope(application: .bundleIdentifier("com.apple.TextEdit")),
        argumentSummary: "the clipboard",
        agentReason: "the test asked",
        origin: .mcpProxy,
    )

    private static let anyIdentity = CallerIdentity(
        processIdentifier: 1,
        effectiveUserIdentifier: 0,
        parentProcessIdentifier: nil,
        code: CodeIdentity(
            executablePath: "/bin/true",
            bundleIdentifier: nil,
            designatedRequirement: nil,
            signature: .signedAndValid,
        ),
        isFullyResolved: true,
    )

    /// One row of a process table a test controls.
    private struct StubProcess {
        var path: String?
        var parent: Int32?
        var signature: SignatureState = .signedAndValid
        var requirement: String?
    }

    private struct StubProcessTable: ProcessInspecting {
        var processes: [Int32: StubProcess]

        func codeIdentity(processIdentifier: Int32) -> CodeIdentity? {
            guard let entry = processes[processIdentifier], let path = entry.path else { return nil }
            return CodeIdentity(
                executablePath: path,
                bundleIdentifier: BundleIdentifierResolver.bundleIdentifier(forExecutable: path),
                designatedRequirement: entry.requirement,
                signature: entry.signature,
            )
        }

        func parentProcessIdentifier(of processIdentifier: Int32) -> Int32? {
            processes[processIdentifier]?.parent
        }
    }
}
