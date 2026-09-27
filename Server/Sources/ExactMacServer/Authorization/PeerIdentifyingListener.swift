import Darwin
import Foundation
import GRPCNIOTransportHTTP2
import NIOCore
import NIOPosix
import os

// MARK: - Reading the kernel's answer from an accepted channel

/// What the kernel says about an accepted connection, read from the accepted channel.
///
/// THE DESCRIPTOR IS NEVER HELD, and that is the fact that makes this reachable at all.
/// SwiftNIO does not expose a socket channel's file descriptor — `BaseSocket.descriptor` is
/// private and no public API returns it — which is why `knowledgeStore.transportLimit`
/// concluded the peer pid was unobtainable. The conclusion was right about the descriptor
/// and wrong about the consequence: `SocketOptionProvider.unsafeGetSocketOption(level:name:)`
/// is public, is implemented by `BaseSocketChannel` against the channel's own descriptor,
/// and lands in `BaseSocket.getOption`, which is a plain `getsockopt` with an arbitrary
/// level and name. So `LOCAL_PEERPID` and `LOCAL_PEERCRED` are read straight off the channel
/// — the same syscall on the same descriptor the design asked for, reached through the
/// only handle SwiftNIO will give out.
///
/// MEASURED on this machine with a C probe rather than read from a header: `LOCAL_PEERPID`
/// returned the peer pid, `LOCAL_PEERCRED` returned an `xucred` whose `cr_uid` is the peer's
/// effective uid, `getpeername` on the accepted socket returned the peer's bound pathname,
/// and an unnamed peer's `getpeername` returned an empty pathname.
///
/// NOTHING HERE BLOCKS. `unsafeGetSocketOption` completes its promise inline when it is
/// already on the event loop, and every callback below runs on that loop, so the whole
/// identification is one non-blocking future chain. A blocking wait on an event loop would
/// deadlock against the very future it was waiting for, which is the one thing that must not
/// be true of a code path every accepted connection runs.
enum UnixSocketPeerEvidence {
    enum Failure: Error, Equatable, CustomStringConvertible {
        case notAUnixSocket
        case notAStreamSocket
        case notAConnectionOptionProvider
        case peerProcessIdentifierUnavailable
        case peerCredentialsUnavailable

        var description: String {
            switch self {
            case .notAUnixSocket: "the accepted channel is not an AF_UNIX socket"
            case .notAStreamSocket: "the accepted channel is not a SOCK_STREAM socket"
            case .notAConnectionOptionProvider: "the accepted channel exposes no socket options"
            case .peerProcessIdentifierUnavailable: "the kernel returned no peer process identifier"
            case .peerCredentialsUnavailable: "the kernel returned no peer credentials"
            }
        }
    }

    /// The outcome of identifying one accepted connection.
    enum Identification: Equatable {
        /// Attributable: the evidence, and the token the interceptor will look it up by.
        case identified(token: PeerConnectionToken, evidence: PeerProcessEvidence)
        /// A real AF_UNIX stream with a resolvable pid, whose peer bound no pathname and so
        /// has no per-connection token to correlate an RPC with.
        ///
        /// IT IS NOT A FAILURE, and the distinction is load-bearing. The connection is
        /// carried at the transport level and refused at the authorization level, so a
        /// client that has not opted into naming its socket gets a working gRPC endpoint it
        /// can do nothing with, rather than a connection error it cannot diagnose.
        case unattributable(evidence: PeerProcessEvidence)
    }

    /// What the kernel named, carried through the chain so the pid and the uid are read
    /// from the same socket and no later step has to re-derive one from the other.
    private struct NamedPeer: Sendable {
        var processIdentifier: pid_t
        var effectiveUserIdentifier: uid_t
    }

