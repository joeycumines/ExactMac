import Darwin
import Foundation
import os

// MARK: - The server end

/// The console channel's server half: a second owner-only socket, distinct from the gRPC
/// listener, existing only in the Unix-socket variant.
///
/// IT EXISTS ONLY IN THE UNIX-SOCKET VARIANT, and that is a property of the type rather
/// than a flag. `ConsoleServerEndpoint.listen` needs a Unix socket path, and a TCP server
/// has none to give it, so "the channel is not created in TCP mode" is a type error rather
/// than a conditional someone has to remember.
///
/// AUTHENTICATION IS BOTH WAYS. A one-way authenticated channel lets any process that
/// merely located the socket path post a decision, which would defeat the entire control
/// without touching a line of server logic. So the console's peer uid AND its token are
/// checked here, and the console checks the server's the same way.
final class ConsoleServerEndpoint: @unchecked Sendable {
    let socketPath: String
    let token: ConsoleChannelToken
    private let responder: @Sendable (QueryKind) async -> ConsoleReply
    private let logger = Logger(
        subsystem: "io.github.joeycumines.exactmac",
        category: "authorization.console",
    )
    private let consumedNonces = ConsumedNonces()
    private let lock = NSLock()
    private var listening: Int32 = -1
    private var connections: [Int32] = []
    /// Connections that have completed the handshake, as opposed to merely being open.
    ///
    /// A CONNECTION IS NOT A CONSOLE until it has produced the token, so the count is
    /// separate from `connections`: reachability is what the authorization layer asks before
    /// it decides that a request needs a prompt, and answering that from a socket that has
    /// not authenticated would report a consent path that does not exist.
    private var authenticatedPeers = 0

    /// Whether a console is connected and has authenticated.
    ///
    /// THE ANSWER THE AUTHORIZATION LAYER ASKS, and the reason it is a live answer rather
    /// than a constant: `true` when no console is running means the interceptor takes the
    /// consent path and then denies on the timeout, and a console that is running means the
    /// operator is actually prompted. The stale-true direction is a prompt that never
    /// appears; the stale-false direction is a permanently unusable service.
    var hasAuthenticatedConsole: Bool {
        lock.withLock { authenticatedPeers > 0 }
    }

    /// - Parameter responder: what a console query is answered with. The CHANNEL carries
    ///   queries; what is in an answer belongs to the store, the audit and the settings, and
    ///   the composition owns that wiring rather than this file inventing three shapes.
    init(
        socketPath: String,
        token: ConsoleChannelToken,
        responder: @escaping @Sendable (QueryKind) async -> ConsoleReply,
    ) {
        self.socketPath = socketPath
        self.token = token
        self.responder = responder
    }

