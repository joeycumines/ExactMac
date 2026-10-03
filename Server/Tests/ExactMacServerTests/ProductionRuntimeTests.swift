import Darwin
import ExactMacProto
@testable import ExactMacServer
import Foundation
import GRPCCore
import XCTest

/// E2's acceptance suite: the server's own state, assembled for real.
///
/// THE PROPERTIES ARE ABOUT A RUNTIME THAT WAS ASSEMBLED, not about components in isolation.
/// Every one of these builds the production assembler against a real state directory, opens a
/// real audit log and a real grant store, and drives the real interceptor — because the
/// failure this task exists to fix is a runtime assembled from the refusing defaults, and no
/// test of `DecisionAudit` in isolation can see that.
final class ProductionRuntimeTests: XCTestCase {
    private var stateDirectory: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // The path is chosen here and the directory is NOT created here: creating it is what
        // `prepareStateDirectory` is under test for, and pre-creating it with the test
        // process's umask would hand the function a 0755 node and fail for a reason that has
        // nothing to do with it.
        stateDirectory = NSTemporaryDirectory() + "emc-e2-" + String(abs(UUID().uuidString.hashValue) % 1_000_000)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: stateDirectory)
        try super.tearDownWithError()
    }

    private func environment(
        consoleSocket: String? = nil,
    ) -> [String: String] {
        var environment: [String: String] = ["EXACTMAC_STATE_DIRECTORY": stateDirectory]
        environment["EXACTMAC_CONSOLE_SOCKET"] = consoleSocket ?? ""
        return environment
    }

    /// `ServerConfig` reads the process environment, which a test must not mutate, so the
    /// values under test are handed to the assembler explicitly and the rest come from the
    /// real reader.
    private func config(_ environment: [String: String]) -> ServerConfig {
        let read = ServerConfig.fromEnvironment()
        return ServerConfig(
            listenAddress: read.listenAddress,
            port: read.port,
            unixSocketPath: nil,
            consoleSocketPath: environment["EXACTMAC_CONSOLE_SOCKET"].flatMap { $0.isEmpty ? nil : $0 },
            consentTimeoutSeconds: read.consentTimeoutSeconds,
            maximumEnvelopeSeconds: read.maximumEnvelopeSeconds,
            defaultPosture: read.defaultPosture,
        )
    }

    // MARK: - The state the server owns

    /// The directory is created owner-only, and a second call is not an error — a server
    /// restarting finds it and must not treat its own state as foreign.
    func testTheStateDirectoryIsCreatedOwnerOnlyAndIsReusable() throws {
        try ExactMacRuntimePaths.prepareStateDirectory(environment: environment())
        let path = ExactMacRuntimePaths.stateDirectory(environment: environment())
        var info = stat()
        XCTAssertEqual(lstat(path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o700)
        XCTAssertNoThrow(try ExactMacRuntimePaths.prepareStateDirectory(environment: environment()))
    }

    /// A state directory that exists with the wrong mode is REFUSED, not repaired. Silently
    /// widening or retaking a directory the operator made is how a store this system treats
    /// as private stops being private.
    func testAStateDirectoryWithTheWrongModeIsRefusedRatherThanRepaired() throws {
        let path = ExactMacRuntimePaths.stateDirectory(environment: environment())
        try ExactMacRuntimePaths.prepareStateDirectory(environment: environment())
        XCTAssertEqual(chmod(path, 0o755), 0)
        XCTAssertThrowsError(try ExactMacRuntimePaths.prepareStateDirectory(environment: environment()))
    }

    /// Every path the server and the deployment documentation use is derived from one
    /// directory, so a disagreement about where state is cannot be expressed.
    ///
    /// The console socket and the console token used to be two more of these and are gone
    /// with the channel: neither is a path this process creates any more, and a path helper
    /// for a file nothing writes is a place for a deployment to point at something that does
    /// not exist.
    func testEveryPathComesFromOneDirectory() {
        let environment = environment()
        let directory = ExactMacRuntimePaths.stateDirectory(environment: environment)
        XCTAssertEqual(ExactMacRuntimePaths.auditLogPath(environment: environment), directory + "/audit.log")
        XCTAssertEqual(ExactMacRuntimePaths.grantStorePath(environment: environment), directory + "/grants.json")
    }

    // MARK: - The assembled runtime

    /// The assembler produces a runtime with a REAL grant store and a REAL audit, and it says
    /// so rather than leaving the refusing defaults in place by accident. Each of those
    /// defaults is safe — they deny — and together they are a system that cannot do anything
    /// while looking as though it is running, which is the failure this suite is about.
    ///
    /// The consent default is STILL a refusing default and is asserted as such rather than
    /// papered over: the operator interface is hosted in the process that builds this runtime,
    /// and nothing has installed one yet, so `consent` is nil and every consent-requiring
    /// capability is denied. That is the honest state of the build, and a test that called it
    /// a "real consent broker" would be asserting something untrue.
    func testTheAssembledRuntimeUsesARealAuditAndARealGrantStoreAndNamesItsConsentPosture() throws {
        let environment = environment(consoleSocket: stateDirectory + "/console.sock")
        let runtime = try ProductionAuthorizationRuntime.make(
            config: config(environment),
            environment: environment,
        )

        XCTAssertTrue(runtime.auditPath.hasSuffix("/audit.log"))
        XCTAssertTrue(runtime.grantStorePath.hasSuffix("/grants.json"))

        // A grant that is not a placeholder: the store round-trips through the file.
        let store = try GrantStore.openStore(
            path: runtime.grantStorePath,
            clock: SystemMonotonicClock(),
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: runtime.grantStorePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: runtime.auditPath))
        XCTAssertTrue(store.liveGrants().isEmpty)

        // And the consent posture is stated, not inferred. This process presents the prompt
        // itself, so there is no channel to configure and no socket to assert on; the posture
        // is entirely a fact about whether a consent handler is installed.
        XCTAssertNil(
            runtime.authorizationRuntime.consent,
            "no operator interface is installed, so there is nobody to ask",
        )
        XCTAssertFalse(
            runtime.authorizationRuntime.isConsoleReachable(),
            "reachability must agree with the absent handler, or the two fail-closed separately",
        )
    }

    /// A state directory the server cannot use is a STARTUP FAILURE, not a fallback. A server
    /// that starts with an unusable audit log has no reason to be listening, and one that
    /// starts with an unreadable grant store is exactly the state in which it must not be
    /// granting things.
    func testAnUnusableStateDirectoryFailsStartupRatherThanFallingBack() throws {
        let blocked = NSTemporaryDirectory() + "emc-e2-blocked-" + String(abs(UUID().uuidString.hashValue) % 1_000_000)
        try FileManager.default.createDirectory(atPath: blocked, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: blocked) }
        try marker(at: blocked)

        let environment = ["EXACTMAC_STATE_DIRECTORY": blocked]
        XCTAssertThrowsError(
            try ProductionAuthorizationRuntime.make(config: config(environment), environment: environment),
            "a state path that is a file must not be adopted",
        )
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: blocked)), Data("not-a-directory".utf8))
    }

    // MARK: - The audit is on the path, not beside it

    /// The ALLOWED half: a decision that permits is on the record before the handler runs.
    ///
    /// A standing grant rather than a no-consent capability, because `localEcho` has exactly
    /// one member in the whole API and binding a security test to a single method's
    /// classification makes it a test of that classification rather than of the recording.
    func testAnAllowedDecisionIsRecordedBeforeTheHandlerRuns() async throws {
        let recorder = RecordingAuditSpy()
        let descriptorPolicy = try PublicRequestDescriptorPolicy.load()
        let runtime = AuthorizationRuntime.unixSocket(
            descriptorPolicy: descriptorPolicy,
            grants: FixedGrantSupply(grants: [Self.clipboardGrant]),
            isConsoleReachable: false,
            peerEvidence: .fixed(Self.thisProcess),
            audit: recorder,
            auditRequired: true,
        )
        let interceptor = AuthorizationInterceptor(runtime: runtime)

        let context = try await Self.context(method: "GetClipboard")
        do {
            _ = try await interceptor.intercept(
                request: Self.request(Exactmac_V1_GetClipboardRequest.with { $0.name = "clipboard" }),
                context: context,
                next: { _, _ -> StreamingServerResponse<Exactmac_V1_Clipboard> in
                    XCTAssertEqual(recorder.decisions.count, 1, "the record precedes the handler")
                    throw RPCError(code: .internalError, message: "the handler was reached")
                },
            )
            XCTFail("the handler throws, so this must throw")
        } catch {
            XCTAssertEqual(recorder.decisions.count, 1)
            XCTAssertEqual(recorder.decisions.first?.outcome, .allow)
            guard let basis = recorder.decisions.first?.basis else {
                return XCTFail("the decision was not recorded")
            }
            guard case .grant = basis else {
                return XCTFail("the recorded basis must name the grant that authorized it, got \(basis)")
            }
        }
    }

    /// The REFUSED half: a decision that denies is on the record too. The half that is easy to
    /// omit, and a log that records what was permitted cannot be asked what was refused.
    func testARefusedDecisionIsRecordedAndNoHandlerRuns() async throws {
        let recorder = RecordingAuditSpy()
        let descriptorPolicy = try PublicRequestDescriptorPolicy.load()
        let runtime = AuthorizationRuntime.unixSocket(
            descriptorPolicy: descriptorPolicy,
            isConsoleReachable: false,
            peerEvidence: .fixed(Self.thisProcess),
            audit: recorder,
            auditRequired: true,
        )
        let interceptor = AuthorizationInterceptor(runtime: runtime)
        let entered = Counter()
        let context = try await Self.context(method: "ExecuteShellCommand")
        do {
            _ = try await interceptor.intercept(
                request: Self.request(Exactmac_V1_ExecuteShellCommandRequest()),
                context: context,
                next: { _, _ -> StreamingServerResponse<Exactmac_V1_ExecuteShellCommandResponse> in
                    entered.increment()
                    throw RPCError(code: .internalError, message: "the handler was reached")
                },
            )
            XCTFail("a mutator with no console must be refused")
        } catch {
            XCTAssertEqual(entered.value, 0, "a refusal must not reach a handler")
        }
        XCTAssertEqual(recorder.decisions.count, 1, "the refusal is on the record as well")
        XCTAssertEqual(recorder.decisions.first?.outcome, .deny)
    }

    /// A decision that could not be recorded is a REFUSAL when the runtime requires the
    /// record. The alternative is a server that grants things it cannot account for, which is
    /// the exact failure the hash chain exists to make visible.
    func testAnUnrecordableDecisionIsRefusedWhenTheRecordIsRequired() async throws {
        let recorder = RecordingAuditSpy()
        let descriptorPolicy = try PublicRequestDescriptorPolicy.load()
        // The operator is reachable but there is nobody to ask: this runtime's consent is the
        // default nil, which is the state the server is in until the host installs one.
        let runtime = AuthorizationRuntime.unixSocket(
            descriptorPolicy: descriptorPolicy,
            isConsoleReachable: true,
            peerEvidence: .fixed(Self.thisProcess),
            audit: FailingAuditSpy(),
            auditRequired: true,
        )
        let interceptor = AuthorizationInterceptor(runtime: runtime)
        let context = try await Self.context(method: "ValidateScript")
        do {
            _ = try await interceptor.intercept(
                request: Self.request(Exactmac_V1_ValidateScriptRequest()),
                context: context,
                next: { _, _ -> StreamingServerResponse<Exactmac_V1_ValidateScriptResponse> in
                    recorder.entered = true
                    throw RPCError(code: .internalError, message: "reached the handler")
                },
            )
            XCTFail("a decision that cannot be recorded must not be enforced")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .permissionDenied)
        }
        XCTAssertFalse(recorder.entered, "an unrecordable decision must not reach a handler")
    }

    /// Without a recorder and without the requirement, the interceptor behaves as it always
    /// did. That is what makes `auditRequired: false` a STATED POSTURE for a test fixture
    /// rather than a way to run production without an audit.
    func testARuntimeWithoutARecorderIsUnaffectedUnlessTheRecordIsRequired() async throws {
        let recorder = RecordingAuditSpy()
        let descriptorPolicy = try PublicRequestDescriptorPolicy.load()
        let runtime = AuthorizationRuntime.unixSocket(
            descriptorPolicy: descriptorPolicy,
            isConsoleReachable: true,
            peerEvidence: .fixed(Self.thisProcess),
        )
        let interceptor = AuthorizationInterceptor(runtime: runtime)
        let context = try await Self.context(method: "ValidateScript")
        do {
            _ = try await interceptor.intercept(
                request: Self.request(Exactmac_V1_ValidateScriptRequest()),
                context: context,
                next: { _, _ -> StreamingServerResponse<Exactmac_V1_ValidateScriptResponse> in
                    recorder.entered = true
                    throw RPCError(code: .internalError, message: "reached the handler")
                },
            )
            XCTFail("the handler throws, so this must throw")
        } catch {
            XCTAssertTrue(recorder.entered, "without a recorder the decision still stands")
        }
    }

    // MARK: - Fixtures

    private func marker(at path: String) throws {
        // An interrupted earlier run may have left a DIRECTORY here, and writing a file over
        // one fails — which would fail this test for a reason that is not the one under test.
        try? FileManager.default.removeItem(atPath: path)
        try Data("not-a-directory".utf8).write(to: URL(fileURLWithPath: path))
    }

    /// A grant that authorizes a clipboard read for the identity the runtime ACTUALLY
    /// resolves, which in a test process is the test binary. A hard-coded path would be a
    /// grant nothing satisfies, and the engine's answer to that is the consent path — a
    /// failure that looks like a wiring bug and is not one.
    private static let clipboardGrant = Grant(
        id: "grant-test",
        capability: .clipboardRead,
        scope: AuthorizationScope(),
        duration: .monotonicSeconds(60),
        holder: bindingOfThisProcess(),
        issuedAt: MonotonicInstant(nanoseconds: 0),
        expiresAt: MonotonicInstant(nanoseconds: UInt64.max),
        origin: .prompt(decidedAt: MonotonicInstant(nanoseconds: 0)),
        remainingOperations: nil,
        targetIsHighConsequence: false,
    )

    private static func bindingOfThisProcess() -> CodeBinding {
        let identity = SystemProcessInspector().codeIdentity(processIdentifier: getpid())
        guard let identity else {
            preconditionFailure("the test process has no resolvable code identity")
        }
        return identity.binding
    }

    private static let thisProcess = PeerProcessEvidence(
        processIdentifier: getpid(),
        effectiveUserIdentifier: getuid(),
    )

    private static func request<Input: Sendable>(_ message: Input) -> StreamingServerRequest<Input> {
        StreamingServerRequest(
            metadata: GRPCCore.Metadata(),
            messages: RPCAsyncSequence<Input, any Error>(wrapping: AsyncThrowingStream { continuation in
                continuation.yield(message)
                continuation.finish()
            }),
        )
    }

    private static func context(method: String) async throws -> ServerContext {
        try await withServerContextRPCCancellationHandle { cancellation in
            ServerContext(
                descriptor: MethodDescriptor(
                    service: ServiceDescriptor(fullyQualifiedService: RPCAuthorizationMap.serviceName),
                    method: method,
                ),
                remotePeer: "unix:/test/listener.sock",
                localPeer: "unix:/test/listener.sock",
                cancellation: cancellation,
            )
        }
    }
}

