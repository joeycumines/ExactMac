import Darwin
import ExactMacProto
@testable import ExactMacServer
import Foundation
import GRPCCore
import XCTest

/// Invariant 1's refusal half, driven through the REAL interceptor against a REAL log.
///
/// INVARIANT 1 CLAIMS "no RPC reaches a handler without a decision recorded in the decision
/// audit log", and AGENTS.md states it as a falsifiable claim backed by automated tests. It
/// was FALSE in the shipped build, and the gap was structural rather than a missing case:
/// the interceptor's `.promptRequired` branch called `prompt()`, which THROWS on every
/// refusal path, so the throw left `authorize` before `record(...)` was ever reached.
///
/// Nothing was written for a declined prompt, an expired prompt, a failed ceremony, an
/// answer bound to the wrong request, or a console that vanished mid-prompt. The measurement
/// that found it was ten such refusals in the unified log on one day against an audit log
/// whose last entry was three days older — every refusal since, invisible.
///
/// THESE TESTS DRIVE THE INTERCEPTOR, not the recorder, because the defect was never in
/// `DecisionAudit`: it wrote everything it was handed. It was handed nothing. A test that
/// called `record(...)` directly would have passed against the broken build, which is
/// exactly the failure mode a test of this kind must not have.
final class ConsentPathAuditTests: XCTestCase {
    private var logPath: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        logPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("exactmac-consent-audit-\(UUID().uuidString).jsonl").path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: logPath)
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private final class FixedClock: MonotonicClock, @unchecked Sendable {
        func now() -> MonotonicInstant {
            MonotonicInstant(nanoseconds: 1_000_000_000)
        }
    }

    /// Kernel evidence that this test process is the caller.
    ///
    /// Supplied by hand because the TRANSPORT cannot supply any — see
    /// `knowledgeStore.transportLimit`. Without it the identity is unresolved and the engine
    /// denies with `.unauthenticatedPeer` BEFORE the consent path, so the refusals under test
    /// would never be reached.
    private static var thisProcess: PeerProcessEvidence {
        PeerProcessEvidence(processIdentifier: getpid(), effectiveUserIdentifier: getuid())
    }

    /// A RESOLVED CALLER, because an unresolved one raises the risk class and changes which
    /// options the decision offers.
    private static var resolvedCaller: CallerIdentity {
        CallerIdentity(
            processIdentifier: getpid(),
            effectiveUserIdentifier: getuid(),
            parentProcessIdentifier: nil,
            code: CodeIdentity(
                executablePath: "/usr/local/bin/exactmac",
                bundleIdentifier: nil,
                designatedRequirement: #"identifier "x" and anchor apple"#,
                signature: .signedAndValid,
            ),
            isFullyResolved: true,
            ancestors: [],
        )
    }

    /// An inspector that resolves ONE pid to a fixed identity and no other.
    ///
    /// The runtime's identity source is a `CallerIdentityResolver` wrapping an inspector,
    /// not a fixed identity, so this is the seam that lets a test supply one without the
    /// kernel being involved. Every other pid resolves to nothing, which is what an
    /// unreadable or exited process looks like to the resolver.
    private struct FixedInspector: ProcessInspecting {
        let pid: Int32
        let identity: CodeIdentity

        func codeIdentity(processIdentifier: Int32) -> CodeIdentity? {
            processIdentifier == pid ? identity : nil
        }

        func parentProcessIdentifier(of _: Int32) -> Int32? {
            nil
        }
    }

    private func makeAudit() throws -> DecisionAudit {
        try DecisionAudit(path: logPath, clock: FixedClock())
    }

    private func entries() throws -> [AuditEntry] {
        try AuditEntry.readAll(from: logPath).whole
    }

    // MARK: - The harness

    /// A runtime with a REAL recorder, the given consent handler, and an operator who IS
    /// reachable.
    ///
    /// Every case below is a refusal that happens AFTER the operator was successfully asked,
    /// which is the class the log was blind to. A refusal with nobody to ask is a different
    /// branch and is covered by the interceptor's own suite.
    private func runtime(
        consent: ConsentAnswering?,
        audit: DecisionAudit,
        consoleReachable: Bool = true,
    ) throws -> AuthorizationRuntime {
        var runtime = try AuthorizationRuntime.unixSocket(
            descriptorPolicy: PublicRequestDescriptorPolicy.load(),
            consent: consent,
            issuance: NoGrantIssuance(),
            clock: FixedClock(),
            // BALANCED, because this suite is about what the audit records on the ALLOW
            // path, and the allow depends on a standing grant being honoured — which is
            // what balanced is FOR. A fresh strict source would ignore the grant and the
            // test would fail for the posture's sake rather than for anything it tests.
            postureSource: {
                let source = PostureSource(override: nil)
                source.setStoredPreference(.balanced)
                return source
            }(),
            // SHORT, so a handler that waits rather than answering is decided by the test
            // rather than by the wall clock.
            consentTimeout: .milliseconds(50),
            isConsoleReachable: consoleReachable,
            peerEvidence: .fixed(Self.thisProcess),
            audit: AuditDecisionRecorder(audit: audit),
            auditRequired: true,
        )
        runtime.identity = .unixSocket(
            CallerIdentityResolver(
                inspector: FixedInspector(pid: getpid(), identity: Self.resolvedCaller.code),
            ),
        )
        return runtime
    }

    /// Runs one clipboard read through the interceptor and reports whether it was refused.
    ///
    /// The handler throws if reached: every case here is a refusal, so a handler that ran
    /// would be the test's own bug rather than a pass.
    @discardableResult
    private func drive(
        consent: ConsentAnswering?,
        audit: DecisionAudit,
        consoleReachable: Bool = true,
        metadata: Metadata = Metadata(),
    ) async throws -> Bool {
        let runtime = try runtime(
            consent: consent,
            audit: audit,
            consoleReachable: consoleReachable,
        )
        let interceptor = AuthorizationInterceptor(runtime: runtime)
        do {
            _ = try await interceptor.intercept(
                request: Self.request(
                    Exactmac_V1_GetClipboardRequest.with { $0.name = "clipboard" },
                    metadata: metadata,
                ),
                context: Self.context(),
                next: { _, _ -> StreamingServerResponse<Exactmac_V1_Clipboard> in
                    throw RPCError(code: .internalError, message: "the handler was reached")
                },
            )
            return false
        } catch {
            // Every path out of here other than the handler is the refusal under test.
            return true
        }
    }

    private static func request<Input: Sendable>(
        _ message: Input,
        metadata: Metadata = Metadata(),
    ) -> StreamingServerRequest<Input> {
        StreamingServerRequest(
            metadata: metadata,
            messages: RPCAsyncSequence<Input, any Error>(wrapping: AsyncThrowingStream { continuation in
                continuation.yield(message)
                continuation.finish()
            }),
        )
    }

    private static func context() async -> ServerContext {
        await withServerContextRPCCancellationHandle { cancellation in
            ServerContext(
                descriptor: MethodDescriptor(
                    service: ServiceDescriptor(
                        fullyQualifiedService: RPCAuthorizationMap.serviceName,
                    ),
                    method: "GetClipboard",
                ),
                remotePeer: "unix",
                localPeer: "unix",
                cancellation: cancellation,
            )
        }
    }

    // MARK: - The refusals

    /// A PROMPT NOBODY ANSWERS is on the record, with its reason.
    ///
    /// The handler is asked and returns nothing, the bound expires, and the request is
    /// refused. Before the fix this wrote NOTHING: `prompt()` threw on the expiry, the throw
    /// left `authorize`, and `record(...)` was never reached.
    func testAnExpiredPromptIsOnTheRecordWithItsReason() async throws {
        let audit = try makeAudit()
        let refused = try await drive(consent: { _, _, _ in nil }, audit: audit)
        XCTAssertTrue(refused, "an unanswered prompt was not refused")

        let written = try entries()
        XCTAssertEqual(written.count, 1, "the consent-path refusal was not recorded at all")
        let entry = try XCTUnwrap(written.first)
        XCTAssertEqual(
            entry.refusalReason,
            DenialReason.consoleUnreachable.rawValue,
            "the entry does not say why the request was refused",
        )
        XCTAssertEqual(entry.capability, Capability.clipboardRead.rawValue)
        // AND WHAT WAS WRITTEN VERIFIES. A refusal that corrupts the chain is worse than a
        // missing one, because the chain is what makes the rest of the log trustworthy.
        XCTAssertTrue(audit.verify().isIntact)
    }

    /// AN OPERATOR WHO DECLINES is the case an operator most needs to find afterwards, and it
    /// was the one the log was blindest to: the prompt was shown, a person answered, and
    /// nothing recorded that they said no.
    func testADeclinedPromptIsOnTheRecord() async throws {
        let audit = try makeAudit()
        let refused = try await drive(
            consent: { request, _, _ in
                ConsentAnswer(
                    requestID: request.id,
                    isApproved: false,
                    selected: nil,
                    note: "not this one",
                    ceremonyProof: nil,
                )
            },
            audit: audit,
        )
        XCTAssertTrue(refused, "a declined prompt was not refused")

        let entry = try XCTUnwrap(try entries().first)
        XCTAssertEqual(entry.refusalReason, DenialReason.notPermitted.rawValue)
        XCTAssertEqual(entry.decision, "deny")
    }

    /// AN ANSWER CARRYING ANOTHER REQUEST'S ID is refused and recorded, because this is the
    /// confused deputy in its narrowest form and a log that could not show it happening could
    /// not show a person whether their answer was applied to the request they were looking at.
    func testAnAnswerForAnotherRequestIsOnTheRecord() async throws {
        let audit = try makeAudit()
        let refused = try await drive(
            consent: { _, _, _ in
                ConsentAnswer(
                    requestID: AuthorizationRequestID(rawValue: "some-other-request"),
                    isApproved: true,
                    selected: .allowOnce,
                    note: nil,
                    ceremonyProof: nil,
                )
            },
            audit: audit,
        )
        XCTAssertTrue(refused, "an answer for another request authorized this one")

        let entry = try XCTUnwrap(try entries().first)
        XCTAssertEqual(entry.refusalReason, DenialReason.notPermitted.rawValue)
    }

    /// A CONSOLE THAT CANNOT BE REACHED IS REFUSED, AND IT IS REFUSED BY THE POLICY — before
    /// `prompt()` is ever entered.
    ///
    /// This is worth pinning because the same reason arises at two layers with different
    /// consequences, and only one of them is a consent-path refusal. The engine checks
    /// reachability itself and returns `.denied(.consoleUnreachable)`, which travels the
    /// `.denied` branch and is recorded as a decision whose basis says so. The consent-path
    /// refusals are the ones that happen after a person WAS reachable and the answer then
    /// failed validation, and those are the rows that used to be lost. Asserting the reason
    /// lands in the entry rather than in a `refusalReason` field is what distinguishes the
    /// two layers, and getting it wrong here would hide a regression in the other.
    func testAnUnreachableConsoleIsRefusedAndRecordedByThePolicy() async throws {
        let audit = try makeAudit()
        let refused = try await drive(
            consent: nil,
            audit: audit,
            consoleReachable: false,
        )
        XCTAssertTrue(refused, "an unreachable console authorized a consent-requiring request")

        let entry = try XCTUnwrap(try entries().first)
        XCTAssertEqual(entry.decision, "deny")
        XCTAssertEqual(entry.basis, "denied:\(DenialReason.consoleUnreachable.rawValue)")
        XCTAssertNil(
            entry.refusalReason,
            "a policy denial carries its reason in the basis, not as a consent-path refusal",
        )
    }

    /// THE CHAIN SURVIVES THE REFUSALS, and the sequence continues across them.
    ///
    /// Adding entries to a hash-chained log is only safe because the chain is walked from
    /// the log's own first entry rather than from anything the current process invents —
    /// invariant 11, and the reason `DecisionAuditTests` exercises a reopen. Recording a
    /// refusal must not be the thing that breaks the chain.
    func testTheChainIsIntactAndContinuousAcrossConsentPathRefusals() async throws {
        let audit = try makeAudit()
        for _ in 0 ..< 3 {
            _ = try await drive(consent: { _, _, _ in nil }, audit: audit)
        }
        let verification = audit.verify()
        XCTAssertEqual(verification.entryCount, 3)
        XCTAssertTrue(
            verification.isIntact,
            "chain defect: \(String(describing: verification.defect))",
        )
        XCTAssertEqual(try entries().map(\.sequence), [1, 2, 3])
    }

    /// AN ALLOW IS STILL AN ALLOW, and carries NO refusal reason — the new field is not a
    /// reinterpretation of the existing ones, and a log that stamped a refusal onto a grant
    /// would be as wrong as one that omitted refusals.
    ///
    /// This drives the standing-grant path rather than the consent path, so it also asserts
    /// that adding the field did not disturb the decision that was already on the record.
    func testAnAllowedRequestRecordsNoRefusalReason() async throws {
        let audit = try makeAudit()
        let now = FixedClock().now()
        let grant = Grant(
            id: "grant-clipboard",
            capability: .clipboardRead,
            scope: AuthorizationScope(application: .any),
            duration: .once,
            holder: Self.resolvedCaller.code.binding,
            issuedAt: now,
            expiresAt: now.advanced(by: .seconds(60)),
            origin: .prompt(decidedAt: now),
            targetIsHighConsequence: false,
        )
        var runtime = try runtime(consent: { _, _, _ in nil }, audit: audit)
        runtime.grants = FixedGrantSupply(grants: [grant])
        let interceptor = AuthorizationInterceptor(runtime: runtime)
        _ = try await interceptor.intercept(
            request: Self.request(
                Exactmac_V1_GetClipboardRequest.with { $0.name = "clipboard" },
            ),
            context: Self.context(),
            next: { _, _ -> StreamingServerResponse<Exactmac_V1_Clipboard> in
                StreamingServerResponse(
                    metadata: Metadata(),
                    producer: { _ in Metadata() },
                )
            },
        )
        let entry = try XCTUnwrap(try entries().first)
        XCTAssertEqual(entry.decision, "allow")
        XCTAssertNil(entry.refusalReason, "an allowed request recorded a refusal reason")
    }

    /// An unreadable agent reason (invalid UTF-8 bytes) is diagnosed accurately as
    /// unreadableAgentReason rather than misreported as consoleUnreachable.
    func testAnUnreadableAgentReasonIsRefusedAndRecorded() async throws {
        let audit = try makeAudit()
        var metadata = Metadata()
        metadata.addBinary([0xFF, 0xFE], forKey: AuthorizationInterceptor.agentReasonMetadataKey)
        metadata.addString("mcp", forKey: AuthorizationInterceptor.mcpProxyMetadataKey)
        let refused = try await drive(
            consent: { _, _, _ in nil },
            audit: audit,
            metadata: metadata,
        )
        XCTAssertTrue(refused, "an unreadable agent reason authorized a request")

        let entry = try XCTUnwrap(try entries().first)
        XCTAssertEqual(entry.decision, "deny")
        XCTAssertEqual(entry.refusalReason, DenialReason.unreadableAgentReason.rawValue)
        XCTAssertNil(entry.agentReason, "unreadable reason was not nil")
        XCTAssertTrue(audit.verify().isIntact, "audit hash chain was broken")
    }

    /// A missing agent reason from an MCP caller is diagnosed as missingAgentReason
    /// rather than misreported as consoleUnreachable.
    func testAMissingAgentReasonFromMCPCallerIsRefusedAndRecorded() async throws {
        let audit = try makeAudit()
        var metadata = Metadata()
        metadata.addString("mcp", forKey: AuthorizationInterceptor.mcpProxyMetadataKey)
        let refused = try await drive(
            consent: { _, _, _ in nil },
            audit: audit,
            metadata: metadata,
        )
        XCTAssertTrue(refused, "a missing agent reason from an MCP caller authorized a request")

        let entry = try XCTUnwrap(try entries().first)
        XCTAssertEqual(entry.decision, "deny")
        XCTAssertEqual(entry.refusalReason, DenialReason.missingAgentReason.rawValue)
        XCTAssertNil(entry.agentReason)
        XCTAssertTrue(audit.verify().isIntact, "audit hash chain was broken")
    }

    /// A legacy caller sending the plain exactmac-agent-reason string key has its reason
    /// delivered to the prompt and preserved in the audit log.
    func testALegacyAgentReasonKeyIsDeliveredToPromptAndAuditLog() async throws {
        let audit = try makeAudit()
        var metadata = Metadata()
        metadata.addString("Inspecting TextEdit window for operator", forKey: AuthorizationInterceptor.legacyAgentReasonMetadataKey)
        metadata.addString("mcp", forKey: AuthorizationInterceptor.mcpProxyMetadataKey)

        final class ReasonBox: @unchecked Sendable {
            private let lock = NSLock()
            private var _value: String?
            var value: String? {
                get { lock.withLock { _value } }
                set { lock.withLock { _value = newValue } }
            }
        }
        let box = ReasonBox()
        let refused = try await drive(
            consent: { request, _, _ in
                box.value = request.agentReason
                return ConsentAnswer(
                    requestID: request.id,
                    isApproved: false,
                    selected: .allowOnce,
                    note: nil,
                    ceremonyProof: nil,
                )
            },
            audit: audit,
            metadata: metadata,
        )
        XCTAssertTrue(refused)
        XCTAssertEqual(box.value, "Inspecting TextEdit window for operator")

        let entry = try XCTUnwrap(try entries().first)
        XCTAssertEqual(entry.decision, "deny")
        XCTAssertEqual(entry.refusalReason, DenialReason.notPermitted.rawValue)
        XCTAssertEqual(entry.agentReason, "Inspecting TextEdit window for operator")
        XCTAssertTrue(audit.verify().isIntact, "audit hash chain was broken")
    }

    /// A grant supply that always reports the same grants.
    ///
    /// The runtime takes an `any GrantSupply`, so this is the seam; a store on disk is not
    /// what any of these tests is about.
    private struct FixedGrantSupply: GrantSupply {
        var grants: [Grant]

        func snapshot() async -> GrantSnapshot {
            GrantSnapshot(grants: grants)
        }

        /// No spend is ever honoured: this fixture is about recording, not about counts,
        /// and the refusal is what a supply that cannot spend must return.
        func consume(_: String, operations _: Int) async -> Bool {
            false
        }

        func consumeEnvelope(_: String, operations _: Int) async -> Bool {
            false
        }
    }
}
