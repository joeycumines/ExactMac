import Darwin
import ExactMacProto
@testable import ExactMacServer
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
import NIOCore
import NIOPosix
import XCTest

/// E1's acceptance suite.
///
/// EVERYTHING HERE RUNS OVER REAL SOCKETS AND THE REAL TRANSPORT, because the claim under
/// test is that the kernel's answer reaches the authorization layer, and a fixture that
/// answered on the kernel's behalf would be asserting nothing. Four properties are
/// established: a peer that names its socket is identified with THIS process's own pid and
/// uid, read from `LOCAL_PEERPID` and `LOCAL_PEERCRED` on the accepted channel; a peer that
/// names nothing is carried but cannot be attributed, and a caller nothing can identify is
/// refused every capability; a closed connection's token stops resolving and a late retire
/// cannot take away the token a later connection has claimed; and something that is not an
/// AF_UNIX stream is refused at accept rather than carried.
final class PeerIdentificationTests: XCTestCase {
    /// Runs `body` against a live harness and ALWAYS tears the harness down before returning.
    ///
    /// THE TEARDOWN IS AWAITED, and that is not tidiness. A `defer { Task { ... } }` hands the
    /// shutdown to a task nothing waits for, so the next test can start while the previous
    /// server is still closing its event loops — and an event loop that shuts down under a
    /// live stream releases that stream's writer unfinished, which SwiftNIO answers with a
    /// `Fatal error` that kills the whole test process rather than failing one test. The
    /// symptom appeared as whichever test ran second failing to connect, which looked like a
    /// transport fault and was not one.
    private func withHarness(
        _ body: (PeerIdentifyingHarness) async throws -> Void,
    ) async throws {
        let harness = try await PeerIdentifyingHarness.start()
        do {
            try await body(harness)
        } catch {
            await harness.stop()
            throw error
        }
        await harness.stop()
    }

    // MARK: - The kernel names the connecting process

    /// The whole of E1 in one assertion: a real accepted AF_UNIX connection, identified by
    /// the kernel as this very process, reachable by the token the transport will report.
    func testTheKernelIdentifiesTheConnectingProcessOnTheAcceptedSocket() async throws {
        try await withHarness { harness in
            let peerName = harness.directory.appending("peer.sock")

            let client = try UnixClient(connectTo: harness.socketPath, bindingPeerNameTo: peerName)
            defer { client.close() }

            let evidence = try await harness.evidence(forPeerName: peerName)
            XCTAssertEqual(evidence.processIdentifier, getpid(), "the kernel named another process")
            XCTAssertEqual(evidence.effectiveUserIdentifier, geteuid())
            XCTAssertEqual(harness.registry.liveCount, 1)
        }
    }

    /// The token the transport reports is the peer's own pathname, which is the only
    /// per-connection value `ServerContext` carries.
    func testTheTokenIsThePeersOwnSocketName() async throws {
        try await withHarness { harness in
            let peerName = harness.directory.appending("named-peer.sock")

            let client = try UnixClient(connectTo: harness.socketPath, bindingPeerNameTo: peerName)
            defer { client.close() }

            try await XCTAssertEventually("the connection was identified and registered") {
                harness.registry.evidence(forPeerDescription: "unix:\(peerName)") != nil
            }
            let token = try XCTUnwrap(PeerConnectionToken(peerDescription: "unix:\(peerName)"))
            XCTAssertEqual(token.pathname, peerName)
        }
    }

    // MARK: - A peer that names nothing

