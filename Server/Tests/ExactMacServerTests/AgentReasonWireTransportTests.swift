import ExactMacProto
@testable import ExactMacServer
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
import SwiftProtobuf
import XCTest

/// E12's acceptance, at the layer its text names: a reason carrying multibyte runes
/// crosses a REAL client transport — a gRPC client over a socket, not in-process
/// metadata construction — and reaches the server handler with the reason byte-identical,
/// and the response is a real result rather than an Internal error.
///
/// The in-process tests prove the parse (`AuthorizationInterceptor.agentReason(from:)`)
/// and the Go tests prove the outgoing metadata map; NEITHER crosses a transport, and the
/// reason has to survive HTTP/2 framing, the `-bin` metadata encoding and the server's
/// own decode to be a reason at all. The consent handler is the capture point: it sees
/// the derived `AuthorizationRequest` exactly as the server holds it, and the approval it
/// returns is what lets the call reach the handler — the client receiving a real
/// clipboard response is the proof the handler ran.
final class AgentReasonWireTransportTests: XCTestCase {
    /// Em dash, curly quotes, accents, emoji and CJK — the acceptance's own list, plus a
    /// combining sequence that must survive as written rather than normalised away.
    private static let multibyteReason =
        "总结 you asked about — “curly” café 👍 brève — \u{0065}\u{0301} combining"

    private final class CapturingConsent: @unchecked Sendable {
        private let lock = NSLock()
        private var captured: (AuthorizationRequest, AuthorizationDecision)?

        var answering: ConsentAnswering {
            { request, _, decision in
                self.lock.withLock { self.captured = (request, decision) }
                // A ceremony is minted when the decision demanded one, dated against the
                // system clock the server validates against — a fixed fixture would be
                // expired before it was checked.
                let now = MonotonicInstant.now()
                let proof: BiometricProof?
                if let nonce = decision.ceremonyNonce {
                    proof = BiometricProof(
                        requestID: request.id,
                        nonce: nonce,
                        decidedAt: now,
                        expiresAt: now.advanced(by: .seconds(120)),
                    )
                } else {
                    proof = nil
                }
                return ConsentAnswer(
                    requestID: request.id,
                    isApproved: true,
                    selected: .allowOnce,
                    ceremonyProof: proof,
                )
            }
        }

        var capturedRequest: AuthorizationRequest? {
            lock.withLock { captured?.0 }
        }
    }