/// A supply that hands the engine a fixed set of grants, so the allowed half of the audit
/// suite is about the RECORDING rather than about how a grant came to exist.
private struct FixedGrantSupply: GrantSupply {
    var grants: [Grant]

    func snapshot() async -> GrantSnapshot {
        GrantSnapshot(grants: grants)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.withLock { count += 1 }
    }

    var value: Int {
        lock.withLock { count }
    }
}

private final class RecordingAuditSpy: DecisionRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [AuthorizationDecision] = []
    private var refusals: [DenialReason?] = []
    var entered = false

    var decisions: [AuthorizationDecision] {
        lock.withLock { recorded }
    }

    /// WHY each recorded decision was refused, in the order they were recorded.
    ///
    /// A `nil` is a decision that was NOT refused — an allow. It is captured rather than
    /// derived because the question invariant 1 asks is "is the refusal on the record", and
    /// answering that from the decision alone would be the mistake this spy exists to catch:
    /// a `.promptRequired` basis reads as "asked a person" and says nothing about whether
    /// anyone answered.
    var refusalReasons: [DenialReason?] {
        lock.withLock { refusals }
    }

    @discardableResult
    func record(
        request _: AuthorizationRequest,
        identity _: CallerIdentity,
        decision: AuthorizationDecision,
        operatorNote _: String?,
        biometricObtained _: Bool,
        refusalReason: DenialReason?,
    ) -> Bool {
        lock.withLock {
            recorded.append(decision)
            refusals.append(refusalReason)
        }
        return true
    }
}

private struct FailingAuditSpy: DecisionRecording {
    @discardableResult
    func record(
        request _: AuthorizationRequest,
        identity _: CallerIdentity,
        decision _: AuthorizationDecision,
        operatorNote _: String?,
        biometricObtained _: Bool,
        refusalReason _: DenialReason?,
    ) -> Bool {
        false
    }
}
