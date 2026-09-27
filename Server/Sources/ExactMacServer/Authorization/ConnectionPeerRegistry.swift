import os
import Synchronization

/// The kernel's name for the peer's end of ONE connected Unix socket.
///
/// WHY A PATHNAME IS THE CORRELATION TOKEN, and it is the whole of E1's design. The
/// authorization interceptor runs per-RPC; the evidence is per-connection; and the pinned
/// gRPC stack hands an interceptor exactly two per-connection strings, `remotePeer` and
/// `localPeer`, both derived from the accepted socket's two addresses. A server-side
/// accepted Unix socket always reports the LISTENER's path as its local address, so the only
/// value that can differ between two live connections is the PEER's bound pathname.
///
/// IT IS A KERNEL FACT AND NOT A CLAIM, which is the distinction that decides whether this
/// is safe. `getpeername(2)` on the accepted socket returns the name the peer bound before
/// connecting, and `bind(2)` on a Unix pathname is exclusive among live sockets, so no
/// second process can be holding that name while the first is connected. A peer cannot
/// announce a token it does not hold: to produce one it must BE the socket the kernel bound
/// to it. The identity the operator judges — pid, effective uid, code signature — comes
/// from `LOCAL_PEERPID` and `LOCAL_PEERCRED` and is never derived from this string.
///
/// THE PRICE, and it is paid rather than hidden: a client that connects without binding a
/// pathname has no token, resolves to nothing, and is denied every capability. That is the
/// fail-closed direction, and it is why the Go MCP proxy binds its own socket.
struct PeerConnectionToken: Sendable, Hashable, CustomStringConvertible {
    let pathname: String

    var description: String { "PeerConnectionToken(\(pathname))" }

    /// - Returns: nil unless `peerDescription` is the transport's `unix:` form with a
    ///   non-empty pathname.
    ///
    /// ONLY THE `unix:` FORM IS ACCEPTED. A TCP description, `in-process:`, or
    /// `<unknown>` carries no connection token, and a registry that accepted them could be
    /// keyed by a value two different transports produce alike. An empty pathname is the
    /// same absence stated differently, so it is refused for the same reason.
    init?(peerDescription: String) {
        let prefix = "unix:"
        guard peerDescription.hasPrefix(prefix),
              peerDescription.utf8.count > prefix.utf8.count
        else {
            return nil
        }
        self.pathname = String(peerDescription.dropFirst(prefix.utf8.count))
    }
}

/// One connection's claim on a token.
///
/// REGISTERING IS NOT ENOUGH TO RETIRE, which is the whole reason this is a value. Two
/// connections can present the same token in sequence — the first closes, releasing the
/// pathname, and the second binds it and connects — and retiring on close without knowing
/// WHICH registration is being retired would let the first connection's `channelInactive`
/// retire the second one's live entry, denying a caller that did nothing wrong. The
/// registry compares identities, so a late retire is a no-op and only the registration that
/// still owns the token takes it out of service.
struct PeerConnectionRegistration: Sendable, Hashable {
    let token: PeerConnectionToken
    let identifier: UInt64
}

/// The kernel's evidence about each live connection, keyed by its token.
///
/// A FINAL CLASS, because a `let` of a struct holding a `Mutex` is not `Copyable` and one
/// registry is shared by every accepted connection and by every interceptor invocation.
final class ConnectionPeerRegistry: Sendable {
    private struct State {
        var live: [PeerConnectionToken: (identifier: UInt64, evidence: PeerProcessEvidence)] = [:]
        var nextIdentifier: UInt64 = 1
    }

    private let state = Mutex(State())
    private let logger = Logger(
        subsystem: "io.github.joeycumines.exactmac",
        category: "authorization.peers",
    )

    /// - Returns: the registration to hand back when the connection closes.
    ///
    /// THE MAP IS THE WHOLE OF THE STATE, and that is a deliberate bound. An earlier version
    /// also kept a set of retired tokens, so that a closed connection's token resolved to
    /// nothing even if an entry for it somehow survived. Removing the entry under the same
    /// lock that adds it already guarantees that, and the set grew by one entry per closed
    /// connection for the life of a long-lived process with no cap — which is a
    /// same-uid process looping connect-and-close, and a breach of the standing invariant
    /// that every growing server-side resource is bounded.
    func register(
        _ token: PeerConnectionToken,
        evidence: PeerProcessEvidence,
    ) -> PeerConnectionRegistration {
        let registration = state.withLock { state -> PeerConnectionRegistration in
            let identifier = state.nextIdentifier
            state.nextIdentifier += 1
            state.live[token] = (identifier, evidence)
            return PeerConnectionRegistration(token: token, identifier: identifier)
        }
        logger.info(
            """
            Registered connection token \(token.pathname, privacy: .private) \
            pid \(evidence.processIdentifier, privacy: .public) \
            uid \(evidence.effectiveUserIdentifier, privacy: .public) \
            live \(self.liveCount, privacy: .public)
            """,
        )
        return registration
    }

    /// Takes one connection's token out of service when that connection closes.
    ///
    /// ONLY IF IT STILL HOLDS IT. A token that has already been taken by a later
    /// connection is left alone, because retiring it would deny the wrong caller.
    func retire(_ registration: PeerConnectionRegistration) {
        let retired: Bool = state.withLock { state in
            guard state.live[registration.token]?.identifier == registration.identifier else {
                return false
            }
            state.live.removeValue(forKey: registration.token)
            return true
        }
        logger.info(
            """
            Retired connection token \(registration.token.pathname, privacy: .private) \
            tookEffect \(retired, privacy: .public) live \(self.liveCount, privacy: .public)
            """,
        )
    }

    /// - Returns: the evidence for a live connection, or nil when the peer description is
    ///   not a Unix socket, names a connection that never registered, or names one that has
    ///   closed.
    func evidence(forPeerDescription description: String) -> PeerProcessEvidence? {
        guard let token = PeerConnectionToken(peerDescription: description) else { return nil }
        return state.withLock { state in
            state.live[token]?.evidence
        }
    }

    /// The number of connections currently attributable to a caller, for tests and logs.
    var liveCount: Int {
        state.withLock { $0.live.count }
    }
}