    /// - Returns: a future that fails with `Failure` for anything that is not an authentic
    ///   connected AF_UNIX stream, or whose peer the kernel will not name. Every one of
    ///   those closes the connection, which is the fail-closed direction: a connection the
    ///   kernel cannot account for is not one this server should carry.
    static func identify(_ channel: any Channel) -> EventLoopFuture<Identification> {
        let eventLoop = channel.eventLoop
        // AF_UNIX, from the address the accepted socket reports for itself. Darwin has no
        // `SO_DOMAIN`, so the kernel's answer about the domain is `getsockname`, which is
        // the same read the transport uses to build its peer description.
        guard case .unixDomainSocket = channel.localAddress else {
            return eventLoop.makeFailedFuture(Failure.notAUnixSocket)
        }
        return option(channel, level: SOL_SOCKET, name: SO_TYPE)
            .flatMapThrowing { (type: Int32) in
                guard type == Int32(SOCK_STREAM) else { throw Failure.notAStreamSocket }
            }
            .flatMap { _ in option(channel, level: SOL_LOCAL, name: LOCAL_PEERPID) }
            .flatMapThrowing { (processIdentifier: pid_t) in
                // pid 0 and 1 mean "no peer" and "the kernel's own init", neither of which
                // is a caller this server can name.
                guard processIdentifier > 1 else {
                    throw Failure.peerProcessIdentifierUnavailable
                }
                return processIdentifier
            }
            .flatMap { processIdentifier in
                option(channel, level: SOL_LOCAL, name: LOCAL_PEERCRED)
                    .map { (credentials: xucred) in
                        NamedPeer(
                            processIdentifier: processIdentifier,
                            effectiveUserIdentifier: credentials.cr_uid,
                        )
                    }
            }
            .map { peer in
                let evidence = PeerProcessEvidence(
                    processIdentifier: peer.processIdentifier,
                    effectiveUserIdentifier: peer.effectiveUserIdentifier,
                )
                // The peer's bound pathname. The LISTENER's own path is explicitly not a
                // token: an unnamed peer produces exactly that value through the
                // transport's Unix-socket fallback, so honouring it would hand every
                // unattributable caller the same lookup key as the listener itself.
                guard let token = Self.token(for: channel),
                      let listener = Self.listenerPathname(channel),
                      token.pathname != listener
                else {
                    return .unattributable(evidence: evidence)
                }
                return .identified(token: token, evidence: evidence)
            }
    }

    /// `getsockopt` on the channel's own descriptor, through the public option API.
    private static func option<Option: Sendable>(
        _ channel: any Channel,
        level: Int32,
        name: Int32,
    ) -> EventLoopFuture<Option> {
        guard let provider = channel as? any SocketOptionProvider else {
            return channel.eventLoop.makeFailedFuture(Failure.notAConnectionOptionProvider)
        }
        return provider.unsafeGetSocketOption(
            level: SocketOptionLevel(level),
            name: SocketOptionName(name),
        )
    }

    /// The peer's bound pathname, which is `getpeername` as SwiftNIO already read it.
    private static func token(for channel: any Channel) -> PeerConnectionToken? {
        guard let peer = Self.pathname(of: channel.remoteAddress), !peer.isEmpty else { return nil }
        return PeerConnectionToken(peerDescription: "unix:\(peer)")
    }

    private static func listenerPathname(_ channel: any Channel) -> String? {
        Self.pathname(of: channel.localAddress)
    }

    /// The `sun_path` of a Unix socket address, or nil for any other address family.
    ///
    /// `SocketAddress.UnixSocketAddress` carries a `sockaddr_un` and nothing that reads the
    /// path out of it, so the path is read from the C struct — which is also exactly what
    /// `getpeername` and `getsockname` filled in, and therefore the kernel's own answer
    /// rather than anything assembled here.
    private static func pathname(of address: NIOCore.SocketAddress?) -> String? {
        guard case let .unixDomainSocket(unix)? = address else { return nil }
        return withUnsafePointer(to: unix.address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: unix.address.sun_path)) {
                String(cString: $0)
            }
        }
    }
}

// MARK: - What the server requires of its own socket pathname

/// The server binds its own Unix socket, so it owns the node at that pathname and has to
/// decide what to do about one it did not create.
///
/// These checks are the same shape as `ConsoleServerEndpoint.listen()`'s and they are
/// separate functions because they bracket the bind and must not be one another: a node that
/// is wrong before the bind is not the node the bind produced, and a node that is wrong after
/// it is the node just created.
enum UnixSocketNodeError: Error, Equatable, CustomStringConvertible {
    case pathAlreadyExistsAndIsLive(String)
    case pathIsNotASocket(String)
    case pathIsNotOwnedByThisUser(String, actual: uid_t)
    case pathIsNotOwnerOnly(String, actual: mode_t)
    case systemCall(operation: String, path: String, code: Int32)

    var description: String {
        switch self {
        case let .pathAlreadyExistsAndIsLive(path):
            "\(path) is already served by a live listener; refusing to take the pathname over"
        case let .pathIsNotASocket(path):
            "\(path) exists and is not a socket; refusing to remove it"
        case let .pathIsNotOwnedByThisUser(path, actual):
            "\(path) is owned by uid \(actual); refusing to touch it"
        case let .pathIsNotOwnerOnly(path, actual):
            "\(path) has permissions 0\(String(actual, radix: 8)); expected 0600"
        case let .systemCall(operation, path, code):
            "\(operation) failed for \(path): errno \(code)"
        }
    }
}