    /// CARRIED BUT UNATTRIBUTABLE, proved by carrying a real RPC over it.
    ///
    /// The earlier version of this test connected, then connected again and watched the
    /// second one register, which would also have passed had the first been REFUSED — so it
    /// did not establish the thing its name claimed. A full gRPC exchange over the unnamed
    /// connection establishes both halves at once: the server spoke HTTP/2 on it, so it was
    /// carried, and the RPC was refused, so carrying it bought the caller nothing.
    func testAnUnnamedPeerCarriesRealTrafficAndIsRefused() async throws {
        try await withHarness { harness in
            let client = try GRPCClient(
                transport: .http2NIOPosix(
                    target: .unixDomainSocket(path: harness.socketPath),
                    transportSecurity: .plaintext,
                ),
            )
            // The client and the calls share a task group because `runConnections` does not
            // return until the client shuts down, so awaiting it before making a call would
            // wait for the call it is meant to be waiting for.
            try await withThrowingDiscardingTaskGroup { group in
                group.addTask { try await client.runConnections() }
                do {
                    let _: Exactmac_V1_Clipboard = try await client.unary(
                        request: ClientRequest(message: Exactmac_V1_GetClipboardRequest.with {
                            $0.name = "clipboard"
                        }),
                        descriptor: Exactmac_V1_ExactMac.Method.GetClipboard.descriptor,
                        serializer: ProtobufSerializer<Exactmac_V1_GetClipboardRequest>(),
                        deserializer: ProtobufDeserializer<Exactmac_V1_Clipboard>(),
                        options: .defaults,
                    ) { response in
                        try response.message
                    }
                    XCTFail("a caller nothing can identify must be refused")
                } catch let error as RPCError {
                    XCTAssertEqual(error.code, .permissionDenied)
                    XCTAssertEqual(
                        try extractErrorInfo(from: error).reason,
                        DenialReason.unauthenticatedPeer.rawValue,
                    )
                }
                client.beginGracefulShutdown()
            }

            XCTAssertEqual(harness.counters.counts[DenialReason.unauthenticatedPeer.rawValue], 1)
            XCTAssertEqual(
                harness.registry.liveCount, 0,
                "an unnamed peer must register nothing, because there is no token to register it under",
            )
            // And an empty pathname is refused as a token, which is the same absence the
            // transport's Unix-socket fallback produces for an unnamed peer.
            XCTAssertNil(PeerConnectionToken(peerDescription: "unix:"))
        }
    }

    /// The listener keeps identifying after an unattributable connection, which is the other
    /// half of "carried": the accept path is not left in a state where one refused
    /// attribution poisons the next connection.
    func testTheListenerKeepsIdentifyingAfterAnUnnamedPeer() async throws {
        try await withHarness { harness in
            let anonymous = try UnixClient(connectTo: harness.socketPath, bindingPeerNameTo: nil)
            defer { anonymous.close() }
            let named = harness.directory.appending("after-anonymous.sock")
            let second = try UnixClient(connectTo: harness.socketPath, bindingPeerNameTo: named)
            defer { second.close() }
            _ = try await harness.evidence(forPeerName: named)

            XCTAssertEqual(harness.registry.liveCount, 1)
        }
    }