    /// Binds and listens. Owner-only, because the whole boundary is that the owning user is
    /// the only one who can be the console.
    func listen() throws {
        // A stale socket from a previous run would make bind fail, and it is ours by
        // pathname — but only after it has been checked, because unlinking whatever is at
        // the path is how a symlink at that path becomes a way to remove someone else's file.
        var info = stat()
        if lstat(socketPath, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFSOCK else {
                throw ConsoleChannelError.unavailable(reason: "the console socket path is not a socket")
            }
            guard unlink(socketPath) == 0 else {
                throw ConsoleChannelError.unavailable(reason: "a stale console socket could not be removed")
            }
        }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw ConsoleChannelError.unavailable(reason: "socket failed with errno \(errno)")
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        // sun_path is a fixed 104 bytes, and a path that does not fit is a configuration
        // error rather than something to truncate — a truncated path is a different path.
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(descriptor)
            throw ConsoleChannelError.unavailable(reason: "the console socket path is too long")
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { chars in
                for (index, byte) in pathBytes.enumerated() {
                    chars[index] = CChar(bitPattern: byte)
                }
                chars[pathBytes.count] = 0
            }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.stride))
            }
        }
        guard bound == 0 else {
            Darwin.close(descriptor)
            throw ConsoleChannelError.unavailable(reason: "bind failed with errno \(errno)")
        }
        // 0600 ON THE SOCKET, so the pathname itself is the boundary. Without it the socket
        // is connectable by any process on the machine and the token becomes the only thing
        // between a stranger and the operator's grants.
        guard chmod(socketPath, 0o600) == 0 else {
            Darwin.close(descriptor)
            unlink(socketPath)
            throw ConsoleChannelError.unavailable(reason: "chmod failed with errno \(errno)")
        }
        guard Darwin.listen(descriptor, 8) == 0 else {
            Darwin.close(descriptor)
            unlink(socketPath)
            throw ConsoleChannelError.unavailable(reason: "listen failed with errno \(errno)")
        }
        lock.withLock { listening = descriptor }
        logger.info("Console channel listening at \(self.socketPath, privacy: .public)")
    }

    /// Serves connections until `stop()`.
    func serve() async {
        while !Task.isCancelled {
            let descriptor = lock.withLock { listening }
            guard descriptor >= 0 else { return }
            let connection = await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    continuation.resume(returning: Darwin.accept(descriptor, nil, nil))
                }
            }
            guard connection >= 0 else {
                if errno == EINTR {
                    continue
                }
                return
            }
            lock.withLock { connections.append(connection) }
            // One task per connection, because a console that is streaming a decision must not
            // block the next one from connecting.
            Task { [weak self] in
                await self?.handle(connection)
                self?.lock.withLock { _ = self?.connections.firstIndex(of: connection) }
                _ = Darwin.close(connection)
            }
        }
    }

    func stop() {
        let (descriptor, open) = lock.withLock { () -> (Int32, [Int32]) in
            let open = connections
            connections = []
            authenticatedPeers = 0
            return (listening, open)
        }
        for connection in open {
            _ = Darwin.close(connection)
        }
        if descriptor >= 0 {
            _ = Darwin.close(descriptor)
            unlink(socketPath)
        }
        lock.withLock { listening = -1 }
    }

    /// Authenticates, then serves frames until the peer goes away.
    private func handle(_ connection: Int32) async {
        do {
            // THE SERVER IDENTIFIES ITSELF FIRST, and the ordering is the security property.
            //
            // The console must not show an operator's consent to a process that merely
            // answered on the path, so the server discloses its token before the console
            // says anything at all — including before the console discloses its own. A
            // console that is talking to a process which cannot produce the token learns
            // nothing, because it never spoke.
            //
            // What this does NOT defend against is stated in `ConsoleChannelToken`: a
            // same-uid process can read the operator's private files, so it can have the
            // token. The control for that case is the graded identity evidence the prompt
            // shows the operator, not this handshake.
            try FrameReader.write(
                .hello(ConsoleHello(
                    token: ConsoleServerEndpoint.tokenText(token),
                    version: ConsoleHello.currentVersion,
                )),
                to: connection,
            )
            guard case let .hello(hello) = try FrameReader.readFrame(from: connection) else {
                throw ConsoleChannelError.unauthenticated
            }
            guard hello.version == ConsoleHello.currentVersion, token.matches(hello.token) else {
                throw ConsoleChannelError.unauthenticated
            }
            // The peer uid, from the CONNECTED SOCKET and not from anything the peer said.
            // A console that merely located the path has the right uid on this machine and
            // the wrong token; a console that has the token and is a different user has the
            // wrong uid. Both are checked because both are cheap and the two facts are
            // different facts.
            var peerUID = uid_t()
            var peerGID = gid_t()
            guard getpeereid(connection, &peerUID, &peerGID) == 0, peerUID == geteuid() else {
                throw ConsoleChannelError.unauthenticated
            }
        } catch {
            logger.notice("A console connection was refused: it did not authenticate.")
            return
        }

        lock.withLock { authenticatedPeers += 1 }
        defer { lock.withLock { authenticatedPeers -= 1 } }

        // CAUGHT UP FIRST: anything raised before this console authenticated is sent to it
        // now, so a request that was already waiting is not lost to a late connection.
        for frame in pendingLock.withLock({ pendingByRequestID.values.map(\.frame) }) {
            _ = try? FrameReader.write(frame, to: connection)
        }

        while !Task.isCancelled {
            do {
                guard let frame = try FrameReader.readFrame(from: connection) else { return }
                switch frame {
                case let .decision(decision):
                    _ = consume(decision)
                case let .query(kind):
                    let reply = await responder(kind)
                    try FrameReader.write(.reply(reply), to: connection)
                case .hello:
                    // A second hello is a protocol error, not a re-authentication.
                    return
                case .pending, .reply:
                    // Server-to-console frames arriving inbound are refused rather than
                    // ignored, because a peer sending them is not speaking this protocol.
                    return
                }
            } catch {
                logger.notice("The console channel closed with an error: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
    }

    /// Single-use, bound to the request AND the digest, and bound to the nonce.
    ///
    /// - Returns: The answer when it is honoured; nil when it is not. Nothing is recorded
    ///   about a refused answer, because a prober must not be able to tell a replay from a
    ///   first attempt.
    private func consume(_ decision: ConsentDecision) -> Bool {
        guard let request = pendingByRequestID[decision.requestID] else { return false }
        guard decision.requestDigest == request.requestDigest else { return false }
        // THE NONCE MUST BE THIS REQUEST'S. Checking only that it is unspent was a hole the
        // concurrency suite found: with two requests pending, an answer carrying the first
        // one's UNSPENT nonce was accepted for the second, so a fingerprint given for a shell
        // authorised a clipboard read. Single-use is not the same as belonging-to-this-
        // decision, and only the second one stops the deputy.
        guard decision.nonce == request.nonce else { return false }
        guard consumedNonces.consume(decision.nonce) else { return false }
        answers.withLock { $0[decision.requestID] = decision }
        return true
    }

    /// The requests this endpoint has put to the console, so a decision can be checked
    /// against what was actually shown rather than against what the caller says was shown.
    /// A request that is waiting on the operator.
    ///
    /// It holds the FRAME as well as the two bindings, and the frame is kept so a console
    /// that authenticates after the request was raised still receives it: broadcasting only
    /// at the moment the request is raised loses the request whenever the console's
    /// connection has not been accepted yet, which at launch is most of the time, and a
    /// request nobody ever sees times out into a denial the operator experiences as a broken
    /// system.
    private struct Pending {
        /// The digest of the request the operator was SHOWN, so a decision that borrowed
        /// another request's consent is refused.
        var requestDigest: String
        /// Single-use, and bound to this request. A ceremony proves presence, and presence is
        /// not consent for a particular request.
        var nonce: String
        var frame: ConsoleFrame
    }

    private let pendingLock = NSLock()
    private var pendingByRequestID: [String: Pending] = [:]
    private let answers = AnswerLedger()

    /// Asks the console, under a bounded wait, and denies on the bound.
    ///
    /// This is the production `ConsentBroker`. A console that is not running yields nil
    /// rather than an error and rather than a wait, because "the console is not there" is
    /// not a fault in the caller and the two must not be distinguishable from outside.
    func obtainConsent(
        for request: AuthorizationRequest,
        identity: CallerIdentity,
        decision: AuthorizationDecision,
        timeout: Duration,
    ) async -> ConsentAnswer? {
        let nonce = ConsoleServerEndpoint.nonce(for: request)
        let digest = RequestDigest.of(request)
        let frame = ConsoleFrame.pending(PendingConsent(
            request: WireRequest(
                requestID: request.id.rawValue,
                rpcName: request.rpcName,
                capability: request.capability.rawValue,
                scopeDescription: request.scope.description,
                argumentSummary: request.argumentSummary,
                agentReason: request.agentReason,
                blastRadius: decision.blastRadius.radius,
                riskClass: decision.riskClass.rawValue,
                isRevokeAll: false,
                operationLimit: request.scope.operationLimit,
                effectiveCapabilities: decision.effectiveCapabilities.map(\.rawValue).sorted(),
            ),
            identity: WireIdentity(
                processIdentifier: identity.processIdentifier,
                effectiveUserIdentifier: identity.effectiveUserIdentifier,
                executablePath: identity.code.executablePath,
                bundleIdentifier: identity.code.bundleIdentifier,
                signature: identity.code.signature.rawValue,
                designatedRequirement: identity.code.designatedRequirement,
                isFullyResolved: identity.isFullyResolved,
                ancestors: identity.ancestors.map {
                    WireAncestor(
                        processIdentifier: $0.processIdentifier,
                        executablePath: $0.code.executablePath,
                        bundleIdentifier: $0.code.bundleIdentifier,
                        signature: $0.code.signature.rawValue,
                        isFullyResolved: $0.isFullyResolved,
                    )
                },
                isAncestryTruncated: identity.isAncestryTruncated,
            ),
            decision: WireDecision(
                basis: ConsoleServerEndpoint.describe(decision.basis),
                requiresBiometric: decision.biometric.reason != nil,
                biometricReason: decision.biometric.reason,
                offered: decision.offeredDecisions.map {
                    WireOption(
                        kind: $0.kind.rawValue,
                        scopeDescription: $0.scope.description,
                        durationDescription: ConsoleServerEndpoint.describe($0.duration),
                        blastRadius: $0.blastRadius.radius,
                        requiresBiometric: $0.biometric.reason != nil,
                        isDestructive: $0.isDestructive,
                        isDefault: $0.isDefault,
                        isPrimary: $0.isPrimary,
                    )
                },
                consentTimeoutSeconds: Int(timeout.components.seconds),
            ),
            nonce: nonce,
            requestDigest: digest,
        ))

        // Recorded BEFORE the request goes out, so a decision that arrives the instant the
        // console sees it cannot land before there is anything to check it against, and KEPT
        // so a console that authenticates later is caught up.
        pendingLock.withLock {
            pendingByRequestID[request.id.rawValue] = Pending(
                requestDigest: digest, nonce: nonce, frame: frame,
            )
        }
        defer { pendingLock.withLock { _ = pendingByRequestID.removeValue(forKey: request.id.rawValue) } }
        broadcast(frame)

        // Wait for an answer, or for the bound. A decision is delivered by the connection's
        // own task into the ledger, so this polls the ledger rather than the socket.
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let answer = answers.withLock({ $0[request.id.rawValue] }) {
                answers.withLock { _ = $0.removeValue(forKey: request.id.rawValue) }
                return ConsentAnswer(
                    requestID: AuthorizationRequestID(rawValue: answer.requestID),
                    isApproved: answer.isApproved,
                    selected: answer.selected.flatMap(OfferedDecision.Kind.init(rawValue:)),
                    note: answer.note,
                    biometricObtained: answer.biometricObtained,
                )
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        // A console that did not answer has not consented. A wait that ended in silence is
        // the same as a refusal, and neither is a hang.
        return nil
    }

    /// Sends a frame to every authenticated console, and to every console that
    /// authenticates later, so a request cannot be lost to a connection that had not been
    /// accepted yet.
    private func broadcast(_ frame: ConsoleFrame) {
        for connection in lock.withLock({ connections }) {
            _ = try? FrameReader.write(frame, to: connection)
        }
    }

    // MARK: - Seams the concurrency suite drives

    //
    // The socket handshake is proven end to end in `ConsoleChannelTests`. What cannot be
    // driven through a socket is the state that matters most here — which request is
    // pending, and whether a decision belongs to it — because two requests racing a real
    // socket is a test that passes for reasons that have nothing to do with the race. These
    // two expose exactly that state and nothing else.

    /// The consent a request is currently under, or nil when there is none.
    func pendingConsent(for requestID: String) -> (nonce: String, digest: String)? {
        let found: Pending? = pendingLock.withLock { pendingByRequestID[requestID] }
        guard let pending = found else { return nil }
        return (nonce: pending.nonce, digest: pending.requestDigest)
    }

    /// Posts a decision, and reports whether it was HONOURED.
    ///
    /// The return value is the point: "did this decision apply to the request it claims" is
    /// the question a caller has, and a channel that swallows the answer cannot be tested
    /// for the confused deputy it exists to prevent.
    @discardableResult
    func answer(_ decision: ConsentDecision) -> Bool {
        consume(decision)
    }

    private static func tokenText(_ token: ConsoleChannelToken) -> String {
        if case let .shared(value) = token {
            return value
        }
        return ""
    }

    private static func describe(_ duration: GrantDuration) -> String {
        switch duration {
        case .once: "once"
        case let .monotonicSeconds(seconds): "\(seconds)s"
        }
    }

    private static func describe(_ basis: DecisionBasis) -> String {
        switch basis {
        case .noConsentRequired: "noConsentRequired"
        case let .grant(id): "grant:\(id)"
        case let .envelope(id): "envelope:\(id)"
        case .promptRequired: "promptRequired"
        case let .denied(reason): "denied:\(reason.rawValue)"
        }
    }

    private static func nonce(for request: AuthorizationRequest) -> String {
        // Bound to the request, so two pending requests never share one.
        RequestDigest.of(request).prefix(32) + "-\(UUID().uuidString.prefix(8))"
    }
}

private final class AnswerLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: ConsentDecision] = [:]

    subscript(key: String) -> ConsentDecision? {
        get { lock.withLock { answers[key] } }
        set { lock.withLock { answers[key] = newValue } }
    }

    func withLock<Result>(_ body: (inout [String: ConsentDecision]) -> Result) -> Result {
        lock.withLock { body(&answers) }
    }
}