enum UnixSocketNode {
    /// Removes a node left behind by a previous run, and refuses everything else.
    ///
    /// A LEFTOVER NODE IS THE ONE LEGITIMATE REASON THE PATH CAN ALREADY EXIST, and taking
    /// it has to be safe in three ways. `lstat` never follows a symlink, so a symlink placed
    /// at the path cannot turn the unlink into a removal of something else. The node must be
    /// a socket owned by this user, so a regular file or another user's node is refused
    /// rather than deleted. And the node must have NO live listener, which is checked by
    /// connecting to it: unlinking a pathname a running server is still serving would give
    /// two listeners on one name and split the clients between them.
    static func reclaimStaleNode(at path: String) throws {
        var status = stat()
        guard path.withCString({ lstat($0, &status) }) == 0 else {
            if errno == ENOENT { return }
            throw UnixSocketNodeError.systemCall(operation: "lstat", path: path, code: errno)
        }
        try requireOwnerOnlySocket(status, path: path)
        guard !isLive(path) else {
            throw UnixSocketNodeError.pathAlreadyExistsAndIsLive(path)
        }
        guard unlink(path) == 0 else {
            throw UnixSocketNodeError.systemCall(operation: "unlink", path: path, code: errno)
        }
    }

    /// Makes the node the bind just created owner-only, and says so if it cannot.
    ///
    /// The process umask is `0077`, so `bind` creates the node as `0700` — owner-only, and
    /// already a boundary. `0600` is nevertheless what the deployment contract and the Go
    /// client's admission check both require, and a socket is never searched, so the execute
    /// bit on it is noise that only widens a checker's idea of what is exposed.
    static func hardenBoundNode(at path: String) throws {
        var status = stat()
        guard path.withCString({ lstat($0, &status) }) == 0 else {
            throw UnixSocketNodeError.systemCall(operation: "lstat", path: path, code: errno)
        }
        try requireOwnerOnlySocket(status, path: path)
        let permissions = status.st_mode & 0o777
        guard permissions == 0o600 else {
            guard chmod(path, 0o600) == 0 else {
                throw UnixSocketNodeError.systemCall(operation: "chmod", path: path, code: errno)
            }
            return
        }
    }

    private static func requireOwnerOnlySocket(_ status: stat, path: String) throws {
        guard status.st_mode & mode_t(0o170000) == mode_t(0o140000) else {
            throw UnixSocketNodeError.pathIsNotASocket(path)
        }
        let owner = geteuid()
        guard status.st_uid == owner else {
            throw UnixSocketNodeError.pathIsNotOwnedByThisUser(path, actual: status.st_uid)
        }
    }

    /// Removes the node this process bound, on a clean shutdown.
    ///
    /// AFTER the transport has closed, so nothing is still accepting through it, and CHECKED
    /// the same way `reclaimStaleNode` checks, because a pathname is mutable and unlinking
    /// whatever sits at it is how a symlink there becomes a way to remove somebody else's
    /// file. A node that has been replaced since the bind is reported rather than deleted.
    static func releaseBoundNode(at path: String) throws {
        var status = stat()
        guard path.withCString({ lstat($0, &status) }) == 0 else {
            if errno == ENOENT { return }
            throw UnixSocketNodeError.systemCall(operation: "lstat", path: path, code: errno)
        }
        try requireOwnerOnlySocket(status, path: path)
        guard status.st_mode & 0o777 == 0o600 else {
            throw UnixSocketNodeError.pathIsNotOwnerOnly(path, actual: status.st_mode & 0o777)
        }
        guard unlink(path) == 0 else {
            throw UnixSocketNodeError.systemCall(operation: "unlink", path: path, code: errno)
        }
    }

    /// Whether anything is currently accepting on `path`.
    ///
    /// A refused connection is the answer a stale node gives: the socket file outlived the
    /// process that bound it. Anything else — success, or a failure that is not a refusal —
    /// is treated as live, so an ambiguous probe is the safe answer.
    private static func isLive(_ path: String) -> Bool {
        let probe = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { return true }
        defer { Darwin.close(probe) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.stride)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return true }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: bytes.count + 1) { chars in
                for (index, byte) in bytes.enumerated() {
                    chars[index] = CChar(bitPattern: byte)
                }
                chars[bytes.count] = 0
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(probe, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.stride))
            }
        }
        return result == 0 || errno != ECONNREFUSED
    }
}

// MARK: - The listener

/// Why this exists, in one paragraph: the accept is the only place a Unix-socket server can
/// learn who connected, so the server runs its own rather than handing the pathname to
/// `HTTP2ServerTransport.Posix`. `ListenerFactory` is a public protocol whose
/// `makeListeningChannel(listenerConfigurator:connectionConfigurator:)` hands this factory
/// both configurators, which is enough to build an equivalent transport with one extra step
/// in the middle of it. The cost is that `ServerBootstrap` cannot adopt an existing listening
/// descriptor, so launchd supervises the server process and the server binds its own
/// pathname. The accept is worth more than the descriptor handoff, because without it the
/// server cannot say who is calling and every capability denies.
struct PeerIdentifyingListenerFactory: HTTP2ServerTransport.ListenerFactory {
    typealias ConnectionChannel = HTTP2ServerTransport.ConnectionConfigurator.ConnectionChannel