    /// The end of the fail-closed chain: a caller nothing can identify is refused, the
    /// refusal names the reason, and no handler runs.
    func testAnUnidentifiableCallerIsRefusedAndNoHandlerRuns() async throws {
        let policy = try PublicRequestDescriptorPolicy.load()
        let counters = AuthorizationCounters()
        let handler = HandlerEntry()
        let runtime = AuthorizationRuntime.unixSocket(
            descriptorPolicy: policy,
            postureSource: PostureSource(override: nil),
            isConsoleReachable: true,
            peerEvidence: .fixed(nil),
        )
        let interceptor = AuthorizationInterceptor(runtime: runtime, counters: counters)

        // The peer's description for a connection nothing can attribute is the listener's
        // own path, because that is what the transport's Unix-socket fallback produces.
        do {
            _ = try await interceptor.intercept(
                request: Self.request(Exactmac_V1_GetClipboardRequest.with { $0.name = "clipboard" }),
                context: Self.context(peer: "unix:/some/listener.sock"),
                next: { _, _ in
                    handler.wasEntered = true
                    throw RPCError(code: .internalError, message: "the handler was reached")
                },
            ) as StreamingServerResponse<Exactmac_V1_Clipboard>
            XCTFail("a caller nothing can identify must be refused")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .permissionDenied)
            // The reason travels in the `google.rpc.ErrorInfo` the status carries, not as
            // loose metadata, so that is where the caller-visible contract is asserted.
            XCTAssertEqual(try extractErrorInfo(from: error).reason, DenialReason.unauthenticatedPeer.rawValue)
        }
        XCTAssertFalse(handler.wasEntered)
        XCTAssertEqual(counters.counts[DenialReason.unauthenticatedPeer.rawValue], 1)
    }

    // MARK: - A closed connection

    /// A closed connection stops resolving, so a call on it can never be authorized against
    /// a token that has since been released.
    func testAClosedConnectionStopsResolving() async throws {
        try await withHarness { harness in
            let peerName = harness.directory.appending("closing-peer.sock")

            let client = try UnixClient(connectTo: harness.socketPath, bindingPeerNameTo: peerName)
            try await XCTAssertEventually("the connection was registered") {
                harness.registry.evidence(forPeerDescription: "unix:\(peerName)") != nil
            }
            client.close()

            try await XCTAssertEventually("the token is retired when the connection closes") {
                harness.registry.evidence(forPeerDescription: "unix:\(peerName)") == nil
            }
        }
    }

    /// A retire that arrives after another connection has already taken the same token must
    /// not take it away from the connection that holds it.
    ///
    /// THE SEQUENCE IS REAL AND THE WINDOW IS REAL: the first connection closes, releasing
    /// the pathname, and the second binds it and connects — while the first connection's
    /// `channelInactive` can still be in flight. A registry that retired by token alone would
    /// deny the second caller for a fault of the first.
    func testALateRetireDoesNotRetireTheConnectionThatTookTheToken() throws {
        let registry = ConnectionPeerRegistry()
        let token = try XCTUnwrap(PeerConnectionToken(peerDescription: "unix:/tmp/token"))
        let first = PeerProcessEvidence(processIdentifier: 100, effectiveUserIdentifier: 501)
        let second = PeerProcessEvidence(processIdentifier: 200, effectiveUserIdentifier: 501)

        let firstRegistration = try XCTUnwrap(registry.register(token, evidence: first))
        let secondRegistration = try XCTUnwrap(registry.register(token, evidence: second))
        registry.retire(firstRegistration)

        XCTAssertEqual(
            registry.evidence(forPeerDescription: "unix:/tmp/token"), second,
            "a late retire took away the token from the connection that holds it",
        )
        registry.retire(secondRegistration)
        XCTAssertNil(registry.evidence(forPeerDescription: "unix:/tmp/token"))
    }

    /// The live map is bounded, and the answer past the ceiling is that the connection is not
    /// identified — which is a denial, not a degraded attribution.
    func testTheLiveMapIsBoundedAndRefusesPastTheCeiling() throws {
        let registry = ConnectionPeerRegistry()
        for index in 0 ..< ConnectionPeerRegistry.maximumLiveConnections {
            let token = try XCTUnwrap(
                PeerConnectionToken(peerDescription: "unix:/tmp/holder-\(index)"),
            )
            XCTAssertNotNil(
                registry.register(token, evidence: PeerProcessEvidence(
                    processIdentifier: Int32(index + 1),
                    effectiveUserIdentifier: 501,
                )),
                "connection \(index) was refused below the ceiling",
            )
        }
        let overflow = try XCTUnwrap(PeerConnectionToken(peerDescription: "unix:/tmp/overflow"))
        XCTAssertNil(
            registry.register(overflow, evidence: PeerProcessEvidence(
                processIdentifier: 9999,
                effectiveUserIdentifier: 501,
            )),
            "a connection past the ceiling must not be attributed to anyone",
        )
        XCTAssertEqual(registry.liveCount, ConnectionPeerRegistry.maximumLiveConnections)
        XCTAssertNil(registry.evidence(forPeerDescription: "unix:/tmp/overflow"))

        // Closing one frees exactly one slot, which is what makes the ceiling a bound rather
        // than a permanent shutdown.
        let holder = try XCTUnwrap(PeerConnectionToken(peerDescription: "unix:/tmp/holder-0"))
        let firstRegistration = try XCTUnwrap(registry.register(holder, evidence: PeerProcessEvidence(
            processIdentifier: 1,
            effectiveUserIdentifier: 501,
        )))
        registry.retire(firstRegistration)
        XCTAssertNotNil(registry.register(overflow, evidence: PeerProcessEvidence(
            processIdentifier: 9999,
            effectiveUserIdentifier: 501,
        )))
    }

    /// A token is only ever looked up in the Unix-socket form. A TCP-shaped description has no
    /// token and must not resolve, or a registry keyed by one string could be addressed by a
    /// different transport's spelling of the same value.
    func testOnlyAUnixSocketDescriptionCarriesAToken() {
        XCTAssertNil(PeerConnectionToken(peerDescription: "ipv4:127.0.0.1:8080"))
        XCTAssertNil(PeerConnectionToken(peerDescription: "ipv6:[::1]:443"))
        XCTAssertNil(PeerConnectionToken(peerDescription: "in-process:27182"))
        XCTAssertNil(PeerConnectionToken(peerDescription: "<unknown>"))
        XCTAssertNil(PeerConnectionToken(peerDescription: ""))
        XCTAssertNil(PeerConnectionToken(peerDescription: "unix:"))
    }

    // MARK: - Something that is not an AF_UNIX stream

    /// A TCP connection is not an authentic Unix stream, and accepting it would be claiming
    /// an identity the kernel gives no standing for.
    func testATCPConnectionIsRefusedAtAccept() async throws {
        try await withHarness { _ in
            let refused = Counter()
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            defer { group.shutdownGracefully { _ in } }
            let channel = try await ServerBootstrap(group: group)
                .childChannelInitializer { channel in
                    UnixSocketPeerEvidence.identify(channel)
                        .flatMapThrowing { _ in
                            XCTFail("a TCP connection was identified")
                            throw TestFailure.identified
                        }
                        .flatMapError { error in
                            XCTAssertEqual(error as? UnixSocketPeerEvidence.Failure, .notAUnixSocket)
                            refused.increment()
                            return channel.eventLoop.makeSucceededFuture(())
                        }
                }
                .bind(host: "127.0.0.1", port: 0)
                .get()
            let port = try XCTUnwrap(channel.localAddress?.port)
            let client = try TCPClient(host: "127.0.0.1", port: port)
            defer { client.close() }
            try await XCTAssertEventually("the TCP connection reached the acceptor") {
                refused.value == 1
            }
        }
    }
}