    func testAMultibyteReasonCrossesARealTransportByteIdentical() async throws {
        let policy = try PublicRequestDescriptorPolicy.load()
        let clock = SystemMonotonicClock()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("exactmac-reason-wire-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let grantStore = try GrantStore.openStore(
            path: directory.appendingPathComponent("grants.json").path,
            clock: clock,
            maximumEnvelopeSeconds: 3600,
        )
        let consent = CapturingConsent()
        var runtime = AuthorizationRuntime.unixSocket(
            descriptorPolicy: policy,
            grants: GrantStoreSupply(store: grantStore),
            issuance: GrantStoreIssuance(store: grantStore),
            isConsoleReachable: true,
            peerEvidence: .fixed(
                PeerProcessEvidence(
                    processIdentifier: getpid(),
                    effectiveUserIdentifier: getuid(),
                ),
            ),
        )
        runtime.consent = consent.answering

        // MOCKS, not production systems: the composition's default construction reaches
        // for real hardware observers, and a test about metadata framing must not depend
        // on what is on screen.
        // MOCKS, not production systems: the composition's defaults reach for real
        // hardware observers and the real pasteboard, and a test about metadata framing
        // must depend on neither.
        let composition = ExactMacServiceComposition(
            system: MockSystemOperations(),
            clipboardPasteboard: StubClipboardPasteboard(),
        )
        // THE LIFETIMES THE RUNTIME STARTS IN PRODUCTION, started here: without them the
        // handlers that consult them can wait forever, and a test that hangs reports
        // nothing. This is the same pair `ServerRuntime.serve` starts before the transport.
        try await composition.sessionManager.startCleanup()
        try await composition.elementRegistry.startCleanup()
        // The socket sits directly under /tmp like the transport suite's own fixtures: a
        // Unix socket bind inside a nested temporary directory has a length limit the
        // bind can exceed, and the failure would look like a timeout.
        let socketPath = "/tmp/exactmac-reason-wire-\(UUID().uuidString).sock"
        let serverTransport = HTTP2ServerTransport.Posix(
            address: .unixDomainSocket(path: socketPath),
            transportSecurity: .plaintext,
        )
        let server = GRPCServer(
            transport: productionServerTransport(serverTransport),
            services: [composition.exactMacService],
            interceptors: productionServerInterceptors(
                AuthorizationInterceptor(runtime: runtime),
            ),
        )
        let serverTask = Task { try await server.serve() }
        defer {
            server.beginGracefulShutdown()
        }
        try await pollUntil("server bind") {
            FileManager.default.fileExists(atPath: socketPath)
        }

        let clientTransport = try HTTP2ClientTransport.Posix(
            target: .unixDomainSocket(path: socketPath),
            transportSecurity: .plaintext,
        )
        let client = GRPCClient(transport: clientTransport)
        let connectionTask = Task { try await client.runConnections() }
        defer {
            client.beginGracefulShutdown()
            connectionTask.cancel()
        }

        var metadata = Metadata()
        metadata.addBinary(
            Array(Self.multibyteReason.utf8),
            forKey: AuthorizationInterceptor.agentReasonMetadataKey,
        )
        metadata.addString("mcp", forKey: AuthorizationInterceptor.mcpProxyMetadataKey)

        // THE CALL CROSSES THE TRANSPORT: a real HTTP/2 connection over a socket, and the
        // response is the handler's own output. An Internal error here is the failure E12
        // described, and the assertion below would never have been reached.
        let clipboard = try await client.unary(
            request: ClientRequest(
                message: Exactmac_V1_GetClipboardRequest.with { $0.name = "clipboard" },
                metadata: metadata,
            ),
            descriptor: Exactmac_V1_ExactMac.Method.GetClipboard.descriptor,
            serializer: ProtobufSerializer<Exactmac_V1_GetClipboardRequest>(),
            deserializer: ProtobufDeserializer<Exactmac_V1_Clipboard>(),
            options: {
                var options = CallOptions.defaults
                // THE SHAPE THE TRANSPORT SUITE ITSELF USES. waitForReady keeps the call
                // queued until the connection is up rather than failing it on a race, and
                // the timeout is the bound that turns "never answered" into a reported
                // failure instead of a hung suite.
                options.waitForReady = true
                options.timeout = .seconds(15)
                return options
            }(),
        ) { response in
            try response.message
        }
        XCTAssertEqual(clipboard.name, "clipboard")

        // AND THE REASON THE SERVER HELD IS THE REASON THE AGENT SENT, byte for byte.
        let captured = try XCTUnwrap(
            consent.capturedRequest,
            "the call reached the handler without the server ever asking",
        )
        XCTAssertEqual(captured.rpcName, "\(RPCAuthorizationMap.serviceName)/GetClipboard")
        XCTAssertEqual(captured.agentReason, Self.multibyteReason)
        XCTAssertEqual(
            Data((captured.agentReason ?? "").utf8),
            Data(Self.multibyteReason.utf8),
            "the reason was altered in transit",
        )

    }

    /// The pasteboard stub, because reading the REAL general pasteboard from a test
    /// crosses into whatever the machine happens to hold.
    private actor StubClipboardPasteboard: ClipboardPasteboard {
        func read() -> Exactmac_V1_Clipboard {
            Exactmac_V1_Clipboard.with { $0.name = "clipboard" }
        }

        func changeCount() -> Int { 0 }

        func clear() {}

        func write(_: Exactmac_V1_ClipboardContent) -> Bool { true }
    }

    private func pollUntil(
        _ name: String,
        deadline: ContinuousClock.Instant = .now + .seconds(10),
        condition: @escaping () -> Bool,
    ) async throws {
        while !condition() {
            if ContinuousClock.now >= deadline {
                // A failure, not a skip: the server failing to bind is the failure under
                // test, and a skip would report a green suite for a server that never ran.
                struct BindTimeout: Error { let name: String }
                throw BindTimeout(name: name)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
