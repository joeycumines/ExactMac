import Darwin
import ExactMacProto
@testable import ExactMacServer
import Foundation
import GRPCCore
import XCTest

/// Acceptance tests for E33: Consent wait cancellation and prompt dismissal.
///
/// Invariant: When the caller's context is cancelled (via `ServerContext.RPCCancellationHandle`
/// or Swift task cancellation), the consent wait ends immediately instead of waiting for the
/// full bound. The timer sleep is shortened by cancellation, the ask task is cancelled to
/// dismiss the prompt in the operator UI, and no audit entry is written for an abandoned request.
final class ConsentWaitCancellationTests: XCTestCase {
    private var logPath: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        logPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("exactmac-cancellation-audit-\(UUID().uuidString).jsonl").path
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

    private func entries() throws -> [AuditEntry] {
        try AuditEntry.readAll(from: logPath).whole
    }

    private func runtime(
        consent: ConsentAnswering?,
        audit: DecisionAudit,
        consentTimeout: Duration = .seconds(60),
    ) throws -> AuthorizationRuntime {
        var runtime = try AuthorizationRuntime.unixSocket(
            descriptorPolicy: PublicRequestDescriptorPolicy.load(),
            consent: consent,
            issuance: NoGrantIssuance(),
            clock: FixedClock(),
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

    private static func clipboardRequest() -> StreamingServerRequest<Exactmac_V1_GetClipboardRequest> {
        let message = Exactmac_V1_GetClipboardRequest.with { $0.name = "clipboard" }
        return StreamingServerRequest(
            metadata: Metadata(),
            messages: RPCAsyncSequence<Exactmac_V1_GetClipboardRequest, any Error>(wrapping: AsyncThrowingStream { continuation in
                continuation.yield(message)
                continuation.finish()
            }),
        )
    }

    private static func context(cancellation: ServerContext.RPCCancellationHandle) -> ServerContext {
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

    // MARK: - Tests

    /// When caller context is cancelled mid-wait, the consent wait returns promptly (< 1s vs 60s timeout)
    /// and throws RPCError.cancelled without writing any audit entry.
    func testCallerCancellationAbortsConsentWaitPromptlyAndWritesNoAuditEntry() async throws {
        let audit = try makeAudit()
        let askedStream = AsyncStream<Void>.makeStream()
        let cancellation = ServerContext.RPCCancellationHandle()

        let runtime = try runtime(
            consent: { _, _, _ in
                askedStream.continuation.yield()
                try? await Task.sleep(for: .seconds(30))
                return nil
            },
            audit: audit,
            consentTimeout: .seconds(60),
        )
        let interceptor = AuthorizationInterceptor(runtime: runtime)

        let task = Task {
            try await interceptor.intercept(
                request: Self.clipboardRequest(),
                context: Self.context(cancellation: cancellation),
                next: { _, _ -> StreamingServerResponse<Exactmac_V1_Clipboard> in
                    throw RPCError(code: .internalError, message: "handler reached")
                },
            )
        }

        var iterator = askedStream.stream.makeAsyncIterator()
        _ = await iterator.next()

        let cancelTime = ContinuousClock.now
        cancellation.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected RPCError.cancelled but call succeeded")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .cancelled)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let elapsed = ContinuousClock.now - cancelTime
        XCTAssertLessThan(
            elapsed,
            .seconds(1),
            "Cancellation took too long (\(elapsed)) — timer sleep was not shortened!",
        )

        let verification = audit.verify()
        XCTAssertEqual(verification.entryCount, 0, "abandoned request wrote to audit log")
        XCTAssertTrue(try entries().isEmpty)
    }

    /// When caller context is already cancelled upfront, intercept returns immediately without
    /// ever asking the operator or writing to audit.
    func testAlreadyCancelledCallerReturnsImmediatelyWithoutAsking() async throws {
        let audit = try makeAudit()
        let cancellation = ServerContext.RPCCancellationHandle()
        cancellation.cancel()

        let consentAsked = LockedValue(false)
        let runtime = try runtime(
            consent: { _, _, _ in
                consentAsked.value = true
                return nil
            },
            audit: audit,
            consentTimeout: .seconds(60),
        )
        let interceptor = AuthorizationInterceptor(runtime: runtime)

        let start = ContinuousClock.now
        do {
            _ = try await interceptor.intercept(
                request: Self.clipboardRequest(),
                context: Self.context(cancellation: cancellation),
                next: { _, _ -> StreamingServerResponse<Exactmac_V1_Clipboard> in
                    throw RPCError(code: .internalError, message: "handler reached")
                },
            )
            XCTFail("Expected RPCError.cancelled")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .cancelled)
        }

        let elapsed = ContinuousClock.now - start
        XCTAssertLessThan(elapsed, .milliseconds(200))
        XCTAssertFalse(consentAsked.value, "consent was asked for an already cancelled call")

        let verification = audit.verify()
        XCTAssertEqual(verification.entryCount, 0)
    }

    /// Task cancellation also shortens the wait and produces cancelled outcome.
    func testTaskCancellationAbortsConsentWaitPromptly() async throws {
        let audit = try makeAudit()
        let askedStream = AsyncStream<Void>.makeStream()
        let cancellation = ServerContext.RPCCancellationHandle()

        let runtime = try runtime(
            consent: { _, _, _ in
                askedStream.continuation.yield()
                try? await Task.sleep(for: .seconds(30))
                return nil
            },
            audit: audit,
            consentTimeout: .seconds(60),
        )
        let interceptor = AuthorizationInterceptor(runtime: runtime)

        let task = Task {
            try await interceptor.intercept(
                request: Self.clipboardRequest(),
                context: Self.context(cancellation: cancellation),
                next: { _, _ -> StreamingServerResponse<Exactmac_V1_Clipboard> in
                    throw RPCError(code: .internalError, message: "handler reached")
                },
            )
        }

        var iterator = askedStream.stream.makeAsyncIterator()
        _ = await iterator.next()

        let cancelTime = ContinuousClock.now
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation error")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .cancelled)
        } catch is CancellationError {
            // CancellationError is acceptable for task cancellation
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let elapsed = ContinuousClock.now - cancelTime
        XCTAssertLessThan(elapsed, .seconds(1))
        XCTAssertEqual(audit.verify().entryCount, 0)
    }

    /// Caller cancellation explicitly signals cancellation to the underlying prompt ask task.
    func testAskTaskCancellationIsSignalledWhenRPCCancelled() async throws {
        let audit = try makeAudit()
        let askedStream = AsyncStream<Void>.makeStream()
        let taskWasCancelledStream = AsyncStream<Void>.makeStream()
        let cancellation = ServerContext.RPCCancellationHandle()

        let runtime = try runtime(
            consent: { _, _, _ in
                askedStream.continuation.yield()
                return await withTaskCancellationHandler {
                    try? await Task.sleep(for: .seconds(30))
                    return nil
                } onCancel: {
                    taskWasCancelledStream.continuation.yield()
                }
            },
            audit: audit,
            consentTimeout: .seconds(60),
        )
        let interceptor = AuthorizationInterceptor(runtime: runtime)

        let task = Task {
            try await interceptor.intercept(
                request: Self.clipboardRequest(),
                context: Self.context(cancellation: cancellation),
                next: { _, _ -> StreamingServerResponse<Exactmac_V1_Clipboard> in
                    throw RPCError(code: .internalError, message: "handler reached")
                },
            )
        }

        var iterator = askedStream.stream.makeAsyncIterator()
        _ = await iterator.next()

        cancellation.cancel()

        var cancelIterator = taskWasCancelledStream.stream.makeAsyncIterator()
        let receivedTaskCancel: Void? = await cancelIterator.next()
        XCTAssertNotNil(receivedTaskCancel, "The consent prompt's Task was not cancelled!")

        _ = try? await task.value
    }
}