// MARK: - Fixtures

/// The `google.rpc.ErrorInfo` a refusal carries, read the way a client reads it.
private func extractErrorInfo(from error: RPCError) throws -> Google_Rpc_ErrorInfo {
    var statusData: [UInt8]?
    for binaryData in error.metadata[binaryValues: "grpc-status-details-bin"] {
        statusData = binaryData
    }
    let bytes = try XCTUnwrap(statusData, "the refusal carried no status details")
    let status = try Google_Rpc_Status(serializedBytes: bytes)
    let packed = try XCTUnwrap(status.details.first, "the status carried no details")
    XCTAssertTrue(packed.isA(Google_Rpc_ErrorInfo.self))
    return try Google_Rpc_ErrorInfo(serializedBytes: packed.value)
}

private final class HandlerEntry: @unchecked Sendable {
    var wasEntered = false
}

private enum TestFailure: Error {
    case pathTooLong(String)
    case write(Int32)
    case socket(Int32)
    case bind(Int32)
    case connect(Int32)
    case identified
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

private extension PeerIdentificationTests {
    static func request<Input: Sendable>(_ message: Input) -> StreamingServerRequest<Input> {
        StreamingServerRequest(
            metadata: Metadata(),
            messages: RPCAsyncSequence<Input, any Error>(wrapping: AsyncThrowingStream { continuation in
                continuation.yield(message)
                continuation.finish()
            }),
        )
    }

