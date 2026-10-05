import Darwin
import ExactMacProto
@testable import ExactMacServer
import Foundation
import GRPCCore
import XCTest

/// Acceptance tests for E32: Concurrency and head-of-line blocking prevention.
///
/// Acceptance criteria:
/// - Calls that need NO consent are never blocked behind one that does — the no-consent
///   path must stay independent, keeping reads working while a prompt is outstanding.
/// - Concurrent consent-requiring calls are resolved rather than silently expiring.
final class ConsentConcurrencyTests: XCTestCase {
    private var logPath: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        logPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("exactmac-concurrency-audit-\(UUID().uuidString).jsonl").path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: logPath)
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private final class LockedValue<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: T

        init(_ value: T) {
            self._value = value
        }

        var value: T {
            get {
                lock.lock()
                defer { lock.unlock() }
                return _value
            }
            set {
                lock.lock()
                defer { lock.unlock() }
                _value = newValue
            }
        }
    }

    private final class FixedClock: MonotonicClock, @unchecked Sendable {
        func now() -> MonotonicInstant {
            MonotonicInstant(nanoseconds: 1_000_000_000)
        }
    }

    private static var thisProcess: PeerProcessEvidence {
        PeerProcessEvidence(processIdentifier: getpid(), effectiveUserIdentifier: getuid())
    }

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

    private struct ImmediateIssuance: GrantIssuing {
        func authorize(
            answer _: ConsentAnswer,
            request: AuthorizationRequest,
            identity _: CallerIdentity,
            offered: [OfferedDecision],
            now _: MonotonicInstant,
        ) async throws -> AuthorizationDecision {
            AuthorizationDecision(
                outcome: .allow,
                basis: .promptRequired,
                effectiveCapabilities: request.capability.impliedCapabilities,
                blastRadius: BlastRadius(
                    capability: 0.1,
                    breadth: 0.1,
                    duration: 0.1,
                    remainingCount: 0.1,
                    targetConsequence: 0.1,
                    signatureQuality: 0.1,
                ),
                riskClass: .routine,
                biometric: .notRequired,
                offeredDecisions: offered,
                expiresAt: nil,
            )
        }
    }

    private func runtime(
        consent: ConsentAnswering?,
        audit: DecisionAudit,
        issuance: any GrantIssuing = NoGrantIssuance(),
        consentTimeout: Duration = .seconds(60),
    ) throws -> AuthorizationRuntime {
        var runtime = try AuthorizationRuntime.unixSocket(
            descriptorPolicy: PublicRequestDescriptorPolicy.load(),
            consent: consent,
            issuance: issuance,
            clock: FixedClock(),
            postureSource: PostureSource(override: nil),
            consentTimeout: consentTimeout,
            isConsoleReachable: true,
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

    private static func clipboardRequest(reason: String = "test clipboard read") -> StreamingServerRequest<Exactmac_V1_GetClipboardRequest> {
        let message = Exactmac_V1_GetClipboardRequest.with { $0.name = "clipboard" }
        var metadata = Metadata()
        metadata.addBinary(Array(reason.utf8), forKey: AuthorizationInterceptor.agentReasonMetadataKey)
        metadata.addString("mcp", forKey: AuthorizationInterceptor.mcpProxyMetadataKey)
        return StreamingServerRequest(
            metadata: metadata,
            messages: RPCAsyncSequence<Exactmac_V1_GetClipboardRequest, any Error>(wrapping: AsyncThrowingStream { continuation in
                continuation.yield(message)
                continuation.finish()
            }),
        )
    }

    private static func listDisplaysRequest() -> StreamingServerRequest<Exactmac_V1_ListDisplaysRequest> {
        let message = Exactmac_V1_ListDisplaysRequest()
        return StreamingServerRequest(
            metadata: Metadata(),
            messages: RPCAsyncSequence<Exactmac_V1_ListDisplaysRequest, any Error>(wrapping: AsyncThrowingStream { continuation in
                continuation.yield(message)
                continuation.finish()
            }),
        )
    }

    private static func clipboardContext(cancellation: ServerContext.RPCCancellationHandle) -> ServerContext {
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

    private static func listDisplaysContext(cancellation: ServerContext.RPCCancellationHandle) -> ServerContext {
        ServerContext(
            descriptor: MethodDescriptor(
                service: ServiceDescriptor(
                    fullyQualifiedService: RPCAuthorizationMap.serviceName,
                ),
                method: "ListDisplays",
            ),
            remotePeer: "unix",
            localPeer: "unix",
            cancellation: cancellation,
        )
    }

    // MARK: - Tests

    /// Calls that need NO consent (like ListDisplays, which is display.read) must succeed
    /// immediately while another call is suspended waiting for operator consent.
    func testNoConsentRequiredCallSucceedsImmediatelyWhileConsentPromptIsPending() async throws {
        let audit = try makeAudit()
        let promptEnteredStream = AsyncStream<Void>.makeStream()
        let cancellation1 = ServerContext.RPCCancellationHandle()

        let runtime = try runtime(
            consent: { _, _, _ in
                promptEnteredStream.continuation.yield()
                // Simulate an operator considering the prompt for 30s
                try? await Task.sleep(for: .seconds(30))
                return nil
            },
            audit: audit,
            consentTimeout: .seconds(60),
        )
        let interceptor = AuthorizationInterceptor(runtime: runtime)

        // Launch Call 1: GetClipboard (needs consent)
        let call1 = Task {
            try await interceptor.intercept(
                request: Self.clipboardRequest(),
                context: Self.clipboardContext(cancellation: cancellation1),
                next: { _, _ -> StreamingServerResponse<Exactmac_V1_Clipboard> in
                    throw RPCError(code: .internalError, message: "handler reached unexpectedly")
                },
            )
        }

        // Wait until Call 1 has entered the consent wait and is actively blocking
        var iterator = promptEnteredStream.stream.makeAsyncIterator()
        _ = await iterator.next()

        // Call 1 is now actively waiting for operator consent.
        // Issue Call 2: ListDisplays (needs NO consent) concurrently.
        let cancellation2 = ServerContext.RPCCancellationHandle()
        let call2Start = ContinuousClock.now
        let call2HandlerReached = LockedValue(false)

        _ = try await interceptor.intercept(
            request: Self.listDisplaysRequest(),
            context: Self.listDisplaysContext(cancellation: cancellation2),
            next: { _, _ -> StreamingServerResponse<Exactmac_V1_ListDisplaysResponse> in
                call2HandlerReached.value = true
                return StreamingServerResponse(metadata: Metadata(), producer: { _ in Metadata() })
            },
        )

        let call2Elapsed = ContinuousClock.now - call2Start
        XCTAssertTrue(call2HandlerReached.value, "Call 2 handler was not reached")
        XCTAssertLessThan(
            call2Elapsed,
            .milliseconds(200),
            "Call 2 was blocked behind Call 1! Elapsed: \(call2Elapsed)",
        )

        // Clean up Call 1
        cancellation1.cancel()
        do {
            _ = try await call1.value
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .cancelled)
        } catch {
            // Cancellation error is expected
        }
    }

    /// Concurrent consent-requiring calls are both resolved rather than expiring.
    /// Two calls are issued, the operator answers the first, then answers the second,
    /// and both calls complete successfully and reach their respective handlers.
    func testTwoConcurrentConsentCallsAreBothResolvedSequentially() async throws {
        let audit = try makeAudit()
        let call1ReachedPrompt = AsyncStream<Void>.makeStream()
        let call2ReachedPrompt = AsyncStream<Void>.makeStream()

        let call1AnswerStream = AsyncStream<ConsentAnswer>.makeStream()
        let call2AnswerStream = AsyncStream<ConsentAnswer>.makeStream()

        let consentCount = LockedValue(0)
        let call1RequestID = LockedValue<AuthorizationRequestID?>(nil)
        let call2RequestID = LockedValue<AuthorizationRequestID?>(nil)

        let runtime = try runtime(
            consent: { request, _, _ in
                let count = consentCount.value
                consentCount.value = count + 1
                if count == 0 {
                    call1RequestID.value = request.id
                    call1ReachedPrompt.continuation.yield()
                    var iterator = call1AnswerStream.stream.makeAsyncIterator()
                    return await iterator.next()
                } else {
                    call2RequestID.value = request.id
                    call2ReachedPrompt.continuation.yield()
                    var iterator = call2AnswerStream.stream.makeAsyncIterator()
                    return await iterator.next()
                }
            },
            audit: audit,
            issuance: ImmediateIssuance(),
            consentTimeout: .seconds(60),
        )
        let interceptor = AuthorizationInterceptor(runtime: runtime)

        let cancellation1 = ServerContext.RPCCancellationHandle()
        let cancellation2 = ServerContext.RPCCancellationHandle()

        let call1HandlerReached = LockedValue(false)
        let call2HandlerReached = LockedValue(false)

        let call1 = Task {
            try await interceptor.intercept(
                request: Self.clipboardRequest(),
                context: Self.clipboardContext(cancellation: cancellation1),
                next: { _, _ -> StreamingServerResponse<Exactmac_V1_Clipboard> in
                    call1HandlerReached.value = true
                    return StreamingServerResponse(metadata: Metadata(), producer: { _ in Metadata() })
                },
            )
        }

        var it1 = call1ReachedPrompt.stream.makeAsyncIterator()
        _ = await it1.next()

        let call2 = Task {
            try await interceptor.intercept(
                request: Self.clipboardRequest(),
                context: Self.clipboardContext(cancellation: cancellation2),
                next: { _, _ -> StreamingServerResponse<Exactmac_V1_Clipboard> in
                    call2HandlerReached.value = true
                    return StreamingServerResponse(metadata: Metadata(), producer: { _ in Metadata() })
                },
            )
        }

        var it2 = call2ReachedPrompt.stream.makeAsyncIterator()
        _ = await it2.next()

        // Call 1 is answered first:
        try call1AnswerStream.continuation.yield(
            ConsentAnswer(
                requestID: XCTUnwrap(call1RequestID.value),
                isApproved: true,
                selected: .allowOnce,
            ),
        )
        _ = try await call1.value
        XCTAssertTrue(call1HandlerReached.value, "Call 1 handler was not reached")

        // Call 2 is answered second:
        try call2AnswerStream.continuation.yield(
            ConsentAnswer(
                requestID: XCTUnwrap(call2RequestID.value),
                isApproved: true,
                selected: .allowOnce,
            ),
        )
        _ = try await call2.value
        XCTAssertTrue(call2HandlerReached.value, "Call 2 handler was not reached")
    }
}
