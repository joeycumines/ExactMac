import Darwin
import Foundation
import GRPCNIOTransportHTTP2
import NIOCore
import NIOPosix
import os
import Synchronization

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
/// returned the peer's pid, `LOCAL_PEERCRED` returned an `xucred` whose `cr_uid` is the
/// peer's effective uid, `getpeername` on the accepted socket returned the peer's bound
/// pathname, and an unnamed peer's `getpeername` returned an empty pathname.
///
/// `LOCAL_PEERPID` NAMES THE PEER SOCKET'S CREATING PROCESS, NOT NECESSARILY THE PROCESS
/// CURRENTLY SPEAKING, and the same probe showed the distinction is real: with the creating
/// process gone the option still reports it, because the socket outlives its creator. A
/// process that forks while holding a named socket therefore has its children's calls
/// attributed to the parent — the parent's pid, so the parent's executable path, the
/// parent's signature state and the parent's grants. Nothing in these two options can see
/// that, so the limitation belongs at the resolution site rather than hidden here, and
/// `CallerIdentityResolver` is where a reader should look for what is and is not provable
/// from a pid. A dead creator fails closed on its own, because there is no executable to
/// resolve and an unresolved identity escalates and then denies.
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
        guard let peer = pathname(of: channel.remoteAddress), !peer.isEmpty else { return nil }
        return PeerConnectionToken(peerDescription: "unix:\(peer)")
    }

    private static func listenerPathname(_ channel: any Channel) -> String? {
        pathname(of: channel.localAddress)
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

/// The server binds its own Unix socket, so the node at that pathname is the server's to
/// manage and it has to decide what to do about one it did not create.
///
/// THE DECISION IS AN ADVISORY LOCK, NOT A PROBE, and that choice was bought by measurement.
/// The first version asked whether anything was listening by calling `connect(2)`, and a C
/// probe on this machine showed it cannot answer the question: with the accept queue full, a
/// connect to a LIVE Unix listener returns `ECONNREFUSED` in under a millisecond, whether it
/// is blocking or not — the same errno a socket with no listener returns, for the same reason
/// the server is not reading. A probe therefore reports a busy server as a dead one, and the
/// reclaim it drives would unlink a live server's node. `flock(2)` answers it exactly, because
/// the kernel releases the lock when the holder dies: a node left behind by a crash is present
/// and unlocked, while a live server's is present and held.
enum UnixSocketNodeError: Error, Equatable, CustomStringConvertible {
    case pathIsNotASocket(String)
    case pathIsNotOwnedByThisUser(String, actual: uid_t)
    case pathAlreadyClaimed(String)
    case ownerNodeIsNotARegularFile(String)
    case ownerNodeIsNotOwnerOnly(String, actual: mode_t)
    case systemCall(operation: String, path: String, code: Int32)

    var description: String {
        switch self {
        case let .pathIsNotASocket(path):
            "\(path) exists and is not a socket; refusing to take it over"
        case let .pathIsNotOwnedByThisUser(path, actual):
            "\(path) is owned by uid \(actual); refusing to touch it"
        case let .pathAlreadyClaimed(path):
            "\(path) is claimed by a running server; refusing to take the pathname over"
        case let .ownerNodeIsNotARegularFile(path):
            "\(path) exists and is not a regular file; refusing to use it as a lock"
        case let .ownerNodeIsNotOwnerOnly(path, actual):
            "\(path) has permissions 0\(String(actual, radix: 8)); expected 0600"
        case let .systemCall(operation, path, code):
            "\(operation) failed for \(path): errno \(code)"
        }
    }
}

/// This process's exclusive claim on one socket pathname.
///
/// IT IS THE PROOF OF OWNERSHIP, and both directions of the socket's life depend on it. A
/// server that could not claim the pathname does not bind it and does not remove it on the
/// way out, so a refused start can never delete a live server's node; and a server that
/// holds the claim knows no other live server can be on the pathname, so removing the node
/// on shutdown is removing its own.
///
/// A `final class` holding a descriptor, so the lock lives exactly as long as the claim and
/// the kernel closes it if this process dies without releasing.
final class SocketPathClaim: @unchecked Sendable {
    /// Beside the socket, so it is on the same filesystem and in the same owner-only place.
    static func ownerNodePath(forSocketPath path: String) -> String {
        path + ".owner"
    }

    let path: String
    private let ownerNodePath: String
    private let descriptor: Int32

    init(path: String, ownerNodePath: String, descriptor: Int32) {
        self.path = path
        self.ownerNodePath = ownerNodePath
        self.descriptor = descriptor
    }

    /// The ONLY close of the lock descriptor, and it is here rather than in `release()`
    /// because a second close is not an error the kernel reports: the number it closes is
    /// whatever the process has been handed since, so a stale close of a released number
    /// succeeds by destroying an unrelated live descriptor. One close, in the deinitializer.
    deinit {
        _ = Darwin.close(descriptor)
    }

    /// Removes the socket and the lock node, then drops the lock.
    ///
    /// IN THAT ORDER, and the order is the whole subtlety. Unlinking the lock node while the
    /// lock is still held leaves a window in which a starting server creates a fresh node
    /// and locks that instead, which is correct: by then this process's socket is already
    /// gone, so the pathname is free and the newcomer may have it. Removing the socket
    /// first, under the lock, is what stops two live servers sharing one name.
    func release() throws {
        try UnixSocketNode.unlinkSocketNode(at: path)
        if unlink(ownerNodePath) != 0, errno != ENOENT {
            // A lock node this process cannot remove is a leftover, not a safety failure:
            // the lock itself is released when this object goes, and the next start opens
            // or replaces the node.
            throw UnixSocketNodeError.systemCall(
                operation: "unlink",
                path: ownerNodePath,
                code: errno,
            )
        }
    }
}

enum UnixSocketNode {
    /// Claims the pathname for this process, and removes a node left behind by a previous run.
    ///
    /// NOTHING HERE FOLLOWS A SYMLINK. `lstat` describes the node itself, `O_NOFOLLOW`
    /// refuses to open through one, and a socket, regular file or directory that is not
    /// what this server expects is reported rather than removed — because unlinking whatever
    /// sits at a path is how a symlink there becomes a way to delete somebody else's file.
    static func claim(_ path: String) throws -> SocketPathClaim {
        var status = stat()
        if path.withCString({ lstat($0, &status) }) == 0 {
            // Owner and socket type, and NOT the mode. The mode of a node this process did
            // not create is a property of the run that crashed, not evidence about anything
            // that matters here: `hardenBoundNode` sets it on the node the bind is about to
            // create, and requiring it of a leftover would mean a server that crashed under
            // a permissive umask could never restart without an operator clearing the
            // pathname by hand — which is the whole failure the claim exists to remove.
            try requireOwnedSocketIgnoringMode(status, path: path)
        } else if errno != ENOENT {
            throw UnixSocketNodeError.systemCall(operation: "lstat", path: path, code: errno)
        }

        let ownerNodePath = SocketPathClaim.ownerNodePath(forSocketPath: path)
        try requireOwnerOnlyLockNode(ownerNodePath)
        let descriptor = Darwin.open(
            ownerNodePath,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            0o600,
        )
        guard descriptor >= 0 else {
            throw UnixSocketNodeError.systemCall(operation: "open", path: ownerNodePath, code: errno)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            _ = Darwin.close(descriptor)
            // EWOULDBLOCK IS THE ANSWER, not a failure to find out: the pathname is being
            // served by a process that is still alive.
            throw UnixSocketNodeError.pathAlreadyClaimed(path)
        }
        // From here the lock is HELD, and it is released when the descriptor is closed. A
        // throw below must still close it, or the pathname stays unclaimable for the life
        // of a process that is about to carry on without a claim.
        var locked = true
        defer {
            if locked {
                _ = Darwin.close(descriptor)
            }
        }
        // Holding the claim is what makes removing a leftover node safe, so the removal
        // comes after it and not before.
        try unlinkSocketNode(at: path)
        locked = false
        return SocketPathClaim(path: path, ownerNodePath: ownerNodePath, descriptor: descriptor)
    }

    /// Makes the node the bind just created owner-only.
    ///
    /// IT CHMODS UNCONDITIONALLY AND CHECKS ONLY THAT THE CHMOD WORKED. An earlier version
    /// first required the node to be owner-only, which is the mode it exists to establish,
    /// so a process whose umask was not `0077` bound a `0755` node, refused to accept it, and
    /// threw out of `makeListeningChannel` after the listener was already bound — which
    /// abandoned an accepted child whose configured channel nothing ever consumed, and
    /// SwiftNIO answers that with a `Fatal error` that kills the process rather than an
    /// error anyone can read. A check that contradicts the operation it guards is not a
    /// check.
    static func hardenBoundNode(at path: String) throws {
        var status = stat()
        guard path.withCString({ lstat($0, &status) }) == 0 else {
            throw UnixSocketNodeError.systemCall(operation: "lstat", path: path, code: errno)
        }
        // The node must be a socket this user owns before it is touched at all, and the mode
        // is deliberately not part of that: the node was just created by this process's bind,
        // and the mode is a parameter of that bind rather than a fact about a stranger's file.
        try requireOwnedSocketIgnoringMode(status, path: path)
        guard chmod(path, 0o600) == 0 else {
            throw UnixSocketNodeError.systemCall(operation: "chmod", path: path, code: errno)
        }
    }

    /// Removes a socket node, and says so rather than removing anything that is not one.
    static func unlinkSocketNode(at path: String) throws {
        var status = stat()
        guard path.withCString({ lstat($0, &status) }) == 0 else {
            if errno == ENOENT {
                return
            }
            throw UnixSocketNodeError.systemCall(operation: "lstat", path: path, code: errno)
        }
        try requireOwnedSocketIgnoringMode(status, path: path)
        guard unlink(path) == 0 else {
            throw UnixSocketNodeError.systemCall(operation: "unlink", path: path, code: errno)
        }
    }

    private static func requireOwnedSocketIgnoringMode(_ status: stat, path: String) throws {
        guard status.st_mode & mode_t(0o170000) == mode_t(0o140000) else {
            throw UnixSocketNodeError.pathIsNotASocket(path)
        }
        let owner = geteuid()
        guard status.st_uid == owner else {
            throw UnixSocketNodeError.pathIsNotOwnedByThisUser(path, actual: status.st_uid)
        }
    }

    private static func requireOwnerOnlyLockNode(_ path: String) throws {
        var status = stat()
        guard path.withCString({ lstat($0, &status) }) == 0 else {
            if errno == ENOENT {
                return
            }
            throw UnixSocketNodeError.systemCall(operation: "lstat", path: path, code: errno)
        }
        guard status.st_mode & mode_t(0o170000) == mode_t(0o100000) else {
            throw UnixSocketNodeError.ownerNodeIsNotARegularFile(path)
        }
        // OWNER-ONLY, NOT EXACTLY 0600, and the reason is the same as for the socket node:
        // `open(3)` masks the mode it is given, so a process whose umask is 0277 or 0777
        // creates this node as 0400 or 0000, and requiring exactly 0600 would make the
        // pathname unclaimable on every subsequent start for a server that merely ran once
        // under a permissive umask. The mode carries no evidence about a lock; the held
        // lock does.
        let permissions = status.st_mode & 0o777
        guard permissions & 0o077 == 0 else {
            throw UnixSocketNodeError.ownerNodeIsNotOwnerOnly(path, actual: permissions)
        }
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
/// A FINAL CLASS because it owns the pathname claim for the life of the process, and the
/// claim is what the shutdown path consults before it removes anything.
final class PeerIdentifyingListenerFactory: HTTP2ServerTransport.ListenerFactory {
    typealias ConnectionChannel = HTTP2ServerTransport.ConnectionConfigurator.ConnectionChannel

    let eventLoopGroup: any EventLoopGroup
    let socketPath: String
    let registry: ConnectionPeerRegistry
    let logger: Logger

    private let claim = Mutex<SocketPathClaim?>(nil)

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

    /// Removes the socket this process bound, and does nothing if it never bound one.
    ///
    /// THE ABSENCE IS THE POINT. A server that failed to claim the pathname failed because
    /// another server is serving it, and the one thing it must not then do is remove that
    /// server's node — which is what an unconditional unlink would do, and what made a
    /// refused start destructive rather than merely inert.
    func releaseClaim() throws {
        guard let held = claim.withLock({ claim in
            defer { claim = nil }
            return claim
        }) else {
            return
        }
        try held.release()
    }

    func makeListeningChannel(
        listenerConfigurator: HTTP2ServerTransport.ListenerConfigurator,
        connectionConfigurator: HTTP2ServerTransport.ConnectionConfigurator,
    ) async throws -> NIOAsyncChannel<ConnectionChannel, Never> {
        let held = try UnixSocketNode.claim(socketPath)
        // The listening channel itself, so a failure AFTER the bind can close it. It is
        // captured from the server channel initializer because `NIOAsyncChannel` exposes no
        // close of its own, and a listener left open behind a released claim is a listener
        // still accepting on a pathname nobody owns.
        let listeningChannel = ListeningChannelReference()
        do {
            let channel = try await ServerBootstrap(group: eventLoopGroup)
                .serverChannelInitializer { channel in
                    listeningChannel.record(channel)
                    // The quiescing handler the listener configurator installs is what makes
                    // `beginGracefulShutdown` close the LISTENER; omitting it would leave the
                    // process accepting connections it has already stopped serving.
                    return listenerConfigurator.configure(channel: channel)
                }
                .bind(
                    unixDomainSocketPath: socketPath,
                    cleanupExistingSocketFile: false,
                ) { channel in
                    Self.accept(channel, registry: self.registry, logger: self.logger) { channel in
                        connectionConfigurator.configure(channel: channel, tls: .none)
                    }
                }
            // HOISTED, and hoisted because of what used to be here. A throw after the bind
            // left the listening channel open and unreachable, and the claim it then released
            // unlinked the pathname out from under a socket that was still accepting. The
            // channel is now in scope for the failure path, so a post-bind failure closes the
            // listener before it drops the claim.
            do {
                // After the bind, because before it there is no node to check, and after it
                // there is no second chance: a listener left accessible to another user is a
                // listener this server cannot honestly call owner-only.
                try UnixSocketNode.hardenBoundNode(at: socketPath)
            } catch {
                try? await listeningChannel.close()
                throw error
            }
            // Only now, once the node exists and is this process's, does the claim become the
            // fact the shutdown path is allowed to act on.
            claim.withLock { $0 = held }
            logger.info("gRPC listener bound at \(self.socketPath, privacy: .public)")
            return channel
        } catch {
            // A bind that failed leaves the claim to drop, and dropping it removes only a
            // node this process proved nobody else was serving.
            try? held.release()
            throw error
        }
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
                    // A REFUSED REGISTRATION IS NOT AN IDENTIFIED CONNECTION. Past the
                    // ceiling the entry does not exist, so every capability on this
                    // connection resolves to nothing and denies, which is the fail-closed
                    // answer and not the alternative of attributing it to another.
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
/// The listening channel, for the one failure path that needs to close it.
private final class ListeningChannelReference: @unchecked Sendable {
    private let channel = Mutex<(any Channel)?>(nil)

    func record(_ channel: any Channel) {
        self.channel.withLock { $0 = channel }
    }

    func close() async throws {
        guard let channel = channel.withLock({ $0 }) else { return }
        try await channel.close().get()
    }
}

/// Retires a connection's token when that connection closes.
///
/// A `ChannelInboundHandler` installed ahead of the HTTP/2 and gRPC handlers, and it
/// forwards everything it sees, so it changes nothing about the byte stream. The inbound
/// type is `ByteBuffer` because an accepted `SocketChannel` has an empty pipeline when the
/// child initializer runs and the socket channel's own read type is what reaches it.
///
/// IT DEPENDS ON THE IDENTIFICATION BEING SYNCHRONOUS, which is a real constraint on future
/// edits rather than an incidental detail. `unsafeGetSocketOption` completes its promise
/// inline when it is already on the event loop, so the whole identification runs inside the
/// child initializer and this handler is installed before the child can become inactive. A
/// future step that hops threads would let a peer disconnect before the handler existed, and
/// `channelInactive` would fire into a pipeline this handler is not in — silently leaking a
/// live registration. The fix then is to retire from `channel.closeFuture` in the accept
/// path rather than from a pipeline event.
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
}