    static func context(peer: String) async throws -> ServerContext {
        try await withServerContextRPCCancellationHandle { cancellation in
            ServerContext(
                descriptor: MethodDescriptor(
                    service: ServiceDescriptor(fullyQualifiedService: RPCAuthorizationMap.serviceName),
                    method: "GetClipboard",
                ),
                remotePeer: peer,
                localPeer: peer,
                cancellation: cancellation,
            )
        }
    }
}

/// A real poll on a real condition, because these properties are decided on another thread
/// and there is no ordering relationship between this process's `connect` returning and the
/// connection's own event loop accepting. A fixed sleep would be a flake dressed as a
/// synchronisation.
private func XCTAssertEventually(
    _ message: String,
    timeout: Duration = .seconds(10),
    _ condition: () throws -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line,
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if (try? condition()) == true {
            return
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    XCTFail(message, file: file, line: line)
}

// MARK: - Harness

/// A real gRPC server on a real Unix socket, served by the peer-identifying accept path and
/// guarded by the real authorization interceptor.
///
/// A REAL SERVICE, not an empty router. The registry entry is created before the gRPC
/// pipeline is configured, so a pipeline that refused to configure would still leave every
/// accept-path test green while the server carried nothing at all. Registering the service
/// and driving a real call over the socket is what rules that out.
private final class PeerIdentifyingHarness: @unchecked Sendable {
    /// Named rather than written inline: `GRPCServer` is generic over its TRANSPORT, and an
    /// empty service list would give the compiler nothing to infer that parameter from.
    typealias Transport = PublicRequestValidatingServerTransport<
        HTTP2ServerTransport.Custom<PeerIdentifyingListenerFactory>,
    >

    let socketPath: String
    let directory: String
    let registry: ConnectionPeerRegistry
    let counters: AuthorizationCounters

    private let group: MultiThreadedEventLoopGroup
    private let server: GRPCServer<Transport>
    private let listener: PeerIdentifyingListenerFactory
    private let serveTask: Task<Void, any Error>

    private init(
        socketPath: String,
        directory: String,
        registry: ConnectionPeerRegistry,
        counters: AuthorizationCounters,
        group: MultiThreadedEventLoopGroup,
        server: GRPCServer<Transport>,
        listener: PeerIdentifyingListenerFactory,
        serveTask: Task<Void, any Error>,
    ) {
        self.socketPath = socketPath
        self.directory = directory
        self.registry = registry
        self.counters = counters
        self.group = group
        self.server = server
        self.listener = listener
        self.serveTask = serveTask
    }

    static func start() async throws -> PeerIdentifyingHarness {
        // SHORT, and the reason is a real limit rather than tidiness: `sun_path` is 104
        // bytes, `NSTemporaryDirectory()` is 49 of them on this machine, and a full-length
        // UUID plus a descriptive name overruns it. The same arithmetic is why the shipped
        // socket lives at `~/Library/Caches/exactmac.sock` and not under a nested state
        // directory, and it is the reason an over-long path is an error rather than a
        // truncation.
        let directory = NSTemporaryDirectory() + "emc-e1-" + String(abs(UUID().uuidString.hashValue) % 1_000_000)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let socketPath = directory + "/listener.sock"
        let registry = ConnectionPeerRegistry()
        let counters = AuthorizationCounters()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let listener = PeerIdentifyingListenerFactory(
            eventLoopGroup: group,
            socketPath: socketPath,
            registry: registry,
        )
        let server: GRPCServer<Transport> = try GRPCServer(
            transport: productionServerTransport(
                HTTP2ServerTransport.Custom(listenerFactory: listener),
            ),
            services: [ExactMacServiceComposition(system: MockSystemOperations()).exactMacService],
            interceptors: productionServerInterceptors(
                AuthorizationInterceptor(
                    runtime: .unixSocket(
                        descriptorPolicy: try PublicRequestDescriptorPolicy.load(),
                        postureSource: PostureSource(override: nil),
                        isConsoleReachable: true,
                        peerEvidence: .registry(registry),
                    ),
                    counters: counters,
                ),
            ),
        )
        let serveTask = Task { try await server.serve() }
        let harness = PeerIdentifyingHarness(
            socketPath: socketPath,
            directory: directory,
            registry: registry,
            counters: counters,
            group: group,
            server: server,
            listener: listener,
            serveTask: serveTask,
        )
        try await XCTAssertEventually("the listener bound its socket") {
            FileManager.default.fileExists(atPath: socketPath)
        }
        return harness
    }

    /// The kernel's evidence for a connection whose peer bound `peerName`.
    func evidence(forPeerName peerName: String) async throws -> PeerProcessEvidence {
        let description = "unix:" + peerName
        var found: PeerProcessEvidence?
        try await XCTAssertEventually("the connection was identified and registered") {
            found = self.registry.evidence(forPeerDescription: description)
            return found != nil
        }
        return try XCTUnwrap(found)
    }

    /// Stops the server, drops the socket claim, and only then stops the event loops.
    ///
    /// IN THAT ORDER, because shutting the group down first is what makes SwiftNIO complain
    /// that tasks cannot be scheduled on a shut-down event loop, and a warning on every run
    /// of a security suite is a warning nobody reads.
    func stop() async {
        server.beginGracefulShutdown()
        try? await serveTask.value
        try? listener.releaseClaim()
        try? await group.shutdownGracefully()
        try? FileManager.default.removeItem(atPath: directory)
    }
}

// MARK: - Sockets

/// A blocking AF_UNIX client socket, so the test controls the one thing that decides
/// attributability: whether the peer binds a pathname of its own.
private struct UnixClient {
    private let descriptor: Int32

    init(connectTo path: String, bindingPeerNameTo peerName: String?) throws {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw TestFailure.socket(errno) }
        do {
            if let peerName {
                try Self.bind(descriptor, to: peerName)
            }
            try Self.connect(descriptor, to: path)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        // The HTTP/2 client connection preface and an empty SETTINGS frame, written before
        // anything else is waited on.
        //
        // A SOCKET THAT CONNECTS AND SAYS NOTHING IS NOT A CLIENT, and this one is the only
        // part of the suite that has to impersonate one. Sending the preface is what makes
        // the connection a legitimate HTTP/2 connection, and it is what the Go proxy sends:
        // the server's HTTP/2 machinery tears down a connection that never speaks the
        // protocol, and a connection the suite provokes a teardown of would be testing
        // grpc-swift's teardown rather than ExactMac's accept path.
        let preface: [UInt8] = Array("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8) + [
            0x00, 0x00, 0x00, // SETTINGS payload length: 0
            0x04, // SETTINGS
            0x00, // flags
            0x00, 0x00, 0x00, 0x00, // stream 0
        ]
        var written = 0
        while written < preface.count {
            let count = preface.withUnsafeBytes { bytes -> Int in
                Darwin.write(descriptor, bytes.baseAddress!.advanced(by: written), preface.count - written)
            }
            guard count > 0 else { throw TestFailure.write(errno) }
            written += count
        }
        self.descriptor = descriptor
    }

    func close() {
        Darwin.close(descriptor)
    }

    private static func bind(_ descriptor: Int32, to path: String) throws {
        var address = try Self.address(path)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.stride))
            }
        }
        guard bound == 0 else { throw TestFailure.bind(errno) }
    }

    private static func connect(_ descriptor: Int32, to path: String) throws {
        var address = try Self.address(path)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.stride))
            }
        }
        guard connected == 0 else { throw TestFailure.connect(errno) }
    }

    private static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.stride)
        let bytes = Array(path.utf8)
        // THROWN rather than asserted. A precondition here traps the whole xctest process and
        // every other test with it, which is how a fixture's own bookkeeping mistake becomes
        // an unattributable suite-wide failure.
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw TestFailure.pathTooLong(path)
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: bytes.count + 1) { chars in
                for (index, byte) in bytes.enumerated() {
                    chars[index] = CChar(bitPattern: byte)
                }
                chars[bytes.count] = 0
            }
        }
        return address
    }
}

private struct TCPClient {
    private let descriptor: Int32

    init(host: String, port: Int) throws {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw TestFailure.socket(errno) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
            Darwin.close(descriptor)
            throw TestFailure.socket(errno)
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.stride))
            }
        }
        guard connected == 0 else {
            Darwin.close(descriptor)
            throw TestFailure.connect(errno)
        }
        self.descriptor = descriptor
    }

    func close() {
        Darwin.close(descriptor)
    }
}
