import Darwin
import ExactMacProto
@testable import ExactMacServer
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
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
    // MARK: - The kernel names the connecting process

    /// The whole of E1 in one assertion: a real accepted AF_UNIX connection, identified by
    /// the kernel as this very process, reachable by the token the transport will report.
    func testTheKernelIdentifiesTheConnectingProcessOnTheAcceptedSocket() async throws {
        let harness = try await PeerIdentifyingHarness.start()
        defer { Task { await harness.stop() } }
        let peerName = harness.directory.appending("peer.sock")

        let client = try UnixClient(connectTo: harness.socketPath, bindingPeerNameTo: peerName)
        defer { client.close() }

        let evidence = try await harness.evidence(forPeerName: peerName)
        XCTAssertEqual(evidence.processIdentifier, getpid(), "the kernel named another process")
        XCTAssertEqual(evidence.effectiveUserIdentifier, geteuid())
        XCTAssertEqual(harness.registry.liveCount, 1)
    }

    /// The token the transport reports is the peer's own pathname, which is the only
    /// per-connection value `ServerContext` carries.
    func testTheTokenIsThePeersOwnSocketName() async throws {
        let harness = try await PeerIdentifyingHarness.start()
        defer { Task { await harness.stop() } }
        let peerName = harness.directory.appending("named-peer.sock")

        let client = try UnixClient(connectTo: harness.socketPath, bindingPeerNameTo: peerName)
        defer { client.close() }

        try await XCTAssertEventually("the connection was identified and registered") {
            harness.registry.evidence(forPeerDescription: "unix:\(peerName)") != nil
        }
        let token = try XCTUnwrap(PeerConnectionToken(peerDescription: "unix:\(peerName)"))
        XCTAssertEqual(token.pathname, peerName)
    }

    // MARK: - A peer that names nothing

    /// CARRIED BUT UNATTRIBUTABLE, and the distinction is the point: refusing the connection
    /// would turn a client that has not opted into naming its socket into a transport error
    /// it cannot diagnose, so it is admitted and denied at the authorization layer instead.
    func testAnUnnamedPeerIsCarriedAndRegistersNothing() async throws {
        let harness = try await PeerIdentifyingHarness.start()
        defer { Task { await harness.stop() } }

        let client = try UnixClient(connectTo: harness.socketPath, bindingPeerNameTo: nil)
        defer { client.close() }
        // The listener is still serving and still identifying, which is shown by a NAMED peer
        // registering immediately afterwards. It could not do so if the first connection had
        // taken the listener down with it.
        let named = harness.directory.appending("after-anonymous.sock")
        let second = try UnixClient(connectTo: harness.socketPath, bindingPeerNameTo: named)
        defer { second.close() }
        _ = try await harness.evidence(forPeerName: named)

        XCTAssertEqual(
            harness.registry.liveCount, 1,
            "an unnamed peer must register nothing, because there is no token to register it under",
        )
        // And an empty pathname is refused as a token, which is the same absence the
        // transport's Unix-socket fallback produces for an unnamed peer.
        XCTAssertNil(PeerConnectionToken(peerDescription: "unix:"))
    }

    /// The end of the fail-closed chain: a caller nothing can identify is refused, the
    /// refusal names the reason, and no handler runs.
    func testAnUnidentifiableCallerIsRefusedAndNoHandlerRuns() async throws {
        let policy = try PublicRequestDescriptorPolicy.load()
        let counters = AuthorizationCounters()
        let handler = HandlerEntry()
        let runtime = AuthorizationRuntime.unixSocket(
            descriptorPolicy: policy,
            isConsoleReachable: true,
            peerEvidence: .fixed(nil),
        )
        let interceptor = AuthorizationInterceptor(runtime: runtime, counters: counters)

        // The peer's description for a connection nothing can attribute is the listener's
        // own path, because that is what the transport's Unix-socket fallback produces.
        do {
            _ = try await interceptor.intercept(
                request: Self.request(Exactmac_V1_GetClipboardRequest.with { $0.name = "clipboard" }),
                context: try await Self.context(peer: "unix:/some/listener.sock"),
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
        let harness = try await PeerIdentifyingHarness.start()
        defer { Task { await harness.stop() } }
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

        let firstRegistration = registry.register(token, evidence: first)
        let secondRegistration = registry.register(token, evidence: second)
        registry.retire(firstRegistration)

        XCTAssertEqual(
            registry.evidence(forPeerDescription: "unix:/tmp/token"), second,
            "a late retire took away the token from the connection that holds it",
        )
        registry.retire(secondRegistration)
        XCTAssertNil(registry.evidence(forPeerDescription: "unix:/tmp/token"))
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
        if (try? condition()) == true { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    XCTFail(message, file: file, line: line)
}

// MARK: - Harness

/// A real gRPC server on a real Unix socket, served by the peer-identifying accept path.
///
/// The service list is empty because nothing here makes an RPC: the properties under test
/// are decided at accept time, and a suite that issued calls would be testing handlers rather
/// than the transport.
private final class PeerIdentifyingHarness: @unchecked Sendable {
    let socketPath: String
    let directory: String
    let registry: ConnectionPeerRegistry

    /// Named rather than written inline: `GRPCServer` is generic over its TRANSPORT, and an
    /// empty service list gives the compiler nothing to infer that parameter from.
    typealias Transport = PublicRequestValidatingServerTransport<
        HTTP2ServerTransport.Custom<PeerIdentifyingListenerFactory>
    >

    private let group: MultiThreadedEventLoopGroup
    private let server: GRPCServer<Transport>

    private init(
        socketPath: String,
        directory: String,
        registry: ConnectionPeerRegistry,
        group: MultiThreadedEventLoopGroup,
        server: GRPCServer<Transport>,
    ) {
        self.socketPath = socketPath
        self.directory = directory
        self.registry = registry
        self.group = group
        self.server = server
    }

    static func start() async throws -> PeerIdentifyingHarness {
        // SHORT, and the reason is a real limit rather than tidiness: `sun_path` is 104
        // bytes, `NSTemporaryDirectory()` is 49 of them on this machine, and a full-length
        // UUID plus a descriptive name overruns it. The same arithmetic is why the shipped
        // socket lives at `~/Library/Caches/exactmac.sock` and not under a nested state
        // directory, and it is the reason `ServerConfig` treats an over-long path as an error
        // rather than truncating it.
        let directory = NSTemporaryDirectory() + "emc-e1-" + String(abs(UUID().uuidString.hashValue) % 1_000_000)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let socketPath = directory + "/listener.sock"
        let registry = ConnectionPeerRegistry()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let factory = PeerIdentifyingListenerFactory(
            eventLoopGroup: group,
            socketPath: socketPath,
            registry: registry,
        )
        let server: GRPCServer<Transport> = GRPCServer(
            transport: productionServerTransport(
                HTTP2ServerTransport.Custom(listenerFactory: factory),
            ),
            services: [],
            interceptors: [],
        )
        _ = Task { try await server.serve() }
        let harness = PeerIdentifyingHarness(
            socketPath: socketPath,
            directory: directory,
            registry: registry,
            group: group,
            server: server,
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
            found = registry.evidence(forPeerDescription: description)
            return found != nil
        }
        return try XCTUnwrap(found)
    }

    func stop() async {
        server.beginGracefulShutdown()
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