    let eventLoopGroup: any EventLoopGroup
    let socketPath: String
    let registry: ConnectionPeerRegistry
    let logger: Logger

    init(
        eventLoopGroup: any EventLoopGroup,
        socketPath: String,
        registry: ConnectionPeerRegistry,
        logger: Logger = Logger(
            subsystem: "io.github.joeycumines.exactmac",
            category: "authorization.listener",
        ),
    ) {
        self.eventLoopGroup = eventLoopGroup
        self.socketPath = socketPath
        self.registry = registry
        self.logger = logger
    }

    func makeListeningChannel(
        listenerConfigurator: HTTP2ServerTransport.ListenerConfigurator,
        connectionConfigurator: HTTP2ServerTransport.ConnectionConfigurator,
    ) async throws -> NIOAsyncChannel<ConnectionChannel, Never> {
        try UnixSocketNode.reclaimStaleNode(at: socketPath)
        let channel = try await ServerBootstrap(group: eventLoopGroup)
            .serverChannelInitializer { channel in
                // The quiescing handler the listener configurator installs is what makes
                // `beginGracefulShutdown` close the LISTENER; omitting it would leave the
                // process accepting connections it has already stopped serving.
                listenerConfigurator.configure(channel: channel)
            }
            .bind(
                unixDomainSocketPath: socketPath,
                cleanupExistingSocketFile: false,
            ) { channel in
                Self.accept(channel, registry: registry, logger: logger) { channel in
                    connectionConfigurator.configure(channel: channel, tls: .none)
                }
            }
        // After the bind, because before it there is no node to check, and after it there is
        // no second chance: a listener left world-readable is a listener anybody can use.
        try UnixSocketNode.hardenBoundNode(at: socketPath)
        logger.info("gRPC listener bound at \(self.socketPath, privacy: .public)")
        return channel
    }

    /// Identifies the connection, registers it, and only then hands it to the gRPC pipeline.
    ///
    /// THE ORDER IS THE PROPERTY. No stream can be opened before the configurator runs, and
    /// the registry entry exists before the configurator runs, so there is no window in
    /// which an RPC could be authorized against a connection whose evidence is not yet
    /// recorded. A connection that cannot be identified is closed HERE rather than carried
    /// and refused later: a socket the kernel will not account for has no business in a
    /// process whose entire claim is that it knows who is talking to it.
    private static func accept(
        _ channel: any Channel,
        registry: ConnectionPeerRegistry,
        logger: Logger,
        configure: @escaping @Sendable (any Channel) -> EventLoopFuture<ConnectionChannel>,
    ) -> EventLoopFuture<ConnectionChannel> {
        UnixSocketPeerEvidence.identify(channel)
            .flatMapThrowing { identification -> any Channel in
                switch identification {
                case let .identified(token, evidence):
                    let registration = registry.register(token, evidence: evidence)
                    try channel.pipeline.syncOperations.addHandler(
                        PeerConnectionLifetime(registry: registry, registration: registration),
                    )
                case let .unattributable(evidence):
                    // NOT A REFUSAL TO CONNECT, and the reason is worth stating: refusing
                    // the connection would turn a client that has not opted into naming its
                    // socket into an unexplained transport error. It is admitted, recorded,
                    // and every capability on it denies because nothing can resolve it.
                    logger.warning(
                        """
                        Accepted a connection whose peer bound no socket pathname \
                        (pid \(evidence.processIdentifier, privacy: .public)); \
                        every capability on it will be denied
                        """,
                    )
                }
                return channel
            }
            .flatMap { channel in configure(channel) }
            .flatMapError { error in
                // Close rather than hand back a half-identified connection. The failure is
                // logged here because a refusal that surfaces only as a closed stream is a
                // refusal nobody can act on.
                logger.error("Refused a connection: \(String(describing: error), privacy: .public)")
                channel.close(promise: nil)
                return channel.eventLoop.makeFailedFuture(error)
            }
    }
}

/// Retires a connection's token when that connection closes.
///
/// A `ChannelInboundHandler` installed ahead of the HTTP/2 and gRPC handlers, and it
/// forwards everything it sees, so it changes nothing about the byte stream. The inbound
/// type is `ByteBuffer` because an accepted `SocketChannel` has an empty pipeline when the
/// child initializer runs and the socket channel's own read type is what reaches it.
final class PeerConnectionLifetime: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private let registry: ConnectionPeerRegistry
    private let registration: PeerConnectionRegistration?

    init(registry: ConnectionPeerRegistry, registration: PeerConnectionRegistration?) {
        self.registry = registry
        self.registration = registration
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.fireChannelRead(data)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if let registration {
            registry.retire(registration)
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.fireErrorCaught(error)
    }
}
